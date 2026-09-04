public with sharing class OpportunityTriggerHandler extends TriggerHandler {

    private static final String PROPOSAL_STAGE = 'Proposal/Negotiation';
    private static final String CLOSED_WON_STAGE = 'Closed Won';

    public OpportunityTriggerHandler() {
        super('OpportunityTriggerHandler');
    }

    protected override Integer getMaxLoopCount() {
        // Database.update/insert 호출 시 allOrNone=false이고 일부 레코드가 addError로
        // 실패하면, 플랫폼이 실패 레코드를 정확히 가려내기 위해 같은 트랜잭션 내에서
        // before/after 트리거를 한 번 더 재실행한다(정상적인 부분 성공 처리 동작이며
        // 재귀 DML이 아니다). 한 트랜잭션에서 insert 1회 + 부분 실패 update 1회처럼
        // 정상적인 다중 DML을 수행해도 여유가 있도록 기본값(5)보다 넉넉하게 잡는다.
        return 10;
    }

    protected override void beforeInsert(List<SObject> newList) {
        stampStageEnteredDateOnInsert((List<Opportunity>) newList);
        validateProposalStageHasPilot((List<Opportunity>) newList);
    }

    protected override void beforeUpdate(List<SObject> newList, Map<Id, SObject> oldMap) {
        stampStageEnteredDateOnStageChange((List<Opportunity>) newList, (Map<Id, Opportunity>) oldMap);
        validateProposalStageHasPilot((List<Opportunity>) newList);
    }

    protected override void afterInsert(List<SObject> newList, Map<Id, SObject> newMap) {
        OpportunityAccountRollupHandler.handle(false, false, (List<Opportunity>) newList, new List<Opportunity>());
    }

    protected override void afterUpdate(List<SObject> newList, Map<Id, SObject> newMap, Map<Id, SObject> oldMap) {
        OpportunityAccountRollupHandler.handle(true, false, (List<Opportunity>) newList, (List<Opportunity>) oldMap.values());
        handleClosedWon((List<Opportunity>) newList, (Map<Id, Opportunity>) oldMap);
    }

    protected override void afterDelete(List<SObject> oldList, Map<Id, SObject> oldMap) {
        OpportunityAccountRollupHandler.handle(false, true, new List<Opportunity>(), (List<Opportunity>) oldList);
    }

    protected override void afterUndelete(List<SObject> newList, Map<Id, SObject> newMap) {
        OpportunityAccountRollupHandler.handle(false, false, (List<Opportunity>) newList, new List<Opportunity>());
    }

    @TestVisible
    private static void stampStageEnteredDateOnInsert(List<Opportunity> opportunities) {
        Date today = Date.today();
        for (Opportunity opp : opportunities) {
            if (opp.Stage_Entered_Date__c == null) {
                opp.Stage_Entered_Date__c = today;
            }
        }
    }

    @TestVisible
    private static void stampStageEnteredDateOnStageChange(List<Opportunity> newList, Map<Id, Opportunity> oldMap) {
        Date today = Date.today();
        for (Opportunity opp : newList) {
            Opportunity oldOpp = oldMap.get(opp.Id);
            if (oldOpp != null && opp.StageName != oldOpp.StageName) {
                opp.Stage_Entered_Date__c = today;
            }
        }
    }

    @TestVisible
    private static void validateProposalStageHasPilot(List<Opportunity> opportunities) {
        Set<Id> proposalOppIds = new Set<Id>();
        for (Opportunity opp : opportunities) {
            if (opp.StageName == PROPOSAL_STAGE && opp.Id != null) {
                proposalOppIds.add(opp.Id);
            }
        }

        Set<Id> oppIdsWithPilot = new Set<Id>();
        if (!proposalOppIds.isEmpty()) {
            for (Pilot__c pilot : [
                SELECT Opportunity__c
                FROM Pilot__c
                WHERE Opportunity__c IN :proposalOppIds
            ]) {
                oppIdsWithPilot.add(pilot.Opportunity__c);
            }
        }

        for (Opportunity opp : opportunities) {
            if (opp.StageName == PROPOSAL_STAGE && !oppIdsWithPilot.contains(opp.Id)) {
                opp.addError('Proposal/Negotiation 단계로 이동하려면 연결된 Pilot 레코드가 반드시 있어야 합니다.');
            }
        }
    }

    @TestVisible
    private static void handleClosedWon(List<Opportunity> newList, Map<Id, Opportunity> oldMap) {
        Set<Id> newlyClosedWonOppIds = new Set<Id>();
        for (Opportunity opp : newList) {
            Opportunity oldOpp = oldMap.get(opp.Id);
            if (oldOpp != null && oldOpp.StageName != CLOSED_WON_STAGE && opp.StageName == CLOSED_WON_STAGE) {
                newlyClosedWonOppIds.add(opp.Id);
            }
        }
        if (!newlyClosedWonOppIds.isEmpty()) {
            ServiceContractCreationService.createFromOpportunities(newlyClosedWonOppIds);
        }
    }
}
