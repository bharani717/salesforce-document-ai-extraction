/**
 * Tests for the document extraction pipeline. A stub client replaces Document AI,
 * so no callouts or credits are used.
 *
 * Note: Application__c is the example target object. Populate any required fields
 * of your own object in newApplication().
 */
@IsTest
private class DocumentExtractionTest {

    private static final String CONFIG = 'Application_Form_Extraction';

    // ------------------------------------------------------------------
    // Test doubles and helpers
    // ------------------------------------------------------------------

    private class StubClient implements DocumentAIClients.Client {
        private final String json;
        private final Boolean needsReview;
        private final Boolean fail;

        StubClient(String json, Boolean needsReview, Boolean fail) {
            this.json = json;
            this.needsReview = needsReview;
            this.fail = fail;
        }

        public DocumentAIClients.Result extract(Document_Extraction__c staging) {
            if (fail) {
                throw new DocumentAIClients.ExtractionException('Simulated Document AI outage');
            }
            DocumentAIClients.Result result = new DocumentAIClients.Result();
            result.extractedJson = json;
            result.needsManualReview = needsReview;
            return result;
        }
    }

    private static void configure(StubClient stub) {
        DocumentAIClients.instance = stub;
        DocumentAIClients.settingsOverride = new Document_AI_Setting__mdt(
            Use_REST_API__c = false,
            Default_Configuration__c = CONFIG,
            Named_Credential__c = 'DocumentAI_Self',
            API_Version__c = 'v66.0'
        );
        DocumentMappingService.mappingOverride = new List<Document_Field_Mapping__mdt>{
            new Document_Field_Mapping__mdt(
                Configuration_Name__c = CONFIG, Extracted_Field_Name__c = 'applicant name',
                Target_Field__c = 'Applicant_Name__c', Data_Type__c = 'Text', Required__c = true),
            new Document_Field_Mapping__mdt(
                Configuration_Name__c = CONFIG, Extracted_Field_Name__c = 'date of birth',
                Target_Field__c = 'Date_of_Birth__c', Data_Type__c = 'Date', Required__c = false)
        };
    }

    private static String extraction(String applicantName, String dateOfBirth, Boolean flagged) {
        Map<String, Object> fields = new Map<String, Object>();
        if (applicantName != null) {
            fields.put('applicant name', field(applicantName, 0.98));
        }
        fields.put('date of birth', field(dateOfBirth, 0.95));
        fields.put('needsManualReview', new Map<String, Object>{ 'type' => 'boolean', 'value' => flagged });
        return JSON.serialize(fields);
    }

    private static Map<String, Object> field(String value, Decimal score) {
        return new Map<String, Object>{
            'type' => 'string', 'value' => value,
            'confidence_score' => score, 'confidence_threshold' => 80.0
        };
    }

    private static Application__c newApplication() {
        Application__c app = new Application__c();
        insert app;
        return app;
    }

    private static Document_Extraction__c newStaging(Id targetId) {
        Document_Extraction__c staging = new Document_Extraction__c(
            Target_Record_Id__c = targetId,
            Content_Document_Id__c = '069000000000001AAA',
            Configuration_Name__c = CONFIG,
            Status__c = 'Pending',
            Attempts__c = 0
        );
        insert staging;
        return staging;
    }

    private static Document_Extraction__c reload(Id stagingId) {
        return [
            SELECT Status__c, Needs_Manual_Review__c, Error_Message__c, Attempts__c
            FROM Document_Extraction__c WHERE Id = :stagingId
        ];
    }

    // ------------------------------------------------------------------
    // End-to-end: upload -> trigger -> platform event -> job -> record updated
    // ------------------------------------------------------------------

    @IsTest
    static void uploadedDocumentIsExtractedAndApplied() {
        configure(new StubClient(extraction('Jane Doe', '1990-04-12', false), false, false));
        Application__c app = newApplication();

        Test.startTest();
        insert new ContentVersion(
            Title = 'Application form', PathOnClient = 'form.pdf',
            VersionData = Blob.valueOf('pdf'), FirstPublishLocationId = app.Id);
        Test.getEventBus().deliver();   // deliver Document_Uploaded__e
        Test.stopTest();                // run DocumentExtractionJob

        Document_Extraction__c staging = [SELECT Status__c FROM Document_Extraction__c LIMIT 1];
        Assert.areEqual('Applied', staging.Status__c);

        app = [SELECT Applicant_Name__c, Date_of_Birth__c FROM Application__c WHERE Id = :app.Id];
        Assert.areEqual('Jane Doe', app.Applicant_Name__c);
        Assert.areEqual(Date.newInstance(1990, 4, 12), app.Date_of_Birth__c);
    }

    @IsTest
    static void unsupportedFileTypeIsIgnored() {
        configure(new StubClient(extraction('Jane Doe', '1990-04-12', false), false, false));
        Application__c app = newApplication();

        Test.startTest();
        insert new ContentVersion(
            Title = 'Notes', PathOnClient = 'notes.txt',
            VersionData = Blob.valueOf('text'), FirstPublishLocationId = app.Id);
        Test.getEventBus().deliver();
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Document_Extraction__c]);
    }

    @IsTest
    static void sameDocumentOnTwoRecordsIsExtractedOnce() {
        configure(new StubClient(extraction('Jane Doe', '1990-04-12', false), false, false));
        Application__c first = newApplication();
        Application__c second = newApplication();

        Test.startTest();
        ContentVersion version = new ContentVersion(
            Title = 'Application form', PathOnClient = 'form.pdf',
            VersionData = Blob.valueOf('pdf'), FirstPublishLocationId = first.Id);
        insert version;
        Id documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :version.Id].ContentDocumentId;
        insert new ContentDocumentLink(ContentDocumentId = documentId, LinkedEntityId = second.Id, ShareType = 'V');
        Test.getEventBus().deliver();
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Document_Extraction__c]);
    }

    // ------------------------------------------------------------------
    // Review routing
    // ------------------------------------------------------------------

    @IsTest
    static void lowConfidenceGoesToReview() {
        configure(new StubClient(extraction('Jane Doe', '1990-04-12', true), true, false));
        Application__c app = newApplication();
        Document_Extraction__c staging = newStaging(app.Id);

        Test.startTest();
        System.enqueueJob(new DocumentExtractionJob(staging.Id));
        Test.stopTest();

        staging = reload(staging.Id);
        Assert.areEqual('Needs Review', staging.Status__c);
        Assert.isTrue(staging.Needs_Manual_Review__c);
        Assert.isNull([SELECT Applicant_Name__c FROM Application__c WHERE Id = :app.Id].Applicant_Name__c,
            'Low-confidence data must not be written to the record');
    }

    @IsTest
    static void missingRequiredValueGoesToReview() {
        configure(new StubClient(extraction(null, '1990-04-12', false), false, false));
        Document_Extraction__c staging = newStaging(newApplication().Id);

        Test.startTest();
        System.enqueueJob(new DocumentExtractionJob(staging.Id));
        Test.stopTest();

        staging = reload(staging.Id);
        Assert.areEqual('Needs Review', staging.Status__c);
        Assert.isTrue(staging.Error_Message__c.contains('Missing required value: applicant name'));
    }

    @IsTest
    static void unparseableDateGoesToReview() {
        configure(new StubClient(extraction('Jane Doe', 'sometime in spring', false), false, false));
        Document_Extraction__c staging = newStaging(newApplication().Id);

        Test.startTest();
        System.enqueueJob(new DocumentExtractionJob(staging.Id));
        Test.stopTest();

        staging = reload(staging.Id);
        Assert.areEqual('Needs Review', staging.Status__c);
        Assert.isTrue(staging.Error_Message__c.contains('date of birth'));
    }

    // ------------------------------------------------------------------
    // Failure handling
    // ------------------------------------------------------------------

    @IsTest
    static void extractionErrorIsRecorded() {
        configure(new StubClient(null, false, true));
        Document_Extraction__c staging = newStaging(newApplication().Id);

        Test.startTest();
        System.enqueueJob(new DocumentExtractionJob(staging.Id));
        Test.stopTest();

        staging = reload(staging.Id);
        Assert.areEqual('Failed', staging.Status__c);
        Assert.areEqual(1, staging.Attempts__c);
        Assert.isTrue(staging.Error_Message__c.contains('Simulated Document AI outage'));
    }

    // ------------------------------------------------------------------
    // Helpers in DocumentAIClients
    // ------------------------------------------------------------------

    @IsTest
    static void findsFieldMapInsideWrappedResponse() {
        String wrapped = JSON.serialize(new Map<String, Object>{
            'data' => new List<Object>{
                new Map<String, Object>{ 'result' => extraction('Jane Doe', '1990-04-12', false) }
            }
        });
        Map<String, Object> fieldMap = DocumentAIClients.findFieldMap(JSON.deserializeUntyped(wrapped));
        Assert.isNotNull(fieldMap);
        Assert.isTrue(fieldMap.containsKey('applicant name'));
    }

    @IsTest
    static void mapsFileExtensionsToMimeTypes() {
        Assert.areEqual('application/pdf', DocumentAIClients.mimeTypeFor('PDF'));
        Assert.areEqual('image/jpeg', DocumentAIClients.mimeTypeFor('jpg'));
        Assert.areEqual(
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
            DocumentAIClients.mimeTypeFor('docx'));
    }
}
