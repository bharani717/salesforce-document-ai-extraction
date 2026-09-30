/**
 * Platform Event subscriber. Runs as the integration user configured in
 * DocumentUploadedSubscriberConfig (PlatformEventSubscriberConfig), NOT as the portal user.
 *
 * 1. Creates one staging record per document. Content_Document_Id__c is a unique External ID,
 *    so redelivered events or a file shared to a second record are rejected here and
 *    never spend Document AI credits twice.
 * 2. Enqueues one extraction job per new staging record. The subscriber batch size (10)
 *    keeps this well inside the per-transaction Queueable limit.
 */
trigger DocumentUploadedSubscriber on Document_Uploaded__e (after insert) {

    List<Document_Extraction__c> stagings = new List<Document_Extraction__c>();
    for (Document_Uploaded__e evt : Trigger.new) {
        stagings.add(new Document_Extraction__c(
            Target_Record_Id__c    = evt.Target_Record_Id__c,
            Content_Document_Id__c = evt.Content_Document_Id__c,
            Content_Version_Id__c  = evt.Content_Version_Id__c,
            Configuration_Name__c  = evt.Configuration_Name__c,
            Status__c              = 'Pending',
            Attempts__c            = 0
        ));
    }

    // allOrNone = false: duplicates fail on the unique key and are simply skipped.
    Database.SaveResult[] results = Database.insert(stagings, false);

    for (Database.SaveResult result : results) {
        if (result.isSuccess()) {
            System.enqueueJob(new DocumentExtractionJob(result.getId()));
        }
    }
}
