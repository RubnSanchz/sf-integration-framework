@IsTest
private class IntegrationRetryPolicyTest {
    @IsTest
    static void retryPolicyUsesExponentialBackoffAndMaximumAttempts() {
        IntegrationConfigService.Config config = IntegrationTestDataFactory.config(true);
        IntegrationTransaction__c transactionRecord =
            new IntegrationTransaction__c(AttemptCount__c = 2);

        System.assertEquals(true, IntegrationRetryPolicy.canRetry(transactionRecord, config));

        Datetime beforeValue = System.now().addSeconds(119);
        Datetime retryAt = IntegrationRetryPolicy.nextRetryAt(transactionRecord, config);
        Datetime afterValue = System.now().addSeconds(121);
        System.assert(retryAt >= beforeValue && retryAt <= afterValue);

        transactionRecord.AttemptCount__c = 3;
        System.assertEquals(true, IntegrationRetryPolicy.canRetry(transactionRecord, config));

        transactionRecord.AttemptCount__c = 4;
        System.assertEquals(false, IntegrationRetryPolicy.canRetry(transactionRecord, config));
    }
}
