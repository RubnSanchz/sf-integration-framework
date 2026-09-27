/**
 * Shared literals. The status, result and disposition values mirror restricted
 * picklists, so they must stay in step with the metadata and must stay final.
 */
public class IntegrationConstants {
    public static final String STATUS_PENDING = 'PENDING';
    public static final String STATUS_PROCESSING = 'PROCESSING';
    public static final String STATUS_SUCCESS = 'SUCCESS';
    public static final String STATUS_ERROR = 'ERROR';
    public static final String STATUS_UNKNOWN = 'UNKNOWN';

    // What the system does next, as opposed to Status__c, which is what happened.
    public static final String DISPOSITION_NONE = 'NONE';
    public static final String DISPOSITION_RETRY = 'RETRY';
    public static final String DISPOSITION_RECONCILE = 'RECONCILE';
    public static final String DISPOSITION_MANUAL = 'MANUAL';
    public static final String DISPOSITION_TERMINAL = 'TERMINAL';

    public static final String RESULT_SUCCESS = 'SUCCESS';
    public static final String RESULT_ERROR = 'ERROR';
    public static final String RESULT_UNKNOWN = 'UNKNOWN';

    // Error codes, split by the only question that matters for recovery:
    // did anything leave the org? Here, no. These are always ERROR.
    public static final String ERROR_CONFIGURATION = 'CONFIGURATION_ERROR';
    public static final String ERROR_HANDLER = 'HANDLER_ERROR';
    public static final String ERROR_REQUEST_BUILD = 'REQUEST_BUILD_ERROR';
    public static final String ERROR_INVALID_REQUEST = 'INVALID_REQUEST';
    public static final String ERROR_HANDLER_DML = 'HANDLER_DML';
    public static final String ERROR_CLIENT = 'CLIENT_ERROR';
    public static final String ERROR_CLAIM = 'CLAIM_ERROR';
    public static final String ERROR_LEASE_EXPIRED = 'LEASE_EXPIRED';

    // Here the remote side may have acted. These are UNKNOWN.
    public static final String ERROR_CALLOUT_EXCEPTION = 'CALLOUT_EXCEPTION';
    public static final String ERROR_POST_PROCESSING = 'POST_PROCESSING_ERROR';
    public static final String ERROR_SUPERSEDED = 'SUPERSEDED';
    public static final String ERROR_STALE_LEASE = 'STALE_LEASE';
    public static final String ERROR_RETRIES_EXHAUSTED = 'RETRIES_EXHAUSTED';

    private IntegrationConstants() {}
}
