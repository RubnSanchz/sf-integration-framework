[English](integration-security.md) | [Español](integration-security.es.md)

# Security model

## Credentials

The framework references Named Credentials by API name. Secrets are never stored in `IntegrationDefinition__mdt`, Apex constants, `IntegrationTransaction__c` or `IntegrationAttempt__c`.

Each subscriber/target org is responsible for creating the Named Credential and associated External Credential/principal. This allows the same package to use different endpoints and credentials per environment.

Salesforce does not package sensitive principal material such as access tokens and certificates with credential metadata; those values must be populated in the target org.

## Headers

Handlers can provide application headers, but the HTTP client rejects overrides for:

- `Authorization`
- `Proxy-Authorization`
- `Host`

Authentication must remain under Named Credential control.

## Payload persistence

Request and response bodies are disabled by default. They are persisted only when the corresponding flags are enabled in `IntegrationDefinition__mdt`.

Before persistence, the framework:

- redacts common token/password keys;
- truncates content to `MaxPayloadChars__c`;
- never stores request headers as part of an attempt.

This is defense in depth, not a substitute for classifying the data handled by each integration. An org should avoid enabling full payload logging for sensitive APIs unless there is a defined need and retention policy.

## Sharing and access

Operational services use explicit/inherited sharing semantics rather than relying on an accidental sharing default. Internal framework DML is intentionally performed by Apex services; administrators receive a packaged permission set for direct record inspection/management.

Consumer code should expose framework functionality to end users only through its own authorization boundary.

## Idempotency trust boundary

`IdempotencyEnabled__c = true` is a security/reliability assertion about the **remote system**, not Salesforce.

Only enable it when the remote API guarantees that repeated requests with the same configured key do not repeat the business side effect. If that guarantee does not exist, uncertain operations remain `UNKNOWN` for reconciliation/manual review rather than being blindly retried.

## Data retention

`IntegrationAttempt__c` can grow quickly in high-volume orgs. Every record counts as 2 KB against data storage whatever it contains, so one operation that took three attempts occupies four records.

`IntegrationPurgeBatch` enforces retention. It deletes only transactions in `SUCCESS`, older than their integration's `RetentionDays__c` (30 by default), and their attempts cascade with them. Failures, uncertain outcomes and anything carrying `MANUAL` or `RECONCILE` are never deleted automatically: they are the evidence someone needs in order to decide, and deleting them would hide an unresolved side effect on the remote system rather than resolve it.

Deleted records remain in the recycle bin for 15 days and keep counting against storage. `new IntegrationPurgeBatch(scope, true)` empties it immediately, which frees the storage at the cost of making the deletion unrecoverable. Decide that per org: a longer window is a cheap safety net against a retention misconfigured too aggressively.

Enable verbose payload logging with the retention already scheduled, not after.

## Package considerations

The initial package is namespace-free and intended for private/reusable 2GP Unlocked Package distribution. If the project is ever intended for Managed 2GP/AppExchange distribution, namespace and API-surface decisions should be revisited before that migration.
