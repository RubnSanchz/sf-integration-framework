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
        IntegrationAttempt__c attempt = new IntegrationAttempt__c(
            Transaction__c = transactionRecord.Id,
            AttemptNumber__c = transactionRecord.AttemptCount__c,
            StartedAt__c = startedAt,
            FinishedAt__c = System.now(),
            HttpMethod__c = request == null ? null : request.method,
            EndpointAlias__c = config.namedCredential,
            HttpStatusCode__c = response == null ? null : response.statusCode,
            Result__c = result,
            ErrorCode__c = errorCode,
            ErrorMessage__c = IntegrationSanitizer.sanitize(errorMessage, config.maxPayloadChars),
            RequestBody__c = config.logRequestBody && request != null
                ? IntegrationSanitizer.sanitize(request.body, config.maxPayloadChars)
                : null,
            ResponseBody__c = config.logResponseBody && response != null
                ? IntegrationSanitizer.sanitize(response.body, config.maxPayloadChars)
                : null,
            DurationMs__c = durationMs
        );
        insert attempt;
        return attempt;
    }
}
