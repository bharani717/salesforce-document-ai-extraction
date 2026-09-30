/**
 * Pluggable Document AI client.
 *
 *   StandardActionClient - standard invocable action "extractDataFromDocument"
 *                          (requires the MuleSoft for Flow: IDP add-on or Agentforce 1 Editions).
 *   RestApiClient        - Data 360 Document AI REST endpoint via a Named Credential
 *                          (requires an External Client App + External Credential).
 *
 * Document_AI_Setting__mdt.Default.Use_REST_API__c chooses the client, so a licensing
 * change is a configuration change. Tests inject a stub through `instance`.
 *
 * Both clients return a normalised Result whose extractedJson is a flat map:
 *   { "<field name>": { "type": ..., "value": ..., "confidence_score": ..., "confidence_threshold": ... },
 *     "needsManualReview": { "type": "boolean", "value": true|false } }
 */
public inherited sharing class DocumentAIClients {

    public interface Client {
        Result extract(Document_Extraction__c staging);
    }

    public class Result {
        public String extractedJson;
        public Boolean needsManualReview = false;
    }

    public class ExtractionException extends Exception {}

    @TestVisible private static Client instance;
    @TestVisible private static Document_AI_Setting__mdt settingsOverride;

    public static Client get() {
        if (instance == null) {
            instance = settings().Use_REST_API__c == true
                ? (Client) new RestApiClient()
                : (Client) new StandardActionClient();
        }
        return instance;
    }

    public static Document_AI_Setting__mdt settings() {
        if (settingsOverride != null) {
            return settingsOverride;
        }
        Document_AI_Setting__mdt configured = Document_AI_Setting__mdt.getInstance('Default');
        return configured != null ? configured : new Document_AI_Setting__mdt(
            Use_REST_API__c          = false,
            Default_Configuration__c = 'Application_Form_Extraction',
            Named_Credential__c      = 'DocumentAI_Self',
            API_Version__c           = 'v66.0'
        );
    }

    // ------------------------------------------------------------------
    // Option A: standard action "extractDataFromDocument"
    // ------------------------------------------------------------------
    public class StandardActionClient implements Client {
        public Result extract(Document_Extraction__c staging) {
            Invocable.Action action = Invocable.Action.createStandardAction('extractDataFromDocument');
            action.setInvocationParameter('documentProcessingConfiguration', staging.Configuration_Name__c);
            action.setInvocationParameter('contentDocumentId', staging.Content_Document_Id__c);

            Invocable.Action.Result actionResult = action.invoke()[0];
            if (!actionResult.isSuccess()) {
                throw new ExtractionException('Document AI action failed: ' + String.valueOf(actionResult.getErrors()));
            }

            Map<String, Object> outputs = actionResult.getOutputParameters();
            Result result = new Result();
            result.extractedJson = (String) outputs.get('extractedDataJson');

            Object flag = outputs.get('needsManualReview');
            result.needsManualReview = (flag instanceof Boolean)
                ? (Boolean) flag
                : readNeedsReview(result.extractedJson);
            return result;
        }
    }

    // ------------------------------------------------------------------
    // Option B: Data 360 Document AI REST endpoint
    // ------------------------------------------------------------------
    public class RestApiClient implements Client {
        public Result extract(Document_Extraction__c staging) {
            Document_AI_Setting__mdt cfg = settings();
            ContentVersion version = [
                SELECT VersionData, FileExtension
                FROM ContentVersion
                WHERE Id = :staging.Content_Version_Id__c
            ];

            Map<String, Object> body = new Map<String, Object>{
                'idpConfigurationIdOrName' => staging.Configuration_Name__c,
                'files' => new List<Object>{
                    new Map<String, Object>{
                        'mimeType' => mimeTypeFor(version.FileExtension),
                        // Base64 grows the payload by ~33%; enforce an upload size limit on the portal.
                        'data'     => EncodingUtil.base64Encode(version.VersionData)
                    }
                }
            };

            HttpRequest request = new HttpRequest();
            request.setEndpoint('callout:' + cfg.Named_Credential__c
                + '/services/data/' + cfg.API_Version__c
                + '/ssot/document-processing/actions/extract-data?htmlEncode=false');
            request.setMethod('POST');
            request.setHeader('Content-Type', 'application/json');
            request.setTimeout(120000);
            request.setBody(JSON.serialize(body));

            HttpResponse response = new Http().send(request);
            if (response.getStatusCode() >= 300) {
                throw new ExtractionException('Document AI API returned '
                    + response.getStatusCode() + ': ' + response.getBody());
            }

            Map<String, Object> fieldMap = findFieldMap(JSON.deserializeUntyped(response.getBody()));
            if (fieldMap == null) {
                throw new ExtractionException('Unrecognised Document AI response: ' + response.getBody().left(2000));
            }

            Result result = new Result();
            result.extractedJson = JSON.serialize(fieldMap);
            result.needsManualReview = readNeedsReview(result.extractedJson);
            return result;
        }
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    public static Boolean readNeedsReview(String extractedJson) {
        if (String.isBlank(extractedJson)) {
            return true;
        }
        Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(extractedJson);
        Object flag = root.get('needsManualReview');
        if (flag instanceof Map<String, Object>) {
            flag = ((Map<String, Object>) flag).get('value');
        }
        return flag == true;
    }

    /**
     * Walks a response and returns the first object that carries the per-field results
     * (identified by the "needsManualReview" entry). Handles results that are wrapped in
     * envelopes/arrays or embedded as a JSON string.
     */
    @TestVisible
    private static Map<String, Object> findFieldMap(Object node) {
        if (node instanceof String) {
            String text = ((String) node).trim();
            if (text.startsWith('{') || text.startsWith('[')) {
                return findFieldMap(JSON.deserializeUntyped(text));
            }
            return null;
        }
        if (node instanceof Map<String, Object>) {
            Map<String, Object> m = (Map<String, Object>) node;
            if (m.containsKey('needsManualReview')) {
                return m;
            }
            for (Object child : m.values()) {
                Map<String, Object> found = findFieldMap(child);
                if (found != null) {
                    return found;
                }
            }
        }
        if (node instanceof List<Object>) {
            for (Object child : (List<Object>) node) {
                Map<String, Object> found = findFieldMap(child);
                if (found != null) {
                    return found;
                }
            }
        }
        return null;
    }

    @TestVisible
    private static String mimeTypeFor(String extension) {
        switch on (extension == null ? '' : extension.toLowerCase()) {
            when 'pdf'         { return 'application/pdf'; }
            when 'png'         { return 'image/png'; }
            when 'jpg', 'jpeg' { return 'image/jpeg'; }
            when 'docx'        { return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'; }
            when 'pptx'        { return 'application/vnd.openxmlformats-officedocument.presentationml.presentation'; }
            when 'xlsx'        { return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'; }
            when else          { throw new ExtractionException('Unsupported file type: ' + extension); }
        }
    }
}
