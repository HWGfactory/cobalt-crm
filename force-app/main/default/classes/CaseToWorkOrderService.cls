public with sharing class CaseToWorkOrderService {

    @TestVisible private static final String CASE_WAITING_STATUS = 'Waiting on Field Service';
    @TestVisible private static final String WORK_ORDER_NEW_STATUS = 'New';
    @TestVisible private static final String DEFAULT_PRIORITY = 'Medium';

    // Equipment Failure/Installation Issue처럼 실제 현장 작업이 필요한 문의만 구체적인 스킬로
    // 매핑한다. Billing/Complaint/Inquiry는 현장 방문 체크가 되더라도 특정 설비 스킬이 필요한
    // 문의가 아니므로 Required_Skill__c는 비워두고 디스패처가 수동으로 판단하게 한다.
    @TestVisible
    private static final Map<String, String> CATEGORY_TO_SKILL = new Map<String, String>{
        'Equipment Failure' => 'Elevator',
        'Installation Issue' => 'Electrical'
    };

    // Case가 전환되어 만들어지는 Work Order는 이 트리거 실행 자체에서 처음 생기는 레코드라
    // Service_Region__c를 어디서도 직접 승계받을 수 없다(Case/Account에 지역 필드가 없음).
    // TechnicianAssignmentService는 이 필드가 비어 있으면 후보 기술자 풀 자체를 만들지 못하므로,
    // 같은 Service_Contract__c 아래 이미 지역이 기록된 최근 작업의 지역을 이어받는다.
    public static void convertToWorkOrders(Set<Id> caseIds) {
        if (caseIds == null || caseIds.isEmpty()) {
            return;
        }

        List<Case> cases = [
            SELECT Id, Priority, Case_Category__c, Service_Contract__c,
                   Account.BillingStreet, Account.BillingCity, Account.BillingState,
                   Account.BillingPostalCode, Account.BillingCountry
            FROM Case
            WHERE Id IN :caseIds
              AND Service_Contract__c != null
        ];
        if (cases.isEmpty()) {
            return;
        }

        Map<Id, String> latestRegionByContract = resolveLatestRegionByContract(contractIdsOf(cases));

        List<Work_Order__c> newOrders = new List<Work_Order__c>();
        for (Case c : cases) {
            newOrders.add(buildWorkOrder(c, latestRegionByContract.get(c.Service_Contract__c)));
        }
        insert newOrders;

        List<Case> caseUpdates = new List<Case>();
        for (Integer i = 0; i < cases.size(); i++) {
            caseUpdates.add(new Case(
                Id = cases[i].Id,
                Related_Work_Order__c = newOrders[i].Id,
                Status = CASE_WAITING_STATUS
            ));
        }
        update caseUpdates;
    }

    private static Set<Id> contractIdsOf(List<Case> cases) {
        Set<Id> ids = new Set<Id>();
        for (Case c : cases) {
            ids.add(c.Service_Contract__c);
        }
        return ids;
    }

    private static Map<Id, String> resolveLatestRegionByContract(Set<Id> contractIds) {
        Map<Id, String> result = new Map<Id, String>();
        for (Work_Order__c wo : [
            SELECT Service_Contract__c, Service_Region__c
            FROM Work_Order__c
            WHERE Service_Contract__c IN :contractIds
              AND Service_Region__c != null
            ORDER BY CreatedDate DESC
        ]) {
            if (!result.containsKey(wo.Service_Contract__c)) {
                result.put(wo.Service_Contract__c, wo.Service_Region__c);
            }
        }
        return result;
    }

    private static Work_Order__c buildWorkOrder(Case c, String inheritedRegion) {
        return new Work_Order__c(
            Service_Contract__c = c.Service_Contract__c,
            Status__c = WORK_ORDER_NEW_STATUS,
            Priority__c = mapPriority(c.Priority),
            Required_Skill__c = CATEGORY_TO_SKILL.get(c.Case_Category__c),
            Service_Region__c = inheritedRegion,
            Service_Address__c = buildAddress(c)
        );
    }

    @TestVisible
    private static String mapPriority(String casePriority) {
        return String.isBlank(casePriority) ? DEFAULT_PRIORITY : casePriority;
    }

    private static String buildAddress(Case c) {
        if (c.Account == null) {
            return null;
        }
        List<String> parts = new List<String>();
        addIfNotBlank(parts, c.Account.BillingStreet);
        addIfNotBlank(parts, c.Account.BillingCity);
        addIfNotBlank(parts, c.Account.BillingState);
        addIfNotBlank(parts, c.Account.BillingPostalCode);
        addIfNotBlank(parts, c.Account.BillingCountry);
        return parts.isEmpty() ? null : String.join(parts, ', ');
    }

    private static void addIfNotBlank(List<String> parts, String value) {
        if (String.isNotBlank(value)) {
            parts.add(value);
        }
    }

    // "현장 작업 생성" Quick Action이나 화면에서 케이스 담당자가 직접 전환을 트리거할 때 쓰는 진입점.
    // 트리거 경로(Requires_Field_Visit__c false -> true)와 동일한 핵심 로직을 그대로 재사용한다.
    @InvocableMethod(
        label='Case를 Work Order로 전환'
        description='현장 방문이 필요한 Case를 연결된 Service Contract 아래 Work Order로 전환합니다.'
    )
    public static void convertToWorkOrdersInvocable(List<Id> caseIds) {
        convertToWorkOrders(new Set<Id>(caseIds));
    }
}
