public class IntegrationHttpClient {
    public static IntegrationResponse send(
        IntegrationRequest request,
        IntegrationTransaction__c transactionRecord,
        IntegrationConfigService.Config config
    ) {
        if (String.isBlank(config.namedCredential)) {
            throw new IntegrationHttpException('NamedCredential__c is required for ' + config.integrationKey);
        }

        HttpRequest httpRequest = new HttpRequest();
        httpRequest.setEndpoint('callout:' + config.namedCredential + normalizePath(request.path));
        httpRequest.setMethod(String.isBlank(request.method) ? 'POST' : request.method.toUpperCase());
        httpRequest.setTimeout(config.timeoutMs);

        if (request.body != null) {
            httpRequest.setBody(request.body);
        }

        for (String headerName : request.headers.keySet()) {
            if (!isForbiddenHeader(headerName)) {
                httpRequest.setHeader(headerName, request.headers.get(headerName));
            }
        }

        if (config.idempotencyEnabled) {
            httpRequest.setHeader(config.idempotencyHeader, transactionRecord.IdempotencyKey__c);
        }

        HttpResponse raw = new Http().send(httpRequest);
        IntegrationResponse response = new IntegrationResponse();
        response.statusCode = raw.getStatusCode();
        response.body = raw.getBody();
        response.successful = response.statusCode >= 200 && response.statusCode < 300;
        response.retryable = config.retryableStatusCodes.contains(response.statusCode);
        response.uncertain = false;
        return response;
    }

    private static String normalizePath(String path) {
        if (String.isBlank(path)) {
            return '';
        }
        return path.startsWith('/') ? path : '/' + path;
    }

    private static Boolean isForbiddenHeader(String name) {
        if (String.isBlank(name)) {
            return true;
        }
        String normalized = name.toLowerCase();
        return normalized == 'authorization' ||
            normalized == 'proxy-authorization' ||
            normalized == 'host';
    }

    public class IntegrationHttpException extends Exception {}
}
