@IsTest
private class WorkOrderControllerTest {

    private static Service_Contract__c createContract(Account acc) {
        Service_Contract__c contract = new Service_Contract__c(Account__c = acc.Id);
        insert contract;
        return contract;
    }

    private static Work_Order__c buildWorkOrder(Id contractId, String status, String priority, Id technicianId) {
        return new Work_Order__c(
            Service_Contract__c = contractId,
            Status__c = status,
            Priority__c = priority,
            Service_Address__c = '123 Main St',
            Scheduled_Date__c = Datetime.now(),
            Assigned_Technician__c = technicianId
        );
    }

    private static Work_Order__c createWorkOrder(Id contractId, String status, String priority, Id technicianId) {
        Work_Order__c wo = buildWorkOrder(contractId, status, priority, technicianId);
        insert wo;
        return wo;
    }

    private static Technician__c createTechnician(String name, Boolean isAvailable) {
        Technician__c tech = new Technician__c(
            Name = name,
            Is_Available__c = isAvailable,
            Active_Work_Orders__c = 0,
            Service_Region__c = 'North',
            Base_Location__Latitude__s = 37.5665,
            Base_Location__Longitude__s = 126.9780
        );
        insert tech;
        return tech;
    }

    @IsTest
    static void testGetActiveWorkOrders_groupsByStatusAndSummarizesCorrectly() {
        Account acc = new Account(Name = 'Dispatcher Board Test Account');
        insert acc;
        Service_Contract__c contract = createContract(acc);
        Technician__c tech = createTechnician('Dispatcher Test Tech', true);

        insert new List<Work_Order__c>{
            buildWorkOrder(contract.Id, 'New', 'Emergency', null),
            buildWorkOrder(contract.Id, 'Assigned', 'High', tech.Id),
            buildWorkOrder(contract.Id, 'En Route', 'Medium', tech.Id),
            buildWorkOrder(contract.Id, 'On Site', 'Low', tech.Id),
            buildWorkOrder(contract.Id, 'Completed', 'Medium', tech.Id),
            buildWorkOrder(contract.Id, 'Cancelled', 'Low', null)
        };

        Test.startTest();
        WorkOrderController.DashboardData data = WorkOrderController.getActiveWorkOrders();
        Test.stopTest();

        System.assertEquals(5, data.summary.totalCount, 'Cancelled 건은 집계에서 제외되어야 함');
        System.assertEquals(1, data.summary.unassignedCount);
        System.assertEquals(3, data.summary.inProgressCount, 'Assigned+En Route+On Site 합계여야 함');
        System.assertEquals(1, data.summary.completedCount);

        System.assertEquals(5, data.columns.size(), '칸반 컬럼은 5개(New/Assigned/En Route/On Site/Completed)여야 함');

        Map<String, WorkOrderController.StatusColumn> columnsByStatus = new Map<String, WorkOrderController.StatusColumn>();
        for (WorkOrderController.StatusColumn column : data.columns) {
            columnsByStatus.put(column.status, column);
        }
        System.assertEquals(1, columnsByStatus.get('New').workOrders.size());
        System.assertEquals(1, columnsByStatus.get('Assigned').workOrders.size());
        System.assertEquals(1, columnsByStatus.get('En Route').workOrders.size());
        System.assertEquals(1, columnsByStatus.get('On Site').workOrders.size());
        System.assertEquals(1, columnsByStatus.get('Completed').workOrders.size());

        WorkOrderController.WorkOrderCard assignedCard = columnsByStatus.get('Assigned').workOrders[0];
        System.assertEquals(acc.Name, assignedCard.customerName, '고객명이 계약을 거쳐 조회되어야 함');
        System.assertEquals(tech.Id, assignedCard.assignedTechnicianId);
        System.assertEquals(tech.Name, assignedCard.assignedTechnicianName);

        System.assertEquals(1, data.technicians.size());
        System.assertEquals(tech.Id, data.technicians[0].technicianId);
        System.assertEquals(true, data.technicians[0].isAvailable);
    }

    @IsTest
    static void testGetActiveWorkOrders_excludesNonTodayScheduledOrders() {
        Account acc = new Account(Name = 'Non Today Account');
        insert acc;
        Service_Contract__c contract = createContract(acc);

        Work_Order__c futureWo = new Work_Order__c(
            Service_Contract__c = contract.Id,
            Status__c = 'New',
            Scheduled_Date__c = Datetime.now().addDays(3)
        );
        insert futureWo;

        Test.startTest();
        WorkOrderController.DashboardData data = WorkOrderController.getActiveWorkOrders();
        Test.stopTest();

        System.assertEquals(0, data.summary.totalCount, '오늘 예정이 아닌 작업은 보드에 나타나지 않아야 함');
    }

    @IsTest
    static void testReassign_newStatusMovesToAssigned() {
        Account acc = new Account(Name = 'Reassign Test Account');
        insert acc;
        Service_Contract__c contract = createContract(acc);
        Technician__c tech = createTechnician('Reassign Target Tech', true);
        Work_Order__c wo = createWorkOrder(contract.Id, 'New', 'Medium', null);

        Test.startTest();
        WorkOrderController.reassign(wo.Id, tech.Id);
        Test.stopTest();

        Work_Order__c updated = [SELECT Status__c, Assigned_Technician__c FROM Work_Order__c WHERE Id = :wo.Id];
        System.assertEquals(tech.Id, updated.Assigned_Technician__c);
        System.assertEquals('Assigned', updated.Status__c, 'New 상태의 작업에 기술자를 배정하면 Assigned로 전환되어야 함');
    }

    @IsTest
    static void testReassign_midFlightStatusPreservedWhileSwappingTechnician() {
        Account acc = new Account(Name = 'Reassign Mid Flight Account');
        insert acc;
        Service_Contract__c contract = createContract(acc);
        Technician__c originalTech = createTechnician('Original Tech', true);
        Technician__c newTech = createTechnician('New Tech', true);
        Work_Order__c wo = createWorkOrder(contract.Id, 'En Route', 'High', originalTech.Id);

        Test.startTest();
        WorkOrderController.reassign(wo.Id, newTech.Id);
        Test.stopTest();

        Work_Order__c updated = [SELECT Status__c, Assigned_Technician__c FROM Work_Order__c WHERE Id = :wo.Id];
        System.assertEquals(newTech.Id, updated.Assigned_Technician__c);
        System.assertEquals('En Route', updated.Status__c, '이미 진행 중인 작업은 기술자만 교체되고 상태는 유지되어야 함');
    }

    @IsTest
    static void testReassign_missingWorkOrderThrows() {
        Account acc = new Account(Name = 'Missing WO Account');
        insert acc;
        Technician__c tech = createTechnician('Orphan Tech', true);
        Work_Order__c wo = createWorkOrder(createContract(acc).Id, 'New', 'Medium', null);
        Id fakeWorkOrderId = wo.Id;
        delete wo;

        Boolean threw = false;
        Test.startTest();
        try {
            WorkOrderController.reassign(fakeWorkOrderId, tech.Id);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, '존재하지 않는 작업에 대한 재배정은 예외를 발생시켜야 함');
    }

    @IsTest
    static void testReassign_missingTechnicianThrows() {
        Account acc = new Account(Name = 'Missing Tech Account');
        insert acc;
        Service_Contract__c contract = createContract(acc);
        Work_Order__c wo = createWorkOrder(contract.Id, 'New', 'Medium', null);

        Technician__c tempTech = createTechnician('Temp Tech', true);
        Id fakeTechnicianId = tempTech.Id;
        delete tempTech;

        Boolean threw = false;
        Test.startTest();
        try {
            WorkOrderController.reassign(wo.Id, fakeTechnicianId);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, '존재하지 않는 기술자에 대한 재배정은 예외를 발생시켜야 함');
    }

    @IsTest
    static void testReassign_nullArgumentsThrow() {
        Boolean threw = false;
        Test.startTest();
        try {
            WorkOrderController.reassign(null, null);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'workOrderId/technicianId가 없으면 예외가 발생해야 함');
    }
}
