@IsTest
private class PartLineTriggerHandlerTest {

    private static Work_Order__c createWorkOrder() {
        Account acc = new Account(Name = 'PartLine Trigger Test Account');
        insert acc;
        Service_Contract__c contract = new Service_Contract__c(Account__c = acc.Id);
        insert contract;
        Work_Order__c wo = new Work_Order__c(Service_Contract__c = contract.Id, Status__c = 'New');
        insert wo;
        return wo;
    }

    private static Part__c createPart(Decimal stock, Decimal reorderPoint) {
        Part__c part = new Part__c(
            Name = 'Trigger Test Part',
            SKU__c = 'TRG-' + Datetime.now().getTime() + '-' + Math.round(Math.random() * 100000),
            Stock_Quantity__c = stock,
            Reorder_Point__c = reorderPoint
        );
        insert part;
        return part;
    }

    @IsTest
    static void testInsert_sufficientStockDeductsViaTrigger() {
        Work_Order__c wo = createWorkOrder();
        Part__c part = createPart(20, 5);

        Test.startTest();
        insert new Part_Line__c(Work_Order__c = wo.Id, Part__c = part.Id, Quantity__c = 5);
        Test.stopTest();

        Part__c updated = [SELECT Stock_Quantity__c FROM Part__c WHERE Id = :part.Id];
        System.assertEquals(15, updated.Stock_Quantity__c, 'Part_Line__c 삽입 시 트리거를 통해 재고가 차감되어야 함');
    }

    @IsTest
    static void testInsert_insufficientStockRollsBackEntireInsert() {
        Work_Order__c wo = createWorkOrder();
        Part__c part = createPart(2, 1);

        Boolean threw = false;
        Test.startTest();
        try {
            insert new Part_Line__c(Work_Order__c = wo.Id, Part__c = part.Id, Quantity__c = 10);
        } catch (DmlException ex) {
            threw = true;
            System.assert(ex.getMessage().contains('재고가 부족합니다'), '재고부족 addError 메시지가 DmlException에 포함되어야 함');
        }
        Test.stopTest();

        System.assert(threw, '재고 부족 시 Part_Line__c insert 자체가 DmlException으로 실패해야 함');

        System.assertEquals(
            0, [SELECT COUNT() FROM Part_Line__c WHERE Work_Order__c = :wo.Id],
            'insert가 롤백되어 Part_Line__c 레코드가 남아있지 않아야 함'
        );
        Part__c unchanged = [SELECT Stock_Quantity__c FROM Part__c WHERE Id = :part.Id];
        System.assertEquals(2, unchanged.Stock_Quantity__c, '롤백되었으므로 재고는 변경되지 않아야 함');
    }

    @IsTest
    static void testInsert_zeroStockRollsBack() {
        Work_Order__c wo = createWorkOrder();
        Part__c part = createPart(0, 3);

        Boolean threw = false;
        Test.startTest();
        try {
            insert new Part_Line__c(Work_Order__c = wo.Id, Part__c = part.Id, Quantity__c = 1);
        } catch (DmlException ex) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, '재고 0에서는 어떤 요청도 실패해야 함');
        System.assertEquals(0, [SELECT COUNT() FROM Part_Line__c WHERE Work_Order__c = :wo.Id]);
    }

    @IsTest
    static void testInsert_negativeQuantityRollsBack() {
        Work_Order__c wo = createWorkOrder();
        Part__c part = createPart(10, 2);

        Boolean threw = false;
        Test.startTest();
        try {
            insert new Part_Line__c(Work_Order__c = wo.Id, Part__c = part.Id, Quantity__c = -5);
        } catch (DmlException ex) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, '음수 수량 요청은 트리거에서도 실패해야 함');
        Part__c unchanged = [SELECT Stock_Quantity__c FROM Part__c WHERE Id = :part.Id];
        System.assertEquals(10, unchanged.Stock_Quantity__c);
    }

    @IsTest
    static void testInsert_bulk200PartLinesAcrossFewParts() {
        Work_Order__c wo = createWorkOrder();
        List<Part__c> parts = new List<Part__c>{
            createPart(500, 50),
            createPart(500, 50)
        };

        List<Part_Line__c> lines = new List<Part_Line__c>();
        for (Integer i = 0; i < 200; i++) {
            lines.add(new Part_Line__c(
                Work_Order__c = wo.Id,
                Part__c = parts[Math.mod(i, parts.size())].Id,
                Quantity__c = 1
            ));
        }

        Test.startTest();
        insert lines;
        Test.stopTest();

        for (Part__c part : [SELECT Id, Stock_Quantity__c FROM Part__c WHERE Id IN :parts]) {
            System.assertEquals(400, part.Stock_Quantity__c, '100건씩 차감되어 400이어야 함');
        }
    }
}
