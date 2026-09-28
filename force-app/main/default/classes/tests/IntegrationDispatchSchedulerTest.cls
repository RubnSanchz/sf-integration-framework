@IsTest
private class IntegrationDispatchSchedulerTest {
    @TestSetup
    static void makeFrameworkUser() {
        IntegrationTestDataFactory.createFrameworkUser();
    }

    @IsTest
    static void dueWorkIsHandedToAClaimJob() {
        // No test config for this key, so the claim job this dispatches parks the
        // record instead of chaining an execution job. A test transaction allows
        // only one queueable, so that is the only way to observe the dispatch.
        System.runAs(IntegrationTestDataFactory.frameworkUser()) {
            IntegrationTransaction__c pending = IntegrationTestDataFactory.pending('dispatch-001');

            Test.startTest();
            new IntegrationDispatchScheduler().execute(null);
            Test.stopTest();

            IntegrationTransaction__c stored = IntegrationTestDataFactory.reload(pending.Id);
            System.assertNotEquals(
                IntegrationConstants.STATUS_PENDING,
                stored.Status__c,
                'The dispatcher has to reach never-executed work, or nothing ever runs.'
            );
            System.assertEquals(IntegrationConstants.ERROR_CONFIGURATION, stored.ErrorCode__c);
        }
    }

    @IsTest
    static void workThatIsNotDueIsLeftAlone() {
        System.runAs(IntegrationTestDataFactory.frameworkUser()) {
            IntegrationTransaction__c later = IntegrationTestDataFactory.withDisposition(
                'dispatch-002',
                IntegrationConstants.STATUS_ERROR,
                IntegrationConstants.DISPOSITION_RETRY,
                1,
                System.now().addMinutes(30)
            );
            IntegrationTransaction__c parked = IntegrationTestDataFactory.withDisposition(
                'dispatch-003',
                IntegrationConstants.STATUS_ERROR,
                IntegrationConstants.DISPOSITION_MANUAL,
                1,
                null
            );

            Test.startTest();
            new IntegrationDispatchScheduler().execute(null);
            Test.stopTest();

            System.assertEquals(
                null,
                IntegrationTestDataFactory.reload(later.Id).ErrorCode__c,
                'A retry scheduled for later is not touched.'
            );
            System.assertEquals(
                null,
                IntegrationTestDataFactory.reload(parked.Id).ErrorCode__c,
                'And a parked one is never picked up automatically.'
            );
        }
    }
}
