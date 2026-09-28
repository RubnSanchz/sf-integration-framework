@IsTest
private class IntegrationTransactionServiceTest {
    @TestSetup
    static void makeFrameworkUser() {
        IntegrationTestDataFactory.createFrameworkUser();
    }

    @IsTest
    static void createsAndClaimsLogicalTransaction() {
        System.runAs(IntegrationTestDataFactory.frameworkUser()) {
            IntegrationTestDataFactory.config(true);
            IntegrationRequest request = new IntegrationRequest('TEST', 'CREATE', 'POST', '/resource');
            request.idempotencyKey = 'op-001';

            IntegrationTransaction__c created = IntegrationTransactionService.create(request);
            System.assertEquals(IntegrationConstants.STATUS_PENDING, created.Status__c);
            System.assertEquals('op-001', created.IdempotencyKey__c);

            IntegrationTransaction__c claimed = IntegrationTransactionService.claim(created.Id, 120);
            System.assertNotEquals(null, claimed);
            System.assertEquals(IntegrationConstants.STATUS_PROCESSING, claimed.Status__c);
            System.assertEquals(1, claimed.AttemptCount__c);
            System.assertNotEquals(null, claimed.LeaseExpiresAt__c);

            IntegrationTransaction__c secondClaim = IntegrationTransactionService.claim(created.Id, 120);
            System.assertEquals(null, secondClaim, 'A PROCESSING transaction must not be claimed twice.');

            IntegrationTransaction__c stored = [
                SELECT Disposition__c FROM IntegrationTransaction__c WHERE Id = :created.Id
            ];
            System.assertEquals(
                IntegrationConstants.DISPOSITION_NONE,
                stored.Disposition__c,
                'A transaction starts with nothing for the system to do about it.'
            );
        }
    }

    @IsTest
    static void transactionErrorMessagesAreSanitized() {
        System.runAs(IntegrationTestDataFactory.frameworkUser()) {
            IntegrationTestDataFactory.config(true);
            IntegrationRequest request = new IntegrationRequest('TEST', 'CREATE', 'POST', '/resource');
            request.idempotencyKey = 'op-sanitize-001';
            IntegrationTransaction__c created = IntegrationTransactionService.create(request);

            IntegrationTransactionService.markError(
                created.Id,
                'CLIENT_ERROR',
                'Callout to /v1/orders?access_token=abc123 failed',
                null,
                IntegrationConstants.DISPOSITION_MANUAL
            );
            IntegrationTransaction__c stored = [
                SELECT ErrorMessage__c FROM IntegrationTransaction__c WHERE Id = :created.Id
            ];
            System.assert(!stored.ErrorMessage__c.contains('abc123'), stored.ErrorMessage__c);
            System.assert(stored.ErrorMessage__c.contains('[REDACTED]'), stored.ErrorMessage__c);

            IntegrationTransactionService.markUnknown(
                created.Id,
                'CALLOUT_EXCEPTION',
                'Read timed out using Bearer abc123def',
                IntegrationConstants.DISPOSITION_RECONCILE
            );
            stored = [
                SELECT ErrorMessage__c FROM IntegrationTransaction__c WHERE Id = :created.Id
            ];
            System.assert(!stored.ErrorMessage__c.contains('abc123def'), stored.ErrorMessage__c);
            System.assert(stored.ErrorMessage__c.contains('[REDACTED]'), stored.ErrorMessage__c);
        }
    }

    @IsTest
    static void aDueRetryIsClaimedWhateverItsStatus() {
        System.runAs(IntegrationTestDataFactory.frameworkUser()) {
            IntegrationTestDataFactory.config(true);
            IntegrationTransaction__c due = new IntegrationTransaction__c(
                IdempotencyKey__c = 'due-001',
                IntegrationKey__c = 'TEST',
                Operation__c = 'CREATE',
                Direction__c = 'OUTBOUND',
                Status__c = IntegrationConstants.STATUS_UNKNOWN,
                Disposition__c = IntegrationConstants.DISPOSITION_RETRY,
                NextRetryAt__c = System.now().addMinutes(-1),
                AttemptCount__c = 1
            );
            insert due;

            IntegrationTransaction__c claimed = IntegrationTransactionService.claim(due.Id, 120);
            System.assertNotEquals(null, claimed, 'UNKNOWN + RETRY is work the system intends to run again.');
            System.assertEquals(IntegrationConstants.STATUS_PROCESSING, claimed.Status__c);
            System.assertEquals(2, claimed.AttemptCount__c);
            System.assertEquals(
                IntegrationConstants.DISPOSITION_NONE,
                IntegrationTestDataFactory.reload(due.Id).Disposition__c,
                'While a worker owns it there is no pending decision.'
            );
        }
    }

    @IsTest
    static void aParkedTransactionIsNeverPickedUpAutomatically() {
        System.runAs(IntegrationTestDataFactory.frameworkUser()) {
            IntegrationTestDataFactory.config(true);
            IntegrationTransaction__c parked = new IntegrationTransaction__c(
                IdempotencyKey__c = 'manual-001',
                IntegrationKey__c = 'TEST',
                Operation__c = 'CREATE',
                Direction__c = 'OUTBOUND',
                Status__c = IntegrationConstants.STATUS_ERROR,
                Disposition__c = IntegrationConstants.DISPOSITION_MANUAL,
                AttemptCount__c = 1
            );
            insert parked;

            System.assertEquals(null, IntegrationTransactionService.claim(parked.Id, 120));

            IntegrationRecoveryScheduler.recoverSafeUnknowns();
            System.assertEquals(
                IntegrationConstants.DISPOSITION_MANUAL,
                IntegrationTestDataFactory.reload(parked.Id).Disposition__c,
                'Only an administrator takes it out of MANUAL.'
            );
        }
    }
}
