// [하이브리드 설계 결정 로그]
// WorkOrder_Status_Notification 레코드-트리거 Flow는 "언제/어떤 상태 변경에 알릴지"를
// 선언적으로 표현하고(비개발 담당자가 Flow Builder에서 조건을 읽고 조정 가능),
// 실제 외부 발송(콜아웃)은 이 Apex 액션으로 위임한다. 이유:
//   1) 콜아웃은 Named Credential 인증, 비동기 Queueable 처리, 실패 재시도/로깅 같은
//      Flow의 선언형 액션만으로는 조합하기 어려운 견고성 요구사항을 갖는다.
//   2) 발송 로직을 Apex로 격리하면 HttpCalloutMock 기반 단위 테스트로 회귀를 방지할 수 있다.
//   3) 메시지 문안이나 재시도 정책이 바뀌어도 Flow 재배포 없이 이 클래스만 수정하면 된다.
public with sharing class SendCustomerNotification {

    public class NotificationRequest {
        @InvocableVariable(required=true label='Work Order Id' description='알림을 보낼 Work Order의 Id')
        public Id workOrderId;

        @InvocableVariable(
            label='Override Message'
            description='설정하면 상태 기반 기본 문안 대신 이 문구를 그대로 사용합니다(예: 날씨로 인한 재조정 안내).'
        )
        public String overrideMessage;

        @InvocableVariable(
            label='Notify Technician Too'
            description='true면 고객뿐 아니라 배정된 기술자에게도 같은 메시지를 함께 발송합니다.'
        )
        public Boolean notifyTechnicianToo;
    }

    public class NotificationResult {
        @InvocableVariable(label='Queued')
        public Boolean queued;

        @InvocableVariable(label='Message')
        public String message;
    }

    @InvocableMethod(
        label='Send Customer Notification'
        description='작업 상태(En Route/On Site/Completed)에 맞는 문안을 만들어 고객에게 알림 발송을 큐잉합니다.'
        category='Work Order'
    )
    public static List<NotificationResult> sendNotifications(List<NotificationRequest> requests) {
        List<NotificationResult> results = new List<NotificationResult>();
        if (requests == null || requests.isEmpty()) {
            return results;
        }

        Set<Id> workOrderIds = new Set<Id>();
        for (NotificationRequest request : requests) {
            if (request.workOrderId != null) {
                workOrderIds.add(request.workOrderId);
            }
        }

        Map<Id, Work_Order__c> workOrdersById = workOrderIds.isEmpty()
            ? new Map<Id, Work_Order__c>()
            : new Map<Id, Work_Order__c>([
                SELECT Id, Status__c, ETA__c, Service_Contract__r.Account__c,
                       Assigned_Technician__c, Assigned_Technician__r.Phone__c, Assigned_Technician__r.User__r.Email
                FROM Work_Order__c
                WHERE Id IN :workOrderIds
                WITH USER_MODE
            ]);

        Set<Id> accountIds = new Set<Id>();
        for (Work_Order__c wo : workOrdersById.values()) {
            if (wo.Service_Contract__r != null && wo.Service_Contract__r.Account__c != null) {
                accountIds.add(wo.Service_Contract__r.Account__c);
            }
        }

        // 이 스키마에는 "주 담당자(Primary Contact)" 필드가 없어, 고객사에 연결된 첫 Contact를
        // 알림 수신자로 사용한다(설계상 가정 - 향후 전용 필드가 생기면 대체 가능).
        Map<Id, Contact> primaryContactByAccountId = new Map<Id, Contact>();
        if (!accountIds.isEmpty()) {
            for (Contact con : [
                SELECT Id, AccountId, Email, Phone
                FROM Contact
                WHERE AccountId IN :accountIds
                WITH USER_MODE
                ORDER BY CreatedDate ASC
            ]) {
                if (!primaryContactByAccountId.containsKey(con.AccountId)) {
                    primaryContactByAccountId.put(con.AccountId, con);
                }
            }
        }

        List<CustomerNotificationQueueable.NotificationPayload> payloads =
            new List<CustomerNotificationQueueable.NotificationPayload>();

        for (NotificationRequest request : requests) {
            NotificationResult result = new NotificationResult();
            Work_Order__c wo = request.workOrderId != null ? workOrdersById.get(request.workOrderId) : null;

            if (wo == null) {
                result.queued = false;
                result.message = '작업(Work_Order__c)을 찾을 수 없습니다.';
                results.add(result);
                continue;
            }

            String messageText = String.isNotBlank(request.overrideMessage)
                ? request.overrideMessage
                : buildMessage(wo);
            if (messageText == null) {
                result.queued = false;
                result.message = '알림 대상 상태가 아닙니다: ' + wo.Status__c;
                results.add(result);
                continue;
            }

            Id accountId = wo.Service_Contract__r != null ? wo.Service_Contract__r.Account__c : null;
            Contact contact = accountId != null ? primaryContactByAccountId.get(accountId) : null;
            Boolean hasCustomerContact = contact != null
                && (String.isNotBlank(contact.Email) || String.isNotBlank(contact.Phone));

            Boolean wantsTechnician = request.notifyTechnicianToo == true && wo.Assigned_Technician__c != null;
            String technicianEmail = wantsTechnician && wo.Assigned_Technician__r != null
                ? (wo.Assigned_Technician__r.User__r != null ? wo.Assigned_Technician__r.User__r.Email : null)
                : null;
            String technicianPhone = wantsTechnician && wo.Assigned_Technician__r != null
                ? wo.Assigned_Technician__r.Phone__c
                : null;
            Boolean hasTechnicianContact = String.isNotBlank(technicianEmail) || String.isNotBlank(technicianPhone);

            if (!hasCustomerContact && !hasTechnicianContact) {
                result.queued = false;
                result.message = '고객/기술자 연락처를 찾을 수 없습니다.';
                results.add(result);
                continue;
            }

            if (hasCustomerContact) {
                CustomerNotificationQueueable.NotificationPayload payload =
                    new CustomerNotificationQueueable.NotificationPayload();
                payload.workOrderId = wo.Id;
                payload.recipientEmail = contact.Email;
                payload.recipientPhone = contact.Phone;
                payload.message = messageText;
                payloads.add(payload);
            }

            if (hasTechnicianContact) {
                CustomerNotificationQueueable.NotificationPayload technicianPayload =
                    new CustomerNotificationQueueable.NotificationPayload();
                technicianPayload.workOrderId = wo.Id;
                technicianPayload.recipientEmail = technicianEmail;
                technicianPayload.recipientPhone = technicianPhone;
                technicianPayload.message = messageText;
                payloads.add(technicianPayload);
            }

            result.queued = true;
            result.message = '알림이 발송 대기열에 추가되었습니다.';
            results.add(result);
        }

        if (!payloads.isEmpty()) {
            System.enqueueJob(new CustomerNotificationQueueable(payloads));
        }

        return results;
    }

    private static String buildMessage(Work_Order__c wo) {
        if (wo.Status__c == 'En Route') {
            // 고객에게 노출되는 시각이므로 실행 사용자 시간대 기준으로 표기한다(고객별 시간대 데이터는 없음).
            String etaLabel = wo.ETA__c != null ? wo.ETA__c.format('HH:mm') : '확인 중';
            return '기술자가 이동 중입니다. ETA ' + etaLabel;
        }
        if (wo.Status__c == 'On Site') {
            return '기술자가 도착했습니다.';
        }
        if (wo.Status__c == 'Completed') {
            return '작업이 완료되었습니다.';
        }
        return null;
    }
}
