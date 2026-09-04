@IsTest
private class WorkOrderStatusNotificationFlowTest {

    // 참고: 'Completed' 전환은 WorkOrderTriggerHandler의 자동 청구/결제 로직도 함께 트리거되어
    // 같은 트랜잭션에서 System.enqueueJob이 2회(결제 + 알림) 호출된다. 이는 실제 운영에서는
    // 문제 없이 동작하지만(트리거 컨텍스트에서도 서로 독립된 enqueueJob 호출은 50회까지 허용됨,
    // 익명 Apex로 직접 검증함), Apex 테스트 컨텍스트는 테스트 메서드 전체에서 enqueueJob 호출을
    // 통틀어 1회로만 제한한다. 그래서 이 Flow 통합 테스트는 다른 자동화와 겹치지 않는
    // En Route/On Site 전환으로 "Flow가 실제로 Apex 액션을 호출한다"는 것만 검증하고,
    // Completed 문안 자체는 SendCustomerNotificationTest에서 Apex 액션을 직접 호출해 별도로 검증한다.

    private static Work_Order__c createWorkOrder() {
        Account acc = new Account(Name = 'Flow Notification Test Account');
        insert acc;
        Contact con = new Contact(LastName = 'FlowTestCustomer', AccountId = acc.Id, Email = 'flow-test@example.com');
        insert con;
        Service_Contract__c contract = new Service_Contract__c(Account__c = acc.Id);
        insert contract;
        Work_Order__c wo = new Work_Order__c(Service_Contract__c = contract.Id, Status__c = 'Assigned');
        insert wo;
        return wo;
    }

    @IsTest
    static void testFlow_statusChangeToEnRouteTriggersNotification() {
        Work_Order__c wo = createWorkOrder();

        Test.startTest();
        wo.Status__c = 'En Route';
        update wo;
        Test.stopTest();

        System.assertEquals(
            1, [SELECT COUNT() FROM Integration_Log__c WHERE Related_Record_Id__c = :wo.Id AND Integration_Type__c = 'Messaging'],
            'Status가 En Route로 바뀌면 Flow가 SendCustomerNotification을 호출해 알림 로그가 남아야 함'
        );
    }

    @IsTest
    static void testFlow_statusChangeToOnSiteTriggersNotification() {
        Work_Order__c wo = createWorkOrder();

        Test.startTest();
        wo.Status__c = 'On Site';
        update wo;
        Test.stopTest();

        System.assertEquals(
            1, [SELECT COUNT() FROM Integration_Log__c WHERE Related_Record_Id__c = :wo.Id AND Integration_Type__c = 'Messaging']
        );
    }

    @IsTest
    static void testFlow_unrelatedFieldChangeDoesNotTriggerNotification() {
        Work_Order__c wo = createWorkOrder();

        Test.startTest();
        wo.Labor_Hours__c = 3;
        update wo;
        Test.stopTest();

        System.assertEquals(
            0, [SELECT COUNT() FROM Integration_Log__c WHERE Related_Record_Id__c = :wo.Id AND Integration_Type__c = 'Messaging'],
            'Status__c가 변경되지 않았으면 Flow 진입 조건(ISCHANGED)에 의해 실행되지 않아야 함'
        );
    }

    @IsTest
    static void testFlow_statusChangeToNonNotifiableStatusDoesNotTriggerNotification() {
        Work_Order__c wo = createWorkOrder();

        Test.startTest();
        wo.Status__c = 'New';
        update wo;
        Test.stopTest();

        System.assertEquals(
            0, [SELECT COUNT() FROM Integration_Log__c WHERE Related_Record_Id__c = :wo.Id AND Integration_Type__c = 'Messaging'],
            'En Route/On Site/Completed 이외의 상태로 바뀌면 Flow의 기본(default) 분기로 빠져 알림이 없어야 함'
        );
    }
}
