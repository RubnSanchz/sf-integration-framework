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

```text
                  +----------+
                  | PENDING  |
                  +----+-----+
                       | claim
                       v
                 +-----------+
                 |PROCESSING |
                 +-----+-----+
                       |
        +--------------+--------------+
        |              |              |
        v              v              v
    SUCCESS          ERROR         UNKNOWN
                       |              |
                       | due retry    | idempotent recovery
                       +-------> PENDING <------+
```

`ERROR` means Salesforce received enough information to classify a failure. A `NextRetryAt__c` value means the framework considers it eligible for retry.

`UNKNOWN` means Salesforce cannot safely infer whether the remote side effect occurred. Automatic retry is only enabled when the integration definition explicitly says the remote API is idempotent.

## Leases and stale work

A claimed transaction receives `ProcessingStartedAt__c` and `LeaseExpiresAt__c`. Recovery treats a `PROCESSING` transaction with an expired lease as stale.

For stale work the recovery scheduler writes a synthetic `IntegrationAttempt__c` with result `UNKNOWN`. It returns the work to `PENDING` only when retry is enabled, remote idempotency is enabled and the retry budget has not been exhausted.

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
