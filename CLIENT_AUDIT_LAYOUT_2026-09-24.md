# Client AuditLog layout — September 24, 2026

This is work 3 in the combined delivery: (1) search specification update,
(2) EntityKey explanation/readable report, and (3) the newly supplied AuditLog
layout. None of this combined delivery has been sent to the client by this tool.

## Main table

`dbo.AuditLog` is now a **physical table** with the nine columns visible in the
client's screenshot, in this order. There is no EntityKey or RunID column in it.

| Column | Definition | Purpose |
|---|---|---|
| AuditID | INT IDENTITY(1,1), primary key, not null | Unique event ID |
| UPRID | BIGINT, nullable | UPR associated with the event, when known |
| EntityNameID | INT, not null | Entity/table ID in REF_ENTITY_IDENTIFICATION.EntityID |
| EntityRecordID | BIGINT, not null | Row ID within that entity; composite/text keys use the existing registry |
| OperationType | NVARCHAR(20), not null | INSERT, UPDATE, DELETE, MERGE or STATUS_CHANGE |
| ChangedBy | NVARCHAR(100), not null | Database original login for generated row events |
| ChangedDate | DATETIME2(3), not null, default SYSDATETIME() | Event time |
| OldValues | NVARCHAR(MAX), nullable | Before-change row JSON |
| NewValues | NVARCHAR(MAX), nullable | After-change row JSON |

The new table has a clustered primary key and the pictured operation/future-date
checks (one-minute tolerance). Constraint names use a `_Client` suffix to avoid
collisions with constraints retained on archived tables. Existing matching
client tables keep their constraint names and datetime2 precision. The screenshot
is low resolution: new-table precision remains 3, matching the project's previous
DDL. The original CREATE TABLE text was requested but has not been supplied;
compare the schema diagnostic with that text before database acceptance.

The screenshot does not show a UPR foreign key. Main-table UPRID retains the event
association after deletion of a UPR. The compatibility view exposes live-only
UPRID and retained OriginalUPRID, preserving the prior report semantics.

## Supporting objects — explicitly disclosed

| Object | Why it exists / change |
|---|---|
| AUDIT_LOG_CONTEXT | **New companion table**, one row per AuditID: OriginalUPRID, EntityKey, RunID, SessionID and ChangeSummary. Retains prior audit context without adding columns to the client's main table. FK to AuditLog with cascade delete. |
| AUDIT_LOG | Changed from physical table to a **read compatibility view**. Joins the main event, context, live UPR and entity dictionary; exposes the prior normalized field names and report aliases. It is not the supported write interface. |
| REF_ENTITY_IDENTIFICATION | Existing entity-name dictionary. Main EntityNameID uses its existing EntityID values; no arbitrary remapping. |
| AUDIT_ENTITY_RECORD | Existing stable registry for composite/text row keys. Negative EntityRecordID values reference this registry, not negative property IDs. |
| UPR_LOAD_RUN | Existing run history, including failed and empty runs. |
| AUDIT_LOG_PreClientLayout | Retained prior normalized table, when that starting layout is migrated. |
| AuditLog_PreSept17 | Retained legacy table, when that starting layout is migrated. |

Two main-table indexes support entity/record and UPR lookups. Two companion-table
indexes support run and original-UPR filtering. Existing parcel-status lookup
index and Condo archive/closure migration remain part of the installer.

Generated triggers on 23 UPR model/reference tables write the main event and
companion context in the business transaction. Multirow statements pair each
new AuditID with its own context. The loader writes its summary using the same
split. Rollback removes both event and context; UPR_LOAD_RUN still records a
failed loader attempt. Direct inserts made by another application into AuditLog
have only the metadata that application supplies; context is not fabricated.

## Existing-history migration

The installer supports a fresh schema, the prior EntityName/EntityKey AuditLog,
the September 23 normalized AUDIT_LOG plus AuditLog view, and an existing client
nine-column AuditLog. Run it with database writers stopped. Migration and trigger
replacement are one transaction; errors roll back those changes. Reinstallation
does not copy archives again or duplicate current events.

Existing AuditIDs, dates, before/after values, raw keys and available run/session
metadata are retained. The existing closure registry spelling correction can
reconcile old AncestorUPRID registry references to the canonical UPRAncestry
reference; original event JSON remains unchanged. Source tables stay archived.

The installer stops for IDs outside INT range, overlapping/unrecognized audit
layouts, unmapped entity IDs, future timestamps that violate the supplied check,
or external foreign-key/schema-bound dependencies requiring explicit migration.
No IDs are truncated or guessed. Legacy tables lacking optional metadata gain
nullable columns in their archive so unavailable values remain NULL.

For an existing client-layout table, the corresponding entity dictionary must
already provide the actual EntityNameID mapping. Do not seed names in an arbitrary
order to invent that mapping. Historical rows without EntityKey, RunID or SessionID
retain NULL for those fields. The readable report shows, for example,
`[EntityRecordID] = 42 (original key not recorded)`; raw mode returns NULL.

Compatible explicit SELECT grants/denies are restored on the same public object
names and surviving column names. Removed-column grants are not broadened to
other objects. Custom writers and queries that expect extra columns on AuditLog
must adopt the main/context contract or read AUDIT_LOG/the report. Review custom
dependencies and application permissions during restored-database testing.
Column grant syntax follows [Microsoft's GRANT object permissions reference](https://learn.microsoft.com/en-us/sql/t-sql/statements/grant-object-permissions-transact-sql?view=sql-server-ver16).

## Apply the complete delivery

1. Restore a test copy; stop its writers and set the database in each script.
   Run `scripts/check_upr_client_schema.sql` and save the starting inventory.
2. Run the **latest** `scripts/install_upr_audit.sql`, even if the September 23
   installer was run previously. Do not run the destructive schema DDL on an
   existing client database.
3. Run `scripts/load_upr_master.sql` for the current incoming data. The new loader
   requires this layout. Follow the search guide's existing-account reconciliation
   rules if its preflight reports old truncated/formatted mappings.
4. Install `scripts/search_upr_master.sql`, `scripts/list_upr_hierarchy.sql` and
   `scripts/list_upr_audit.sql` from the same extracted package.
5. Run `scripts/check_upr_client_schema.sql`, `scripts/diagnose_upr_accounts.sql`,
   `scripts/check_sept17_acceptance.sql` and `test/run_test_and_results.sql`.
   Compare archived/current audit history, run reports and real source results.
6. On a disposable fixture database, run `test/run_local_it.sh` (Docker SQL Server)
   including the search assertions and new `test/check_audit_layout.py` migration
   checks. The migration regression uses repository revision `fce184f` as its prior
   version. Do not run sample/reset fixtures against client data.

```sql
-- Exact main-table layout supplied by the client.
SELECT TOP (100) AuditID, UPRID, EntityNameID, EntityRecordID, OperationType,
    ChangedBy, ChangedDate, OldValues, NewValues
FROM dbo.AuditLog ORDER BY AuditID DESC;

-- Human-readable explanation of the changed row; preserves existing output names.
EXEC dbo.usp_UPR_AuditReport @LatestRun=0, @IncludeFieldDetails=1;
-- Technical consumers can request the recorded JSON.
EXEC dbo.usp_UPR_AuditReport @LatestRun=0, @RawRecordKey=1;
```

## Validation status

See [combined results](WORK_RESULTS_2026-09-24.md). Local static/syntax validation
is available; **no SQL Server integration execution or production update has
occurred in this workspace**. The prepared regression covers both starting
layouts, history preservation, repeated installation, missing original keys,
unmapped IDs, INT overflow rollback, reader grants, multirow events and rollback
of paired context. Existing suites cover deletion, load failures and search.
