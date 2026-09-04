trigger PartLineTrigger on Part_Line__c (after insert) {
    new PartLineTriggerHandler().run();
}
