public with sharing class RouteCalloutService implements Queueable, Database.AllowsCallouts {

    public class PendingLookup {
        public Id workOrderId;
        public Id technicianId;
        public Decimal originLatitude;
        public Decimal originLongitude;
        public Decimal destinationLatitude;
        public Decimal destinationLongitude;
        public Decimal skillMatchPercent;
        public Decimal workloadPercent;
    }

    @TestVisible
    private class RouteResult {
        public Decimal distanceKm;
        public Decimal etaMinutes;
    }

    private class ScoredCandidate {
        Id technicianId;
        Decimal etaMinutes;
        Decimal totalScore;
    }

    public class RouteParseException extends Exception {}
    public class RouteCalloutException extends Exception {}

    // 배정 스코어링 가중치(합이 1이 되도록 맞춰져 있음). 실제 배정 결과를 보면서 튜닝할
    // 값이라 상수로 남겨뒀다. 다른 클래스에 같은 값을 복제하지 말고 이 파일에서만 관리한다.
    private static final Decimal WEIGHT_DISTANCE = 0.4;
    private static final Decimal WEIGHT_SKILL = 0.3;
    private static final Decimal WEIGHT_WORKLOAD = 0.3;
    private static final Decimal MAX_SEARCH_RADIUS_KM = 100;
    private static final String NAMED_CREDENTIAL = 'Cobalt_Route_API';

    private final List<PendingLookup> lookups;
    private final Boolean etaOnlyMode;

    public RouteCalloutService(List<PendingLookup> lookups) {
        this.lookups = lookups;
        this.etaOnlyMode = false;
    }

    private RouteCalloutService(List<PendingLookup> lookups, Boolean etaOnlyMode) {
        this.lookups = lookups;
        this.etaOnlyMode = etaOnlyMode;
    }

    // 기술자 배정과 무관하게, 이미 배정된 특정 기술자↔작업 쌍의 실시간 ETA만 새로고침하는 진입점.
    // (자동 배정 엔진의 벌크 스코어링 경로는 System.enqueueJob(new RouteCalloutService(pendingLookups))를 그대로 사용)
    public static void getRouteInfo(Id workOrderId, Id technicianId) {
        if (workOrderId == null || technicianId == null) {
            throw new RouteCalloutException('workOrderId와 technicianId가 모두 필요합니다.');
        }

        List<Work_Order__c> workOrders = [
            SELECT Id, Service_Location__Latitude__s, Service_Location__Longitude__s
            FROM Work_Order__c
            WHERE Id = :workOrderId
            WITH USER_MODE
            LIMIT 1
        ];
        if (workOrders.isEmpty()) {
            throw new RouteCalloutException('작업(Work_Order__c)을 찾을 수 없습니다: ' + workOrderId);
        }

        List<Technician__c> technicians = [
            SELECT Id, Base_Location__Latitude__s, Base_Location__Longitude__s
            FROM Technician__c
            WHERE Id = :technicianId
            WITH USER_MODE
            LIMIT 1
        ];
        if (technicians.isEmpty()) {
            throw new RouteCalloutException('기술자(Technician__c)를 찾을 수 없습니다: ' + technicianId);
        }

        PendingLookup lookup = new PendingLookup();
        lookup.workOrderId = workOrderId;
        lookup.technicianId = technicianId;
        lookup.originLatitude = technicians[0].Base_Location__Latitude__s;
        lookup.originLongitude = technicians[0].Base_Location__Longitude__s;
        lookup.destinationLatitude = workOrders[0].Service_Location__Latitude__s;
        lookup.destinationLongitude = workOrders[0].Service_Location__Longitude__s;
        lookup.skillMatchPercent = 100;
        lookup.workloadPercent = 100;

        System.enqueueJob(new RouteCalloutService(new List<PendingLookup>{ lookup }, true));
    }

    public void execute(QueueableContext context) {
        if (etaOnlyMode) {
            executeEtaRefresh();
        } else {
            executeAssignmentScoring();
        }
    }

    // ETA 전용 모드: 이미 배정된 기술자의 ETA__c만 갱신한다(재배정/상태 변경 없음).
    // 지도 API 실패는 strict=true로 RouteCalloutException을 발생시키며, 항목별로 흡수해
    // 다른 lookup의 처리를 막지 않는다 - 실패는 Integration_Log__c에 이미 기록되어 있다.
    private void executeEtaRefresh() {
        List<Work_Order__c> updates = new List<Work_Order__c>();
        List<Integration_Log__c> pendingLogs = new List<Integration_Log__c>();

        for (PendingLookup lookup : lookups) {
            try {
                RouteResult route = performCalculatedRoute(
                    lookup.originLatitude, lookup.originLongitude,
                    lookup.destinationLatitude, lookup.destinationLongitude,
                    lookup.workOrderId, true, pendingLogs
                );
                Integer etaMinutesInt = route.etaMinutes == null ? 0 : Integer.valueOf(route.etaMinutes);
                updates.add(new Work_Order__c(
                    Id = lookup.workOrderId,
                    ETA__c = Datetime.now().addMinutes(etaMinutesInt)
                ));
            } catch (RouteCalloutException routeEx) {
                // 이미 pendingLogs에 실패로 기록되었음 - 이 작업의 ETA는 갱신하지 않고 계속 진행.
                continue;
            }
        }

        if (!pendingLogs.isEmpty()) {
            insert pendingLogs;
        }
        if (!updates.isEmpty()) {
            update updates;
        }
    }

    private void executeAssignmentScoring() {
        Map<Id, List<ScoredCandidate>> scoredByWorkOrder = new Map<Id, List<ScoredCandidate>>();
        List<Integration_Log__c> pendingLogs = new List<Integration_Log__c>();

        for (PendingLookup lookup : lookups) {
            RouteResult route = performCalculatedRoute(
                lookup.originLatitude, lookup.originLongitude,
                lookup.destinationLatitude, lookup.destinationLongitude,
                lookup.workOrderId, false, pendingLogs
            );

            Decimal distanceScore = 100 - Math.min(100, (route.distanceKm / MAX_SEARCH_RADIUS_KM) * 100);
            Decimal totalScore = (distanceScore * WEIGHT_DISTANCE)
                                + (lookup.skillMatchPercent * WEIGHT_SKILL)
                                + (lookup.workloadPercent * WEIGHT_WORKLOAD);

            ScoredCandidate scored = new ScoredCandidate();
            scored.technicianId = lookup.technicianId;
            scored.etaMinutes = route.etaMinutes;
            scored.totalScore = totalScore;

            if (!scoredByWorkOrder.containsKey(lookup.workOrderId)) {
                scoredByWorkOrder.put(lookup.workOrderId, new List<ScoredCandidate>());
            }
            scoredByWorkOrder.get(lookup.workOrderId).add(scored);
        }

        if (!pendingLogs.isEmpty()) {
            insert pendingLogs;
        }

        // 이 콜아웃은 배정 시점 이후 비동기로 완료되므로, 그 사이 기술자가 이미 작업을
        // En Route/On Site/Completed 등으로 진행시켰을 수 있다. 그런 경우 여기서 뒤늦게
        // Status__c='Assigned'로 덮어써 진행 상태를 되돌리면 안 되므로, 실행 시점의 실제
        // 상태를 재조회해 아직 'New'인 작업에만 배정 결과를 반영한다.
        Map<Id, Work_Order__c> currentWorkOrders = new Map<Id, Work_Order__c>([
            SELECT Id, Status__c FROM Work_Order__c WHERE Id IN :scoredByWorkOrder.keySet()
        ]);

        List<Work_Order__c> updates = new List<Work_Order__c>();
        for (Id workOrderId : scoredByWorkOrder.keySet()) {
            ScoredCandidate best = pickBest(scoredByWorkOrder.get(workOrderId));
            if (best == null) {
                continue;
            }
            Work_Order__c current = currentWorkOrders.get(workOrderId);
            if (current == null || current.Status__c != 'New') {
                continue;
            }
            Integer etaMinutesInt = best.etaMinutes == null ? 0 : Integer.valueOf(best.etaMinutes);
            updates.add(new Work_Order__c(
                Id = workOrderId,
                Assigned_Technician__c = best.technicianId,
                Status__c = 'Assigned',
                ETA__c = Datetime.now().addMinutes(etaMinutesInt)
            ));
        }
        if (!updates.isEmpty()) {
            update updates;
        }
    }

    private static ScoredCandidate pickBest(List<ScoredCandidate> candidates) {
        ScoredCandidate best = null;
        for (ScoredCandidate candidate : candidates) {
            if (best == null
                || candidate.totalScore > best.totalScore
                || (candidate.totalScore == best.totalScore
                    && String.valueOf(candidate.technicianId) < String.valueOf(best.technicianId))) {
                best = candidate;
            }
        }
        return best;
    }

    // 하위 호환용 얇은 래퍼: 단건 호출이므로 로그도 그 자리에서 바로 삽입한다.
    // (벌크 경로는 executeEtaRefresh/executeAssignmentScoring에서 로그를 모아 한 번에 삽입함)
    @TestVisible
    private static RouteResult calculateRoute(Decimal originLat, Decimal originLng, Decimal destLat, Decimal destLng) {
        List<Integration_Log__c> logs = new List<Integration_Log__c>();
        RouteResult result = performCalculatedRoute(originLat, originLng, destLat, destLng, null, false, logs);
        if (!logs.isEmpty()) {
            insert logs;
        }
        return result;
    }

    // 실제 콜아웃 + 파싱을 담당하는 핵심 메서드. Integration_Log__c 레코드는 즉시 insert하지 않고
    // pendingLogs에 담아두었다가 호출부(벌크 루프)에서 한 번에 insert해 DML 문 수를 일정하게 유지한다.
    // strict=false(내부 스코어링용): 실패 시 Haversine 추정치로 조용히 대체.
    // strict=true(getRouteInfo 등 명시적 조회용): 실패 시 RouteCalloutException으로 감싸서 던짐.
    @TestVisible
    private static RouteResult performCalculatedRoute(
        Decimal originLat, Decimal originLng, Decimal destLat, Decimal destLng,
        Id relatedWorkOrderId, Boolean strict, List<Integration_Log__c> pendingLogs
    ) {
        Long startTime = Datetime.now().getTime();
        // TODO: Cobalt_Route_API 벤더 계약이 확정되면 실제 엔드포인트 경로/인증 방식으로 교체.
        // Named Credential 'Cobalt_Route_API'가 Setup에 구성되어 있어야 이 콜아웃이 정상 동작함.
        String endpoint = 'callout:' + NAMED_CREDENTIAL + '/route?origin=' + originLat + ',' + originLng
            + '&destination=' + destLat + ',' + destLng;

        HttpResponse res;
        Exception calloutFailure;
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setMethod('GET');
            req.setTimeout(10000);
            Http http = new Http();
            res = http.send(req);
        } catch (Exception ex) {
            calloutFailure = ex;
        }

        Long durationMs = Datetime.now().getTime() - startTime;

        if (calloutFailure != null) {
            // Named Credential 미구성, 타임아웃, 네트워크 오류 등 콜아웃 자체가 실패한 경우.
            pendingLogs.add(buildLog(endpoint, relatedWorkOrderId, null, null, false, calloutFailure.getMessage(), durationMs));
            if (strict) {
                throw new RouteCalloutException('지도 API 호출 중 오류가 발생했습니다: ' + calloutFailure.getMessage());
            }
            return estimateRouteByHaversine(originLat, originLng, destLat, destLng);
        }

        if (res.getStatusCode() != 200) {
            pendingLogs.add(buildLog(
                endpoint, relatedWorkOrderId, res.getStatusCode(), res.getBody(), false,
                '지도 API가 실패 상태 코드를 반환했습니다: ' + res.getStatusCode(), durationMs
            ));
            if (strict) {
                throw new RouteCalloutException('지도 API가 실패 상태 코드를 반환했습니다: ' + res.getStatusCode());
            }
            return estimateRouteByHaversine(originLat, originLng, destLat, destLng);
        }

        RouteResult result;
        try {
            result = parseRouteResponse(res.getBody());
        } catch (RouteParseException parseEx) {
            pendingLogs.add(buildLog(
                endpoint, relatedWorkOrderId, res.getStatusCode(), res.getBody(), false,
                '응답 파싱 실패: ' + parseEx.getMessage(), durationMs
            ));
            if (strict) {
                throw new RouteCalloutException('지도 API 응답을 파싱할 수 없습니다: ' + parseEx.getMessage());
            }
            return estimateRouteByHaversine(originLat, originLng, destLat, destLng);
        }

        pendingLogs.add(buildLog(endpoint, relatedWorkOrderId, res.getStatusCode(), res.getBody(), true, null, durationMs));
        return result;
    }

    private static Integration_Log__c buildLog(
        String endpoint, Id relatedRecordId, Integer statusCode, String responseBody,
        Boolean isSuccess, String errorMessage, Long durationMs
    ) {
        return new Integration_Log__c(
            Integration_Type__c = 'Route',
            Related_Record_Id__c = relatedRecordId,
            Endpoint__c = endpoint,
            Response_Body__c = responseBody,
            Status_Code__c = statusCode,
            Is_Success__c = isSuccess,
            Error_Message__c = errorMessage,
            Duration_Ms__c = durationMs
        );
    }

    @TestVisible
    private static RouteResult parseRouteResponse(String jsonBody) {
        Map<String, Object> parsed;
        try {
            parsed = (Map<String, Object>) JSON.deserializeUntyped(jsonBody);
        } catch (Exception ex) {
            throw new RouteParseException('지도 API 응답이 유효한 JSON이 아닙니다: ' + ex.getMessage());
        }

        RouteResult result = new RouteResult();
        result.distanceKm = parsed.containsKey('distanceKm') ? (Decimal) parsed.get('distanceKm') : null;
        result.etaMinutes = parsed.containsKey('etaMinutes') ? (Decimal) parsed.get('etaMinutes') : null;
        if (result.distanceKm == null || result.etaMinutes == null) {
            throw new RouteParseException('지도 API 응답에 distanceKm/etaMinutes 필드가 없습니다: ' + jsonBody);
        }
        return result;
    }

    @TestVisible
    private static RouteResult estimateRouteByHaversine(Decimal lat1, Decimal lng1, Decimal lat2, Decimal lng2) {
        RouteResult result = new RouteResult();
        if (lat1 == null || lng1 == null || lat2 == null || lng2 == null) {
            result.distanceKm = 9999;
            result.etaMinutes = 999;
            return result;
        }

        Double earthRadiusKm = 6371.0;
        Double dLat = toRadians((lat2 - lat1).doubleValue());
        Double dLng = toRadians((lng2 - lng1).doubleValue());
        Double a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
                 + Math.cos(toRadians(lat1.doubleValue())) * Math.cos(toRadians(lat2.doubleValue()))
                 * Math.sin(dLng / 2) * Math.sin(dLng / 2);
        Double c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
        Double distanceKm = earthRadiusKm * c;

        result.distanceKm = Decimal.valueOf(distanceKm).setScale(2);
        // 현장 평균 이동 속도 40km/h 가정한 대략적 ETA 추정치.
        Double etaMinutesDouble = (distanceKm / 40.0) * 60.0;
        result.etaMinutes = Decimal.valueOf(etaMinutesDouble).setScale(0);
        return result;
    }

    private static Double toRadians(Double degrees) {
        return degrees * (Math.PI / 180.0);
    }
}
