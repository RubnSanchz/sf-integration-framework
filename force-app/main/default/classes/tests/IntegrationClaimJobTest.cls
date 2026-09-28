@IsTest
private class IntegrationClaimJobTest {
    @TestSetup
    static void makeFrameworkUser() {
        IntegrationTestDataFactory.createFrameworkUser();
    }

    // Called directly rather than enqueued: a test transaction allows only one
    // queueable, and this job chains a second one. Calling it inline leaves that
    // single slot for the execution job it chains, which is the wiring worth
    // checking.
    private static void claim(Id transactionId) {
        new IntegrationClaimJob(transactionId).execute(null);
    }

    @IsTest
    static void claimingChainsTheExecutionJobWithTheAttemptNumber() {
        IntegrationTestDataFactory.config(true, IntegrationTestDataFactory.HANDLER_CLASS);
        IntegrationExecutionJobTest.handlerMode = IntegrationExecutionJobTest.MODE_NORMAL;
        Test.setMock(HttpCalloutMock.class, new IntegrationExecutionJobTest.Mock());

        System.runAs(IntegrationTestDataFactory.frameworkUser()) {
            IntegrationTransaction__c pending = IntegrationTestDataFactory.pending('claim-ok-001');

            Test.startTest();
            claim(pending.Id);

            IntegrationTransaction__c claimed = IntegrationTestDataFactory.reload(pending.Id);
            System.assertEquals(IntegrationConstants.STATUS_PROCESSING, claimed.Status__c);
            System.assertEquals(1, claimed.AttemptCount__c);
            System.assertNotEquals(null, claimed.LeaseExpiresAt__c);
            System.assertEquals(
                IntegrationConstants.DISPOSITION_NONE,
                claimed.Disposition__c,
                'While a worker owns it there is no pending decision.'
            );
            Test.stopTest();

            // The chained execution job ran. It could only have got this far by
            // finding the attempt number it was handed still on the record.
            System.assertEquals(
                IntegrationConstants.STATUS_SUCCESS,
                IntegrationTestDataFactory.reload(pending.Id).Status__c,
                'The claim job has to hand the execution job a matching attempt number.'
            );
        }
    }

    @IsTest
    static void aRecordThatNoLongerExistsIsLetGoQuietly() {
        IntegrationTestDataFactory.config(true);

        System.runAs(IntegrationTestDataFactory.frameworkUser()) {
            IntegrationTransaction__c pending = IntegrationTestDataFactory.pending('claim-gone-001');
            Id goneId = pending.Id;
            delete pending;

            Test.startTest();
            claim(goneId);
            Test.stopTest();

            System.assertEquals(
                0,
                [SELECT COUNT() FROM IntegrationAttempt__c],
                'Nothing to claim means nothing to record, and no exception either.'
            );
        }
    }

    @IsTest
    static void brokenConfigurationParksTheTransaction() {
        // No test config registered for this key, so get() throws.
        System.runAs(IntegrationTestDataFactory.frameworkUser()) {
            IntegrationTransaction__c pending = IntegrationTestDataFactory.pending('claim-config-001');

            Test.startTest();
            claim(pending.Id);
            Test.stopTest();

            IntegrationTransaction__c stored = IntegrationTestDataFactory.reload(pending.Id);
            System.assertEquals(
                IntegrationConstants.STATUS_ERROR,
                stored.Status__c,
                'Leaving it PENDING would have the dispatcher pick it up on every run, forever.'
            );
            System.assertEquals(IntegrationConstants.DISPOSITION_MANUAL, stored.Disposition__c);
            System.assertEquals(IntegrationConstants.ERROR_CONFIGURATION, stored.ErrorCode__c);
            System.assertEquals(null, stored.NextRetryAt__c);
        }
    }

    @IsTest
    static void aFailedClaimIsRescheduledRatherThanParked() {
        IntegrationConfigService.Config config = IntegrationTestDataFactory.config(true);

        System.runAs(IntegrationTestDataFactory.frameworkUser()) {
            IntegrationTransaction__c pending = IntegrationTestDataFactory.pending('claim-fail-001');
            // AttemptCount__c has precision 9, so incrementing from the maximum
            // overflows the field and claim() fails on its update. That stands in
            // for the case this branch actually exists for: two claim jobs racing
            // for the same row.
            pending.AttemptCount__c = 999999999;
            update pending;

            Test.startTest();
            claim(pending.Id);
            Test.stopTest();

            IntegrationTransaction__c stored = IntegrationTestDataFactory.reload(pending.Id);
            System.assertEquals(IntegrationConstants.STATUS_ERROR, stored.Status__c);
            System.assertEquals(
                IntegrationConstants.DISPOSITION_RETRY,
                stored.Disposition__c,
                'Nothing was sent, so trying again is always safe.'
            );
            System.assertEquals(IntegrationConstants.ERROR_CLAIM, stored.ErrorCode__c);
            System.assertNotEquals(
                null,
                stored.NextRetryAt__c,
                'And it must carry a date, or nothing will ever pick it up.'
            );
        }
    }
}
