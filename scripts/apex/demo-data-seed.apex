// ============================================================================
// Cobalt FSM 데모 데이터 시드 스크립트
// 실행: sf apex run --file scripts/apex/demo-data-seed.apex --target-org cobalt-dev
//
// 이 스크립트는 실제(비테스트) 컨텍스트에서 실행되므로, Named Credential이 org에
// 아직 구성되어 있지 않다면 외부 API 콜아웃(경로/결제/메시징/재고 ERP/날씨)은
// 전부 자연스럽게 실패합니다 - 이는 버그가 아니라 의도된 안전한 폴백 동작이며,
// Integration_Log__c에 실패로 정확히 기록되는 모습 자체가 데모 포인트입니다.
// (자동 테스트로 "성공 시 전체 플로우가 끝까지 도는가"는 FullLifecycleIntegrationTest가
// 이미 Mock으로 증명했습니다.)
// ============================================================================

System.debug('=== [1/7] 고객사 + 담당자 생성 ===');

Account accNorth = new Account(Name = 'Aurora Facilities Group');
Account accSouth = new Account(Name = 'Riverside Retail Chain');
Account accCentral = new Account(Name = 'Metro Health Clinics');
insert new List<Account>{ accNorth, accSouth, accCentral };

Contact conNorth = new Contact(LastName = 'Kim', FirstName = 'Minjun', AccountId = accNorth.Id, Email = 'minjun.kim@aurora-demo.example', Phone = '02-555-0101');
Contact conSouth = new Contact(LastName = 'Park', FirstName = 'Soyeon', AccountId = accSouth.Id, Email = 'soyeon.park@riverside-demo.example', Phone = '02-555-0102');
Contact conCentral = new Contact(LastName = 'Lee', FirstName = 'Jihoon', AccountId = accCentral.Id, Email = 'jihoon.lee@metrohealth-demo.example', Phone = '02-555-0103');
insert new List<Contact>{ conNorth, conSouth, conCentral };

System.debug('=== [2/7] 기술자 생성 (지역/스킬 다양화) ===');

List<Technician__c> technicians = new List<Technician__c>{
    new Technician__c(
        Name = 'Technician - Han Seojun', Skills__c = 'HVAC;Electrical', Service_Region__c = 'North',
        Is_Available__c = true, Active_Work_Orders__c = 1, Phone__c = '010-2001-0001',
        Base_Location__Latitude__s = 37.5665, Base_Location__Longitude__s = 126.9780
    ),
    new Technician__c(
        Name = 'Technician - Yoon Areum', Skills__c = 'Plumbing;HVAC', Service_Region__c = 'South',
        Is_Available__c = true, Active_Work_Orders__c = 0, Phone__c = '010-2001-0002',
        Base_Location__Latitude__s = 35.1796, Base_Location__Longitude__s = 129.0756
    ),
    new Technician__c(
        Name = 'Technician - Jung Doyun', Skills__c = 'Elevator;Electrical', Service_Region__c = 'Central',
        Is_Available__c = true, Active_Work_Orders__c = 2, Phone__c = '010-2001-0003',
        Base_Location__Latitude__s = 36.3504, Base_Location__Longitude__s = 127.3845
    )
};
insert technicians;

System.debug('=== [3/7] 부품 재고 생성 (일부는 재주문 임계값 이하) ===');

List<Part__c> parts = new List<Part__c>{
    new Part__c(Name = 'Compressor Unit CX-200', SKU__c = 'DEMO-SKU-CX200', Stock_Quantity__c = 42, Unit_Price__c = 350, Reorder_Point__c = 10, Warehouse__c = 'North Warehouse'),
    new Part__c(Name = 'Circuit Breaker 30A', SKU__c = 'DEMO-SKU-CB30', Stock_Quantity__c = 8, Unit_Price__c = 22, Reorder_Point__c = 15, Warehouse__c = 'South Warehouse'),
    new Part__c(Name = 'Elevator Cable 10m', SKU__c = 'DEMO-SKU-EC10', Stock_Quantity__c = 5, Unit_Price__c = 180, Reorder_Point__c = 5, Warehouse__c = 'Central Warehouse'),
    new Part__c(Name = 'PVC Pipe Fitting Set', SKU__c = 'DEMO-SKU-PVC1', Stock_Quantity__c = 120, Unit_Price__c = 12, Reorder_Point__c = 20, Warehouse__c = 'South Warehouse')
};
insert parts;

System.debug('=== [4/7] Closed Won 딜 -> 계약/분기별 정기 점검 Work Order 자동 생성 트리거 ===');

Opportunity closedWonOpp = new Opportunity(
    Name = 'Aurora Facilities - Enterprise 계약',
    AccountId = accNorth.Id,
    StageName = 'Prospecting',
    CloseDate = Date.today(),
    Product_Tier__c = 'Enterprise',
    Contract_Reviewed__c = true,
    Technician_Count__c = 5
);
insert closedWonOpp;

Opportunity openOpp = new Opportunity(
    Name = 'Riverside Retail - Pro 검토 중',
    AccountId = accSouth.Id,
    StageName = 'Qualification',
    CloseDate = Date.today().addDays(21),
    Product_Tier__c = 'Pro'
);
insert openOpp;

closedWonOpp.StageName = 'Closed Won';
update closedWonOpp; // -> OpportunityTriggerHandler -> ServiceContractCreationService

Service_Contract__c contract = [
    SELECT Id, Tier__c, SLA_Hours__c FROM Service_Contract__c WHERE Opportunity__c = :closedWonOpp.Id LIMIT 1
];
System.debug('생성된 계약: Tier=' + contract.Tier__c + ', SLA_Hours=' + contract.SLA_Hours__c);
System.debug('자동 생성된 분기별 정기 점검 Work Order 수: ' +
    [SELECT COUNT() FROM Work_Order__c WHERE Service_Contract__c = :contract.Id]);

System.debug('=== [5/7] 디스패처 보드용 Work Order를 다양한 상태로 생성 ===');

Work_Order__c woNew = new Work_Order__c(
    Service_Contract__c = contract.Id, Status__c = 'New', Priority__c = 'Emergency',
    Required_Skill__c = 'Electrical', Service_Region__c = 'North',
    Service_Address__c = '서울시 종로구 1가', Scheduled_Date__c = Datetime.now().addHours(1),
    Service_Location__Latitude__s = 37.5729, Service_Location__Longitude__s = 126.9794
);
insert woNew; // -> 자동 배정 엔진이 즉시 기술자 매칭 시도(성공 시 Assigned로 전환됨)

// 참고: 아래 3건은 처음부터 "이미 배정된" 상태로 만든다. New으로 넣었다가 곧바로 다른
// 상태로 바꾸면, 실제 운영에서는 몇 초 뒤 비동기로 완료되는 자동 배정 콜백이 이 스크립트
// 종료 후에야 실행되면서 "이미 진행된 작업을 되돌리지 않는다"는 안전장치(경쟁 상태 수정)에
// 의해 배정 자체가 스킵되어버린다 - 데모에서는 기술자가 이미 배정된 채로 보이는 편이 자연스럽다.
Work_Order__c woOnSite = new Work_Order__c(
    Service_Contract__c = contract.Id, Status__c = 'On Site', Priority__c = 'High',
    Required_Skill__c = 'Elevator', Service_Region__c = 'Central',
    Assigned_Technician__c = technicians[2].Id, ETA__c = Datetime.now(),
    Service_Address__c = '대전시 서구 2가', Scheduled_Date__c = Datetime.now().addHours(3),
    Service_Location__Latitude__s = 36.3504, Service_Location__Longitude__s = 127.3845
);
insert woOnSite; // Status가 이미 On Site이므로 자동 배정 대상이 아니며,
                 // Flow의 On Site 알림 분기는 "업데이트로 변경될 때만" 발동하므로 insert에서는 발동하지 않는다.

Work_Order__c woOutdoorTomorrow = new Work_Order__c(
    Service_Contract__c = contract.Id, Status__c = 'Assigned', Priority__c = 'Medium',
    Required_Skill__c = 'HVAC', Service_Region__c = 'South', Is_Outdoor__c = true,
    Assigned_Technician__c = technicians[1].Id, ETA__c = Datetime.now().addDays(1),
    Service_Address__c = '부산시 해운대구 3가', Scheduled_Date__c = Datetime.now().addDays(1),
    Service_Location__Latitude__s = 35.1796, Service_Location__Longitude__s = 129.0756
);
insert woOutdoorTomorrow; // -> WeatherRescheduleService 배치 데모용(내일 예정 + 옥외)

System.debug('=== [6/7] 부품 사용 + 현장 완료 처리 (청구서 자동 생성 흐름 시연용) ===');

Work_Order__c woToComplete = new Work_Order__c(
    Service_Contract__c = contract.Id, Status__c = 'On Site', Priority__c = 'Medium',
    Required_Skill__c = 'HVAC', Service_Region__c = 'North',
    Assigned_Technician__c = technicians[0].Id, ETA__c = Datetime.now(),
    Service_Address__c = '서울시 강남구 4가', Labor_Hours__c = 2.5,
    Scheduled_Date__c = Datetime.now().addHours(-1)
);
insert woToComplete;

insert new Part_Line__c(
    Work_Order__c = woToComplete.Id, Part__c = parts[0].Id, Quantity__c = 1, Unit_Price__c = 350
); // -> InventoryService 재고 차감 + ERP 동기화 시도

String samplePngBase64 = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
WorkPhotoGalleryController.PhotoInput demoPhoto = new WorkPhotoGalleryController.PhotoInput();
demoPhoto.fileName = 'site-before.png';
demoPhoto.base64Data = samplePngBase64;
WorkPhotoGalleryController.savePhotos(woToComplete.Id, new List<WorkPhotoGalleryController.PhotoInput>{ demoPhoto });

List<String> completionChecklist = new List<String>{
    '작업 내용을 고객에게 설명함',
    '사용된 부품을 기록함',
    '작업 현장을 정리함',
    '고객이 결과에 만족함을 확인함'
}; // FieldCompletionController.REQUIRED_CHECKLIST_ITEMS와 동일 - 그 필드는 @TestVisible이라
   // 테스트 컨텍스트가 아닌 이 스크립트에서는 직접 참조할 수 없어 값을 그대로 복제했다.

FieldCompletionController.saveSignature(woToComplete.Id, samplePngBase64);
FieldCompletionController.completeWorkOrder(woToComplete.Id, completionChecklist);
// -> Status=Completed -> InvoiceGenerationService(청구서 생성) + PaymentCalloutQueueable(결제 시도, 비동기)
//    + WorkOrder_Status_Notification Flow(완료 알림, 비동기)

System.debug('=== [7/7] 시드 완료 - 요약 ===');
System.debug('Account: 3건, Contact: 3건, Technician__c: 3건, Part__c: 4건(1건은 Reorder_Point 이하)');
System.debug('Opportunity: Closed Won 1건 + 진행 중 1건');
System.debug('Service_Contract__c: ' + contract.Id);
System.debug('Work_Order__c 총 건수: ' + [SELECT COUNT() FROM Work_Order__c WHERE Service_Contract__c = :contract.Id]);
System.debug('청구 대상 Work Order(완료 처리): ' + woToComplete.Id);
System.debug('');
System.debug('>>> 결제/재고동기화/알림 등 비동기 Queueable은 이 스크립트 종료 후 몇 초 내 백그라운드에서 실행됩니다.');
System.debug('>>> Setup > Apex Jobs에서 진행 상황을, Integration_Log__c 탭에서 결과를 확인하세요.');
System.debug('>>> Named Credential 4~5종이 아직 설정되지 않았다면 해당 로그는 Is_Success__c=false로 남습니다(의도된 동작).');
