public with sharing class WorkPhotoGalleryController {

    private static final Set<String> IMAGE_FILE_TYPES = new Set<String>{
        'JPG', 'JPEG', 'PNG', 'GIF', 'BMP', 'WEBP', 'HEIC'
    };

    public class PhotoInfo {
        @AuraEnabled public Id contentVersionId;
        @AuraEnabled public Id contentDocumentId;
        @AuraEnabled public String title;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public String thumbnailUrl;
        @AuraEnabled public String fullUrl;
    }

    @AuraEnabled(cacheable=true)
    public static List<PhotoInfo> getPhotos(Id workOrderId) {
        if (workOrderId == null) {
            throw new AuraHandledException('작업 Id가 필요합니다.');
        }

        List<PhotoInfo> results = new List<PhotoInfo>();
        for (ContentDocumentLink link : [
            SELECT ContentDocumentId, ContentDocument.Title, ContentDocument.CreatedDate,
                   ContentDocument.LatestPublishedVersionId, ContentDocument.FileType
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :workOrderId
            WITH USER_MODE
            ORDER BY ContentDocument.CreatedDate DESC
        ]) {
            if (!IMAGE_FILE_TYPES.contains(String.valueOf(link.ContentDocument.FileType).toUpperCase())) {
                continue;
            }
            // FieldCompletionController가 고객 서명을 같은 Work Order에 동일한 방식(ContentVersion
            // + ContentDocumentLink)으로 첨부하므로, 파일 제목 접두어로 서명 파일을 갤러리에서 제외한다.
            if (String.valueOf(link.ContentDocument.Title).startsWith('Signature_')) {
                continue;
            }
            results.add(toPhotoInfo(link.ContentDocument.LatestPublishedVersionId, link.ContentDocumentId,
                link.ContentDocument.Title, link.ContentDocument.CreatedDate));
        }
        return results;
    }

    @AuraEnabled
    public static PhotoInfo savePhoto(Id workOrderId, String fileName, String base64Data) {
        if (workOrderId == null) {
            throw new AuraHandledException('작업 Id가 필요합니다.');
        }
        if (String.isBlank(base64Data)) {
            throw new AuraHandledException('유효한 사진 데이터가 없습니다.');
        }

        List<Work_Order__c> workOrders = [
            SELECT Id FROM Work_Order__c WHERE Id = :workOrderId WITH USER_MODE LIMIT 1
        ];
        if (workOrders.isEmpty()) {
            throw new AuraHandledException('작업을 찾을 수 없습니다.');
        }

        String cleanBase64 = base64Data.contains(',') ? base64Data.substringAfter(',') : base64Data;

        Blob photoBlob;
        try {
            photoBlob = EncodingUtil.base64Decode(cleanBase64);
        } catch (Exception ex) {
            throw new AuraHandledException('사진 데이터를 디코딩할 수 없습니다: ' + fileName);
        }

        String resolvedFileName = String.isNotBlank(fileName)
            ? fileName
            : ('Photo_' + Datetime.now().getTime() + '.jpg');

        ContentVersion version = new ContentVersion(
            Title = resolvedFileName,
            PathOnClient = resolvedFileName,
            VersionData = photoBlob,
            ContentLocation = 'S'
        );
        try {
            insert version;
        } catch (DmlException ex) {
            throw new AuraHandledException('사진 저장 중 오류가 발생했습니다: ' + ex.getMessage());
        }

        ContentVersion inserted = [
            SELECT Id, ContentDocumentId, Title, CreatedDate
            FROM ContentVersion
            WHERE Id = :version.Id
            WITH USER_MODE
            LIMIT 1
        ];

        ContentDocumentLink link = new ContentDocumentLink(
            ContentDocumentId = inserted.ContentDocumentId,
            LinkedEntityId = workOrderId,
            ShareType = 'V',
            Visibility = 'AllUsers'
        );
        try {
            insert link;
        } catch (DmlException ex) {
            throw new AuraHandledException('사진을 작업에 연결하는 중 오류가 발생했습니다: ' + ex.getMessage());
        }

        return toPhotoInfo(inserted.Id, inserted.ContentDocumentId, inserted.Title, inserted.CreatedDate);
    }

    private static PhotoInfo toPhotoInfo(Id contentVersionId, Id contentDocumentId, String title, Datetime createdDate) {
        PhotoInfo info = new PhotoInfo();
        info.contentVersionId = contentVersionId;
        info.contentDocumentId = contentDocumentId;
        info.title = title;
        info.createdDate = createdDate;
        info.thumbnailUrl = '/sfc/servlet.shepherd/version/renditionDownload?rendition=THUMB240BY180&versionId=' + contentVersionId;
        info.fullUrl = '/sfc/servlet.shepherd/version/download/' + contentVersionId;
        return info;
    }
}
