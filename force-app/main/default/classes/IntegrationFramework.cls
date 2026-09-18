public class IntegrationFramework {
    public static IntegrationTransaction__c register(IntegrationRequest request) {
        return IntegrationTransactionService.create(request);
    }

    public static IntegrationTransaction__c registerAndEnqueue(IntegrationRequest request) {
        IntegrationTransaction__c transactionRecord = register(request);
        System.enqueueJob(new IntegrationClaimJob(transactionRecord.Id));
        return transactionRecord;
    }

    public static Id enqueue(Id transactionId) {
        return System.enqueueJob(new IntegrationClaimJob(transactionId));
    }
}
