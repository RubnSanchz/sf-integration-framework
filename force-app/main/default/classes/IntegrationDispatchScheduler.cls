public class IntegrationDispatchScheduler implements Schedulable {
    private static final Integer MAX_JOBS_PER_RUN = 40;

    public void execute(SchedulableContext context) {
        Datetime nowValue = System.now();
        List<IntegrationTransaction__c> ready = [
            SELECT Id
            FROM IntegrationTransaction__c
            WHERE Status__c = :IntegrationConstants.STATUS_PENDING
               OR (
                   Status__c = :IntegrationConstants.STATUS_ERROR
                   AND NextRetryAt__c != null
                   AND NextRetryAt__c <= :nowValue
               )
            ORDER BY CreatedDate ASC
            LIMIT :MAX_JOBS_PER_RUN
        ];

        for (IntegrationTransaction__c transactionRecord : ready) {
            System.enqueueJob(new IntegrationClaimJob(transactionRecord.Id));
        }
    }
}
