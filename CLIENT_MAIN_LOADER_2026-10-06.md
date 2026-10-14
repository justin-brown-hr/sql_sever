> Superseded by [October 8 R9](CLIENT_MAIN_LOADER_2026-10-08.md), which retains
> this audit behavior and corrects Condo units to use their linked Building parent.

# October 6 R8 — written AuditLog, UPR totals and readable values

Send **UPR_Main_Loader_2026-10-06_R8.zip**. It replaces R7 and contains:

1. `check_upr_client_schema.sql` — read-only schema and audit-writer diagnostic.
2. `load_upr_master_2026-10-06_R8.sql` — complete main loader.
3. `check_upr_audit_result.sql` — read-only audit reconciliation for one RunID.
4. `check_upr_closure_distance.sql` — read-only hierarchy/index verification.

The dated loader is byte-identical to `scripts/load_upr_master.sql`. Its first
line and Messages identify `UPR MAIN LOADER 2026-10-06 R8`. Use this file instead
of earlier open tabs. Do not run the legacy audit installer or schema recreation.

## Audit behavior

The main loader captures its INSERT, UPDATE and DELETE operations using OUTPUT
and writes individual audit entries to the existing `dbo.AuditLog`. It does not
require audit triggers or any new permanent support table. All 62 business DML
statements across 19 tables are covered, including UPR, entity tables, address/
contact links, identifiers, closure, review queue, status history and reference
rows inserted by the loader. Dictionary bootstrap is metadata setup, not a
business-row event. The loader's existing matching and hierarchy DML is unchanged.

Captured values are labeled text, for example:

```text
RunID = <run identifier>
UPRID = "207075"
ParentUPRID = "88788"
StatusCode = "ACTIVE"
```

OldValues contains the before-image on UPDATE/DELETE. NewValue contains the
after-image on INSERT/UPDATE. The other image is NULL for INSERT/DELETE. Values
include keys and the columns used by the loader; this is not a backup of arbitrary
custom columns. Null is displayed as `<NULL>`; literal strings are quoted, embedded
quotes doubled, and backslashes/line breaks escaped. ChangedBy/ChangedDate identify
the load user and batch timestamp. Column spelling and existing VARCHAR/NVARCHAR
types are preserved (NewValues remains supported for older project layouts).
The client's VARCHAR columns retain their existing database encoding limits.

EntityNameID uses the existing REF_ENTITY_IDENTIFICATION dictionary. Missing
mappings for the 19 audited tables and UPR_HIER_LOAD are seeded with validated IDs;
existing non-NULL IDs are preserved. Manual INT allocation is serialized with a
table lock held through the transaction. This can block other dictionary writers.
EntityRecordID is the native numeric table key (for example UnitID), while UPRID
is the associated UPR. **For UPR_CLOSURE, EntityRecordID is DescendantUPRID and the
complete AncestorUPRID/DescendantUPRID pair is included in the readable images.**
No negative registry IDs or new EntityKey column are introduced. Address/contact
records without a known unique UPR association keep UPRID NULL; link events retain
the association. Review rows can also have no UPR yet.

As requested, existing historical audit values are not rewritten or deleted.
All new loader audit images, batch summaries and returned details are readable
text rather than generated JSON. Unchanged UPDATE images are excluded. Each
successful run also writes one readable batch summary (EntityRecordID 0).

Auditing is scoped to statements in this loader. It does not install monitoring
for future API/manual writes or claim to capture independent trigger side effects.
Existing audit-writing, JSON-producing or unreadable triggers on affected tables
are reported before business loading; they are not disabled or replaced. Return
those trigger names/definitions for review to avoid duplicate/unreadable events.

## Statistics

Both Messages and the results grid include:

- UPR rows inserted, updated and deleted, based on captured row changes.
- Distinct UPR records inserted or updated, across parents, buildings and units.
- Total UPR records in the database after the load.
- Individual audit entries written and the separate batch-summary count.
- Per-table INSERT/UPDATE/DELETE counts, RunID, BatchAuditID and audit ID bounds.

An unchanged rerun may correctly report zero new UPR records while the database
contains many existing UPRs. Reused rows are not labeled as newly written. Repeated
changes to one UPR produce multiple events; the distinct-record metric counts that
UPR only once. Deletes are displayed separately.

## Run order

1. Select the intended test database and run the schema diagnostic. Resolve
   missing core columns, invalid audit mappings and audit-writer conflicts first.
   Absence of the old optional audit-support tables is supported.
2. Open the dated R8 loader, set its `USE` line to that same database and run the
   **entire file** in a dedicated session without an open transaction. No install
   audit step is needed. Save Messages and the summary grids.
3. After `UPR hierarchical load COMPLETE`, copy its RunID into the audit checker.
   Optionally enter the reported FirstAuditID/LastAuditID to limit scanning. Run
   the checker in the same database. Expect one batch summary, matching expected/
   actual row-audit counts, zero invalid mappings and zero unexpected JSON rows.
   The checker returns at most 50 readable examples, not the entire large run.
4. Run the closure checker with UPRID 207075. For the supplied chain, distances
   remain (24,207075,2), (88788,207075,1), (207075,207075,0).
5. Rerun with unchanged source data to verify stable business counts. Audit
   summaries are retained for every successful run.

Audit INSERTs are limited to 10,000 captured events per batch. Capture and writes
are set-based; only the 20 dictionary names are processed individually. Temporary
capture and persistent audit rows still consume tempdb and transaction-log space.
A 200,000-source-row load can generate substantially more than 200,000 audit events
because one source row can affect several entities and links. No SQL Server
throughput, elapsed time or storage requirement has been measured here.

Business changes and their new audit rows share one transaction. An audit failure
rolls back that transaction. Earlier helper-function/missing-column batches remain
outside it. There is no separate failed-run history table; retain Messages on a
failure. Existing closure column definitions/indexes remain intact except the
previously requested creation of missing pair/traversal indexes.

## Validation performed

- Microsoft ScriptDom parsed delivery scripts and rendered dynamic audit SQL.
- AST checks found audit capture on all 62 business statements across 19 tables,
  validated OUTPUT column bindings/arity against the project DDL, and confirmed
  business DML matches R7 after removing only audit OUTPUT.
- Schema/dependency, nullable-ID, payload-name, closure/index and runner checks passed.
- Actual audit text expressions passed local NULL, quote, backslash, CR/LF, Unicode
  and long-value cases. SQLite does not reproduce the client's VARCHAR encoding.
- A local SQLite correctness test wrote 200,000 synthetic audit events exactly
  once in 20 batches. **This is not a 200,000-source-row SQL Server benchmark.**

SQL Server integration cases cover native audit tables without support objects,
row IDs/UPR associations, repeated loads, readable new values, preserved history,
audit-insert rollback, conflicting triggers and closure repairs. An optional
`UPR_STRESS_ROWS=200000` case adds 200,000 MA rows and checks 222,000 resulting UPRs,
audit reconciliation and a stable rerun in a disposable database.
**These SQL Server integration/stress cases have not run:** no server or client
connection is available here. The client database test is still required.
