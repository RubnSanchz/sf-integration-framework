@IsTest
private class IntegrationAttemptServiceTest {
    @TestSetup
    static void makeFrameworkUser() {
        IntegrationTestDataFactory.createFrameworkUser();
    }

    private static IntegrationRequest request() {
        return new IntegrationRequest(IntegrationTestDataFactory.INTEGRATION_KEY, 'CREATE', 'POST', '/a')
            .withBody('{"password":"hunter2","id":1}');
    }

    private static IntegrationResponse response() {
        IntegrationResponse response = new IntegrationResponse();
        response.statusCode = 201;
        response.body = '{"access_token":"leaked","id":"EXT-1"}';
        response.successful = true;
        response.retryable = false;
        return response;
    }

    @IsTest
    static void bodiesAreNotPersistedUnlessTheIntegrationAsksForIt() {
        IntegrationConfigService.Config config = IntegrationTestDataFactory.config(true);

        System.runAs(IntegrationTestDataFactory.frameworkUser()) {
            IntegrationTransaction__c transactionRecord =
                IntegrationTestDataFactory.processing('attempt-001', 1);

            IntegrationAttemptService.record(
                transactionRecord, request(), response(), System.now(), 120,
                IntegrationConstants.RESULT_SUCCESS, null, null, config
            );

            IntegrationAttempt__c attempt = IntegrationTestDataFactory.attemptsOf(transactionRecord.Id)[0];
            IntegrationAttempt__c bodies = [
                SELECT RequestBody__c, ResponseBody__c, HttpStatusCode__c, DurationMs__c, AttemptNumber__c
                FROM IntegrationAttempt__c WHERE Id = :attempt.Id
            ];

            System.assertEquals(null, bodies.RequestBody__c, 'Payload logging is opt-in.');
            System.assertEquals(null, bodies.ResponseBody__c);
            System.assertEquals(201, bodies.HttpStatusCode__c);
            System.assertEquals(120, bodies.DurationMs__c);
            System.assertEquals(1, bodies.AttemptNumber__c);
        }
    }

    @IsTest
    static void persistedBodiesAreSanitized() {
        IntegrationConfigService.Config config = IntegrationTestDataFactory.config(true);
        config.logRequestBody = true;
        config.logResponseBody = true;
        IntegrationConfigService.setTestConfig(config);

        System.runAs(IntegrationTestDataFactory.frameworkUser()) {
            IntegrationTransaction__c transactionRecord =
                IntegrationTestDataFactory.processing('attempt-002', 1);

            IntegrationAttemptService.record(
                transactionRecord, request(), response(), System.now(), 120,
                IntegrationConstants.RESULT_SUCCESS, null, null, config
            );

            IntegrationAttempt__c stored = [
                SELECT RequestBody__c, ResponseBody__c
                FROM IntegrationAttempt__c WHERE Transaction__c = :transactionRecord.Id
            ];

            System.assert(!stored.RequestBody__c.contains('hunter2'), stored.RequestBody__c);
            System.assert(!stored.ResponseBody__c.contains('leaked'), stored.ResponseBody__c);
            System.assert(stored.RequestBody__c.contains('[REDACTED]'), stored.RequestBody__c);
            System.assert(
                stored.ResponseBody__c.contains('EXT-1'),
                'Only the secrets go, the rest has to stay readable: ' + stored.ResponseBody__c
            );
        }
    }

    @IsTest
    static void anAttemptIsRecordedEvenWhenTheConfigurationIsWhatFailed() {
        IntegrationTestDataFactory.config(true);

        System.runAs(IntegrationTestDataFactory.frameworkUser()) {
            IntegrationTransaction__c transactionRecord =
                IntegrationTestDataFactory.processing('attempt-003', 1);

            // config is null: this is the CONFIGURATION_ERROR path, where the
            // configuration could not be resolved at all.
            IntegrationAttemptService.record(
                transactionRecord, null, null, System.now(), 5,
                IntegrationConstants.RESULT_ERROR,
                IntegrationConstants.ERROR_CONFIGURATION,
                'Missing IntegrationDefinition__mdt for TEST',
                null
            );

            IntegrationAttempt__c stored = [
                SELECT Result__c, ErrorCode__c, ErrorMessage__c, EndpointAlias__c, HttpMethod__c
                FROM IntegrationAttempt__c WHERE Transaction__c = :transactionRecord.Id
            ];

            System.assertEquals(IntegrationConstants.RESULT_ERROR, stored.Result__c);
            System.assertEquals(IntegrationConstants.ERROR_CONFIGURATION, stored.ErrorCode__c);
            System.assert(stored.ErrorMessage__c.contains('Missing'), stored.ErrorMessage__c);
            System.assertEquals(null, stored.EndpointAlias__c, 'There was no credential to name.');
            System.assertEquals(null, stored.HttpMethod__c, 'And no request to describe.');
        }
    }
}
