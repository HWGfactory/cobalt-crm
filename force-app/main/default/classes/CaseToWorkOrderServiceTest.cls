@IsTest
private class CaseToWorkOrderServiceTest {

    private static Account createAccount() {
        Account acc = new Account(
            Name = 'CTWOS Test Account',
            BillingStreet = '123 Field St',
            BillingCity = 'Seoul',
            BillingState = 'Seoul',
            BillingPostalCode = '04524',
            BillingCountry = 'South Korea'
        );
        insert acc;
        return acc;
    }

    private static Service_Contract__c createContract(Id accountId) {
        Service_Contract__c contract = new Service_Contract__c(Account__c = accountId);
        insert contract;
        return contract;
    }

    private static Case createCase(Id accountId, Id contractId, String category, String priority) {
        return new Case(
            AccountId = accountId,
            Service_Contract__c = contractId,
            Case_Category__c = category,
            Priority = priority,
            Subject = 'Test Case',
            Requires_Field_Visit__c = false
        );
    }

    @IsTest
    static void testConvert_equipmentFailureMapsToElevatorSkillAndInheritsFields() {
        Account acc = createAccount();
        Service_Contract__c contract = createContract(acc.Id);
        Case c = createCase(acc.Id, contract.Id, 'Equipment Failure', 'High');
        insert c;

        Test.startTest();
        CaseToWorkOrderService.convertToWorkOrders(new Set<Id>{ c.Id });
        Test.stopTest();

        Case updated = [SELECT Status, Related_Work_Order__c FROM Case WHERE Id = :c.Id];
        System.assertNotEquals(null, updated.Related_Work_Order__c, 'Case에 새로 만든 Work Order가 연결되어야 함');
        System.assertEquals(
            CaseToWorkOrderService.CASE_WAITING_STATUS, updated.Status,
            'Case Status는 현장 서비스 대기 상태로 바뀌어야 함'
        );

        Work_Order__c wo = [
            SELECT Status__c, Priority__c, Required_Skill__c, Service_Contract__c, Service_Address__c
            FROM Work_Order__c
            WHERE Id = :updated.Related_Work_Order__c
        ];
        System.assertEquals(contract.Id, wo.Service_Contract__c);
        System.assertEquals('New', wo.Status__c);
        System.assertEquals('High', wo.Priority__c, 'Priority는 Case Priority를 그대로 승계해야 함');
        System.assertEquals(
            'Elevator', wo.Required_Skill__c, 'Equipment Failure는 Elevator 스킬로 매핑되어야 함'
        );
        System.assert(
            wo.Service_Address__c.contains('123 Field St') && wo.Service_Address__c.contains('Seoul'),
            'Service_Address__c는 Case Account의 청구지 주소로 채워져야 함'
        );
    }

    @IsTest
    static void testConvert_billingCategoryLeavesSkillBlank() {
        Account acc = createAccount();
        Service_Contract__c contract = createContract(acc.Id);
        Case c = createCase(acc.Id, contract.Id, 'Billing', 'Low');
        insert c;

        Test.startTest();
        CaseToWorkOrderService.convertToWorkOrders(new Set<Id>{ c.Id });
        Test.stopTest();

        Case updated = [SELECT Related_Work_Order__c FROM Case WHERE Id = :c.Id];
        Work_Order__c wo = [SELECT Required_Skill__c FROM Work_Order__c WHERE Id = :updated.Related_Work_Order__c];
        System.assertEquals(
            null, wo.Required_Skill__c,
            'Billing처럼 설비 스킬이 필요 없는 문의는 Required_Skill__c를 비워둬야 함'
        );
    }

    @IsTest
    static void testConvert_inheritsServiceRegionFromLatestSiblingWorkOrder() {
        Account acc = createAccount();
        Service_Contract__c contract = createContract(acc.Id);

        Work_Order__c sibling = new Work_Order__c(
            Service_Contract__c = contract.Id,
            Status__c = 'Completed',
            Service_Region__c = 'North'
        );
        insert sibling;

        Case c = createCase(acc.Id, contract.Id, 'Equipment Failure', 'Medium');
        insert c;

        Test.startTest();
        CaseToWorkOrderService.convertToWorkOrders(new Set<Id>{ c.Id });
        Test.stopTest();

        Case updated = [SELECT Related_Work_Order__c FROM Case WHERE Id = :c.Id];
        Work_Order__c wo = [SELECT Service_Region__c FROM Work_Order__c WHERE Id = :updated.Related_Work_Order__c];
        System.assertEquals(
            'North', wo.Service_Region__c,
            '새 Work Order는 같은 계약의 기존 작업 지역을 이어받아야 기술자 배정 후보를 찾을 수 있음'
        );
    }

    @IsTest
    static void testConvert_caseWithoutContractIsSkipped() {
        Account acc = createAccount();
        Case c = new Case(
            AccountId = acc.Id,
            Case_Category__c = 'Equipment Failure',
            Priority = 'High',
            Subject = 'No contract linked',
            Requires_Field_Visit__c = false
        );
        insert c;

        Test.startTest();
        CaseToWorkOrderService.convertToWorkOrders(new Set<Id>{ c.Id });
        Test.stopTest();

        Case unchanged = [SELECT Status, Related_Work_Order__c FROM Case WHERE Id = :c.Id];
        System.assertEquals(null, unchanged.Related_Work_Order__c, 'Service_Contract__c가 없으면 전환하지 않아야 함');
        System.assertNotEquals(
            CaseToWorkOrderService.CASE_WAITING_STATUS, unchanged.Status,
            'Service_Contract__c가 없으면 Status도 바뀌지 않아야 함'
        );
    }

    @IsTest
    static void testConvert_blankPriorityDefaultsToMedium() {
        Account acc = createAccount();
        Service_Contract__c contract = createContract(acc.Id);
        Case c = createCase(acc.Id, contract.Id, 'Inquiry', null);
        insert c;

        Test.startTest();
        CaseToWorkOrderService.convertToWorkOrders(new Set<Id>{ c.Id });
        Test.stopTest();

        Case updated = [SELECT Related_Work_Order__c FROM Case WHERE Id = :c.Id];
        Work_Order__c wo = [SELECT Priority__c FROM Work_Order__c WHERE Id = :updated.Related_Work_Order__c];
        System.assertEquals(CaseToWorkOrderService.DEFAULT_PRIORITY, wo.Priority__c);
    }

    @IsTest
    static void testConvert_bulkTwoCasesEachGetOwnWorkOrder() {
        Account acc = createAccount();
        Service_Contract__c contract = createContract(acc.Id);
        Case c1 = createCase(acc.Id, contract.Id, 'Equipment Failure', 'High');
        Case c2 = createCase(acc.Id, contract.Id, 'Installation Issue', 'Low');
        insert new List<Case>{ c1, c2 };

        Test.startTest();
        CaseToWorkOrderService.convertToWorkOrders(new Set<Id>{ c1.Id, c2.Id });
        Test.stopTest();

        List<Case> updated = [
            SELECT Related_Work_Order__c FROM Case WHERE Id IN :new List<Id>{ c1.Id, c2.Id }
        ];
        Set<Id> workOrderIds = new Set<Id>();
        for (Case c : updated) {
            System.assertNotEquals(null, c.Related_Work_Order__c);
            workOrderIds.add(c.Related_Work_Order__c);
        }
        System.assertEquals(2, workOrderIds.size(), '각 Case는 서로 다른 Work Order로 전환되어야 함');
    }

    @IsTest
    static void testConvert_invocableWrapperDelegatesToCoreLogic() {
        Account acc = createAccount();
        Service_Contract__c contract = createContract(acc.Id);
        Case c = createCase(acc.Id, contract.Id, 'Equipment Failure', 'High');
        insert c;

        Test.startTest();
        CaseToWorkOrderService.convertToWorkOrdersInvocable(new List<Id>{ c.Id });
        Test.stopTest();

        Case updated = [SELECT Related_Work_Order__c FROM Case WHERE Id = :c.Id];
        System.assertNotEquals(null, updated.Related_Work_Order__c, 'Invocable 진입점도 동일하게 전환을 수행해야 함');
    }

    @IsTest
    static void testConvert_emptyOrNullSetDoesNothing() {
        Test.startTest();
        CaseToWorkOrderService.convertToWorkOrders(new Set<Id>());
        CaseToWorkOrderService.convertToWorkOrders(null);
        Test.stopTest();
        System.assert(true, '빈 집합/널 입력 시 예외 없이 종료되어야 함');
    }
}
