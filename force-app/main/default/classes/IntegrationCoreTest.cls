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

        IntegrationTransaction__c stored = [
            SELECT Disposition__c FROM IntegrationTransaction__c WHERE Id = :created.Id
        ];
        System.assertEquals(
            IntegrationConstants.DISPOSITION_NONE,
            stored.Disposition__c,
            'A transaction starts with nothing for the system to do about it.'
        );
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

    // Checkbox fields on a record built in memory read back as false, not as the
    // defaultValue declared on the field, so they are set here explicitly to
    // mirror what a stored IntegrationDefinition__mdt record would carry.
    private static Set<String> picklistValues(Schema.SObjectField field) {
        Set<String> values = new Set<String>();
        for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
            values.add(entry.getValue());
        }
        return values;
    }

    // CLAUDE.md requires the Apex constants and the restricted picklists to stay
    // in step. A mismatch only shows up as a DML error at runtime.
    @IsTest
    static void constantsMatchTheRestrictedPicklists() {
        System.assertEquals(
            new Set<String>{
                IntegrationConstants.DISPOSITION_NONE,
                IntegrationConstants.DISPOSITION_RETRY,
                IntegrationConstants.DISPOSITION_RECONCILE,
                IntegrationConstants.DISPOSITION_MANUAL,
                IntegrationConstants.DISPOSITION_TERMINAL
            },
            picklistValues(IntegrationTransaction__c.Disposition__c)
        );

        System.assertEquals(
            new Set<String>{
                IntegrationConstants.STATUS_PENDING,
                IntegrationConstants.STATUS_PROCESSING,
                IntegrationConstants.STATUS_SUCCESS,
                IntegrationConstants.STATUS_ERROR,
                IntegrationConstants.STATUS_UNKNOWN
            },
            picklistValues(IntegrationTransaction__c.Status__c)
        );

        System.assertEquals(
            new Set<String>{
                IntegrationConstants.RESULT_SUCCESS,
                IntegrationConstants.RESULT_ERROR,
                IntegrationConstants.RESULT_UNKNOWN
            },
            picklistValues(IntegrationAttempt__c.Result__c)
        );
    }

    private static IntegrationDefinition__mdt definition() {
        return new IntegrationDefinition__mdt(
            NamedCredential__c = 'Test_Named_Credential',
            HandlerClass__c = 'UnusedHandler',
            RetryEnabled__c = true,
            IdempotencyEnabled__c = true,
            LogRequestBody__c = false,
            LogResponseBody__c = false
        );
    }

    private static String rejectionMessage(IntegrationDefinition__mdt definition) {
        try {
            IntegrationConfigService.fromDefinition('TEST', definition);
            return null;
        } catch (IntegrationConfigService.IntegrationConfigurationException ex) {
            return ex.getMessage();
        }
    }

    @IsTest
    static void configParsingAppliesDocumentedDefaults() {
        IntegrationConfigService.Config config =
            IntegrationConfigService.fromDefinition('TEST', definition());

        System.assertEquals('Idempotency-Key', config.idempotencyHeader);
        System.assertEquals(30000, config.timeoutMs);
        System.assertEquals(60, config.processingLeaseSeconds);
        System.assertEquals(3, config.maxRetries);
        System.assertEquals(60, config.retryBaseDelaySeconds);
        System.assertEquals(12000, config.maxPayloadChars);
        System.assertEquals(true, config.retryEnabled);
        System.assertEquals(true, config.idempotencyEnabled);
        System.assertEquals(false, config.logRequestBody);
        System.assertEquals(false, config.logResponseBody);
        System.assertEquals(
            new Set<Integer>{408, 429, 500, 502, 503, 504},
            config.retryableStatusCodes
        );

        // Checkbox fields are never null on an sObject: assigning null stores false,
        // so the parser has nothing to guard against.
        IntegrationDefinition__mdt nulled = definition();
        nulled.RetryEnabled__c = null;
        System.assertEquals(
            false,
            IntegrationConfigService.fromDefinition('TEST', nulled).retryEnabled
        );
    }

    @IsTest
    static void configValidationRejectsOutOfRangeValues() {
        IntegrationDefinition__mdt tooFast = definition();
        tooFast.TimeoutMs__c = 0;
        System.assert(rejectionMessage(tooFast).contains('TimeoutMs__c'), rejectionMessage(tooFast));
        System.assert(rejectionMessage(tooFast).contains('TEST'), 'The message must name the integration.');

        IntegrationDefinition__mdt tooSlow = definition();
        tooSlow.TimeoutMs__c = 120001;
        tooSlow.ProcessingLeaseSeconds__c = 300;
        System.assert(rejectionMessage(tooSlow).contains('TimeoutMs__c'), rejectionMessage(tooSlow));

        // 60 s of callout needs at least 90 s of lease, or recovery reclaims live work.
        IntegrationDefinition__mdt shortLease = definition();
        shortLease.TimeoutMs__c = 60000;
        System.assert(
            rejectionMessage(shortLease).contains('ProcessingLeaseSeconds__c'),
            rejectionMessage(shortLease)
        );

        IntegrationDefinition__mdt noPayload = definition();
        noPayload.MaxPayloadChars__c = 0;
        System.assert(rejectionMessage(noPayload).contains('MaxPayloadChars__c'), rejectionMessage(noPayload));

        IntegrationDefinition__mdt hugePayload = definition();
        hugePayload.MaxPayloadChars__c = 32769;
        System.assert(rejectionMessage(hugePayload).contains('MaxPayloadChars__c'), rejectionMessage(hugePayload));

        IntegrationDefinition__mdt negativeRetries = definition();
        negativeRetries.MaxRetries__c = -1;
        System.assert(rejectionMessage(negativeRetries).contains('MaxRetries__c'), rejectionMessage(negativeRetries));

        IntegrationDefinition__mdt noDelay = definition();
        noDelay.RetryBaseDelaySeconds__c = 0;
        System.assert(
            rejectionMessage(noDelay).contains('RetryBaseDelaySeconds__c'),
            rejectionMessage(noDelay)
        );
    }

    @IsTest
    static void configValidationAcceptsTheBoundaries() {
        IntegrationDefinition__mdt boundary = definition();
        boundary.TimeoutMs__c = 120000;
        boundary.ProcessingLeaseSeconds__c = 150;
        boundary.MaxPayloadChars__c = 32768;
        boundary.MaxRetries__c = 0;
        boundary.RetryBaseDelaySeconds__c = 1;

        System.assertEquals(null, rejectionMessage(boundary), 'The exact boundaries must be valid.');

        // The shipped defaults have to satisfy their own rules.
        System.assertEquals(null, rejectionMessage(definition()));
    }

    @IsTest
    static void configParsesRetryableStatusCodes() {
        IntegrationDefinition__mdt listed = definition();
        listed.RetryableStatusCodes__c = '408, 500 ,503';
        System.assertEquals(
            new Set<Integer>{408, 500, 503},
            IntegrationConfigService.fromDefinition('TEST', listed).retryableStatusCodes
        );

        IntegrationDefinition__mdt broken = definition();
        broken.RetryableStatusCodes__c = '408,abc';
        String message = rejectionMessage(broken);
        System.assert(message != null && message.contains('abc'), message);
    }

    @IsTest
    static void configIsCachedPerTransaction() {
        IntegrationDefinition__mdt first = definition();
        first.TimeoutMs__c = 20000;
        IntegrationConfigService.Config initial = IntegrationConfigService.cached('CACHED', first);

        IntegrationDefinition__mdt second = definition();
        second.TimeoutMs__c = 45000;
        second.ProcessingLeaseSeconds__c = 120;
        IntegrationConfigService.Config again = IntegrationConfigService.cached('CACHED', second);

        System.assert(initial === again, 'The same key must return the same instance.');
        System.assertEquals(20000, again.timeoutMs, 'The second definition must not be parsed again.');

        IntegrationConfigService.clearTestConfigs();
        System.assertEquals(
            45000,
            IntegrationConfigService.cached('CACHED', second).timeoutMs,
            'Clearing the test state must also clear the cache.'
        );
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
            null,
            IntegrationConstants.DISPOSITION_MANUAL
        );
        IntegrationTransaction__c stored = [
            SELECT ErrorMessage__c FROM IntegrationTransaction__c WHERE Id = :created.Id
        ];
        System.assert(!stored.ErrorMessage__c.contains('abc123'), stored.ErrorMessage__c);
        System.assert(stored.ErrorMessage__c.contains('[REDACTED]'), stored.ErrorMessage__c);

        IntegrationTransactionService.markUnknown(
            created.Id,
            'CALLOUT_EXCEPTION',
            'Read timed out using Bearer abc123def',
            IntegrationConstants.DISPOSITION_RECONCILE
        );
        stored = [
            SELECT ErrorMessage__c FROM IntegrationTransaction__c WHERE Id = :created.Id
        ];
        System.assert(!stored.ErrorMessage__c.contains('abc123def'), stored.ErrorMessage__c);
        System.assert(stored.ErrorMessage__c.contains('[REDACTED]'), stored.ErrorMessage__c);
    }

    private static IntegrationTransaction__c staleProcessing(String key, Integer attemptCount) {
        IntegrationTransaction__c stale = new IntegrationTransaction__c(
            IdempotencyKey__c = key,
            IntegrationKey__c = 'TEST',
            Operation__c = 'CREATE',
            Direction__c = 'OUTBOUND',
            Status__c = IntegrationConstants.STATUS_PROCESSING,
            AttemptCount__c = attemptCount,
            ProcessingStartedAt__c = System.now().addMinutes(-10),
            LeaseExpiresAt__c = System.now().addMinutes(-5)
        );
        insert stale;
        return stale;
    }

    private static IntegrationTransaction__c stored(Id transactionId) {
        return [
            SELECT Status__c, Disposition__c, ErrorCode__c, NextRetryAt__c, LeaseExpiresAt__c
            FROM IntegrationTransaction__c
            WHERE Id = :transactionId
        ];
    }

    @IsTest
    static void staleLeaseWithIdempotencyIsScheduledForAnotherAttempt() {
        configure(true);
        IntegrationTransaction__c stale = staleProcessing('stale-001', 1);

        new IntegrationRecoveryScheduler().execute(null);

        IntegrationTransaction__c recovered = stored(stale.Id);
        System.assertEquals(
            IntegrationConstants.STATUS_UNKNOWN,
            recovered.Status__c,
            'The worker died mid-flight, so the outcome is genuinely unknown: it does not go back to PENDING.'
        );
        System.assertEquals(IntegrationConstants.DISPOSITION_RETRY, recovered.Disposition__c);
        System.assertEquals(IntegrationConstants.ERROR_STALE_LEASE, recovered.ErrorCode__c);
        System.assertNotEquals(null, recovered.NextRetryAt__c, 'RETRY always carries a date.');
        System.assertEquals(null, recovered.LeaseExpiresAt__c);
        System.assertEquals(
            1,
            [SELECT COUNT() FROM IntegrationAttempt__c WHERE Transaction__c = :stale.Id],
            'The expired lease is recorded as a fact.'
        );
    }

    // RECONCILE means "uncertain, not yet evaluated". The recovery scheduler is
    // the evaluator: it turns each one into RETRY or, when nothing automatic can
    // resolve it, into MANUAL. Both steps run in a single scheduled execution.
    @IsTest
    static void staleLeaseWithoutIdempotencyEndsUpNeedingAPerson() {
        configure(false);
        IntegrationTransaction__c stale = staleProcessing('stale-002', 1);

        IntegrationRecoveryScheduler.recoverStaleProcessing();

        IntegrationTransaction__c afterFirstStep = stored(stale.Id);
        System.assertEquals(IntegrationConstants.STATUS_UNKNOWN, afterFirstStep.Status__c);
        System.assertEquals(
            IntegrationConstants.DISPOSITION_RECONCILE,
            afterFirstStep.Disposition__c,
            'Sending again could duplicate the operation, so it is not a RETRY.'
        );
        System.assertEquals(null, afterFirstStep.NextRetryAt__c);

        IntegrationRecoveryScheduler.recoverSafeUnknowns();

        IntegrationTransaction__c afterSecondStep = stored(stale.Id);
        System.assertEquals(
            IntegrationConstants.DISPOSITION_MANUAL,
            afterSecondStep.Disposition__c,
            'Without idempotency no automatic path exists, so it must reach a person.'
        );
        System.assertEquals(
            IntegrationConstants.STATUS_UNKNOWN,
            afterSecondStep.Status__c,
            'The status still records that the remote side may have acted.'
        );
    }

    @IsTest
    static void reconcilableUnknownIsRequeuedOnlyWhileRetriesRemain() {
        configure(true);
        IntegrationTransaction__c pendingReview = new IntegrationTransaction__c(
            IdempotencyKey__c = 'unknown-001',
            IntegrationKey__c = 'TEST',
            Operation__c = 'CREATE',
            Direction__c = 'OUTBOUND',
            Status__c = IntegrationConstants.STATUS_UNKNOWN,
            Disposition__c = IntegrationConstants.DISPOSITION_RECONCILE,
            AttemptCount__c = 1
        );
        IntegrationTransaction__c exhausted = new IntegrationTransaction__c(
            IdempotencyKey__c = 'unknown-002',
            IntegrationKey__c = 'TEST',
            Operation__c = 'CREATE',
            Direction__c = 'OUTBOUND',
            Status__c = IntegrationConstants.STATUS_UNKNOWN,
            Disposition__c = IntegrationConstants.DISPOSITION_RECONCILE,
            AttemptCount__c = 9
        );
        insert new List<IntegrationTransaction__c>{pendingReview, exhausted};

        IntegrationRecoveryScheduler.recoverSafeUnknowns();

        System.assertEquals(
            IntegrationConstants.DISPOSITION_RETRY,
            stored(pendingReview.Id).Disposition__c
        );
        System.assertNotEquals(null, stored(pendingReview.Id).NextRetryAt__c);
        System.assertEquals(
            IntegrationConstants.DISPOSITION_MANUAL,
            stored(exhausted.Id).Disposition__c,
            'With no retries left it must leave the reconciliation window, or it crowds out newer work.'
        );
    }

    @IsTest
    static void recoveryKeepsGoingWhenOneDefinitionIsBroken() {
        configure(true);
        IntegrationTransaction__c healthy = staleProcessing('stale-003', 1);
        IntegrationTransaction__c broken = staleProcessing('stale-004', 1);
        broken.IntegrationKey__c = 'NO_SUCH_INTEGRATION';
        update broken;

        IntegrationRecoveryScheduler.recoverStaleProcessing();

        System.assertEquals(
            IntegrationConstants.DISPOSITION_RETRY,
            stored(healthy.Id).Disposition__c,
            'One broken definition must not stop the rest of the run.'
        );
        IntegrationTransaction__c parked = stored(broken.Id);
        System.assertEquals(IntegrationConstants.DISPOSITION_MANUAL, parked.Disposition__c);
        System.assertEquals(IntegrationConstants.ERROR_CONFIGURATION, parked.ErrorCode__c);
    }

    @IsTest
    static void aRetryIsNotDispatchedBeforeItsDate() {
        configure(true);
        IntegrationTransaction__c later = new IntegrationTransaction__c(
            IdempotencyKey__c = 'future-001',
            IntegrationKey__c = 'TEST',
            Operation__c = 'CREATE',
            Direction__c = 'OUTBOUND',
            Status__c = IntegrationConstants.STATUS_ERROR,
            Disposition__c = IntegrationConstants.DISPOSITION_RETRY,
            NextRetryAt__c = System.now().addMinutes(30),
            AttemptCount__c = 1
        );
        insert later;

        System.assertEquals(
            null,
            IntegrationTransactionService.claim(later.Id, 120),
            'A retry scheduled for later must not be claimed now.'
        );

        Test.startTest();
        new IntegrationDispatchScheduler().execute(null);
        Test.stopTest();

        System.assertEquals(
            IntegrationConstants.STATUS_ERROR,
            stored(later.Id).Status__c,
            'And it must not be dispatched either.'
        );
    }

    @IsTest
    static void aDueRetryIsClaimedWhateverItsStatus() {
        configure(true);
        IntegrationTransaction__c due = new IntegrationTransaction__c(
            IdempotencyKey__c = 'due-001',
            IntegrationKey__c = 'TEST',
            Operation__c = 'CREATE',
            Direction__c = 'OUTBOUND',
            Status__c = IntegrationConstants.STATUS_UNKNOWN,
            Disposition__c = IntegrationConstants.DISPOSITION_RETRY,
            NextRetryAt__c = System.now().addMinutes(-1),
            AttemptCount__c = 1
        );
        insert due;

        IntegrationTransaction__c claimed = IntegrationTransactionService.claim(due.Id, 120);
        System.assertNotEquals(null, claimed, 'UNKNOWN + RETRY is work the system intends to run again.');
        System.assertEquals(IntegrationConstants.STATUS_PROCESSING, claimed.Status__c);
        System.assertEquals(2, claimed.AttemptCount__c);
        System.assertEquals(
            IntegrationConstants.DISPOSITION_NONE,
            stored(due.Id).Disposition__c,
            'While a worker owns it there is no pending decision.'
        );
    }

    @IsTest
    static void aParkedTransactionIsNeverPickedUpAutomatically() {
        configure(true);
        IntegrationTransaction__c parked = new IntegrationTransaction__c(
            IdempotencyKey__c = 'manual-001',
            IntegrationKey__c = 'TEST',
            Operation__c = 'CREATE',
            Direction__c = 'OUTBOUND',
            Status__c = IntegrationConstants.STATUS_ERROR,
            Disposition__c = IntegrationConstants.DISPOSITION_MANUAL,
            AttemptCount__c = 1
        );
        insert parked;

        System.assertEquals(null, IntegrationTransactionService.claim(parked.Id, 120));

        IntegrationRecoveryScheduler.recoverSafeUnknowns();
        System.assertEquals(
            IntegrationConstants.DISPOSITION_MANUAL,
            stored(parked.Id).Disposition__c,
            'Only an administrator takes it out of MANUAL.'
        );
    }
}
