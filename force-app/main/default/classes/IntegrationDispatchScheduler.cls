public class IntegrationDispatchScheduler implements Schedulable {
    private static final Integer MAX_JOBS_PER_RUN = 40;

    public void execute(SchedulableContext context) {
        Datetime nowValue = System.now();
        // Same rule as IntegrationTransactionService.claim(), and it must stay the
        // same. A record is due either because it has never run, or because
        // something decided it should run again and said so in Disposition__c.
        // An administrator can requeue a parked record by setting RETRY, with a
        // date to delay it or without one to send it on the next run.
        List<IntegrationTransaction__c> ready = [
            SELECT Id
            FROM IntegrationTransaction__c
            WHERE (
                   Status__c = :IntegrationConstants.STATUS_PENDING
                   AND Disposition__c = :IntegrationConstants.DISPOSITION_NONE
               )
               OR (
                   Disposition__c = :IntegrationConstants.DISPOSITION_RETRY
                   AND (NextRetryAt__c = null OR NextRetryAt__c <= :nowValue)
               )
            ORDER BY CreatedDate ASC
            LIMIT :MAX_JOBS_PER_RUN
        ];

        for (IntegrationTransaction__c transactionRecord : ready) {
            System.enqueueJob(new IntegrationClaimJob(transactionRecord.Id));
        }
    }
}
