import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getWorkOrderSummary from '@salesforce/apex/FieldCompletionController.getWorkOrderSummary';
import saveSignature from '@salesforce/apex/FieldCompletionController.saveSignature';
import completeWorkOrder from '@salesforce/apex/FieldCompletionController.completeWorkOrder';

const CHECKLIST_TEMPLATE = [
    { key: 'explain', label: '작업 내용을 고객에게 설명함' },
    { key: 'parts', label: '사용된 부품을 기록함' },
    { key: 'cleanup', label: '작업 현장을 정리함' },
    { key: 'satisfaction', label: '고객이 결과에 만족함을 확인함' }
];

export default class FieldCompletion extends LightningElement {
    @api recordId;

    summary;
    loadError;
    checklistItems = CHECKLIST_TEMPLATE.map((item) => ({ ...item, checked: false }));
    uploadedPhotoCount = 0;
    isSaving = false;
    hasSignature = false;
    acceptedFormats = ['.png', '.jpg', '.jpeg', '.heic', '.pdf'];

    canvasContext;
    isDrawing = false;
    canvasInitialized = false;

    connectedCallback() {
        if (this.recordId) {
            this.loadSummary();
        }
    }

    renderedCallback() {
        if (this.canvasInitialized) {
            return;
        }
        this.initializeCanvas();
    }

    async loadSummary() {
        try {
            this.summary = await getWorkOrderSummary({ workOrderId: this.recordId });
            this.loadError = undefined;
        } catch (error) {
            this.loadError = this.extractErrorMessage(error);
        }
    }

    initializeCanvas() {
        const canvas = this.getCanvas();
        if (!canvas) {
            return;
        }
        // 캔버스의 실제 픽셀 해상도를 화면에 표시되는 크기와 맞춰서
        // 터치/마우스 좌표와 그려지는 위치가 어긋나지 않도록 한다.
        const rect = canvas.getBoundingClientRect();
        canvas.width = rect.width;
        canvas.height = rect.height;

        const ctx = canvas.getContext('2d');
        ctx.lineWidth = 2.5;
        ctx.lineCap = 'round';
        ctx.lineJoin = 'round';
        ctx.strokeStyle = '#16325c';
        this.canvasContext = ctx;
        this.canvasInitialized = true;
    }

    getCanvas() {
        return this.template.querySelector('.signature-canvas');
    }

    getPointerPosition(event) {
        const canvas = this.getCanvas();
        const rect = canvas.getBoundingClientRect();
        let clientX;
        let clientY;

        if (event.touches && event.touches.length > 0) {
            clientX = event.touches[0].clientX;
            clientY = event.touches[0].clientY;
        } else if (event.changedTouches && event.changedTouches.length > 0) {
            clientX = event.changedTouches[0].clientX;
            clientY = event.changedTouches[0].clientY;
        } else {
            clientX = event.clientX;
            clientY = event.clientY;
        }

        return {
            x: clientX - rect.left,
            y: clientY - rect.top
        };
    }

    handlePointerDown(event) {
        event.preventDefault();
        if (!this.canvasContext) {
            this.initializeCanvas();
        }
        this.isDrawing = true;
        const { x, y } = this.getPointerPosition(event);
        this.canvasContext.beginPath();
        this.canvasContext.moveTo(x, y);
    }

    handlePointerMove(event) {
        if (!this.isDrawing) {
            return;
        }
        event.preventDefault();
        const { x, y } = this.getPointerPosition(event);
        this.canvasContext.lineTo(x, y);
        this.canvasContext.stroke();
        this.hasSignature = true;
    }

    handlePointerUp(event) {
        if (!this.isDrawing) {
            return;
        }
        event.preventDefault();
        this.isDrawing = false;
        this.canvasContext.closePath();
    }

    handleClearSignature() {
        const canvas = this.getCanvas();
        if (this.canvasContext) {
            this.canvasContext.clearRect(0, 0, canvas.width, canvas.height);
        }
        this.hasSignature = false;
    }

    handleChecklistChange(event) {
        const key = event.target.dataset.key;
        const checked = event.target.checked;
        this.checklistItems = this.checklistItems.map((item) =>
            item.key === key ? { ...item, checked } : item
        );
    }

    handleUploadFinished(event) {
        const uploadedFiles = event.detail.files;
        this.uploadedPhotoCount += uploadedFiles.length;
    }

    get hasSummary() {
        return !!this.summary;
    }

    get hasUploadedPhotos() {
        return this.uploadedPhotoCount > 0;
    }

    get isChecklistComplete() {
        return this.checklistItems.every((item) => item.checked);
    }

    get isCompleteDisabled() {
        return this.isSaving;
    }

    async handleComplete() {
        if (!this.isChecklistComplete) {
            this.showToast('체크리스트 미완료', '모든 체크리스트 항목을 확인해야 합니다.', 'warning');
            return;
        }
        if (!this.hasSignature) {
            this.showToast('서명 필요', '고객 서명을 받아야 작업을 완료할 수 있습니다.', 'warning');
            return;
        }

        this.isSaving = true;
        try {
            const canvas = this.getCanvas();
            const base64Data = canvas.toDataURL('image/png');

            await saveSignature({ workOrderId: this.recordId, base64Data });

            const checklist = this.checklistItems.filter((item) => item.checked).map((item) => item.label);
            await completeWorkOrder({ workOrderId: this.recordId, checklist });

            this.showToast('작업 완료', '작업이 완료 처리되었습니다.', 'success');
            this.dispatchEvent(
                new CustomEvent('completed', {
                    detail: { workOrderId: this.recordId },
                    bubbles: true,
                    composed: true
                })
            );
        } catch (error) {
            this.showToast('처리 실패', this.extractErrorMessage(error), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    extractErrorMessage(error) {
        if (error && error.body && error.body.message) {
            return error.body.message;
        }
        return '요청을 처리하는 중 오류가 발생했습니다.';
    }
}
