public with sharing class WorkOrderController {

    private static final List<String> KANBAN_STATUSES = new List<String>{
        'New', 'Assigned', 'En Route', 'On Site', 'Completed'
    };

    private static final Set<String> IN_PROGRESS_STATUSES = new Set<String>{
        'Assigned', 'En Route', 'On Site'
    };

    @AuraEnabled(cacheable=true)
    public static DashboardData getActiveWorkOrders() {
        DashboardData result = new DashboardData();

        List<Work_Order__c> workOrders = [
            SELECT Id, Name, Status__c, Priority__c, Service_Address__c, ETA__c, Scheduled_Date__c,
                   Assigned_Technician__c, Assigned_Technician__r.Name,
                   Service_Contract__r.Account__r.Name
            FROM Work_Order__c
            WHERE Scheduled_Date__c = TODAY AND Status__c != 'Cancelled'
            WITH USER_MODE
            ORDER BY Priority__c DESC NULLS LAST, Scheduled_Date__c ASC NULLS LAST
        ];

        Map<String, List<WorkOrderCard>> cardsByStatus = new Map<String, List<WorkOrderCard>>();
        for (String status : KANBAN_STATUSES) {
            cardsByStatus.put(status, new List<WorkOrderCard>());
        }

        Integer unassignedCount = 0;
        Integer inProgressCount = 0;
        Integer completedCount = 0;

        for (Work_Order__c wo : workOrders) {
            WorkOrderCard card = new WorkOrderCard();
            card.workOrderId = wo.Id;
            card.workOrderNumber = wo.Name;
            card.customerName = (wo.Service_Contract__r != null && wo.Service_Contract__r.Account__r != null)
                ? wo.Service_Contract__r.Account__r.Name
                : null;
            card.serviceAddress = wo.Service_Address__c;
            card.priority = wo.Priority__c;
            card.status = wo.Status__c;
            card.eta = wo.ETA__c;
            card.scheduledDate = wo.Scheduled_Date__c;
            card.assignedTechnicianId = wo.Assigned_Technician__c;
            card.assignedTechnicianName = wo.Assigned_Technician__c != null ? wo.Assigned_Technician__r.Name : null;

            if (!cardsByStatus.containsKey(wo.Status__c)) {
                cardsByStatus.put(wo.Status__c, new List<WorkOrderCard>());
            }
            cardsByStatus.get(wo.Status__c).add(card);

            if (wo.Status__c == 'New' && wo.Assigned_Technician__c == null) {
                unassignedCount++;
            } else if (IN_PROGRESS_STATUSES.contains(wo.Status__c)) {
                inProgressCount++;
            } else if (wo.Status__c == 'Completed') {
                completedCount++;
            }
        }

        List<StatusColumn> columns = new List<StatusColumn>();
        for (String status : KANBAN_STATUSES) {
            StatusColumn column = new StatusColumn();
            column.status = status;
            column.workOrders = cardsByStatus.get(status);
            columns.add(column);
        }

        SummaryStats summary = new SummaryStats();
        summary.totalCount = workOrders.size();
        summary.unassignedCount = unassignedCount;
        summary.inProgressCount = inProgressCount;
        summary.completedCount = completedCount;

        result.summary = summary;
        result.columns = columns;
        result.technicians = buildTechnicianList();
        return result;
    }

    @AuraEnabled
    public static void reassign(Id workOrderId, Id technicianId) {
        if (workOrderId == null || technicianId == null) {
            throw new AuraHandledException('작업과 기술자를 모두 지정해야 합니다.');
        }

        List<Work_Order__c> workOrders = [
            SELECT Id, Status__c FROM Work_Order__c WHERE Id = :workOrderId WITH USER_MODE LIMIT 1
        ];
        if (workOrders.isEmpty()) {
            throw new AuraHandledException('작업을 찾을 수 없습니다.');
        }

        List<Technician__c> technicians = [
            SELECT Id FROM Technician__c WHERE Id = :technicianId WITH USER_MODE LIMIT 1
        ];
        if (technicians.isEmpty()) {
            throw new AuraHandledException('기술자를 찾을 수 없습니다.');
        }

        Work_Order__c wo = workOrders[0];
        wo.Assigned_Technician__c = technicianId;
        if (wo.Status__c == 'New') {
            wo.Status__c = 'Assigned';
        }

        try {
            update wo;
        } catch (DmlException ex) {
            throw new AuraHandledException('재배정 중 오류가 발생했습니다: ' + ex.getMessage());
        }
    }

    private static List<TechnicianInfo> buildTechnicianList() {
        List<TechnicianInfo> result = new List<TechnicianInfo>();
        for (Technician__c tech : [
            SELECT Id, Name, Is_Available__c, Active_Work_Orders__c, Service_Region__c,
                   Base_Location__Latitude__s, Base_Location__Longitude__s
            FROM Technician__c
            WITH USER_MODE
            ORDER BY Name ASC
        ]) {
            TechnicianInfo info = new TechnicianInfo();
            info.technicianId = tech.Id;
            info.name = tech.Name;
            info.isAvailable = tech.Is_Available__c;
            info.activeWorkOrders = tech.Active_Work_Orders__c;
            info.serviceRegion = tech.Service_Region__c;
            info.latitude = tech.Base_Location__Latitude__s;
            info.longitude = tech.Base_Location__Longitude__s;
            result.add(info);
        }
        return result;
    }

    public class DashboardData {
        @AuraEnabled public SummaryStats summary;
        @AuraEnabled public List<StatusColumn> columns;
        @AuraEnabled public List<TechnicianInfo> technicians;
    }

    public class SummaryStats {
        @AuraEnabled public Integer totalCount;
        @AuraEnabled public Integer unassignedCount;
        @AuraEnabled public Integer inProgressCount;
        @AuraEnabled public Integer completedCount;
    }

    public class StatusColumn {
        @AuraEnabled public String status;
        @AuraEnabled public List<WorkOrderCard> workOrders;
    }

    public class WorkOrderCard {
        @AuraEnabled public Id workOrderId;
        @AuraEnabled public String workOrderNumber;
        @AuraEnabled public String customerName;
        @AuraEnabled public String serviceAddress;
        @AuraEnabled public String priority;
        @AuraEnabled public String status;
        @AuraEnabled public Datetime eta;
        @AuraEnabled public Datetime scheduledDate;
        @AuraEnabled public Id assignedTechnicianId;
        @AuraEnabled public String assignedTechnicianName;
    }

    public class TechnicianInfo {
        @AuraEnabled public Id technicianId;
        @AuraEnabled public String name;
        @AuraEnabled public Boolean isAvailable;
        @AuraEnabled public Decimal activeWorkOrders;
        @AuraEnabled public String serviceRegion;
        @AuraEnabled public Decimal latitude;
        @AuraEnabled public Decimal longitude;
    }
}
