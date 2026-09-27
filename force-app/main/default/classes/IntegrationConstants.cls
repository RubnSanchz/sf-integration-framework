public class IntegrationConstants {
    public static final String STATUS_PENDING = 'PENDING';
    public static final String STATUS_PROCESSING = 'PROCESSING';
    public static final String STATUS_SUCCESS = 'SUCCESS';
    public static final String STATUS_ERROR = 'ERROR';
    public static final String STATUS_UNKNOWN = 'UNKNOWN';

    // Disposition__c answers "what does the system do now", separately from
    // Status__c ("what happened"). Every value must exist in the restricted
    // picklist on IntegrationTransaction__c.Disposition__c.
    public static final String DISPOSITION_NONE = 'NONE';
    public static final String DISPOSITION_RETRY = 'RETRY';
    public static final String DISPOSITION_RECONCILE = 'RECONCILE';
    public static final String DISPOSITION_MANUAL = 'MANUAL';
    public static final String DISPOSITION_TERMINAL = 'TERMINAL';

    public static final String RESULT_SUCCESS = 'SUCCESS';
    public static final String RESULT_ERROR = 'ERROR';
    public static final String RESULT_UNKNOWN = 'UNKNOWN';

    // Error codes. The first block is everything that can go wrong before a
    // request leaves the org, where we know the remote side has not acted.
    public static final String ERROR_CONFIGURATION = 'CONFIGURATION_ERROR';
    public static final String ERROR_HANDLER = 'HANDLER_ERROR';
    public static final String ERROR_REQUEST_BUILD = 'REQUEST_BUILD_ERROR';
    public static final String ERROR_INVALID_REQUEST = 'INVALID_REQUEST';
    public static final String ERROR_HANDLER_DML = 'HANDLER_DML';
    public static final String ERROR_CLAIM = 'CLAIM_ERROR';

    // From the callout onwards the remote side effect is uncertain.
    public static final String ERROR_CALLOUT_EXCEPTION = 'CALLOUT_EXCEPTION';
    public static final String ERROR_CLIENT = 'CLIENT_ERROR';
    public static final String ERROR_POST_PROCESSING = 'POST_PROCESSING_ERROR';
    public static final String ERROR_RETRIES_EXHAUSTED = 'RETRIES_EXHAUSTED';

    private IntegrationConstants() {}
}
