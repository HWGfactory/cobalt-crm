@IsTest
private class SLACalculatorTest {

    private static Id getDefaultBusinessHoursId() {
        return [SELECT Id FROM BusinessHours WHERE IsDefault = true LIMIT 1].Id;
    }

    @IsTest
    static void testCalculateDeadline_delegatesToBusinessHoursAdd() {
        Id bhId = getDefaultBusinessHoursId();
        Datetime start = Datetime.newInstanceGmt(2026, 9, 2, 17, 0, 0); // 수 10:00 PDT
        Integer slaHours = 4;

        Datetime expected = BusinessHours.add(bhId, start, (Long) slaHours * 3600000L);
        Datetime actual = SLACalculator.calculateDeadline(start, slaHours, bhId);

        System.assertEquals(expected, actual, 'SLACalculator는 BusinessHours.add()에 동일한 결과로 위임해야 함');
    }

    @IsTest
    static void testCalculateDeadline_withinSameBusinessDay() {
        Id bhId = getDefaultBusinessHoursId();
        // 2026-09-02(수) 09:00 PDT = 16:00 UTC
        Datetime start = Datetime.newInstanceGmt(2026, 9, 2, 16, 0, 0);
        System.assert(BusinessHours.isWithin(bhId, start), '테스트 전제: 시작 시각은 영업시간 이내여야 함');

        Datetime deadline = SLACalculator.calculateDeadline(start, 4, bhId);

        // 09:00 + 4h = 13:00 PDT = 20:00 UTC, 당일 내에 마감되어야 함
        Datetime expected = Datetime.newInstanceGmt(2026, 9, 2, 20, 0, 0);
        System.assertEquals(expected, deadline, '영업시간 내에서 끝나는 SLA는 당일 마감이어야 함');
    }

    @IsTest
    static void testCalculateDeadline_rollsOverToNextBusinessDayWithinWeek() {
        Id bhId = getDefaultBusinessHoursId();
        // 2026-09-03(목) 15:00 PDT = 22:00 UTC 접수. 당일 잔여 영업시간은 2시간(15~17시)뿐이라
        // Enterprise 티어 SLA 4시간을 채우려면 다음 영업일(금요일)로 넘어가야 한다.
        Datetime start = Datetime.newInstanceGmt(2026, 9, 3, 22, 0, 0);
        System.assert(BusinessHours.isWithin(bhId, start), '테스트 전제: 시작 시각은 영업시간 이내여야 함');

        Datetime deadline = SLACalculator.calculateDeadline(start, 4, bhId);

        // 목요일 잔여 2h 소진 후 금요일 09:00부터 2h 추가 -> 금요일 11:00 PDT = 18:00 UTC
        Datetime expected = Datetime.newInstanceGmt(2026, 9, 4, 18, 0, 0);
        System.assertEquals(expected, deadline, '당일 잔여 영업시간을 넘는 SLA는 다음 영업일 영업 개시 시각부터 이어서 계산되어야 함');
    }

    @IsTest
    static void testCalculateDeadline_fridayAfternoonSubmissionBoundary() {
        Id bhId = getDefaultBusinessHoursId();
        // 2026-09-04(금) 15:00 PDT = 22:00 UTC 접수, Enterprise 티어 SLA 4시간.
        // 금요일 잔여 영업시간은 2시간뿐이라 마감이 영업시간 외(퇴근 이후)로 그대로 새어나가지 않고
        // 다음 영업 개시 시점부터 이어서 계산되어야 한다.
        // 참고: 이 조직의 Default Business Hours는 평일(월~금) 09:00-17:00으로 구성되어 있다.
        // 토/일을 완전히 휴무로 표시하려면 Setup > Business Hours에서 토/일 체크를 해제해야 하며
        // (Apex/일부 Data API로는 해당 필드를 null로 만들 수 없어 코드로는 강제할 수 없음),
        // 이 테스트는 "영업시간 외 구간은 SLA 시계에서 제외된다"는 핵심 동작을
        // BusinessHours.add()와의 동일 결과 비교로 검증한다.
        Datetime fridayAfternoon = Datetime.newInstanceGmt(2026, 9, 4, 22, 0, 0);
        System.assert(BusinessHours.isWithin(bhId, fridayAfternoon), '테스트 전제: 금요일 접수 시각은 영업시간 이내여야 함');

        Datetime expected = BusinessHours.add(bhId, fridayAfternoon, 4L * 3600000L);
        Datetime actual = SLACalculator.calculateDeadline(fridayAfternoon, 4, bhId);

        System.assertEquals(expected, actual, '금요일 오후 접수 경계 케이스에서도 BusinessHours 계산 결과와 정확히 일치해야 함');
        System.assert(
            actual > fridayAfternoon.addHours(4),
            '잔여 영업시간(2시간)만으로는 SLA를 채울 수 없으므로 단순 달력상 +4시간보다 늦게 마감되어야 함'
        );
    }

    @IsTest
    static void testCalculateDeadline_nullStartThrows() {
        Id bhId = getDefaultBusinessHoursId();
        Boolean threw = false;
        try {
            SLACalculator.calculateDeadline(null, 4, bhId);
        } catch (SLACalculator.SLACalculatorException ex) {
            threw = true;
        }
        System.assert(threw, '시작 시각이 없으면 SLACalculatorException이 발생해야 함');
    }

    @IsTest
    static void testCalculateDeadline_nullSlaHoursThrows() {
        Id bhId = getDefaultBusinessHoursId();
        Boolean threw = false;
        try {
            SLACalculator.calculateDeadline(Datetime.now(), null, bhId);
        } catch (SLACalculator.SLACalculatorException ex) {
            threw = true;
        }
        System.assert(threw, 'SLA 시간이 없으면 SLACalculatorException이 발생해야 함');
    }

    @IsTest
    static void testCalculateDeadline_nullBusinessHoursIdThrows() {
        Boolean threw = false;
        try {
            SLACalculator.calculateDeadline(Datetime.now(), 4, null);
        } catch (SLACalculator.SLACalculatorException ex) {
            threw = true;
        }
        System.assert(threw, 'Business Hours Id가 없으면 SLACalculatorException이 발생해야 함');
    }
}
