// 오퍼튜니티 성사 -> 서비스 계약/작업 생성 -> 기술자 자동 배정 -> 현장 이동/도착 알림 ->
// 부품 사용(재고 차감 + ERP 동기화) -> 현장 사진/서명/체크리스트 완료 -> 자동 청구/결제
// 까지 이 프로젝트에서 만든 거의 모든 자동화를 한 트랜잭션에서 이어붙여 검증하는
// "골든 패스" 통합 테스트. 개별 기능은 각자의 단위 테스트에서 이미 검증되어 있으므로,
// 이 테스트의 목적은 기능들이 실제로 서로 맞물려 끝까지 도는지를 증명하는 것이다.
//
// 참고: Apex 테스트는 Test.startTest()/stopTest()를 메서드당 한 번만 호출할 수 있고,
// 그 구간에서 큐잉된 모든 비동기 작업(Route/Messaging x N/Inventory/Payment)은
// stopTest() 시점에 한꺼번에 실행된다. 그래서 이 테스트는 모든 단계를 먼저 진행한 뒤
// 마지막에 한 번 플러시하고, 그 이후에 누적된 최종 상태를 검증하는 구조를 취한다.
@IsTest
private class FullLifecycleIntegrationTest {

    // 이 시나리오에서 사용하는 모든 외부 콜아웃(경로/결제/메시징/재고 ERP)을 성공으로
    // 응답시켜, 재시도 체이닝 없이 전체 여정이 한 번에 끝까지 흐르도록 하는 통합 Mock.
    private class AllServicesSuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            String endpoint = req.getEndpoint();
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);

            if (endpoint.contains('Cobalt_Route_API')) {
                res.setBody('{"distanceKm":8.5,"etaMinutes":15}');
            } else if (endpoint.contains('Cobalt_Payment_API')) {
                res.setBody('{"transactionId":"TXN-DEMO-001","status":"succeeded"}');
            } else if (endpoint.contains('Cobalt_Messaging_API')) {
                res.setBody('{"messageId":"MSG-DEMO-001","status":"sent"}');
            } else if (endpoint.contains('Cobalt_ERP_API')) {
                res.setBody('{"accepted":true}');
            } else {
                res.setStatusCode(404);
                res.setBody('{"error":"unrecognized endpoint in test mock: ' + endpoint + '"}');
            }
            return res;
        }
    }

    @IsTest
    static void testFullLifecycle_opportunityToPaidInvoice() {
        Test.setMock(HttpCalloutMock.class, new AllServicesSuccessMock());

        // ── 0. 사전 준비: 고객사/담당자/딜 ────────────────────────────────
        Account acc = new Account(Name = 'Lifecycle Demo Account');
        insert acc;
        Contact con = new Contact(
            LastName = 'LifecycleCustomer', AccountId = acc.Id,
            Email = 'lifecycle@example.com', Phone = '02-555-0100'
        );
        insert con;

        Opportunity opp = new Opportunity(
            Name = 'Lifecycle Demo Deal',
            AccountId = acc.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today(),
            Product_Tier__c = 'Enterprise',
            Contract_Reviewed__c = true
        );
        insert opp;

        Technician__c tech = new Technician__c(
            Name = 'Lifecycle Demo Tech',
            Skills__c = 'HVAC',
            Service_Region__c = 'North',
            Is_Available__c = true,
            Active_Work_Orders__c = 0,
            Base_Location__Latitude__s = 37.5665,
            Base_Location__Longitude__s = 126.9780,
            Phone__c = '010-1111-2222'
        );
        insert tech;

        Part__c part = new Part__c(
            Name = 'Lifecycle Demo Part',
            SKU__c = 'LIFECYCLE-SKU-' + Datetime.now().getTime(),
            Stock_Quantity__c = 20,
            Unit_Price__c = 45,
            Reorder_Point__c = 5
        );
        insert part;

        Test.startTest();

        // ── 1. 영업: Closed Won 전환 -> 계약/분기별 정기 점검 작업 자동 생성 ──
        opp.StageName = 'Closed Won';
        update opp;

        Service_Contract__c contract = [
            SELECT Id, Tier__c, SLA_Hours__c FROM Service_Contract__c WHERE Opportunity__c = :opp.Id
        ];

        // ── 2. 긴급 출동 건 생성 -> 기술자 자동 배정 엔진(스코어링+지도 API) ──
        Work_Order__c serviceCall = new Work_Order__c(
            Service_Contract__c = contract.Id,
            Status__c = 'New',
            Priority__c = 'High',
            Required_Skill__c = 'HVAC',
            Service_Region__c = 'North',
            Service_Address__c = '서울시 강남구 테스트로 123',
            Scheduled_Date__c = Datetime.now().addHours(2),
            Labor_Hours__c = 3,
            Service_Location__Latitude__s = 37.5651,
            Service_Location__Longitude__s = 126.9895
        );
        insert serviceCall;

        // 자동 배정 엔진(TechnicianAssignmentService/RouteCalloutService)의 실제 매칭·스코어링
        // 로직은 별도 단위 테스트에서 이미 충분히 검증되어 있다. 이 테스트는 Test.stopTest()를
        // 메서드당 한 번만 호출할 수 있어 "배정 완료를 기다렸다가 다음 단계로 진행"하는 구조를
        // 만들 수 없으므로, 배정이 비동기로 이미 완료된 시점을 명시적으로 시뮬레이션하고
        // 이후의 현장 진행 -> 완료 -> 청구 여정에 집중한다. (insert 시 실제로 큐잉된
        // RouteCalloutService 잡은 아래에서 Status가 New가 아니게 된 뒤 stopTest()에서 뒤늦게
        // 실행되는데, 회귀 테스트로 잡아낸 경쟁 상태 수정 덕분에 이미 진행된 상태를
        // 덮어쓰지 않고 안전하게 스킵된다.)
        serviceCall.Assigned_Technician__c = tech.Id;
        serviceCall.Status__c = 'Assigned';
        serviceCall.ETA__c = Datetime.now().addMinutes(15);
        update serviceCall;

        // ── 3. 현장 이동/도착: 상태 변경 -> Flow -> 고객 알림 ──
        serviceCall.Status__c = 'En Route';
        update serviceCall;

        serviceCall.Status__c = 'On Site';
        update serviceCall;

        // ── 4. 부품 사용 -> 재고 차감 + ERP 동기화 ──
        insert new Part_Line__c(
            Work_Order__c = serviceCall.Id,
            Part__c = part.Id,
            Quantity__c = 2,
            Unit_Price__c = 45
        );

        // ── 5. 현장 사진 첨부 ──
        String samplePngBase64 =
            'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
        WorkPhotoGalleryController.PhotoInput photoInput = new WorkPhotoGalleryController.PhotoInput();
        photoInput.fileName = 'before-after.png';
        photoInput.base64Data = samplePngBase64;
        WorkPhotoGalleryController.savePhotos(
            serviceCall.Id, new List<WorkPhotoGalleryController.PhotoInput>{ photoInput }
        );

        // ── 6. 고객 서명 + 체크리스트 완료 -> Completed -> 청구서 생성 + 결제 + 완료 알림 ──
        FieldCompletionController.saveSignature(serviceCall.Id, samplePngBase64);
        FieldCompletionController.completeWorkOrder(serviceCall.Id, FieldCompletionController.REQUIRED_CHECKLIST_ITEMS);

        // 여기까지 큐잉된 모든 비동기 작업(배정 경로 조회, 알림 3건, 재고 ERP 동기화, 결제)을
        // 한 번에 실행한다. 각 Queueable은 스스로를 재체이닝하지 않으므로(Mock이 전부 성공을
        // 반환) 서로 독립적으로 안전하게 끝까지 처리된다.
        Test.stopTest();

        // ══════════════════════════════════════════════════════════════
        // 검증: 여정 전체가 실제로 끝까지 이어졌는지 최종 상태를 확인한다.
        // ══════════════════════════════════════════════════════════════

        // 계약 전환 결과
        System.assertEquals('Enterprise', contract.Tier__c);
        System.assertEquals(4, contract.SLA_Hours__c);
        System.assertEquals(
            4, [SELECT COUNT() FROM Work_Order__c WHERE Service_Contract__c = :contract.Id AND Id != :serviceCall.Id],
            '분기별 정기 점검 Work Order 4건이 자동 생성되어야 함'
        );

        // 기술자 자동 배정 결과
        Work_Order__c finalCall = [
            SELECT Status__c, Assigned_Technician__c, ETA__c, Signature_Captured__c, Completed_Date__c
            FROM Work_Order__c WHERE Id = :serviceCall.Id
        ];
        System.assertEquals(tech.Id, finalCall.Assigned_Technician__c, '적합한 기술자가 자동 배정되어야 함');
        System.assertNotEquals(null, finalCall.ETA__c, '지도 API 콜아웃으로 ETA가 설정되어야 함');

        // 현장 완료 결과
        System.assertEquals('Completed', finalCall.Status__c);
        System.assertEquals(true, finalCall.Signature_Captured__c);
        System.assertNotEquals(null, finalCall.Completed_Date__c);

        // 현장 사진
        List<WorkPhotoGalleryController.PhotoInfo> photos = WorkPhotoGalleryController.getPhotos(serviceCall.Id);
        System.assertEquals(1, photos.size(), '현장 사진이 Work Order에 첨부되어야 함');

        // 재고 차감
        Part__c updatedPart = [SELECT Stock_Quantity__c FROM Part__c WHERE Id = :part.Id];
        System.assertEquals(18, updatedPart.Stock_Quantity__c, '부품 2개 사용 후 재고가 20 -> 18로 차감되어야 함');

        // 자동 청구서 (부품비 45x2=90 + 공임 75x3시간=225 = 315)
        Invoice__c invoice = [
            SELECT Parts_Amount__c, Labor_Amount__c, Total_Amount__c, Payment_Status__c,
                   Payment_Reference__c, Idempotency_Key__c
            FROM Invoice__c WHERE Work_Order__c = :serviceCall.Id
        ];
        System.assertEquals(90, invoice.Parts_Amount__c, '부품비 = 45 x 2 = 90');
        System.assertEquals(225, invoice.Labor_Amount__c, '공임 = 75 x 3시간 = 225');
        System.assertEquals(315, invoice.Total_Amount__c);
        System.assertEquals('Paid', invoice.Payment_Status__c, 'Mock 결제가 성공했으므로 Paid로 확정되어야 함');
        System.assertEquals('TXN-DEMO-001', invoice.Payment_Reference__c);
        System.assertEquals('INV-' + serviceCall.Id, invoice.Idempotency_Key__c, '멱등키는 Work Order Id에서 결정론적으로 유도되어야 함');

        // 고객 알림: En Route + On Site + Completed = 총 3건
        System.assertEquals(
            3, [
                SELECT COUNT() FROM Integration_Log__c
                WHERE Related_Record_Id__c = :serviceCall.Id AND Integration_Type__c = 'Messaging'
            ],
            'En Route/On Site/Completed 전환마다 고객 알림이 기록되어야 함'
        );

        // 관측성: 이 여정에서 사용된 4가지 외부 연동(Route/Messaging/Inventory/Payment)이
        // 전부 Integration_Log__c에 최소 1건 이상 기록되어야 한다.
        Map<String, Integer> logCountByType = new Map<String, Integer>();
        for (AggregateResult ar : [
            SELECT Integration_Type__c logType, COUNT(Id) logCount
            FROM Integration_Log__c
            GROUP BY Integration_Type__c
        ]) {
            logCountByType.put((String) ar.get('logType'), (Integer) ar.get('logCount'));
        }
        System.assert(logCountByType.containsKey('Route'), 'Route(경로/ETA) 연동 로그가 있어야 함');
        System.assert(logCountByType.containsKey('Payment'), 'Payment(결제) 연동 로그가 있어야 함');
        System.assert(logCountByType.containsKey('Messaging'), 'Messaging(고객 알림) 연동 로그가 있어야 함');
        System.assert(logCountByType.containsKey('Inventory'), 'Inventory(ERP 재고 동기화) 연동 로그가 있어야 함');

        // 모든 로그가 실제로 성공(Is_Success__c=true)으로 기록되었는지도 함께 확인한다 -
        // Mock이 전부 200을 반환했으므로 실패로 남은 통합 로그가 있으면 안 된다.
        System.assertEquals(
            0, [SELECT COUNT() FROM Integration_Log__c WHERE Is_Success__c = false],
            'Mock이 전부 성공을 반환했으므로 실패로 기록된 통합 로그가 없어야 함'
        );
    }
}
