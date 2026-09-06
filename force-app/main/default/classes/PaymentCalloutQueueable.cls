public with sharing class PaymentCalloutQueueable implements Queueable, Database.AllowsCallouts {

    public class PaymentRequest {
        public Id invoiceId;
        public Decimal amount;
        public String idempotencyKey;
        public Integer retryCount;
    }

    private class AttemptOutcome {
        Boolean isPaid;
        String paymentReference;
    }

    private static final String NAMED_CREDENTIAL = 'Cobalt_Payment_API';
    // 결제 API 재시도 최대 횟수. 벤더 SLA에 맞춰 조정할 값이라 상수로 유지 중이다.
    @TestVisible private static final Integer MAX_RETRY_COUNT = 3;
    // Salesforce 콜아웃 한도(트랜잭션당 100회)에 안전 마진을 두고 청구 요청을 배치로 나눠 처리한다.
    @TestVisible private static final Integer MAX_CALLOUTS_PER_EXECUTION = 50;

    private final List<PaymentRequest> requests;

    public PaymentCalloutQueueable(List<PaymentRequest> requests) {
        this.requests = requests;
    }

    public void execute(QueueableContext context) {
        List<PaymentRequest> currentBatch = requests;
        List<PaymentRequest> nextRoundRequests = new List<PaymentRequest>();

        if (requests.size() > MAX_CALLOUTS_PER_EXECUTION) {
            currentBatch = new List<PaymentRequest>();
            for (Integer i = 0; i < requests.size(); i++) {
                if (i < MAX_CALLOUTS_PER_EXECUTION) {
                    currentBatch.add(requests[i]);
                } else {
                    // 이번 실행에서 처리하지 못한 나머지는 다음 배치로 이월(아래에서 재시도 요청과 합쳐 1회만 enqueue).
                    nextRoundRequests.add(requests[i]);
                }
            }
        }

        List<Invoice__c> updates = new List<Invoice__c>();
        List<Integration_Log__c> pendingLogs = new List<Integration_Log__c>();

        for (PaymentRequest req : currentBatch) {
            AttemptOutcome outcome = attemptPayment(req, pendingLogs);

            if (outcome.isPaid) {
                updates.add(new Invoice__c(
                    Id = req.invoiceId,
                    Payment_Status__c = 'Paid',
                    Payment_Reference__c = outcome.paymentReference
                ));
            } else if (req.retryCount < MAX_RETRY_COUNT) {
                PaymentRequest retry = new PaymentRequest();
                retry.invoiceId = req.invoiceId;
                retry.amount = req.amount;
                retry.idempotencyKey = req.idempotencyKey;
                retry.retryCount = req.retryCount + 1;
                nextRoundRequests.add(retry);
            } else {
                // 최대 재시도 횟수를 모두 소진 - 영구 실패로 확정.
                updates.add(new Invoice__c(
                    Id = req.invoiceId,
                    Payment_Status__c = 'Failed'
                ));
            }
        }

        if (!pendingLogs.isEmpty()) {
            insert pendingLogs;
        }
        if (!updates.isEmpty()) {
            update updates;
        }
        if (!nextRoundRequests.isEmpty()) {
            // Queueable execute() 1회당 enqueueJob은 1회만 허용되므로, 배치 이월분과 재시도분을
            // 합쳐서 단 한 번의 System.enqueueJob 호출로 다음 실행을 예약한다.
            System.enqueueJob(new PaymentCalloutQueueable(nextRoundRequests));
        }
    }

    private static AttemptOutcome attemptPayment(PaymentRequest req, List<Integration_Log__c> pendingLogs) {
        Long startTime = Datetime.now().getTime();
        // TODO: Cobalt_Payment_API 벤더 계약이 확정되면 실제 엔드포인트 경로/요청·응답 스키마로 교체.
        // Named Credential 'Cobalt_Payment_API'가 Setup에 구성되어 있어야 이 콜아웃이 정상 동작함.
        String endpoint = 'callout:' + NAMED_CREDENTIAL + '/charges';
        String requestBody = JSON.serialize(new Map<String, Object>{
            'invoiceId' => req.invoiceId,
            'amount' => req.amount,
            'idempotencyKey' => req.idempotencyKey
        });

        AttemptOutcome outcome = new AttemptOutcome();
        outcome.isPaid = false;

        HttpResponse res;
        Exception calloutFailure;
        try {
            HttpRequest httpReq = new HttpRequest();
            httpReq.setEndpoint(endpoint);
            httpReq.setMethod('POST');
            httpReq.setHeader('Content-Type', 'application/json');
            // 멱등키: 같은 청구 시도(Invoice__c)에 대해 재시도 전 구간에서 항상 동일한 값을 전송해
            // 결제 게이트웨이가 네트워크 재시도로 인한 중복 청구를 스스로 걸러내도록 한다.
            httpReq.setHeader('Idempotency-Key', req.idempotencyKey);
            httpReq.setBody(requestBody);
            httpReq.setTimeout(10000);
            Http http = new Http();
            res = http.send(httpReq);
        } catch (Exception ex) {
            calloutFailure = ex;
        }

        Long durationMs = Datetime.now().getTime() - startTime;

        if (calloutFailure != null) {
            pendingLogs.add(buildLog(endpoint, req, null, null, false, calloutFailure.getMessage(), durationMs));
            return outcome;
        }

        Boolean isHttpSuccess = res.getStatusCode() == 200 || res.getStatusCode() == 201;
        String errorMessage;
        String paymentReference;

        if (isHttpSuccess) {
            try {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                paymentReference = parsed.containsKey('transactionId') ? String.valueOf(parsed.get('transactionId')) : null;
                outcome.isPaid = true;
            } catch (Exception parseEx) {
                isHttpSuccess = false;
                errorMessage = '응답 파싱 실패: ' + parseEx.getMessage();
            }
        } else {
            errorMessage = '결제 게이트웨이가 실패 상태 코드를 반환했습니다: ' + res.getStatusCode();
        }

        pendingLogs.add(buildLog(endpoint, req, res.getStatusCode(), res.getBody(), isHttpSuccess, errorMessage, durationMs));
        outcome.paymentReference = paymentReference;
        return outcome;
    }

    private static Integration_Log__c buildLog(
        String endpoint, PaymentRequest req, Integer statusCode, String responseBody,
        Boolean isSuccess, String errorMessage, Long durationMs
    ) {
        return new Integration_Log__c(
            Integration_Type__c = 'Payment',
            Related_Record_Id__c = req.invoiceId,
            Endpoint__c = endpoint,
            Response_Body__c = responseBody,
            Status_Code__c = statusCode,
            Is_Success__c = isSuccess,
            Error_Message__c = errorMessage,
            Duration_Ms__c = durationMs
        );
    }
}
