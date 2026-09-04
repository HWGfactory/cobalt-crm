@IsTest
private class WorkOrderTriggerHandlerTest {

    // Completed 전환 시 자동 청구/결제 콜아웃이 함께 트리거되므로,
    // 테스트 컨텍스트의 "enqueueJob 총 1회" 한도 안에서 끝나도록 결제가 즉시 성공하는 Mock을 사용한다.
    private class SuccessPaymentMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"transactionId":"TXN-WOTH-OK","status":"succeeded"}');
            return res;
        }
    }

    private static Account createAccount() {
        Account acc = new Account(Name = 'WOTH Test Account');
        insert acc;
        return acc;
    }

    private static Service_Contract__c createContract(Id accountId) {
        Service_Contract__c contract = new Service_Contract__c(Account__c = accountId);
        insert contract;
        return contract;
    }

    @IsTest
    static void testAfterInsert_newUnassignedWorkOrderTriggersAssignment() {
        Account acc = createAccount();
        Service_Contract__c contract = createContract(acc.Id);

        Technician__c tech = new Technician__c(
            Name = 'Trigger Test Tech',
            Skills__c = 'HVAC',
            Service_Region__c = 'North',
            Is_Available__c = true,
            Active_Work_Orders__c = 0,
            Base_Location__Latitude__s = 37.5665,
            Base_Location__Longitude__s = 126.9780
        );
        insert tech;

        Test.startTest();
        Work_Order__c wo = new Work_Order__c(
            Service_Contract__c = contract.Id,
            Status__c = 'New',
            Required_Skill__c = 'HVAC',
            Service_Region__c = 'North',
            Scheduled_Date__c = Datetime.now().addDays(1),
            Service_Location__Latitude__s = 37.5651,
            Service_Location__Longitude__s = 126.9895
        );
        insert wo;
        Test.stopTest();

        Work_Order__c result = [SELECT Status__c, Assigned_Technician__c FROM Work_Order__c WHERE Id = :wo.Id];
        System.assertEquals('Assigned', result.Status__c);
        System.assertEquals(tech.Id, result.Assigned_Technician__c);
    }

    @IsTest
    static void testAfterInsert_nonNewStatusSkipsAssignment() {
        Account acc = createAccount();
        Service_Contract__c contract = createContract(acc.Id);

        Technician__c tech = new Technician__c(
            Name = 'Skip Test Tech',
            Skills__c = 'HVAC',
            Service_Region__c = 'North',
            Is_Available__c = true,
            Active_Work_Orders__c = 0,
            Base_Location__Latitude__s = 37.5665,
            Base_Location__Longitude__s = 126.9780
        );
        insert tech;

        Test.startTest();
        Work_Order__c wo = new Work_Order__c(
            Service_Contract__c = contract.Id,
            Status__c = 'Cancelled',
            Required_Skill__c = 'HVAC',
            Service_Region__c = 'North',
            Scheduled_Date__c = Datetime.now().addDays(1)
        );
        insert wo;
        Test.stopTest();

        Work_Order__c result = [SELECT Assigned_Technician__c FROM Work_Order__c WHERE Id = :wo.Id];
        System.assertEquals(null, result.Assigned_Technician__c, 'Status가 New가 아니면 자동 배정 로직이 실행되지 않아야 함');
    }

    @IsTest
    static void testAfterUpdate_transitionToNewTriggersAssignment() {
        Account acc = createAccount();
        Service_Contract__c contract = createContract(acc.Id);

        Technician__c tech = new Technician__c(
            Name = 'Update Test Tech',
            Skills__c = 'Electrical',
            Service_Region__c = 'South',
            Is_Available__c = true,
            Active_Work_Orders__c = 0,
            Base_Location__Latitude__s = 35.1796,
            Base_Location__Longitude__s = 129.0756
        );
        insert tech;

        Work_Order__c wo = new Work_Order__c(
            Service_Contract__c = contract.Id,
            Status__c = 'Cancelled',
            Required_Skill__c = 'Electrical',
            Service_Region__c = 'South',
            Scheduled_Date__c = Datetime.now().addDays(1)
        );
        insert wo;

        Test.startTest();
        wo.Status__c = 'New';
        update wo;
        Test.stopTest();

        Work_Order__c result = [SELECT Status__c, Assigned_Technician__c FROM Work_Order__c WHERE Id = :wo.Id];
        System.assertEquals('Assigned', result.Status__c);
        System.assertEquals(tech.Id, result.Assigned_Technician__c);
    }

    @IsTest
    static void testAfterInsert_noCandidateCreatesEscalationTask() {
        Account acc = createAccount();
        Service_Contract__c contract = createContract(acc.Id);

        Test.startTest();
        Work_Order__c wo = new Work_Order__c(
            Service_Contract__c = contract.Id,
            Status__c = 'New',
            Required_Skill__c = 'Elevator',
            Service_Region__c = 'West',
            Scheduled_Date__c = Datetime.now().addDays(1)
        );
        insert wo;
        Test.stopTest();

        List<Task> escalations = [SELECT Id FROM Task WHERE WhatId = :wo.Id];
        System.assertEquals(1, escalations.size());
    }

    @IsTest
    static void testAfterInsert_bulk200RecordsProcessedSafely() {
        Account acc = createAccount();
        Service_Contract__c contract = createContract(acc.Id);

        List<Technician__c> techs = new List<Technician__c>();
        for (Integer i = 0; i < 5; i++) {
            techs.add(new Technician__c(
                Name = 'Bulk Trigger Tech ' + i,
                Skills__c = 'Telecom',
                Service_Region__c = 'Central',
                Is_Available__c = true,
                Active_Work_Orders__c = 0,
                Base_Location__Latitude__s = 36.5 + (i * 0.01),
                Base_Location__Longitude__s = 127.5 + (i * 0.01)
            ));
        }
        insert techs;

        List<Work_Order__c> orders = new List<Work_Order__c>();
        for (Integer i = 0; i < 200; i++) {
            orders.add(new Work_Order__c(
                Service_Contract__c = contract.Id,
                Status__c = 'New',
                Required_Skill__c = 'Telecom',
                Service_Region__c = 'Central',
                Scheduled_Date__c = Datetime.now().addDays(1).addMinutes(i)
            ));
        }

        Test.startTest();
        insert orders;
        Test.stopTest();

        Set<Id> orderIds = new Map<Id, Work_Order__c>(orders).keySet();
        Integer resolvedCount = [
            SELECT COUNT() FROM Work_Order__c WHERE Id IN :orderIds AND Assigned_Technician__c != null
        ];
        Integer escalatedCount = [SELECT COUNT() FROM Task WHERE WhatId IN :orderIds];
        System.assertEquals(200, resolvedCount + escalatedCount);
    }

    @IsTest
    static void testAfterUpdate_transitionToCompletedGeneratesInvoice() {
        Account acc = new Account(Name = 'Completion Invoice Test Account');
        insert acc;
        Service_Contract__c contract = new Service_Contract__c(Account__c = acc.Id);
        insert contract;
        Work_Order__c wo = new Work_Order__c(
            Service_Contract__c = contract.Id,
            Status__c = 'On Site',
            Labor_Hours__c = 2
        );
        insert wo;

        Test.setMock(HttpCalloutMock.class, new SuccessPaymentMock());
        Test.startTest();
        wo.Status__c = 'Completed';
        update wo;
        Test.stopTest();

        System.assertEquals(
            1, [SELECT COUNT() FROM Invoice__c WHERE Work_Order__c = :wo.Id],
            'Work Order가 Completed로 전환되면 Invoice__c가 자동 생성되어야 함'
        );
    }

    @IsTest
    static void testAfterUpdate_nonCompletedTransitionDoesNotGenerateInvoice() {
        Account acc = new Account(Name = 'Non Completion Invoice Account');
        insert acc;
        Service_Contract__c contract = new Service_Contract__c(Account__c = acc.Id);
        insert contract;
        Work_Order__c wo = new Work_Order__c(Service_Contract__c = contract.Id, Status__c = 'Assigned');
        insert wo;

        Test.startTest();
        wo.Status__c = 'En Route';
        update wo;
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Invoice__c WHERE Work_Order__c = :wo.Id]);
    }

    @IsTest
    static void testAfterUpdate_alreadyCompletedDoesNotRegenerateInvoice() {
        Account acc = new Account(Name = 'Already Completed Invoice Account');
        insert acc;
        Service_Contract__c contract = new Service_Contract__c(Account__c = acc.Id);
        insert contract;
        Work_Order__c wo = new Work_Order__c(Service_Contract__c = contract.Id, Status__c = 'Completed');
        insert wo;

        Test.startTest();
        wo.Labor_Hours__c = 5;
        update wo;
        Test.stopTest();

        System.assertEquals(
            0, [SELECT COUNT() FROM Invoice__c WHERE Work_Order__c = :wo.Id],
            'Insert 시 이미 Completed였던 경우 이후 업데이트로는 재트리거되지 않아야 함'
        );
    }
}
