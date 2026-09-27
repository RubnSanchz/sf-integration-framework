/**
 * Every literal the framework shares. Exposed as getter-only properties rather
 * than public static final fields: reading one field initialises the whole
 * class, so a flat constant list puts values nobody asked for in front of you
 * while debugging. A property is evaluated only when it is read.
 *
 * Getters only, never setters. The status, result and disposition values must
 * match the restricted picklists they mirror, and a settable "constant" could
 * drift from them at runtime. IntegrationCoreTest pins both the literals and
 * that correspondence.
 */
public class IntegrationConstants {
    public static String STATUS_PENDING { get { return 'PENDING'; } }
    public static String STATUS_PROCESSING { get { return 'PROCESSING'; } }
    public static String STATUS_SUCCESS { get { return 'SUCCESS'; } }
    public static String STATUS_ERROR { get { return 'ERROR'; } }
    public static String STATUS_UNKNOWN { get { return 'UNKNOWN'; } }

    // Disposition__c answers "what does the system do now", separately from
    // Status__c ("what happened"). Every value must exist in the restricted
    // picklist on IntegrationTransaction__c.Disposition__c.
    public static String DISPOSITION_NONE { get { return 'NONE'; } }
    public static String DISPOSITION_RETRY { get { return 'RETRY'; } }
    public static String DISPOSITION_RECONCILE { get { return 'RECONCILE'; } }
    public static String DISPOSITION_MANUAL { get { return 'MANUAL'; } }
    public static String DISPOSITION_TERMINAL { get { return 'TERMINAL'; } }

    public static String RESULT_SUCCESS { get { return 'SUCCESS'; } }
    public static String RESULT_ERROR { get { return 'ERROR'; } }
    public static String RESULT_UNKNOWN { get { return 'UNKNOWN'; } }

    // Error codes. The first block is everything that can go wrong before a
    // request leaves the org, where we know the remote side has not acted.
    public static String ERROR_CONFIGURATION { get { return 'CONFIGURATION_ERROR'; } }
    public static String ERROR_HANDLER { get { return 'HANDLER_ERROR'; } }
    public static String ERROR_REQUEST_BUILD { get { return 'REQUEST_BUILD_ERROR'; } }
    public static String ERROR_INVALID_REQUEST { get { return 'INVALID_REQUEST'; } }
    public static String ERROR_HANDLER_DML { get { return 'HANDLER_DML'; } }
    public static String ERROR_CLAIM { get { return 'CLAIM_ERROR'; } }
    public static String ERROR_LEASE_EXPIRED { get { return 'LEASE_EXPIRED'; } }

    // Recorded on the attempt of a worker that lost ownership of its transaction.
    public static String ERROR_SUPERSEDED { get { return 'SUPERSEDED'; } }

    // Recorded by the recovery scheduler on a lease that ran out with no result.
    public static String ERROR_STALE_LEASE { get { return 'STALE_LEASE'; } }

    // From the callout onwards the remote side effect is uncertain.
    public static String ERROR_CALLOUT_EXCEPTION { get { return 'CALLOUT_EXCEPTION'; } }
    public static String ERROR_CLIENT { get { return 'CLIENT_ERROR'; } }
    public static String ERROR_POST_PROCESSING { get { return 'POST_PROCESSING_ERROR'; } }
    public static String ERROR_RETRIES_EXHAUSTED { get { return 'RETRIES_EXHAUSTED'; } }

    private IntegrationConstants() {}
}
