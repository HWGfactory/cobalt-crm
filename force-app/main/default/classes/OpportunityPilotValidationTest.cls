@isTest
private class OpportunityPilotValidationTest {

    @isTest
    static void testBlocksProposalWithoutPilot() {
        Opportunity opp = new Opportunity(
            Name = 'No Pilot Opp',
            StageName = 'Proposal/Negotiation',
            CloseDate = Date.today().addDays(30)
        );

        Boolean errorThrown = false;
        Test.startTest();
        try {
            insert opp;
        } catch (DmlException e) {
            errorThrown = true;
            System.assert(e.getMessage().contains('Pilot'), 'Expected Pilot-related error message');
        }
        Test.stopTest();

        System.assert(errorThrown, 'Expected an error when moving to Proposal/Negotiation without a linked Pilot');
    }

    @isTest
    static void testAllowsProposalWithPilot() {
        Opportunity opp = new Opportunity(
            Name = 'Has Pilot Opp',
            StageName = 'Qualification',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;

        Pilot__c pilot = new Pilot__c(
            Name = 'Test Pilot',
            Opportunity__c = opp.Id
        );
        insert pilot;

        opp.StageName = 'Proposal/Negotiation';
        Test.startTest();
        update opp;
        Test.stopTest();

        Opportunity updated = [SELECT StageName FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals('Proposal/Negotiation', updated.StageName);
    }

    @isTest
    static void testNonProposalStagesNeverRequirePilot() {
        // 부정 케이스: Pilot 검증은 Proposal/Negotiation 단계에만 적용되어야 한다.
        // 다른 단계는 Pilot이 전혀 없어도 항상 저장에 성공해야 한다.
        Opportunity qualificationOpp = new Opportunity(
            Name = 'Qualification No Pilot',
            StageName = 'Qualification',
            CloseDate = Date.today().addDays(30)
        );
        insert qualificationOpp;

        Opportunity demoOpp = new Opportunity(
            Name = 'Demo No Pilot',
            StageName = 'Demo/Solution Fit',
            CloseDate = Date.today().addDays(30),
            Technician_Count__c = 5
        );
        insert demoOpp;

        System.assertNotEquals(null, qualificationOpp.Id, 'Qualification 단계는 Pilot 없이도 저장되어야 합니다');
        System.assertNotEquals(null, demoOpp.Id, 'Demo/Solution Fit 단계도 Pilot 없이 저장되어야 합니다');
    }
}
