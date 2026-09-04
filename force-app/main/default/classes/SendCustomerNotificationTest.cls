@IsTest
private class SendCustomerNotificationTest {

    private static Account createAccountWithContact(String email, String phone) {
        Account acc = new Account(Name = 'Send Notification Test Account');
        insert acc;
        Contact con = new Contact(LastName = 'Customer', AccountId = acc.Id, Email = email, Phone = phone);
        insert con;
        return acc;
    }

    private static Work_Order__c createWorkOrder(Id accountId, String status, Datetime eta) {
        Service_Contract__c contract = new Service_Contract__c(Account__c = accountId);
        insert contract;
        Work_Order__c wo = new Work_Order__c(Service_Contract__c = contract.Id, Status__c = status, ETA__c = eta);
        insert wo;
        return wo;
    }

    private static SendCustomerNotification.NotificationRequest buildRequest(Id workOrderId) {
        SendCustomerNotification.NotificationRequest req = new SendCustomerNotification.NotificationRequest();
        req.workOrderId = workOrderId;
        return req;
    }

    @IsTest
    static void testSendNotifications_enRouteBuildsEtaMessageAndQueues() {
        Account acc = createAccountWithContact('customer@example.com', null);
        Work_Order__c wo = createWorkOrder(acc.Id, 'En Route', Datetime.now().addMinutes(30));

        Test.startTest();
        List<SendCustomerNotification.NotificationResult> results = SendCustomerNotification.sendNotifications(
            new List<SendCustomerNotification.NotificationRequest>{ buildRequest(wo.Id) }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(true, results[0].queued);

        List<Integration_Log__c> logs = [
            SELECT Integration_Type__c, Related_Record_Id__c, Request_Body__c
            FROM Integration_Log__c
            WHERE Related_Record_Id__c = :wo.Id
        ];
        System.assertEquals(1, logs.size());
        System.assertEquals('Messaging', logs[0].Integration_Type__c);
        System.assert(logs[0].Request_Body__c.contains('이동 중'), 'En Route 문안이 요청 본문에 포함되어야 함');
    }

    @IsTest
    static void testSendNotifications_onSiteBuildsArrivedMessage() {
        Account acc = createAccountWithContact('customer@example.com', null);
        Work_Order__c wo = createWorkOrder(acc.Id, 'On Site', null);

        Test.startTest();
        SendCustomerNotification.sendNotifications(
            new List<SendCustomerNotification.NotificationRequest>{ buildRequest(wo.Id) }
        );
        Test.stopTest();

        Integration_Log__c log = [SELECT Request_Body__c FROM Integration_Log__c WHERE Related_Record_Id__c = :wo.Id];
        System.assert(log.Request_Body__c.contains('도착했습니다'), 'On Site 문안이 포함되어야 함');
    }

    @IsTest
    static void testSendNotifications_completedBuildsCompletionMessage() {
        Account acc = createAccountWithContact('customer@example.com', null);
        Work_Order__c wo = createWorkOrder(acc.Id, 'Completed', null);

        Test.startTest();
        SendCustomerNotification.sendNotifications(
            new List<SendCustomerNotification.NotificationRequest>{ buildRequest(wo.Id) }
        );
        Test.stopTest();

        Integration_Log__c log = [SELECT Request_Body__c FROM Integration_Log__c WHERE Related_Record_Id__c = :wo.Id];
        System.assert(log.Request_Body__c.contains('완료되었습니다'), 'Completed 문안이 포함되어야 함');
    }

    @IsTest
    static void testSendNotifications_irrelevantStatusNotQueuedAndNoLog() {
        Account acc = createAccountWithContact('customer@example.com', null);
        Work_Order__c wo = createWorkOrder(acc.Id, 'Assigned', null);

        Test.startTest();
        List<SendCustomerNotification.NotificationResult> results = SendCustomerNotification.sendNotifications(
            new List<SendCustomerNotification.NotificationRequest>{ buildRequest(wo.Id) }
        );
        Test.stopTest();

        System.assertEquals(false, results[0].queued);
        System.assertEquals(0, [SELECT COUNT() FROM Integration_Log__c WHERE Related_Record_Id__c = :wo.Id]);
    }

    @IsTest
    static void testSendNotifications_missingContactNotQueued() {
        Account acc = new Account(Name = 'No Contact Account');
        insert acc;
        Work_Order__c wo = createWorkOrder(acc.Id, 'On Site', null);

        Test.startTest();
        List<SendCustomerNotification.NotificationResult> results = SendCustomerNotification.sendNotifications(
            new List<SendCustomerNotification.NotificationRequest>{ buildRequest(wo.Id) }
        );
        Test.stopTest();

        System.assertEquals(false, results[0].queued);
        System.assert(results[0].message.contains('연락처'));
        System.assertEquals(0, [SELECT COUNT() FROM Integration_Log__c WHERE Related_Record_Id__c = :wo.Id]);
    }

    @IsTest
    static void testSendNotifications_missingWorkOrderReturnsNotFound() {
        Account acc = createAccountWithContact('customer@example.com', null);
        Work_Order__c wo = createWorkOrder(acc.Id, 'On Site', null);
        Id fakeId = wo.Id;
        delete wo;

        Test.startTest();
        List<SendCustomerNotification.NotificationResult> results = SendCustomerNotification.sendNotifications(
            new List<SendCustomerNotification.NotificationRequest>{ buildRequest(fakeId) }
        );
        Test.stopTest();

        System.assertEquals(false, results[0].queued);
        System.assert(results[0].message.contains('찾을 수 없습니다'));
    }

    @IsTest
    static void testSendNotifications_emptyListReturnsEmptyResults() {
        Test.startTest();
        List<SendCustomerNotification.NotificationResult> results = SendCustomerNotification.sendNotifications(
            new List<SendCustomerNotification.NotificationRequest>()
        );
        Test.stopTest();

        System.assert(results.isEmpty());
    }

    @IsTest
    static void testSendNotifications_bulkRequestsPreserveOrderAndStayWithinQueryLimits() {
        Account acc = createAccountWithContact('customer@example.com', null);

        List<Work_Order__c> workOrders = new List<Work_Order__c>();
        Service_Contract__c contract = new Service_Contract__c(Account__c = acc.Id);
        insert contract;
        for (Integer i = 0; i < 20; i++) {
            workOrders.add(new Work_Order__c(
                Service_Contract__c = contract.Id,
                // 짝수 인덱스는 알림 대상 상태, 홀수 인덱스는 대상 아님 - 순서 보존 검증용으로 섞는다.
                Status__c = Math.mod(i, 2) == 0 ? 'On Site' : 'Assigned'
            ));
        }
        insert workOrders;

        List<SendCustomerNotification.NotificationRequest> requests = new List<SendCustomerNotification.NotificationRequest>();
        for (Work_Order__c wo : workOrders) {
            requests.add(buildRequest(wo.Id));
        }

        Integer queriesBefore = Limits.getQueries();
        Test.startTest();
        List<SendCustomerNotification.NotificationResult> results = SendCustomerNotification.sendNotifications(requests);
        Integer queriesAfter = Limits.getQueries();
        Test.stopTest();

        System.assert(
            (queriesAfter - queriesBefore) <= 3,
            '벌크 처리 시 레코드 수와 무관하게 SOQL 쿼리 수가 일정해야 함 (실제: ' + (queriesAfter - queriesBefore) + ')'
        );

        System.assertEquals(20, results.size(), '입력과 동일한 개수/순서로 결과를 반환해야 함');
        for (Integer i = 0; i < results.size(); i++) {
            System.assertEquals(
                Math.mod(i, 2) == 0, results[i].queued,
                i + '번째 결과가 입력 순서와 일치해야 함'
            );
        }

        System.assertEquals(10, [SELECT COUNT() FROM Integration_Log__c WHERE Related_Record_Id__c IN :new Map<Id, Work_Order__c>(workOrders).keySet()]);
    }
}
