@IsTest
private class CaseTriggerHandlerTest {

    private static Account createAccount() {
        Account acc = new Account(Name = 'CTH Test Account');
        insert acc;
        return acc;
    }

    private static Service_Contract__c createContract(Id accountId) {
        Service_Contract__c contract = new Service_Contract__c(Account__c = accountId);
        insert contract;
        return contract;
    }

    @IsTest
    static void testAfterUpdate_falseToTrueTransitionConvertsToWorkOrder() {
        Account acc = createAccount();
        Service_Contract__c contract = createContract(acc.Id);
        Case c = new Case(
            AccountId = acc.Id,
            Service_Contract__c = contract.Id,
            Case_Category__c = 'Equipment Failure',
            Priority = 'High',
            Subject = 'Elevator stuck',
            Requires_Field_Visit__c = false
        );
        insert c;

        Test.startTest();
        c.Requires_Field_Visit__c = true;
        update c;
        Test.stopTest();

        Case updated = [SELECT Status, Related_Work_Order__c FROM Case WHERE Id = :c.Id];
        System.assertNotEquals(null, updated.Related_Work_Order__c, 'false->true 전환 시 Work Order가 생성되어야 함');
        System.assertEquals('Waiting on Field Service', updated.Status);
    }

    @IsTest
    static void testAfterUpdate_trueToTrueDoesNotConvertAgain() {
        Account acc = createAccount();
        Service_Contract__c contract = createContract(acc.Id);
        Case c = new Case(
            AccountId = acc.Id,
            Service_Contract__c = contract.Id,
            Case_Category__c = 'Equipment Failure',
            Priority = 'High',
            Subject = 'Already flagged',
            Requires_Field_Visit__c = true
        );
        insert c;

        Test.startTest();
        c.Subject = 'Already flagged - updated subject only';
        update c;
        Test.stopTest();

        System.assertEquals(
            0, [SELECT COUNT() FROM Work_Order__c WHERE Service_Contract__c = :contract.Id],
            'Requires_Field_Visit__c가 이미 true였다면 다른 필드 변경만으로는 재전환되지 않아야 함'
        );
    }

    @IsTest
    static void testAfterUpdate_trueToFalseDoesNotConvert() {
        Account acc = createAccount();
        Service_Contract__c contract = createContract(acc.Id);
        Case c = new Case(
            AccountId = acc.Id,
            Service_Contract__c = contract.Id,
            Case_Category__c = 'Equipment Failure',
            Priority = 'High',
            Subject = 'Visit cancelled',
            Requires_Field_Visit__c = true
        );
        insert c;

        Test.startTest();
        c.Requires_Field_Visit__c = false;
        update c;
        Test.stopTest();

        System.assertEquals(
            0, [SELECT COUNT() FROM Work_Order__c WHERE Service_Contract__c = :contract.Id],
            'true->false 전환은 전환 대상이 아니어야 함'
        );
    }

    @IsTest
    static void testAfterUpdate_noContractLeavesCaseUnconverted() {
        Account acc = createAccount();
        Case c = new Case(
            AccountId = acc.Id,
            Case_Category__c = 'Equipment Failure',
            Priority = 'High',
            Subject = 'No contract on this case',
            Requires_Field_Visit__c = false
        );
        insert c;

        Test.startTest();
        c.Requires_Field_Visit__c = true;
        update c;
        Test.stopTest();

        Case updated = [SELECT Status, Related_Work_Order__c FROM Case WHERE Id = :c.Id];
        System.assertEquals(null, updated.Related_Work_Order__c);
        System.assertNotEquals('Waiting on Field Service', updated.Status);
    }
}
