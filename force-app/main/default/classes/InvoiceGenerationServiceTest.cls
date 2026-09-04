@IsTest
private class InvoiceGenerationServiceTest {

    // InvoiceGenerationService.generateInvoices()는 성공 시 결제 콜아웃을 1회 큐잉한다.
    // 이 클래스의 관심사는 인보이스 생성/금액 계산이므로, 재시도 체이닝(별도 클래스에서 검증)이
    // 테스트 컨텍스트의 "enqueueJob 총 1회" 한도에 걸리지 않도록 결제가 즉시 성공하는 Mock을 사용한다.
    private class SuccessPaymentMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"transactionId":"TXN-INVGEN-OK","status":"succeeded"}');
            return res;
        }
    }

    private static Account createAccount() {
        Account acc = new Account(Name = 'Invoice Gen Test Account');
        insert acc;
        return acc;
    }

    private static Service_Contract__c createContract(Id accountId) {
        Service_Contract__c contract = new Service_Contract__c(Account__c = accountId);
        insert contract;
        return contract;
    }

    private static Work_Order__c createWorkOrder(Id contractId, Decimal laborHours) {
        Work_Order__c wo = new Work_Order__c(
            Service_Contract__c = contractId,
            Status__c = 'On Site',
            Labor_Hours__c = laborHours
        );
        insert wo;
        return wo;
    }

    private static Part__c createPart(Decimal unitPrice) {
        Part__c part = new Part__c(
            Name = 'Invoice Gen Test Part',
            SKU__c = 'INVGEN-' + Datetime.now().getTime() + '-' + Math.round(Math.random() * 100000),
            Stock_Quantity__c = 1000,
            Unit_Price__c = unitPrice
        );
        insert part;
        return part;
    }

    @IsTest
    static void testGenerateInvoices_calculatesPartsAndLaborCorrectly() {
        Account acc = createAccount();
        Service_Contract__c contract = createContract(acc.Id);
        Work_Order__c wo = createWorkOrder(contract.Id, 4);
        Part__c part = createPart(50);
        insert new Part_Line__c(Work_Order__c = wo.Id, Part__c = part.Id, Quantity__c = 3, Unit_Price__c = 50);

        Test.setMock(HttpCalloutMock.class, new SuccessPaymentMock());
        Test.startTest();
        InvoiceGenerationService.generateInvoices(new Set<Id>{ wo.Id });
        Test.stopTest();

        Invoice__c invoice = [
            SELECT Work_Order__c, Account__c, Parts_Amount__c, Labor_Amount__c, Total_Amount__c,
                   Payment_Status__c, Idempotency_Key__c, Issued_Date__c
            FROM Invoice__c
            WHERE Work_Order__c = :wo.Id
        ];
        System.assertEquals(acc.Id, invoice.Account__c);
        System.assertEquals(150, invoice.Parts_Amount__c, '부품비 = 단가50 x 수량3 = 150');
        System.assertEquals(
            4 * InvoiceGenerationService.LABOR_HOURLY_RATE, invoice.Labor_Amount__c,
            '공임 = 작업시간4 x 시간당단가'
        );
        System.assertEquals(150 + (4 * InvoiceGenerationService.LABOR_HOURLY_RATE), invoice.Total_Amount__c);
        System.assertEquals('INV-' + wo.Id, invoice.Idempotency_Key__c);
        System.assertEquals(Date.today(), invoice.Issued_Date__c);
        System.assertEquals('Paid', invoice.Payment_Status__c, '결제 콜아웃이 성공했으므로 Paid로 갱신되어야 함');
    }

    @IsTest
    static void testGenerateInvoices_noPartsOrLaborDefaultsToZero() {
        Account acc = createAccount();
        Service_Contract__c contract = createContract(acc.Id);
        Work_Order__c wo = createWorkOrder(contract.Id, null);

        Test.setMock(HttpCalloutMock.class, new SuccessPaymentMock());
        Test.startTest();
        InvoiceGenerationService.generateInvoices(new Set<Id>{ wo.Id });
        Test.stopTest();

        Invoice__c invoice = [SELECT Parts_Amount__c, Labor_Amount__c FROM Invoice__c WHERE Work_Order__c = :wo.Id];
        System.assertEquals(0, invoice.Parts_Amount__c);
        System.assertEquals(0, invoice.Labor_Amount__c);
    }

    @IsTest
    static void testGenerateInvoices_doesNotDuplicateInvoiceForSameWorkOrder() {
        Account acc = createAccount();
        Service_Contract__c contract = createContract(acc.Id);
        Work_Order__c wo = createWorkOrder(contract.Id, 2);

        Test.setMock(HttpCalloutMock.class, new SuccessPaymentMock());
        Test.startTest();
        InvoiceGenerationService.generateInvoices(new Set<Id>{ wo.Id });
        InvoiceGenerationService.generateInvoices(new Set<Id>{ wo.Id });
        Test.stopTest();

        System.assertEquals(
            1, [SELECT COUNT() FROM Invoice__c WHERE Work_Order__c = :wo.Id],
            '같은 작업에 대해 인보이스가 중복 생성되지 않아야 함'
        );
    }

    @IsTest
    static void testGenerateInvoices_emptyOrNullSetDoesNothing() {
        Test.startTest();
        InvoiceGenerationService.generateInvoices(new Set<Id>());
        InvoiceGenerationService.generateInvoices(null);
        Test.stopTest();
        System.assert(true, '빈 집합/널 입력 시 예외 없이 종료되어야 함');
    }

    @IsTest
    static void testGenerateInvoices_bulkWorkOrdersStaysWithinLimits() {
        // 참고: 청구 건수를 PaymentCalloutQueueable.MAX_CALLOUTS_PER_EXECUTION(50) 이하로 잡는다.
        // 그 이상이면 결제 콜아웃이 여러 라운드로 이월되어 매 라운드 System.enqueueJob이 필요한데,
        // Apex 테스트 컨텍스트는 테스트 전체에서 enqueueJob을 총 1회까지만 허용하므로
        // (2회째부터 "Maximum stack depth" 예외) 벌크 인보이스 생성 자체의 SOQL/DML 안전성 검증이라는
        // 이 테스트의 목적에는 40건으로도 레코드 수 무관 상수 쿼리 여부를 충분히 증명할 수 있다.
        Account acc = createAccount();
        Service_Contract__c contract = createContract(acc.Id);

        List<Work_Order__c> orders = new List<Work_Order__c>();
        for (Integer i = 0; i < 40; i++) {
            orders.add(new Work_Order__c(
                Service_Contract__c = contract.Id,
                Status__c = 'On Site',
                Labor_Hours__c = 1
            ));
        }
        insert orders;

        Set<Id> orderIds = new Map<Id, Work_Order__c>(orders).keySet();

        Test.setMock(HttpCalloutMock.class, new SuccessPaymentMock());
        Integer queriesBefore = Limits.getQueries();
        Test.startTest();
        InvoiceGenerationService.generateInvoices(orderIds);
        Integer queriesAfter = Limits.getQueries();
        Test.stopTest();

        System.assert(
            (queriesAfter - queriesBefore) <= 5,
            '벌크 처리 시 레코드 수와 무관하게 SOQL 쿼리 수가 일정해야 함 (실제: ' + (queriesAfter - queriesBefore) + ')'
        );

        System.assertEquals(40, [SELECT COUNT() FROM Invoice__c WHERE Work_Order__c IN :orderIds]);
    }
}
