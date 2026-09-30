/**
 * Maps extracted values onto the target record using Document_Field_Mapping__mdt.
 *
 * A record is auto-applied only when ALL of these hold:
 *   1. Document AI reported no low-confidence field (needsManualReview = false),
 *   2. every required field has a value, and
 *   3. every value converts cleanly to its target field type and the update succeeds.
 * Otherwise the staging record goes to "Needs Review" with the reasons in Error_Message__c.
 */
public without sharing class DocumentMappingService {

    @TestVisible private static List<Document_Field_Mapping__mdt> mappingOverride;

    public static void applyOrRoute(Document_Extraction__c staging) {
        Map<String, Object> fields = lowerCaseKeys(
            (Map<String, Object>) JSON.deserializeUntyped(staging.Extracted_Data_JSON__c));

        Id targetId = (Id) staging.Target_Record_Id__c;
        SObject target = targetId.getSObjectType().newSObject(targetId);

        Boolean needsReview = staging.Needs_Manual_Review__c == true;
        List<String> issues = new List<String>();
        if (needsReview) {
            issues.add('Document AI flagged one or more fields below their confidence threshold.');
        }

        for (Document_Field_Mapping__mdt mapping : mappingsFor(staging.Configuration_Name__c)) {
            String name = mapping.Extracted_Field_Name__c;
            Object raw = valueOf(fields, name);

            if (raw == null || String.isBlank(String.valueOf(raw))) {
                if (mapping.Required__c) {
                    issues.add('Missing required value: ' + name);
                }
                continue;
            }
            try {
                target.put(mapping.Target_Field__c, convert(raw, mapping.Data_Type__c));
            } catch (Exception e) {
                issues.add('Could not convert "' + name + '" (' + raw + ') to ' + mapping.Data_Type__c);
            }
        }

        needsReview = needsReview || !issues.isEmpty();

        if (!needsReview) {
            Database.SaveResult saved = Database.update(target, false);
            if (!saved.isSuccess()) {
                needsReview = true;
                issues.add('Record update failed: ' + saved.getErrors()[0].getMessage());
            }
        }

        staging.Needs_Manual_Review__c = needsReview;
        staging.Status__c = needsReview ? 'Needs Review' : 'Applied';
        staging.Error_Message__c = issues.isEmpty() ? null : String.join(issues, '\n');
        update staging;
    }

    // ------------------------------------------------------------------

    private static List<Document_Field_Mapping__mdt> mappingsFor(String configurationName) {
        if (mappingOverride != null) {
            return mappingOverride;
        }
        return [
            SELECT Extracted_Field_Name__c, Target_Field__c, Data_Type__c, Required__c
            FROM Document_Field_Mapping__mdt
            WHERE Configuration_Name__c = :configurationName
        ];
    }

    /** Field entries look like { "type": "string", "value": "...", "confidence_score": 0.97, ... }. */
    private static Object valueOf(Map<String, Object> fields, String name) {
        Object node = fields.get(name == null ? null : name.toLowerCase());
        if (node instanceof Map<String, Object>) {
            return ((Map<String, Object>) node).get('value');
        }
        return node;
    }

    @TestVisible
    private static Object convert(Object raw, String dataType) {
        String text = String.valueOf(raw).trim();
        switch on dataType {
            when 'Date' {
                return parseDate(text);
            }
            when 'Number', 'Currency' {
                // Strips symbols and thousands separators (e.g. "$1,250.00").
                // Adjust for locales that use a comma as the decimal separator.
                return Decimal.valueOf(text.replaceAll('[^0-9.\\-]', ''));
            }
            when 'Checkbox' {
                if (raw instanceof Boolean) {
                    return raw;
                }
                String lowered = text.toLowerCase();
                if (lowered == 'true' || lowered == 'yes' || lowered == 'y') { return true; }
                if (lowered == 'false' || lowered == 'no' || lowered == 'n') { return false; }
                throw new TypeException('Not a boolean: ' + text);
            }
            when else {
                return text;
            }
        }
    }

    /** ISO (yyyy-MM-dd) first, then the running user's locale format; anything else goes to review. */
    private static Date parseDate(String text) {
        try {
            return Date.valueOf(text.left(10));
        } catch (Exception isoFailure) {
            return Date.parse(text);
        }
    }

    private static Map<String, Object> lowerCaseKeys(Map<String, Object> source) {
        Map<String, Object> result = new Map<String, Object>();
        for (String key : source.keySet()) {
            result.put(key.toLowerCase(), source.get(key));
        }
        return result;
    }
}
