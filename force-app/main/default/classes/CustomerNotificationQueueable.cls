public with sharing class CustomerNotificationQueueable implements Queueable, Database.AllowsCallouts {

    public class NotificationPayload {
        public Id workOrderId;
        public String recipientEmail;
        public String recipientPhone;
        public String message;
    }

    private static final String NAMED_CREDENTIAL = 'Cobalt_Messaging_API';

    private final List<NotificationPayload> payloads;

    public CustomerNotificationQueueable(List<NotificationPayload> payloads) {
        this.payloads = payloads;
    }

    public void execute(QueueableContext context) {
        List<Integration_Log__c> logs = new List<Integration_Log__c>();

        for (NotificationPayload payload : payloads) {
            logs.add(sendOne(payload));
        }

        if (!logs.isEmpty()) {
            insert logs;
        }
    }

    private static Integration_Log__c sendOne(NotificationPayload payload) {
        Long startTime = Datetime.now().getTime();
        // TODO: Cobalt Messaging 벤더 계약이 확정되면 실제 엔드포인트 경로/요청 스키마로 교체.
        // Named Credential 'Cobalt_Messaging_API'가 Setup에 구성되어 있어야 이 콜아웃이 정상 동작함.
        String endpoint = 'callout:' + NAMED_CREDENTIAL + '/messages';
        String requestBody = JSON.serialize(new Map<String, Object>{
            'to' => String.isNotBlank(payload.recipientEmail) ? payload.recipientEmail : payload.recipientPhone,
            'message' => payload.message
        });

        Integration_Log__c log = new Integration_Log__c(
            Integration_Type__c = 'Messaging',
            Related_Record_Id__c = payload.workOrderId,
            Endpoint__c = endpoint,
            Request_Body__c = requestBody,
            Is_Success__c = false
        );

        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setBody(requestBody);
            req.setTimeout(10000);
            Http http = new Http();
            HttpResponse res = http.send(req);

            log.Status_Code__c = res.getStatusCode();
            log.Response_Body__c = res.getBody();
            log.Is_Success__c = res.getStatusCode() == 200 || res.getStatusCode() == 201;
            if (!log.Is_Success__c) {
                log.Error_Message__c = '메시징 API가 실패 상태 코드를 반환했습니다: ' + res.getStatusCode();
            }
        } catch (Exception ex) {
            // Named Credential 미구성 또는 실제 메시징 API 엔드포인트 연결 실패.
            log.Error_Message__c = ex.getMessage();
        }

        log.Duration_Ms__c = Datetime.now().getTime() - startTime;
        return log;
    }
}
