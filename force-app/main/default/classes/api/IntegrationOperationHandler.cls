public interface IntegrationOperationHandler {
    IntegrationRequest buildRequest(IntegrationTransaction__c transactionRecord);
    String extractExternalId(IntegrationResponse response);
    void handleSuccess(IntegrationTransaction__c transactionRecord, IntegrationResponse response);
}
