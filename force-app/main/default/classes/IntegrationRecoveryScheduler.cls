public class IntegrationRecoveryScheduler implements Schedulable {
    private static final Integer MAX_RECORDS_PER_RUN = 500;

    public void execute(SchedulableContext context) {
        recoverStaleProcessing();
        recoverSafeUnknowns();
    }

    @TestVisible
    private static void recoverStaleProcessing() {
        Datetime nowValue = System.now();
        List<IntegrationTransaction__c> stale = [
            SELECT Id, IntegrationKey__c, AttemptCount__c, Status__c,
                   ProcessingStartedAt__c, LeaseExpiresAt__c
            FROM IntegrationTransaction__c
            WHERE Status__c = :IntegrationConstants.STATUS_PROCESSING
              AND LeaseExpiresAt__c != null
              AND LeaseExpiresAt__c < :nowValue
            LIMIT :MAX_RECORDS_PER_RUN
        ];

        List<IntegrationAttempt__c> syntheticAttempts = new List<IntegrationAttempt__c>();
        List<IntegrationTransaction__c> updates = new List<IntegrationTransaction__c>();

        for (IntegrationTransaction__c transactionRecord : stale) {
            IntegrationConfigService.Config config =
                IntegrationConfigService.get(transactionRecord.IntegrationKey__c);
            Boolean safeRetry = config.idempotencyEnabled &&
                IntegrationRetryPolicy.canRetry(transactionRecord, config);

            syntheticAttempts.add(new IntegrationAttempt__c(
                Transaction__c = transactionRecord.Id,
                AttemptNumber__c = transactionRecord.AttemptCount__c,
                StartedAt__c = transactionRecord.ProcessingStartedAt__c,
                FinishedAt__c = nowValue,
                Result__c = IntegrationConstants.RESULT_UNKNOWN,
                ErrorCode__c = 'STALE_LEASE',
                ErrorMessage__c = 'Processing lease expired before the worker persisted a final result.'
            ));

            updates.add(new IntegrationTransaction__c(
                Id = transactionRecord.Id,
                Status__c = safeRetry
                    ? IntegrationConstants.STATUS_PENDING
                    : IntegrationConstants.STATUS_UNKNOWN,
                LeaseExpiresAt__c = null,
                NextRetryAt__c = null,
                ErrorCode__c = 'STALE_LEASE',
                ErrorMessage__c = safeRetry
                    ? 'Stale execution recovered and returned to PENDING.'
                    : 'Stale execution requires reconciliation or manual review.'
            ));
        }

        if (!syntheticAttempts.isEmpty()) {
            insert syntheticAttempts;
        }
        if (!updates.isEmpty()) {
            update updates;
        }
    }

    @TestVisible
    private static void recoverSafeUnknowns() {
        List<IntegrationTransaction__c> unknowns = [
            SELECT Id, IntegrationKey__c, AttemptCount__c
            FROM IntegrationTransaction__c
            WHERE Status__c = :IntegrationConstants.STATUS_UNKNOWN
            ORDER BY LastAttemptAt__c ASC NULLS FIRST
            LIMIT :MAX_RECORDS_PER_RUN
        ];

        List<IntegrationTransaction__c> updates = new List<IntegrationTransaction__c>();
        for (IntegrationTransaction__c transactionRecord : unknowns) {
            IntegrationConfigService.Config config =
                IntegrationConfigService.get(transactionRecord.IntegrationKey__c);

            if (config.idempotencyEnabled &&
                IntegrationRetryPolicy.canRetry(transactionRecord, config)) {
                updates.add(new IntegrationTransaction__c(
                    Id = transactionRecord.Id,
                    Status__c = IntegrationConstants.STATUS_PENDING,
                    NextRetryAt__c = null,
                    LeaseExpiresAt__c = null
                ));
            }
        }

        if (!updates.isEmpty()) {
            update updates;
        }
    }
}
