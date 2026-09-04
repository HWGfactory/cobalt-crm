@isTest
private class OpportunityTriggerHandlerTest {

    @isTest
    static void testStageEnteredDateIsStampedOnInsert() {
        Opportunity opp = new Opportunity(
            Name = 'Stage Stamp Insert Opp',
            StageName = 'Qualification',
            CloseDate = Date.today().addDays(30)
        );

        Test.startTest();
        insert opp;
        Test.stopTest();

        Opportunity inserted = [SELECT Stage_Entered_Date__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals(Date.today(), inserted.Stage_Entered_Date__c, '신규 생성 시 오늘 날짜로 스탬프되어야 합니다');
    }

    @isTest
    static void testStageEnteredDateUnchangedWhenStageDoesNotChange() {
        Opportunity opp = new Opportunity(
            Name = 'Stage Stamp NoChange Opp',
            StageName = 'Qualification',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;

        Date pastDate = Date.today().addDays(-30);
        opp.Stage_Entered_Date__c = pastDate;
        update opp;

        opp.Amount = 12345;
        Test.startTest();
        update opp;
        Test.stopTest();

        Opportunity updated = [SELECT Stage_Entered_Date__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals(
            pastDate, updated.Stage_Entered_Date__c,
            'Stage가 바뀌지 않은 업데이트는 Stage_Entered_Date__c를 건드리지 않아야 합니다'
        );
    }

    @isTest
    static void testStageEnteredDateResetsWhenStageChanges() {
        Opportunity opp = new Opportunity(
            Name = 'Stage Stamp Change Opp',
            StageName = 'Qualification',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;

        opp.Stage_Entered_Date__c = Date.today().addDays(-30);
        update opp;

        opp.StageName = 'Prospecting';
        Test.startTest();
        update opp;
        Test.stopTest();

        Opportunity updated = [SELECT Stage_Entered_Date__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals(
            Date.today(), updated.Stage_Entered_Date__c,
            'Stage가 변경되면 Stage_Entered_Date__c가 오늘 날짜로 재설정되어야 합니다'
        );
    }

    @isTest
    static void testBulkInsertStaysWithinGovernorLimitsAndRollsUpAccounts() {
        List<Account> accounts = new List<Account>{
            new Account(Name = 'Bulk Account A'),
            new Account(Name = 'Bulk Account B'),
            new Account(Name = 'Bulk Account C')
        };
        insert accounts;

        List<Opportunity> opps = new List<Opportunity>();
        Map<Id, Decimal> expectedClosedWonAcv = new Map<Id, Decimal>();
        Map<Id, Decimal> expectedOpenPipeline = new Map<Id, Decimal>();

        for (Integer i = 0; i < 200; i++) {
            Account acc = accounts[Math.mod(i, accounts.size())];
            Boolean isClosedWon = Math.mod(i, 2) == 0;

            Opportunity opp = new Opportunity(
                Name = 'Bulk Opp ' + i,
                AccountId = acc.Id,
                CloseDate = isClosedWon ? Date.today().addMonths(-1) : Date.today().addDays(30)
            );

            if (isClosedWon) {
                opp.StageName = 'Closed Won';
                opp.Contract_Reviewed__c = true;
                opp.Technician_Count__c = 10;
                expectedClosedWonAcv.put(
                    acc.Id,
                    (expectedClosedWonAcv.containsKey(acc.Id) ? expectedClosedWonAcv.get(acc.Id) : 0) + (10 * 49 * 12)
                );
            } else {
                opp.StageName = 'Prospecting';
                opp.Amount = 1000;
                expectedOpenPipeline.put(
                    acc.Id,
                    (expectedOpenPipeline.containsKey(acc.Id) ? expectedOpenPipeline.get(acc.Id) : 0) + 1000
                );
            }

            opps.add(opp);
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();

        insert opps;

        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        System.assert(
            queriesUsed <= 5,
            '벌크 insert 200건에 대해 SOQL 쿼리 수는 레코드 수와 무관하게 고정되어야 합니다. 실제: ' + queriesUsed
        );
        System.assert(
            dmlUsed <= 3,
            '벌크 insert 200건에 대해 DML 문 수는 레코드 수와 무관하게 고정되어야 합니다. 실제: ' + dmlUsed
        );

        Map<Id, Account> updatedAccounts = new Map<Id, Account>(
            [SELECT Id, Name, Closed_Won_ACV_L12M__c, Open_Pipeline_Amount__c FROM Account WHERE Id IN :accounts]
        );

        for (Account acc : accounts) {
            Account updated = updatedAccounts.get(acc.Id);
            Decimal expectedAcv = expectedClosedWonAcv.containsKey(acc.Id) ? expectedClosedWonAcv.get(acc.Id) : 0;
            Decimal expectedPipeline = expectedOpenPipeline.containsKey(acc.Id) ? expectedOpenPipeline.get(acc.Id) : 0;

            System.assertEquals(
                expectedAcv, updated.Closed_Won_ACV_L12M__c, updated.Name + '의 Closed Won ACV 롤업이 일치해야 합니다'
            );
            System.assertEquals(
                expectedPipeline, updated.Open_Pipeline_Amount__c, updated.Name + '의 오픈 파이프라인 롤업이 일치해야 합니다'
            );
        }
    }

    @isTest
    static void testBulkProposalValidationBlocksOnlyOpportunitiesWithoutPilot() {
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(new Opportunity(
                Name = 'Proposal Bulk Opp ' + i,
                StageName = 'Qualification',
                CloseDate = Date.today().addDays(30)
            ));
        }
        insert opps;

        List<Pilot__c> pilots = new List<Pilot__c>();
        for (Integer i = 0; i < opps.size(); i++) {
            if (Math.mod(i, 2) == 0) {
                pilots.add(new Pilot__c(
                    Name = 'Pilot ' + i,
                    Opportunity__c = opps[i].Id
                ));
            }
        }
        insert pilots;

        for (Opportunity opp : opps) {
            opp.StageName = 'Proposal/Negotiation';
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Database.SaveResult[] results = Database.update(opps, false);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        System.assert(
            queriesUsed <= 3,
            'Pilot 검증 SOQL은 벌크 업데이트 200건에 대해 1회로 처리되어야 합니다. 실제: ' + queriesUsed
        );

        for (Integer i = 0; i < results.size(); i++) {
            if (Math.mod(i, 2) == 0) {
                System.assert(results[i].isSuccess(), i + '번 레코드는 Pilot이 연결되어 있으므로 성공해야 합니다');
            } else {
                System.assert(!results[i].isSuccess(), i + '번 레코드는 Pilot이 없으므로 실패해야 합니다');
                System.assert(
                    results[i].getErrors()[0].getMessage().contains('Pilot'),
                    'Pilot 관련 에러 메시지가 있어야 합니다'
                );
            }
        }
    }

    @isTest
    static void testHandleClosedWon_stageChangeToClosedWonCreatesServiceContract() {
        Account acc = new Account(Name = 'Closed Won Handler Test Account');
        insert acc;

        Opportunity opp = new Opportunity(
            Name = 'Closed Won Handler Opp',
            AccountId = acc.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Product_Tier__c = 'Pro',
            Contract_Reviewed__c = true
        );
        insert opp;

        Test.startTest();
        opp.StageName = 'Closed Won';
        update opp;
        Test.stopTest();

        List<Service_Contract__c> contracts = [
            SELECT Id, Tier__c, SLA_Hours__c FROM Service_Contract__c WHERE Opportunity__c = :opp.Id
        ];
        System.assertEquals(1, contracts.size(), 'Closed Won으로 전환되면 Service_Contract__c가 1건 생성되어야 합니다');
        System.assertEquals('Pro', contracts[0].Tier__c);
        System.assertEquals(24, contracts[0].SLA_Hours__c);

        System.assertEquals(
            4, [SELECT COUNT() FROM Work_Order__c WHERE Service_Contract__c = :contracts[0].Id],
            '분기별 정기 점검 Work Order가 4건 생성되어야 합니다'
        );
    }

    @isTest
    static void testHandleClosedWon_doesNotFireWhenStageWasAlreadyClosedWon() {
        Account acc = new Account(Name = 'Already Closed Won Account');
        insert acc;

        Opportunity opp = new Opportunity(
            Name = 'Already Closed Won Opp',
            AccountId = acc.Id,
            StageName = 'Closed Won',
            CloseDate = Date.today(),
            Product_Tier__c = 'Enterprise',
            Contract_Reviewed__c = true
        );
        insert opp;

        Test.startTest();
        opp.Amount = 5000;
        update opp;
        Test.stopTest();

        System.assertEquals(
            0, [SELECT COUNT() FROM Service_Contract__c WHERE Opportunity__c = :opp.Id],
            'Insert 시점에는 handleClosedWon이 실행되지 않고, Stage 변경 없는 Update로도 새로 생성되지 않아야 합니다'
        );
    }

    @isTest
    static void testHandleClosedWon_bulkStageChangeToClosedWon() {
        Account acc = new Account(Name = 'Bulk Closed Won Account');
        insert acc;

        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(new Opportunity(
                Name = 'Bulk Closed Won Opp ' + i,
                AccountId = acc.Id,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(30),
                Product_Tier__c = 'Starter',
                Contract_Reviewed__c = true
            ));
        }
        insert opps;

        for (Opportunity opp : opps) {
            opp.StageName = 'Closed Won';
        }

        Test.startTest();
        update opps;
        Test.stopTest();

        Set<Id> oppIds = new Map<Id, Opportunity>(opps).keySet();
        System.assertEquals(
            200, [SELECT COUNT() FROM Service_Contract__c WHERE Opportunity__c IN :oppIds],
            '200건 벌크 Closed Won 전환에 대해 Service_Contract__c가 각각 1건씩 생성되어야 합니다'
        );
    }
}
