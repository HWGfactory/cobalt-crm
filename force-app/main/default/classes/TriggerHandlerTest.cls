@isTest
private class TriggerHandlerTest {

    private class TestHandler extends TriggerHandler {
        public TestHandler() {
            super('TriggerHandlerTest.TestHandler');
        }

        protected override Integer getMaxLoopCount() {
            return 2;
        }
    }

    // getMaxLoopCount()를 오버라이드하지 않아 TriggerHandler의 기본값(5)을 그대로 사용하는 핸들러.
    private class DefaultMaxLoopHandler extends TriggerHandler {
        public DefaultMaxLoopHandler() {
            super('TriggerHandlerTest.DefaultMaxLoopHandler');
        }
    }

    @isTest
    static void testBypassPreventsHandlerFromRunning() {
        String handlerName = 'TriggerHandlerTest.TestHandler';
        System.assertEquals(false, TriggerHandler.isBypassed(handlerName), '기본 상태에서는 bypass되어 있지 않아야 합니다');

        TriggerHandler.bypass(handlerName);
        System.assertEquals(true, TriggerHandler.isBypassed(handlerName), 'bypass 호출 후에는 bypass 상태여야 합니다');

        TriggerHandler.clearBypass(handlerName);
        System.assertEquals(false, TriggerHandler.isBypassed(handlerName), 'clearBypass 호출 후에는 bypass가 해제되어야 합니다');
    }

    @isTest
    static void testClearAllBypassesRemovesEveryEntry() {
        TriggerHandler.bypass('HandlerA');
        TriggerHandler.bypass('HandlerB');

        TriggerHandler.clearAllBypasses();

        System.assertEquals(false, TriggerHandler.isBypassed('HandlerA'), 'clearAllBypasses 후 HandlerA는 bypass 해제되어야 합니다');
        System.assertEquals(false, TriggerHandler.isBypassed('HandlerB'), 'clearAllBypasses 후 HandlerB는 bypass 해제되어야 합니다');
    }

    @isTest
    static void testLoopGuardAllowsExactlyMaxCountThenThrowsOnNextCall() {
        TestHandler handler = new TestHandler();
        String handlerName = 'TriggerHandlerTest.TestHandler';

        // 경계값: maxLoopCount(2)까지는 정상 허용되어야 한다 (예외 없이 통과).
        handler.enforceLoopGuard(handlerName);
        handler.enforceLoopGuard(handlerName);

        // 경계값 초과: maxLoopCount를 넘어서는 (max + 1)번째 호출은 예외를 던져야 한다.
        Boolean exceptionThrown = false;
        try {
            handler.enforceLoopGuard(handlerName);
        } catch (TriggerHandler.TriggerHandlerException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains(handlerName), '예외 메시지에 핸들러 이름이 포함되어야 합니다');
        }
        System.assert(exceptionThrown, '최대 루프 횟수를 초과하면 예외가 발생해야 합니다');
    }

    @isTest
    static void testDefaultMaxLoopCountAllowsExactlyFiveCallsThenThrows() {
        // getMaxLoopCount()를 오버라이드하지 않은 핸들러는 TriggerHandler의
        // 기본값(DEFAULT_MAX_LOOP_COUNT = 5)을 그대로 사용해야 한다.
        DefaultMaxLoopHandler handler = new DefaultMaxLoopHandler();
        String handlerName = 'TriggerHandlerTest.DefaultMaxLoopHandler';

        for (Integer i = 0; i < 5; i++) {
            handler.enforceLoopGuard(handlerName);
        }

        Boolean exceptionThrown = false;
        try {
            handler.enforceLoopGuard(handlerName);
        } catch (TriggerHandler.TriggerHandlerException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('5'), '예외 메시지에 기본 최대 루프 횟수(5)가 포함되어야 합니다');
        }
        System.assert(exceptionThrown, '기본 최대 루프 횟수(5)를 초과하면 예외가 발생해야 합니다');
    }

    @isTest
    static void testRunThrowsOutsideTriggerContext() {
        TestHandler handler = new TestHandler();

        Boolean exceptionThrown = false;
        try {
            handler.run();
        } catch (TriggerHandler.TriggerHandlerException e) {
            exceptionThrown = true;
        }
        System.assert(exceptionThrown, 'Trigger 컨텍스트 밖에서 run()을 호출하면 예외가 발생해야 합니다');
    }

    @isTest
    static void testBypassSkipsRealHandlerLogicDuringTriggerExecution() {
        // 긍정 케이스: bypass 상태에서는 OpportunityTriggerHandler 로직(Pilot 검증)이
        // 아예 실행되지 않으므로, Pilot 없이 Proposal/Negotiation으로 insert해도 성공해야 한다.
        TriggerHandler.bypass('OpportunityTriggerHandler');

        Opportunity bypassedOpp = new Opportunity(
            Name = 'Bypassed Proposal Opp',
            StageName = 'Proposal/Negotiation',
            CloseDate = Date.today().addDays(30)
        );

        Boolean errorThrownWhileBypassed = false;
        try {
            insert bypassedOpp;
        } catch (DmlException e) {
            errorThrownWhileBypassed = true;
        }
        System.assert(!errorThrownWhileBypassed, 'bypass 상태에서는 Pilot 검증 로직이 실행되지 않아야 합니다');

        TriggerHandler.clearBypass('OpportunityTriggerHandler');

        // 부정 케이스: bypass 해제 후에는 동일한 시도가 다시 정상적으로 차단되어야 한다.
        Opportunity notBypassedOpp = new Opportunity(
            Name = 'Not Bypassed Proposal Opp',
            StageName = 'Proposal/Negotiation',
            CloseDate = Date.today().addDays(30)
        );

        Boolean errorThrownAfterClear = false;
        try {
            insert notBypassedOpp;
        } catch (DmlException e) {
            errorThrownAfterClear = true;
            System.assert(e.getMessage().contains('Pilot'), 'bypass 해제 후에는 Pilot 관련 에러가 다시 발생해야 합니다');
        }
        System.assert(errorThrownAfterClear, 'bypass 해제 후에는 Pilot 검증이 다시 정상 동작해야 합니다');
    }
}
