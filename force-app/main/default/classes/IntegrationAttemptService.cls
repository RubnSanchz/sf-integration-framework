public inherited sharing class IntegrationAttemptService {
    public static IntegrationAttempt__c start(
        IntegrationTransaction__c transactionRecord,
        IntegrationRequest request,
        IntegrationConfigService.Config config
    ) {
        IntegrationAttempt__c attempt = new IntegrationAttempt__c(
            Transaction__c = transactionRecord.Id,
            AttemptNumber__c = transactionRecord.AttemptCount__c,
            StartedAt__c = System.now(),
            HttpMethod__c = request.method,
            EndpointAlias__c = config.namedCredential,
            RequestBody__c = config.logRequestBody
                ? IntegrationSanitizer.sanitize(request.body, config.maxPayloadChars)
                : null
        );
        insert attempt;
        return attempt;
    }

    public static void finishSuccess(
        Id attemptId,
        Integer statusCode,
        String responseBody,
        Long durationMs,
        IntegrationConfigService.Config config
    ) {
        update new IntegrationAttempt__c(
            Id = attemptId,
            FinishedAt__c = System.now(),
            HttpStatusCode__c = statusCode,
            Result__c = IntegrationConstants.RESULT_SUCCESS,
            ResponseBody__c = config.logResponseBody
                ? IntegrationSanitizer.sanitize(responseBody, config.maxPayloadChars)
                : null,
            DurationMs__c = durationMs
        );
    }

    public static void finishError(
        Id attemptId,
        String result,
        Integer statusCode,
        String errorCode,
        String errorMessage,
        String responseBody,
        Long durationMs,
        IntegrationConfigService.Config config
    ) {
        update new IntegrationAttempt__c(
            Id = attemptId,
            FinishedAt__c = System.now(),
            HttpStatusCode__c = statusCode,
            Result__c = result,
            ErrorCode__c = errorCode,
            ErrorMessage__c = IntegrationSanitizer.sanitize(errorMessage, config.maxPayloadChars),
            ResponseBody__c = config.logResponseBody
                ? IntegrationSanitizer.sanitize(responseBody, config.maxPayloadChars)
                : null,
            DurationMs__c = durationMs
        );
    }
}
