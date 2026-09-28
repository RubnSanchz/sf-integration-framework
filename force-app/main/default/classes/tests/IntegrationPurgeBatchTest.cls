@IsTest
private class IntegrationPurgeBatchTest {
    @TestSetup
    static void makeFrameworkUser() {
        IntegrationTestDataFactory.createFrameworkUser();
    }

    private static IntegrationTransaction__c completed(String key, Integer daysAgo) {
        IntegrationTransaction__c record = IntegrationTestDataFactory.newPending(key);
        record.Status__c = IntegrationConstants.STATUS_SUCCESS;
        record.Disposition__c = IntegrationConstants.DISPOSITION_NONE;
        record.AttemptCount__c = 1;
        insert record;
        // CompletedAt__c is written by markSuccess, so it has to be set after the
        // insert to survive the picklist default on Disposition__c.
        record.CompletedAt__c = System.now().addDays(-daysAgo);
        update record;
        return record;
    }

    private static Boolean stillThere(Id transactionId) {
        return [SELECT COUNT() FROM IntegrationTransaction__c WHERE Id = :transactionId] == 1;
    }

    private static void runPurge() {
        Test.startTest();
        Database.executeBatch(new IntegrationPurgeBatch(), 200);
        Test.stopTest();
    }

    @IsTest
    static void deletesSuccessfulTransactionsPastTheirRetention() {
        IntegrationTestDataFactory.config(true);
        System.runAs(IntegrationTestDataFactory.frameworkUser()) {
            IntegrationTransaction__c old = completed('purge-old-001', 40);
            IntegrationTransaction__c recent = completed('purge-recent-001', 5);

            runPurge();

            System.assertEquals(false, stillThere(old.Id), '40 days old with a 30 day retention.');
            System.assertEquals(true, stillThere(recent.Id), '5 days old is well inside it.');
        }
    }

    @IsTest
    static void attemptsGoWithTheirTransaction() {
        IntegrationTestDataFactory.config(true);
        System.runAs(IntegrationTestDataFactory.frameworkUser()) {
            IntegrationTransaction__c old = completed('purge-old-002', 40);
            insert new IntegrationAttempt__c(
                Transaction__c = old.Id,
                AttemptNumber__c = 1,
                StartedAt__c = System.now().addDays(-40),
                FinishedAt__c = System.now().addDays(-40),
                Result__c = IntegrationConstants.RESULT_SUCCESS
            );

            runPurge();

            System.assertEquals(
                0,
                [SELECT COUNT() FROM IntegrationAttempt__c WHERE Transaction__c = :old.Id],
                'Attempts follow the master-detail cascade.'
            );
        }
    }

    @IsTest
    static void retentionIsPerIntegration() {
        // A longer retention than the record's age: the record is inside the
        // query locator's window but must survive its own integration's rule.
        IntegrationConfigService.Config config = IntegrationTestDataFactory.config(true);
        config.retentionDays = 90;
        IntegrationConfigService.setTestConfig(config);

        System.runAs(IntegrationTestDataFactory.frameworkUser()) {
            IntegrationTransaction__c old = completed('purge-long-001', 40);

            runPurge();

            System.assertEquals(
                true,
                stillThere(old.Id),
                '40 days old, but this integration keeps 90.'
            );
        }
    }

    @IsTest
    static void neverTouchesAnythingButSuccess() {
        IntegrationTestDataFactory.config(true);
        System.runAs(IntegrationTestDataFactory.frameworkUser()) {
            IntegrationTransaction__c failed = completed('purge-error-001', 40);
            failed.Status__c = IntegrationConstants.STATUS_ERROR;
            failed.Disposition__c = IntegrationConstants.DISPOSITION_TERMINAL;
            update failed;

            IntegrationTransaction__c needsAPerson = completed('purge-manual-001', 40);
            needsAPerson.Disposition__c = IntegrationConstants.DISPOSITION_MANUAL;
            update needsAPerson;

            IntegrationTransaction__c uncertain = completed('purge-unknown-001', 40);
            uncertain.Status__c = IntegrationConstants.STATUS_UNKNOWN;
            uncertain.Disposition__c = IntegrationConstants.DISPOSITION_RECONCILE;
            update uncertain;

            runPurge();

            System.assertEquals(true, stillThere(failed.Id), 'A failure is evidence, not clutter.');
            System.assertEquals(true, stillThere(needsAPerson.Id), 'Someone still owes this an answer.');
            System.assertEquals(true, stillThere(uncertain.Id), 'The remote side may have acted.');
        }
    }

    @IsTest
    static void aTransactionWithNoDefinitionIsLeftAlone() {
        IntegrationTestDataFactory.config(true);
        System.runAs(IntegrationTestDataFactory.frameworkUser()) {
            IntegrationTransaction__c orphan = completed('purge-orphan-001', 40);
            orphan.IntegrationKey__c = 'NO_SUCH_INTEGRATION';
            update orphan;

            runPurge();

            System.assertEquals(
                true,
                stillThere(orphan.Id),
                'A definition that no longer resolves is not a licence to delete its history.'
            );
        }
    }

    @IsTest
    static void schedulingItRunsTheBatch() {
        IntegrationTestDataFactory.config(true);
        System.runAs(IntegrationTestDataFactory.frameworkUser()) {
            IntegrationTransaction__c old = completed('purge-sched-001', 40);

            Test.startTest();
            System.schedule('SIF Purge Test', '0 0 3 1 1 ? 2100', new IntegrationPurgeBatch());
            Test.stopTest();

            System.assertEquals(
                true,
                stillThere(old.Id),
                'The schedule is set for 2100, so nothing runs yet.'
            );
        }
    }
}
