# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Salesforce DX project (Apex + custom objects, API 67.0, no namespace) meant to ship as a 2GP Unlocked Package. All source is under `force-app/main/default`. The only tooling is the `sf` CLI: there is no `package.json`, linter config, or CI. `README.md` has the full install / package / configuration walkthrough; `docs/integration-architecture.md` and `docs/integration-security.md` explain the design decisions summarised below.

English documentation is canonical. `README.es.md` and `docs/*.es.md` are Spanish translations with no extra content: do not read them unless the task is about translations. When you edit an English doc, update its `.es.md` counterpart in the same change or tell the user it needs re-syncing. Each pair carries a `[English](x.md) | [Español](x.es.md)` bar as its first line. `CLAUDE.md` files are not translated.

## Commands

Every command needs an authenticated org. Scratch org bootstrap:

```bash
sf org login web --alias my-devhub --set-default-dev-hub
sf org create scratch --definition-file config/project-scratch-def.json --alias sif-scratch --duration-days 7
```

Deploy and test against it:

```bash
sf project deploy start --target-org sif-scratch                                   # all source
sf project deploy start --target-org sif-scratch --source-dir force-app/main/default/classes/IntegrationHttpClient.cls
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
- `SF_Integration_Framework_Admin.permissionset-meta.xml` lists `fieldPermissions` per custom field. New fields on `IntegrationTransaction__c` / `IntegrationAttempt__c` must be added there.
- Every `.cls` needs a sibling `.cls-meta.xml` (apiVersion 67.0, status Active).
- The string constants in `IntegrationConstants` must match the restricted picklists on `IntegrationTransaction__c.Status__c` and `IntegrationAttempt__c.Result__c`.
- Named Credentials are deliberately **not** packaged; never add environment-specific credential metadata to `force-app`.

## Architecture

Transactional outbox for outbound HTTP. One `IntegrationTransaction__c` is one logical business operation with a stable, unique `IdempotencyKey__c`. One `IntegrationAttempt__c` is one physical execution attempt (audit only, never read back for retry decisions). Per-integration config comes from `IntegrationDefinition__mdt`, keyed by `DeveloperName` (the "integration key" passed from Apex).

Pipeline, where each arrow is a separate Apex transaction:

```
IntegrationFramework.registerAndEnqueue(request)    caller's transaction: insert PENDING tx, enqueue claim job
  -> IntegrationClaimJob (Queueable)                 SELECT ... FOR UPDATE; PENDING or due ERROR -> PROCESSING,
                                                     AttemptCount++, set lease; chain execution job
  -> IntegrationExecutionJob (Queueable + AllowsCallouts)
       handler.buildRequest(tx) -> IntegrationHttpClient.send -> IntegrationAttemptService.record
                                                                + IntegrationTransactionService.markSuccess/Error/Unknown
```

**Why two Queueables:** DML followed by a callout in the same Apex transaction fails with "uncommitted work pending". The claim job does only DML; the execution job does the callout *first* and DML afterwards. That is also why `IntegrationOperationHandler.buildRequest()` must be read-only and why retries rebuild the request from Salesforce state instead of a persisted body.

**Outcome classification** lives entirely in `IntegrationExecutionJob`:

| Situation | Attempt `Result__c` | Tx `Status__c` |
| --- | --- | --- |
| 2xx and `handleSuccess` OK | SUCCESS | SUCCESS |
| 2xx but `handleSuccess` / `extractExternalId` throws | UNKNOWN | UNKNOWN (local DML rolled back to savepoint; remote side effect already happened) |
| `CalloutException` (timeout, etc.) | UNKNOWN | UNKNOWN |
| Retryable status AND `IdempotencyEnabled__c` AND `canRetry` | ERROR | ERROR with `NextRetryAt__c` |
| Retryable status but idempotency disabled | UNKNOWN | UNKNOWN |
| Any other non-2xx, or non-callout exception | ERROR | ERROR, no retry |

`UNKNOWN` means "the remote side effect may have happened, do not blindly redo it". The framework only re-queues UNKNOWN or stale-lease work when `config.idempotencyEnabled && IntegrationRetryPolicy.canRetry(...)`. This gate appears in both `IntegrationExecutionJob` and `IntegrationRecoveryScheduler`; keep it intact in any change, it is the core safety property.

**Schedulers** (customers schedule them via `System.schedule`, see README): `IntegrationDispatchScheduler` enqueues a claim job for each PENDING or due-retry ERROR record (max 40 per run). `IntegrationRecoveryScheduler` turns expired PROCESSING leases into a synthetic `STALE_LEASE` attempt and re-queues only safe UNKNOWNs.

**Retry math** (`IntegrationRetryPolicy`): `MaxRetries__c` counts retries *after* the first attempt, so `canRetry` is `attemptCount <= maxRetries`. Backoff is `base * 2^(attempt-1)` with the exponent capped at 10.

Other things worth knowing before editing:

- `IntegrationConfigService.get()` owns all defaults (timeout 30000 ms, lease 60 s, 3 retries, 60 s base delay, 12000 payload chars, retryable codes 408/429/500/502/503/504, header `Idempotency-Key`). Change defaults there, not at call sites.
- `IntegrationHttpClient` builds the endpoint as `callout:<NamedCredential__c>` + path, silently drops `Authorization` / `Proxy-Authorization` / `Host` headers supplied by handlers, and sets the idempotency header only when idempotency is enabled.
- Bodies are persisted only when `LogRequestBody__c` / `LogResponseBody__c` are true, always through `IntegrationSanitizer.sanitize` (regex redaction of token/password keys, then truncation). Headers are never persisted.
- Handlers are resolved reflectively with `Type.forName(HandlerClass__c)` in `IntegrationHandlerFactory`; the package ships no concrete handler.
- The three `*Service` classes are `inherited sharing`; the jobs and schedulers run as system context Queueable/Schedulable.

## Testing

Custom Metadata cannot be inserted in tests, so `IntegrationCoreTest` injects configuration through the `@TestVisible` seam `IntegrationConfigService.setTestConfig(config)`, which `get()` honours only under `Test.isRunningTest()`. Use that seam in new tests rather than relying on `IntegrationDefinition__mdt` records. `IntegrationExecutionJob` and `IntegrationHttpClient` currently have no callout-mock coverage; if you test them, use `Test.setMock(HttpCalloutMock.class, ...)` and a handler class defined inside the test.
