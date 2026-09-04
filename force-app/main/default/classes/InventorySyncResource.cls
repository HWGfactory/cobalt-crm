@RestResource(urlMapping='/inventory/sync/*')
global with sharing class InventorySyncResource {

    public class SyncRequestItem {
        public String sku;
        public Decimal quantity;
    }

    public class SyncRequest {
        public List<SyncRequestItem> items;
    }

    public class SyncFailure {
        public String sku;
        public String reason;

        public SyncFailure(String sku, String reason) {
            this.sku = sku;
            this.reason = reason;
        }
    }

    public class SyncResponse {
        public Integer successCount = 0;
        public Integer failureCount = 0;
        public List<SyncFailure> failures = new List<SyncFailure>();
    }

    @HttpPost
    global static void syncInventory() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;

        // 참고: 이 엔드포인트는 Connected App을 통한 OAuth 인증 세션에서만 도달 가능하다는 전제이며,
        // Salesforce 플랫폼이 Apex 코드 실행 전에 OAuth 토큰/세션 유효성을 이미 검증한다
        // (Apex에서 토큰 자체를 재검증할 방법도, 필요도 없음). 여기서는 그 다음 계층인
        // "이 통합 사용자가 실제로 Part__c 재고를 수정할 권한이 있는가(CRUD/FLS)"를 명시적으로 검증한다.
        if (!hasRequiredPermissions()) {
            writeError(res, 403, '이 통합 사용자에게는 Part__c 재고를 수정할 권한이 없습니다.');
            return;
        }

        SyncRequest payload;
        try {
            payload = (SyncRequest) JSON.deserialize(req.requestBody.toString(), SyncRequest.class);
        } catch (Exception ex) {
            writeError(res, 400, '요청 본문을 파싱할 수 없습니다: ' + ex.getMessage());
            return;
        }

        if (payload == null || payload.items == null || payload.items.isEmpty()) {
            writeError(res, 400, 'items 배열이 비어있거나 누락되었습니다.');
            return;
        }

        SyncResponse result;
        try {
            result = processSync(payload.items);
        } catch (Exception ex) {
            writeError(res, 500, '재고 동기화 처리 중 오류가 발생했습니다: ' + ex.getMessage());
            return;
        }

        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(result));
        logSync(req, result, 200, null);
    }

    @TestVisible
    private static SyncResponse processSync(List<SyncRequestItem> items) {
        SyncResponse result = new SyncResponse();

        Map<String, SyncRequestItem> validItemsBySku = new Map<String, SyncRequestItem>();
        for (SyncRequestItem item : items) {
            if (String.isBlank(item.sku)) {
                result.failures.add(new SyncFailure(item.sku, 'SKU가 비어있습니다.'));
                continue;
            }
            if (item.quantity == null || item.quantity < 0) {
                result.failures.add(new SyncFailure(item.sku, '수량이 없거나 음수입니다.'));
                continue;
            }
            // 같은 SKU가 한 페이로드에 중복 등장하면 ERP가 보낸 마지막 값을 최종 상태로 간주한다.
            validItemsBySku.put(item.sku, item);
        }

        if (!validItemsBySku.isEmpty()) {
            Map<String, Part__c> existingPartsBySku = new Map<String, Part__c>();
            for (Part__c part : [
                SELECT Id, SKU__c FROM Part__c WHERE SKU__c IN :validItemsBySku.keySet() WITH USER_MODE
            ]) {
                existingPartsBySku.put(part.SKU__c, part);
            }

            List<Part__c> partsToUpdate = new List<Part__c>();
            for (String sku : validItemsBySku.keySet()) {
                if (!existingPartsBySku.containsKey(sku)) {
                    // 잘못된/존재하지 않는 SKU는 새 Part__c를 만들지 않고 실패로 보고한다 -
                    // ERP 쪽 오타나 동기화 지연으로 유령 마스터 데이터가 생기는 것을 방지한다.
                    result.failures.add(new SyncFailure(sku, '일치하는 Part__c 레코드를 찾을 수 없습니다.'));
                    continue;
                }
                partsToUpdate.add(new Part__c(
                    Id = existingPartsBySku.get(sku).Id,
                    SKU__c = sku,
                    Stock_Quantity__c = validItemsBySku.get(sku).quantity,
                    Last_Synced__c = Datetime.now()
                ));
            }

            if (!partsToUpdate.isEmpty()) {
                List<Database.SaveResult> saveResults = Database.update(partsToUpdate, false);
                for (Integer i = 0; i < saveResults.size(); i++) {
                    Database.SaveResult sr = saveResults[i];
                    if (sr.isSuccess()) {
                        result.successCount++;
                    } else {
                        result.failures.add(new SyncFailure(partsToUpdate[i].SKU__c, sr.getErrors()[0].getMessage()));
                    }
                }
            }
        }

        result.failureCount = result.failures.size();
        return result;
    }

    private static Boolean hasRequiredPermissions() {
        return Schema.sObjectType.Part__c.isUpdateable()
            && Schema.sObjectType.Part__c.fields.Stock_Quantity__c.isUpdateable()
            && Schema.sObjectType.Part__c.fields.SKU__c.isAccessible();
    }

    private static void writeError(RestResponse res, Integer statusCode, String message) {
        res.statusCode = statusCode;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, String>{ 'error' => message }));
        logSync(RestContext.request, null, statusCode, message);
    }

    private static void logSync(RestRequest req, SyncResponse result, Integer statusCode, String errorMessage) {
        Integration_Log__c log = new Integration_Log__c(
            Integration_Type__c = 'Inventory',
            Endpoint__c = req != null ? req.requestURI : null,
            Request_Body__c = (req != null && req.requestBody != null) ? req.requestBody.toString() : null,
            Response_Body__c = result != null ? JSON.serialize(result) : null,
            Status_Code__c = statusCode,
            Is_Success__c = result != null && result.failureCount == 0,
            Error_Message__c = errorMessage != null
                ? errorMessage
                : (result != null && result.failureCount > 0 ? result.failureCount + '건의 SKU 매칭/검증 실패' : null)
        );
        insert log;
    }
}
