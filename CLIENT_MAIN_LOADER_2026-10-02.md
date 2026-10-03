# Main loader R2 — client schema correction, October 2, 2026

Send `UPR_Main_Loader_2026-10-02_R2.zip`. It replaces the earlier October 2 ZIP,
which assumed audit-extension objects the client had not installed.

The ZIP contains exactly three files, in run order:

1. `check_upr_client_schema.sql` — read-only diagnostic of 170 columns across 26
   tables, plus actual layouts, constraints and triggers.
2. `load_upr_master.sql` — complete corrected main loader.
3. `check_upr_closure_distance.sql` — read-only hierarchy and index verification.

The extra diagnostic file addresses the reported schema mismatch; no installer,
fresh-schema DDL, search script or standalone repair is needed for this delivery.

## Correction for the reported missing objects

The screenshots show editor diagnostics around `UPR_CONDO_LEGACY`,
`AUDIT_LOG_CONTEXT`, `UPR_LOAD_RUN` and the `AUDIT_LOG` compatibility view. They
do not show the complete 46-item list or SQL Server execution Messages.

The loader now supports the existing nine-column physical `dbo.AuditLog` and
`dbo.REF_ENTITY_IDENTIFICATION` without those extensions. Optional archive,
context and run-history objects are referenced through guarded dynamic SQL only
when installed. The `AUDIT_LOG` view is no longer used. The loader creates no
permanent audit-support tables and does not install, replace or disable triggers.
An incomplete existing project audit-trigger installation causes a clear stop;
the loader does not suppress its errors by disabling auditing.

A batch summary, including counts and a generated run ID, is saved as JSON in
`AuditLog.NewValues`. The existing entity dictionary's `UPR_HIER_LOAD` entry
identifies that summary. If absent, the loader adds that one dictionary record
only when other required fields have generated values/defaults; it never guesses
an EntityID. `EntityRecordID = 0` denotes the batch summary, not a UPR row.
These are recorded values in existing tables; no EntityKey or RunID column is
added to AuditLog. ChangedBy is limited to the client's 100-character column.

Existing row-audit triggers and audit history remain in place. Without optional
context, run-scoped row-change details report NOT_AVAILABLE; they are not inferred
from AuditID ranges or presented as zero changes. Without optional run history,
failed runs return their error in Messages and roll back the load transaction;
no separate failed-run history table is created. Batch insertion counts are not a
replacement for complete row-level audit coverage.

Condo reclassification checks existing live CondoName/Parcel values when those
columns exist, plus archived names when the optional archive exists. Records with
such values are protected from automatic Condo-to-Complex conversion, avoiding
loss of legacy details merely because an archive was never installed.

The existing loader still maintains its normalization functions, reference codes,
and any previously supported missing CondoUnit/Level columns. This release does
not claim the whole loader is free of schema changes: closure index creation is
explicitly part of the client's request. AuditLog's layout remains unchanged.

## What is fixed in the main script

Step 12 starts every self path at 0 and extends a path using its prior distance
plus 1. This is the same distance calculation as the client's recursive CTE.
It builds expected paths from ParentUPRID, updates incorrect distances, adds
missing paths and removes stale paths. It does not truncate the table or append
another complete copy on every run. Unchanged paths do not generate update events.
The root traversal rejects cycles and unreachable/missing parents before path
generation. Existing table/column names remain AncestorUPRID, DescendantUPRID, Level.

For the supplied chain, a direct descendant filter should return:

| Level | AncestorUPRID | DescendantUPRID |
| ---: | ---: | ---: |
| 2 | 24 | 207075 |
| 1 | 88788 | 207075 |
| 0 | 207075 | 207075 |

The supplied CTE is valid distance logic, but its INSERT alone is not rerunnable
against populated closure data. Without pair uniqueness it can append duplicates;
with uniqueness it fails on existing pairs. MAXRECURSION 0 also does not detect a
cycle. The main loader retains its validation and transactional synchronization.

## Index behavior

| Purpose | Keys | Main-loader behavior |
| --- | --- | --- |
| Prevent duplicate pairs and support ancestor-first tree queries | UNIQUE (AncestorUPRID, DescendantUPRID) | Reuses the composite PK or an equivalent active unfiltered unique index; otherwise creates UX_UPR_CLOSURE_AncestorDescendant with Level included. |
| Support reverse traversal from a descendant to its ancestors | (DescendantUPRID, AncestorUPRID) | Reuses an active unfiltered index with these leading keys; otherwise creates IX_UPR_CLOSURE_Descendant with Level included. |

Uniqueness belongs to the pair, not either ID individually. A second unique
constraint in reverse key order is unnecessary: the forward constraint already
prevents duplicate pairs regardless of query direction. The reverse index serves
lookup performance. Included Level is not part of the unique key, so a different
Level value cannot permit a duplicate pair.

The script checks actual index definitions, not just names. Filtered, disabled,
hypothetical or insufficient indexes do not satisfy the relevant check. Forward
uniqueness must reject duplicates, not silently ignore them. If a needed index
name is occupied by an incompatible definition, the load stops for review rather
than overwriting an unknown index.

Existing duplicate pairs are reported (up to 20 examples) before business loading
and stop the load. They are not silently deleted. New index creation occurs
within the load transaction, after any legacy Level column backfill, and rolls
back if that transaction fails. Equivalent indexes are reused on repeated loads.

## Repeating local syntax validation

With .NET 8 installed, run from the project root:

```sh
dotnet run --project test/tsql_parser/SqlSyntax.csproj -- ddl/03_new_upr_schema.sql scripts/*.sql test/*.sql
python3 test/schema_contract_check.py
python3 test/check_client_schema_dependencies.py
```

The first command restores the pinned Microsoft parser package. The validator and
its build dependencies stay local and are not included in the client ZIP.

## Client run instructions

1. Select the intended restored test database in SSMS. Run the entire
   `check_upr_client_schema.sql` and save all results. Optional extensions marked
   missing are supported; missing core tables/columns need comparison with the
   actual client schema before loading. Continue only after resolving any
   CORE_MISSING result. A names-only PASS is not certification of types, data,
   permissions, custom constraints or trigger behavior.
2. Change `USE UPRXDB_TEST;` in `load_upr_master.sql` to that same database.
   Run the complete file in a dedicated session with no open transaction.
   This is a full source load. Do not run the fresh-schema DDL or install an audit
   migration to resolve the optional-table diagnostics.
3. If execution fails, return the full Messages output and schema diagnostic
   results. Do not truncate closure or recreate the database to bypass errors.
4. After successful completion, run `check_upr_closure_distance.sql` in the same
   database with `@UPRID = 207075` (or another known UPR). It verifies stored
   relationships, distances and index definitions against ParentUPRID.
5. Repeat the main load and verification with unchanged input. Business rows and
   closure pairs should stay stable; each successful run adds a batch summary.
   Return both summaries and verification results for review.

No API code is included. The client reports fixing their API separately. A full
property tree starting from a unit also requires endpoint logic to resolve its
root and retrieve that root's subtree; closure distances alone do not implement
that endpoint behavior.

## Validation performed here

The additional review requested after packaging found no SQL syntax errors. It
strengthened the diagnostic beyond the original audit-only checks and corrected
the local INSERT checker to include statements that omit the optional INTO keyword.
The loader itself did not need another change during this review.

- Microsoft's ScriptDom parser (161.9142.1, SQL Server 2019 grammar) passed all
  22 current SQL files under ddl/scripts/test, plus 12 literal dynamic-SQL batches.
  This includes the main loader's eight dynamic batches. Assembled SQL variables
  are not covered by the literal-batch check. Parsing does not bind database names
  or execute statements.
- The client diagnostic covers every statically referenced core table and every
  INSERT/MERGE target column. It checks 170 columns over 26 core/optional tables,
  distinguishes optional absence from missing core columns, and returns full
  physical types/defaults plus constraints/triggers for comparison.
- The strengthened schema-contract check passed 51 INSERT statements, five
  MERGEs, five OUTPUT mappings and 37 INSERT/SELECT column-count checks.

- Static hierarchy, schema-contract, runner-mode, Python/shell syntax and diff
  checks passed.
- Dependency checks passed: no static references to the absent extension objects,
  no permanent-table creation or trigger removal/disable statements in the loader.
- Offline cases passed for live/archived Condo protection, including no archive.
- Actual closure SELECTs and independent upward verification passed offline
  fixtures containing 229 nodes and 6,068 paths, including the 207075 example,
  deep trees, cycles and missing parents.
- Index-selection and duplicate-pair checks passed offline catalog/SQLite cases.
- A SQL Server regression was added for the native client layout without support
  tables, preserved custom triggers/history, repeated loads and enhanced audit
  operation without the compatibility view. It has not been executed here.
- SQL Server execution remains pending: no SQL Server/docker/sqlcmd runtime is
  available. Offline checks do not establish SQL Server compilation, trigger,
  DDL, lock or rollback behavior. No client database was accessed or changed.

The visible dependencies are corrected. Confirmation that every reported
client diagnostic is resolved requires the actual schema and SQL Server test.
