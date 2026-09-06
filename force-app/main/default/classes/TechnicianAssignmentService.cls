public with sharing class TechnicianAssignmentService {

    // 스킬/거리/업무량 가중치는 실제 스코어링 계산이 일어나는 RouteCalloutService 한 곳에만
    // 둔다. 이전에는 이 클래스에도 같은 값을 복제해뒀는데, 여기서는 실제로 쓰이지 않는 죽은
    // 상수였고 두 곳을 따로 관리하면 한쪽만 바꿨을 때 조용히 어긋날 위험이 있었다.
    @TestVisible private static final Decimal MAX_WORKLOAD_ORDERS = 10;
    @TestVisible private static final Integer SCHEDULE_BUFFER_MINUTES = 120;

    private static final Set<String> ACTIVE_STATUSES = new Set<String>{
        'New', 'Assigned', 'En Route', 'On Site'
    };

    public static void assign(Set<Id> workOrderIds) {
        if (workOrderIds == null || workOrderIds.isEmpty()) {
            return;
        }

        List<Work_Order__c> workOrders = [
            SELECT Id, Name, Required_Skill__c, Service_Region__c, Scheduled_Date__c,
                   Service_Location__Latitude__s, Service_Location__Longitude__s
            FROM Work_Order__c
            WHERE Id IN :workOrderIds
        ];
        if (workOrders.isEmpty()) {
            return;
        }

        Set<String> regions = new Set<String>();
        for (Work_Order__c wo : workOrders) {
            if (String.isNotBlank(wo.Service_Region__c)) {
                regions.add(wo.Service_Region__c);
            }
        }

        List<Technician__c> candidatePool = regions.isEmpty() ? new List<Technician__c>() : [
            SELECT Id, Name, Skills__c, Service_Region__c, Is_Available__c, Active_Work_Orders__c,
                   Base_Location__Latitude__s, Base_Location__Longitude__s
            FROM Technician__c
            WHERE Is_Available__c = true
              AND Service_Region__c IN :regions
        ];

        Set<Id> technicianIdsInPool = new Set<Id>();
        for (Technician__c t : candidatePool) {
            technicianIdsInPool.add(t.Id);
        }

        Map<Id, List<Work_Order__c>> activeOrdersByTechnician = new Map<Id, List<Work_Order__c>>();
        if (!technicianIdsInPool.isEmpty()) {
            for (Work_Order__c activeWo : [
                SELECT Id, Assigned_Technician__c, Scheduled_Date__c
                FROM Work_Order__c
                WHERE Assigned_Technician__c IN :technicianIdsInPool
                  AND Status__c IN :ACTIVE_STATUSES
                  AND Id NOT IN :workOrderIds
            ]) {
                if (!activeOrdersByTechnician.containsKey(activeWo.Assigned_Technician__c)) {
                    activeOrdersByTechnician.put(activeWo.Assigned_Technician__c, new List<Work_Order__c>());
                }
                activeOrdersByTechnician.get(activeWo.Assigned_Technician__c).add(activeWo);
            }
        }

        List<Work_Order__c> ordersToEscalate = new List<Work_Order__c>();
        List<RouteCalloutService.PendingLookup> pendingLookups = new List<RouteCalloutService.PendingLookup>();

        for (Work_Order__c wo : workOrders) {
            List<Technician__c> candidates = filterCandidates(wo, candidatePool, activeOrdersByTechnician);
            if (candidates.isEmpty()) {
                ordersToEscalate.add(wo);
                continue;
            }
            for (Technician__c candidate : candidates) {
                pendingLookups.add(buildLookup(wo, candidate));
            }
        }

        if (!ordersToEscalate.isEmpty()) {
            createEscalationTasks(ordersToEscalate);
        }

        if (!pendingLookups.isEmpty()) {
            System.enqueueJob(new RouteCalloutService(pendingLookups));
        }
    }

    private static RouteCalloutService.PendingLookup buildLookup(Work_Order__c wo, Technician__c candidate) {
        RouteCalloutService.PendingLookup lookup = new RouteCalloutService.PendingLookup();
        lookup.workOrderId = wo.Id;
        lookup.technicianId = candidate.Id;
        lookup.originLatitude = candidate.Base_Location__Latitude__s;
        lookup.originLongitude = candidate.Base_Location__Longitude__s;
        lookup.destinationLatitude = wo.Service_Location__Latitude__s;
        lookup.destinationLongitude = wo.Service_Location__Longitude__s;
        lookup.skillMatchPercent = 100;
        lookup.workloadPercent = computeWorkloadScore(candidate.Active_Work_Orders__c) * 100;
        return lookup;
    }

    private static List<Technician__c> filterCandidates(
        Work_Order__c wo,
        List<Technician__c> pool,
        Map<Id, List<Work_Order__c>> activeOrdersByTechnician
    ) {
        List<Technician__c> result = new List<Technician__c>();
        for (Technician__c t : pool) {
            if (wo.Service_Region__c != t.Service_Region__c) {
                continue;
            }
            if (String.isNotBlank(wo.Required_Skill__c) && !hasSkill(t.Skills__c, wo.Required_Skill__c)) {
                continue;
            }
            if (isBusyAtScheduledTime(t.Id, wo.Scheduled_Date__c, activeOrdersByTechnician)) {
                continue;
            }
            result.add(t);
        }
        return result;
    }

    private static Boolean hasSkill(String skillsCsv, String requiredSkill) {
        if (String.isBlank(skillsCsv)) {
            return false;
        }
        for (String skill : skillsCsv.split(';')) {
            if (skill == requiredSkill) {
                return true;
            }
        }
        return false;
    }

    private static Boolean isBusyAtScheduledTime(
        Id technicianId,
        DateTime scheduledDate,
        Map<Id, List<Work_Order__c>> activeOrdersByTechnician
    ) {
        if (scheduledDate == null || !activeOrdersByTechnician.containsKey(technicianId)) {
            return false;
        }
        Long bufferMs = (Long) SCHEDULE_BUFFER_MINUTES * 60000L;
        for (Work_Order__c existing : activeOrdersByTechnician.get(technicianId)) {
            if (existing.Scheduled_Date__c == null) {
                continue;
            }
            Long diffMs = Math.abs(existing.Scheduled_Date__c.getTime() - scheduledDate.getTime());
            if (diffMs <= bufferMs) {
                return true;
            }
        }
        return false;
    }

    private static Decimal computeWorkloadScore(Decimal activeWorkOrders) {
        Decimal load = activeWorkOrders == null ? 0 : activeWorkOrders;
        Decimal ratio = load / MAX_WORKLOAD_ORDERS;
        if (ratio > 1) {
            ratio = 1;
        }
        return 1 - ratio;
    }

    private static void createEscalationTasks(List<Work_Order__c> orders) {
        List<Group> dispatcherQueues = [
            SELECT Id FROM Group WHERE DeveloperName = 'Dispatcher_Queue' AND Type = 'Queue' LIMIT 1
        ];
        Id ownerId = dispatcherQueues.isEmpty() ? UserInfo.getUserId() : dispatcherQueues[0].Id;

        List<Task> escalations = new List<Task>();
        for (Work_Order__c wo : orders) {
            escalations.add(new Task(
                WhatId = wo.Id,
                OwnerId = ownerId,
                Subject = '배정 실패: 기술자 후보 없음 - ' + wo.Name,
                Description = '필요 스킬/지역/가용 시간대 조건을 만족하는 기술자 후보가 없어 자동 배정에 실패했습니다. 수동 배정이 필요합니다.',
                Priority = 'High',
                Status = 'Not Started',
                ActivityDate = Date.today()
            ));
        }
        insert escalations;
    }
}
