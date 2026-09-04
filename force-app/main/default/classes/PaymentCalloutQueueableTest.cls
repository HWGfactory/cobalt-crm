@IsTest
private class PaymentCalloutQueueableTest {

    private class SuccessPaymentMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"transactionId":"TXN-SUCCESS-001","status":"succeeded"}');
            return res;
        }
    }

    private class AlwaysFailPaymentMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(503);
            res.setBody('{"error":"Service Unavailable"}');
            return res;
        }
    }

    // 1번째 호출은 실패, 2번째 호출부터는 성공 - 재시도 후 회복되는 시나리오용.
    private class EventuallySucceedsPaymentMock implements HttpCalloutMock {
        Integer callCount = 0;
        Integer failuresBeforeSuccess;
        EventuallySucceedsPaymentMock(Integer failuresBeforeSuccess) {
            this.failuresBeforeSuccess = failuresBeforeSuccess;
        }
        public HttpResponse respond(HttpRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            if (callCount <= failuresBeforeSuccess) {
                res.setStatusCode(503);
                res.setBody('{"error":"Service Unavailable"}');
            } else {
                res.setStatusCode(200);
                res.setBody('{"transactionId":"TXN-RETRY-OK","status":"succeeded"}');
            }
            return res;
        }
    }

    private class HeaderCapturingMock implements HttpCalloutMock {
        public List<String> capturedIdempotencyKeys = new List<String>();
        public HttpResponse respond(HttpRequest req) {
            capturedIdempotencyKeys.add(req.getHeader('Idempotency-Key'));
            HttpResponse res = new HttpResponse();
            res.setStatusCode(503);
            res.setBody('{"error":"Service Unavailable"}');
            return res;
        }
    }

    private static Work_Order__c createWorkOrder() {
        Account acc = new Account(Name = 'Payment Test Account');
        insert acc;
        Service_Contract__c contract = new Service_Contract__c(Account__c = acc.Id);
        insert contract;
        Work_Order__c wo = new Work_Order__c(Service_Contract__c = contract.Id, Status__c = 'On Site');
        insert wo;
        return wo;
    }

    private static Invoice__c createInvoice(Id workOrderId, Decimal amount, String idempotencyKey) {
        Invoice__c inv = new Invoice__c(
            Work_Order__c = workOrderId,
            Parts_Amount__c = amount,
            Labor_Amount__c = 0,
            Payment_Status__c = 'Pending',
            Idempotency_Key__c = idempotencyKey
        );
        insert inv;
        return inv;
    }

    private static PaymentCalloutQueueable.PaymentRequest buildRequest(
        Id invoiceId, Decimal amount, String idempotencyKey, Integer retryCount
    ) {
        PaymentCalloutQueueable.PaymentRequest req = new PaymentCalloutQueueable.PaymentRequest();
        req.invoiceId = invoiceId;
        req.amount = amount;
        req.idempotencyKey = idempotencyKey;
        req.retryCount = retryCount;
        return req;
    }

    @IsTest
    static void testExecute_successfulPaymentMarksInvoicePaid() {
        Work_Order__c wo = createWorkOrder();
        Invoice__c inv = createInvoice(wo.Id, 100, 'IDEM-SUCCESS-001');
        Test.setMock(HttpCalloutMock.class, new SuccessPaymentMock());

        Test.startTest();
        System.enqueueJob(new PaymentCalloutQueueable(new List<PaymentCalloutQueueable.PaymentRequest>{
            buildRequest(inv.Id, 100, inv.Idempotency_Key__c, 0)
        }));
        Test.stopTest();

        Invoice__c updated = [SELECT Payment_Status__c, Payment_Reference__c FROM Invoice__c WHERE Id = :inv.Id];
        System.assertEquals('Paid', updated.Payment_Status__c);
        System.assertEquals('TXN-SUCCESS-001', updated.Payment_Reference__c);

        List<Integration_Log__c> logs = [
            SELECT Is_Success__c, Integration_Type__c FROM Integration_Log__c WHERE Related_Record_Id__c = :inv.Id
        ];
        System.assertEquals(1, logs.size(), '성공 시 1회 시도만 기록되어야 함');
        System.assertEquals(true, logs[0].Is_Success__c);
        System.assertEquals('Payment', logs[0].Integration_Type__c);
    }

    // 참고: Apex 테스트 컨텍스트는 테스트 메서드 전체에서 System.enqueueJob 호출을 통틀어 1회로 제한한다
    // (체이닝된/직접 호출된 execute() 내부에서 또 enqueueJob을 호출하면 "Maximum stack depth" 예외 발생).
    // 그래서 재시도 로직의 두 경계 조건(재시도 후 회복 / 재시도 소진 후 확정)만 검증하고,
    // "재시도가 큐잉된 직후의 중간 상태"는 아래 두 테스트가 실질적으로 함께 증명하므로 별도 테스트를 두지 않는다.

    @IsTest
    static void testExecute_failureAtMaxRetryCountMarksFailedWithoutFurtherRetry() {
        Work_Order__c wo = createWorkOrder();
        Invoice__c inv = createInvoice(wo.Id, 200, 'IDEM-RETRY-EXHAUSTED-001');
        Test.setMock(HttpCalloutMock.class, new AlwaysFailPaymentMock());

        Test.startTest();
        // 이미 최대 재시도 횟수(MAX_RETRY_COUNT)에 도달한 요청을 직접 실행 -
        // 실패해도 더 이상 재시도를 큐잉하지 않고 즉시 Failed로 확정되어야 한다.
        new PaymentCalloutQueueable(new List<PaymentCalloutQueueable.PaymentRequest>{
            buildRequest(inv.Id, 200, inv.Idempotency_Key__c, PaymentCalloutQueueable.MAX_RETRY_COUNT)
        }).execute(null);
        Test.stopTest();

        Invoice__c updated = [SELECT Payment_Status__c FROM Invoice__c WHERE Id = :inv.Id];
        System.assertEquals('Failed', updated.Payment_Status__c, '최대 재시도 횟수에서도 실패하면 Failed로 확정되어야 함');
        System.assertEquals(1, [SELECT COUNT() FROM Integration_Log__c WHERE Related_Record_Id__c = :inv.Id]);
    }

    @IsTest
    static void testExecute_transientFailureRetriesThenSucceeds() {
        Work_Order__c wo = createWorkOrder();
        Invoice__c inv = createInvoice(wo.Id, 150, 'IDEM-RETRY-OK-001');
        // 1번째 호출(최초 시도)은 실패, 2번째 호출(재시도)부터 성공.
        Test.setMock(HttpCalloutMock.class, new EventuallySucceedsPaymentMock(1));

        Test.startTest();
        // 최초 시도(retryCount=0)를 직접 실행 → 실패 → retryCount=1 재시도를 1회 enqueueJob(테스트 한도 이내).
        new PaymentCalloutQueueable(new List<PaymentCalloutQueueable.PaymentRequest>{
            buildRequest(inv.Id, 150, inv.Idempotency_Key__c, 0)
        }).execute(null);
        Test.stopTest(); // 큐잉된 retryCount=1 재시도가 실제로 비동기 실행되며, 이번엔 성공해 Paid로 마감된다.

        Invoice__c updated = [SELECT Payment_Status__c, Payment_Reference__c FROM Invoice__c WHERE Id = :inv.Id];
        System.assertEquals('Paid', updated.Payment_Status__c, '재시도에서 성공하면 최종적으로 Paid여야 함');
        System.assertEquals('TXN-RETRY-OK', updated.Payment_Reference__c);

        System.assertEquals(
            2, [SELECT COUNT() FROM Integration_Log__c WHERE Related_Record_Id__c = :inv.Id],
            '실패 1회 + 성공 1회 = 총 2회 기록되어야 함'
        );
    }

    @IsTest
    static void testExecute_idempotencyKeySentConsistentlyAcrossRetry() {
        Work_Order__c wo = createWorkOrder();
        Invoice__c inv = createInvoice(wo.Id, 80, 'IDEM-HEADER-CHECK-001');
        HeaderCapturingMock mock = new HeaderCapturingMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        // retryCount를 MAX_RETRY_COUNT-1에서 시작시켜, 이번 시도의 재시도가 MAX_RETRY_COUNT에 정확히
        // 도달해 더 이상 enqueueJob을 호출하지 않고 종료되도록 한다(테스트 컨텍스트의 enqueueJob 1회 한도 준수).
        new PaymentCalloutQueueable(new List<PaymentCalloutQueueable.PaymentRequest>{
            buildRequest(inv.Id, 80, inv.Idempotency_Key__c, PaymentCalloutQueueable.MAX_RETRY_COUNT - 1)
        }).execute(null);
        Test.stopTest();

        System.assertEquals(2, mock.capturedIdempotencyKeys.size(), '최초 시도 + 재시도 1회 = 총 2회 호출');
        for (String key : mock.capturedIdempotencyKeys) {
            System.assertEquals(
                'IDEM-HEADER-CHECK-001', key,
                '재시도 시에도 항상 동일한 멱등키가 전송되어야 함'
            );
        }
    }

    @IsTest
    static void testExecute_bulkMultipleInvoicesInSingleJobProcessedIndependently() {
        Work_Order__c wo1 = createWorkOrder();
        Work_Order__c wo2 = createWorkOrder();
        Invoice__c inv1 = createInvoice(wo1.Id, 10, 'IDEM-BULK-1');
        Invoice__c inv2 = createInvoice(wo2.Id, 20, 'IDEM-BULK-2');
        Test.setMock(HttpCalloutMock.class, new SuccessPaymentMock());

        Test.startTest();
        System.enqueueJob(new PaymentCalloutQueueable(new List<PaymentCalloutQueueable.PaymentRequest>{
            buildRequest(inv1.Id, 10, inv1.Idempotency_Key__c, 0),
            buildRequest(inv2.Id, 20, inv2.Idempotency_Key__c, 0)
        }));
        Test.stopTest();

        for (Invoice__c inv : [SELECT Payment_Status__c FROM Invoice__c WHERE Id IN (:inv1.Id, :inv2.Id)]) {
            System.assertEquals('Paid', inv.Payment_Status__c);
        }
    }

    @IsTest
    static void testIdempotencyKeyUniqueConstraintBlocksDuplicateInvoice() {
        Work_Order__c wo = createWorkOrder();
        createInvoice(wo.Id, 50, 'INV-' + wo.Id);

        Invoice__c duplicate = new Invoice__c(
            Work_Order__c = wo.Id,
            Parts_Amount__c = 50,
            Payment_Status__c = 'Pending',
            Idempotency_Key__c = 'INV-' + wo.Id
        );

        Boolean threw = false;
        Test.startTest();
        try {
            insert duplicate;
        } catch (DmlException ex) {
            threw = true;
            System.assert(
                ex.getMessage().toLowerCase().contains('duplicate') || ex.getMessage().toLowerCase().contains('unique'),
                'Idempotency_Key__c Unique 제약 위반 메시지여야 함: ' + ex.getMessage()
            );
        }
        Test.stopTest();

        System.assert(threw, '동일 멱등키로 두 번째 Invoice를 생성하려 하면 Unique 제약으로 실패해야 함');
    }
}
