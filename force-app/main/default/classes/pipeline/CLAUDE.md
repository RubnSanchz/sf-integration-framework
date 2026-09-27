# classes/pipeline/

The async machinery: `IntegrationClaimJob` and `IntegrationExecutionJob` (queueables), `IntegrationDispatchScheduler` and `IntegrationRecoveryScheduler` (schedulables).

- **Why two queueables:** DML followed by a callout in one Apex transaction fails with "uncommitted work pending". The claim job does only DML; the execution job does the callout first and DML afterwards. Never add DML to the execution job before the callout.
- **Fencing.** `IntegrationExecutionJob` takes the attempt number its claim reserved and acts only while `AttemptCount__c` still matches, checked on entry and again `FOR UPDATE` after the callout. Do not add a code path that writes the transaction without passing that check. A worker that lost ownership records an `UNKNOWN` / `SUPERSEDED` attempt and leaves the transaction alone.
- **Anything that fails before the request leaves the org is ERROR, never UNKNOWN.** There is nothing to reconcile when nothing was sent. Give each cause its own error code.
- **The due-work predicate is duplicated on purpose** in `IntegrationDispatchScheduler` and `IntegrationTransactionService.claim()`, and the two must stay identical: `(Status__c = PENDING AND Disposition__c = NONE) OR (Disposition__c = RETRY AND (NextRetryAt__c = null OR NextRetryAt__c <= now))`.
- **The recovery scheduler is not a second classifier.** It handles only what never reached a normal ending: expired `PROCESSING` leases and `UNKNOWN` + `RECONCILE`. It evaluates each `RECONCILE` into `RETRY` or `MANUAL` every run, which is what keeps that window draining. Both sweeps catch configuration errors per record so one broken definition cannot abort the batch.
- Schedulers write in bulk, one `update` for up to 500 records. Do not call the per-record `mark*` helpers in those loops.
