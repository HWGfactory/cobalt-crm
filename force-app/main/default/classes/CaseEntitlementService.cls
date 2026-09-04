public with sharing class CaseEntitlementService {

    // Service_Contract__c.Tier__c 값 -> 등급별 Entitlement Process(Name) 매핑.
    // Entitlement Process 자체(마일스톤/목표 시간)는 메타데이터로 배포되어 있고,
    // 여기서는 등급에 맞는 프로세스를 찾아 연결하는 책임만 진다.
    @TestVisible
    private static final Map<String, String> TIER_TO_PROCESS_NAME = new Map<String, String>{
        'Enterprise' => 'Cobalt Enterprise SLA',
        'Pro' => 'Cobalt Pro SLA',
        'Starter' => 'Cobalt Starter SLA'
    };

    // Entitlement Process(EntitlementProcess 메타데이터)는 등급당 하나만 존재하면 되지만,
    // 그 프로세스를 실제로 Case에 연결하려면 Account 단위의 Entitlement 레코드(데이터)가 있어야
    // 한다. 이 메서드는 Case 생성 시 계정+등급 조합에 맞는 Entitlement가 없으면 새로 만들고,
    // 있으면 재사용해서 Case.EntitlementId를 채운다.
    public static void assignEntitlements(Set<Id> caseIds) {
        if (caseIds == null || caseIds.isEmpty()) {
            return;
        }

        List<Case> cases = [
            SELECT Id, AccountId, Service_Contract__r.Tier__c
            FROM Case
            WHERE Id IN :caseIds
              AND EntitlementId = null
              AND Service_Contract__c != null
              AND AccountId != null
        ];
        if (cases.isEmpty()) {
            return;
        }

        Map<String, Id> processIdByName = queryEntitlementProcessIds();
        Map<String, Id> entitlementIdByKey = findExistingEntitlements(cases);

        List<String> newKeys = new List<String>();
        List<Entitlement> newEntitlements = new List<Entitlement>();
        Set<String> plannedKeys = new Set<String>();
        Id businessHoursId;

        for (Case c : cases) {
            String tier = c.Service_Contract__r.Tier__c;
            String processName = TIER_TO_PROCESS_NAME.get(tier);
            Id processId = processName == null ? null : processIdByName.get(processName);
            if (processId == null) {
                continue; // 등급을 모르거나, 해당 등급의 Entitlement Process가 배포되어 있지 않음
            }

            String key = entitlementKey(c.AccountId, tier);
            if (entitlementIdByKey.containsKey(key) || plannedKeys.contains(key)) {
                continue;
            }

            if (businessHoursId == null) {
                businessHoursId = resolveDefaultBusinessHoursId();
            }

            plannedKeys.add(key);
            newKeys.add(key);
            newEntitlements.add(new Entitlement(
                Name = tier + ' SLA Entitlement',
                AccountId = c.AccountId,
                SlaProcessId = processId,
                BusinessHoursId = businessHoursId
            ));
        }

        if (!newEntitlements.isEmpty()) {
            insert newEntitlements;
            for (Integer i = 0; i < newKeys.size(); i++) {
                entitlementIdByKey.put(newKeys[i], newEntitlements[i].Id);
            }
        }

        List<Case> caseUpdates = new List<Case>();
        for (Case c : cases) {
            String tier = c.Service_Contract__r.Tier__c;
            Id entitlementId = entitlementIdByKey.get(entitlementKey(c.AccountId, tier));
            if (entitlementId != null) {
                caseUpdates.add(new Case(Id = c.Id, EntitlementId = entitlementId));
            }
        }
        if (!caseUpdates.isEmpty()) {
            update caseUpdates;
        }
    }

    private static String entitlementKey(Id accountId, String tier) {
        return accountId + ':' + tier;
    }

    // EntitlementProcess는 메타데이터 구성 요소지만, 실제 레코드 Id는 Data API 상
    // SlaProcess라는 이름의 SObject로 조회된다(Metadata API 이름과 Data API 이름이 다른
    // 플랫폼의 알려진 특이 케이스).
    private static Map<String, Id> queryEntitlementProcessIds() {
        Map<String, Id> result = new Map<String, Id>();
        for (SlaProcess p : [
            SELECT Id, Name FROM SlaProcess WHERE Name IN :TIER_TO_PROCESS_NAME.values()
        ]) {
            result.put(p.Name, p.Id);
        }
        return result;
    }

    private static Map<String, Id> findExistingEntitlements(List<Case> cases) {
        Set<Id> accountIds = new Set<Id>();
        for (Case c : cases) {
            accountIds.add(c.AccountId);
        }

        Map<String, Id> result = new Map<String, Id>();
        for (Entitlement e : [
            SELECT Id, AccountId, SlaProcess.Name
            FROM Entitlement
            WHERE AccountId IN :accountIds AND SlaProcessId != null
        ]) {
            String tier = tierForProcessName(e.SlaProcess.Name);
            if (tier != null) {
                result.put(entitlementKey(e.AccountId, tier), e.Id);
            }
        }
        return result;
    }

    private static String tierForProcessName(String processName) {
        for (String tier : TIER_TO_PROCESS_NAME.keySet()) {
            if (TIER_TO_PROCESS_NAME.get(tier) == processName) {
                return tier;
            }
        }
        return null;
    }

    // Entitlement/Milestone의 SLA 카운트다운 자체는 플랫폼이 Business Hours를 반영해
    // 내부적으로 계산해준다(SLACalculator가 담당하는 수동 마감시각 계산과는 별개 경로).
    // 여기서는 새로 만드는 Entitlement에 붙일 기본 Business Hours만 조회하면 된다.
    @TestVisible
    private static Id resolveDefaultBusinessHoursId() {
        List<BusinessHours> defaultHours = [SELECT Id FROM BusinessHours WHERE IsDefault = true LIMIT 1];
        return defaultHours.isEmpty() ? null : defaultHours[0].Id;
    }
}
