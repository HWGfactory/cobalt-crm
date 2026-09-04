@IsTest
private class CaseEntitlementServiceTest {

    private static Account createAccount(String name) {
        Account acc = new Account(Name = name);
        insert acc;
        return acc;
    }

    private static Service_Contract__c createContract(Id accountId, String tier) {
        Service_Contract__c contract = new Service_Contract__c(Account__c = accountId, Tier__c = tier);
        insert contract;
        return contract;
    }

    private static Case createCase(Id accountId, Id contractId) {
        return new Case(
            AccountId = accountId,
            Service_Contract__c = contractId,
            Subject = 'CES Test Case'
        );
    }

    @IsTest
    static void testAssign_enterpriseTierLinksEnterpriseEntitlement() {
        Account acc = createAccount('CES Enterprise Account');
        Service_Contract__c contract = createContract(acc.Id, 'Enterprise');
        Case c = createCase(acc.Id, contract.Id);

        Test.startTest();
        insert c; // CaseTrigger의 afterInsert가 CaseEntitlementService를 자동 호출
        Test.stopTest();

        Case result = [SELECT EntitlementId, Entitlement.Name, Entitlement.SlaProcess.Name FROM Case WHERE Id = :c.Id];
        System.assertNotEquals(null, result.EntitlementId);
        System.assertEquals('Cobalt Enterprise SLA', result.Entitlement.SlaProcess.Name);
    }

    @IsTest
    static void testAssign_proTierLinksProEntitlement() {
        Account acc = createAccount('CES Pro Account');
        Service_Contract__c contract = createContract(acc.Id, 'Pro');
        Case c = createCase(acc.Id, contract.Id);

        Test.startTest();
        insert c;
        Test.stopTest();

        Case result = [SELECT Entitlement.SlaProcess.Name FROM Case WHERE Id = :c.Id];
        System.assertEquals('Cobalt Pro SLA', result.Entitlement.SlaProcess.Name);
    }

    @IsTest
    static void testAssign_starterTierLinksStarterEntitlement() {
        Account acc = createAccount('CES Starter Account');
        Service_Contract__c contract = createContract(acc.Id, 'Starter');
        Case c = createCase(acc.Id, contract.Id);

        Test.startTest();
        insert c;
        Test.stopTest();

        Case result = [SELECT Entitlement.SlaProcess.Name FROM Case WHERE Id = :c.Id];
        System.assertEquals('Cobalt Starter SLA', result.Entitlement.SlaProcess.Name);
    }

    @IsTest
    static void testAssign_secondCaseOnSameAccountAndTierReusesEntitlement() {
        Account acc = createAccount('CES Reuse Account');
        Service_Contract__c contract = createContract(acc.Id, 'Pro');
        Case c1 = createCase(acc.Id, contract.Id);
        insert c1;

        Case c2 = createCase(acc.Id, contract.Id);
        Test.startTest();
        insert c2;
        Test.stopTest();

        Case result1 = [SELECT EntitlementId FROM Case WHERE Id = :c1.Id];
        Case result2 = [SELECT EntitlementId FROM Case WHERE Id = :c2.Id];
        System.assertEquals(
            result1.EntitlementId, result2.EntitlementId,
            '같은 계정, 같은 등급이면 Entitlement 레코드를 재사용해야 함(중복 생성 금지)'
        );
        System.assertEquals(
            1, [SELECT COUNT() FROM Entitlement WHERE AccountId = :acc.Id],
            'Entitlement은 계정+등급 조합당 하나만 존재해야 함'
        );
    }

    @IsTest
    static void testAssign_differentTiersOnSameAccountGetSeparateEntitlements() {
        Account acc = createAccount('CES Multi Tier Account');
        Service_Contract__c proContract = createContract(acc.Id, 'Pro');
        Service_Contract__c enterpriseContract = createContract(acc.Id, 'Enterprise');

        Case proCase = createCase(acc.Id, proContract.Id);
        Case enterpriseCase = createCase(acc.Id, enterpriseContract.Id);

        Test.startTest();
        insert new List<Case>{ proCase, enterpriseCase };
        Test.stopTest();

        Case proResult = [SELECT EntitlementId FROM Case WHERE Id = :proCase.Id];
        Case entResult = [SELECT EntitlementId FROM Case WHERE Id = :enterpriseCase.Id];
        System.assertNotEquals(
            proResult.EntitlementId, entResult.EntitlementId,
            '같은 계정이라도 등급이 다르면 서로 다른 Entitlement를 써야 함'
        );
    }

    @IsTest
    static void testAssign_caseWithoutContractIsSkipped() {
        Account acc = createAccount('CES No Contract Account');
        Case c = new Case(AccountId = acc.Id, Subject = 'No contract');

        Test.startTest();
        insert c;
        Test.stopTest();

        Case result = [SELECT EntitlementId FROM Case WHERE Id = :c.Id];
        System.assertEquals(null, result.EntitlementId);
    }

    @IsTest
    static void testAssign_unknownTierIsSkipped() {
        Account acc = createAccount('CES Unknown Tier Account');
        Service_Contract__c contract = new Service_Contract__c(Account__c = acc.Id); // Tier__c 미지정
        insert contract;
        Case c = createCase(acc.Id, contract.Id);

        Test.startTest();
        insert c;
        Test.stopTest();

        Case result = [SELECT EntitlementId FROM Case WHERE Id = :c.Id];
        System.assertEquals(null, result.EntitlementId);
    }

    @IsTest
    static void testAssign_emptyOrNullSetDoesNothing() {
        Test.startTest();
        CaseEntitlementService.assignEntitlements(new Set<Id>());
        CaseEntitlementService.assignEntitlements(null);
        Test.stopTest();
        System.assert(true, '빈 집합/널 입력 시 예외 없이 종료되어야 함');
    }
}
