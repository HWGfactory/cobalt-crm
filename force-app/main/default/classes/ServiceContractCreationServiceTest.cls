@IsTest
private class ServiceContractCreationServiceTest {

    private static Account createAccount() {
        Account acc = new Account(Name = 'SCCS Test Account');
        insert acc;
        return acc;
    }

    private static Opportunity buildOpportunity(Id accountId, String productTier) {
        return new Opportunity(
            Name = 'SCCS Test Opp ' + productTier,
            AccountId = accountId,
            StageName = 'Closed Won',
            CloseDate = Date.today(),
            Product_Tier__c = productTier,
            Contract_Reviewed__c = true
        );
    }

    @IsTest
    static void testCreateFromOpportunities_enterpriseTierCreatesContractAndQuarterlyOrders() {
        Account acc = createAccount();
        Opportunity opp = buildOpportunity(acc.Id, 'Enterprise');
        insert opp;

        Test.startTest();
        ServiceContractCreationService.createFromOpportunities(new Set<Id>{ opp.Id });
        Test.stopTest();

        Service_Contract__c contract = [
            SELECT Account__c, Opportunity__c, Start_Date__c, End_Date__c, Tier__c, SLA_Hours__c, Status__c
            FROM Service_Contract__c
            WHERE Opportunity__c = :opp.Id
        ];
        System.assertEquals(acc.Id, contract.Account__c);
        System.assertEquals(opp.Id, contract.Opportunity__c);
        System.assertEquals(Date.today(), contract.Start_Date__c);
        System.assertEquals(Date.today().addYears(1), contract.End_Date__c);
        System.assertEquals('Enterprise', contract.Tier__c);
        System.assertEquals(4, contract.SLA_Hours__c);
        System.assertEquals('Active', contract.Status__c);

        List<Work_Order__c> maintenanceOrders = [
            SELECT Status__c, Priority__c, Work_Type__c, Scheduled_Date__c, SLA_Deadline__c
            FROM Work_Order__c
            WHERE Service_Contract__c = :contract.Id
            ORDER BY Scheduled_Date__c ASC
        ];
        System.assertEquals(4, maintenanceOrders.size(), '분기별 정기 점검 Work Order가 4건 생성되어야 함');

        for (Integer i = 0; i < maintenanceOrders.size(); i++) {
            Work_Order__c wo = maintenanceOrders[i];
            System.assertEquals('New', wo.Status__c);
            System.assertEquals('Medium', wo.Priority__c);
            System.assertEquals('Maintenance', wo.Work_Type__c);
            System.assertNotEquals(null, wo.SLA_Deadline__c);

            Date expectedQuarterDate = Date.today().addMonths(3 * (i + 1));
            System.assertEquals(expectedQuarterDate, wo.Scheduled_Date__c.date(), (i + 1) + '분기 점검일이 3개월 간격이어야 함');
        }
    }

    @IsTest
    static void testCreateFromOpportunities_tierToSlaHoursMapping() {
        System.assertEquals(48, ServiceContractCreationService.resolveSlaHours('Starter'));
        System.assertEquals(24, ServiceContractCreationService.resolveSlaHours('Pro'));
        System.assertEquals(4, ServiceContractCreationService.resolveSlaHours('Enterprise'));
        System.assertEquals(24, ServiceContractCreationService.resolveSlaHours(null), '알 수 없는/미설정 티어는 Pro(24h)로 기본 처리되어야 함');
    }

    @IsTest
    static void testCreateFromOpportunities_doesNotDuplicateWhenAlreadyConverted() {
        Account acc = createAccount();
        Opportunity opp = buildOpportunity(acc.Id, 'Starter');
        insert opp;

        Test.startTest();
        ServiceContractCreationService.createFromOpportunities(new Set<Id>{ opp.Id });
        ServiceContractCreationService.createFromOpportunities(new Set<Id>{ opp.Id });
        Test.stopTest();

        List<Service_Contract__c> contracts = [
            SELECT Id FROM Service_Contract__c WHERE Opportunity__c = :opp.Id
        ];
        System.assertEquals(1, contracts.size(), '이미 전환된 Opportunity는 다시 전환되지 않아야 함');
    }

    @IsTest
    static void testCreateFromOpportunities_emptyOrNullSetDoesNothing() {
        Test.startTest();
        ServiceContractCreationService.createFromOpportunities(new Set<Id>());
        ServiceContractCreationService.createFromOpportunities(null);
        Test.stopTest();
        System.assert(true, '빈 집합/널 입력 시 예외 없이 종료되어야 함');
    }

    @IsTest
    static void testCreateFromOpportunities_bulk200Opportunities() {
        Account acc = createAccount();
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(buildOpportunity(acc.Id, 'Pro'));
        }
        insert opps;

        Set<Id> oppIds = new Map<Id, Opportunity>(opps).keySet();

        Integer queriesBefore = Limits.getQueries();
        Test.startTest();
        ServiceContractCreationService.createFromOpportunities(oppIds);
        Integer queriesAfter = Limits.getQueries();
        Test.stopTest();

        // Work_Order__c 삽입은 WorkOrderTrigger(기술자 자동 배정 엔진)도 함께 촉발시키므로
        // 이 서비스 자체의 쿼리 수보다 여유 있게 잡되, 레코드 수(200/800건)에 비례하지 않는지만 검증한다.
        System.assert(
            (queriesAfter - queriesBefore) <= 15,
            '벌크 처리 시 레코드 수와 무관하게 SOQL 쿼리 수가 일정해야 함 (실제: ' + (queriesAfter - queriesBefore) + ')'
        );

        System.assertEquals(200, [SELECT COUNT() FROM Service_Contract__c WHERE Opportunity__c IN :oppIds]);
        System.assertEquals(800, [SELECT COUNT() FROM Work_Order__c WHERE Service_Contract__c IN (
            SELECT Id FROM Service_Contract__c WHERE Opportunity__c IN :oppIds
        )]);
    }
}
