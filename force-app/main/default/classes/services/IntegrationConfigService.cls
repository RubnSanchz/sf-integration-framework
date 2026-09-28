public inherited sharing class IntegrationConfigService {
    @TestVisible
    private static Map<String, Config> testConfigs = new Map<String, Config>();

    // Every default lives here, never at a call site.
    private static final String DEFAULT_IDEMPOTENCY_HEADER = 'Idempotency-Key';
    private static final Integer DEFAULT_TIMEOUT_MS = 30000;
    private static final Integer DEFAULT_LEASE_SECONDS = 60;
    private static final Integer DEFAULT_MAX_RETRIES = 3;
    private static final Integer DEFAULT_RETRY_BASE_DELAY_SECONDS = 60;
    private static final Integer DEFAULT_MAX_PAYLOAD_CHARS = 12000;
    private static final Integer DEFAULT_RETENTION_DAYS = 30;
    private static final Set<Integer> DEFAULT_RETRYABLE_STATUS_CODES =
        new Set<Integer>{408, 429, 500, 502, 503, 504};

    // Bounds. The lease has to outlive the callout it covers, or the recovery
    // scheduler reclaims work that is still running.
    private static final Integer MAX_TIMEOUT_MS = 120000;
    private static final Integer MAX_PAYLOAD_CHARS = 32768;
    private static final Integer LEASE_HEADROOM_SECONDS = 30;

    // One instance per integration per Apex transaction: the recovery scheduler
    // calls get() once per record, up to 500 times in a single run.
    private static final Map<String, Config> CACHE = new Map<String, Config>();

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
        public Integer retentionDays;
        public Set<Integer> retryableStatusCodes = new Set<Integer>();
    }

    public static Config get(String integrationKey) {
        if (Test.isRunningTest() && testConfigs.containsKey(integrationKey)) {
            return testConfigs.get(integrationKey);
        }
        if (CACHE.containsKey(integrationKey)) {
            return CACHE.get(integrationKey);
        }

        // getInstance() is not a SOQL query, but the parsing and validation below are
        // worth doing once per transaction.
        IntegrationDefinition__mdt definition = IntegrationDefinition__mdt.getInstance(integrationKey);
        if (definition == null) {
            throw new IntegrationConfigurationException('Missing IntegrationDefinition__mdt for ' + integrationKey);
        }

        return cached(integrationKey, definition);
    }

    // Separate from get() so the cache can be exercised without a deployed
    // IntegrationDefinition__mdt: the package ships none and tests cannot
    // insert Custom Metadata.
    @TestVisible
    private static Config cached(String integrationKey, IntegrationDefinition__mdt definition) {
        if (CACHE.containsKey(integrationKey)) {
            return CACHE.get(integrationKey);
        }
        Config config = fromDefinition(integrationKey, definition);
        CACHE.put(integrationKey, config);
        return config;
    }

    // Split out from get() so the parsing can be tested on an in-memory record:
    // Custom Metadata cannot be inserted in a test, but it can be instantiated.
    @TestVisible
    private static Config fromDefinition(String integrationKey, IntegrationDefinition__mdt definition) {
        Config config = new Config();
        config.integrationKey = integrationKey;
        config.namedCredential = definition.NamedCredential__c;
        config.handlerClass = definition.HandlerClass__c;
        config.idempotencyHeader = String.isBlank(definition.IdempotencyHeader__c)
            ? DEFAULT_IDEMPOTENCY_HEADER
            : definition.IdempotencyHeader__c;
        config.timeoutMs = integerValue(definition.TimeoutMs__c, DEFAULT_TIMEOUT_MS);
        config.processingLeaseSeconds = integerValue(definition.ProcessingLeaseSeconds__c, DEFAULT_LEASE_SECONDS);
        config.maxRetries = integerValue(definition.MaxRetries__c, DEFAULT_MAX_RETRIES);
        config.retryBaseDelaySeconds = integerValue(definition.RetryBaseDelaySeconds__c, DEFAULT_RETRY_BASE_DELAY_SECONDS);
        // Checkbox fields are never null on an sObject: assigning null stores false.
        // What a stored record carries is governed by each field's defaultValue,
        // so there is nothing to fall back to here.
        config.retryEnabled = definition.RetryEnabled__c;
        config.idempotencyEnabled = definition.IdempotencyEnabled__c;
        config.logRequestBody = definition.LogRequestBody__c;
        config.logResponseBody = definition.LogResponseBody__c;
        config.maxPayloadChars = integerValue(definition.MaxPayloadChars__c, DEFAULT_MAX_PAYLOAD_CHARS);
        config.retentionDays = integerValue(definition.RetentionDays__c, DEFAULT_RETENTION_DAYS);
        config.retryableStatusCodes = parseStatusCodes(definition.RetryableStatusCodes__c, integrationKey);

        validate(config);
        return config;
    }

    private static Set<Integer> parseStatusCodes(String rawValue, String integrationKey) {
        if (String.isBlank(rawValue)) {
            return DEFAULT_RETRYABLE_STATUS_CODES.clone();
        }

        Set<Integer> codes = new Set<Integer>();
        for (String code : rawValue.split(',')) {
            try {
                codes.add(Integer.valueOf(code.trim()));
            } catch (Exception ignored) {
                throw new IntegrationConfigurationException(
                    'Invalid retryable HTTP status code "' + code + '" for ' + integrationKey
                );
            }
        }
        return codes;
    }

    private static void validate(Config config) {
        if (config.timeoutMs < 1 || config.timeoutMs > MAX_TIMEOUT_MS) {
            throw invalid(config, 'TimeoutMs__c must be between 1 and ' + MAX_TIMEOUT_MS +
                ' milliseconds, found ' + config.timeoutMs);
        }

        // Round the timeout up to whole seconds before comparing.
        Integer minimumLease = (config.timeoutMs + 999) / 1000 + LEASE_HEADROOM_SECONDS;
        if (config.processingLeaseSeconds < minimumLease) {
            throw invalid(config, 'ProcessingLeaseSeconds__c must be at least ' + minimumLease +
                ' seconds to cover a ' + config.timeoutMs + ' ms callout, found ' +
                config.processingLeaseSeconds);
        }

        if (config.maxPayloadChars < 1 || config.maxPayloadChars > MAX_PAYLOAD_CHARS) {
            throw invalid(config, 'MaxPayloadChars__c must be between 1 and ' + MAX_PAYLOAD_CHARS +
                ', found ' + config.maxPayloadChars);
        }

        if (config.maxRetries < 0) {
            throw invalid(config, 'MaxRetries__c cannot be negative, found ' + config.maxRetries);
        }

        if (config.retryBaseDelaySeconds < 1) {
            throw invalid(config, 'RetryBaseDelaySeconds__c must be at least 1 second, found ' +
                config.retryBaseDelaySeconds);
        }

        if (config.retentionDays < 1) {
            throw invalid(config, 'RetentionDays__c must be at least 1 day, found ' +
                config.retentionDays);
        }
    }

    private static IntegrationConfigurationException invalid(Config config, String detail) {
        return new IntegrationConfigurationException(
            'Invalid IntegrationDefinition__mdt for ' + config.integrationKey + ': ' + detail
        );
    }

    // The purge runs one query for every integration at once, so it needs the
    // shortest retention in the org to bound it. Anything older than that is a
    // candidate; each record is then checked against its own integration.
    public static Integer shortestRetentionDays() {
        Integer shortest = DEFAULT_RETENTION_DAYS;
        for (IntegrationDefinition__mdt definition : IntegrationDefinition__mdt.getAll().values()) {
            Integer retention = integerValue(definition.RetentionDays__c, DEFAULT_RETENTION_DAYS);
            if (retention < shortest) {
                shortest = retention;
            }
        }
        return shortest;
    }

    @TestVisible
    private static void setTestConfig(Config config) {
        testConfigs.put(config.integrationKey, config);
    }

    @TestVisible
    private static void clearTestConfigs() {
        testConfigs.clear();
        CACHE.clear();
    }

    private static Integer integerValue(Decimal value, Integer fallback) {
        return value == null ? fallback : value.intValue();
    }

    public class IntegrationConfigurationException extends Exception {}
}
