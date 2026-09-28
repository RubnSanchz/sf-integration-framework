# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Salesforce DX project (Apex + custom objects, API 67.0, no namespace) meant to ship as a 2GP Unlocked Package. All source is under `force-app/main/default`. The only tooling is the `sf` CLI: there is no `package.json`, linter config, or CI. `README.md` has the full install / package / configuration walkthrough; `docs/integration-architecture.md` and `docs/integration-security.md` explain the design decisions summarised below.

English documentation is canonical. `README.es.md` and `docs/*.es.md` are Spanish translations with no extra content: do not read them unless the task is about translations. When you edit an English doc, update its `.es.md` counterpart in the same change or tell the user it needs re-syncing. Each pair carries a `[English](x.md) | [Español](x.es.md)` bar as its first line. `CLAUDE.md` files are not translated.

## Apex layout

Classes are grouped in subfolders under `force-app/main/default/classes/`:

| Folder | What lives there |
| --- | --- |
| `api/` | What a consumer touches: `IntegrationFramework`, `IntegrationRequest`, `IntegrationResponse`, `IntegrationOperationHandler` |
| `pipeline/` | The async machinery: the two Queueables and the two Schedulables |
| `services/` | DML owners, all `inherited sharing`: transaction, attempt and config services |
| `policy/` | Pure decision logic, no DML: `IntegrationRetryPolicy` |
| `support/` | `IntegrationHttpClient`, `IntegrationSanitizer`, `IntegrationHandlerFactory`, `IntegrationConstants` |
| `tests/` | Test classes |

**The folders are a repository convention only.** Apex has no concept of folders: the metadata API flattens everything into `classes/`, so the layout never reaches an org and a subscriber who retrieves the installed package gets a flat `classes/` directory. Moving a class between these folders is not a metadata change and needs no manifest edit — `manifest/package.xml` lists member names, not paths.

Two things do depend on the paths: `--source-dir` arguments must include the subfolder, and `sf project retrieve start` into this project keeps each file where it already is (verified). A blanket retrieve is not content-neutral, though: it strips the trailing newline from every class and rewrites the permission set from the org's own copy, so prefer deploying over retrieving here.

## Commands

Every command needs an authenticated org. Scratch org bootstrap:

```bash
sf org login web --alias my-devhub --set-default-dev-hub
sf org create scratch --definition-file config/project-scratch-def.json --alias sif-scratch --duration-days 7
```

Deploy and test against it:

```bash
sf project deploy start --target-org sif-scratch                                   # all source
sf project deploy start --target-org sif-scratch --source-dir force-app/main/default/classes/support/IntegrationHttpClient.cls
sf apex run test --target-org sif-scratch --test-level RunLocalTests --wait 20
sf apex run test --target-org sif-scratch --class-names IntegrationCoreTest --code-coverage --wait 10
sf apex run test --target-org sif-scratch --tests IntegrationCoreTest.sanitizerRedactsSecretsAndTruncatesPayloads --wait 10
```

Manifest-based validation (deploying without the package) and package versioning:

```bash
sf project deploy validate --manifest manifest/package.xml --target-org <org> --test-level RunLocalTests --wait 30
sf package version create --package sf-integration-framework --installation-key-bypass --code-coverage --wait 20 --target-dev-hub my-devhub
```

Package versions need 75% org-wide Apex coverage to be promotable. The package alias/ID that `sf package create` writes into `sfdx-project.json` must be committed.

## Keeping metadata in sync (easy to forget)

- `manifest/package.xml` is hand-maintained. Add every new Apex class, object, or permission set to it.
- `SF_Integration_Framework_Admin.permissionset-meta.xml` lists `fieldPermissions` per custom field. New fields on `IntegrationTransaction__c` / `IntegrationAttempt__c` must be added there, **except required and master-detail fields**: their FLS is implicit and the deploy fails with "You cannot deploy to a required field".
- Inside the permission set, repeated elements must be contiguous and in XSD order (`description`, `fieldPermissions`, `hasActivationRequired`, `label`, `objectPermissions`). Interleaving two `objectPermissions` blocks fails the whole deployment with "Element objectPermissions is duplicated at this location".
- Every `*.field-meta.xml` needs an explicit `<fullName>` matching its file name, or the deploy fails with "element fullName missing for a child of type CustomField".
- `IntegrationAttempt__c` is a master-detail child, so its `sharingModel` must stay `ControlledByParent`.
- Every `.cls` needs a sibling `.cls-meta.xml` (apiVersion 67.0, status Active).
- The string constants in `IntegrationConstants` must match the restricted picklists on `IntegrationTransaction__c.Status__c`, `IntegrationTransaction__c.Disposition__c` and `IntegrationAttempt__c.Result__c`. `constantsMatchTheRestrictedPicklists` enforces it.
- They are `public static final` fields, the conventional Apex form, and `final` is load-bearing: it is what stops a value that mirrors a restricted picklist being reassigned at runtime. Grouping them by family inside one class is deliberate — an Apex inner class cannot hold static members ("static can only be used on fields of a top level type"), so the only alternative is several top-level classes. `constantValuesArePinned` pins every literal.
- Named Credentials are deliberately **not** packaged; never add environment-specific credential metadata to `force-app`.

## Architecture

Transactional outbox for outbound HTTP. One `IntegrationTransaction__c` is one logical business operation with a stable, unique `IdempotencyKey__c`. One `IntegrationAttempt__c` is one physical execution attempt (audit only, never read back for retry decisions). Per-integration config comes from `IntegrationDefinition__mdt`, keyed by `DeveloperName` (the "integration key" passed from Apex).

**Status and disposition are different questions.** `Status__c` records what happened (PENDING, PROCESSING, SUCCESS, ERROR, UNKNOWN). `Disposition__c` records what the system does next (NONE, RETRY, RECONCILE, MANUAL, TERMINAL). `PENDING` means only "never executed": a transaction never returns to it, and work that will run again says so through `Disposition__c = RETRY` whatever its status. That is what lets an uncertain outcome stay UNKNOWN while still being scheduled.

Pipeline, where each arrow is a separate Apex transaction:

```
IntegrationFramework.registerAndEnqueue(request)    caller's transaction: insert PENDING tx, enqueue claim job
  -> IntegrationClaimJob (Queueable)                 SELECT ... FOR UPDATE; never-executed or due RETRY ->
                                                     PROCESSING, AttemptCount++, set lease; chain execution
                                                     job carrying the claimed attempt number
  -> IntegrationExecutionJob (Queueable + AllowsCallouts)
       fence on (PROCESSING, expectedAttempt) -> config -> lease check -> handler.buildRequest(tx)
       -> IntegrationHttpClient.send -> re-check the fence FOR UPDATE
       -> IntegrationAttemptService.record + IntegrationTransactionService.mark*
```

**Work is due** when `(Status__c = PENDING AND Disposition__c = NONE) OR (Disposition__c = RETRY AND (NextRetryAt__c = null OR NextRetryAt__c <= now))`. That predicate is duplicated in `IntegrationDispatchScheduler` and `IntegrationTransactionService.claim()` and the two must stay identical.

**Fencing:** `IntegrationExecutionJob` takes the attempt number its claim reserved and only acts while `AttemptCount__c` still matches, checked once on entry and again `FOR UPDATE` after the callout. A worker that lost ownership mid-flight records its callout as an `UNKNOWN` / `SUPERSEDED` attempt carrying the real HTTP status and leaves the transaction to its new owner. Without this, a job still queued when its lease expired would send a second request for work someone else owns.

**Why two Queueables:** DML followed by a callout in the same Apex transaction fails with "uncommitted work pending". The claim job does only DML; the execution job does the callout *first* and DML afterwards. That is also why `IntegrationOperationHandler.buildRequest()` must be read-only and why retries rebuild the request from Salesforce state instead of a persisted body.

**Outcome classification** lives entirely in `IntegrationExecutionJob`. Everything above the rule failed before a request left the org, so the remote side cannot have acted: those are always ERROR, never UNKNOWN.

| Situation | `ErrorCode__c` | Attempt `Result__c` | Tx `Status__c` | `Disposition__c` |
| --- | --- | --- | --- | --- |
| `IntegrationConfigService.get` throws | CONFIGURATION_ERROR | ERROR | ERROR | MANUAL |
| handler class missing or not implementing the interface | HANDLER_ERROR | ERROR | ERROR | MANUAL |
| `buildRequest` throws | REQUEST_BUILD_ERROR | ERROR | ERROR | MANUAL |
| `buildRequest` returns null | INVALID_REQUEST | ERROR | ERROR | MANUAL |
| `buildRequest` performed DML (rolled back, nothing sent) | HANDLER_DML | ERROR | ERROR | MANUAL |
| lease already expired, so no callout is made | LEASE_EXPIRED | ERROR | ERROR | RETRY with date, or TERMINAL |
| --- | --- | --- | --- | --- |
| 2xx and `handleSuccess` OK | — | SUCCESS | SUCCESS | NONE |
| 2xx but `handleSuccess` / `extractExternalId` throws | POST_PROCESSING_ERROR | UNKNOWN | UNKNOWN (local DML rolled back to savepoint; remote side effect already happened) | RECONCILE |
| `CalloutException` (timeout, etc.) | CALLOUT_EXCEPTION | UNKNOWN | UNKNOWN | RECONCILE |
| Retryable status AND `IdempotencyEnabled__c` AND `canRetry` | HTTP_nnn | ERROR | ERROR with `NextRetryAt__c` | RETRY |
| Retryable status but idempotency disabled | HTTP_nnn | UNKNOWN | UNKNOWN | RECONCILE |
| Retryable status, idempotent, but no retries left | RETRIES_EXHAUSTED | UNKNOWN | UNKNOWN | TERMINAL |
| Any other non-2xx | HTTP_nnn | ERROR | ERROR | TERMINAL |
| non-callout exception from the client | CLIENT_ERROR | ERROR | ERROR | MANUAL |
| ownership lost while the callout was in flight | SUPERSEDED | UNKNOWN | *untouched* | *untouched* |

`UNKNOWN` means "the remote side effect may have happened, do not blindly redo it". The framework only re-queues UNKNOWN or stale-lease work when `config.idempotencyEnabled && IntegrationRetryPolicy.canRetry(...)`. This gate appears in both `IntegrationExecutionJob` and `IntegrationRecoveryScheduler`; keep it intact in any change, it is the core safety property. The one exception is `LEASE_EXPIRED`, which is decided *before* the callout: nothing was sent, so retrying it needs no idempotency.

`RECONCILE` means "uncertain, not yet evaluated". `IntegrationRecoveryScheduler` is the evaluator and every run turns each one into RETRY or MANUAL, which is what keeps that window draining instead of filling with records nobody will requeue.

**Schedulers** (customers schedule them via `System.schedule`, see README): `IntegrationPurgeBatch` is Batchable and Schedulable; it deletes only `SUCCESS` transactions older than their integration's `RetentionDays__c` (30 by default), never anything carrying `MANUAL` or `RECONCILE`, and never a transaction whose definition no longer resolves. Attempts cascade through the master-detail.

**Schedulers** (customers schedule them via `System.schedule`, see README): `IntegrationDispatchScheduler` enqueues a claim job for each due record, per the predicate above (max 40 per run). `IntegrationRecoveryScheduler` handles only what had no normal ending: expired `PROCESSING` leases, which become a synthetic `STALE_LEASE` attempt plus an `UNKNOWN` transaction, and `UNKNOWN` + `RECONCILE` records. Both sweeps catch configuration errors per record, park that one as MANUAL and carry on.

**Retry math** (`IntegrationRetryPolicy`): `MaxRetries__c` counts retries *after* the first attempt, so `canRetry` is `attemptCount <= maxRetries`. Backoff is `base * 2^(attempt-1)` with the exponent capped at 10.

Other things worth knowing before editing:

- `IntegrationConfigService.get()` owns all defaults (timeout 30000 ms, lease 60 s, 3 retries, 60 s base delay, 12000 payload chars, 30 days retention, retryable codes 408/429/500/502/503/504, header `Idempotency-Key`). Change defaults there, not at call sites. It also validates every definition and caches one `Config` per key per Apex transaction, so `get()` is cheap to call in a loop.
- `IntegrationOperationHandler.buildRequest()` runs inside a savepoint with a DML counter. If it writes, the write is rolled back and the attempt is refused as `HANDLER_DML` without calling out, because that DML would otherwise turn the callout into an "uncommitted work pending" failure that reads exactly like an uncertain remote call.
- `IntegrationHttpClient` builds the endpoint as `callout:<NamedCredential__c>` + path, silently drops `Authorization` / `Proxy-Authorization` / `Host` headers supplied by handlers, and sets the idempotency header only when idempotency is enabled.
- Bodies are persisted only when `LogRequestBody__c` / `LogResponseBody__c` are true, always through `IntegrationSanitizer.sanitize` (regex redaction of token/password keys, then truncation). Headers are never persisted.
- Handlers are resolved reflectively with `Type.forName(HandlerClass__c)` in `IntegrationHandlerFactory`; the package ships no concrete handler.
- The three `*Service` classes are `inherited sharing`; the jobs and schedulers run as system context Queueable/Schedulable.

## Testing

`IntegrationTestDataFactory` holds everything shared between test classes: the configuration seam, the transaction builders and the test user. `classes/tests/CLAUDE.md` has the details.

Two rules that are easy to break:

- **Tests run as a user holding nothing but the shipped permission set**, created in `@TestSetup` and entered with `System.runAs`. Any test doing DML on `IntegrationTransaction__c` or `IntegrationAttempt__c` belongs inside that block; outside it, the test silently depends on whoever launched it and fails in a clean packaging org with "fields being inaccessible". This also makes the suite prove the permission set is sufficient on its own. Verified by unassigning it from the developer's user: 38/38 still pass.
- **Custom Metadata cannot be inserted in tests**, so configuration goes in through the `@TestVisible` seam `IntegrationConfigService.setTestConfig(config)`, which `get()` honours only under `Test.isRunningTest()`. To test the parsing, build an `IntegrationDefinition__mdt` in memory and call `fromDefinition`; for the cache, call `cached`.

`IntegrationExecutionJobTest` owns the callout infrastructure: a mock that counts calls, can throw a `CalloutException` and can steal the transaction mid-flight, plus a handler with five failure modes. `IntegrationHttpClient` still has no coverage of its own, and `IntegrationClaimJob` and `IntegrationRequest` are the two thinnest at 53% and 45%.
