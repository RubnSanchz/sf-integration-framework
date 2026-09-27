public class IntegrationExecutionJob implements Queueable, Database.AllowsCallouts {
    private Id transactionId;

    public IntegrationExecutionJob(Id transactionId) {
        this.transactionId = transactionId;
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

        if (transactionRecord.Status__c != IntegrationConstants.STATUS_PROCESSING) {
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
            failBeforeCallout(
                transactionRecord, null, null, startedAt, startedMs,
                IntegrationConstants.ERROR_CONFIGURATION, ex.getMessage()
            );
            return;
        }

        IntegrationOperationHandler handler;
        try {
            handler = IntegrationHandlerFactory.create(config.handlerClass);
        } catch (Exception ex) {
            failBeforeCallout(
                transactionRecord, config, null, startedAt, startedMs,
                IntegrationConstants.ERROR_HANDLER, ex.getMessage()
            );
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
            failBeforeCallout(
                transactionRecord, config, null, startedAt, startedMs,
                IntegrationConstants.ERROR_REQUEST_BUILD, buildError
            );
            return;
        }

        if (handlerWroteData) {
            failBeforeCallout(
                transactionRecord, config, request, startedAt, startedMs,
                IntegrationConstants.ERROR_HANDLER_DML,
                'buildRequest() performed DML. It must be read-only: the write has been ' +
                'rolled back and no request was sent.'
            );
            return;
        }

        if (request == null) {
            failBeforeCallout(
                transactionRecord, config, null, startedAt, startedMs,
                IntegrationConstants.ERROR_INVALID_REQUEST,
                'Integration handler returned a null request.'
            );
            return;
        }

        IntegrationResponse response;
        try {
            response = IntegrationHttpClient.send(request, transactionRecord, config);
        } catch (CalloutException ex) {
            // The request may have reached the remote side. Never ERROR.
            finish(
                transactionRecord, request, null, startedAt, startedMs, config,
                IntegrationConstants.RESULT_UNKNOWN, IntegrationConstants.STATUS_UNKNOWN,
                IntegrationConstants.DISPOSITION_RECONCILE,
                IntegrationConstants.ERROR_CALLOUT_EXCEPTION, ex.getMessage(), null
            );
            return;
        } catch (Exception ex) {
            failBeforeCallout(
                transactionRecord, config, request, startedAt, startedMs,
                IntegrationConstants.ERROR_CLIENT, ex.getMessage()
            );
            return;
        }

        Long duration = System.now().getTime() - startedMs;

        if (response.successful) {
            Savepoint beforeHandling = Database.setSavepoint();
            try {
                handler.handleSuccess(transactionRecord, response);
                IntegrationAttemptService.record(
                    transactionRecord, request, response, startedAt, duration,
                    IntegrationConstants.RESULT_SUCCESS, null, null, config
                );
                IntegrationTransactionService.markSuccess(
                    transactionRecord.Id,
                    handler.extractExternalId(response)
                );
            } catch (Exception ex) {
                // The remote side did the work; only the local bookkeeping failed.
                Database.rollback(beforeHandling);
                finish(
                    transactionRecord, request, response, startedAt, startedMs, config,
                    IntegrationConstants.RESULT_UNKNOWN, IntegrationConstants.STATUS_UNKNOWN,
                    IntegrationConstants.DISPOSITION_RECONCILE,
                    IntegrationConstants.ERROR_POST_PROCESSING, ex.getMessage(), null
                );
            }
            return;
        }

        String httpCode = 'HTTP_' + response.statusCode;

        if (!response.retryable) {
            finish(
                transactionRecord, request, response, startedAt, startedMs, config,
                IntegrationConstants.RESULT_ERROR, IntegrationConstants.STATUS_ERROR,
                IntegrationConstants.DISPOSITION_TERMINAL,
                httpCode, 'Non-success HTTP response.', null
            );
            return;
        }

        if (!config.idempotencyEnabled) {
            // Retrying without remote idempotency could duplicate the operation.
            finish(
                transactionRecord, request, response, startedAt, startedMs, config,
                IntegrationConstants.RESULT_UNKNOWN, IntegrationConstants.STATUS_UNKNOWN,
                IntegrationConstants.DISPOSITION_RECONCILE,
                httpCode, 'Potentially retryable response but remote idempotency is disabled.', null
            );
            return;
        }

        if (!IntegrationRetryPolicy.canRetry(transactionRecord, config)) {
            finish(
                transactionRecord, request, response, startedAt, startedMs, config,
                IntegrationConstants.RESULT_UNKNOWN, IntegrationConstants.STATUS_UNKNOWN,
                IntegrationConstants.DISPOSITION_TERMINAL,
                IntegrationConstants.ERROR_RETRIES_EXHAUSTED,
                'Retryable HTTP response ' + response.statusCode + ' but no retries are left.',
                null
            );
            return;
        }

        finish(
            transactionRecord, request, response, startedAt, startedMs, config,
            IntegrationConstants.RESULT_ERROR, IntegrationConstants.STATUS_ERROR,
            IntegrationConstants.DISPOSITION_RETRY,
            httpCode, 'Retryable HTTP response.',
            IntegrationRetryPolicy.nextRetryAt(transactionRecord, config)
        );
    }

    private void failBeforeCallout(
        IntegrationTransaction__c transactionRecord,
        IntegrationConfigService.Config config,
        IntegrationRequest request,
        Datetime startedAt,
        Long startedMs,
        String errorCode,
        String errorMessage
    ) {
        finish(
            transactionRecord, request, null, startedAt, startedMs, config,
            IntegrationConstants.RESULT_ERROR, IntegrationConstants.STATUS_ERROR,
            IntegrationConstants.DISPOSITION_MANUAL,
            errorCode, errorMessage, null
        );
    }

    // Single exit point: an attempt is always recorded and the transaction always
    // ends with a disposition, so no path can leave a record in PROCESSING.
    private void finish(
        IntegrationTransaction__c transactionRecord,
        IntegrationRequest request,
        IntegrationResponse response,
        Datetime startedAt,
        Long startedMs,
        IntegrationConfigService.Config config,
        String attemptResult,
        String status,
        String disposition,
        String errorCode,
        String errorMessage,
        Datetime nextRetryAt
    ) {
        IntegrationAttemptService.record(
            transactionRecord, request, response, startedAt,
            System.now().getTime() - startedMs,
            attemptResult, errorCode, errorMessage, config
        );

        if (status == IntegrationConstants.STATUS_UNKNOWN) {
            IntegrationTransactionService.markUnknown(
                transactionRecord.Id, errorCode, errorMessage, disposition
            );
        } else {
            IntegrationTransactionService.markError(
                transactionRecord.Id, errorCode, errorMessage, nextRetryAt, disposition
            );
        }
    }
}
