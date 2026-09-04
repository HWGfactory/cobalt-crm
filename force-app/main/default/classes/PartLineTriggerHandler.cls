public with sharing class PartLineTriggerHandler extends TriggerHandler {

    public PartLineTriggerHandler() {
        super('PartLineTriggerHandler');
    }

    protected override void afterInsert(List<SObject> newList, Map<Id, SObject> newMap) {
        try {
            InventoryService.deductStock((List<Part_Line__c>) newList);
        } catch (InventoryService.InsufficientStockException ex) {
            // InventoryService가 이미 문제가 된 Part_Line__c 레코드에 addError()로
            // 사용자에게 표시할 구체적인 메시지를 설정했으므로, 여기서는 전체 트랜잭션이
            // 원시 예외 배너 대신 그 필드 오류로 실패하도록 추가 처리 없이 종료한다.
        }
    }
}
