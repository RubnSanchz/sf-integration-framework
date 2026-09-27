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

    private IntegrationConstants() {}
}
