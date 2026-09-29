# classes/services/

`IntegrationTransactionService`, `IntegrationAttemptService`, `IntegrationConfigService`. These own the DML, and all three are `inherited sharing`: they run in the caller's sharing context, so the calling user needs the permission set.

- Every write of `Status__c` must also set `Disposition__c`. A record that is not PENDING or SUCCESS and still carries `NONE` is an impossible state.
- `Disposition__c = RETRY` must always carry a `NextRetryAt__c`, or nothing picks the record up again and it dies silently.
- Anything persisted into `ErrorMessage__c` goes through `IntegrationSanitizer.sanitize` first. Exception messages carry tokens in URLs.
- `IntegrationConfigService.get()` owns every default and validates the definition, then caches one `Config` per key for the Apex transaction, so it is cheap to call in a loop. Change defaults there, never at a call site.
- `IntegrationAttemptService.record()` tolerates a null config, because the failure being recorded may be that the configuration itself could not be resolved.
- `claim()` clears the disposition, the retry date and the error fields: while a worker owns a record there is no pending decision about it.
