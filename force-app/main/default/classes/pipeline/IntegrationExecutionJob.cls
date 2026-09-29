public class IntegrationExecutionJob implements Queueable, Database.AllowsCallouts {
    private Id transactionId;
    private Integer expectedAttempt;

    public IntegrationExecutionJob(Id transactionId, Integer expectedAttempt) {
        this.transactionId = transactionId;
        this.expectedAttempt = expectedAttempt;
    }

    // What the job decided to persist. Kept in one place because the values are
    // interdependent: a RETRY without a date is never picked up again, and a
    // status without an attempt leaves no audit trail.
    private class Outcome {
        IntegrationRequest request;
        IntegrationResponse response;
        String attemptResult;
        String status;
        String disposition;
        String errorCode;
        String errorMessage;
        Datetime nextRetryAt;
        String externalId;

        Outcome(String attemptResult, String status, String disposition,
                String errorCode, String errorMessage) {
            this.attemptResult = attemptResult;
            this.status = status;
            this.disposition = disposition;
            this.errorCode = errorCode;
            this.errorMessage = errorMessage;
        }
    }

    public void execute(QueueableContext context) {
        IntegrationTransaction__c transactionRecord = [
            SELECT Id, IntegrationKey__c, Operation__c, IdempotencyKey__c,
                   Status__c, AttemptCount__c, ObjectApiName__c, RecordId__c,
                   LeaseExpiresAt__c
            FROM IntegrationTransaction__c
            WHERE Id = :transactionId
            LIMIT 1
        ];

        // Fencing. Only the worker that claimed this attempt may act on it: a job
        // that was superseded while queued would otherwise execute a second
        // callout for work someone else already owns.
        if (!owns(transactionRecord)) {
            return;
        }

        Datetime startedAt = System.now();
        Long startedMs = startedAt.getTime();

        // Everything from here to the callout can only fail before a request
        // leaves the org. Those failures are ERROR, never UNKNOWN: we know the
        // remote side has not acted, so there is nothing to reconcile. They are
        // also terminal, because none of them is fixed by trying again.
        IntegrationConfigService.Config config;
        try {
            config = IntegrationConfigService.get(transactionRecord.IntegrationKey__c);
        } catch (Exception ex) {
            persist(transactionRecord, null, startedAt, startedMs,
                terminal(IntegrationConstants.ERROR_CONFIGURATION, ex.getMessage()));
            return;
        }

        if (transactionRecord.LeaseExpiresAt__c != null &&
            transactionRecord.LeaseExpiresAt__c <= System.now()) {
            // The lease ran out before we sent anything, so there is no remote
            // side effect and retrying does not need remote idempotency.
            Boolean retry = IntegrationRetryPolicy.canRetry(transactionRecord, config);
            Outcome expired = new Outcome(
                IntegrationConstants.RESULT_ERROR,
                IntegrationConstants.STATUS_ERROR,
                retry ? IntegrationConstants.DISPOSITION_RETRY : IntegrationConstants.DISPOSITION_TERMINAL,
                IntegrationConstants.ERROR_LEASE_EXPIRED,
                'The processing lease expired before the callout was made. Nothing was sent.'
            );
            if (retry) {
                expired.nextRetryAt = IntegrationRetryPolicy.nextRetryAt(transactionRecord, config);
            }
            persist(transactionRecord, config, startedAt, startedMs, expired);
            return;
        }

        IntegrationOperationHandler handler;
        try {
            handler = IntegrationHandlerFactory.create(config.handlerClass);
        } catch (Exception ex) {
            persist(transactionRecord, config, startedAt, startedMs,
                terminal(IntegrationConstants.ERROR_HANDLER, ex.getMessage()));
            return;
        }

        // buildRequest must be read-only: any DML it performs would make the
        // callout below fail with "uncommitted work pending". The savepoint lets
        // us undo that write and refuse the attempt, instead of leaving half of
        // the handler's work committed and the remote side never called.
        Savepoint beforeBuild = Database.setSavepoint();
        Integer dmlBefore = Limits.getDmlStatements();
        IntegrationRequest request;
        Boolean buildFailed = false;
        String buildError;

        try {
            request = handler.buildRequest(transactionRecord);
        } catch (Exception ex) {
            buildFailed = true;
            buildError = ex.getMessage();
        }

        Boolean handlerWroteData = Limits.getDmlStatements() > dmlBefore;
        if (handlerWroteData) {
            Database.rollback(beforeBuild);
        }
        Database.releaseSavepoint(beforeBuild);

        if (buildFailed) {
            persist(transactionRecord, config, startedAt, startedMs,
                terminal(IntegrationConstants.ERROR_REQUEST_BUILD, buildError));
            return;
        }

        if (handlerWroteData) {
            Outcome dirty = terminal(
                IntegrationConstants.ERROR_HANDLER_DML,
                'buildRequest() performed DML. It must be read-only: the write has been ' +
                'rolled back and no request was sent.'
            );
            dirty.request = request;
            persist(transactionRecord, config, startedAt, startedMs, dirty);
            return;
        }

        if (request == null) {
            persist(transactionRecord, config, startedAt, startedMs,
                terminal(IntegrationConstants.ERROR_INVALID_REQUEST,
                    'Integration handler returned a null request.'));
            return;
        }

        IntegrationResponse response;
        try {
            response = IntegrationHttpClient.send(request, transactionRecord, config);
        } catch (CalloutException ex) {
            // The request may have reached the remote side. Never ERROR.
            Outcome uncertain = new Outcome(
                IntegrationConstants.RESULT_UNKNOWN,
                IntegrationConstants.STATUS_UNKNOWN,
                IntegrationConstants.DISPOSITION_RECONCILE,
                IntegrationConstants.ERROR_CALLOUT_EXCEPTION,
                ex.getMessage()
            );
            uncertain.request = request;
            persistAfterCallout(transactionRecord, config, startedAt, startedMs, uncertain);
            return;
        } catch (Exception ex) {
            Outcome clientError = terminal(IntegrationConstants.ERROR_CLIENT, ex.getMessage());
            clientError.request = request;
            persist(transactionRecord, config, startedAt, startedMs, clientError);
            return;
        }

        persistAfterCallout(
            transactionRecord, config, startedAt, startedMs,
            classify(transactionRecord, config, handler, request, response, startedAt, startedMs)
        );
    }

    private Outcome classify(
        IntegrationTransaction__c transactionRecord,
        IntegrationConfigService.Config config,
        IntegrationOperationHandler handler,
        IntegrationRequest request,
        IntegrationResponse response,
        Datetime startedAt,
        Long startedMs
    ) {
        Outcome outcome;

        if (response.successful) {
            Savepoint beforeHandling = Database.setSavepoint();
            try {
                handler.handleSuccess(transactionRecord, response);
                outcome = new Outcome(
                    IntegrationConstants.RESULT_SUCCESS,
                    IntegrationConstants.STATUS_SUCCESS,
                    IntegrationConstants.DISPOSITION_NONE,
                    null,
                    null
                );
                outcome.externalId = handler.extractExternalId(response);
            } catch (Exception ex) {
                // The remote side did the work; only the local bookkeeping failed.
                Database.rollback(beforeHandling);
                outcome = new Outcome(
                    IntegrationConstants.RESULT_UNKNOWN,
                    IntegrationConstants.STATUS_UNKNOWN,
                    IntegrationConstants.DISPOSITION_RECONCILE,
                    IntegrationConstants.ERROR_POST_PROCESSING,
                    ex.getMessage()
                );
            }
        } else if (!response.retryable) {
            outcome = new Outcome(
                IntegrationConstants.RESULT_ERROR,
                IntegrationConstants.STATUS_ERROR,
                IntegrationConstants.DISPOSITION_TERMINAL,
                'HTTP_' + response.statusCode,
                'Non-success HTTP response.'
            );
        } else if (!config.idempotencyEnabled) {
            // Retrying without remote idempotency could duplicate the operation.
            outcome = new Outcome(
                IntegrationConstants.RESULT_UNKNOWN,
                IntegrationConstants.STATUS_UNKNOWN,
                IntegrationConstants.DISPOSITION_RECONCILE,
                'HTTP_' + response.statusCode,
                'Potentially retryable response but remote idempotency is disabled.'
            );
        } else if (!IntegrationRetryPolicy.canRetry(transactionRecord, config)) {
            outcome = new Outcome(
                IntegrationConstants.RESULT_UNKNOWN,
                IntegrationConstants.STATUS_UNKNOWN,
                IntegrationConstants.DISPOSITION_TERMINAL,
                IntegrationConstants.ERROR_RETRIES_EXHAUSTED,
                'Retryable HTTP response ' + response.statusCode + ' but no retries are left.'
            );
        } else {
            outcome = new Outcome(
                IntegrationConstants.RESULT_ERROR,
                IntegrationConstants.STATUS_ERROR,
                IntegrationConstants.DISPOSITION_RETRY,
                'HTTP_' + response.statusCode,
                'Retryable HTTP response.'
            );
            outcome.nextRetryAt = IntegrationRetryPolicy.nextRetryAt(transactionRecord, config);
        }

        outcome.request = request;
        outcome.response = response;
        return outcome;
    }

    private Outcome terminal(String errorCode, String errorMessage) {
        return new Outcome(
            IntegrationConstants.RESULT_ERROR,
            IntegrationConstants.STATUS_ERROR,
            IntegrationConstants.DISPOSITION_MANUAL,
            errorCode,
            errorMessage
        );
    }

    private Boolean owns(IntegrationTransaction__c transactionRecord) {
        if (transactionRecord.Status__c != IntegrationConstants.STATUS_PROCESSING) {
            return false;
        }
        // No null check on expectedAttempt: the only constructor requires it and
        // claim() never leaves AttemptCount__c null, so it cannot be null here.
        // If it somehow were, comparing it below stands the worker down, which is
        // the safe direction anyway.
        Integer current = transactionRecord.AttemptCount__c == null
            ? 0
            : transactionRecord.AttemptCount__c.intValue();
        return current == expectedAttempt;
    }

    // Re-check ownership before writing anything the callout produced. A worker
    // whose lease expired mid-flight has been replaced: its result is recorded as
    // an attempt so the callout is not lost, but the transaction belongs to
    // someone else now and must not be touched.
    private void persistAfterCallout(
        IntegrationTransaction__c transactionRecord,
        IntegrationConfigService.Config config,
        Datetime startedAt,
        Long startedMs,
        Outcome outcome
    ) {
        IntegrationTransaction__c current = [
            SELECT Id, Status__c, AttemptCount__c
            FROM IntegrationTransaction__c
            WHERE Id = :transactionId
            LIMIT 1
            FOR UPDATE
        ];

        if (owns(current)) {
            persist(transactionRecord, config, startedAt, startedMs, outcome);
            return;
        }

        IntegrationAttemptService.record(
            transactionRecord, outcome.request, outcome.response, startedAt,
            System.now().getTime() - startedMs,
            IntegrationConstants.RESULT_UNKNOWN,
            IntegrationConstants.ERROR_SUPERSEDED,
            'This worker was superseded while its callout was in flight. ' +
            'Outcome not applied to the transaction: ' +
            (outcome.errorCode == null ? outcome.status : outcome.errorCode),
            config
        );
    }

    // Single exit point: an attempt is always recorded and the transaction always
    // ends with a disposition, so no path can leave a record in PROCESSING.
    private void persist(
        IntegrationTransaction__c transactionRecord,
        IntegrationConfigService.Config config,
        Datetime startedAt,
        Long startedMs,
        Outcome outcome
    ) {
        IntegrationAttemptService.record(
            transactionRecord, outcome.request, outcome.response, startedAt,
            System.now().getTime() - startedMs,
            outcome.attemptResult, outcome.errorCode, outcome.errorMessage, config
        );

        if (outcome.status == IntegrationConstants.STATUS_SUCCESS) {
            IntegrationTransactionService.markSuccess(transactionRecord.Id, outcome.externalId);
        } else if (outcome.status == IntegrationConstants.STATUS_UNKNOWN) {
            IntegrationTransactionService.markUnknown(
                transactionRecord.Id, outcome.errorCode, outcome.errorMessage, outcome.disposition
            );
        } else {
            IntegrationTransactionService.markError(
                transactionRecord.Id, outcome.errorCode, outcome.errorMessage,
                outcome.nextRetryAt, outcome.disposition
            );
        }
    }
}
