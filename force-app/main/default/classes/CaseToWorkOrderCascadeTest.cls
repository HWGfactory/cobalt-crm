// Service Cloud(Case)와 기존 FSM 실행 레이어(Work_Order__c/Technician__c)가
// 실제로 한 번의 트랜잭션 안에서 맞물리는지를 증명하는 통합 테스트.
// Case 하나의 필드 변경 -> Work Order 생성 -> TechnicianAssignmentService ->
// RouteCalloutService(Queueable)까지 이어지는 전체 연쇄를 끝까지 검증한다.
@IsTest
private class CaseToWorkOrderCascadeTest {

    @IsTest
    static void testCaseFlaggedForFieldVisit_cascadesAllTheWayToTechnicianAssignment() {
        Account acc = new Account(
            Name = 'Cascade Test Account',
            BillingStreet = '77 Cobalt Ave',
            BillingCity = 'Busan',
            BillingState = 'Busan',
            BillingPostalCode = '48058',
            BillingCountry = 'South Korea'
        );
        insert acc;

        Service_Contract__c contract = new Service_Contract__c(Account__c = acc.Id, Status__c = 'Active');
        insert contract;

        // 이 계약 아래 이미 진행된 작업이 있어야 새 Work Order가 지역을 이어받아
        // 기술자 후보 풀을 찾을 수 있다.
        Work_Order__c pastVisit = new Work_Order__c(
            Service_Contract__c = contract.Id,
            Status__c = 'Completed',
            Service_Region__c = 'South'
        );
        insert pastVisit;

        Technician__c tech = new Technician__c(
            Name = 'Cascade Test Technician',
            Skills__c = 'Elevator',
            Service_Region__c = 'South',
            Is_Available__c = true,
            Active_Work_Orders__c = 0,
            Base_Location__Latitude__s = 35.1796,
            Base_Location__Longitude__s = 129.0756
        );
        insert tech;

        Case c = new Case(
            AccountId = acc.Id,
            Service_Contract__c = contract.Id,
            Case_Category__c = 'Equipment Failure',
            Priority = 'High',
            Subject = 'Elevator not responding on floor 12',
            Requires_Field_Visit__c = false
        );
        insert c;

        // 연쇄의 시작점: Service Cloud 담당자가 현장 방문이 필요하다고 체크하는 순간.
        Test.startTest();
        c.Requires_Field_Visit__c = true;
        update c;
        Test.stopTest(); // RouteCalloutService(Queueable)를 여기서 동기적으로 실행시킨다.

        // 1) Case가 Work Order로 전환되고, 상태가 현장 서비스 대기로 바뀌었는가.
        Case convertedCase = [
            SELECT Status, Related_Work_Order__c FROM Case WHERE Id = :c.Id
        ];
        System.assertEquals('Waiting on Field Service', convertedCase.Status);
        System.assertNotEquals(null, convertedCase.Related_Work_Order__c);

        // 2) 생성된 Work Order가 Case의 정보를 정확히 승계했는가.
        Work_Order__c wo = [
            SELECT Status__c, Priority__c, Required_Skill__c, Service_Region__c,
                   Service_Address__c, Service_Contract__c, Assigned_Technician__c
            FROM Work_Order__c
            WHERE Id = :convertedCase.Related_Work_Order__c
        ];
        System.assertEquals(contract.Id, wo.Service_Contract__c);
        System.assertEquals('High', wo.Priority__c);
        System.assertEquals('Elevator', wo.Required_Skill__c);
        System.assertEquals('South', wo.Service_Region__c);
        System.assert(wo.Service_Address__c.contains('Busan'));

        // 3) 이 지점이 핵심 장면: Work Order insert가 WorkOrderTriggerHandler를 통해
        // TechnicianAssignmentService를 자동으로 호출했고, 그 결과 실제 기술자가 배정됐다.
        // Case를 만든 사람은 TechnicianAssignmentService를 단 한 줄도 직접 호출하지 않았다.
        System.assertEquals(
            'Assigned', wo.Status__c,
            'Work Order 생성만으로 기존 기술자 배정 엔진이 자동 실행되어 Assigned 상태가 되어야 함'
        );
        System.assertEquals(
            tech.Id, wo.Assigned_Technician__c,
            'Service_Region__c/Required_Skill__c가 일치하는 유일한 기술자가 자동 배정되어야 함'
        );

        // 4) 배정 실패(에스컬레이션)로 새지 않았는지도 함께 확인한다.
        System.assertEquals(
            0, [SELECT COUNT() FROM Task WHERE WhatId = :wo.Id],
            '정상 배정된 경우 디스패처 에스컬레이션 Task는 생성되지 않아야 함'
        );
    }

    @IsTest
    static void testCaseFlaggedForFieldVisit_noMatchingTechnicianEscalatesInstead() {
        Account acc = new Account(Name = 'Cascade No Match Account');
        insert acc;
        Service_Contract__c contract = new Service_Contract__c(Account__c = acc.Id);
        insert contract;
        Work_Order__c pastVisit = new Work_Order__c(
            Service_Contract__c = contract.Id,
            Status__c = 'Completed',
            Service_Region__c = 'East'
        );
        insert pastVisit;

        // 지역은 맞지만 스킬이 다른 기술자만 존재 -> 자동 배정 실패 -> 디스패처 큐로 에스컬레이션.
        Technician__c wrongSkillTech = new Technician__c(
            Name = 'Wrong Skill Technician',
            Skills__c = 'Plumbing',
            Service_Region__c = 'East',
            Is_Available__c = true,
            Active_Work_Orders__c = 0
        );
        insert wrongSkillTech;

        Case c = new Case(
            AccountId = acc.Id,
            Service_Contract__c = contract.Id,
            Case_Category__c = 'Equipment Failure',
            Priority = 'Medium',
            Subject = 'Elevator issue, no matching technician',
            Requires_Field_Visit__c = false
        );
        insert c;

        Test.startTest();
        c.Requires_Field_Visit__c = true;
        update c;
        Test.stopTest();

        Case convertedCase = [SELECT Related_Work_Order__c FROM Case WHERE Id = :c.Id];
        Work_Order__c wo = [
            SELECT Status__c, Assigned_Technician__c FROM Work_Order__c WHERE Id = :convertedCase.Related_Work_Order__c
        ];
        System.assertEquals(null, wo.Assigned_Technician__c);
        System.assertEquals('New', wo.Status__c);
        System.assertEquals(
            1, [SELECT COUNT() FROM Task WHERE WhatId = :wo.Id],
            '조건에 맞는 기술자가 없으면 Case 발 전환이라도 동일하게 에스컬레이션되어야 함'
        );
    }
}
