public class IntegrationClaimJob implements Queueable {
    private Id transactionId;

    public IntegrationClaimJob(Id transactionId) {
        this.transactionId = transactionId;
    }

    public void execute(QueueableContext context) {
        IntegrationTransaction__c current = [
            SELECT Id, IntegrationKey__c
            FROM IntegrationTransaction__c
            WHERE Id = :transactionId
            LIMIT 1
        ];

        IntegrationConfigService.Config config;
        try {
            config = IntegrationConfigService.get(current.IntegrationKey__c);
        } catch (Exception ex) {
            // Broken configuration is not fixed by trying again, and leaving the
            // record PENDING would have the dispatcher pick it up on every run.
            IntegrationTransactionService.markError(
                current.Id,
                IntegrationConstants.ERROR_CONFIGURATION,
                ex.getMessage(),
                null,
                IntegrationConstants.DISPOSITION_MANUAL
            );
            return;
        }

        IntegrationTransaction__c claimed;
        try {
            claimed = IntegrationTransactionService.claim(transactionId, config.processingLeaseSeconds);
        } catch (Exception ex) {
            // Nothing was sent, so retrying is always safe. Row lock contention is
            // the expected case here and it clears by itself.
            IntegrationTransactionService.markError(
                current.Id,
                IntegrationConstants.ERROR_CLAIM,
                ex.getMessage(),
                System.now().addSeconds(config.retryBaseDelaySeconds),
                IntegrationConstants.DISPOSITION_RETRY
            );
            return;
        }

        if (claimed != null) {
            // The attempt number fences the worker: if anything reclaims this
            // transaction before the job runs, it will find a different number
            // and stand down.
            System.enqueueJob(
                new IntegrationExecutionJob(claimed.Id, claimed.AttemptCount__c.intValue())
            );
        }
    }
}
