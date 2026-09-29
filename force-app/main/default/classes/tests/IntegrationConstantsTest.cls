@IsTest
private class IntegrationConstantsTest {
    // Checkbox fields on a record built in memory read back as false, not as the
    // defaultValue declared on the field, so they are set here explicitly to
    // mirror what a stored IntegrationDefinition__mdt record would carry.
    private static Set<String> picklistValues(Schema.SObjectField field) {
        Set<String> values = new Set<String>();
        for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
            values.add(entry.getValue());
        }
        return values;
    }

    // The values are getter-only properties, so nothing else pins them. This test
    // turns a typo in a literal into a test failure instead of a runtime one.
    @IsTest
    static void constantValuesArePinned() {
        System.assertEquals('PENDING', IntegrationConstants.STATUS_PENDING);
        System.assertEquals('PROCESSING', IntegrationConstants.STATUS_PROCESSING);
        System.assertEquals('SUCCESS', IntegrationConstants.STATUS_SUCCESS);
        System.assertEquals('ERROR', IntegrationConstants.STATUS_ERROR);
        System.assertEquals('UNKNOWN', IntegrationConstants.STATUS_UNKNOWN);

        System.assertEquals('NONE', IntegrationConstants.DISPOSITION_NONE);
        System.assertEquals('RETRY', IntegrationConstants.DISPOSITION_RETRY);
        System.assertEquals('RECONCILE', IntegrationConstants.DISPOSITION_RECONCILE);
        System.assertEquals('MANUAL', IntegrationConstants.DISPOSITION_MANUAL);
        System.assertEquals('TERMINAL', IntegrationConstants.DISPOSITION_TERMINAL);

        System.assertEquals('SUCCESS', IntegrationConstants.RESULT_SUCCESS);
        System.assertEquals('ERROR', IntegrationConstants.RESULT_ERROR);
        System.assertEquals('UNKNOWN', IntegrationConstants.RESULT_UNKNOWN);

        System.assertEquals('CONFIGURATION_ERROR', IntegrationConstants.ERROR_CONFIGURATION);
        System.assertEquals('HANDLER_ERROR', IntegrationConstants.ERROR_HANDLER);
        System.assertEquals('REQUEST_BUILD_ERROR', IntegrationConstants.ERROR_REQUEST_BUILD);
        System.assertEquals('INVALID_REQUEST', IntegrationConstants.ERROR_INVALID_REQUEST);
        System.assertEquals('HANDLER_DML', IntegrationConstants.ERROR_HANDLER_DML);
        System.assertEquals('CLAIM_ERROR', IntegrationConstants.ERROR_CLAIM);
        System.assertEquals('LEASE_EXPIRED', IntegrationConstants.ERROR_LEASE_EXPIRED);
        System.assertEquals('SUPERSEDED', IntegrationConstants.ERROR_SUPERSEDED);
        System.assertEquals('STALE_LEASE', IntegrationConstants.ERROR_STALE_LEASE);
        System.assertEquals('CALLOUT_EXCEPTION', IntegrationConstants.ERROR_CALLOUT_EXCEPTION);
        System.assertEquals('CLIENT_ERROR', IntegrationConstants.ERROR_CLIENT);
        System.assertEquals('POST_PROCESSING_ERROR', IntegrationConstants.ERROR_POST_PROCESSING);
        System.assertEquals('RETRIES_EXHAUSTED', IntegrationConstants.ERROR_RETRIES_EXHAUSTED);
    }

    // CLAUDE.md requires the Apex constants and the restricted picklists to stay
    // in step. A mismatch only shows up as a DML error at runtime.
    @IsTest
    static void constantsMatchTheRestrictedPicklists() {
        System.assertEquals(
            new Set<String>{
                IntegrationConstants.DISPOSITION_NONE,
                IntegrationConstants.DISPOSITION_RETRY,
                IntegrationConstants.DISPOSITION_RECONCILE,
                IntegrationConstants.DISPOSITION_MANUAL,
                IntegrationConstants.DISPOSITION_TERMINAL
            },
            picklistValues(IntegrationTransaction__c.Disposition__c)
        );

        System.assertEquals(
            new Set<String>{
                IntegrationConstants.STATUS_PENDING,
                IntegrationConstants.STATUS_PROCESSING,
                IntegrationConstants.STATUS_SUCCESS,
                IntegrationConstants.STATUS_ERROR,
                IntegrationConstants.STATUS_UNKNOWN
            },
            picklistValues(IntegrationTransaction__c.Status__c)
        );

        System.assertEquals(
            new Set<String>{
                IntegrationConstants.RESULT_SUCCESS,
                IntegrationConstants.RESULT_ERROR,
                IntegrationConstants.RESULT_UNKNOWN
            },
            picklistValues(IntegrationAttempt__c.Result__c)
        );
    }
}
