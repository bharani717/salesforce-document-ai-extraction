/**
 * Extracts one document and hands the result to DocumentMappingService.
 *
 * Runs as the integration user (it is enqueued by the Platform Event subscriber).
 * `without sharing` because this is a system process: the integration user must be able to
 * update target records owned by portal users.
 *
 * Transaction order matters: the callout happens BEFORE any DML, otherwise Apex throws
 * "You have uncommitted work pending". The staging record already exists (created by the subscriber).
 */
public without sharing class DocumentExtractionJob implements Queueable, Database.AllowsCallouts {

    @TestVisible private static final Integer MAX_ATTEMPTS = 3;

    private final Id stagingId;

    public DocumentExtractionJob(Id stagingId) {
        this.stagingId = stagingId;
    }

    public void execute(QueueableContext context) {
        Document_Extraction__c staging = [
            SELECT Id, Target_Record_Id__c, Content_Document_Id__c, Content_Version_Id__c,
                   Configuration_Name__c, Attempts__c
            FROM Document_Extraction__c
            WHERE Id = :stagingId
        ];
        staging.Attempts__c = (staging.Attempts__c == null ? 0 : staging.Attempts__c) + 1;

        DocumentAIClients.Result result;
        try {
            result = DocumentAIClients.get().extract(staging);   // callout - no DML before this line
        } catch (Exception e) {
            recordFailure(staging, e);
            return;
        }

        staging.Extracted_Data_JSON__c = result.extractedJson;
        staging.Needs_Manual_Review__c = result.needsManualReview;
        staging.Status__c = 'Extracted';

        DocumentMappingService.applyOrRoute(staging);             // updates target + staging
    }

    private static void recordFailure(Document_Extraction__c staging, Exception e) {
        staging.Status__c = 'Failed';
        staging.Error_Message__c = (e.getMessage() + '\n' + e.getStackTraceString()).left(131072);
        update staging;

        // Retry transient failures with a growing delay; credits are spent on every attempt, so cap it.
        if (staging.Attempts__c < MAX_ATTEMPTS && !Test.isRunningTest()) {
            System.enqueueJob(new DocumentExtractionJob(staging.Id), Integer.valueOf(staging.Attempts__c));
        }
    }
}
