public with sharing class OpportunityAccountRollupHandler {

    @TestVisible
    private static Integer rolling12MonthsWindow = 12;

    public static void handle(Boolean isUpdate, Boolean isDelete, List<Opportunity> newList, List<Opportunity> oldList) {
        Set<Id> accountIds = new Set<Id>();
        collectAccountIds(accountIds, newList);
        if (isUpdate || isDelete) {
            collectAccountIds(accountIds, oldList);
        }
        accountIds.remove(null);

        if (!accountIds.isEmpty()) {
            recalculateRollups(accountIds);
        }
    }

    private static void collectAccountIds(Set<Id> accountIds, List<Opportunity> opps) {
        if (opps == null) {
            return;
        }
        for (Opportunity opp : opps) {
            if (opp.AccountId != null) {
                accountIds.add(opp.AccountId);
            }
        }
    }

    @TestVisible
    private static void recalculateRollups(Set<Id> accountIds) {
        Date windowStart = Date.today().addMonths(-rolling12MonthsWindow);

        Map<Id, Decimal> closedWonAcvByAccount = new Map<Id, Decimal>();
        for (AggregateResult ar : [
            SELECT AccountId acctId, SUM(ACV__c) totalAcv
            FROM Opportunity
            WHERE AccountId IN :accountIds
                AND IsWon = true
                AND CloseDate >= :windowStart
            GROUP BY AccountId
        ]) {
            closedWonAcvByAccount.put((Id) ar.get('acctId'), (Decimal) ar.get('totalAcv'));
        }

        Map<Id, Decimal> openPipelineByAccount = new Map<Id, Decimal>();
        for (AggregateResult ar : [
            SELECT AccountId acctId, SUM(Amount) totalAmount
            FROM Opportunity
            WHERE AccountId IN :accountIds
                AND IsClosed = false
            GROUP BY AccountId
        ]) {
            openPipelineByAccount.put((Id) ar.get('acctId'), (Decimal) ar.get('totalAmount'));
        }

        List<Account> accountsToUpdate = new List<Account>();
        for (Id accountId : accountIds) {
            accountsToUpdate.add(new Account(
                Id = accountId,
                Closed_Won_ACV_L12M__c = closedWonAcvByAccount.containsKey(accountId) ? closedWonAcvByAccount.get(accountId) : 0,
                Open_Pipeline_Amount__c = openPipelineByAccount.containsKey(accountId) ? openPipelineByAccount.get(accountId) : 0
            ));
        }

        if (!accountsToUpdate.isEmpty()) {
            update accountsToUpdate;
        }
    }
}
