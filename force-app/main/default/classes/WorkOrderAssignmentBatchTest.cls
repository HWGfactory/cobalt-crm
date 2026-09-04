@IsTest
private class WorkOrderAssignmentBatchTest {

    @IsTest
    static void testBatch_reassignsStaleUnassignedWorkOrders() {
        Account acc = new Account(Name = 'Batch Test Account');
        insert acc;
        Service_Contract__c contract = new Service_Contract__c(Account__c = acc.Id);
        insert contract;

        Technician__c tech = new Technician__c(
            Name = 'Batch Tech',
            Skills__c = 'HVAC',
            Service_Region__c = 'North',
            Is_Available__c = true,
            Active_Work_Orders__c = 0,
            Base_Location__Latitude__s = 37.5665,
            Base_Location__Longitude__s = 126.9780
        );
        insert tech;

        Work_Order__c staleWo = new Work_Order__c(
            Service_Contract__c = contract.Id,
            Status__c = 'New',
            Required_Skill__c = 'HVAC',
            Service_Region__c = 'South',
            Scheduled_Date__c = Datetime.now().addDays(1)
        );
        insert staleWo;
        Test.setCreatedDate(staleWo.Id, Datetime.now().addHours(-48));

        Work_Order__c freshWo = new Work_Order__c(
            Service_Contract__c = contract.Id,
            Status__c = 'New',
            Required_Skill__c = 'HVAC',
            Service_Region__c = 'South',
            Scheduled_Date__c = Datetime.now().addDays(1)
        );
        insert freshWo;

        // 배치 대상 조건(지역 매칭)을 만족시키기 위해 기술자 지역을 두 작업이 이미 존재하는 뒤에 변경.
        // Work_Order__c 트리거는 Technician__c 갱신으로는 재실행되지 않으므로 두 작업 모두 New/미배정 상태로 유지됨.
        tech.Service_Region__c = 'South';
        update tech;

        Test.startTest();
        Database.executeBatch(new WorkOrderAssignmentBatch(), 50);
        Test.stopTest();

        Work_Order__c staleResult = [
            SELECT Status__c, Assigned_Technician__c FROM Work_Order__c WHERE Id = :staleWo.Id
        ];
        Work_Order__c freshResult = [SELECT Status__c FROM Work_Order__c WHERE Id = :freshWo.Id];

        System.assertEquals('Assigned', staleResult.Status__c, '24시간 이상 미배정된 작업은 배치에 의해 재시도되어야 함');
        System.assertEquals(tech.Id, staleResult.Assigned_Technician__c);
        System.assertEquals('New', freshResult.Status__c, '24시간 미만인 작업은 배치 대상에서 제외되어야 함');
    }

    @IsTest
    static void testSchedulable_launchesBatch() {
        Test.startTest();
        new WorkOrderAssignmentBatch().execute(null);
        Test.stopTest();

        List<AsyncApexJob> jobs = [
            SELECT Id, Status FROM AsyncApexJob WHERE ApexClass.Name = 'WorkOrderAssignmentBatch'
        ];
        System.assert(!jobs.isEmpty(), 'Schedulable 실행 시 배치 잡이 큐잉되어야 함');
    }
}
