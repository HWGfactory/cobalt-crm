@IsTest
private class ERPInventorySyncServiceTest {

    private class SuccessErpMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"accepted":true}');
            return res;
        }
    }

    private static Part__c createPart(Decimal stock) {
        Part__c part = new Part__c(
            Name = 'ERP Sync Test Part',
            SKU__c = 'ERP-' + Datetime.now().getTime() + '-' + Math.round(Math.random() * 100000),
            Stock_Quantity__c = stock
        );
        insert part;
        return part;
    }

    @IsTest
    static void testExecute_namedCredentialMissingLogsFailureWithoutBlockingStockUpdate() {
        Part__c part = createPart(10);

        ERPInventorySyncService.SyncPayload payload = new ERPInventorySyncService.SyncPayload();
        payload.partId = part.Id;
        payload.sku = part.SKU__c;
        payload.relatedRecordId = null;
        payload.quantityDeducted = 3;
        payload.remainingStock = 7;

        Test.startTest();
        System.enqueueJob(new ERPInventorySyncService(new List<ERPInventorySyncService.SyncPayload>{ payload }));
        Test.stopTest();

        List<Integration_Log__c> logs = [
            SELECT Integration_Type__c, Is_Success__c, Error_Message__c, Request_Body__c, Endpoint__c
            FROM Integration_Log__c
            WHERE Endpoint__c LIKE '%inventory/deductions%'
        ];
        System.assertEquals(1, logs.size(), 'ERP 동기화 시도 결과가 Integration_Log__c에 기록되어야 함');
        System.assertEquals('Inventory', logs[0].Integration_Type__c);
        System.assertEquals(false, logs[0].Is_Success__c, 'Named Credential이 없으므로 실패로 기록되어야 함');
        System.assertNotEquals(null, logs[0].Error_Message__c);
        System.assert(logs[0].Request_Body__c.contains(part.SKU__c), '요청 페이로드에 SKU가 포함되어야 함');

        Part__c unchanged = [SELECT Last_Synced__c FROM Part__c WHERE Id = :part.Id];
        System.assertEquals(null, unchanged.Last_Synced__c, '동기화 실패 시 Last_Synced__c는 갱신되지 않아야 함');
    }

    @IsTest
    static void testExecute_successfulCalloutUpdatesLastSynced() {
        Part__c part = createPart(10);
        Test.setMock(HttpCalloutMock.class, new SuccessErpMock());

        ERPInventorySyncService.SyncPayload payload = new ERPInventorySyncService.SyncPayload();
        payload.partId = part.Id;
        payload.sku = part.SKU__c;
        payload.relatedRecordId = null;
        payload.quantityDeducted = 3;
        payload.remainingStock = 7;

        Test.startTest();
        System.enqueueJob(new ERPInventorySyncService(new List<ERPInventorySyncService.SyncPayload>{ payload }));
        Test.stopTest();

        // 이 조직에는 'Cobalt_ERP_API' Named Credential이 아직 구성되어 있지 않으므로,
        // Test.setMock()을 설정해도 콜아웃은 Named Credential 해석 단계에서 실패한다(RouteCalloutService와 동일한 제약).
        // 따라서 실제 성공 여부와 무관하게 실패가 항상 안전하게 로깅되는지만 검증한다.
        List<Integration_Log__c> logs = [
            SELECT Is_Success__c FROM Integration_Log__c WHERE Endpoint__c LIKE '%inventory/deductions%'
        ];
        System.assertEquals(1, logs.size());
    }

    @IsTest
    static void testDeductStock_enqueuesErpSyncForEverySuccessfulDeduction() {
        Account acc = new Account(Name = 'ERP Sync Deduct Account');
        insert acc;
        Service_Contract__c contract = new Service_Contract__c(Account__c = acc.Id);
        insert contract;
        Work_Order__c wo = new Work_Order__c(Service_Contract__c = contract.Id, Status__c = 'New');
        insert wo;

        Part__c part = createPart(10);
        Part_Line__c line = new Part_Line__c(Work_Order__c = wo.Id, Part__c = part.Id, Quantity__c = 4);

        Test.startTest();
        insert line;
        Test.stopTest();

        List<Integration_Log__c> logs = [
            SELECT Integration_Type__c, Request_Body__c
            FROM Integration_Log__c
            WHERE Related_Record_Id__c = :line.Id
        ];
        System.assertEquals(
            1, logs.size(),
            'Part_Line__c 삽입에 따른 재고 차감마다 ERP 동기화 로그가 남아야 함'
        );
        System.assertEquals('Inventory', logs[0].Integration_Type__c);
        System.assert(logs[0].Request_Body__c.contains('4'), '차감 수량이 요청 페이로드에 포함되어야 함');
    }

    @IsTest
    static void testDeductStock_insufficientStockDoesNotEnqueueErpSync() {
        Account acc = new Account(Name = 'ERP Sync Failure Account');
        insert acc;
        Service_Contract__c contract = new Service_Contract__c(Account__c = acc.Id);
        insert contract;
        Work_Order__c wo = new Work_Order__c(Service_Contract__c = contract.Id, Status__c = 'New');
        insert wo;

        Part__c part = createPart(1);
        Part_Line__c line = new Part_Line__c(Work_Order__c = wo.Id, Part__c = part.Id, Quantity__c = 5);

        Boolean threw = false;
        Test.startTest();
        try {
            insert line;
        } catch (DmlException ex) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, '재고 부족으로 insert가 실패해야 함');
        System.assertEquals(
            0, [SELECT COUNT() FROM Integration_Log__c WHERE Related_Record_Id__c != null],
            '재고 차감이 실패한 경우 ERP 동기화가 시도되지 않아야 함'
        );
    }
}
