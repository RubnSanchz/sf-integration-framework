# classes/

Apex conventions and the decisions behind them. The root `CLAUDE.md` has the architecture; this file has how the code is written.

## Layout

`api/` what a consumer touches · `pipeline/` queueables and schedulables · `services/` the classes that own the DML · `policy/` pure decision logic · `support/` plumbing · `tests/`.

**The folders are a repository convention only.** Apex has no folders: the metadata API flattens everything into `classes/`, so the layout never reaches an org and a subscriber never sees it. Moving a class between folders is not a metadata change and needs no `manifest/package.xml` edit — the manifest lists member names, not paths. Only `--source-dir` arguments carry the subfolder.

## Naming

- Classes are `Integration` + role: `Service`, `Job`, `Scheduler`, `Policy`, `Factory`, `Client`, `Sanitizer`, `Constants`. Value objects take no suffix (`IntegrationRequest`). The interface is `IntegrationOperationHandler`, no `I` prefix.
- Exceptions are `<Domain>Exception`, declared inside the class that throws them.
- Methods are verbs; the ones returning `Boolean` start with one (`owns`, `canRetry`, `isForbiddenHeader`).
- Variables use whole words, never abbreviations: `transactionRecord`, not `txn`. `transaction` on its own does not compile, it is a reserved word in Apex. Suffix `Value` where the natural name collides (`nowValue`, `rawValue`).
- Constants are `UPPER_SNAKE` with a family prefix: `STATUS_`, `RESULT_`, `DISPOSITION_`, `ERROR_`, `DEFAULT_`.
- Booleans read as an assertion: `successful`, `retryable`, `safeRetry`, `handlerWroteData`, `neverExecuted`.
- No Hungarian notation, no `m_`, no leading underscore.

## Deliberate, do not "fix"

- Shared literals are `public static final`, not properties. Both the property form and inner classes were tried: an inner class cannot hold statics at all ("static can only be used on fields of a top level type"), and a property loses `final`, which is what keeps a value from drifting from the restricted picklist it mirrors. Nested enums do work, but almost every use writes a String to an sObject field, so they would add `.name()` at some sixty call sites.
- Test seams are `@TestVisible private`. Never widen a member to `public` just to test it.

## Known rough edges, already logged for the cleanup phase

- `ERROR_CONFIGURATION` holds `'CONFIGURATION_ERROR'`: the prefix is a family marker, not part of the value, but it reads like a mistake.
- `MAX_PAYLOAD_CHARS` (the 32768 ceiling) and `DEFAULT_MAX_PAYLOAD_CHARS` (the 12000 default) sit one word apart in `IntegrationConfigService` and mean opposite things. `IntegrationSanitizer.DEFAULT_MAX_CHARS` duplicates that 12000.
- `parked()` and `terminal()` are adjectives used as factory methods.
