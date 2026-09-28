/**
 * Deletes transactions that finished successfully long enough ago, together
 * with their attempts, which follow through the master-detail relationship.
 *
 * Only SUCCESS is ever deleted. Anything that failed, is uncertain, or still
 * needs a person is operational evidence, and the whole point of the outbox is
 * that it survives long enough to be looked at. Retention is per integration,
 * because an integration that moves invoices and one that syncs preferences do
 * not deserve the same memory.
 *
 * Customers schedule it themselves, like the other two jobs:
 *
 *   System.schedule('SIF Purge', '0 0 3 * * ?', new IntegrationPurgeBatch());
 */
public class IntegrationPurgeBatch implements Database.Batchable<SObject>, Schedulable {
    private static final Integer DEFAULT_SCOPE = 200;

    // A SUCCESS record never carries either of these, so this is a second guard
    // rather than the main one. It is here so that widening the batch later
    // cannot silently start deleting work that a person still owes an answer to.
    private static final Set<String> PROTECTED_DISPOSITIONS = new Set<String>{
        IntegrationConstants.DISPOSITION_MANUAL,
        IntegrationConstants.DISPOSITION_RECONCILE
    };

    private Integer scopeSize;
    private Boolean emptyRecycleBin;

    public IntegrationPurgeBatch() {
        this(DEFAULT_SCOPE, false);
    }

    /**
     * @param emptyRecycleBin frees the storage immediately instead of after the
     *        standard 15 days, at the cost of making the deletion unrecoverable.
     */
    public IntegrationPurgeBatch(Integer scopeSize, Boolean emptyRecycleBin) {
        this.scopeSize = scopeSize == null || scopeSize <= 0 ? DEFAULT_SCOPE : scopeSize;
        this.emptyRecycleBin = emptyRecycleBin == true;
    }

    public void execute(SchedulableContext context) {
        Database.executeBatch(this, scopeSize);
    }

    public Database.QueryLocator start(Database.BatchableContext context) {
        // Bounded by the shortest retention configured anywhere, because one
        // query has to serve every integration. execute() then holds each record
        // to its own.
        Datetime cutoff = System.now().addDays(-IntegrationConfigService.shortestRetentionDays());
        return Database.getQueryLocator([
            SELECT Id, IntegrationKey__c, CompletedAt__c
            FROM IntegrationTransaction__c
            WHERE Status__c = :IntegrationConstants.STATUS_SUCCESS
              AND CompletedAt__c != null
              AND CompletedAt__c < :cutoff
              AND Disposition__c NOT IN :PROTECTED_DISPOSITIONS
            ORDER BY CompletedAt__c ASC
        ]);
    }

    // Database.Batchable<SObject> fixes this signature: the scope cannot be typed
    // as the concrete object, so it is cast once here.
    public void execute(Database.BatchableContext context, List<SObject> scope) {
        Datetime nowValue = System.now();
        List<IntegrationTransaction__c> expired = new List<IntegrationTransaction__c>();

        for (IntegrationTransaction__c transactionRecord : (List<IntegrationTransaction__c>) scope) {
            Integer retentionDays;
            try {
                retentionDays = IntegrationConfigService.get(
                    transactionRecord.IntegrationKey__c
                ).retentionDays;
            } catch (Exception ex) {
                // A definition that no longer resolves is not a licence to delete
                // its history. Leave it for a person to decide.
                continue;
            }

            if (transactionRecord.CompletedAt__c < nowValue.addDays(-retentionDays)) {
                expired.add(transactionRecord);
            }
        }

        if (expired.isEmpty()) {
            return;
        }

        delete expired;
        if (emptyRecycleBin) {
            Database.emptyRecycleBin(expired);
        }
    }

    public void finish(Database.BatchableContext context) {}
}
