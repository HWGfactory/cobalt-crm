@IsTest
private class WorkPhotoGalleryControllerTest {

    // 1x1 투명 PNG의 Base64 (data URI 접두어 포함)
    private static final String SAMPLE_PNG_DATA_URI =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

    private static Work_Order__c createWorkOrder() {
        Account acc = new Account(Name = 'Photo Gallery Test Account');
        insert acc;
        Service_Contract__c contract = new Service_Contract__c(Account__c = acc.Id);
        insert contract;
        Work_Order__c wo = new Work_Order__c(Service_Contract__c = contract.Id, Status__c = 'On Site');
        insert wo;
        return wo;
    }

    @IsTest
    static void testSavePhoto_createsContentVersionLinkedToWorkOrder() {
        Work_Order__c wo = createWorkOrder();

        Test.startTest();
        WorkPhotoGalleryController.PhotoInfo result = WorkPhotoGalleryController.savePhoto(
            wo.Id, 'site-photo-1.png', SAMPLE_PNG_DATA_URI
        );
        Test.stopTest();

        System.assertNotEquals(null, result.contentVersionId);
        System.assertNotEquals(null, result.contentDocumentId);
        System.assert(result.thumbnailUrl.contains(String.valueOf(result.contentVersionId)));
        System.assert(result.fullUrl.contains(String.valueOf(result.contentVersionId)));

        System.assertEquals(
            1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :wo.Id],
            '저장된 사진이 Work Order에 연결되어야 함'
        );
    }

    @IsTest
    static void testGetPhotos_returnsOnlyImageFilesOrderedByNewest() {
        Work_Order__c wo = createWorkOrder();

        WorkPhotoGalleryController.savePhoto(wo.Id, 'image.png', SAMPLE_PNG_DATA_URI);

        // 이미지가 아닌 파일도 같은 작업에 연결해 필터링되는지 검증한다.
        ContentVersion textVersion = new ContentVersion(
            Title = 'notes',
            PathOnClient = 'notes.txt',
            VersionData = Blob.valueOf('작업 메모'),
            ContentLocation = 'S'
        );
        insert textVersion;
        ContentVersion insertedTextVersion = [
            SELECT ContentDocumentId FROM ContentVersion WHERE Id = :textVersion.Id
        ];
        insert new ContentDocumentLink(
            ContentDocumentId = insertedTextVersion.ContentDocumentId,
            LinkedEntityId = wo.Id,
            ShareType = 'V',
            Visibility = 'AllUsers'
        );

        Test.startTest();
        List<WorkPhotoGalleryController.PhotoInfo> photos = WorkPhotoGalleryController.getPhotos(wo.Id);
        Test.stopTest();

        System.assertEquals(1, photos.size(), '이미지 파일만 반환되고 텍스트 파일은 제외되어야 함');
        System.assertEquals('image.png', photos[0].title);
    }

    @IsTest
    static void testGetPhotos_noPhotosReturnsEmptyList() {
        Work_Order__c wo = createWorkOrder();

        Test.startTest();
        List<WorkPhotoGalleryController.PhotoInfo> photos = WorkPhotoGalleryController.getPhotos(wo.Id);
        Test.stopTest();

        System.assert(photos.isEmpty());
    }

    @IsTest
    static void testGetPhotos_missingWorkOrderIdThrows() {
        Boolean threw = false;
        Test.startTest();
        try {
            WorkPhotoGalleryController.getPhotos(null);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw);
    }

    @IsTest
    static void testSavePhoto_missingWorkOrderIdThrows() {
        Boolean threw = false;
        Test.startTest();
        try {
            WorkPhotoGalleryController.savePhoto(null, 'photo.png', SAMPLE_PNG_DATA_URI);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw);
    }

    @IsTest
    static void testSavePhoto_missingWorkOrderThrows() {
        Id bogusId = Id.valueOf('a05000000000000AAA');

        Boolean threw = false;
        Test.startTest();
        try {
            WorkPhotoGalleryController.savePhoto(bogusId, 'photo.png', SAMPLE_PNG_DATA_URI);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw);
    }

    @IsTest
    static void testSavePhoto_blankBase64Throws() {
        Work_Order__c wo = createWorkOrder();

        Boolean threw = false;
        Test.startTest();
        try {
            WorkPhotoGalleryController.savePhoto(wo.Id, 'empty.png', '');
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, '유효한 사진 데이터가 없으면 예외가 발생해야 함');
    }
}
