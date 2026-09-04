import { createElement } from 'lwc';
import { registerApexTestWireAdapter } from '@salesforce/sfdx-lwc-jest';
import PilotHealthCockpit from 'c/pilotHealthCockpit';
import getCockpitData from '@salesforce/apex/PilotHealthCockpitController.getCockpitData';

const getCockpitDataAdapter = registerApexTestWireAdapter(getCockpitData);

const FULLY_QUALIFIED_DATA = {
    meddic: {
        completionPct: 100,
        fields: [
            { label: 'Metrics', isFilled: true },
            { label: 'Economic Buyer', isFilled: true },
            { label: 'Decision Criteria', isFilled: true },
            { label: 'Decision Process', isFilled: true },
            { label: 'Identify Pain', isFilled: true },
            { label: 'Champion', isFilled: true }
        ]
    },
    pilots: [
        {
            pilotId: 'a00000000000001',
            name: 'Healthy Pilot',
            startDate: '2026-08-01',
            endDate: '2026-09-10',
            health: 'Healthy',
            technicianCount: 8,
            daysRemaining: 5
        }
    ]
};

const EMPTY_DATA = {
    meddic: {
        completionPct: 0,
        fields: [
            { label: 'Metrics', isFilled: false },
            { label: 'Economic Buyer', isFilled: false },
            { label: 'Decision Criteria', isFilled: false },
            { label: 'Decision Process', isFilled: false },
            { label: 'Identify Pain', isFilled: false },
            { label: 'Champion', isFilled: false }
        ]
    },
    pilots: []
};

describe('c-pilot-health-cockpit', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders pilot health badge and MEDDIC completion percentage when data is fully populated', async () => {
        const element = createElement('c-pilot-health-cockpit', {
            is: PilotHealthCockpit
        });
        element.recordId = '006000000000001';
        document.body.appendChild(element);

        getCockpitDataAdapter.emit(FULLY_QUALIFIED_DATA);
        await Promise.resolve();

        const progressRing = element.shadowRoot.querySelector('lightning-progress-ring');
        expect(progressRing.value).toBe(100);

        const badge = element.shadowRoot.querySelector('.slds-badge');
        expect(badge.textContent).toContain('Healthy');

        const ddayText = element.shadowRoot.querySelector('p.slds-text-heading_small.slds-m-top_xx-small');
        expect(ddayText.textContent).toBe('D-5');
    });

    it('renders an empty state and 0% scorecard when there is no pilot or MEDDIC data', async () => {
        const element = createElement('c-pilot-health-cockpit', {
            is: PilotHealthCockpit
        });
        element.recordId = '006000000000002';
        document.body.appendChild(element);

        getCockpitDataAdapter.emit(EMPTY_DATA);
        await Promise.resolve();

        const progressRing = element.shadowRoot.querySelector('lightning-progress-ring');
        expect(progressRing.value).toBe(0);
        expect(progressRing.variant).toBe('expired');

        const emptyState = element.shadowRoot.querySelector('.slds-illustration');
        expect(emptyState.textContent).toContain('연결된 Pilot 레코드가 없습니다');

        const badges = element.shadowRoot.querySelectorAll('.slds-badge');
        expect(badges.length).toBe(0);
    });

    it('shows an error message when the wire service returns an error', async () => {
        const element = createElement('c-pilot-health-cockpit', {
            is: PilotHealthCockpit
        });
        element.recordId = '006000000000003';
        document.body.appendChild(element);

        getCockpitDataAdapter.error({ message: 'insufficient access' });
        await Promise.resolve();

        const errorEl = element.shadowRoot.querySelector('.slds-text-color_error');
        expect(errorEl.textContent).toBe('insufficient access');
    });
});
