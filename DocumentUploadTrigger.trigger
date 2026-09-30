/**
 * Fires when a file is linked to a record (e.g. uploaded on an Experience Cloud record page).
 * All logic lives in DocumentUploadHandler.
 */
trigger DocumentUploadTrigger on ContentDocumentLink (after insert) {
    DocumentUploadHandler.handleAfterInsert(Trigger.new);
}
