@IsTest
private class IntegrationConfigServiceTest {
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
            IntegrationConfigService.fromDefinition('TEST', IntegrationTestDataFactory.definition());

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
        IntegrationDefinition__mdt nulled = IntegrationTestDataFactory.definition();
        nulled.RetryEnabled__c = null;
        System.assertEquals(
            false,
            IntegrationConfigService.fromDefinition('TEST', nulled).retryEnabled
        );
    }

    @IsTest
    static void configValidationRejectsOutOfRangeValues() {
        IntegrationDefinition__mdt tooFast = IntegrationTestDataFactory.definition();
        tooFast.TimeoutMs__c = 0;
        System.assert(rejectionMessage(tooFast).contains('TimeoutMs__c'), rejectionMessage(tooFast));
        System.assert(rejectionMessage(tooFast).contains('TEST'), 'The message must name the integration.');

        IntegrationDefinition__mdt tooSlow = IntegrationTestDataFactory.definition();
        tooSlow.TimeoutMs__c = 120001;
        tooSlow.ProcessingLeaseSeconds__c = 300;
        System.assert(rejectionMessage(tooSlow).contains('TimeoutMs__c'), rejectionMessage(tooSlow));

        // 60 s of callout needs at least 90 s of lease, or recovery reclaims live work.
        IntegrationDefinition__mdt shortLease = IntegrationTestDataFactory.definition();
        shortLease.TimeoutMs__c = 60000;
        System.assert(
            rejectionMessage(shortLease).contains('ProcessingLeaseSeconds__c'),
            rejectionMessage(shortLease)
        );

        IntegrationDefinition__mdt noPayload = IntegrationTestDataFactory.definition();
        noPayload.MaxPayloadChars__c = 0;
        System.assert(rejectionMessage(noPayload).contains('MaxPayloadChars__c'), rejectionMessage(noPayload));

        IntegrationDefinition__mdt hugePayload = IntegrationTestDataFactory.definition();
        hugePayload.MaxPayloadChars__c = 32769;
        System.assert(rejectionMessage(hugePayload).contains('MaxPayloadChars__c'), rejectionMessage(hugePayload));

        IntegrationDefinition__mdt negativeRetries = IntegrationTestDataFactory.definition();
        negativeRetries.MaxRetries__c = -1;
        System.assert(rejectionMessage(negativeRetries).contains('MaxRetries__c'), rejectionMessage(negativeRetries));

        IntegrationDefinition__mdt noDelay = IntegrationTestDataFactory.definition();
        noDelay.RetryBaseDelaySeconds__c = 0;
        System.assert(
            rejectionMessage(noDelay).contains('RetryBaseDelaySeconds__c'),
            rejectionMessage(noDelay)
        );
    }

    @IsTest
    static void configValidationAcceptsTheBoundaries() {
        IntegrationDefinition__mdt boundary = IntegrationTestDataFactory.definition();
        boundary.TimeoutMs__c = 120000;
        boundary.ProcessingLeaseSeconds__c = 150;
        boundary.MaxPayloadChars__c = 32768;
        boundary.MaxRetries__c = 0;
        boundary.RetryBaseDelaySeconds__c = 1;

        System.assertEquals(null, rejectionMessage(boundary), 'The exact boundaries must be valid.');

        // The shipped defaults have to satisfy their own rules.
        System.assertEquals(null, rejectionMessage(IntegrationTestDataFactory.definition()));
    }

    @IsTest
    static void configParsesRetryableStatusCodes() {
        IntegrationDefinition__mdt listed = IntegrationTestDataFactory.definition();
        listed.RetryableStatusCodes__c = '408, 500 ,503';
        System.assertEquals(
            new Set<Integer>{408, 500, 503},
            IntegrationConfigService.fromDefinition('TEST', listed).retryableStatusCodes
        );

        IntegrationDefinition__mdt broken = IntegrationTestDataFactory.definition();
        broken.RetryableStatusCodes__c = '408,abc';
        String message = rejectionMessage(broken);
        System.assert(message != null && message.contains('abc'), message);
    }

    @IsTest
    static void configIsCachedPerTransaction() {
        IntegrationDefinition__mdt first = IntegrationTestDataFactory.definition();
        first.TimeoutMs__c = 20000;
        IntegrationConfigService.Config initial = IntegrationConfigService.cached('CACHED', first);

        IntegrationDefinition__mdt second = IntegrationTestDataFactory.definition();
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
    static void anIntegrationCanNameItsOwnIdempotencyHeader() {
        IntegrationDefinition__mdt custom = IntegrationTestDataFactory.definition();
        custom.IdempotencyHeader__c = 'X-Request-Id';

        System.assertEquals(
            'X-Request-Id',
            IntegrationConfigService.fromDefinition('TEST', custom).idempotencyHeader
        );
    }

}
