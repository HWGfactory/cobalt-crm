public with sharing class CaseTriggerHandler extends TriggerHandler {

    public CaseTriggerHandler() {
        super('CaseTriggerHandler');
    }

    protected override void afterInsert(List<SObject> newList, Map<Id, SObject> newMap) {
        CaseEntitlementService.assignEntitlements(newMap.keySet());
    }

    protected override void afterUpdate(List<SObject> newList, Map<Id, SObject> newMap, Map<Id, SObject> oldMap) {
        afterUpdate((Map<Id, Case>) oldMap, (Map<Id, Case>) newMap);
    }

    @TestVisible
    private void afterUpdate(Map<Id, Case> oldMap, Map<Id, Case> newMap) {
        Set<Id> caseIdsRequiringConversion = new Set<Id>();
        for (Case c : newMap.values()) {
            Case oldCase = oldMap.get(c.Id);
            if (oldCase != null && !oldCase.Requires_Field_Visit__c && c.Requires_Field_Visit__c) {
                caseIdsRequiringConversion.add(c.Id);
            }
        }
        if (!caseIdsRequiringConversion.isEmpty()) {
            CaseToWorkOrderService.convertToWorkOrders(caseIdsRequiringConversion);
        }
    }
}
