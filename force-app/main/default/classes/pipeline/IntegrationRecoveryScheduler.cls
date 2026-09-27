/**
 * Rescues the work that never reached a normal ending: a worker that died with
 * its lease still held, and uncertain outcomes that may still be safe to send
 * again. Everything that ended normally already carries its own disposition and
 * is handled by the dispatcher, not here.
 *
 * RECONCILE means "uncertain, not yet evaluated". This class is the evaluator:
 * every run turns each RECONCILE into RETRY when sending again is safe, or into
 * MANUAL when nothing automatic can resolve it. That is what keeps the
 * reconciliation window draining instead of filling up with records nobody will
 * ever look at again.
 */
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
            // The expired lease is a fact, recorded whatever is decided next.
            syntheticAttempts.add(new IntegrationAttempt__c(
                Transaction__c = transactionRecord.Id,
                AttemptNumber__c = transactionRecord.AttemptCount__c,
                StartedAt__c = transactionRecord.ProcessingStartedAt__c,
                FinishedAt__c = nowValue,
                Result__c = IntegrationConstants.RESULT_UNKNOWN,
                ErrorCode__c = IntegrationConstants.ERROR_STALE_LEASE,
                ErrorMessage__c = 'Processing lease expired before the worker persisted a final result.'
            ));

            IntegrationConfigService.Config config;
            try {
                config = IntegrationConfigService.get(transactionRecord.IntegrationKey__c);
            } catch (Exception ex) {
                // One broken definition must not stop the rest of the run.
                updates.add(parked(transactionRecord.Id, ex.getMessage()));
                continue;
            }

            // The worker may have reached the remote side before it died, so
            // sending again is only safe with remote idempotency.
            Boolean safeRetry = config.idempotencyEnabled &&
                IntegrationRetryPolicy.canRetry(transactionRecord, config);

            updates.add(new IntegrationTransaction__c(
                Id = transactionRecord.Id,
                Status__c = IntegrationConstants.STATUS_UNKNOWN,
                Disposition__c = safeRetry
                    ? IntegrationConstants.DISPOSITION_RETRY
                    : IntegrationConstants.DISPOSITION_RECONCILE,
                LeaseExpiresAt__c = null,
                NextRetryAt__c = safeRetry
                    ? IntegrationRetryPolicy.nextRetryAt(transactionRecord, config)
                    : null,
                ErrorCode__c = IntegrationConstants.ERROR_STALE_LEASE,
                ErrorMessage__c = safeRetry
                    ? 'Stale execution recovered and scheduled for another attempt.'
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
              AND Disposition__c = :IntegrationConstants.DISPOSITION_RECONCILE
            ORDER BY LastAttemptAt__c ASC NULLS FIRST
            LIMIT :MAX_RECORDS_PER_RUN
        ];

        List<IntegrationTransaction__c> updates = new List<IntegrationTransaction__c>();
        for (IntegrationTransaction__c transactionRecord : unknowns) {
            IntegrationConfigService.Config config;
            try {
                config = IntegrationConfigService.get(transactionRecord.IntegrationKey__c);
            } catch (Exception ex) {
                updates.add(parked(transactionRecord.Id, ex.getMessage()));
                continue;
            }

            if (config.idempotencyEnabled &&
                IntegrationRetryPolicy.canRetry(transactionRecord, config)) {
                updates.add(new IntegrationTransaction__c(
                    Id = transactionRecord.Id,
                    Disposition__c = IntegrationConstants.DISPOSITION_RETRY,
                    NextRetryAt__c = IntegrationRetryPolicy.nextRetryAt(transactionRecord, config),
                    LeaseExpiresAt__c = null
                ));
            } else {
                // Nothing automatic will resolve this one. It has to leave the
                // reconciliation window or it crowds out newer work on every run.
                updates.add(new IntegrationTransaction__c(
                    Id = transactionRecord.Id,
                    Disposition__c = IntegrationConstants.DISPOSITION_MANUAL,
                    NextRetryAt__c = null,
                    LeaseExpiresAt__c = null
                ));
            }
        }

        if (!updates.isEmpty()) {
            update updates;
        }
    }

    private static IntegrationTransaction__c parked(Id transactionId, String reason) {
        return new IntegrationTransaction__c(
            Id = transactionId,
            Status__c = IntegrationConstants.STATUS_UNKNOWN,
            Disposition__c = IntegrationConstants.DISPOSITION_MANUAL,
            LeaseExpiresAt__c = null,
            NextRetryAt__c = null,
            ErrorCode__c = IntegrationConstants.ERROR_CONFIGURATION,
            ErrorMessage__c = IntegrationSanitizer.sanitize(reason, null)
        );
    }
}
