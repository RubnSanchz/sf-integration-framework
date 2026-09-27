# classes/support/

`IntegrationHttpClient`, `IntegrationSanitizer`, `IntegrationHandlerFactory`, `IntegrationConstants`.

- `IntegrationConstants` values that mirror a restricted picklist must match it exactly; `constantsMatchTheRestrictedPicklists` enforces that and `constantValuesArePinned` pins every literal. See `classes/CLAUDE.md` for why they are `public static final` and not properties.
- `IntegrationHttpClient` builds the endpoint as `callout:<NamedCredential__c>` + path, silently drops `Authorization`, `Proxy-Authorization` and `Host` supplied by handlers, and sets the idempotency header only when idempotency is enabled. Do not let a handler override those three.
- `IntegrationSanitizer` compiles its patterns once into statics. Keep it that way: a getter would recompile the regexes on every read. Redaction keys are matched case-insensitively, so `apiKey` and `APIKEY` need one entry, while `access_token` and `accessToken` need two. Truncation counts its own suffix, so the result never exceeds `maxChars`.
- Headers are never persisted. Bodies only when `LogRequestBody__c` / `LogResponseBody__c` say so, always sanitized.
- `IntegrationHandlerFactory` resolves handlers reflectively with `Type.forName`. The package ships no concrete handler and must not.
