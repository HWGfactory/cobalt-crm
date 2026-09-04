public with sharing class WorkPhotoGalleryController {

    private static final Set<String> IMAGE_FILE_TYPES = new Set<String>{
        'JPG', 'JPEG', 'PNG', 'GIF', 'BMP', 'WEBP', 'HEIC'
    };

    public class PhotoInput {
        @AuraEnabled public String fileName;
        @AuraEnabled public String base64Data;
    }

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
    public static List<PhotoInfo> savePhotos(Id workOrderId, List<PhotoInput> photos) {
        if (workOrderId == null) {
            throw new AuraHandledException('작업 Id가 필요합니다.');
        }
        if (photos == null || photos.isEmpty()) {
            throw new AuraHandledException('저장할 사진이 없습니다.');
        }

        List<Work_Order__c> workOrders = [
            SELECT Id FROM Work_Order__c WHERE Id = :workOrderId WITH USER_MODE LIMIT 1
        ];
        if (workOrders.isEmpty()) {
            throw new AuraHandledException('작업을 찾을 수 없습니다.');
        }

        List<ContentVersion> versionsToInsert = new List<ContentVersion>();
        for (PhotoInput photo : photos) {
            if (String.isBlank(photo.base64Data)) {
                continue;
            }

            String cleanBase64 = photo.base64Data.contains(',')
                ? photo.base64Data.substringAfter(',')
                : photo.base64Data;

            Blob photoBlob;
            try {
                photoBlob = EncodingUtil.base64Decode(cleanBase64);
            } catch (Exception ex) {
                throw new AuraHandledException('사진 데이터를 디코딩할 수 없습니다: ' + photo.fileName);
            }

            String fileName = String.isNotBlank(photo.fileName)
                ? photo.fileName
                : ('Photo_' + Datetime.now().getTime() + '.jpg');

            versionsToInsert.add(new ContentVersion(
                Title = fileName,
                PathOnClient = fileName,
                VersionData = photoBlob,
                ContentLocation = 'S'
            ));
        }

        if (versionsToInsert.isEmpty()) {
            throw new AuraHandledException('유효한 사진 데이터가 없습니다.');
        }

        try {
            insert versionsToInsert;
        } catch (DmlException ex) {
            throw new AuraHandledException('사진 저장 중 오류가 발생했습니다: ' + ex.getMessage());
        }

        Set<Id> versionIds = new Map<Id, ContentVersion>(versionsToInsert).keySet();
        Map<Id, ContentVersion> insertedVersions = new Map<Id, ContentVersion>([
            SELECT Id, ContentDocumentId, Title, CreatedDate
            FROM ContentVersion
            WHERE Id IN :versionIds
            WITH USER_MODE
        ]);

        List<ContentDocumentLink> links = new List<ContentDocumentLink>();
        for (ContentVersion cv : insertedVersions.values()) {
            links.add(new ContentDocumentLink(
                ContentDocumentId = cv.ContentDocumentId,
                LinkedEntityId = workOrderId,
                ShareType = 'V',
                Visibility = 'AllUsers'
            ));
        }

        try {
            insert links;
        } catch (DmlException ex) {
            throw new AuraHandledException('사진을 작업에 연결하는 중 오류가 발생했습니다: ' + ex.getMessage());
        }

        List<PhotoInfo> results = new List<PhotoInfo>();
        for (ContentVersion cv : insertedVersions.values()) {
            results.add(toPhotoInfo(cv.Id, cv.ContentDocumentId, cv.Title, cv.CreatedDate));
        }
        return results;
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
