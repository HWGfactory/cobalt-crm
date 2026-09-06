public with sharing class WeatherRescheduleService implements Database.Batchable<SObject>, Database.AllowsCallouts, Schedulable {

    private static final String NAMED_CREDENTIAL = 'Cobalt_Weather_API';
    // 이 확률(%) 이상의 강수 예보면 현장 작업 일정을 재조정한다. 아직 실제 운영 기준이
    // 확정되지 않은 잠정값이라 상수로 두었다.
    @TestVisible private static final Decimal PRECIPITATION_THRESHOLD_PCT = 70;
    private static final Set<String> ACTIVE_STATUSES = new Set<String>{
        'New', 'Assigned', 'En Route', 'On Site'
    };

    @TestVisible
    private class WeatherResult {
        public Decimal precipitationProbability;
        public Boolean hasSevereAlert;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, Scheduled_Date__c, Status__c,
                   Service_Location__Latitude__s, Service_Location__Longitude__s
            FROM Work_Order__c
            WHERE Is_Outdoor__c = true
              AND Scheduled_Date__c = TOMORROW
              AND Status__c IN :ACTIVE_STATUSES
        ]);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        List<Work_Order__c> workOrders = (List<Work_Order__c>) scope;
        List<Work_Order__c> toReschedule = new List<Work_Order__c>();
        List<Integration_Log__c> pendingLogs = new List<Integration_Log__c>();
        List<SendCustomerNotification.NotificationRequest> notifications =
            new List<SendCustomerNotification.NotificationRequest>();

        for (Work_Order__c wo : workOrders) {
            if (wo.Scheduled_Date__c == null
                || wo.Service_Location__Latitude__s == null
                || wo.Service_Location__Longitude__s == null) {
                continue;
            }

            WeatherResult weather = checkWeather(
                wo.Service_Location__Latitude__s, wo.Service_Location__Longitude__s, wo.Id, pendingLogs
            );
            if (weather == null) {
                // 조회 자체가 실패한 경우 - 잘못된 정보로 임의 재조정하지 않고 그대로 두어 수동 확인을 유도한다.
                continue;
            }
            if (weather.precipitationProbability < PRECIPITATION_THRESHOLD_PCT && !weather.hasSevereAlert) {
                continue;
            }

            Date oldDate = wo.Scheduled_Date__c.date();
            Date newDate = nextAvailableDay(oldDate);
            Datetime newScheduledDate = Datetime.newInstance(newDate, wo.Scheduled_Date__c.time());

            String reason = '악천후로 인한 자동 재조정 (' + oldDate.format() + ' -> ' + newDate.format() + '): '
                + '강수확률 ' + weather.precipitationProbability + '%'
                + (weather.hasSevereAlert ? ', 기상 경보 발효' : '');

            toReschedule.add(new Work_Order__c(
                Id = wo.Id,
                Scheduled_Date__c = newScheduledDate,
                Reschedule_Reason__c = reason
            ));

            SendCustomerNotification.NotificationRequest request = new SendCustomerNotification.NotificationRequest();
            request.workOrderId = wo.Id;
            request.overrideMessage = '기상 악화로 방문 일정이 ' + newDate.format() + '로 변경되었습니다.';
            request.notifyTechnicianToo = true;
            notifications.add(request);
        }

        if (!pendingLogs.isEmpty()) {
            insert pendingLogs;
        }
        if (!toReschedule.isEmpty()) {
            update toReschedule;
        }
        if (!notifications.isEmpty()) {
            // 배치 execute() 1회당 자동화(재조정 알림)를 위해 기존 Invocable을 1회만 호출한다.
            SendCustomerNotification.sendNotifications(notifications);
        }
    }

    public void finish(Database.BatchableContext bc) {
        // 재조정/알림은 execute()에서 이미 처리됨 - 추가 후처리 없음.
    }

    public void execute(SchedulableContext sc) {
        Database.executeBatch(new WeatherRescheduleService(), 50);
    }

    @TestVisible
    private static WeatherResult checkWeather(
        Decimal latitude, Decimal longitude, Id relatedWorkOrderId, List<Integration_Log__c> pendingLogs
    ) {
        Long startTime = Datetime.now().getTime();
        // TODO: Cobalt Weather 벤더 계약이 확정되면 실제 엔드포인트 경로/응답 스키마로 교체.
        // Named Credential 'Cobalt_Weather_API'가 Setup에 구성되어 있어야 이 콜아웃이 정상 동작함.
        String endpoint = 'callout:' + NAMED_CREDENTIAL + '/forecast?lat=' + latitude + '&lng=' + longitude;

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
        WeatherResult result;

        if (calloutFailure != null) {
            pendingLogs.add(buildLog(endpoint, relatedWorkOrderId, null, null, false, calloutFailure.getMessage(), durationMs));
            return null;
        }

        if (res.getStatusCode() != 200) {
            pendingLogs.add(buildLog(
                endpoint, relatedWorkOrderId, res.getStatusCode(), res.getBody(), false,
                '날씨 API가 실패 상태 코드를 반환했습니다: ' + res.getStatusCode(), durationMs
            ));
            return null;
        }

        try {
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            result = new WeatherResult();
            result.precipitationProbability = parsed.containsKey('precipitationProbability')
                ? (Decimal) parsed.get('precipitationProbability')
                : 0;
            result.hasSevereAlert = parsed.containsKey('alert') ? (Boolean) parsed.get('alert') : false;
        } catch (Exception parseEx) {
            pendingLogs.add(buildLog(
                endpoint, relatedWorkOrderId, res.getStatusCode(), res.getBody(), false,
                '응답 파싱 실패: ' + parseEx.getMessage(), durationMs
            ));
            return null;
        }

        pendingLogs.add(buildLog(endpoint, relatedWorkOrderId, res.getStatusCode(), res.getBody(), true, null, durationMs));
        return result;
    }

    private static Integration_Log__c buildLog(
        String endpoint, Id relatedRecordId, Integer statusCode, String responseBody,
        Boolean isSuccess, String errorMessage, Long durationMs
    ) {
        return new Integration_Log__c(
            Integration_Type__c = 'Weather',
            Related_Record_Id__c = relatedRecordId,
            Endpoint__c = endpoint,
            Response_Body__c = responseBody,
            Status_Code__c = statusCode,
            Is_Success__c = isSuccess,
            Error_Message__c = errorMessage,
            Duration_Ms__c = durationMs
        );
    }

    // "다음 가용일" = 다음 영업일(토/일 제외). 재조정 시점에 해당 날짜의 날씨까지 재귀적으로
    // 확인하려면 매번 추가 콜아웃이 필요해 무한정 늘어날 수 있으므로, 이 배치의 범위는
    // "주말이 아닌 다음 날"로 단순화했다 - 필요 시 이 메서드만 확장하면 된다.
    @TestVisible
    private static Date nextAvailableDay(Date fromDate) {
        Date candidate = fromDate.addDays(1);
        while (isWeekend(candidate)) {
            candidate = candidate.addDays(1);
        }
        return candidate;
    }

    // Datetime.newInstance(Date, Time)는 로컬 시간대로 생성되는데 이를 formatGmt()로 포맷하면
    // 시간대 오프셋만큼 요일이 어긋날 수 있어(예: UTC+9에서 자정 인스턴스를 GMT로 보면 전날),
    // 시간대와 무관하게 정확한 순수 Date 산술로 요일을 계산한다.
    private static Boolean isWeekend(Date d) {
        Date knownSaturday = Date.newInstance(2026, 9, 5);
        Integer diffDays = knownSaturday.daysBetween(d);
        Integer dayOffset = Math.mod(diffDays + 70000, 7); // 70000은 7의 배수라 나머지에 영향 없이 음수 입력을 방지
        return dayOffset == 0 || dayOffset == 1; // Saturday(0) 또는 Sunday(1)
    }
}
