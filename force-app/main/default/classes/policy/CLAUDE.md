# classes/policy/

Decision logic with no side effects. `IntegrationRetryPolicy` today; `IntegrationRecoveryPolicy` lands here when the recovery refactor happens.

- **No SOQL, no DML, no queueables, no `Test.setMock`, no `Test.startTest`.** A class here must be testable as a table of inputs and expected outputs. If it needs to read something, the caller reads it and passes it in.
- `MaxRetries__c` counts retries *after* the first attempt, so `canRetry` is `attemptCount <= maxRetries`. Backoff is `base * 2^(attempt - 1)` with the exponent capped at 10.
- The framework's safety property lives here: uncertain work is only re-queued when `config.idempotencyEnabled && canRetry(...)`. The one exception is `LEASE_EXPIRED`, decided before the callout, where nothing was sent and no idempotency is required.
