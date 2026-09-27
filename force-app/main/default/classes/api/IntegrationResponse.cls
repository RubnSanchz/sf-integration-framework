public class IntegrationResponse {
    public Integer statusCode;
    public String body;
    public Map<String, String> headers = new Map<String, String>();
    public Boolean successful;
    public Boolean retryable;
    public Boolean uncertain;
}
