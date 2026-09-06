public with sharing class ServiceContractCreationService {

    // 등급별 SLA 목표 시간(시간 단위). 영업 정책이라 자주 바뀌는 값은 아니라고 보고
    // 상수로 유지 중이다. 등급이나 정책이 잦아지면 Custom Metadata Type 이동을 검토한다.
    @TestVisible private static final Integer SLA_HOURS_STARTER = 48;
    @TestVisible private static final Integer SLA_HOURS_PRO = 24;
    @TestVisible private static final Integer SLA_HOURS_ENTERPRISE = 4;

    private static final Map<String, Integer> TIER_TO_SLA_HOURS = new Map<String, Integer>{
        'Starter' => SLA_HOURS_STARTER,
        'Pro' => SLA_HOURS_PRO,
        'Enterprise' => SLA_HOURS_ENTERPRISE
    };

    private static final Integer QUARTERLY_CHECK_COUNT = 4;
    private static final Integer MONTHS_PER_QUARTER = 3;
    private static final Time QUARTERLY_CHECK_TIME = Time.newInstance(9, 0, 0, 0);

    public static void createFromOpportunities(Set<Id> opportunityIds) {
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return;
        }

        List<Opportunity> opportunities = [
            SELECT Id, AccountId, Product_Tier__c
            FROM Opportunity
            WHERE Id IN :opportunityIds
        ];
        if (opportunities.isEmpty()) {
            return;
        }

        Set<Id> alreadyConvertedOppIds = new Set<Id>();
        for (Service_Contract__c existing : [
            SELECT Opportunity__c FROM Service_Contract__c WHERE Opportunity__c IN :opportunityIds
        ]) {
            alreadyConvertedOppIds.add(existing.Opportunity__c);
        }

        List<Opportunity> opportunitiesToConvert = new List<Opportunity>();
        for (Opportunity opp : opportunities) {
            if (!alreadyConvertedOppIds.contains(opp.Id)) {
                opportunitiesToConvert.add(opp);
            }
        }
        if (opportunitiesToConvert.isEmpty()) {
            return;
        }

        Id businessHoursId = resolveDefaultBusinessHoursId();

        List<Service_Contract__c> contracts = new List<Service_Contract__c>();
        for (Opportunity opp : opportunitiesToConvert) {
            contracts.add(buildContract(opp));
        }
        insert contracts;

        List<Work_Order__c> maintenanceOrders = new List<Work_Order__c>();
        for (Integer i = 0; i < contracts.size(); i++) {
            Service_Contract__c contract = contracts[i];
            Integer slaHours = resolveSlaHours(opportunitiesToConvert[i].Product_Tier__c);
            maintenanceOrders.addAll(buildQuarterlyMaintenanceOrders(contract, slaHours, businessHoursId));
        }
        if (!maintenanceOrders.isEmpty()) {
            insert maintenanceOrders;
        }
    }

    private static Service_Contract__c buildContract(Opportunity opp) {
        Date startDate = Date.today();
        return new Service_Contract__c(
            Account__c = opp.AccountId,
            Opportunity__c = opp.Id,
            Start_Date__c = startDate,
            End_Date__c = startDate.addYears(1),
            Status__c = 'Active',
            Tier__c = opp.Product_Tier__c,
            SLA_Hours__c = resolveSlaHours(opp.Product_Tier__c)
        );
    }

    @TestVisible
    private static Integer resolveSlaHours(String productTier) {
        Integer hours = TIER_TO_SLA_HOURS.get(productTier);
        return hours == null ? SLA_HOURS_PRO : hours;
    }

    private static List<Work_Order__c> buildQuarterlyMaintenanceOrders(
        Service_Contract__c contract, Integer slaHours, Id businessHoursId
    ) {
        List<Work_Order__c> orders = new List<Work_Order__c>();
        for (Integer quarter = 1; quarter <= QUARTERLY_CHECK_COUNT; quarter++) {
            Datetime scheduledDate = Datetime.newInstance(
                contract.Start_Date__c.addMonths(MONTHS_PER_QUARTER * quarter), QUARTERLY_CHECK_TIME
            );
            orders.add(new Work_Order__c(
                Service_Contract__c = contract.Id,
                Status__c = 'New',
                Priority__c = 'Medium',
                Work_Type__c = 'Maintenance',
                Scheduled_Date__c = scheduledDate,
                SLA_Deadline__c = SLACalculator.calculateDeadline(scheduledDate, slaHours, businessHoursId)
            ));
        }
        return orders;
    }

    @TestVisible
    private static Id resolveDefaultBusinessHoursId() {
        List<BusinessHours> defaultHours = [SELECT Id FROM BusinessHours WHERE IsDefault = true LIMIT 1];
        return defaultHours.isEmpty() ? null : defaultHours[0].Id;
    }
}
