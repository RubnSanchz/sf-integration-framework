# classes/tests/

- **Custom Metadata cannot be inserted in a test.** Inject configuration through the `@TestVisible` seam `IntegrationConfigService.setTestConfig(config)`, which `get()` honours only under `Test.isRunningTest()`. To test the parsing itself, build an `IntegrationDefinition__mdt` in memory and call `fromDefinition`; to test the cache, call `cached`.
- **Checkbox fields are never null on an sObject**: assigning `null` stores `false`. A record built in memory reads `false`, not the field's `defaultValue`, so set them explicitly when a test needs a realistic definition.
- Test method names are full sentences in the third person, no `test` prefix, no underscores, and they state the expected behaviour rather than the mechanics: `expiredLeaseIsRescheduledWithoutCallingOut`.
- Idempotency keys in test data are kebab-case `<scope>-<case>-<nnn>`, for example `exec-503-001`.
- `IntegrationExecutionJobTest` holds the callout infrastructure: a mock that counts calls, can throw a `CalloutException` and can steal the transaction mid-flight, plus a handler with five failure modes selected through static state, because the factory instantiates it reflectively with no arguments.
- Assert that nothing was sent when nothing should have been. The call counter on the mock is the only way to prove a pre-callout branch really stopped before the callout.
- **These tests need field access.** They do DML on `IntegrationTransaction__c` and fail with "fields being inaccessible" unless the running user has the permission set. Making them independent of that is still pending.
