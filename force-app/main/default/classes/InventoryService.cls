public with sharing class InventoryService {

    public class InsufficientStockException extends Exception {}

    @TestVisible
    private static List<Database.SaveResult> lastReorderPublishResults;

    public static void deductStock(List<Part_Line__c> partLines) {
        if (partLines == null || partLines.isEmpty()) {
            return;
        }

        Boolean hasBlockingError = false;
        Map<Id, List<Part_Line__c>> linesByPartId = new Map<Id, List<Part_Line__c>>();

        for (Part_Line__c line : partLines) {
            if (line.Part__c == null) {
                line.addError('부품(Part)이 지정되지 않은 라인은 재고를 차감할 수 없습니다.');
                hasBlockingError = true;
            } else if (line.Quantity__c == null || line.Quantity__c <= 0) {
                line.addError('사용 수량(Quantity)은 0보다 큰 값이어야 합니다.');
                hasBlockingError = true;
            } else {
                if (!linesByPartId.containsKey(line.Part__c)) {
                    linesByPartId.put(line.Part__c, new List<Part_Line__c>());
                }
                linesByPartId.get(line.Part__c).add(line);
            }
        }

        List<Part__c> partsToUpdate = new List<Part__c>();
        List<Part_Reorder__e> reorderEvents = new List<Part_Reorder__e>();
        List<ERPInventorySyncService.SyncPayload> erpSyncPayloads = new List<ERPInventorySyncService.SyncPayload>();

        if (!linesByPartId.isEmpty()) {
            // 동시성 안전: 관련 Part__c 행을 잠근 뒤(FOR UPDATE) 재고를 검증하고 차감한다.
            Map<Id, Part__c> lockedParts = new Map<Id, Part__c>([
                SELECT Id, Name, SKU__c, Stock_Quantity__c, Reorder_Point__c, Warehouse__c
                FROM Part__c
                WHERE Id IN :linesByPartId.keySet()
                FOR UPDATE
            ]);

            for (Id partId : linesByPartId.keySet()) {
                List<Part_Line__c> linesForPart = linesByPartId.get(partId);
                Part__c part = lockedParts.get(partId);

                if (part == null) {
                    for (Part_Line__c line : linesForPart) {
                        line.addError('참조된 부품(Id: ' + partId + ')을 찾을 수 없습니다. 삭제되었을 수 있습니다.');
                    }
                    hasBlockingError = true;
                    continue;
                }

                Decimal currentStock = part.Stock_Quantity__c == null ? 0 : part.Stock_Quantity__c;
                Decimal totalRequested = 0;
                for (Part_Line__c line : linesForPart) {
                    totalRequested += line.Quantity__c;
                }

                if (totalRequested > currentStock) {
                    String message = String.format(
                        '재고가 부족합니다. 부품: {0} (SKU: {1}), 요청 수량: {2}, 현재 재고: {3}',
                        new List<String>{
                            part.Name, String.valueOf(part.SKU__c),
                            String.valueOf(totalRequested), String.valueOf(currentStock)
                        }
                    );
                    for (Part_Line__c line : linesForPart) {
                        line.addError(message);
                    }
                    hasBlockingError = true;
                    continue;
                }

                Decimal remainingStock = currentStock - totalRequested;
                part.Stock_Quantity__c = remainingStock;
                partsToUpdate.add(part);

                ERPInventorySyncService.SyncPayload syncPayload = new ERPInventorySyncService.SyncPayload();
                syncPayload.partId = part.Id;
                syncPayload.sku = part.SKU__c;
                syncPayload.relatedRecordId = linesForPart[0].Id;
                syncPayload.quantityDeducted = totalRequested;
                syncPayload.remainingStock = remainingStock;
                erpSyncPayloads.add(syncPayload);

                if (part.Reorder_Point__c != null && remainingStock <= part.Reorder_Point__c) {
                    reorderEvents.add(new Part_Reorder__e(
                        Part_Id__c = part.Id,
                        SKU__c = part.SKU__c,
                        Current_Stock__c = remainingStock,
                        Reorder_Point__c = part.Reorder_Point__c,
                        Warehouse__c = part.Warehouse__c
                    ));
                }
            }
        }

        if (hasBlockingError) {
            throw new InsufficientStockException(
                '일부 부품 라인의 재고 차감에 실패했습니다. 각 라인에 표시된 오류 메시지를 확인하세요.'
            );
        }

        if (!partsToUpdate.isEmpty()) {
            update partsToUpdate;
        }
        if (!reorderEvents.isEmpty()) {
            lastReorderPublishResults = EventBus.publish(reorderEvents);
        }
        if (!erpSyncPayloads.isEmpty()) {
            // 트리거 컨텍스트에서는 트랜잭션당 System.enqueueJob 호출이 1회로 제한되므로,
            // 이번 호출에서 차감된 모든 부품을 하나의 Queueable 잡으로 묶어 발행한다.
            System.enqueueJob(new ERPInventorySyncService(erpSyncPayloads));
        }
    }
}
