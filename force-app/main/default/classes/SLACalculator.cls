public with sharing class SLACalculator {

    public class SLACalculatorException extends Exception {}

    public static Datetime calculateDeadline(Datetime startDateTime, Integer slaHours, Id businessHoursId) {
        if (startDateTime == null || slaHours == null) {
            throw new SLACalculatorException('시작 시각(startDateTime)과 SLA 시간(slaHours)은 필수입니다.');
        }
        if (businessHoursId == null) {
            throw new SLACalculatorException(
                'Business Hours Id가 필요합니다. 조직에 활성화된 Business Hours 레코드가 있는지 확인하세요.'
            );
        }

        Long slaMilliseconds = (Long) slaHours * 3600000L;
        return BusinessHours.add(businessHoursId, startDateTime, slaMilliseconds);
    }
}
