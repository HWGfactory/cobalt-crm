@IsTest
private class FieldCompletionControllerTest {

    // 1x1 투명 PNG의 Base64 (data URI 접두어 포함, canvas.toDataURL() 형식과 동일)
    private static final String SAMPLE_PNG_DATA_URI =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

    // Status를 Completed로 바꾸면 자동 청구/결제 콜아웃이 함께 트리거되므로,
    // 테스트 컨텍스트의 "enqueueJob 총 1회" 한도 안에서 끝나도록 결제가 즉시 성공하는 Mock을 사용한다.
    private class SuccessPaymentMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"transactionId":"TXN-FCC-OK","status":"succeeded"}');
            return res;
        }
    }

    private static Work_Order__c createWorkOrder() {
        Account acc = new Account(Name = 'Field Completion Test Account');
        insert acc;
        Service_Contract__c contract = new Service_Contract__c(Account__c = acc.Id);
        insert contract;
        Work_Order__c wo = new Work_Order__c(
            Service_Contract__c = contract.Id,
            Status__c = 'On Site',
            Service_Address__c = '456 Field St'
        );
        insert wo;
        // Name은 AutoNumber라 insert 직후 로컬 인스턴스에 채워지지 않으므로 재조회한다.
        return [SELECT Id, Name, Status__c, Service_Address__c FROM Work_Order__c WHERE Id = :wo.Id];
    }

    private static List<String> allChecklistItemsCompleted() {
        return FieldCompletionController.REQUIRED_CHECKLIST_ITEMS;
    }

    @IsTest
    static void testGetWorkOrderSummary_returnsCustomerAndAddress() {
        Work_Order__c wo = createWorkOrder();

        Test.startTest();
        FieldCompletionController.WorkOrderSummary summary = FieldCompletionController.getWorkOrderSummary(wo.Id);
        Test.stopTest();

        System.assertEquals(wo.Name, summary.workOrderNumber);
        System.assertEquals('456 Field St', summary.serviceAddress);
        System.assertEquals('Field Completion Test Account', summary.customerName);
    }

    @IsTest
    static void testGetWorkOrderSummary_missingWorkOrderThrows() {
        Boolean threw = false;
        Test.startTest();
        try {
            FieldCompletionController.getWorkOrderSummary(null);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'workOrderId가 없으면 예외가 발생해야 함');
    }

    @IsTest
    static void testSaveSignature_createsContentVersionLinkedToWorkOrder() {
        Work_Order__c wo = createWorkOrder();

        Test.startTest();
        FieldCompletionController.saveSignature(wo.Id, SAMPLE_PNG_DATA_URI);
        Test.stopTest();

        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId, ContentDocument.Title
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :wo.Id
        ];
        System.assertEquals(1, links.size(), '서명 파일이 Work Order에 연결되어야 함');
        System.assert(
            links[0].ContentDocument.Title.startsWith('Signature_'),
            '파일 제목이 Signature_ 접두어로 시작해야 함'
        );
    }

    @IsTest
    static void testSaveSignature_blankBase64Throws() {
        Work_Order__c wo = createWorkOrder();

        Boolean threw = false;
        Test.startTest();
        try {
            FieldCompletionController.saveSignature(wo.Id, '');
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, '빈 서명 데이터는 예외를 발생시켜야 함');
        System.assertEquals(0, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :wo.Id]);
    }

    @IsTest
    static void testSaveSignature_missingWorkOrderThrows() {
        Boolean threw = false;
        Test.startTest();
        try {
            FieldCompletionController.saveSignature(null, SAMPLE_PNG_DATA_URI);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw);
    }

    @IsTest
    static void testCompleteWorkOrder_allItemsCheckedCompletesSuccessfully() {
        Work_Order__c wo = createWorkOrder();

        Test.setMock(HttpCalloutMock.class, new SuccessPaymentMock());
        Test.startTest();
        FieldCompletionController.completeWorkOrder(wo.Id, allChecklistItemsCompleted());
        Test.stopTest();

        Work_Order__c updated = [
            SELECT Status__c, Signature_Captured__c, Completed_Date__c FROM Work_Order__c WHERE Id = :wo.Id
        ];
        System.assertEquals('Completed', updated.Status__c);
        System.assertEquals(true, updated.Signature_Captured__c);
        System.assertNotEquals(null, updated.Completed_Date__c);
    }

    @IsTest
    static void testCompleteWorkOrder_incompleteChecklistThrowsAndDoesNotUpdate() {
        Work_Order__c wo = createWorkOrder();
        List<String> partialChecklist = new List<String>{ FieldCompletionController.REQUIRED_CHECKLIST_ITEMS[0] };

        Boolean threw = false;
        Test.startTest();
        try {
            FieldCompletionController.completeWorkOrder(wo.Id, partialChecklist);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, '체크리스트가 모두 완료되지 않으면 예외가 발생해야 함');
        Work_Order__c unchanged = [SELECT Status__c, Signature_Captured__c FROM Work_Order__c WHERE Id = :wo.Id];
        System.assertEquals('On Site', unchanged.Status__c, '검증 실패 시 상태가 변경되지 않아야 함');
        System.assertEquals(false, unchanged.Signature_Captured__c);
    }

    @IsTest
    static void testCompleteWorkOrder_emptyChecklistThrows() {
        Work_Order__c wo = createWorkOrder();

        Boolean threw = false;
        Test.startTest();
        try {
            FieldCompletionController.completeWorkOrder(wo.Id, new List<String>());
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, '빈 체크리스트는 예외를 발생시켜야 함');
    }

    @IsTest
    static void testCompleteWorkOrder_nullChecklistThrows() {
        Work_Order__c wo = createWorkOrder();

        Boolean threw = false;
        Test.startTest();
        try {
            FieldCompletionController.completeWorkOrder(wo.Id, null);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, '널 체크리스트는 예외를 발생시켜야 함');
    }

    @IsTest
    static void testCompleteWorkOrder_missingWorkOrderThrows() {
        Boolean threw = false;
        Test.startTest();
        try {
            FieldCompletionController.completeWorkOrder(null, allChecklistItemsCompleted());
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw);
    }
}
