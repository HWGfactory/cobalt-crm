@IsTest
private class TechnicianAssignmentServiceTest {

    private static Account createAccount() {
        Account acc = new Account(Name = 'TAS Test Account');
        insert acc;
        return acc;
    }

    private static Service_Contract__c createContract(Id accountId) {
        Service_Contract__c contract = new Service_Contract__c(Account__c = accountId);
        insert contract;
        return contract;
    }

    private static Technician__c buildTechnician(
        String name, String skills, String region, Decimal lat, Decimal lng, Decimal activeOrders
    ) {
        return new Technician__c(
            Name = name,
            Skills__c = skills,
            Service_Region__c = region,
            Is_Available__c = true,
            Active_Work_Orders__c = activeOrders,
            Base_Location__Latitude__s = lat,
            Base_Location__Longitude__s = lng
        );
    }

    private static Work_Order__c buildWorkOrder(
        Id contractId, String skill, String region, Decimal lat, Decimal lng, Datetime scheduled
    ) {
        return new Work_Order__c(
            Service_Contract__c = contractId,
            Status__c = 'New',
            Required_Skill__c = skill,
            Service_Region__c = region,
            Scheduled_Date__c = scheduled,
            Service_Location__Latitude__s = lat,
            Service_Location__Longitude__s = lng
        );
    }

    @IsTest
    static void testAssign_positiveCandidateGetsAssigned() {
        Account acc = createAccount();
        Service_Contract__c contract = createContract(acc.Id);

        Technician__c tech = buildTechnician('Near Tech', 'HVAC', 'North', 37.5665, 126.9780, 1);
        insert tech;

        Test.startTest();
        Work_Order__c wo = buildWorkOrder(contract.Id, 'HVAC', 'North', 37.5651, 126.9895, Datetime.now().addDays(1));
        insert wo;
        Test.stopTest();

        Work_Order__c result = [SELECT Status__c, Assigned_Technician__c FROM Work_Order__c WHERE Id = :wo.Id];
        System.assertEquals('Assigned', result.Status__c);
        System.assertEquals(tech.Id, result.Assigned_Technician__c);
    }

    @IsTest
    static void testAssign_bestScoringCandidateWinsOverFartherBusierTechnician() {
        Account acc = createAccount();
        Service_Contract__c contract = createContract(acc.Id);

        Technician__c nearIdleTech = buildTechnician('Near Idle', 'HVAC', 'North', 37.5651, 126.9895, 0);
        Technician__c farBusyTech = buildTechnician('Far Busy', 'HVAC', 'North', 38.5, 128.5, 9);
        insert new List<Technician__c>{ nearIdleTech, farBusyTech };

        Test.startTest();
        Work_Order__c wo = buildWorkOrder(contract.Id, 'HVAC', 'North', 37.5651, 126.9895, Datetime.now().addDays(1));
        insert wo;
        Test.stopTest();

        Work_Order__c result = [SELECT Assigned_Technician__c FROM Work_Order__c WHERE Id = :wo.Id];
        System.assertEquals(nearIdleTech.Id, result.Assigned_Technician__c);
    }

    @IsTest
    static void testAssign_noMatchingSkillEscalates() {
        Account acc = createAccount();
        Service_Contract__c contract = createContract(acc.Id);

        Technician__c tech = buildTechnician('Wrong Skill Tech', 'Plumbing', 'North', 37.5665, 126.9780, 0);
        insert tech;

        Test.startTest();
        Work_Order__c wo = buildWorkOrder(contract.Id, 'HVAC', 'North', 37.5651, 126.9895, Datetime.now().addDays(1));
        insert wo;
        Test.stopTest();

        // Work_Order__c 삽입 시 WorkOrderTrigger가 이미 assign()을 호출하므로 여기서 다시 호출하지 않음
        // (중복 호출 시 에스컬레이션 Task가 2건 생성됨).
        Work_Order__c result = [SELECT Status__c, Assigned_Technician__c FROM Work_Order__c WHERE Id = :wo.Id];
        System.assertEquals(null, result.Assigned_Technician__c);
        System.assertEquals('New', result.Status__c);

        List<Task> escalations = [SELECT Id, WhatId, Priority FROM Task WHERE WhatId = :wo.Id];
        System.assertEquals(1, escalations.size());
        System.assertEquals('High', escalations[0].Priority);
    }

    @IsTest
    static void testAssign_timeSlotConflictEscalates() {
        Account acc = createAccount();
        Service_Contract__c contract = createContract(acc.Id);

        Technician__c tech = buildTechnician('Booked Tech', 'HVAC', 'North', 37.5665, 126.9780, 0);
        insert tech;

        Datetime targetSlot = Datetime.now().addDays(2);

        Work_Order__c existingWo = buildWorkOrder(contract.Id, 'HVAC', 'North', 37.5651, 126.9895, targetSlot);
        existingWo.Assigned_Technician__c = tech.Id;
        existingWo.Status__c = 'Assigned';
        insert existingWo;

        Test.startTest();
        Work_Order__c newWo = buildWorkOrder(
            contract.Id, 'HVAC', 'North', 37.5651, 126.9895, targetSlot.addMinutes(30)
        );
        insert newWo;
        Test.stopTest();

        // Work_Order__c 삽입 시 WorkOrderTrigger가 이미 assign()을 호출하므로 여기서 다시 호출하지 않음.
        Work_Order__c result = [SELECT Assigned_Technician__c FROM Work_Order__c WHERE Id = :newWo.Id];
        System.assertEquals(null, result.Assigned_Technician__c);

        List<Task> escalations = [SELECT Id FROM Task WHERE WhatId = :newWo.Id];
        System.assertEquals(1, escalations.size());
    }

    @IsTest
    static void testAssign_emptyOrNullSetDoesNothing() {
        Test.startTest();
        TechnicianAssignmentService.assign(new Set<Id>());
        TechnicianAssignmentService.assign(null);
        Test.stopTest();
        System.assert(true, '빈 집합/널 입력 시 예외 없이 종료되어야 함');
    }

    @IsTest
    static void testAssign_bulk200WorkOrdersStaysWithinQueryLimits() {
        Account acc = createAccount();
        Service_Contract__c contract = createContract(acc.Id);

        List<Technician__c> techs = new List<Technician__c>();
        for (Integer i = 0; i < 10; i++) {
            techs.add(buildTechnician(
                'Bulk Tech ' + i, 'HVAC', 'North', 37.5 + (i * 0.01), 127.0 + (i * 0.01), 0
            ));
        }
        insert techs;

        List<Work_Order__c> orders = new List<Work_Order__c>();
        for (Integer i = 0; i < 200; i++) {
            orders.add(buildWorkOrder(
                contract.Id, 'HVAC', 'North', 37.55, 127.05, Datetime.now().addDays(1).addMinutes(i)
            ));
        }
        Integer queriesBefore = Limits.getQueries();
        Test.startTest();
        insert orders;
        Integer queriesAfterSync = Limits.getQueries();
        Test.stopTest();

        System.assert(
            (queriesAfterSync - queriesBefore) <= 5,
            '벌크 처리 시 레코드 수와 무관하게 SOQL 쿼리 수가 일정해야 함 (실제: ' + (queriesAfterSync - queriesBefore) + ')'
        );

        Set<Id> orderIds = new Map<Id, Work_Order__c>(orders).keySet();
        Integer resolvedCount = [
            SELECT COUNT() FROM Work_Order__c WHERE Id IN :orderIds AND Assigned_Technician__c != null
        ];
        Integer escalatedCount = [SELECT COUNT() FROM Task WHERE WhatId IN :orderIds];
        System.assertEquals(200, resolvedCount + escalatedCount);
    }
}
