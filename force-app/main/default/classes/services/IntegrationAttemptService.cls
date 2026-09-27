public inherited sharing class IntegrationAttemptService {
    public static IntegrationAttempt__c record(
        IntegrationTransaction__c transactionRecord,
        IntegrationRequest request,
        IntegrationResponse response,
        Datetime startedAt,
        Long durationMs,
        String result,
        String errorCode,
        String errorMessage,
        IntegrationConfigService.Config config
    ) {
        // config is null when the failure is that the configuration itself could
        // not be resolved. The attempt still has to be recorded.
        Integer maxChars = config == null ? null : config.maxPayloadChars;
        Boolean logRequest = config != null && config.logRequestBody;
        Boolean logResponse = config != null && config.logResponseBody;

        IntegrationAttempt__c attempt = new IntegrationAttempt__c(
            Transaction__c = transactionRecord.Id,
            AttemptNumber__c = transactionRecord.AttemptCount__c,
            StartedAt__c = startedAt,
            FinishedAt__c = System.now(),
            HttpMethod__c = request == null ? null : request.method,
            EndpointAlias__c = config == null ? null : config.namedCredential,
            HttpStatusCode__c = response == null ? null : response.statusCode,
            Result__c = result,
            ErrorCode__c = errorCode,
            ErrorMessage__c = IntegrationSanitizer.sanitize(errorMessage, maxChars),
            RequestBody__c = logRequest && request != null
                ? IntegrationSanitizer.sanitize(request.body, maxChars)
                : null,
            ResponseBody__c = logResponse && response != null
                ? IntegrationSanitizer.sanitize(response.body, maxChars)
                : null,
            DurationMs__c = durationMs
        );
        insert attempt;
        return attempt;
    }
}
