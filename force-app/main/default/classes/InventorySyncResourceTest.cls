@IsTest
private class InventorySyncResourceTest {

    private static Part__c createPart(String sku, Decimal stock) {
        Part__c part = new Part__c(
            Name = 'Inventory Sync Test Part',
            SKU__c = sku,
            Stock_Quantity__c = stock
        );
        insert part;
        return part;
    }

    private static RestResponse setupRequest(String jsonBody) {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/inventory/sync/';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(jsonBody);
        RestContext.request = req;
        RestContext.response = new RestResponse();
        return RestContext.response;
    }

    @IsTest
    static void testSyncInventory_allValidSkusSucceed() {
        Part__c partA = createPart('SYNC-SKU-A-' + Datetime.now().getTime(), 10);
        Part__c partB = createPart('SYNC-SKU-B-' + Datetime.now().getTime(), 20);

        String body = JSON.serialize(new Map<String, Object>{
            'items' => new List<Map<String, Object>>{
                new Map<String, Object>{ 'sku' => partA.SKU__c, 'quantity' => 55 },
                new Map<String, Object>{ 'sku' => partB.SKU__c, 'quantity' => 77 }
            }
        });
        RestResponse res = setupRequest(body);

        Test.startTest();
        InventorySyncResource.syncInventory();
        Test.stopTest();

        System.assertEquals(200, res.statusCode);
        InventorySyncResource.SyncResponse result = (InventorySyncResource.SyncResponse) JSON.deserialize(
            res.responseBody.toString(), InventorySyncResource.SyncResponse.class
        );
        System.assertEquals(2, result.successCount);
        System.assertEquals(0, result.failureCount);
        System.assert(result.failures.isEmpty());

        Map<Id, Part__c> updated = new Map<Id, Part__c>([
            SELECT Id, Stock_Quantity__c, Last_Synced__c FROM Part__c WHERE Id IN (:partA.Id, :partB.Id)
        ]);
        System.assertEquals(55, updated.get(partA.Id).Stock_Quantity__c);
        System.assertEquals(77, updated.get(partB.Id).Stock_Quantity__c);
        System.assertNotEquals(null, updated.get(partA.Id).Last_Synced__c);

        List<Integration_Log__c> logs = [
            SELECT Integration_Type__c, Is_Success__c, Status_Code__c
            FROM Integration_Log__c
            WHERE Endpoint__c = '/services/apexrest/inventory/sync/'
        ];
        System.assertEquals(1, logs.size());
        System.assertEquals('Inventory', logs[0].Integration_Type__c);
        System.assertEquals(true, logs[0].Is_Success__c);
        System.assertEquals(200, logs[0].Status_Code__c);
    }

    @IsTest
    static void testSyncInventory_partialFailureReturnsFailureListButUpdatesValidOnes() {
        Part__c validPart = createPart('SYNC-SKU-VALID-' + Datetime.now().getTime(), 5);
        String unknownSku = 'SYNC-SKU-DOES-NOT-EXIST-' + Datetime.now().getTime();

        String body = JSON.serialize(new Map<String, Object>{
            'items' => new List<Map<String, Object>>{
                new Map<String, Object>{ 'sku' => validPart.SKU__c, 'quantity' => 42 },
                new Map<String, Object>{ 'sku' => unknownSku, 'quantity' => 10 },
                new Map<String, Object>{ 'sku' => 'SYNC-SKU-NEGATIVE', 'quantity' => -5 },
                new Map<String, Object>{ 'sku' => '', 'quantity' => 3 }
            }
        });
        RestResponse res = setupRequest(body);

        Test.startTest();
        InventorySyncResource.syncInventory();
        Test.stopTest();

        System.assertEquals(200, res.statusCode, '부분 실패도 HTTP 200으로 응답하고 본문에 실패 목록을 담아야 함');
        InventorySyncResource.SyncResponse result = (InventorySyncResource.SyncResponse) JSON.deserialize(
            res.responseBody.toString(), InventorySyncResource.SyncResponse.class
        );
        System.assertEquals(1, result.successCount);
        System.assertEquals(3, result.failureCount, '존재하지 않는 SKU + 음수 수량 + 빈 SKU = 3건 실패');

        Set<String> failedSkus = new Set<String>();
        for (InventorySyncResource.SyncFailure failure : result.failures) {
            failedSkus.add(failure.sku);
        }
        System.assert(failedSkus.contains(unknownSku), '존재하지 않는 SKU가 실패 목록에 있어야 함');
        System.assert(failedSkus.contains('SYNC-SKU-NEGATIVE'), '음수 수량 SKU가 실패 목록에 있어야 함');

        Part__c updated = [SELECT Stock_Quantity__c FROM Part__c WHERE Id = :validPart.Id];
        System.assertEquals(42, updated.Stock_Quantity__c, '유효한 항목은 다른 항목의 실패와 무관하게 갱신되어야 함');

        List<Integration_Log__c> logs = [
            SELECT Is_Success__c FROM Integration_Log__c WHERE Endpoint__c = '/services/apexrest/inventory/sync/'
        ];
        System.assertEquals(1, logs.size());
        System.assertEquals(false, logs[0].Is_Success__c, '실패 건이 있으므로 Is_Success__c는 false여야 함');
    }

    @IsTest
    static void testSyncInventory_duplicateSkuInPayloadUsesLastValue() {
        Part__c part = createPart('SYNC-SKU-DUP-' + Datetime.now().getTime(), 1);

        String body = JSON.serialize(new Map<String, Object>{
            'items' => new List<Map<String, Object>>{
                new Map<String, Object>{ 'sku' => part.SKU__c, 'quantity' => 10 },
                new Map<String, Object>{ 'sku' => part.SKU__c, 'quantity' => 99 }
            }
        });
        RestResponse res = setupRequest(body);

        Test.startTest();
        InventorySyncResource.syncInventory();
        Test.stopTest();

        Part__c updated = [SELECT Stock_Quantity__c FROM Part__c WHERE Id = :part.Id];
        System.assertEquals(99, updated.Stock_Quantity__c, '같은 SKU가 중복되면 마지막 값이 최종 반영되어야 함');
    }

    @IsTest
    static void testSyncInventory_emptyItemsReturns400() {
        RestResponse res = setupRequest(JSON.serialize(new Map<String, Object>{ 'items' => new List<Object>() }));

        Test.startTest();
        InventorySyncResource.syncInventory();
        Test.stopTest();

        System.assertEquals(400, res.statusCode);
    }

    @IsTest
    static void testSyncInventory_missingItemsReturns400() {
        RestResponse res = setupRequest(JSON.serialize(new Map<String, Object>{ 'note' => 'no items field' }));

        Test.startTest();
        InventorySyncResource.syncInventory();
        Test.stopTest();

        System.assertEquals(400, res.statusCode);
    }

    @IsTest
    static void testSyncInventory_malformedJsonReturns400() {
        RestResponse res = setupRequest('{this is not valid json');

        Test.startTest();
        InventorySyncResource.syncInventory();
        Test.stopTest();

        System.assertEquals(400, res.statusCode);
    }

    @IsTest
    static void testProcessSync_bulk50ItemsStaysWithinQueryLimits() {
        List<Part__c> parts = new List<Part__c>();
        for (Integer i = 0; i < 50; i++) {
            parts.add(new Part__c(
                Name = 'Bulk Sync Part ' + i,
                SKU__c = 'SYNC-BULK-' + Datetime.now().getTime() + '-' + i,
                Stock_Quantity__c = 0
            ));
        }
        insert parts;

        List<InventorySyncResource.SyncRequestItem> items = new List<InventorySyncResource.SyncRequestItem>();
        for (Part__c part : parts) {
            InventorySyncResource.SyncRequestItem item = new InventorySyncResource.SyncRequestItem();
            item.sku = part.SKU__c;
            item.quantity = 123;
            items.add(item);
        }

        Integer queriesBefore = Limits.getQueries();
        Test.startTest();
        InventorySyncResource.SyncResponse result = InventorySyncResource.processSync(items);
        Integer queriesAfter = Limits.getQueries();
        Test.stopTest();

        System.assertEquals(50, result.successCount);
        System.assertEquals(0, result.failureCount);
        System.assert(
            (queriesAfter - queriesBefore) <= 2,
            '벌크 처리 시 레코드 수와 무관하게 SOQL 쿼리 수가 일정해야 함 (실제: ' + (queriesAfter - queriesBefore) + ')'
        );
    }
}
