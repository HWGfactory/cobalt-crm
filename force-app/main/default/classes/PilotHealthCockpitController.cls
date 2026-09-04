public with sharing class PilotHealthCockpitController {

    @AuraEnabled(cacheable=true)
    public static CockpitData getCockpitData(Id opportunityId) {
        if (opportunityId == null) {
            AuraHandledException ex = new AuraHandledException('Opportunity Id가 필요합니다.');
            ex.setMessage('Opportunity Id가 필요합니다.');
            throw ex;
        }

        CockpitData result = new CockpitData();
        result.meddic = buildMeddicScorecard(opportunityId);
        result.pilots = buildPilotSummaries(opportunityId);
        return result;
    }

    private static MeddicScorecard buildMeddicScorecard(Id opportunityId) {
        List<Opportunity> opps = [
            SELECT Metrics__c, Economic_Buyer__c, Decision_Criteria__c, Decision_Process__c,
                   Identify_Pain__c, Champion__c, MEDDIC_Score__c
            FROM Opportunity
            WHERE Id = :opportunityId
            WITH USER_MODE
            LIMIT 1
        ];

        MeddicScorecard scorecard = new MeddicScorecard();
        if (opps.isEmpty()) {
            scorecard.completionPct = 0;
            scorecard.fields = buildMeddicFields(null);
            return scorecard;
        }

        Opportunity opp = opps[0];
        scorecard.completionPct = opp.MEDDIC_Score__c != null ? opp.MEDDIC_Score__c : 0;
        scorecard.fields = buildMeddicFields(opp);
        return scorecard;
    }

    private static List<MeddicFieldStatus> buildMeddicFields(Opportunity opp) {
        return new List<MeddicFieldStatus>{
            new MeddicFieldStatus('Metrics', opp != null && String.isNotBlank(opp.Metrics__c)),
            new MeddicFieldStatus('Economic Buyer', opp != null && String.isNotBlank(opp.Economic_Buyer__c)),
            new MeddicFieldStatus('Decision Criteria', opp != null && String.isNotBlank(opp.Decision_Criteria__c)),
            new MeddicFieldStatus('Decision Process', opp != null && String.isNotBlank(opp.Decision_Process__c)),
            new MeddicFieldStatus('Identify Pain', opp != null && String.isNotBlank(opp.Identify_Pain__c)),
            new MeddicFieldStatus('Champion', opp != null && String.isNotBlank(opp.Champion__c))
        };
    }

    private static List<PilotSummary> buildPilotSummaries(Id opportunityId) {
        List<PilotSummary> summaries = new List<PilotSummary>();
        Date today = Date.today();

        for (Pilot__c pilot : [
            SELECT Name, Start_Date__c, End_Date__c, Pilot_Health__c, Technician_Count__c
            FROM Pilot__c
            WHERE Opportunity__c = :opportunityId
            WITH USER_MODE
            ORDER BY End_Date__c ASC NULLS LAST
        ]) {
            PilotSummary summary = new PilotSummary();
            summary.pilotId = pilot.Id;
            summary.name = pilot.Name;
            summary.startDate = pilot.Start_Date__c;
            summary.endDate = pilot.End_Date__c;
            summary.health = pilot.Pilot_Health__c;
            summary.technicianCount = pilot.Technician_Count__c;
            summary.daysRemaining = pilot.End_Date__c != null ? today.daysBetween(pilot.End_Date__c) : null;
            summaries.add(summary);
        }
        return summaries;
    }

    public class CockpitData {
        @AuraEnabled public MeddicScorecard meddic;
        @AuraEnabled public List<PilotSummary> pilots;
    }

    public class MeddicScorecard {
        @AuraEnabled public Decimal completionPct;
        @AuraEnabled public List<MeddicFieldStatus> fields;
    }

    public class MeddicFieldStatus {
        @AuraEnabled public String label;
        @AuraEnabled public Boolean isFilled;

        public MeddicFieldStatus(String label, Boolean isFilled) {
            this.label = label;
            this.isFilled = isFilled;
        }
    }

    public class PilotSummary {
        @AuraEnabled public Id pilotId;
        @AuraEnabled public String name;
        @AuraEnabled public Date startDate;
        @AuraEnabled public Date endDate;
        @AuraEnabled public String health;
        @AuraEnabled public Decimal technicianCount;
        @AuraEnabled public Integer daysRemaining;
    }
}
