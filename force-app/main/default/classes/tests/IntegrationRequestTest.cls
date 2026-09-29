@IsTest
private class IntegrationRequestTest {
    private static Id fakeTransactionId() {
        // A synthetic id of the right shape, so forRecord can be exercised
        // without inserting anything.
        return Id.valueOf(
            IntegrationTransaction__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001'
        );
    }

    @IsTest
    static void theConstructorSetsWhatIdentifiesTheOperation() {
        IntegrationRequest request = new IntegrationRequest('KEY', 'CREATE', 'POST', '/orders');

        System.assertEquals('KEY', request.integrationKey);
        System.assertEquals('CREATE', request.operation);
        System.assertEquals('POST', request.method);
        System.assertEquals('/orders', request.path);
        System.assertEquals(true, request.headers.isEmpty());
    }

    @IsTest
    static void theBuildersReturnTheSameInstance() {
        IntegrationRequest request = new IntegrationRequest('KEY', 'CREATE', 'POST', '/orders');

        IntegrationRequest chained = request
            .withBody('{"id":1}')
            .withIdempotencyKey('op-001')
            .withHeader('X-Correlation-Id', 'abc');

        System.assertEquals(
            true,
            request === chained,
            'The builders mutate and return the same request, they do not copy.'
        );
        System.assertEquals('{"id":1}', request.body);
        System.assertEquals('op-001', request.idempotencyKey);
        System.assertEquals('abc', request.headers.get('X-Correlation-Id'));
    }

    @IsTest
    static void forRecordTakesBothTheIdAndTheObjectName() {
        IntegrationRequest request = new IntegrationRequest('KEY', 'CREATE', 'POST', '/orders')
            .forRecord(new IntegrationTransaction__c(Id = fakeTransactionId()));

        System.assertEquals(fakeTransactionId(), request.recordId);
        System.assertEquals(
            'IntegrationTransaction__c',
            request.objectApiName,
            'The object name comes from the record, so a handler cannot mistype it.'
        );
    }

    @IsTest
    static void forRecordIgnoresNull() {
        IntegrationRequest request = new IntegrationRequest('KEY', 'CREATE', 'POST', '/orders')
            .forRecord(null);

        System.assertEquals(null, request.recordId);
        System.assertEquals(null, request.objectApiName);
    }

    @IsTest
    static void headersAccumulateAndTheLastOneWins() {
        IntegrationRequest request = new IntegrationRequest('KEY', 'CREATE', 'POST', '/orders')
            .withHeader('A', '1')
            .withHeader('B', '2')
            .withHeader('A', '3');

        System.assertEquals(2, request.headers.size());
        System.assertEquals('3', request.headers.get('A'));
    }
}
