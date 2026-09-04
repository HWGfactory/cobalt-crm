public with sharing class InvoiceGenerationService {

    // 실제 요율 체계가 정해지기 전까지 사용하는 기본 시간당 공임 단가.
    @TestVisible private static final Decimal LABOR_HOURLY_RATE = 75;

    public static void generateInvoices(Set<Id> workOrderIds) {
        if (workOrderIds == null || workOrderIds.isEmpty()) {
            return;
        }

        List<Work_Order__c> workOrders = [
            SELECT Id, Labor_Hours__c, Service_Contract__r.Account__c
            FROM Work_Order__c
            WHERE Id IN :workOrderIds
        ];
        if (workOrders.isEmpty()) {
            return;
        }

        Set<Id> alreadyInvoicedWorkOrderIds = new Set<Id>();
        for (Invoice__c existing : [
            SELECT Work_Order__c FROM Invoice__c WHERE Work_Order__c IN :workOrderIds
        ]) {
            alreadyInvoicedWorkOrderIds.add(existing.Work_Order__c);
        }

        Map<Id, Decimal> partsAmountByWorkOrder = new Map<Id, Decimal>();
        for (AggregateResult ar : [
            SELECT Work_Order__c workOrderId, SUM(Line_Total__c) total
            FROM Part_Line__c
            WHERE Work_Order__c IN :workOrderIds
            GROUP BY Work_Order__c
        ]) {
            partsAmountByWorkOrder.put((Id) ar.get('workOrderId'), (Decimal) ar.get('total'));
        }

        List<Invoice__c> invoicesToInsert = new List<Invoice__c>();
        for (Work_Order__c wo : workOrders) {
            if (alreadyInvoicedWorkOrderIds.contains(wo.Id)) {
                continue;
            }

            Decimal laborHours = wo.Labor_Hours__c == null ? 0 : wo.Labor_Hours__c;
            Decimal laborAmount = (laborHours * LABOR_HOURLY_RATE).setScale(2);
            Decimal partsAmount = partsAmountByWorkOrder.containsKey(wo.Id)
                ? partsAmountByWorkOrder.get(wo.Id)
                : 0;

            invoicesToInsert.add(new Invoice__c(
                Work_Order__c = wo.Id,
                Account__c = wo.Service_Contract__r != null ? wo.Service_Contract__r.Account__c : null,
                Parts_Amount__c = partsAmount,
                Labor_Amount__c = laborAmount,
                Payment_Status__c = 'Pending',
                // Work Order Id에서 결정론적으로 유도 - 동일 작업에 대한 재호출이 있어도
                // 항상 같은 값이 나오므로 Idempotency_Key__c의 Unique 제약이 중복 청구서를 막아준다.
                Idempotency_Key__c = 'INV-' + wo.Id,
                Issued_Date__c = Date.today()
            ));
        }

        if (invoicesToInsert.isEmpty()) {
            return;
        }

        insert invoicesToInsert;

        List<PaymentCalloutQueueable.PaymentRequest> paymentRequests = new List<PaymentCalloutQueueable.PaymentRequest>();
        for (Invoice__c inv : invoicesToInsert) {
            PaymentCalloutQueueable.PaymentRequest request = new PaymentCalloutQueueable.PaymentRequest();
            request.invoiceId = inv.Id;
            request.amount = (inv.Parts_Amount__c == null ? 0 : inv.Parts_Amount__c)
                + (inv.Labor_Amount__c == null ? 0 : inv.Labor_Amount__c);
            request.idempotencyKey = inv.Idempotency_Key__c;
            request.retryCount = 0;
            paymentRequests.add(request);
        }

        if (!paymentRequests.isEmpty()) {
            System.enqueueJob(new PaymentCalloutQueueable(paymentRequests));
        }
    }
}
