/**
 * Shared test data. Two things live here because every test class needs them
 * and they were duplicated before: the configuration seam, and a user that
 * holds nothing but the shipped permission set.
 *
 * Tests run as that user through System.runAs so they do not depend on whoever
 * launches them. That also makes them prove something the previous tests could
 * not: that SF_Integration_Framework_Admin on its own is enough to run the
 * framework. Before this, they passed only because the permission set happened
 * to be assigned to the developer's user, and would have failed in a clean
 * packaging org with "fields being inaccessible".
 */
@IsTest
public class IntegrationTestDataFactory {
    public static final String INTEGRATION_KEY = 'TEST';
    public static final String HANDLER_CLASS = 'IntegrationExecutionJobTest.TestHandler';
    private static final String USER_ALIAS = 'sifTest';

    // Call from @TestSetup. User and PermissionSetAssignment are setup objects
    // and cannot be inserted in the same transaction as business records, so
    // they need the separate transaction that @TestSetup provides.
    public static void createFrameworkUser() {
        User frameworkUser = new User(
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1].Id,
            Alias = USER_ALIAS,
            LastName = 'Framework',
            Username = 'sif.' + UserInfo.getOrganizationId() + '@example.invalid',
            Email = 'sif@example.invalid',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'GMT'
        );
        insert frameworkUser;

        insert new PermissionSetAssignment(
            AssigneeId = frameworkUser.Id,
            PermissionSetId = [
                SELECT Id FROM PermissionSet WHERE Name = 'SF_Integration_Framework_Admin' LIMIT 1
            ].Id
        );
    }

    public static User frameworkUser() {
        return [SELECT Id FROM User WHERE Alias = :USER_ALIAS LIMIT 1];
    }

    public static IntegrationConfigService.Config config(Boolean idempotent) {
        return config(idempotent, 'UnusedHandler');
    }

    public static IntegrationConfigService.Config config(Boolean idempotent, String handlerClass) {
        IntegrationConfigService.Config config = new IntegrationConfigService.Config();
        config.integrationKey = INTEGRATION_KEY;
        config.namedCredential = 'Test_Named_Credential';
        config.handlerClass = handlerClass;
        config.idempotencyHeader = 'Idempotency-Key';
        config.timeoutMs = 30000;
        config.processingLeaseSeconds = 120;
        config.maxRetries = 3;
        config.retryBaseDelaySeconds = 60;
        config.retryEnabled = true;
        config.idempotencyEnabled = idempotent;
        config.logRequestBody = false;
        config.logResponseBody = false;
        config.maxPayloadChars = 12000;
        config.retentionDays = 30;
        config.retryableStatusCodes.addAll(new Set<Integer>{408, 429, 500, 502, 503, 504});
        IntegrationConfigService.setTestConfig(config);
        return config;
    }

    // Checkbox fields on a record built in memory read back as false, not as the
    // defaultValue declared on the field, so they are set here explicitly to
    // mirror what a stored IntegrationDefinition__mdt record would carry.
    public static IntegrationDefinition__mdt definition() {
        return new IntegrationDefinition__mdt(
            NamedCredential__c = 'Test_Named_Credential',
            HandlerClass__c = 'UnusedHandler',
            RetryEnabled__c = true,
            IdempotencyEnabled__c = true,
            LogRequestBody__c = false,
            LogResponseBody__c = false
        );
    }

    // Unsaved, for the tests that need to observe the insert itself.
    public static IntegrationTransaction__c newPending(String key) {
        return new IntegrationTransaction__c(
            IdempotencyKey__c = key,
            IntegrationKey__c = INTEGRATION_KEY,
            Operation__c = 'CREATE',
            Direction__c = 'OUTBOUND',
            Status__c = IntegrationConstants.STATUS_PENDING,
            Disposition__c = IntegrationConstants.DISPOSITION_NONE,
            AttemptCount__c = 0
        );
    }

    public static IntegrationTransaction__c pending(String key) {
        IntegrationTransaction__c record = newPending(key);
        insert record;
        return record;
    }

    // A transaction a worker has claimed, which is what the execution job
    // expects to find.
    public static IntegrationTransaction__c processing(String key, Integer attemptCount) {
        IntegrationTransaction__c record = newPending(key);
        record.Status__c = IntegrationConstants.STATUS_PROCESSING;
        record.AttemptCount__c = attemptCount;
        record.ProcessingStartedAt__c = System.now();
        record.LeaseExpiresAt__c = System.now().addSeconds(120);
        insert record;
        return record;
    }

    // A worker that died: still PROCESSING, lease long gone.
    public static IntegrationTransaction__c staleProcessing(String key, Integer attemptCount) {
        IntegrationTransaction__c record = processing(key, attemptCount);
        record.ProcessingStartedAt__c = System.now().addMinutes(-10);
        record.LeaseExpiresAt__c = System.now().addMinutes(-5);
        update record;
        return record;
    }

    public static IntegrationTransaction__c withDisposition(
        String key,
        String status,
        String disposition,
        Integer attemptCount,
        Datetime nextRetryAt
    ) {
        IntegrationTransaction__c record = newPending(key);
        record.Status__c = status;
        record.Disposition__c = disposition;
        record.AttemptCount__c = attemptCount;
        record.NextRetryAt__c = nextRetryAt;
        insert record;
        return record;
    }

    public static IntegrationTransaction__c reload(Id transactionId) {
        return [
            SELECT Status__c, Disposition__c, ErrorCode__c, ErrorMessage__c,
                   NextRetryAt__c, LeaseExpiresAt__c, ExternalId__c, AttemptCount__c
            FROM IntegrationTransaction__c
            WHERE Id = :transactionId
        ];
    }

    public static List<IntegrationAttempt__c> attemptsOf(Id transactionId) {
        return [
            SELECT Result__c, ErrorCode__c, ErrorMessage__c, HttpStatusCode__c, AttemptNumber__c
            FROM IntegrationAttempt__c
            WHERE Transaction__c = :transactionId
        ];
    }
}
