/**
 * Detects documents uploaded against target records and hands them off for extraction
 * by publishing Document_Uploaded__e.
 *
 * Runs in the UPLOADING user's context (often an external portal user), so it deliberately:
 *   - does no Document AI work (portal users hold no Document AI permissions or licences), and
 *   - does not read or write the staging object (it is private to internal users).
 * The Platform Event subscriber picks the work up as the integration user.
 */
public with sharing class DocumentUploadHandler {

    @TestVisible
    private static final Set<String> SUPPORTED_EXTENSIONS =
        new Set<String>{ 'pdf', 'docx', 'png', 'jpg', 'jpeg' };

    /** Object whose attachments should be extracted. Replace with your own object. */
    @TestVisible
    private static final SObjectType TARGET_TYPE = Application__c.SObjectType;

    public static void handleAfterInsert(List<ContentDocumentLink> links) {
        Map<Id, Id> recordByDocument = new Map<Id, Id>();
        for (ContentDocumentLink link : links) {
            if (link.LinkedEntityId != null
                && link.LinkedEntityId.getSObjectType() == TARGET_TYPE) {
                recordByDocument.put(link.ContentDocumentId, link.LinkedEntityId);
            }
        }
        if (recordByDocument.isEmpty()) {
            return;
        }

        String configurationName = DocumentAIClients.settings().Default_Configuration__c;
        List<Document_Uploaded__e> events = new List<Document_Uploaded__e>();

        for (ContentVersion version : [
            SELECT Id, ContentDocumentId, FileExtension
            FROM ContentVersion
            WHERE ContentDocumentId IN :recordByDocument.keySet()
              AND IsLatest = true
        ]) {
            String extension = version.FileExtension == null ? '' : version.FileExtension.toLowerCase();
            if (!SUPPORTED_EXTENSIONS.contains(extension)) {
                continue;
            }
            events.add(new Document_Uploaded__e(
                Target_Record_Id__c    = recordByDocument.get(version.ContentDocumentId),
                Content_Document_Id__c = version.ContentDocumentId,
                Content_Version_Id__c  = version.Id,
                // Single document type here; resolve per record type / file name if you have several.
                Configuration_Name__c  = configurationName
            ));
        }

        if (!events.isEmpty()) {
            // Document_Uploaded__e uses "Publish After Commit": nothing is processed
            // unless the upload transaction actually commits.
            EventBus.publish(events);
        }
    }
}
