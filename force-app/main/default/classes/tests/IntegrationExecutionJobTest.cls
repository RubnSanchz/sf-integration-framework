/**
 * Covers how IntegrationExecutionJob classifies what happened. The split that
 * matters: anything that fails before the request leaves the org is ERROR,
 * because the remote side cannot have acted; anything from the callout onwards
 * is UNKNOWN unless the response itself tells us otherwise.
 */
@IsTest
public class IntegrationExecutionJobTest {
    public static final String MODE_NORMAL = 'NORMAL';
    public static final String MODE_NULL_REQUEST = 'NULL_REQUEST';
    public static final String MODE_THROW_ON_BUILD = 'THROW_ON_BUILD';
    public static final String MODE_DML_ON_BUILD = 'DML_ON_BUILD';
    public static final String MODE_THROW_ON_SUCCESS = 'THROW_ON_SUCCESS';

    // The factory builds the handler reflectively with a no-argument constructor,
    // so the mode has to travel through static state.
    public static String handlerMode = MODE_NORMAL;

    public class TestHandler implements IntegrationOperationHandler {
        public IntegrationRequest buildRequest(IntegrationTransaction__c transactionRecord) {
            if (handlerMode == MODE_NULL_REQUEST) {
                return null;
            }
            if (handlerMode == MODE_THROW_ON_BUILD) {
                throw new HandlerTestException('buildRequest blew up');
            }
            if (handlerMode == MODE_DML_ON_BUILD) {
                insert newTransaction('written-by-build-request');
            }
            return new IntegrationRequest('TEST', 'CREATE', 'POST', '/resource').withBody('{}');
        }

        public String extractExternalId(IntegrationResponse response) {
            return 'EXT-1';
        }

        public void handleSuccess(IntegrationTransaction__c transactionRecord, IntegrationResponse response) {
            if (handlerMode == MODE_THROW_ON_SUCCESS) {
                throw new HandlerTestException('handleSuccess blew up');
            }
        }
    }

    public class HandlerTestException extends Exception {}

    public class Mock implements HttpCalloutMock {
        public Integer statusCode = 200;
        public String body = '{"id":"EXT-1"}';
        public Boolean failWithCalloutException = false;
        public Integer calls = 0;
        // Simulates another worker reclaiming the transaction while this
        // callout is in flight.
        public Id stealTransactionId;

        public HttpResponse respond(HttpRequest request) {
            calls++;
            if (stealTransactionId != null) {
                update new IntegrationTransaction__c(
                    Id = stealTransactionId,
                    AttemptCount__c = 99
                );
            }
            if (failWithCalloutException) {
                throw new CalloutException('Read timed out');
            }
            HttpResponse response = new HttpResponse();
            response.setStatusCode(statusCode);
            response.setBody(body);
            return response;
        }
    }

    private static IntegrationConfigService.Config configure(Boolean idempotent, String handlerClass) {
        IntegrationConfigService.Config config = new IntegrationConfigService.Config();
        config.integrationKey = 'TEST';
        config.namedCredential = 'Test_Named_Credential';
        config.handlerClass = handlerClass;
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

    private static IntegrationTransaction__c newTransaction(String key) {
        return new IntegrationTransaction__c(
            IdempotencyKey__c = key,
            IntegrationKey__c = 'TEST',
            Operation__c = 'CREATE',
            Direction__c = 'OUTBOUND',
            Status__c = IntegrationConstants.STATUS_PENDING,
            AttemptCount__c = 0
        );
    }

    // A transaction already claimed by a worker, which is what the execution job
    // expects to find.
    private static IntegrationTransaction__c processing(String key, Integer attemptCount) {
        IntegrationTransaction__c transactionRecord = newTransaction(key);
        transactionRecord.Status__c = IntegrationConstants.STATUS_PROCESSING;
        transactionRecord.AttemptCount__c = attemptCount;
        transactionRecord.ProcessingStartedAt__c = System.now();
        transactionRecord.LeaseExpiresAt__c = System.now().addSeconds(120);
        insert transactionRecord;
        return transactionRecord;
    }

    private static IntegrationTransaction__c reload(Id transactionId) {
        return [
            SELECT Status__c, Disposition__c, ErrorCode__c, ErrorMessage__c,
                   NextRetryAt__c, ExternalId__c, LeaseExpiresAt__c
            FROM IntegrationTransaction__c
            WHERE Id = :transactionId
        ];
    }

    private static List<IntegrationAttempt__c> attemptsOf(Id transactionId) {
        return [
            SELECT Result__c, ErrorCode__c, ErrorMessage__c, HttpStatusCode__c
            FROM IntegrationAttempt__c
            WHERE Transaction__c = :transactionId
        ];
    }

    private static void run(Id transactionId, Integer expectedAttempt) {
        Test.startTest();
        System.enqueueJob(new IntegrationExecutionJob(transactionId, expectedAttempt));
        Test.stopTest();
    }

    @IsTest
    static void missingConfigurationIsATerminalErrorBeforeAnyCallout() {
        Mock mock = new Mock();
        Test.setMock(HttpCalloutMock.class, mock);
        // No test config registered for this key, so get() throws.
        IntegrationTransaction__c stale = processing('exec-config-001', 1);

        run(stale.Id, 1);

        IntegrationTransaction__c stored = reload(stale.Id);
        System.assertEquals(IntegrationConstants.STATUS_ERROR, stored.Status__c);
        System.assertEquals(IntegrationConstants.DISPOSITION_MANUAL, stored.Disposition__c);
        System.assertEquals(IntegrationConstants.ERROR_CONFIGURATION, stored.ErrorCode__c);
        System.assertEquals(null, stored.NextRetryAt__c, 'A terminal failure has no retry date.');
        System.assertEquals(0, mock.calls, 'Nothing may be sent without configuration.');
        System.assertEquals(1, attemptsOf(stale.Id).size(), 'The attempt must still be recorded.');
    }

    @IsTest
    static void unresolvableHandlerIsATerminalError() {
        Mock mock = new Mock();
        Test.setMock(HttpCalloutMock.class, mock);
        configure(true, 'NoSuchHandlerClass');
        IntegrationTransaction__c stale = processing('exec-handler-001', 1);

        run(stale.Id, 1);

        IntegrationTransaction__c stored = reload(stale.Id);
        System.assertEquals(IntegrationConstants.STATUS_ERROR, stored.Status__c);
        System.assertEquals(IntegrationConstants.DISPOSITION_MANUAL, stored.Disposition__c);
        System.assertEquals(IntegrationConstants.ERROR_HANDLER, stored.ErrorCode__c);
        System.assertEquals(0, mock.calls);
        System.assertEquals(IntegrationConstants.RESULT_ERROR, attemptsOf(stale.Id)[0].Result__c);
    }

    @IsTest
    static void handlerThrowingInBuildRequestIsATerminalError() {
        Mock mock = new Mock();
        Test.setMock(HttpCalloutMock.class, mock);
        configure(true, 'IntegrationExecutionJobTest.TestHandler');
        handlerMode = MODE_THROW_ON_BUILD;
        IntegrationTransaction__c stale = processing('exec-build-001', 1);

        run(stale.Id, 1);

        IntegrationTransaction__c stored = reload(stale.Id);
        System.assertEquals(IntegrationConstants.STATUS_ERROR, stored.Status__c);
        System.assertEquals(IntegrationConstants.DISPOSITION_MANUAL, stored.Disposition__c);
        System.assertEquals(IntegrationConstants.ERROR_REQUEST_BUILD, stored.ErrorCode__c);
        System.assertEquals(0, mock.calls);
    }

    @IsTest
    static void handlerReturningNullRequestIsATerminalError() {
        Mock mock = new Mock();
        Test.setMock(HttpCalloutMock.class, mock);
        configure(true, 'IntegrationExecutionJobTest.TestHandler');
        handlerMode = MODE_NULL_REQUEST;
        IntegrationTransaction__c stale = processing('exec-null-001', 1);

        run(stale.Id, 1);

        IntegrationTransaction__c stored = reload(stale.Id);
        System.assertEquals(IntegrationConstants.STATUS_ERROR, stored.Status__c);
        System.assertEquals(IntegrationConstants.DISPOSITION_MANUAL, stored.Disposition__c);
        System.assertEquals(IntegrationConstants.ERROR_INVALID_REQUEST, stored.ErrorCode__c);
        System.assertEquals(0, mock.calls);
    }

    @IsTest
    static void handlerWritingInBuildRequestIsRolledBackAndRefused() {
        Mock mock = new Mock();
        Test.setMock(HttpCalloutMock.class, mock);
        configure(true, 'IntegrationExecutionJobTest.TestHandler');
        handlerMode = MODE_DML_ON_BUILD;
        IntegrationTransaction__c stale = processing('exec-dml-001', 1);

        run(stale.Id, 1);

        IntegrationTransaction__c stored = reload(stale.Id);
        System.assertEquals(IntegrationConstants.STATUS_ERROR, stored.Status__c);
        System.assertEquals(IntegrationConstants.DISPOSITION_MANUAL, stored.Disposition__c);
        System.assertEquals(IntegrationConstants.ERROR_HANDLER_DML, stored.ErrorCode__c);
        System.assertEquals(0, mock.calls, 'A dirty transaction must not reach the remote side.');
        System.assertEquals(
            0,
            [SELECT COUNT() FROM IntegrationTransaction__c WHERE IdempotencyKey__c = 'written-by-build-request'],
            'The write made by buildRequest must be rolled back.'
        );
    }

    @IsTest
    static void successfulCalloutCompletesTheTransaction() {
        Mock mock = new Mock();
        Test.setMock(HttpCalloutMock.class, mock);
        configure(true, 'IntegrationExecutionJobTest.TestHandler');
        handlerMode = MODE_NORMAL;
        IntegrationTransaction__c stale = processing('exec-ok-001', 1);

        run(stale.Id, 1);

        IntegrationTransaction__c stored = reload(stale.Id);
        System.assertEquals(IntegrationConstants.STATUS_SUCCESS, stored.Status__c);
        System.assertEquals(IntegrationConstants.DISPOSITION_NONE, stored.Disposition__c);
        System.assertEquals('EXT-1', stored.ExternalId__c);
        System.assertEquals(1, mock.calls);
        System.assertEquals(IntegrationConstants.RESULT_SUCCESS, attemptsOf(stale.Id)[0].Result__c);
    }

    @IsTest
    static void postProcessingFailureIsUnknownNotError() {
        Mock mock = new Mock();
        Test.setMock(HttpCalloutMock.class, mock);
        configure(true, 'IntegrationExecutionJobTest.TestHandler');
        handlerMode = MODE_THROW_ON_SUCCESS;
        IntegrationTransaction__c stale = processing('exec-post-001', 1);

        run(stale.Id, 1);

        IntegrationTransaction__c stored = reload(stale.Id);
        System.assertEquals(
            IntegrationConstants.STATUS_UNKNOWN,
            stored.Status__c,
            'The remote side did the work: this is not an ERROR.'
        );
        System.assertEquals(IntegrationConstants.DISPOSITION_RECONCILE, stored.Disposition__c);
        System.assertEquals(IntegrationConstants.ERROR_POST_PROCESSING, stored.ErrorCode__c);
        System.assertEquals(null, stored.ExternalId__c, 'The local write must have been rolled back.');
    }

    @IsTest
    static void calloutExceptionIsUnknown() {
        Mock mock = new Mock();
        mock.failWithCalloutException = true;
        Test.setMock(HttpCalloutMock.class, mock);
        configure(true, 'IntegrationExecutionJobTest.TestHandler');
        handlerMode = MODE_NORMAL;
        IntegrationTransaction__c stale = processing('exec-timeout-001', 1);

        run(stale.Id, 1);

        IntegrationTransaction__c stored = reload(stale.Id);
        System.assertEquals(IntegrationConstants.STATUS_UNKNOWN, stored.Status__c);
        System.assertEquals(IntegrationConstants.DISPOSITION_RECONCILE, stored.Disposition__c);
        System.assertEquals(IntegrationConstants.ERROR_CALLOUT_EXCEPTION, stored.ErrorCode__c);
    }

    @IsTest
    static void retryableResponseSchedulesARetry() {
        Mock mock = new Mock();
        mock.statusCode = 503;
        Test.setMock(HttpCalloutMock.class, mock);
        configure(true, 'IntegrationExecutionJobTest.TestHandler');
        handlerMode = MODE_NORMAL;
        IntegrationTransaction__c stale = processing('exec-503-001', 1);

        run(stale.Id, 1);

        IntegrationTransaction__c stored = reload(stale.Id);
        System.assertEquals(IntegrationConstants.STATUS_ERROR, stored.Status__c);
        System.assertEquals(IntegrationConstants.DISPOSITION_RETRY, stored.Disposition__c);
        System.assertEquals('HTTP_503', stored.ErrorCode__c);
        System.assertNotEquals(null, stored.NextRetryAt__c, 'RETRY always carries a date.');
    }

    @IsTest
    static void retryableResponseWithoutIdempotencyNeedsReconciliation() {
        Mock mock = new Mock();
        mock.statusCode = 503;
        Test.setMock(HttpCalloutMock.class, mock);
        configure(false, 'IntegrationExecutionJobTest.TestHandler');
        handlerMode = MODE_NORMAL;
        IntegrationTransaction__c stale = processing('exec-503-002', 1);

        run(stale.Id, 1);

        IntegrationTransaction__c stored = reload(stale.Id);
        System.assertEquals(IntegrationConstants.STATUS_UNKNOWN, stored.Status__c);
        System.assertEquals(IntegrationConstants.DISPOSITION_RECONCILE, stored.Disposition__c);
        System.assertEquals(null, stored.NextRetryAt__c);
    }

    @IsTest
    static void retryableResponseWithNoRetriesLeftIsTerminal() {
        Mock mock = new Mock();
        mock.statusCode = 503;
        Test.setMock(HttpCalloutMock.class, mock);
        configure(true, 'IntegrationExecutionJobTest.TestHandler');
        handlerMode = MODE_NORMAL;
        // maxRetries is 3 and counts retries after the first attempt, so the
        // fifth attempt has none left.
        IntegrationTransaction__c stale = processing('exec-503-003', 5);

        run(stale.Id, 5);

        IntegrationTransaction__c stored = reload(stale.Id);
        System.assertEquals(IntegrationConstants.STATUS_UNKNOWN, stored.Status__c);
        System.assertEquals(IntegrationConstants.DISPOSITION_TERMINAL, stored.Disposition__c);
        System.assertEquals(IntegrationConstants.ERROR_RETRIES_EXHAUSTED, stored.ErrorCode__c);
        System.assertEquals(null, stored.NextRetryAt__c);
    }

    @IsTest
    static void nonRetryableResponseIsTerminal() {
        Mock mock = new Mock();
        mock.statusCode = 422;
        Test.setMock(HttpCalloutMock.class, mock);
        configure(true, 'IntegrationExecutionJobTest.TestHandler');
        handlerMode = MODE_NORMAL;
        IntegrationTransaction__c stale = processing('exec-422-001', 1);

        run(stale.Id, 1);

        IntegrationTransaction__c stored = reload(stale.Id);
        System.assertEquals(IntegrationConstants.STATUS_ERROR, stored.Status__c);
        System.assertEquals(IntegrationConstants.DISPOSITION_TERMINAL, stored.Disposition__c);
        System.assertEquals('HTTP_422', stored.ErrorCode__c);
        System.assertEquals(422, attemptsOf(stale.Id)[0].HttpStatusCode__c);
    }

    @IsTest
    static void claimJobParksATransactionWithBrokenConfiguration() {
        IntegrationTransaction__c pending = newTransaction('claim-config-001');
        insert pending;

        Test.startTest();
        System.enqueueJob(new IntegrationClaimJob(pending.Id));
        Test.stopTest();

        IntegrationTransaction__c stored = reload(pending.Id);
        System.assertEquals(
            IntegrationConstants.STATUS_ERROR,
            stored.Status__c,
            'A failed claim must not leave the record PENDING for the dispatcher to retry forever.'
        );
        System.assertEquals(IntegrationConstants.DISPOSITION_MANUAL, stored.Disposition__c);
        System.assertEquals(IntegrationConstants.ERROR_CONFIGURATION, stored.ErrorCode__c);
    }
    @IsTest
    static void workerWithAStaleAttemptNumberStandsDown() {
        Mock mock = new Mock();
        Test.setMock(HttpCalloutMock.class, mock);
        configure(true, 'IntegrationExecutionJobTest.TestHandler');
        handlerMode = MODE_NORMAL;
        IntegrationTransaction__c stale = processing('exec-fence-001', 3);

        // The claim that produced this job was for attempt 2; something has
        // reclaimed the transaction since.
        run(stale.Id, 2);

        IntegrationTransaction__c stored = reload(stale.Id);
        System.assertEquals(
            IntegrationConstants.STATUS_PROCESSING,
            stored.Status__c,
            'A superseded worker must leave the transaction exactly as it found it.'
        );
        System.assertEquals(0, mock.calls, 'It must not call out either.');
        System.assertEquals(0, attemptsOf(stale.Id).size());
    }

    @IsTest
    static void expiredLeaseIsRescheduledWithoutCallingOut() {
        Mock mock = new Mock();
        Test.setMock(HttpCalloutMock.class, mock);
        configure(true, 'IntegrationExecutionJobTest.TestHandler');
        handlerMode = MODE_NORMAL;
        IntegrationTransaction__c stale = processing('exec-lease-001', 1);
        stale.LeaseExpiresAt__c = System.now().addSeconds(-1);
        update stale;

        run(stale.Id, 1);

        IntegrationTransaction__c stored = reload(stale.Id);
        System.assertEquals(IntegrationConstants.STATUS_ERROR, stored.Status__c);
        System.assertEquals(
            IntegrationConstants.DISPOSITION_RETRY,
            stored.Disposition__c,
            'Nothing was sent, so this retry does not need remote idempotency.'
        );
        System.assertEquals(IntegrationConstants.ERROR_LEASE_EXPIRED, stored.ErrorCode__c);
        System.assertNotEquals(null, stored.NextRetryAt__c);
        System.assertEquals(0, mock.calls, 'An expired lease must never call out.');
        System.assertEquals(
            IntegrationConstants.ERROR_LEASE_EXPIRED,
            attemptsOf(stale.Id)[0].ErrorCode__c
        );
    }

    @IsTest
    static void expiredLeaseWithNoRetriesLeftIsTerminal() {
        Mock mock = new Mock();
        Test.setMock(HttpCalloutMock.class, mock);
        configure(true, 'IntegrationExecutionJobTest.TestHandler');
        handlerMode = MODE_NORMAL;
        IntegrationTransaction__c stale = processing('exec-lease-002', 5);
        stale.LeaseExpiresAt__c = System.now().addSeconds(-1);
        update stale;

        run(stale.Id, 5);

        IntegrationTransaction__c stored = reload(stale.Id);
        System.assertEquals(IntegrationConstants.STATUS_ERROR, stored.Status__c);
        System.assertEquals(IntegrationConstants.DISPOSITION_TERMINAL, stored.Disposition__c);
        System.assertEquals(null, stored.NextRetryAt__c);
        System.assertEquals(0, mock.calls);
    }

    @IsTest
    static void supersededWorkerRecordsItsCalloutWithoutTouchingTheTransaction() {
        Mock mock = new Mock();
        Test.setMock(HttpCalloutMock.class, mock);
        configure(true, 'IntegrationExecutionJobTest.TestHandler');
        handlerMode = MODE_NORMAL;
        IntegrationTransaction__c stale = processing('exec-superseded-001', 1);
        mock.stealTransactionId = stale.Id;

        run(stale.Id, 1);

        IntegrationTransaction__c stored = [
            SELECT Status__c, Disposition__c, AttemptCount__c, ExternalId__c
            FROM IntegrationTransaction__c
            WHERE Id = :stale.Id
        ];
        System.assertEquals(1, mock.calls, 'The callout did happen.');
        System.assertEquals(
            IntegrationConstants.STATUS_PROCESSING,
            stored.Status__c,
            'The transaction now belongs to another worker and must not be written.'
        );
        System.assertEquals(99, stored.AttemptCount__c);
        System.assertEquals(null, stored.ExternalId__c);

        List<IntegrationAttempt__c> attempts = attemptsOf(stale.Id);
        System.assertEquals(1, attempts.size(), 'The callout must not be lost.');
        System.assertEquals(IntegrationConstants.RESULT_UNKNOWN, attempts[0].Result__c);
        System.assertEquals(IntegrationConstants.ERROR_SUPERSEDED, attempts[0].ErrorCode__c);
        System.assertEquals(200, attempts[0].HttpStatusCode__c, 'With the real status code.');
    }
}
