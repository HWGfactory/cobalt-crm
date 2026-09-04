@isTest
private class PilotHealthCockpitControllerTest {

    @isTest
    static void testThrowsWhenOpportunityIdIsNull() {
        Boolean exceptionThrown = false;
        try {
            PilotHealthCockpitController.getCockpitData(null);
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        System.assert(exceptionThrown, 'Opportunity Id가 없으면 예외가 발생해야 합니다');
    }

    @isTest
    static void testFullyQualifiedOpportunityWithFuturePilotReturnsCompleteScorecard() {
        Opportunity opp = new Opportunity(
            Name = 'Fully Qualified Opp',
            StageName = 'Discovery',
            CloseDate = Date.today().addDays(60),
            Metrics__c = 'M',
            Economic_Buyer__c = 'EB',
            Decision_Criteria__c = 'DC',
            Decision_Process__c = 'DP',
            Identify_Pain__c = 'IP',
            Champion__c = 'C',
            MEDDIC_Score__c = 100
        );
        insert opp;

        Pilot__c pilot = new Pilot__c(
            Name = 'Future Pilot',
            Opportunity__c = opp.Id,
            Start_Date__c = Date.today().addDays(-5),
            End_Date__c = Date.today().addDays(10),
            Pilot_Health__c = 'Healthy',
            Technician_Count__c = 8
        );
        insert pilot;

        Test.startTest();
        PilotHealthCockpitController.CockpitData data = PilotHealthCockpitController.getCockpitData(opp.Id);
        Test.stopTest();

        System.assertEquals(100, data.meddic.completionPct, 'MEDDIC 완성도는 100%여야 합니다');
        for (PilotHealthCockpitController.MeddicFieldStatus field : data.meddic.fields) {
            System.assert(field.isFilled, field.label + ' 필드는 채워져 있어야 합니다');
        }

        System.assertEquals(1, data.pilots.size(), 'Pilot이 1건 반환되어야 합니다');
        PilotHealthCockpitController.PilotSummary summary = data.pilots[0];
        System.assertEquals('Healthy', summary.health);
        System.assertEquals(10, summary.daysRemaining, '10일 후 종료이므로 daysRemaining은 10이어야 합니다');
    }

    @isTest
    static void testEmptyOpportunityWithNoPilotReturnsEmptyScorecard() {
        Opportunity opp = new Opportunity(
            Name = 'Empty Opp',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;

        Test.startTest();
        PilotHealthCockpitController.CockpitData data = PilotHealthCockpitController.getCockpitData(opp.Id);
        Test.stopTest();

        System.assertEquals(0, data.meddic.completionPct, 'MEDDIC 필드가 없으면 완성도는 0%여야 합니다');
        for (PilotHealthCockpitController.MeddicFieldStatus field : data.meddic.fields) {
            System.assert(!field.isFilled, field.label + ' 필드는 비어있어야 합니다');
        }
        System.assertEquals(0, data.pilots.size(), 'Pilot이 없으면 빈 리스트를 반환해야 합니다');
    }

    @isTest
    static void testPilotEndingTodayHasZeroDaysRemainingBoundary() {
        Opportunity opp = new Opportunity(
            Name = 'Boundary Opp',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;

        Pilot__c pilot = new Pilot__c(
            Name = 'Ending Today Pilot',
            Opportunity__c = opp.Id,
            Start_Date__c = Date.today().addDays(-30),
            End_Date__c = Date.today(),
            Pilot_Health__c = 'At Risk'
        );
        insert pilot;

        Test.startTest();
        PilotHealthCockpitController.CockpitData data = PilotHealthCockpitController.getCockpitData(opp.Id);
        Test.stopTest();

        System.assertEquals(1, data.pilots.size());
        System.assertEquals(
            0, data.pilots[0].daysRemaining,
            '오늘이 종료일이면 daysRemaining은 정확히 0이어야 합니다 (경계값)'
        );
    }

    @isTest
    static void testOverduePilotHasNegativeDaysRemaining() {
        Opportunity opp = new Opportunity(
            Name = 'Overdue Opp',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;

        Pilot__c pilot = new Pilot__c(
            Name = 'Overdue Pilot',
            Opportunity__c = opp.Id,
            Start_Date__c = Date.today().addDays(-40),
            End_Date__c = Date.today().addDays(-3),
            Pilot_Health__c = 'Stalled'
        );
        insert pilot;

        Test.startTest();
        PilotHealthCockpitController.CockpitData data = PilotHealthCockpitController.getCockpitData(opp.Id);
        Test.stopTest();

        System.assertEquals(
            -3, data.pilots[0].daysRemaining,
            '종료일이 3일 지났으므로 daysRemaining은 -3이어야 합니다'
        );
        System.assertEquals('Stalled', data.pilots[0].health);
    }
}
