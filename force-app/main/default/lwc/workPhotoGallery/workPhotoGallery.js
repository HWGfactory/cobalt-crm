import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getPhotos from '@salesforce/apex/WorkPhotoGalleryController.getPhotos';
import savePhotos from '@salesforce/apex/WorkPhotoGalleryController.savePhotos';

export default class WorkPhotoGallery extends LightningElement {
    @api recordId;

    photos = [];
    loadError;

    lightboxOpen = false;
    lightboxIndex = 0;

    connectedCallback() {
        if (this.recordId) {
            this.loadPhotos();
        }
        window.addEventListener('keydown', this.handleKeydown);
    }

    disconnectedCallback() {
        window.removeEventListener('keydown', this.handleKeydown);
    }

    async loadPhotos() {
        try {
            const result = await getPhotos({ workOrderId: this.recordId });
            this.photos = result.map((photo) => this.toPhotoViewModel(photo));
            this.loadError = undefined;
        } catch (error) {
            this.loadError = this.extractErrorMessage(error);
        }
    }

    toPhotoViewModel(photo) {
        return {
            key: photo.contentVersionId,
            contentVersionId: photo.contentVersionId,
            title: photo.title,
            thumbnailUrl: photo.thumbnailUrl,
            fullUrl: photo.fullUrl,
            isPending: false
        };
    }

    handleFilesSelected(event) {
        const files = Array.from(event.target.files || []);
        files.forEach((file) => this.readFileForPreview(file));
        // 같은 파일을 다시 선택해도 change 이벤트가 발생하도록 입력값을 초기화한다.
        event.target.value = '';
    }

    readFileForPreview(file) {
        const reader = new FileReader();
        reader.onload = () => {
            const dataUrl = reader.result;
            const pendingPhoto = {
                key: 'pending-' + Date.now() + '-' + Math.random(),
                contentVersionId: null,
                title: file.name,
                thumbnailUrl: dataUrl,
                fullUrl: dataUrl,
                isPending: true,
                base64Data: dataUrl,
                fileName: file.name
            };
            this.photos = [...this.photos, pendingPhoto];
            this.uploadPendingPhoto(pendingPhoto);
        };
        reader.onerror = () => {
            this.showToast('오류', file.name + ' 파일을 읽을 수 없습니다.', 'error');
        };
        reader.readAsDataURL(file);
    }

    async uploadPendingPhoto(pendingPhoto) {
        try {
            const saved = await savePhotos({
                workOrderId: this.recordId,
                photos: [{ fileName: pendingPhoto.fileName, base64Data: pendingPhoto.base64Data }]
            });
            const savedPhoto = this.toPhotoViewModel(saved[0]);
            // 로컬 미리보기(pending) 항목을 서버에 저장된 실제 항목으로 교체한다.
            this.photos = this.photos.map((photo) => (photo.key === pendingPhoto.key ? savedPhoto : photo));
            this.showToast('업로드 완료', pendingPhoto.fileName + ' 저장되었습니다.', 'success');
        } catch (error) {
            this.photos = this.photos.filter((photo) => photo.key !== pendingPhoto.key);
            this.showToast('업로드 실패', this.extractErrorMessage(error), 'error');
        }
    }

    handleThumbnailClick(event) {
        const key = event.currentTarget.dataset.key;
        const index = this.photos.findIndex((photo) => photo.key === key);
        if (index === -1) {
            return;
        }
        this.lightboxIndex = index;
        this.lightboxOpen = true;
    }

    closeLightbox() {
        this.lightboxOpen = false;
    }

    showPrevious() {
        if (!this.lightboxOpen || this.photos.length === 0) {
            return;
        }
        this.lightboxIndex = (this.lightboxIndex - 1 + this.photos.length) % this.photos.length;
    }

    showNext() {
        if (!this.lightboxOpen || this.photos.length === 0) {
            return;
        }
        this.lightboxIndex = (this.lightboxIndex + 1) % this.photos.length;
    }

    stopPropagation(event) {
        event.stopPropagation();
    }

    handleKeydown = (event) => {
        if (!this.lightboxOpen) {
            return;
        }
        if (event.key === 'Escape') {
            this.closeLightbox();
        } else if (event.key === 'ArrowLeft') {
            this.showPrevious();
        } else if (event.key === 'ArrowRight') {
            this.showNext();
        }
    };

    get currentPhoto() {
        return this.photos[this.lightboxIndex];
    }

    get hasPhotos() {
        return this.photos.length > 0;
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
