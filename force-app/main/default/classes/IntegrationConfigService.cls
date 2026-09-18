public inherited sharing class IntegrationConfigService {
    public class Config {
        public String integrationKey;
        public String namedCredential;
        public String handlerClass;
        public String idempotencyHeader;
        public Integer timeoutMs;
        public Integer processingLeaseSeconds;
        public Integer maxRetries;
        public Integer retryBaseDelaySeconds;
        public Boolean retryEnabled;
        public Boolean idempotencyEnabled;
        public Boolean logRequestBody;
        public Boolean logResponseBody;
        public Integer maxPayloadChars;
        public Set<Integer> retryableStatusCodes = new Set<Integer>();
    }

    public static Config get(String integrationKey) {
        IntegrationDefinition__mdt definition = IntegrationDefinition__mdt.getInstance(integrationKey);
        if (definition == null) {
            throw new IntegrationConfigurationException('Missing IntegrationDefinition__mdt for ' + integrationKey);
        }

        Config config = new Config();
        config.integrationKey = integrationKey;
        config.namedCredential = definition.NamedCredential__c;
        config.handlerClass = definition.HandlerClass__c;
        config.idempotencyHeader = String.isBlank(definition.IdempotencyHeader__c)
            ? 'Idempotency-Key'
            : definition.IdempotencyHeader__c;
        config.timeoutMs = integerValue(definition.TimeoutMs__c, 30000);
        config.processingLeaseSeconds = integerValue(definition.ProcessingLeaseSeconds__c, 60);
        config.maxRetries = integerValue(definition.MaxRetries__c, 3);
        config.retryBaseDelaySeconds = integerValue(definition.RetryBaseDelaySeconds__c, 60);
        config.retryEnabled = definition.RetryEnabled__c;
        config.idempotencyEnabled = definition.IdempotencyEnabled__c;
        config.logRequestBody = definition.LogRequestBody__c;
        config.logResponseBody = definition.LogResponseBody__c;
        config.maxPayloadChars = integerValue(definition.MaxPayloadChars__c, 12000);

        if (String.isNotBlank(definition.RetryableStatusCodes__c)) {
            for (String token : definition.RetryableStatusCodes__c.split(',')) {
                try {
                    config.retryableStatusCodes.add(Integer.valueOf(token.trim()));
                } catch (Exception ignored) {
                    throw new IntegrationConfigurationException(
                        'Invalid retryable HTTP status code "' + token + '" for ' + integrationKey
                    );
                }
            }
        } else {
            config.retryableStatusCodes.addAll(new Set<Integer>{408, 429, 500, 502, 503, 504});
        }
        return config;
    }

    private static Integer integerValue(Decimal value, Integer fallback) {
        return value == null ? fallback : value.intValue();
    }

    public class IntegrationConfigurationException extends Exception {}
}
