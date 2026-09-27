@IsTest
private class IntegrationCoreTest {
    private static IntegrationConfigService.Config configure(Boolean idempotent) {
        IntegrationConfigService.Config config = new IntegrationConfigService.Config();
        config.integrationKey = 'TEST';
        config.namedCredential = 'Test_Named_Credential';
        config.handlerClass = 'UnusedHandler';
        config.idempotencyHeader = 'Idempotency-Key';
        config.timeoutMs = 30000;
        config.processingLeaseSeconds = 120;
        config.maxRetries = 3;
        config.retryBaseDelaySeconds = 60;
        config.retryEnabled = true;
        config.idempotencyEnabled = idempotent;
        config.logRequestBody = false;
        config.logResponseBody = false;
        config.maxPayloadChars = 12000;
        config.retryableStatusCodes.addAll(new Set<Integer>{408, 429, 500, 502, 503, 504});
        IntegrationConfigService.setTestConfig(config);
        return config;
    }

    @IsTest
    static void createsAndClaimsLogicalTransaction() {
        configure(true);
        IntegrationRequest request = new IntegrationRequest('TEST', 'CREATE', 'POST', '/resource');
        request.idempotencyKey = 'op-001';

        IntegrationTransaction__c created = IntegrationTransactionService.create(request);
        System.assertEquals(IntegrationConstants.STATUS_PENDING, created.Status__c);
        System.assertEquals('op-001', created.IdempotencyKey__c);

        IntegrationTransaction__c claimed = IntegrationTransactionService.claim(created.Id, 120);
        System.assertNotEquals(null, claimed);
        System.assertEquals(IntegrationConstants.STATUS_PROCESSING, claimed.Status__c);
        System.assertEquals(1, claimed.AttemptCount__c);
        System.assertNotEquals(null, claimed.LeaseExpiresAt__c);

        IntegrationTransaction__c secondClaim = IntegrationTransactionService.claim(created.Id, 120);
        System.assertEquals(null, secondClaim, 'A PROCESSING transaction must not be claimed twice.');
    }

    @IsTest
    static void retryPolicyUsesExponentialBackoffAndMaximumAttempts() {
        IntegrationConfigService.Config config = configure(true);
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

    @IsTest
    static void sanitizerRedactsSecretsAndTruncatesPayloads() {
        String payload = '{"access_token":"secret","password":"hidden","value":"safe"}';
        String sanitized = IntegrationSanitizer.sanitize(payload, 1000);

        System.assert(!sanitized.contains('secret'));
        System.assert(!sanitized.contains('hidden'));
        System.assert(sanitized.contains('[REDACTED]'));
        System.assert(sanitized.contains('safe'), 'Non-sensitive values must survive.');

        Map<String, String> headers = IntegrationSanitizer.sanitizeHeaders(
            new Map<String, String>{'Authorization' => 'Bearer abc', 'Accept' => 'application/json'}
        );
        System.assertEquals('[REDACTED]', headers.get('Authorization'));
        System.assertEquals('application/json', headers.get('Accept'));
    }

    @IsTest
    static void sanitizerTruncationFitsWithinTheLimit() {
        String source = '0123456789'.repeat(10);

        String truncated = IntegrationSanitizer.sanitize(source, 20);
        System.assertEquals(20, truncated.length(), 'The suffix counts towards maxChars.');
        System.assert(truncated.endsWith('...[TRUNCATED]'));
        System.assertEquals('012345', truncated.substring(0, 6));

        System.assertEquals(
            '12345',
            IntegrationSanitizer.sanitize('12345', 5),
            'A value exactly at the limit is untouched.'
        );
        System.assertEquals(
            '12345',
            IntegrationSanitizer.sanitize('1234567890', 5),
            'With no room for the suffix the value is only cut.'
        );
    }

    @IsTest
    static void sanitizerRedactsEveryKnownSecretKey() {
        for (String key : IntegrationSanitizer.SENSITIVE_KEYS) {
            String json = IntegrationSanitizer.sanitize('{"' + key + '":"leak-me"}', 1000);
            System.assert(
                !json.contains('leak-me'),
                'JSON key not redacted: ' + key + ' -> ' + json
            );

            String query = IntegrationSanitizer.sanitize('a=1&' + key + '=leak-me&b=2', 1000);
            System.assert(
                !query.contains('leak-me'),
                'Query key not redacted: ' + key + ' -> ' + query
            );
            System.assert(query.contains('b=2'), 'Redaction must stop at the separator.');
        }
    }

    @IsTest
    static void sanitizerRedactsBearerTokensInFreeText() {
        String sanitized = IntegrationSanitizer.sanitize(
            'Callout failed with header Authorization: Bearer eyJhbGciOi.Jz-9_x',
            1000
        );

        System.assert(!sanitized.contains('eyJhbGciOi'), sanitized);
        System.assert(sanitized.contains('Bearer [REDACTED]'), sanitized);
    }

    @IsTest
    static void transactionErrorMessagesAreSanitized() {
        configure(true);
        IntegrationRequest request = new IntegrationRequest('TEST', 'CREATE', 'POST', '/resource');
        request.idempotencyKey = 'op-sanitize-001';
        IntegrationTransaction__c created = IntegrationTransactionService.create(request);

        IntegrationTransactionService.markError(
            created.Id,
            'CLIENT_ERROR',
            'Callout to /v1/orders?access_token=abc123 failed',
            null
        );
        IntegrationTransaction__c stored = [
            SELECT ErrorMessage__c FROM IntegrationTransaction__c WHERE Id = :created.Id
        ];
        System.assert(!stored.ErrorMessage__c.contains('abc123'), stored.ErrorMessage__c);
        System.assert(stored.ErrorMessage__c.contains('[REDACTED]'), stored.ErrorMessage__c);

        IntegrationTransactionService.markUnknown(
            created.Id,
            'CALLOUT_EXCEPTION',
            'Read timed out using Bearer abc123def'
        );
        stored = [
            SELECT ErrorMessage__c FROM IntegrationTransaction__c WHERE Id = :created.Id
        ];
        System.assert(!stored.ErrorMessage__c.contains('abc123def'), stored.ErrorMessage__c);
        System.assert(stored.ErrorMessage__c.contains('[REDACTED]'), stored.ErrorMessage__c);
    }

    @IsTest
    static void recoveryRequeuesOnlyIdempotentStaleTransactions() {
        configure(true);
        IntegrationTransaction__c stale = new IntegrationTransaction__c(
            IdempotencyKey__c = 'stale-001',
            IntegrationKey__c = 'TEST',
            Operation__c = 'CREATE',
            Direction__c = 'OUTBOUND',
            Status__c = IntegrationConstants.STATUS_PROCESSING,
            AttemptCount__c = 1,
            ProcessingStartedAt__c = System.now().addMinutes(-10),
            LeaseExpiresAt__c = System.now().addMinutes(-5)
        );
        insert stale;

        IntegrationRecoveryScheduler scheduler = new IntegrationRecoveryScheduler();
        scheduler.execute(null);

        stale = [
            SELECT Status__c, ErrorCode__c
            FROM IntegrationTransaction__c
            WHERE Id = :stale.Id
        ];
        System.assertEquals(IntegrationConstants.STATUS_PENDING, stale.Status__c);
        System.assertEquals('STALE_LEASE', stale.ErrorCode__c);

        System.assertEquals(
            1,
            [SELECT COUNT() FROM IntegrationAttempt__c WHERE Transaction__c = :stale.Id]
        );
    }
}
