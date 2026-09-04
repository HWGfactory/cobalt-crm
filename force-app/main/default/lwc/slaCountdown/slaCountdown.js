import { LightningElement, api, wire } from 'lwc';
import { getRecord } from 'lightning/uiRecordApi';
import SLA_DEADLINE_FIELD from '@salesforce/schema/Work_Order__c.SLA_Deadline__c';
import CREATED_DATE_FIELD from '@salesforce/schema/Work_Order__c.CreatedDate';

const FIELDS = [SLA_DEADLINE_FIELD, CREATED_DATE_FIELD];
const TICK_INTERVAL_MS = 1000;

// 남은 시간 비율(remaining / total window) 기준값.
const RATIO_GREEN_THRESHOLD = 0.5;
const RATIO_ORANGE_THRESHOLD = 0.2;

export default class SlaCountdown extends LightningElement {
    @api recordId;

    hasDeadline = false;
    isOverdue = false;
    timeLabel = '--:--:--';
    severityClass = 'countdown-value severity-ok';
    loadError;

    deadlineTime;
    totalWindowMs;
    intervalId;

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS })
    wiredWorkOrder({ data, error }) {
        if (data) {
            this.loadError = undefined;
            const deadlineValue = data.fields.SLA_Deadline__c.value;
            const createdValue = data.fields.CreatedDate.value;

            if (deadlineValue) {
                this.hasDeadline = true;
                this.deadlineTime = new Date(deadlineValue).getTime();
                const createdTime = new Date(createdValue).getTime();
                // 총 허용 시간(SLA 부여 시점 ~ 마감)을 분모로 삼아 남은 시간의 비율을 계산한다.
                this.totalWindowMs = Math.max(this.deadlineTime - createdTime, 1);
                this.updateCountdown();
            } else {
                this.hasDeadline = false;
                this.timeLabel = '--:--:--';
            }
        } else if (error) {
            this.loadError = this.extractErrorMessage(error);
        }
    }

    connectedCallback() {
        this.intervalId = setInterval(() => {
            this.updateCountdown();
        }, TICK_INTERVAL_MS);
    }

    disconnectedCallback() {
        if (this.intervalId) {
            clearInterval(this.intervalId);
            this.intervalId = undefined;
        }
    }

    updateCountdown() {
        if (!this.hasDeadline || this.deadlineTime == null) {
            return;
        }
        const remainingMs = this.deadlineTime - Date.now();
        this.isOverdue = remainingMs <= 0;
        this.timeLabel = this.formatDuration(remainingMs);

        const ratio = remainingMs / this.totalWindowMs;
        this.severityClass = this.resolveSeverityClass(ratio, this.isOverdue);
    }

    formatDuration(ms) {
        const isNegative = ms < 0;
        const absMs = Math.abs(ms);
        const totalSeconds = Math.floor(absMs / 1000);
        const hours = Math.floor(totalSeconds / 3600);
        const minutes = Math.floor((totalSeconds % 3600) / 60);
        const seconds = totalSeconds % 60;
        const pad = (value) => String(value).padStart(2, '0');
        const formatted = `${pad(hours)}:${pad(minutes)}:${pad(seconds)}`;
        return isNegative ? `-${formatted}` : formatted;
    }

    resolveSeverityClass(ratio, isOverdue) {
        if (isOverdue || ratio < RATIO_ORANGE_THRESHOLD) {
            return 'countdown-value severity-critical';
        }
        if (ratio < RATIO_GREEN_THRESHOLD) {
            return 'countdown-value severity-warning';
        }
        return 'countdown-value severity-ok';
    }

    extractErrorMessage(error) {
        if (error && error.body && error.body.message) {
            return error.body.message;
        }
        return 'SLA 정보를 불러오는 중 오류가 발생했습니다.';
    }
}
