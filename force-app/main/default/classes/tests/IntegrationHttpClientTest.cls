/**
 * The HTTP client is the one class that had no tests of its own. It needs no
 * DML: the transaction only supplies its idempotency key, so it can stay in
 * memory and these tests need no framework user.
 */
@IsTest
private class IntegrationHttpClientTest {
    // Keeps the request the client built, which is the only way to assert what
    // was actually sent.
    private class CapturingMock implements HttpCalloutMock {
        public HttpRequest captured;
        public Integer statusCode = 200;
        public String body = '{"ok":true}';

        public HttpResponse respond(HttpRequest request) {
            captured = request;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(statusCode);
            response.setBody(body);
            return response;
        }
    }

    private static IntegrationTransaction__c transactionRecord() {
        return new IntegrationTransaction__c(IdempotencyKey__c = 'op-http-001');
    }

    private static IntegrationRequest request(String method, String path) {
        return new IntegrationRequest(
            IntegrationTestDataFactory.INTEGRATION_KEY, 'CREATE', method, path
        );
    }

    @IsTest
    static void buildsTheEndpointFromTheNamedCredential() {
        CapturingMock mock = new CapturingMock();
        Test.setMock(HttpCalloutMock.class, mock);
        IntegrationConfigService.Config config = IntegrationTestDataFactory.config(true);

        IntegrationHttpClient.send(request('POST', 'resource'), transactionRecord(), config);

        System.assertEquals(
            'callout:Test_Named_Credential/resource',
            mock.captured.getEndpoint(),
            'A path without a leading slash still produces one.'
        );
    }

    @IsTest
    static void aPathThatAlreadyHasItsSlashIsNotDoubled() {
        CapturingMock mock = new CapturingMock();
        Test.setMock(HttpCalloutMock.class, mock);

        IntegrationHttpClient.send(
            request('POST', '/resource'), transactionRecord(), IntegrationTestDataFactory.config(true)
        );

        System.assertEquals('callout:Test_Named_Credential/resource', mock.captured.getEndpoint());
    }

    @IsTest
    static void aBlankPathCallsTheCredentialItself() {
        CapturingMock mock = new CapturingMock();
        Test.setMock(HttpCalloutMock.class, mock);

        IntegrationHttpClient.send(
            request('POST', null), transactionRecord(), IntegrationTestDataFactory.config(true)
        );

        System.assertEquals('callout:Test_Named_Credential', mock.captured.getEndpoint());
    }

    @IsTest
    static void theMethodDefaultsToPostAndIsUppercased() {
        CapturingMock mock = new CapturingMock();
        Test.setMock(HttpCalloutMock.class, mock);
        IntegrationConfigService.Config config = IntegrationTestDataFactory.config(true);

        IntegrationHttpClient.send(request(null, '/a'), transactionRecord(), config);
        System.assertEquals('POST', mock.captured.getMethod(), 'No method means POST.');

        IntegrationHttpClient.send(request('patch', '/a'), transactionRecord(), config);
        System.assertEquals('PATCH', mock.captured.getMethod());
    }

    @IsTest
    static void handlersCannotOverrideTheAuthenticationHeaders() {
        CapturingMock mock = new CapturingMock();
        Test.setMock(HttpCalloutMock.class, mock);

        IntegrationRequest request = request('POST', '/a')
            .withHeader('Authorization', 'Bearer stolen')
            .withHeader('proxy-authorization', 'Basic stolen')
            .withHeader('HOST', 'evil.example.com')
            .withHeader('X-Correlation-Id', 'abc-123');

        IntegrationHttpClient.send(request, transactionRecord(), IntegrationTestDataFactory.config(true));

        System.assertEquals(
            null,
            mock.captured.getHeader('Authorization'),
            'The Named Credential is the authentication boundary and a handler cannot cross it.'
        );
        System.assertEquals(null, mock.captured.getHeader('proxy-authorization'));
        System.assertEquals(null, mock.captured.getHeader('HOST'), 'Matching is case-insensitive.');
        System.assertEquals(
            'abc-123',
            mock.captured.getHeader('X-Correlation-Id'),
            'Every other header the handler sets is passed through.'
        );
    }

    @IsTest
    static void theIdempotencyHeaderIsSentOnlyWhenTheRemoteHonoursIt() {
        CapturingMock mock = new CapturingMock();
        Test.setMock(HttpCalloutMock.class, mock);

        IntegrationHttpClient.send(
            request('POST', '/a'), transactionRecord(), IntegrationTestDataFactory.config(true)
        );
        System.assertEquals(
            'op-http-001',
            mock.captured.getHeader('Idempotency-Key'),
            'The transaction key is what the remote side deduplicates on.'
        );

        IntegrationHttpClient.send(
            request('POST', '/a'), transactionRecord(), IntegrationTestDataFactory.config(false)
        );
        System.assertEquals(
            null,
            mock.captured.getHeader('Idempotency-Key'),
            'Claiming idempotency the remote does not implement would be worse than not claiming it.'
        );
    }

    @IsTest
    static void theIdempotencyHeaderNameIsConfigurable() {
        CapturingMock mock = new CapturingMock();
        Test.setMock(HttpCalloutMock.class, mock);
        IntegrationConfigService.Config config = IntegrationTestDataFactory.config(true);
        config.idempotencyHeader = 'X-Request-Id';
        IntegrationConfigService.setTestConfig(config);

        IntegrationHttpClient.send(request('POST', '/a'), transactionRecord(), config);

        System.assertEquals('op-http-001', mock.captured.getHeader('X-Request-Id'));
        System.assertEquals(null, mock.captured.getHeader('Idempotency-Key'));
    }

    @IsTest
    static void theBodyIsSentOnlyWhenThereIsOne() {
        CapturingMock mock = new CapturingMock();
        Test.setMock(HttpCalloutMock.class, mock);
        IntegrationConfigService.Config config = IntegrationTestDataFactory.config(true);

        IntegrationHttpClient.send(
            request('POST', '/a').withBody('{"id":1}'), transactionRecord(), config
        );
        System.assertEquals('{"id":1}', mock.captured.getBody());

        IntegrationHttpClient.send(request('GET', '/a'), transactionRecord(), config);
        System.assertEquals('', mock.captured.getBody(), 'No body set means none sent.');
    }

    @IsTest
    static void theResponseCarriesWhatClassificationNeeds() {
        CapturingMock mock = new CapturingMock();
        Test.setMock(HttpCalloutMock.class, mock);
        IntegrationConfigService.Config config = IntegrationTestDataFactory.config(true);

        mock.statusCode = 201;
        IntegrationResponse created = IntegrationHttpClient.send(
            request('POST', '/a'), transactionRecord(), config
        );
        System.assertEquals(201, created.statusCode);
        System.assertEquals('{"ok":true}', created.body);
        System.assertEquals(true, created.successful, 'Any 2xx is a success.');
        System.assertEquals(false, created.retryable);

        mock.statusCode = 503;
        IntegrationResponse unavailable = IntegrationHttpClient.send(
            request('POST', '/a'), transactionRecord(), config
        );
        System.assertEquals(false, unavailable.successful);
        System.assertEquals(true, unavailable.retryable, '503 is in the configured list.');

        mock.statusCode = 422;
        IntegrationResponse rejected = IntegrationHttpClient.send(
            request('POST', '/a'), transactionRecord(), config
        );
        System.assertEquals(false, rejected.successful);
        System.assertEquals(false, rejected.retryable, '422 is not.');
    }

    @IsTest
    static void aMissingNamedCredentialFailsBeforeAnythingIsSent() {
        CapturingMock mock = new CapturingMock();
        Test.setMock(HttpCalloutMock.class, mock);
        IntegrationConfigService.Config config = IntegrationTestDataFactory.config(true);
        config.namedCredential = null;

        String message;
        try {
            IntegrationHttpClient.send(request('POST', '/a'), transactionRecord(), config);
        } catch (IntegrationHttpClient.IntegrationHttpException ex) {
            message = ex.getMessage();
        }

        System.assertNotEquals(null, message, 'Without a credential there is no endpoint to call.');
        System.assert(message.contains('NamedCredential__c'), message);
        System.assertEquals(null, mock.captured, 'And nothing was sent.');
    }
}
