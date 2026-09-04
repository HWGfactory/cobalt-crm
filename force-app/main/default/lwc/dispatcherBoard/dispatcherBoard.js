import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getActiveWorkOrders from '@salesforce/apex/WorkOrderController.getActiveWorkOrders';
import reassign from '@salesforce/apex/WorkOrderController.reassign';

const POLL_INTERVAL_MS = 30000;

const STATUS_COLUMN_META = [
    { status: 'New', label: '신규 (New)', headerClass: 'column-header status-new' },
    { status: 'Assigned', label: '배정됨 (Assigned)', headerClass: 'column-header status-assigned' },
    { status: 'En Route', label: '이동 중 (En Route)', headerClass: 'column-header status-en-route' },
    { status: 'On Site', label: '현장 도착 (On Site)', headerClass: 'column-header status-on-site' },
    { status: 'Completed', label: '완료 (Completed)', headerClass: 'column-header status-completed' }
];

const PRIORITY_CLASS = {
    Emergency: 'priority-emergency',
    High: 'priority-high',
    Medium: 'priority-medium',
    Low: 'priority-low'
};

export default class DispatcherBoard extends LightningElement {
    summary = { totalCount: 0, unassignedCount: 0, inProgressCount: 0, completedCount: 0 };
    columns = [];
    technicians = [];
    technicianOptions = [];
    loadError;

    wiredResult;
    pollingHandle;

    @wire(getActiveWorkOrders)
    wiredWorkOrders(result) {
        this.wiredResult = result;
        const { data, error } = result;
        if (data) {
            this.loadError = undefined;
            this.summary = data.summary;
            this.columns = this.buildColumns(data.columns);
            this.technicians = data.technicians.map((tech) => this.toTechnicianViewModel(tech));
            this.technicianOptions = data.technicians.map((tech) => ({
                label: tech.name,
                value: tech.technicianId
            }));
        } else if (error) {
            this.loadError = this.extractErrorMessage(error);
        }
    }

    connectedCallback() {
        this.pollingHandle = setInterval(() => {
            refreshApex(this.wiredResult);
        }, POLL_INTERVAL_MS);
    }

    disconnectedCallback() {
        if (this.pollingHandle) {
            clearInterval(this.pollingHandle);
            this.pollingHandle = undefined;
        }
    }

    buildColumns(columns) {
        return STATUS_COLUMN_META.map((meta) => {
            const column = columns.find((c) => c.status === meta.status);
            const workOrders = column ? column.workOrders : [];
            return {
                status: meta.status,
                label: meta.label,
                headerClass: meta.headerClass,
                hasWorkOrders: workOrders.length > 0,
                workOrders: workOrders.map((wo) => this.toWorkOrderViewModel(wo))
            };
        });
    }

    toWorkOrderViewModel(wo) {
        const priorityClass = PRIORITY_CLASS[wo.priority] || 'priority-medium';
        return {
            ...wo,
            cardClass: `wo-card ${priorityClass}`,
            priorityBadgeClass: `priority-badge ${priorityClass}`,
            etaLabel: wo.eta ? new Date(wo.eta).toLocaleString() : '미정'
        };
    }

    toTechnicianViewModel(tech) {
        return {
            ...tech,
            availabilityLabel: tech.isAvailable ? '가용' : '작업 중',
            availabilityBadgeClass: `availability-badge ${tech.isAvailable ? 'available' : 'unavailable'}`
        };
    }

    handleCardClick(event) {
        const workOrderId = event.currentTarget.dataset.id;
        this.dispatchEvent(
            new CustomEvent('workorderselect', {
                detail: { workOrderId },
                bubbles: true,
                composed: true
            })
        );
    }

    stopPropagation(event) {
        event.stopPropagation();
    }

    async handleReassign(event) {
        event.stopPropagation();
        const workOrderId = event.target.dataset.id;
        const technicianId = event.detail.value;

        try {
            await reassign({ workOrderId, technicianId });
            this.dispatchEvent(
                new ShowToastEvent({
                    title: '재배정 완료',
                    message: '작업이 새 기술자에게 재배정되었습니다.',
                    variant: 'success'
                })
            );
            await refreshApex(this.wiredResult);
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: '재배정 실패',
                    message: this.extractErrorMessage(error),
                    variant: 'error'
                })
            );
        }
    }

    extractErrorMessage(error) {
        if (error && error.body && error.body.message) {
            return error.body.message;
        }
        return '데이터를 불러오는 중 오류가 발생했습니다.';
    }

    get hasError() {
        return !!this.loadError;
    }
}
