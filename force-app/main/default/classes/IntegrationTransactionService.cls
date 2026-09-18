public inherited sharing class IntegrationTransactionService {
    public static IntegrationTransaction__c create(IntegrationRequest request) {
        validate(request);
        IntegrationConfigService.get(request.integrationKey);

        IntegrationTransaction__c transactionRecord = new IntegrationTransaction__c(
            IdempotencyKey__c = String.isBlank(request.idempotencyKey) ? generateOperationKey() : request.idempotencyKey,
            IntegrationKey__c = request.integrationKey,
            Operation__c = request.operation,
            Direction__c = 'OUTBOUND',
            Status__c = IntegrationConstants.STATUS_PENDING,
            ObjectApiName__c = request.objectApiName,
            RecordId__c = request.recordId == null ? null : String.valueOf(request.recordId),
            AttemptCount__c = 0
        );
        insert transactionRecord;
        return transactionRecord;
    }

    public static IntegrationTransaction__c claim(Id transactionId, Integer leaseSeconds) {
        IntegrationTransaction__c transactionRecord = [
            SELECT Id, Status__c, AttemptCount__c, LeaseExpiresAt__c, NextRetryAt__c,
                   IntegrationKey__c, IdempotencyKey__c, Operation__c,
                   ObjectApiName__c, RecordId__c
            FROM IntegrationTransaction__c
            WHERE Id = :transactionId
            LIMIT 1
            FOR UPDATE
        ];

        Boolean pending = transactionRecord.Status__c == IntegrationConstants.STATUS_PENDING;
        Boolean retryDue = transactionRecord.Status__c == IntegrationConstants.STATUS_ERROR &&
            (transactionRecord.NextRetryAt__c == null || transactionRecord.NextRetryAt__c <= System.now());

        if (!pending && !retryDue) {
            return null;
        }

        Datetime nowValue = System.now();
        Integer effectiveLease = leaseSeconds == null || leaseSeconds <= 0 ? 60 : leaseSeconds;
        transactionRecord.Status__c = IntegrationConstants.STATUS_PROCESSING;
        transactionRecord.ProcessingStartedAt__c = nowValue;
        transactionRecord.LeaseExpiresAt__c = nowValue.addSeconds(effectiveLease);
        transactionRecord.LastAttemptAt__c = nowValue;
        transactionRecord.AttemptCount__c =
            (transactionRecord.AttemptCount__c == null ? 0 : transactionRecord.AttemptCount__c) + 1;
        transactionRecord.NextRetryAt__c = null;
        transactionRecord.ErrorCode__c = null;
        transactionRecord.ErrorMessage__c = null;
        update transactionRecord;
        return transactionRecord;
    }

    public static void markSuccess(Id transactionId, String externalId) {
        update new IntegrationTransaction__c(
            Id = transactionId,
            Status__c = IntegrationConstants.STATUS_SUCCESS,
            ExternalId__c = externalId,
            CompletedAt__c = System.now(),
            LeaseExpiresAt__c = null,
            NextRetryAt__c = null,
            ErrorCode__c = null,
            ErrorMessage__c = null
        );
    }

    public static void markError(Id transactionId, String code, String message, Datetime nextRetryAt) {
        update new IntegrationTransaction__c(
            Id = transactionId,
            Status__c = IntegrationConstants.STATUS_ERROR,
            LeaseExpiresAt__c = null,
            NextRetryAt__c = nextRetryAt,
            ErrorCode__c = code,
            ErrorMessage__c = message
        );
    }

    public static void markUnknown(Id transactionId, String code, String message) {
        update new IntegrationTransaction__c(
            Id = transactionId,
            Status__c = IntegrationConstants.STATUS_UNKNOWN,
            LeaseExpiresAt__c = null,
            NextRetryAt__c = null,
            ErrorCode__c = code,
            ErrorMessage__c = message
        );
    }

    public static void resetToPending(Id transactionId) {
        update new IntegrationTransaction__c(
            Id = transactionId,
            Status__c = IntegrationConstants.STATUS_PENDING,
            LeaseExpiresAt__c = null,
            NextRetryAt__c = null
        );
    }

    @TestVisible
    private static String generateOperationKey() {
        Blob seed = Blob.valueOf(
            String.valueOf(System.now().getTime()) + ':' +
            String.valueOf(Crypto.getRandomInteger()) + ':' +
            String.valueOf(UserInfo.getOrganizationId())
        );
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', seed));
    }

    private static void validate(IntegrationRequest request) {
        if (request == null ||
            String.isBlank(request.integrationKey) ||
            String.isBlank(request.operation)) {
            throw new IntegrationTransactionException('integrationKey and operation are required.');
        }
    }

    public class IntegrationTransactionException extends Exception {}
}
