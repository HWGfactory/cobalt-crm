// 이 세션 앞부분에서 검증 규칙(Validation Rule) 테스트용으로 만들었던 임시 데이터
// (VR Test Account/2/3, Pilot Gate Test Account 및 각각의 Opportunity)를 정리한다.
// Closed Won 이력이 없어 Service_Contract__c/Work_Order__c로 캐스케이드된 것이
// 없음을 사전에 확인했다(0건).
List<Id> accIds = new List<Id>{
    '001g800000hkQWyAAM', '001g800000hkwHxAAI', '001g800000hkxAnAAI', '001g800000hkyEvAAI'
};

List<Opportunity> opps = [SELECT Id FROM Opportunity WHERE AccountId IN :accIds];
System.debug('Deleting Opportunity count: ' + opps.size());
delete opps;

List<Account> accs = [SELECT Id FROM Account WHERE Id IN :accIds];
System.debug('Deleting Account count: ' + accs.size());
delete accs;

// InvoiceGenerationService 개발 초기 임시 스크립트에서 남은, Work_Order__c 참조가
// 전혀 없는 고아 Invoice__c 1건도 함께 정리한다.
delete new Invoice__c(Id = 'a07g800000dBVU3AAO');
System.debug('Deleted orphaned Invoice__c with no Work_Order__c reference.');
