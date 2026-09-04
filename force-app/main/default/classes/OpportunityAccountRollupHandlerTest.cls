@isTest
private class OpportunityAccountRollupHandlerTest {

    private static Account createAccount(String name) {
        Account acc = new Account(Name = name);
        insert acc;
        return acc;
    }

    @isTest
    static void testClosedWonWithinWindowRollsUpAcv() {
        Account acc = createAccount('Closed Won Within Window');

        Opportunity opp = new Opportunity(
            Name = 'Won Opp',
            AccountId = acc.Id,
            StageName = 'Closed Won',
            CloseDate = Date.today().addMonths(-3),
            Technician_Count__c = 10,
            Contract_Reviewed__c = true
        );

        Test.startTest();
        insert opp;
        Test.stopTest();

        Account updated = [SELECT Closed_Won_ACV_L12M__c, Open_Pipeline_Amount__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(10 * 49 * 12, updated.Closed_Won_ACV_L12M__c, 'ACV within the last 12 months should roll up');
        System.assertEquals(0, updated.Open_Pipeline_Amount__c, 'No open opportunities should mean zero open pipeline');
    }

    @isTest
    static void testClosedWonExactlyAtWindowBoundaryIsIncluded() {
        // 경계값 케이스: CloseDate가 정확히 12개월 전(windowStart)이면 '>=' 조건에 의해
        // 롤업 범위에 포함되어야 한다.
        Account acc = createAccount('Exact 12 Month Boundary Account');

        Opportunity opp = new Opportunity(
            Name = 'Exact Boundary Opp',
            AccountId = acc.Id,
            StageName = 'Closed Won',
            CloseDate = Date.today().addMonths(-12),
            Technician_Count__c = 10,
            Contract_Reviewed__c = true
        );

        Test.startTest();
        insert opp;
        Test.stopTest();

        Account updated = [SELECT Closed_Won_ACV_L12M__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(
            10 * 49 * 12, updated.Closed_Won_ACV_L12M__c,
            '정확히 12개월 전(경계값)의 CloseDate는 >= 조건에 의해 롤업에 포함되어야 합니다'
        );
    }

    @isTest
    static void testClosedWonOutsideWindowIsExcluded() {
        Account acc = createAccount('Closed Won Outside Window');

        Opportunity opp = new Opportunity(
            Name = 'Old Won Opp',
            AccountId = acc.Id,
            StageName = 'Closed Won',
            CloseDate = Date.today().addMonths(-13),
            Technician_Count__c = 10,
            Contract_Reviewed__c = true
        );

        Test.startTest();
        insert opp;
        Test.stopTest();

        Account updated = [SELECT Closed_Won_ACV_L12M__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(0, updated.Closed_Won_ACV_L12M__c, 'Opportunities closed more than 12 months ago should be excluded');
    }

    @isTest
    static void testOpenPipelineRollsUpAmount() {
        Account acc = createAccount('Open Pipeline Account');

        Opportunity opp = new Opportunity(
            Name = 'Open Opp',
            AccountId = acc.Id,
            StageName = 'Qualification',
            CloseDate = Date.today().addDays(30),
            Amount = 25000
        );

        Test.startTest();
        insert opp;
        Test.stopTest();

        Account updated = [SELECT Open_Pipeline_Amount__c, Closed_Won_ACV_L12M__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(25000, updated.Open_Pipeline_Amount__c, 'Open opportunity amount should roll up');
        System.assertEquals(0, updated.Closed_Won_ACV_L12M__c, 'No closed won opportunities should mean zero ACV');
    }

    @isTest
    static void testDeleteRecalculatesRollup() {
        Account acc = createAccount('Delete Recalc Account');

        Opportunity keepOpp = new Opportunity(
            Name = 'Keep Open Opp',
            AccountId = acc.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(60),
            Amount = 10000
        );
        Opportunity removeOpp = new Opportunity(
            Name = 'Remove Open Opp',
            AccountId = acc.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(60),
            Amount = 15000
        );
        insert new List<Opportunity>{ keepOpp, removeOpp };

        Account beforeDelete = [SELECT Open_Pipeline_Amount__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(25000, beforeDelete.Open_Pipeline_Amount__c, 'Both open opportunities should roll up before delete');

        Test.startTest();
        delete removeOpp;
        Test.stopTest();

        Account afterDelete = [SELECT Open_Pipeline_Amount__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(10000, afterDelete.Open_Pipeline_Amount__c, 'Deleting an opportunity should recalculate the rollup');
    }

    @isTest
    static void testAccountReparentingRecalculatesBothAccounts() {
        Account accA = createAccount('Reparent Source Account');
        Account accB = createAccount('Reparent Target Account');

        Opportunity opp = new Opportunity(
            Name = 'Reparented Opp',
            AccountId = accA.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(60),
            Amount = 5000
        );
        insert opp;

        opp.AccountId = accB.Id;
        Test.startTest();
        update opp;
        Test.stopTest();

        Account updatedA = [SELECT Open_Pipeline_Amount__c FROM Account WHERE Id = :accA.Id];
        Account updatedB = [SELECT Open_Pipeline_Amount__c FROM Account WHERE Id = :accB.Id];
        System.assertEquals(0, updatedA.Open_Pipeline_Amount__c, 'Original account should no longer include the reparented opportunity');
        System.assertEquals(5000, updatedB.Open_Pipeline_Amount__c, 'New account should include the reparented opportunity');
    }
}
