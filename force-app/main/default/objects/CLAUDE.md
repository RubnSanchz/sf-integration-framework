# objects/

Custom objects and the Custom Metadata type. Four rules here were each learned from a deployment that failed outright.

- Every `*.field-meta.xml` needs an explicit `<fullName>` matching its file name, or the deploy fails with "element fullName missing for a child of type CustomField" — and then every Apex class fails to compile, which looks like an Apex problem and is not.
- `IntegrationAttempt__c` is a master-detail child, so its `sharingModel` must stay `ControlledByParent`.
- Required and master-detail fields must **not** appear in the permission set's `fieldPermissions`: their FLS is implicit and the deploy fails with "You cannot deploy to a required field". Today that is `IdempotencyKey__c`, `IntegrationKey__c`, `Operation__c` and `IntegrationAttempt__c.Transaction__c`.
- Picklist values that Apex refers to are `UPPER_SNAKE` and must match `IntegrationConstants` exactly. `Status__c`, `Disposition__c` and `IntegrationAttempt__c.Result__c` are restricted; a test enforces the correspondence.
- Field history is on for `Status__c` and `Disposition__c` only. It answers "how did it get here" without filling the related list with lease and timestamp noise, and it does not count towards data storage.
- New fields need their `fieldPermissions` in `SF_Integration_Framework_Admin`, and repeated elements in that file must stay contiguous and in XSD order or the whole deployment fails.
