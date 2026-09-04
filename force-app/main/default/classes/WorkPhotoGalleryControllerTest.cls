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
    static void testSavePhotos_createsContentVersionsLinkedToWorkOrder() {
        Work_Order__c wo = createWorkOrder();

        WorkPhotoGalleryController.PhotoInput photo1 = new WorkPhotoGalleryController.PhotoInput();
        photo1.fileName = 'site-photo-1.png';
        photo1.base64Data = SAMPLE_PNG_DATA_URI;

        WorkPhotoGalleryController.PhotoInput photo2 = new WorkPhotoGalleryController.PhotoInput();
        photo2.fileName = 'site-photo-2.png';
        photo2.base64Data = SAMPLE_PNG_DATA_URI;

        Test.startTest();
        List<WorkPhotoGalleryController.PhotoInfo> results = WorkPhotoGalleryController.savePhotos(
            wo.Id, new List<WorkPhotoGalleryController.PhotoInput>{ photo1, photo2 }
        );
        Test.stopTest();

        System.assertEquals(2, results.size());
        for (WorkPhotoGalleryController.PhotoInfo info : results) {
            System.assertNotEquals(null, info.contentVersionId);
            System.assertNotEquals(null, info.contentDocumentId);
            System.assert(info.thumbnailUrl.contains(String.valueOf(info.contentVersionId)));
            System.assert(info.fullUrl.contains(String.valueOf(info.contentVersionId)));
        }

        System.assertEquals(
            2, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :wo.Id],
            '저장된 사진 수만큼 Work Order에 파일이 연결되어야 함'
        );
    }

    @IsTest
    static void testGetPhotos_returnsOnlyImageFilesOrderedByNewest() {
        Work_Order__c wo = createWorkOrder();

        WorkPhotoGalleryController.PhotoInput photo = new WorkPhotoGalleryController.PhotoInput();
        photo.fileName = 'image.png';
        photo.base64Data = SAMPLE_PNG_DATA_URI;
        WorkPhotoGalleryController.savePhotos(wo.Id, new List<WorkPhotoGalleryController.PhotoInput>{ photo });

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
    static void testSavePhotos_missingWorkOrderThrows() {
        WorkPhotoGalleryController.PhotoInput photo = new WorkPhotoGalleryController.PhotoInput();
        photo.fileName = 'photo.png';
        photo.base64Data = SAMPLE_PNG_DATA_URI;

        Boolean threw = false;
        Test.startTest();
        try {
            WorkPhotoGalleryController.savePhotos(null, new List<WorkPhotoGalleryController.PhotoInput>{ photo });
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw);
    }

    @IsTest
    static void testSavePhotos_emptyListThrows() {
        Work_Order__c wo = createWorkOrder();

        Boolean threw = false;
        Test.startTest();
        try {
            WorkPhotoGalleryController.savePhotos(wo.Id, new List<WorkPhotoGalleryController.PhotoInput>());
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw);
    }

    @IsTest
    static void testSavePhotos_blankBase64ItemsAreSkippedAndAllBlankThrows() {
        Work_Order__c wo = createWorkOrder();

        WorkPhotoGalleryController.PhotoInput blankPhoto = new WorkPhotoGalleryController.PhotoInput();
        blankPhoto.fileName = 'empty.png';
        blankPhoto.base64Data = '';

        Boolean threw = false;
        Test.startTest();
        try {
            WorkPhotoGalleryController.savePhotos(wo.Id, new List<WorkPhotoGalleryController.PhotoInput>{ blankPhoto });
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, '유효한 사진 데이터가 하나도 없으면 예외가 발생해야 함');
    }
}
