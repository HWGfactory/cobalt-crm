@IsTest
private class WeatherRescheduleServiceTest {

    private class SevereWeatherMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"precipitationProbability":85,"alert":false}');
            return res;
        }
    }

    private class SevereAlertOnlyMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"precipitationProbability":15,"alert":true}');
            return res;
        }
    }

    private class ClearWeatherMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"precipitationProbability":10,"alert":false}');
            return res;
        }
    }

    private class WeatherApiErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(503);
            res.setBody('{"error":"Service Unavailable"}');
            return res;
        }
    }

    private static Work_Order__c createOutdoorWorkOrder(Datetime scheduledDate, Boolean isOutdoor) {
        Account acc = new Account(Name = 'Weather Reschedule Test Account');
        insert acc;
        Contact con = new Contact(LastName = 'WeatherTestCustomer', AccountId = acc.Id, Email = 'weather-test@example.com');
        insert con;
        Service_Contract__c contract = new Service_Contract__c(Account__c = acc.Id);
        insert contract;
        Technician__c tech = new Technician__c(
            Name = 'Weather Test Tech',
            Is_Available__c = true,
            Active_Work_Orders__c = 0,
            Service_Region__c = 'North',
            Phone__c = '555-0100'
        );
        insert tech;
        Work_Order__c wo = new Work_Order__c(
            Service_Contract__c = contract.Id,
            Status__c = 'Assigned',
            Assigned_Technician__c = tech.Id,
            Is_Outdoor__c = isOutdoor,
            Scheduled_Date__c = scheduledDate,
            Service_Location__Latitude__s = 37.5665,
            Service_Location__Longitude__s = 126.9780
        );
        insert wo;
        return wo;
    }

    @IsTest
    static void testExecute_severePrecipitationReschedulesAndNotifies() {
        Datetime tomorrow9am = Datetime.newInstance(Date.today().addDays(1), Time.newInstance(9, 0, 0, 0));
        Work_Order__c wo = createOutdoorWorkOrder(tomorrow9am, true);
        Test.setMock(HttpCalloutMock.class, new SevereWeatherMock());

        Test.startTest();
        Database.executeBatch(new WeatherRescheduleService(), 50);
        Test.stopTest();

        Work_Order__c updated = [
            SELECT Scheduled_Date__c, Reschedule_Reason__c FROM Work_Order__c WHERE Id = :wo.Id
        ];
        System.assertNotEquals(
            tomorrow9am.date(), updated.Scheduled_Date__c.date(),
            '강수확률 70% 이상이면 일정이 다음 가용일로 이동해야 함'
        );
        System.assert(updated.Reschedule_Reason__c.contains('악천후'), '재조정 사유가 기록되어야 함');
        System.assert(updated.Reschedule_Reason__c.contains('85%'), '강수확률 수치가 사유에 포함되어야 함');

        List<Integration_Log__c> weatherLogs = [
            SELECT Is_Success__c FROM Integration_Log__c WHERE Integration_Type__c = 'Weather' AND Related_Record_Id__c = :wo.Id
        ];
        System.assertEquals(1, weatherLogs.size());
        System.assertEquals(true, weatherLogs[0].Is_Success__c);

        List<Integration_Log__c> messagingLogs = [
            SELECT Id FROM Integration_Log__c WHERE Integration_Type__c = 'Messaging' AND Related_Record_Id__c = :wo.Id
        ];
        System.assertEquals(2, messagingLogs.size(), '고객 1건 + 기술자 1건 = 총 2건의 알림이 발송되어야 함');
    }

    @IsTest
    static void testExecute_severeAlertAloneAlsoReschedules() {
        Datetime tomorrow9am = Datetime.newInstance(Date.today().addDays(1), Time.newInstance(9, 0, 0, 0));
        Work_Order__c wo = createOutdoorWorkOrder(tomorrow9am, true);
        Test.setMock(HttpCalloutMock.class, new SevereAlertOnlyMock());

        Test.startTest();
        Database.executeBatch(new WeatherRescheduleService(), 50);
        Test.stopTest();

        Work_Order__c updated = [SELECT Scheduled_Date__c, Reschedule_Reason__c FROM Work_Order__c WHERE Id = :wo.Id];
        System.assertNotEquals(
            tomorrow9am.date(), updated.Scheduled_Date__c.date(),
            '강수확률이 낮아도 경보가 발효되어 있으면 재조정되어야 함'
        );
        System.assert(updated.Reschedule_Reason__c.contains('경보'));
    }

    @IsTest
    static void testExecute_clearWeatherDoesNotReschedule() {
        Datetime tomorrow9am = Datetime.newInstance(Date.today().addDays(1), Time.newInstance(9, 0, 0, 0));
        Work_Order__c wo = createOutdoorWorkOrder(tomorrow9am, true);
        Test.setMock(HttpCalloutMock.class, new ClearWeatherMock());

        Test.startTest();
        Database.executeBatch(new WeatherRescheduleService(), 50);
        Test.stopTest();

        Work_Order__c updated = [SELECT Scheduled_Date__c, Reschedule_Reason__c FROM Work_Order__c WHERE Id = :wo.Id];
        System.assertEquals(tomorrow9am, updated.Scheduled_Date__c, '맑은 날씨면 일정이 변경되지 않아야 함');
        System.assertEquals(null, updated.Reschedule_Reason__c);

        System.assertEquals(
            0, [SELECT COUNT() FROM Integration_Log__c WHERE Integration_Type__c = 'Messaging' AND Related_Record_Id__c = :wo.Id],
            '재조정이 없으면 알림도 발송되지 않아야 함'
        );
    }

    @IsTest
    static void testExecute_nonOutdoorWorkOrderIsNotProcessed() {
        Datetime tomorrow9am = Datetime.newInstance(Date.today().addDays(1), Time.newInstance(9, 0, 0, 0));
        Work_Order__c wo = createOutdoorWorkOrder(tomorrow9am, false);
        Test.setMock(HttpCalloutMock.class, new SevereWeatherMock());

        Test.startTest();
        Database.executeBatch(new WeatherRescheduleService(), 50);
        Test.stopTest();

        Work_Order__c updated = [SELECT Scheduled_Date__c FROM Work_Order__c WHERE Id = :wo.Id];
        System.assertEquals(tomorrow9am, updated.Scheduled_Date__c, '옥외 작업이 아니면 날씨와 무관하게 처리 대상이 아니어야 함');
        System.assertEquals(0, [SELECT COUNT() FROM Integration_Log__c WHERE Related_Record_Id__c = :wo.Id]);
    }

    @IsTest
    static void testExecute_weatherApiFailureLeavesWorkOrderUntouched() {
        Datetime tomorrow9am = Datetime.newInstance(Date.today().addDays(1), Time.newInstance(9, 0, 0, 0));
        Work_Order__c wo = createOutdoorWorkOrder(tomorrow9am, true);
        Test.setMock(HttpCalloutMock.class, new WeatherApiErrorMock());

        Test.startTest();
        Database.executeBatch(new WeatherRescheduleService(), 50);
        Test.stopTest();

        Work_Order__c updated = [SELECT Scheduled_Date__c FROM Work_Order__c WHERE Id = :wo.Id];
        System.assertEquals(
            tomorrow9am, updated.Scheduled_Date__c,
            '날씨 조회 자체가 실패하면 임의로 재조정하지 않고 그대로 두어야 함'
        );

        Integration_Log__c log = [
            SELECT Is_Success__c, Status_Code__c FROM Integration_Log__c WHERE Related_Record_Id__c = :wo.Id
        ];
        System.assertEquals(false, log.Is_Success__c);
        System.assertEquals(503, log.Status_Code__c);
    }

    @IsTest
    static void testExecute_notScheduledForTomorrowIsNotProcessed() {
        Datetime nextWeek = Datetime.newInstance(Date.today().addDays(7), Time.newInstance(9, 0, 0, 0));
        Work_Order__c wo = createOutdoorWorkOrder(nextWeek, true);
        Test.setMock(HttpCalloutMock.class, new SevereWeatherMock());

        Test.startTest();
        Database.executeBatch(new WeatherRescheduleService(), 50);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Integration_Log__c WHERE Related_Record_Id__c = :wo.Id]);
    }

    @IsTest
    static void testNextAvailableDay_skipsWeekend() {
        // 2026-09-04는 금요일 -> 다음 가용일은 주말(5,6일)을 건너뛴 2026-09-07(월요일)이어야 함.
        Date friday = Date.newInstance(2026, 9, 4);
        Date result = WeatherRescheduleService.nextAvailableDay(friday);
        System.assertEquals(Date.newInstance(2026, 9, 7), result);
    }

    @IsTest
    static void testNextAvailableDay_weekdayJustAddsOneDay() {
        // 2026-09-01은 화요일 -> 다음 가용일은 바로 다음날인 수요일.
        Date tuesday = Date.newInstance(2026, 9, 1);
        Date result = WeatherRescheduleService.nextAvailableDay(tuesday);
        System.assertEquals(Date.newInstance(2026, 9, 2), result);
    }

    @IsTest
    static void testSchedulableExecute_launchesBatch() {
        Test.startTest();
        new WeatherRescheduleService().execute(null);
        Test.stopTest();

        List<AsyncApexJob> jobs = [
            SELECT Id FROM AsyncApexJob WHERE ApexClass.Name = 'WeatherRescheduleService' AND JobType = 'BatchApex'
        ];
        System.assert(!jobs.isEmpty(), 'Schedulable 실행 시 배치 잡이 큐잉되어야 함');
    }
}
