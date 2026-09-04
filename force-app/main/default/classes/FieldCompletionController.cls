public with sharing class FieldCompletionController {

    @TestVisible
    private static final List<String> REQUIRED_CHECKLIST_ITEMS = new List<String>{
        '작업 내용을 고객에게 설명함',
        '사용된 부품을 기록함',
        '작업 현장을 정리함',
        '고객이 결과에 만족함을 확인함'
    };

    @AuraEnabled(cacheable=true)
    public static WorkOrderSummary getWorkOrderSummary(Id workOrderId) {
        if (workOrderId == null) {
            throw new AuraHandledException('작업 Id가 필요합니다.');
        }

        List<Work_Order__c> workOrders = [
            SELECT Id, Name, Service_Address__c, Service_Contract__r.Account__r.Name
            FROM Work_Order__c
            WHERE Id = :workOrderId
            WITH USER_MODE
            LIMIT 1
        ];
        if (workOrders.isEmpty()) {
            throw new AuraHandledException('작업을 찾을 수 없습니다.');
        }

        Work_Order__c wo = workOrders[0];
        WorkOrderSummary summary = new WorkOrderSummary();
        summary.workOrderNumber = wo.Name;
        summary.serviceAddress = wo.Service_Address__c;
        summary.customerName = (wo.Service_Contract__r != null && wo.Service_Contract__r.Account__r != null)
            ? wo.Service_Contract__r.Account__r.Name
            : null;
        return summary;
    }

    @AuraEnabled
    public static void saveSignature(Id workOrderId, String base64Data) {
        if (workOrderId == null || String.isBlank(base64Data)) {
            throw new AuraHandledException('작업과 서명 데이터가 모두 필요합니다.');
        }

        List<Work_Order__c> workOrders = [
            SELECT Id, Name FROM Work_Order__c WHERE Id = :workOrderId WITH USER_MODE LIMIT 1
        ];
        if (workOrders.isEmpty()) {
            throw new AuraHandledException('작업을 찾을 수 없습니다.');
        }

        String cleanBase64 = base64Data.contains(',') ? base64Data.substringAfter(',') : base64Data;
        Blob signatureBlob;
        try {
            signatureBlob = EncodingUtil.base64Decode(cleanBase64);
        } catch (Exception ex) {
            throw new AuraHandledException('서명 데이터를 디코딩할 수 없습니다.');
        }

        ContentVersion cv = new ContentVersion(
            Title = 'Signature_' + workOrders[0].Name,
            PathOnClient = 'Signature_' + workOrders[0].Name + '.png',
            VersionData = signatureBlob,
            ContentLocation = 'S'
        );

        try {
            insert cv;
        } catch (DmlException ex) {
            throw new AuraHandledException('서명 파일 저장 중 오류가 발생했습니다: ' + ex.getMessage());
        }

        ContentVersion insertedVersion = [
            SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id WITH USER_MODE LIMIT 1
        ];

        ContentDocumentLink link = new ContentDocumentLink(
            ContentDocumentId = insertedVersion.ContentDocumentId,
            LinkedEntityId = workOrderId,
            ShareType = 'V',
            Visibility = 'AllUsers'
        );

        try {
            insert link;
        } catch (DmlException ex) {
            throw new AuraHandledException('서명 파일을 작업에 연결하는 중 오류가 발생했습니다: ' + ex.getMessage());
        }
    }

    @AuraEnabled
    public static void completeWorkOrder(Id workOrderId, List<String> checklist) {
        if (workOrderId == null) {
            throw new AuraHandledException('작업 Id가 필요합니다.');
        }

        Set<String> completedItems = checklist == null ? new Set<String>() : new Set<String>(checklist);
        for (String requiredItem : REQUIRED_CHECKLIST_ITEMS) {
            if (!completedItems.contains(requiredItem)) {
                throw new AuraHandledException(
                    '완료 체크리스트를 모두 확인해야 작업을 완료할 수 있습니다: ' + requiredItem
                );
            }
        }

        List<Work_Order__c> workOrders = [
            SELECT Id, Status__c FROM Work_Order__c WHERE Id = :workOrderId WITH USER_MODE LIMIT 1
        ];
        if (workOrders.isEmpty()) {
            throw new AuraHandledException('작업을 찾을 수 없습니다.');
        }

        Work_Order__c wo = workOrders[0];
        wo.Status__c = 'Completed';
        wo.Signature_Captured__c = true;
        wo.Completed_Date__c = Datetime.now();

        try {
            update wo;
        } catch (DmlException ex) {
            throw new AuraHandledException('작업 완료 처리 중 오류가 발생했습니다: ' + ex.getMessage());
        }
    }

    public class WorkOrderSummary {
        @AuraEnabled public String workOrderNumber;
        @AuraEnabled public String customerName;
        @AuraEnabled public String serviceAddress;
    }
}
