public with sharing class ERPInventorySyncService implements Queueable, Database.AllowsCallouts {

    public class SyncPayload {
        public Id partId;
        public String sku;
        public Id relatedRecordId;
        public Decimal quantityDeducted;
        public Decimal remainingStock;
    }

    private static final String NAMED_CREDENTIAL = 'Cobalt_ERP_API';

    private final List<SyncPayload> payloads;

    public ERPInventorySyncService(List<SyncPayload> payloads) {
        this.payloads = payloads;
    }

    public void execute(QueueableContext context) {
        List<Integration_Log__c> logs = new List<Integration_Log__c>();
        List<Part__c> partsToMarkSynced = new List<Part__c>();

        for (SyncPayload payload : payloads) {
            Long startTime = Datetime.now().getTime();
            String endpoint = 'callout:' + NAMED_CREDENTIAL + '/inventory/deductions';
            String requestBody = JSON.serialize(new Map<String, Object>{
                'sku' => payload.sku,
                'quantityDeducted' => payload.quantityDeducted,
                'remainingStock' => payload.remainingStock
            });

            Integration_Log__c log = new Integration_Log__c(
                Integration_Type__c = 'Inventory',
                Related_Record_Id__c = payload.relatedRecordId,
                Endpoint__c = endpoint,
                Request_Body__c = requestBody,
                Is_Success__c = false
            );

            try {
                // TODO: Cobalt ERP 벤더 API 계약이 확정되면 실제 엔드포인트 경로/인증 방식으로 교체.
                // Named Credential 'Cobalt_ERP_API'가 Setup에 구성되어 있어야 이 콜아웃이 정상 동작함.
                HttpRequest req = new HttpRequest();
                req.setEndpoint(endpoint);
                req.setMethod('POST');
                req.setHeader('Content-Type', 'application/json');
                req.setBody(requestBody);
                req.setTimeout(10000);

                Http http = new Http();
                HttpResponse res = http.send(req);

                log.Status_Code__c = res.getStatusCode();
                log.Response_Body__c = res.getBody();
                log.Is_Success__c = res.getStatusCode() >= 200 && res.getStatusCode() < 300;

                if (log.Is_Success__c) {
                    partsToMarkSynced.add(new Part__c(Id = payload.partId, Last_Synced__c = Datetime.now()));
                } else {
                    log.Error_Message__c = 'ERP가 실패 상태 코드를 반환했습니다: ' + res.getStatusCode();
                }
            } catch (Exception calloutEx) {
                // Named Credential 미구성 또는 실제 ERP 엔드포인트 연결 실패 - 실패로 로깅하고
                // 다음 재고 변동 시 재동기화를 기대한다(Stock_Quantity__c 자체는 이미 정상 반영됨).
                log.Is_Success__c = false;
                log.Error_Message__c = calloutEx.getMessage();
            }

            log.Duration_Ms__c = Datetime.now().getTime() - startTime;
            logs.add(log);
        }

        if (!partsToMarkSynced.isEmpty()) {
            update partsToMarkSynced;
        }
        if (!logs.isEmpty()) {
            insert logs;
        }
    }
}
