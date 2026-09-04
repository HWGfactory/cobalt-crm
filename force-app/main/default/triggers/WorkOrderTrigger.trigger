trigger WorkOrderTrigger on Work_Order__c (
    after insert, after update
) {
    new WorkOrderTriggerHandler().run();
}
