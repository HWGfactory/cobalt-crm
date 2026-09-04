// 이 세션 중 InvoiceGenerationService 작업 당시 실행했던 test_query_count.apex의
// 잔여물(Query Count Test Acc 및 그 하위 5건의 Service_Contract__c -> 20건의
// 분기별 Work_Order__c, 5건의 Opportunity)을 정리한다. 관련 Invoice__c 없음을
// 사전에 확인했다(0건).
Id accId = '001g800000iJpofAAC';

List<Service_Contract__c> contracts = [SELECT Id FROM Service_Contract__c WHERE Account__c = :accId];
System.debug('Deleting Service_Contract__c count: ' + contracts.size());
delete contracts; // Master-Detail이므로 Work_Order__c 자식도 함께 삭제됨

List<Opportunity> opps = [SELECT Id FROM Opportunity WHERE AccountId = :accId];
System.debug('Deleting Opportunity count: ' + opps.size());
delete opps;

List<Contact> cons = [SELECT Id FROM Contact WHERE AccountId = :accId];
System.debug('Deleting Contact count: ' + cons.size());
delete cons;

delete new Account(Id = accId);
System.debug('Deleted Query Count Test Acc and all cascaded children.');
