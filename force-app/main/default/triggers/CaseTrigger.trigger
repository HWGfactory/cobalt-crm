trigger CaseTrigger on Case (after insert, after update) {
    new CaseTriggerHandler().run();
}
