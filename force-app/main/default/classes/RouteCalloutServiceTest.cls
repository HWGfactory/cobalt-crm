@IsTest
private class RouteCalloutServiceTest {

    private class SuccessRouteMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"distanceKm":12.5,"etaMinutes":18}');
            return res;
        }
    }

    private class ServerErrorRouteMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('{"error":"Internal Server Error"}');
            return res;
        }
    }

    private class InvalidJsonRouteMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('this is not valid json {{{');
            return res;
        }
    }

    private static Work_Order__c createWorkOrderForRoute() {
        Account acc = new Account(Name = 'GetRouteInfo Test Account');
        insert acc;
        Service_Contract__c contract = new Service_Contract__c(Account__c = acc.Id);
        insert contract;
        Work_Order__c wo = new Work_Order__c(
            Service_Contract__c = contract.Id,
            Status__c = 'Assigned',
            Service_Location__Latitude__s = 37.5651,
            Service_Location__Longitude__s = 126.9895
        );
        insert wo;
        return wo;
    }

    private static Technician__c createTechnicianForRoute() {
        Technician__c tech = new Technician__c(
            Name = 'GetRouteInfo Test Tech',
            Is_Available__c = true,
            Active_Work_Orders__c = 0,
            Base_Location__Latitude__s = 37.5665,
            Base_Location__Longitude__s = 126.9780
        );
        insert tech;
        return tech;
    }

    @IsTest
    static void testParseRouteResponse_success() {
        RouteCalloutService.RouteResult result = RouteCalloutService.parseRouteResponse(
            '{"distanceKm":12.5,"etaMinutes":18}'
        );
        System.assertEquals(12.5, result.distanceKm);
        System.assertEquals(18, result.etaMinutes);
    }

    @IsTest
    static void testParseRouteResponse_missingFieldsThrows() {
        Boolean threw = false;
        try {
            RouteCalloutService.parseRouteResponse('{"foo":"bar"}');
        } catch (RouteCalloutService.RouteParseException ex) {
            threw = true;
        }
        System.assert(threw, 'distanceKm/etaMinutes 누락 시 RouteParseException이 발생해야 함');
    }

    @IsTest
    static void testEstimateRouteByHaversine_knownPoints() {
        RouteCalloutService.RouteResult result = RouteCalloutService.estimateRouteByHaversine(
            37.5665, 126.9780, 35.1796, 129.0756
        );
        System.assert(
            result.distanceKm > 300 && result.distanceKm < 400,
            '서울-부산 대권거리 추정값이 합리적 범위여야 함: ' + result.distanceKm
        );
        System.assert(result.etaMinutes > 0);
    }

    @IsTest
    static void testEstimateRouteByHaversine_nullCoordinatesReturnsSentinel() {
        RouteCalloutService.RouteResult result = RouteCalloutService.estimateRouteByHaversine(
            null, null, 35.0, 129.0
        );
        System.assertEquals(9999, result.distanceKm);
    }

    @IsTest
    static void testCalculateRoute_fallsBackToHaversineWhenNamedCredentialMissing() {
        Test.setMock(HttpCalloutMock.class, new SuccessRouteMock());

        Test.startTest();
        RouteCalloutService.RouteResult result = RouteCalloutService.calculateRoute(
            37.5665, 126.9780, 37.5651, 126.9895
        );
        Test.stopTest();

        System.assertNotEquals(null, result.distanceKm);
        System.assertNotEquals(null, result.etaMinutes);
    }

    @IsTest
    static void testExecute_assignsBestScoredCandidateAndSetsEta() {
        Account acc = new Account(Name = 'RouteCallout Test Account');
        insert acc;
        Service_Contract__c contract = new Service_Contract__c(Account__c = acc.Id);
        insert contract;

        Work_Order__c wo = new Work_Order__c(
            Service_Contract__c = contract.Id,
            Status__c = 'New',
            Required_Skill__c = 'HVAC',
            Service_Region__c = 'North',
            Service_Location__Latitude__s = 37.5651,
            Service_Location__Longitude__s = 126.9895
        );
        insert wo;

        Technician__c tech = new Technician__c(
            Name = 'Route Tech',
            Skills__c = 'HVAC',
            Service_Region__c = 'North',
            Is_Available__c = true,
            Active_Work_Orders__c = 0,
            Base_Location__Latitude__s = 37.5665,
            Base_Location__Longitude__s = 126.9780
        );
        insert tech;

        RouteCalloutService.PendingLookup lookup = new RouteCalloutService.PendingLookup();
        lookup.workOrderId = wo.Id;
        lookup.technicianId = tech.Id;
        lookup.originLatitude = 37.5665;
        lookup.originLongitude = 126.9780;
        lookup.destinationLatitude = 37.5651;
        lookup.destinationLongitude = 126.9895;
        lookup.skillMatchPercent = 100;
        lookup.workloadPercent = 100;

        Test.startTest();
        System.enqueueJob(new RouteCalloutService(new List<RouteCalloutService.PendingLookup>{ lookup }));
        Test.stopTest();

        Work_Order__c updated = [
            SELECT Status__c, Assigned_Technician__c, ETA__c FROM Work_Order__c WHERE Id = :wo.Id
        ];
        System.assertEquals('Assigned', updated.Status__c);
        System.assertEquals(tech.Id, updated.Assigned_Technician__c);
        System.assertNotEquals(null, updated.ETA__c);
    }

    @IsTest
    static void testGetRouteInfo_successMockUpdatesEtaAndLogsSuccess() {
        Work_Order__c wo = createWorkOrderForRoute();
        Technician__c tech = createTechnicianForRoute();
        Test.setMock(HttpCalloutMock.class, new SuccessRouteMock());

        Datetime beforeCall = Datetime.now();
        Test.startTest();
        RouteCalloutService.getRouteInfo(wo.Id, tech.Id);
        Test.stopTest();

        List<Integration_Log__c> logs = [
            SELECT Is_Success__c, Status_Code__c, Response_Body__c, Error_Message__c
            FROM Integration_Log__c
            WHERE Integration_Type__c = 'Route' AND Related_Record_Id__c = :wo.Id
        ];
        System.assertEquals(1, logs.size(), 'getRouteInfo 호출 1건당 Integration_Log__c가 1건 기록되어야 함');
        System.assertEquals(true, logs[0].Is_Success__c);
        System.assertEquals(200, logs[0].Status_Code__c);
        System.assertEquals(null, logs[0].Error_Message__c);
        System.assert(logs[0].Response_Body__c.contains('distanceKm'));

        Work_Order__c updated = [SELECT ETA__c FROM Work_Order__c WHERE Id = :wo.Id];
        System.assertNotEquals(null, updated.ETA__c, '정상 응답 시 ETA__c가 갱신되어야 함');
        // Mock 응답의 etaMinutes=18을 반영해 호출 시점 기준 대략 18분 뒤여야 함(±5분 허용오차).
        System.assert(
            updated.ETA__c >= beforeCall.addMinutes(13) && updated.ETA__c <= beforeCall.addMinutes(23),
            'ETA__c가 응답의 etaMinutes(18분)만큼 미래여야 함: ' + updated.ETA__c
        );
    }

    @IsTest
    static void testGetRouteInfo_serverErrorDoesNotUpdateEtaAndLogsFailure() {
        Work_Order__c wo = createWorkOrderForRoute();
        Technician__c tech = createTechnicianForRoute();
        Test.setMock(HttpCalloutMock.class, new ServerErrorRouteMock());

        Test.startTest();
        RouteCalloutService.getRouteInfo(wo.Id, tech.Id);
        Test.stopTest();

        List<Integration_Log__c> logs = [
            SELECT Is_Success__c, Status_Code__c, Error_Message__c
            FROM Integration_Log__c
            WHERE Integration_Type__c = 'Route' AND Related_Record_Id__c = :wo.Id
        ];
        System.assertEquals(1, logs.size());
        System.assertEquals(false, logs[0].Is_Success__c);
        System.assertEquals(500, logs[0].Status_Code__c);
        System.assert(logs[0].Error_Message__c.contains('500'));

        Work_Order__c updated = [SELECT ETA__c FROM Work_Order__c WHERE Id = :wo.Id];
        System.assertEquals(null, updated.ETA__c, '500 에러 시 ETA__c는 갱신되지 않아야 함');
    }

    @IsTest
    static void testGetRouteInfo_invalidJsonDoesNotUpdateEtaAndLogsFailure() {
        Work_Order__c wo = createWorkOrderForRoute();
        Technician__c tech = createTechnicianForRoute();
        Test.setMock(HttpCalloutMock.class, new InvalidJsonRouteMock());

        Test.startTest();
        RouteCalloutService.getRouteInfo(wo.Id, tech.Id);
        Test.stopTest();

        List<Integration_Log__c> logs = [
            SELECT Is_Success__c, Status_Code__c, Error_Message__c
            FROM Integration_Log__c
            WHERE Integration_Type__c = 'Route' AND Related_Record_Id__c = :wo.Id
        ];
        System.assertEquals(1, logs.size());
        System.assertEquals(false, logs[0].Is_Success__c);
        System.assertEquals(200, logs[0].Status_Code__c, '상태 코드는 200이지만 본문 파싱이 실패한 케이스여야 함');
        System.assert(
            logs[0].Error_Message__c.contains('파싱') || logs[0].Error_Message__c.contains('JSON'),
            '파싱 실패 사유가 에러 메시지에 남아야 함: ' + logs[0].Error_Message__c
        );

        Work_Order__c updated = [SELECT ETA__c FROM Work_Order__c WHERE Id = :wo.Id];
        System.assertEquals(null, updated.ETA__c, '잘못된 JSON 응답 시 ETA__c는 갱신되지 않아야 함');
    }

    @IsTest
    static void testGetRouteInfo_missingWorkOrderThrows() {
        Technician__c tech = createTechnicianForRoute();
        Boolean threw = false;
        Test.startTest();
        try {
            RouteCalloutService.getRouteInfo(null, tech.Id);
        } catch (RouteCalloutService.RouteCalloutException ex) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'workOrderId가 없으면 RouteCalloutException이 발생해야 함');
    }

    @IsTest
    static void testGetRouteInfo_missingTechnicianThrows() {
        Work_Order__c wo = createWorkOrderForRoute();
        Boolean threw = false;
        Test.startTest();
        try {
            RouteCalloutService.getRouteInfo(wo.Id, null);
        } catch (RouteCalloutService.RouteCalloutException ex) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'technicianId가 없으면 RouteCalloutException이 발생해야 함');
    }
}
