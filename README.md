# sf-integration-framework

Reusable integration framework for Salesforce. It provides durable integration transactions, stable idempotency keys, per-attempt audit records, asynchronous HTTP execution, retry/backoff primitives and stale-work recovery.

The project is structured as a Salesforce DX project and is intended to be distributed as a **2GP Unlocked Package**.

> Status: early `0.1.x` development. Public APIs may still change.

## What problem it solves

A business change and an outbound integration should not depend on one fragile HTTP execution. The framework persists the logical operation first and executes it asynchronously:

```text
Business transaction
      |
      +-- business DML
      +-- IntegrationTransaction__c (PENDING)
                |
              COMMIT
                |
           claim Queueable
                |
       PROCESSING + lease
                |
            HTTP callout
                |
       IntegrationAttempt__c
                |
      SUCCESS / ERROR / UNKNOWN
```

`IntegrationTransaction__c` is operational state. `IntegrationAttempt__c` is the history of physical execution attempts. Diagnostic logging is deliberately a separate concern.

## Main capabilities

- Stable operation/idempotency key across retries.
- `PENDING`, `PROCESSING`, `SUCCESS`, `ERROR` and `UNKNOWN` lifecycle.
- Pessimistic claim using `FOR UPDATE`.
- Processing leases to detect abandoned async jobs.
- Separate Queueables for claim/DML and HTTP execution to avoid uncommitted-work callout errors.
- Configurable retryable HTTP status codes and exponential backoff.
- Automatic retry of uncertain outcomes only when remote idempotency is explicitly enabled.
- Configurable request/response persistence with sanitization and truncation.
- Named Credential based callouts; no secrets in Apex or Custom Metadata.
- Pluggable operation handlers that rebuild requests from durable business state.
- Scheduled dispatcher and recovery jobs.

## Repository layout

```text
force-app/main/default/
|-- classes/
|-- objects/
|   |-- IntegrationTransaction__c/
|   |-- IntegrationAttempt__c/
|   `-- IntegrationDefinition__mdt/
`-- permissionsets/
config/
`-- project-scratch-def.json
docs/
|-- architecture.md
`-- security.md
```

## Requirements

- Salesforce CLI (`sf`).
- A Dev Hub enabled org to create 2GP package versions.
- A target org for installation.
- Named Credentials / External Credentials configured in each target org for real integrations.

## Local development

```bash
git clone https://github.com/RubnSanchz/sf-integration-framework.git
cd sf-integration-framework

sf org login web --alias my-devhub --set-default-dev-hub
sf org create scratch \
  --definition-file config/project-scratch-def.json \
  --alias sif-scratch \
  --duration-days 7

sf project deploy start --target-org sif-scratch
sf apex run test --target-org sif-scratch --test-level RunLocalTests --wait 20
```

## Create the Unlocked Package

The package itself is created once in the selected Dev Hub:

```bash
sf package create \
  --name sf-integration-framework \
  --package-type Unlocked \
  --path force-app \
  --target-dev-hub my-devhub
```

Salesforce CLI adds the package alias/ID to `sfdx-project.json`. Commit that generated alias before creating distributable versions.

Create a package version:

```bash
sf package version create \
  --package sf-integration-framework \
  --installation-key-bypass \
  --code-coverage \
  --wait 20 \
  --target-dev-hub my-devhub
```

After validating a version, promote it:

```bash
sf package version promote \
  --package <04t-package-version-id> \
  --target-dev-hub my-devhub
```

## Install in an org

```bash
sf package install \
  --package <04t-package-version-id-or-alias> \
  --target-org <org-alias> \
  --wait 20 \
  --publish-wait 20
```

Then:

1. Assign `SF Integration Framework Admin` to administrators who need to inspect or manage framework records.
2. Configure the target org's Named Credential and External Credential.
3. Create an `IntegrationDefinition__mdt` record for each integration.
4. Implement an Apex class that implements `IntegrationOperationHandler`.
5. Schedule dispatcher/recovery jobs if you want automatic recovery and draining of pending work.

## Configure an integration

`IntegrationDefinition__mdt.DeveloperName` is the integration key used from Apex.

Important fields:

| Field | Purpose |
| --- | --- |
| `NamedCredential__c` | Named Credential API name used as `callout:<name>` |
| `HandlerClass__c` | Apex class implementing `IntegrationOperationHandler` |
| `TimeoutMs__c` | HTTP timeout |
| `ProcessingLeaseSeconds__c` | Maximum expected processing lease before recovery treats work as stale |
| `MaxRetries__c` | Additional retries after the first attempt |
| `RetryBaseDelaySeconds__c` | Base delay for exponential backoff |
| `RetryableStatusCodes__c` | Comma-separated HTTP codes; defaults to `408,429,500,502,503,504` |
| `IdempotencyEnabled__c` | Whether the remote system guarantees duplicate-safe processing for the configured key |
| `IdempotencyHeader__c` | Header name, default `Idempotency-Key` |
| `LogRequestBody__c` / `LogResponseBody__c` | Explicit opt-in payload persistence |

Do **not** enable `IdempotencyEnabled__c` merely because Salesforce generates a key. The remote API must actually consume and enforce that key.

## Implement a handler

```apex
public class InvoiceIntegrationHandler implements IntegrationOperationHandler {
    public IntegrationRequest buildRequest(IntegrationTransaction__c tx) {
        Factura__c invoice = [
            SELECT Id, Amount__c
            FROM Factura__c
            WHERE Id = :tx.RecordId__c
        ];

        return new IntegrationRequest(
            tx.IntegrationKey__c,
            tx.Operation__c,
            'POST',
            '/v1/invoices'
        ).withBody(JSON.serialize(invoice));
    }

    public String extractExternalId(IntegrationResponse response) {
        Map<String, Object> body =
            (Map<String, Object>) JSON.deserializeUntyped(response.body);
        return (String) body.get('id');
    }

    public void handleSuccess(
        IntegrationTransaction__c tx,
        IntegrationResponse response
    ) {
        // Optional local post-processing after the remote call succeeds.
    }
}
```

`buildRequest()` must be read-only. Do not perform DML there: the framework intentionally performs the HTTP callout before any DML in the execution Queueable.

## Register work transactionally

Call the framework in the same Salesforce transaction as the business change:

```apex
update invoice;

IntegrationRequest request = new IntegrationRequest(
    'CORE_INVOICE',
    'CREATE',
    'POST',
    '/v1/invoices'
).forRecord(invoice);

IntegrationFramework.registerAndEnqueue(request);
```

If the surrounding Salesforce transaction rolls back, the integration transaction and queued work roll back with it.

## Schedule recovery

Example from Execute Anonymous:

```apex
System.schedule(
    'SIF Dispatcher',
    '0 0/5 * * * ?',
    new IntegrationDispatchScheduler()
);

System.schedule(
    'SIF Recovery',
    '0 2/5 * * * ?',
    new IntegrationRecoveryScheduler()
);
```

The dispatcher drains `PENDING` and due retry work. Recovery identifies expired processing leases and only auto-requeues uncertain work when remote idempotency is configured.

## Security

- No credentials, tokens or passwords are stored in package Custom Metadata.
- Named Credentials/External Credentials remain the authentication boundary.
- Authorization/host headers cannot be overridden by operation handlers.
- Persisting request and response bodies is opt-in.
- Persisted payloads are redacted and truncated.
- Treat `IntegrationTransaction__c` and `IntegrationAttempt__c` as operational/audit data and apply org retention policies.

See [docs/security.md](docs/security.md).

## Current scope / limitations

- No UI is included yet.
- No generic reconciliation endpoint strategy is included yet; non-idempotent `UNKNOWN` work remains for manual or integration-specific reconciliation.
- Named Credential definitions are intentionally not packaged because endpoint/authentication configuration is environment-specific.
- Nebula Logger is not a dependency. A logging adapter can be added later without coupling the operational state model to diagnostic logging.

## License

No open-source license has been selected yet.
