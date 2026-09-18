public class IntegrationRequest {
    public String integrationKey;
    public String operation;
    public String method;
    public String path;
    public String body;
    public String objectApiName;
    public Id recordId;
    public String idempotencyKey;
    public Map<String, String> headers = new Map<String, String>();

    public IntegrationRequest(String integrationKey, String operation, String method, String path) {
        this.integrationKey = integrationKey;
        this.operation = operation;
        this.method = method;
        this.path = path;
    }

    public IntegrationRequest withBody(String value) {
        body = value;
        return this;
    }

    public IntegrationRequest forRecord(SObject recordValue) {
        if (recordValue != null) {
            recordId = recordValue.Id;
            objectApiName = recordValue.getSObjectType().getDescribe().getName();
        }
        return this;
    }

    public IntegrationRequest withIdempotencyKey(String value) {
        idempotencyKey = value;
        return this;
    }

    public IntegrationRequest withHeader(String name, String value) {
        headers.put(name, value);
        return this;
    }
}
