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
        IntegrationConfigService.Config config = IntegrationConfigService.get(current.IntegrationKey__c);
        IntegrationTransaction__c claimed =
            IntegrationTransactionService.claim(transactionId, config.processingLeaseSeconds);

        if (claimed != null) {
            System.enqueueJob(new IntegrationExecutionJob(claimed.Id));
        }
    }
}
