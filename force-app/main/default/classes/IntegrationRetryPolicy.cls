public class IntegrationRetryPolicy {
    public static Boolean canRetry(
        IntegrationTransaction__c transactionRecord,
        IntegrationConfigService.Config config
    ) {
        Integer attempts = transactionRecord.AttemptCount__c == null
            ? 0
            : transactionRecord.AttemptCount__c.intValue();
        return config.retryEnabled && attempts < config.maxRetries;
    }

    public static Datetime nextRetryAt(
        IntegrationTransaction__c transactionRecord,
        IntegrationConfigService.Config config
    ) {
        Integer attempts = transactionRecord.AttemptCount__c == null
            ? 1
            : Math.max(1, transactionRecord.AttemptCount__c.intValue());
        Integer exponent = Math.min(attempts - 1, 10);
        Integer multiplier = 1;
        for (Integer i = 0; i < exponent; i++) {
            multiplier *= 2;
        }
        Integer delay = config.retryBaseDelaySeconds * multiplier;
        return System.now().addSeconds(delay);
    }
}
