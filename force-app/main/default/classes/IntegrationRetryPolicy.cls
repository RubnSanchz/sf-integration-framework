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
        Decimal multiplier = Math.pow(2, exponent);
        Integer delay = (Decimal.valueOf(config.retryBaseDelaySeconds) * multiplier).intValue();
        return System.now().addSeconds(delay);
    }
}
