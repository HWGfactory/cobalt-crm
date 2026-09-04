@IsTest
private class InventoryServiceTest {

    private static Service_Contract__c createContract() {
        Account acc = new Account(Name = 'Inventory Test Account');
        insert acc;
        Service_Contract__c contract = new Service_Contract__c(Account__c = acc.Id);
        insert contract;
        return contract;
    }

    private static Work_Order__c createWorkOrder(Id contractId) {
        Work_Order__c wo = new Work_Order__c(Service_Contract__c = contractId, Status__c = 'New');
        insert wo;
        return wo;
    }

    private static Part__c createPart(Decimal stock, Decimal reorderPoint) {
        Part__c part = new Part__c(
            Name = 'Inventory Test Part',
            SKU__c = 'SKU-' + Datetime.now().getTime() + '-' + Math.round(Math.random() * 100000),
            Stock_Quantity__c = stock,
            Reorder_Point__c = reorderPoint,
            Warehouse__c = 'North Warehouse'
        );
        insert part;
        return part;
    }

    private static Part_Line__c buildLine(Id workOrderId, Id partId, Decimal quantity) {
        return new Part_Line__c(Work_Order__c = workOrderId, Part__c = partId, Quantity__c = quantity);
    }

    @IsTest
    static void testDeductStock_sufficientStockDecrementsCorrectly() {
        Service_Contract__c contract = createContract();
        Work_Order__c wo = createWorkOrder(contract.Id);
        Part__c part = createPart(10, 2);

        List<Part_Line__c> lines = new List<Part_Line__c>{ buildLine(wo.Id, part.Id, 3) };

        Test.startTest();
        InventoryService.deductStock(lines);
        Test.stopTest();

        Part__c updated = [SELECT Stock_Quantity__c FROM Part__c WHERE Id = :part.Id];
        System.assertEquals(7, updated.Stock_Quantity__c, '요청 수량만큼 재고가 차감되어야 함');
    }

    @IsTest
    static void testDeductStock_exactBoundaryStockEqualsRequestedSucceeds() {
        Service_Contract__c contract = createContract();
        Work_Order__c wo = createWorkOrder(contract.Id);
        Part__c part = createPart(5, 0);

        List<Part_Line__c> lines = new List<Part_Line__c>{ buildLine(wo.Id, part.Id, 5) };

        Test.startTest();
        InventoryService.deductStock(lines);
        Test.stopTest();

        Part__c updated = [SELECT Stock_Quantity__c FROM Part__c WHERE Id = :part.Id];
        System.assertEquals(0, updated.Stock_Quantity__c, '재고와 요청 수량이 정확히 같으면 0까지 차감되어야 함');
    }

    @IsTest
    static void testDeductStock_zeroStockAnyRequestFails() {
        Service_Contract__c contract = createContract();
        Work_Order__c wo = createWorkOrder(contract.Id);
        Part__c part = createPart(0, 2);

        List<Part_Line__c> lines = new List<Part_Line__c>{ buildLine(wo.Id, part.Id, 1) };

        Boolean threw = false;
        Test.startTest();
        try {
            InventoryService.deductStock(lines);
        } catch (InventoryService.InsufficientStockException ex) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, '재고 0에서 요청이 들어오면 InsufficientStockException이 발생해야 함');
        System.assert(!lines[0].getErrors().isEmpty(), 'addError로 라인에 오류가 표시되어야 함');

        Part__c unchanged = [SELECT Stock_Quantity__c FROM Part__c WHERE Id = :part.Id];
        System.assertEquals(0, unchanged.Stock_Quantity__c, '실패 시 재고는 변경되지 않아야 함');
    }

    @IsTest
    static void testDeductStock_insufficientStockThrowsAndAddsErrorWithoutMutatingStock() {
        Service_Contract__c contract = createContract();
        Work_Order__c wo = createWorkOrder(contract.Id);
        Part__c part = createPart(3, 1);

        List<Part_Line__c> lines = new List<Part_Line__c>{ buildLine(wo.Id, part.Id, 5) };

        Boolean threw = false;
        Test.startTest();
        try {
            InventoryService.deductStock(lines);
        } catch (InventoryService.InsufficientStockException ex) {
            threw = true;
            System.assert(ex.getMessage().contains('재고 차감에 실패'), '예외 메시지가 명확해야 함');
        }
        Test.stopTest();

        System.assert(threw, '재고 부족 시 InsufficientStockException이 발생해야 함');
        System.assert(
            lines[0].getErrors()[0].getMessage().contains('재고가 부족합니다'),
            'addError 메시지가 사용자에게 명확해야 함'
        );

        Part__c unchanged = [SELECT Stock_Quantity__c FROM Part__c WHERE Id = :part.Id];
        System.assertEquals(3, unchanged.Stock_Quantity__c, '재고 부족으로 실패하면 재고가 변경되지 않아야 함');
    }

    @IsTest
    static void testDeductStock_negativeQuantityThrowsAndAddsError() {
        Service_Contract__c contract = createContract();
        Work_Order__c wo = createWorkOrder(contract.Id);
        Part__c part = createPart(10, 2);

        List<Part_Line__c> lines = new List<Part_Line__c>{ buildLine(wo.Id, part.Id, -1) };

        Boolean threw = false;
        Test.startTest();
        try {
            InventoryService.deductStock(lines);
        } catch (InventoryService.InsufficientStockException ex) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, '음수 수량 요청은 예외를 발생시켜야 함');
        System.assert(
            lines[0].getErrors()[0].getMessage().contains('0보다 큰 값'),
            '음수 수량에 대한 addError 메시지가 있어야 함'
        );

        Part__c unchanged = [SELECT Stock_Quantity__c FROM Part__c WHERE Id = :part.Id];
        System.assertEquals(10, unchanged.Stock_Quantity__c);
    }

    @IsTest
    static void testDeductStock_zeroQuantityThrowsAndAddsError() {
        Service_Contract__c contract = createContract();
        Work_Order__c wo = createWorkOrder(contract.Id);
        Part__c part = createPart(10, 2);

        List<Part_Line__c> lines = new List<Part_Line__c>{ buildLine(wo.Id, part.Id, 0) };

        Boolean threw = false;
        Test.startTest();
        try {
            InventoryService.deductStock(lines);
        } catch (InventoryService.InsufficientStockException ex) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, '수량 0 요청은 예외를 발생시켜야 함');
    }

    @IsTest
    static void testDeductStock_missingPartThrowsAndAddsError() {
        Service_Contract__c contract = createContract();
        Work_Order__c wo = createWorkOrder(contract.Id);

        List<Part_Line__c> lines = new List<Part_Line__c>{ buildLine(wo.Id, null, 1) };

        Boolean threw = false;
        Test.startTest();
        try {
            InventoryService.deductStock(lines);
        } catch (InventoryService.InsufficientStockException ex) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, '부품이 지정되지 않으면 예외가 발생해야 함');
        System.assert(lines[0].getErrors()[0].getMessage().contains('지정되지'));
    }

    @IsTest
    static void testDeductStock_emptyOrNullListDoesNothing() {
        Test.startTest();
        InventoryService.deductStock(new List<Part_Line__c>());
        InventoryService.deductStock(null);
        Test.stopTest();
        System.assert(true, '빈 리스트/널 입력 시 예외 없이 종료되어야 함');
    }

    @IsTest
    static void testDeductStock_multipleLinesForSamePartAggregateDemand() {
        Service_Contract__c contract = createContract();
        Work_Order__c wo = createWorkOrder(contract.Id);
        Part__c part = createPart(10, 2);

        List<Part_Line__c> lines = new List<Part_Line__c>{
            buildLine(wo.Id, part.Id, 4),
            buildLine(wo.Id, part.Id, 4)
        };

        Test.startTest();
        InventoryService.deductStock(lines);
        Test.stopTest();

        Part__c updated = [SELECT Stock_Quantity__c FROM Part__c WHERE Id = :part.Id];
        System.assertEquals(2, updated.Stock_Quantity__c, '같은 부품을 참조하는 여러 라인의 수요가 합산되어 차감되어야 함');
    }

    @IsTest
    static void testDeductStock_multipleLinesForSamePartInsufficientAggregateFails() {
        Service_Contract__c contract = createContract();
        Work_Order__c wo = createWorkOrder(contract.Id);
        Part__c part = createPart(5, 1);

        List<Part_Line__c> lines = new List<Part_Line__c>{
            buildLine(wo.Id, part.Id, 3),
            buildLine(wo.Id, part.Id, 3)
        };

        Boolean threw = false;
        Test.startTest();
        try {
            InventoryService.deductStock(lines);
        } catch (InventoryService.InsufficientStockException ex) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, '개별 라인은 재고 이내여도 합산 수요가 재고를 초과하면 실패해야 함');
        Part__c unchanged = [SELECT Stock_Quantity__c FROM Part__c WHERE Id = :part.Id];
        System.assertEquals(5, unchanged.Stock_Quantity__c);
    }

    @IsTest
    static void testDeductStock_reorderPointCrossedPublishesEvent() {
        Service_Contract__c contract = createContract();
        Work_Order__c wo = createWorkOrder(contract.Id);
        Part__c part = createPart(10, 5);

        List<Part_Line__c> lines = new List<Part_Line__c>{ buildLine(wo.Id, part.Id, 6) };

        Test.startTest();
        InventoryService.deductStock(lines);
        Test.stopTest();

        Part__c updated = [SELECT Stock_Quantity__c FROM Part__c WHERE Id = :part.Id];
        System.assertEquals(4, updated.Stock_Quantity__c);
        System.assertNotEquals(null, InventoryService.lastReorderPublishResults, '재고가 임계값 이하이면 Part_Reorder__e가 발행되어야 함');
        System.assertEquals(1, InventoryService.lastReorderPublishResults.size());
        System.assert(InventoryService.lastReorderPublishResults[0].isSuccess(), 'Platform Event 발행이 성공해야 함');
    }

    @IsTest
    static void testDeductStock_aboveReorderPointDoesNotPublishEvent() {
        InventoryService.lastReorderPublishResults = null;

        Service_Contract__c contract = createContract();
        Work_Order__c wo = createWorkOrder(contract.Id);
        Part__c part = createPart(10, 2);

        List<Part_Line__c> lines = new List<Part_Line__c>{ buildLine(wo.Id, part.Id, 3) };

        Test.startTest();
        InventoryService.deductStock(lines);
        Test.stopTest();

        System.assertEquals(
            null, InventoryService.lastReorderPublishResults,
            '재고가 임계값보다 여유 있으면 Part_Reorder__e를 발행하지 않아야 함'
        );
    }

    @IsTest
    static void testDeductStock_bulk200LinesAcrossFewPartsStaysWithinLimits() {
        Service_Contract__c contract = createContract();
        Work_Order__c wo = createWorkOrder(contract.Id);

        List<Part__c> parts = new List<Part__c>{
            createPart(1000, 50),
            createPart(1000, 50)
        };

        List<Part_Line__c> lines = new List<Part_Line__c>();
        for (Integer i = 0; i < 200; i++) {
            lines.add(buildLine(wo.Id, parts[Math.mod(i, parts.size())].Id, 1));
        }

        Integer queriesBefore = Limits.getQueries();
        Test.startTest();
        InventoryService.deductStock(lines);
        Integer queriesAfter = Limits.getQueries();
        Test.stopTest();

        System.assert(
            (queriesAfter - queriesBefore) <= 3,
            '벌크 처리 시 관련 부품 종류 수와 무관하게 SOQL 쿼리 수가 일정해야 함 (실제: ' + (queriesAfter - queriesBefore) + ')'
        );

        for (Part__c part : [SELECT Id, Stock_Quantity__c FROM Part__c WHERE Id IN :parts]) {
            System.assertEquals(900, part.Stock_Quantity__c, '100건씩 차감되어 900이어야 함');
        }
    }
}
