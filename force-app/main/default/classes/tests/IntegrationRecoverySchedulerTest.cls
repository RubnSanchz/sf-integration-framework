@IsTest
private class IntegrationRecoverySchedulerTest {
    @TestSetup
    static void makeFrameworkUser() {
        IntegrationTestDataFactory.createFrameworkUser();
    }

    @IsTest
    static void staleLeaseWithIdempotencyIsScheduledForAnotherAttempt() {
        System.runAs(IntegrationTestDataFactory.frameworkUser()) {
            IntegrationTestDataFactory.config(true);
            IntegrationTransaction__c stale = IntegrationTestDataFactory.staleProcessing('stale-001', 1);

            new IntegrationRecoveryScheduler().execute(null);

            IntegrationTransaction__c recovered = IntegrationTestDataFactory.reload(stale.Id);
            System.assertEquals(
                IntegrationConstants.STATUS_UNKNOWN,
                recovered.Status__c,
                'The worker died mid-flight, so the outcome is genuinely unknown: it does not go back to PENDING.'
            );
            System.assertEquals(IntegrationConstants.DISPOSITION_RETRY, recovered.Disposition__c);
            System.assertEquals(IntegrationConstants.ERROR_STALE_LEASE, recovered.ErrorCode__c);
            System.assertNotEquals(null, recovered.NextRetryAt__c, 'RETRY always carries a date.');
            System.assertEquals(null, recovered.LeaseExpiresAt__c);
            System.assertEquals(
                1,
                [SELECT COUNT() FROM IntegrationAttempt__c WHERE Transaction__c = :stale.Id],
                'The expired lease is recorded as a fact.'
            );
        }
    }

    // RECONCILE means "uncertain, not yet evaluated". The recovery scheduler is
    // the evaluator: it turns each one into RETRY or, when nothing automatic can
    // resolve it, into MANUAL. Both steps run in a single scheduled execution.
    @IsTest
    static void staleLeaseWithoutIdempotencyEndsUpNeedingAPerson() {
        System.runAs(IntegrationTestDataFactory.frameworkUser()) {
            IntegrationTestDataFactory.config(false);
            IntegrationTransaction__c stale = IntegrationTestDataFactory.staleProcessing('stale-002', 1);

            IntegrationRecoveryScheduler.recoverStaleProcessing();

            IntegrationTransaction__c afterFirstStep = IntegrationTestDataFactory.reload(stale.Id);
            System.assertEquals(IntegrationConstants.STATUS_UNKNOWN, afterFirstStep.Status__c);
            System.assertEquals(
                IntegrationConstants.DISPOSITION_RECONCILE,
                afterFirstStep.Disposition__c,
                'Sending again could duplicate the operation, so it is not a RETRY.'
            );
            System.assertEquals(null, afterFirstStep.NextRetryAt__c);

            IntegrationRecoveryScheduler.recoverSafeUnknowns();

            IntegrationTransaction__c afterSecondStep = IntegrationTestDataFactory.reload(stale.Id);
            System.assertEquals(
                IntegrationConstants.DISPOSITION_MANUAL,
                afterSecondStep.Disposition__c,
                'Without idempotency no automatic path exists, so it must reach a person.'
            );
            System.assertEquals(
                IntegrationConstants.STATUS_UNKNOWN,
                afterSecondStep.Status__c,
                'The status still records that the remote side may have acted.'
            );
        }
    }

    @IsTest
    static void reconcilableUnknownIsRequeuedOnlyWhileRetriesRemain() {
        System.runAs(IntegrationTestDataFactory.frameworkUser()) {
            IntegrationTestDataFactory.config(true);
            IntegrationTransaction__c pendingReview = new IntegrationTransaction__c(
                IdempotencyKey__c = 'unknown-001',
                IntegrationKey__c = 'TEST',
                Operation__c = 'CREATE',
                Direction__c = 'OUTBOUND',
                Status__c = IntegrationConstants.STATUS_UNKNOWN,
                Disposition__c = IntegrationConstants.DISPOSITION_RECONCILE,
                AttemptCount__c = 1
            );
            IntegrationTransaction__c exhausted = new IntegrationTransaction__c(
                IdempotencyKey__c = 'unknown-002',
                IntegrationKey__c = 'TEST',
                Operation__c = 'CREATE',
                Direction__c = 'OUTBOUND',
                Status__c = IntegrationConstants.STATUS_UNKNOWN,
                Disposition__c = IntegrationConstants.DISPOSITION_RECONCILE,
                AttemptCount__c = 9
            );
            insert new List<IntegrationTransaction__c>{pendingReview, exhausted};

            IntegrationRecoveryScheduler.recoverSafeUnknowns();

            System.assertEquals(
                IntegrationConstants.DISPOSITION_RETRY,
                IntegrationTestDataFactory.reload(pendingReview.Id).Disposition__c
            );
            System.assertNotEquals(null, IntegrationTestDataFactory.reload(pendingReview.Id).NextRetryAt__c);
            System.assertEquals(
                IntegrationConstants.DISPOSITION_MANUAL,
                IntegrationTestDataFactory.reload(exhausted.Id).Disposition__c,
                'With no retries left it must leave the reconciliation window, or it crowds out newer work.'
            );
        }
    }

    @IsTest
    static void recoveryKeepsGoingWhenOneDefinitionIsBroken() {
        System.runAs(IntegrationTestDataFactory.frameworkUser()) {
            IntegrationTestDataFactory.config(true);
            IntegrationTransaction__c healthy = IntegrationTestDataFactory.staleProcessing('stale-003', 1);
            IntegrationTransaction__c broken = IntegrationTestDataFactory.staleProcessing('stale-004', 1);
            broken.IntegrationKey__c = 'NO_SUCH_INTEGRATION';
            update broken;

            IntegrationRecoveryScheduler.recoverStaleProcessing();

            System.assertEquals(
                IntegrationConstants.DISPOSITION_RETRY,
                IntegrationTestDataFactory.reload(healthy.Id).Disposition__c,
                'One broken definition must not stop the rest of the run.'
            );
            IntegrationTransaction__c parked = IntegrationTestDataFactory.reload(broken.Id);
            System.assertEquals(IntegrationConstants.DISPOSITION_MANUAL, parked.Disposition__c);
            System.assertEquals(IntegrationConstants.ERROR_CONFIGURATION, parked.ErrorCode__c);
        }
    }

    @IsTest
    static void aRetryIsNotDispatchedBeforeItsDate() {
        System.runAs(IntegrationTestDataFactory.frameworkUser()) {
            IntegrationTestDataFactory.config(true);
            IntegrationTransaction__c later = new IntegrationTransaction__c(
                IdempotencyKey__c = 'future-001',
                IntegrationKey__c = 'TEST',
                Operation__c = 'CREATE',
                Direction__c = 'OUTBOUND',
                Status__c = IntegrationConstants.STATUS_ERROR,
                Disposition__c = IntegrationConstants.DISPOSITION_RETRY,
                NextRetryAt__c = System.now().addMinutes(30),
                AttemptCount__c = 1
            );
            insert later;

            System.assertEquals(
                null,
                IntegrationTransactionService.claim(later.Id, 120),
                'A retry scheduled for later must not be claimed now.'
            );

            Test.startTest();
            new IntegrationDispatchScheduler().execute(null);
            Test.stopTest();

            System.assertEquals(
                IntegrationConstants.STATUS_ERROR,
                IntegrationTestDataFactory.reload(later.Id).Status__c,
                'And it must not be dispatched either.'
            );
        }
    }
    @IsTest
    static void aReconcilableRecordWithNoDefinitionIsParkedForAPerson() {
        IntegrationTestDataFactory.config(true);
        System.runAs(IntegrationTestDataFactory.frameworkUser()) {
            IntegrationTransaction__c orphan = IntegrationTestDataFactory.withDisposition(
                'recover-orphan-001',
                IntegrationConstants.STATUS_UNKNOWN,
                IntegrationConstants.DISPOSITION_RECONCILE,
                1,
                null
            );
            orphan.IntegrationKey__c = 'NO_SUCH_INTEGRATION';
            update orphan;

            IntegrationRecoveryScheduler.recoverSafeUnknowns();

            IntegrationTransaction__c stored = IntegrationTestDataFactory.reload(orphan.Id);
            System.assertEquals(
                IntegrationConstants.DISPOSITION_MANUAL,
                stored.Disposition__c,
                'Nothing automatic can evaluate it, so it has to leave the window.'
            );
            System.assertEquals(IntegrationConstants.ERROR_CONFIGURATION, stored.ErrorCode__c);
        }
    }

}
