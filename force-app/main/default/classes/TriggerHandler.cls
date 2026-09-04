public virtual class TriggerHandler {

    private static final Integer DEFAULT_MAX_LOOP_COUNT = 5;

    @TestVisible
    private static Set<String> bypassedHandlers = new Set<String>();

    @TestVisible
    private static Map<String, Integer> executionCounts = new Map<String, Integer>();

    private final String handlerName;

    protected TriggerHandler(String handlerName) {
        this.handlerName = handlerName;
    }

    public void run() {
        if (!Trigger.isExecuting) {
            throw new TriggerHandlerException(handlerName + ' must be invoked from trigger context.');
        }

        if (isBypassed(handlerName)) {
            return;
        }

        enforceLoopGuard(handlerName);

        if (Trigger.isBefore) {
            if (Trigger.isInsert) {
                beforeInsert(Trigger.new);
            } else if (Trigger.isUpdate) {
                beforeUpdate(Trigger.new, Trigger.oldMap);
            } else if (Trigger.isDelete) {
                beforeDelete(Trigger.old);
            }
        } else if (Trigger.isAfter) {
            if (Trigger.isInsert) {
                afterInsert(Trigger.new, Trigger.newMap);
            } else if (Trigger.isUpdate) {
                afterUpdate(Trigger.new, Trigger.newMap, Trigger.oldMap);
            } else if (Trigger.isDelete) {
                afterDelete(Trigger.old, Trigger.oldMap);
            } else if (Trigger.isUndelete) {
                afterUndelete(Trigger.new, Trigger.newMap);
            }
        }
    }

    public static void bypass(String handlerName) {
        bypassedHandlers.add(handlerName);
    }

    public static void clearBypass(String handlerName) {
        bypassedHandlers.remove(handlerName);
    }

    public static Boolean isBypassed(String handlerName) {
        return bypassedHandlers.contains(handlerName);
    }

    public static void clearAllBypasses() {
        bypassedHandlers.clear();
    }

    @TestVisible
    private void enforceLoopGuard(String handlerName) {
        Integer count = executionCounts.containsKey(handlerName) ? executionCounts.get(handlerName) + 1 : 1;
        executionCounts.put(handlerName, count);

        Integer maxLoopCount = getMaxLoopCount();
        if (count > maxLoopCount) {
            throw new TriggerHandlerException(
                handlerName + ' exceeded the maximum trigger loop count of ' + maxLoopCount +
                '. This usually indicates recursive DML inside the handler.'
            );
        }
    }

    protected virtual Integer getMaxLoopCount() {
        return DEFAULT_MAX_LOOP_COUNT;
    }

    protected virtual void beforeInsert(List<SObject> newList) {}
    protected virtual void beforeUpdate(List<SObject> newList, Map<Id, SObject> oldMap) {}
    protected virtual void beforeDelete(List<SObject> oldList) {}
    protected virtual void afterInsert(List<SObject> newList, Map<Id, SObject> newMap) {}
    protected virtual void afterUpdate(List<SObject> newList, Map<Id, SObject> newMap, Map<Id, SObject> oldMap) {}
    protected virtual void afterDelete(List<SObject> oldList, Map<Id, SObject> oldMap) {}
    protected virtual void afterUndelete(List<SObject> newList, Map<Id, SObject> newMap) {}

    public class TriggerHandlerException extends Exception {}
}
