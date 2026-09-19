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

        IntegrationConfigService.Config config =
            IntegrationConfigService.get(transactionRecord.IntegrationKey__c);
        IntegrationOperationHandler handler =
            IntegrationHandlerFactory.create(config.handlerClass);
        IntegrationRequest request = handler.buildRequest(transactionRecord);

        if (request == null) {
            IntegrationTransactionService.markError(
                transactionRecord.Id,
                'INVALID_REQUEST',
                'Integration handler returned a null request.',
                null
            );
            return;
        }

        Datetime startedAt = System.now();
        Long startedMs = startedAt.getTime();
        IntegrationResponse response;

        try {
            response = IntegrationHttpClient.send(request, transactionRecord, config);
        } catch (CalloutException ex) {
            Long duration = System.now().getTime() - startedMs;
            IntegrationAttemptService.record(
                transactionRecord, request, null, startedAt, duration,
                IntegrationConstants.RESULT_UNKNOWN, 'CALLOUT_EXCEPTION', ex.getMessage(), config
            );
            IntegrationTransactionService.markUnknown(
                transactionRecord.Id,
                'CALLOUT_EXCEPTION',
                ex.getMessage()
            );
            return;
        } catch (Exception ex) {
            Long duration = System.now().getTime() - startedMs;
            IntegrationAttemptService.record(
                transactionRecord, request, null, startedAt, duration,
                IntegrationConstants.RESULT_ERROR, 'CLIENT_ERROR', ex.getMessage(), config
            );
            IntegrationTransactionService.markError(
                transactionRecord.Id,
                'CLIENT_ERROR',
                ex.getMessage(),
                null
            );
            return;
        }

        Long duration = System.now().getTime() - startedMs;

        if (response.successful) {
            Savepoint successSavepoint = Database.setSavepoint();
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
                Database.rollback(successSavepoint);
                IntegrationAttemptService.record(
                    transactionRecord, request, response, startedAt, duration,
                    IntegrationConstants.RESULT_UNKNOWN,
                    'POST_PROCESSING_ERROR',
                    ex.getMessage(),
                    config
                );
                IntegrationTransactionService.markUnknown(
                    transactionRecord.Id,
                    'POST_PROCESSING_ERROR',
                    ex.getMessage()
                );
            }
            return;
        }

        if (response.retryable && config.idempotencyEnabled &&
            IntegrationRetryPolicy.canRetry(transactionRecord, config)) {
            IntegrationAttemptService.record(
                transactionRecord, request, response, startedAt, duration,
                IntegrationConstants.RESULT_ERROR,
                'HTTP_' + response.statusCode,
                'Retryable HTTP response.',
                config
            );
            IntegrationTransactionService.markError(
                transactionRecord.Id,
                'HTTP_' + response.statusCode,
                'Retryable HTTP response.',
                IntegrationRetryPolicy.nextRetryAt(transactionRecord, config)
            );
        } else if (response.retryable) {
            IntegrationAttemptService.record(
                transactionRecord, request, response, startedAt, duration,
                IntegrationConstants.RESULT_UNKNOWN,
                'HTTP_' + response.statusCode,
                'Potentially retryable response but remote idempotency is disabled.',
                config
            );
            IntegrationTransactionService.markUnknown(
                transactionRecord.Id,
                'HTTP_' + response.statusCode,
                'Potentially retryable response but remote idempotency is disabled.'
            );
        } else {
            IntegrationAttemptService.record(
                transactionRecord, request, response, startedAt, duration,
                IntegrationConstants.RESULT_ERROR,
                'HTTP_' + response.statusCode,
                'Non-success HTTP response.',
                config
            );
            IntegrationTransactionService.markError(
                transactionRecord.Id,
                'HTTP_' + response.statusCode,
                'Non-success HTTP response.',
                null
            );
        }
    }
}
