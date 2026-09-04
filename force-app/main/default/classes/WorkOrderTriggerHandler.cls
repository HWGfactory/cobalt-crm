public with sharing class WorkOrderTriggerHandler extends TriggerHandler {

    private static final String COMPLETED_STATUS = 'Completed';

    public WorkOrderTriggerHandler() {
        super('WorkOrderTriggerHandler');
    }

    protected override Integer getMaxLoopCount() {
        // 하나의 작업 하나의 실행 레이어 여정(생성 -> 배정 -> 상태 전환 여러 번 -> 완료)은
        // 실제로는 서로 다른 시점의 별도 트랜잭션에서 일어나지만, 자동 배정 엔진의 비동기
        // 콜백(RouteCalloutService)이 같은 트랜잭션 안에서 Work_Order__c를 한 번 더 갱신하는
        // 경우처럼 insert 1회 + update 여러 회가 한 트랜잭션에 몰릴 수 있다. 기본값(5)보다
        // 여유 있게 잡아 정상적인 다중 DML 시나리오에서 재귀 오탐이 나지 않도록 한다.
        return 10;
    }

    protected override void afterInsert(List<SObject> newList, Map<Id, SObject> newMap) {
        afterInsert((List<Work_Order__c>) newList);
    }

    protected override void afterUpdate(List<SObject> newList, Map<Id, SObject> newMap, Map<Id, SObject> oldMap) {
        afterUpdate((Map<Id, Work_Order__c>) oldMap, (Map<Id, Work_Order__c>) newMap);
    }

    @TestVisible
    private void afterInsert(List<Work_Order__c> newList) {
        Set<Id> workOrderIds = new Set<Id>();
        for (Work_Order__c wo : newList) {
            if (needsAssignment(wo)) {
                workOrderIds.add(wo.Id);
            }
        }
        dispatchAssignment(workOrderIds);
    }

    @TestVisible
    private void afterUpdate(Map<Id, Work_Order__c> oldMap, Map<Id, Work_Order__c> newMap) {
        Set<Id> workOrderIds = new Set<Id>();
        Set<Id> newlyCompletedWorkOrderIds = new Set<Id>();
        for (Work_Order__c wo : newMap.values()) {
            if (needsAssignment(wo)) {
                workOrderIds.add(wo.Id);
            }
            Work_Order__c oldWo = oldMap.get(wo.Id);
            if (oldWo != null && oldWo.Status__c != COMPLETED_STATUS && wo.Status__c == COMPLETED_STATUS) {
                newlyCompletedWorkOrderIds.add(wo.Id);
            }
        }
        dispatchAssignment(workOrderIds);
        dispatchInvoiceGeneration(newlyCompletedWorkOrderIds);
    }

    private static Boolean needsAssignment(Work_Order__c wo) {
        return wo.Status__c == 'New' && wo.Assigned_Technician__c == null;
    }

    private static void dispatchAssignment(Set<Id> workOrderIds) {
        if (!workOrderIds.isEmpty()) {
            TechnicianAssignmentService.assign(workOrderIds);
        }
    }

    private static void dispatchInvoiceGeneration(Set<Id> workOrderIds) {
        if (!workOrderIds.isEmpty()) {
            InvoiceGenerationService.generateInvoices(workOrderIds);
        }
    }
}
