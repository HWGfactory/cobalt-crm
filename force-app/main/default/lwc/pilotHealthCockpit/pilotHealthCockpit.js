import { LightningElement, api, wire } from 'lwc';
import getCockpitData from '@salesforce/apex/PilotHealthCockpitController.getCockpitData';

const HEALTH_BADGE_CLASS = {
    Healthy: 'slds-badge slds-theme_success',
    'At Risk': 'slds-badge slds-theme_warning',
    Stalled: 'slds-badge slds-theme_error'
};

const HEALTH_ICON = {
    Healthy: 'utility:success',
    'At Risk': 'utility:warning',
    Stalled: 'utility:error'
};

export default class PilotHealthCockpit extends LightningElement {
    @api recordId;

    pilots = [];
    meddicFields = [];
    completionPct = 0;
    hasLoaded = false;
    loadError;

    @wire(getCockpitData, { opportunityId: '$recordId' })
    wiredCockpit({ data, error }) {
        this.hasLoaded = true;
        if (data) {
            this.loadError = undefined;
            this.completionPct = data.meddic.completionPct != null ? data.meddic.completionPct : 0;
            this.meddicFields = data.meddic.fields.map((field) => ({
                label: field.label,
                iconName: field.isFilled ? 'utility:success' : 'utility:close',
                iconVariant: field.isFilled ? 'success' : 'error',
                textClass: field.isFilled ? 'slds-text-color_default' : 'slds-text-color_weak'
            }));
            this.pilots = data.pilots.map((pilot) => this.toPilotViewModel(pilot));
        } else if (error) {
            this.loadError = this.extractErrorMessage(error);
            this.pilots = [];
            this.meddicFields = [];
        }
    }

    toPilotViewModel(pilot) {
        const dday = pilot.daysRemaining;
        let ddayLabel;
        let ddayClass = 'slds-text-heading_small slds-m-top_xx-small';

        if (dday === null || dday === undefined) {
            ddayLabel = '종료일 미정';
        } else if (dday > 0) {
            ddayLabel = `D-${dday}`;
            if (dday <= 5) {
                ddayClass += ' slds-text-color_error';
            }
        } else if (dday === 0) {
            ddayLabel = 'D-Day';
            ddayClass += ' slds-text-color_error';
        } else {
            ddayLabel = `D+${Math.abs(dday)} 지연`;
            ddayClass += ' slds-text-color_error';
        }

        return {
            pilotId: pilot.pilotId,
            name: pilot.name,
            startDate: pilot.startDate,
            endDate: pilot.endDate,
            technicianCount: pilot.technicianCount,
            health: pilot.health,
            healthBadgeClass: HEALTH_BADGE_CLASS[pilot.health] || 'slds-badge',
            healthIcon: HEALTH_ICON[pilot.health] || 'utility:info',
            ddayLabel,
            ddayClass
        };
    }

    extractErrorMessage(error) {
        if (error && error.body && error.body.message) {
            return error.body.message;
        }
        return '데이터를 불러오는 중 오류가 발생했습니다.';
    }

    get hasPilots() {
        return this.pilots.length > 0;
    }

    get completionPctLabel() {
        return `${this.completionPct}%`;
    }

    get ringVariant() {
        if (this.completionPct >= 80) {
            return 'base-autocomplete';
        }
        if (this.completionPct >= 40) {
            return 'warning';
        }
        return 'expired';
    }
}
