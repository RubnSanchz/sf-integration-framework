# classes/api/

The surface a consumer of the package touches: `IntegrationFramework` (the only entry point), `IntegrationRequest`, `IntegrationResponse` and the `IntegrationOperationHandler` interface.

- This is packaged API. In a 2GP package a `public` member cannot be removed or have its signature changed once a version is released, so add rather than alter, and think before making something `public` here that could be `private`.
- `IntegrationOperationHandler.buildRequest()` **must be read-only**. The execution job wraps it in a savepoint with a DML counter and refuses the attempt as `HANDLER_DML` if it writes, because that DML turns the following callout into an "uncommitted work pending" failure that is indistinguishable from an uncertain remote call.
- Retries rebuild the request from Salesforce state. Never persist a request body as the source of truth for a retry: payload logging is opt-in and must stay optional.
- `IntegrationRequest` is a builder (`withBody`, `withHeader`, `forRecord`). Keep new options in that shape.
