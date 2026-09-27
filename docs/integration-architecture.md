[English](integration-architecture.md) | [Español](integration-architecture.es.md)

# Architecture

## Design principles

### Logical operation != HTTP attempt

`IntegrationTransaction__c` represents one logical business integration operation. Its `IdempotencyKey__c` remains stable across retries. `IntegrationAttempt__c` represents one physical execution attempt.

### Transactional outbox

The recommended usage is to create the framework transaction in the same Salesforce transaction as the business mutation. The outbound HTTP work happens only after commit.

### Claim before execute

The claim phase runs in its own Queueable and locks the transaction with `FOR UPDATE`, moves it to `PROCESSING`, increments the attempt counter and sets a lease. It then chains the callout Queueable.

This separation is intentional: performing DML and then attempting a callout in the same Apex transaction can fail with pending/uncommitted work.

### Request reconstruction

The framework does not rely on a persisted request body as the source of truth for retries. `IntegrationOperationHandler.buildRequest()` reconstructs the outbound request from durable Salesforce state.

This allows payload logging to remain optional without making recovery impossible.

## State machine

Two fields answer two different questions. `Status__c` says what happened. `Disposition__c` says what the framework does next.

```text
                  +----------+
                  | PENDING  |   Disposition NONE: never executed
                  +----+-----+
                       | claim (AttemptCount++, lease, attempt number handed to the worker)
                       v
                 +-----------+
                 |PROCESSING |
                 +-----+-----+
                       |
        +--------------+--------------+
        |              |              |
        v              v              v
    SUCCESS          ERROR         UNKNOWN
    NONE           RETRY | TERMINAL | MANUAL
                                  RETRY | RECONCILE | TERMINAL | MANUAL
                       |              |
                       +---- Disposition RETRY and NextRetryAt due ----+
                                      |
                                      v
                                 claimed again
```

A transaction never goes back to `PENDING`. `PENDING` means "never executed", and everything the framework intends to run again says so through `Disposition__c = RETRY` plus a `NextRetryAt__c`, whatever its status. This is what lets an uncertain outcome remain `UNKNOWN` while still being scheduled, instead of being rewritten as `PENDING` and losing that information.

Work is due when:

```text
(Status__c = PENDING AND Disposition__c = NONE)
OR (Disposition__c = RETRY AND (NextRetryAt__c = null OR NextRetryAt__c <= now))
```

`ERROR` means Salesforce received enough information to classify a failure.

`UNKNOWN` means Salesforce cannot safely infer whether the remote side effect occurred. Automatic retry is only enabled when the integration definition explicitly says the remote API is idempotent.

The dispositions:

| Value | Meaning |
| --- | --- |
| `NONE` | Nothing for the framework to do: either never executed, or finished successfully. |
| `RETRY` | It will be sent again once `NextRetryAt__c` is due. An empty date means "as soon as possible". |
| `RECONCILE` | The outcome is uncertain and has not been evaluated yet. The recovery scheduler evaluates it on its next run and turns it into `RETRY` or `MANUAL`. |
| `MANUAL` | Nothing automatic will resolve this. It needs an administrator. |
| `TERMINAL` | Finished without success and there is nothing left to try. |

An administrator requeues a parked transaction by setting `Disposition__c` to `RETRY`, with a date to delay it or without one to have it dispatched on the next run.

## Failures before the callout

Everything that can fail between claiming a transaction and sending the request is classified as `ERROR`, never `UNKNOWN`: no request left the org, so the remote side cannot have acted. Each cause has its own code, because they are resolved differently: `CONFIGURATION_ERROR`, `HANDLER_ERROR`, `REQUEST_BUILD_ERROR`, `INVALID_REQUEST` and `HANDLER_DML`.

`buildRequest()` runs inside a savepoint with a DML counter. If it writes anything, the write is rolled back and the attempt is refused as `HANDLER_DML` without calling out. That DML would otherwise make the following callout fail with "uncommitted work pending", which is indistinguishable at runtime from a genuinely uncertain remote call.

## Leases, fencing and stale work

A claimed transaction receives `ProcessingStartedAt__c` and `LeaseExpiresAt__c`, and the worker is handed the attempt number its claim reserved.

That number is the fence. The execution job only acts while the stored `AttemptCount__c` still matches it, checked on entry and again with `FOR UPDATE` after the callout returns. Three outcomes:

- Wrong attempt number on entry: the worker stands down silently, writing nothing and sending nothing.
- Lease already expired on entry: no callout is made. Since nothing was sent there is no remote side effect, so this retry does not require remote idempotency. The attempt is recorded as `LEASE_EXPIRED`.
- Ownership lost while the callout was in flight: the response is recorded as an `UNKNOWN` / `SUPERSEDED` attempt carrying the real HTTP status code, and the transaction is left untouched for whoever owns it now.

Recovery treats a `PROCESSING` transaction with an expired lease as stale. It writes a synthetic `IntegrationAttempt__c` with result `UNKNOWN` and code `STALE_LEASE`, and moves the transaction to `UNKNOWN` with `RETRY` and a backoff date only when retry is enabled, remote idempotency is enabled and the retry budget has not been exhausted. Otherwise it becomes `RECONCILE`, and from there `MANUAL` once the recovery scheduler has confirmed that nothing automatic can resolve it.

## Retry policy

`MaxRetries__c` means additional retries after the first execution. `RetryBaseDelaySeconds__c` uses capped exponential backoff:

```text
delay = base * 2^(attempt - 1)
```

The exponent is capped to avoid unbounded integer growth.

## Extension point

Each integration supplies an `IntegrationOperationHandler`:

- `buildRequest()` rebuilds the request without DML.
- `extractExternalId()` extracts the remote identifier after success.
- `handleSuccess()` performs optional local post-processing.

If post-processing fails after the remote API has already succeeded, local DML is rolled back to a savepoint and the transaction becomes `UNKNOWN`. This avoids incorrectly declaring a remote side effect as failed.

## Deliberately separate concerns

Operational recovery state is not diagnostic logging. The framework can later integrate with Nebula Logger through an adapter, but retry decisions must never depend on log records.
