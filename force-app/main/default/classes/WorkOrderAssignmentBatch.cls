public with sharing class WorkOrderAssignmentBatch implements Database.Batchable<SObject>, Schedulable {

    private static final Integer STALE_HOURS = 24;
    private static final Integer BATCH_SIZE = 50;

    public Database.QueryLocator start(Database.BatchableContext bc) {
        DateTime cutoff = DateTime.now().addHours(-STALE_HOURS);
        return Database.getQueryLocator([
            SELECT Id
            FROM Work_Order__c
            WHERE Status__c = 'New'
              AND Assigned_Technician__c = null
              AND CreatedDate <= :cutoff
        ]);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        Set<Id> workOrderIds = new Map<Id, SObject>(scope).keySet();
        if (!workOrderIds.isEmpty()) {
            TechnicianAssignmentService.assign(workOrderIds);
        }
    }

    public void finish(Database.BatchableContext bc) {
        // 배정/에스컬레이션은 assign() 내부에서 이미 처리됨 - 추가 후처리 없음.
    }

    public void execute(SchedulableContext sc) {
        Database.executeBatch(new WorkOrderAssignmentBatch(), BATCH_SIZE);
    }
}
