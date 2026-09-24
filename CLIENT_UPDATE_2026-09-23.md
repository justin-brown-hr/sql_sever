# September 17 review update — September 23 implementation

Package: `UPR_Corrections_2026-09-23_Review_Update.zip`.
Revised after a [client-perspective review](CLIENT_REVIEW_FEEDBACK_2026-09-23.md).
This supersedes the September 16 package. It is a **candidate for isolated database testing**:
static checks pass, but the updated SQL has not been executed against SQL Server in this
workspace. Docker, SQL Server, and sqlcmd are unavailable here. Earlier recorded integration
passes apply to the previous delivery, not this update.

## Changes

- Account `00050037`: the screenshot's three MA addresses plus the overlapping SDAT
  address should produce one Complex, three Buildings and three Units.
- Account `00261025`: normalize `BLV` to `BLVD`; its overlapping 13800 CASTLE address
  should likewise produce three Buildings and three Units.
- Preserve the distinct SDAT addresses in the two examples marked correct:
  `00050048` has seven Buildings/seven Units; `00272520` has four Buildings/four Units.
  These counts describe the document's visible inventories, not arbitrary future source files.
- A single blank MA row and a single blank SDAT row at the same account/group/full
  normalized address, with no numbered Units at that address, now share one Unit.
  MA supplies the blank convention (`N/A`) on fresh loads; an existing survivor
  retains its value. Both source identifiers remain.
  Multiple ambiguous blank rows remain separate. Real numbered Units still match by
  number within their Building, never across accounts or Buildings.
- The loader repairs previously generated blank-unit overlaps only when source links,
  parent structure and donor fields establish an unambiguous match. It keeps the MA
  Unit/Building IDs, moves source/contact/address/history links, and removes redundant
  nodes with before/after auditing. Enriched or incompatible records remain and receive
  an `AMBIGUOUS_CANDIDATES` review. Nonstandard database dependencies may reject and
  roll back a repair instead of allowing data loss.
- Remove `CONDO.CondoName` and `CONDO.Parcel`. The migration saves existing values in
  `UPR_CONDO_LEGACY` first. Archived named Condos continue to block automatic
  Condo-to-Complex reclassification. Condo name is removed from reports. Condo parcel search/display uses the archived
  value for existing Condos and loader history for new Condos, with provenance
  shown in the hierarchy report. PROPERTY.Parcel remains available.
- Rename `UPR_CLOSURE.AncestorUPRID` to `UPRAncestry` throughout current scripts.
  The ancestor/descendant relationships and root-depth `Level` meaning remain.
- The repository runner now defaults to upgrading the existing schema.
  Only explicit `--sample-data` resets tables; invalid modes stop before SQL runs.

## Audit contract

The document's detailed table specification takes precedence over its earlier
`EntityNameID`/`Entity_Name` wording. The physical event table is `dbo.AUDIT_LOG`,
referencing `dbo.REF_ENTITY_IDENTIFICATION(EntityID)`.

Events include `AuditLogID` (BIGINT), nullable `UPRID` FK, `EntityID`,
`EntityRecordID`, `ActionType`, date/user, and JSON old/new values. Indexes support
entity, UPR and run filtering. `ChangedBy` remains NVARCHAR(100) to retain Unicode
usernames. RunID, SessionID, ChangeSummary and complete EntityKey are retained.

Important identity cases:

- Ordinary numeric primary keys populate EntityRecordID directly.
- Composite/text keys receive stable negative IDs from `AUDIT_ENTITY_RECORD`;
  EntityKey retains the full original key. Closure registry keys use the new
  ancestry column name consistently across migration; original event JSON stays intact. A closure event cannot be identified by
  one of its key components alone.
- UPRID refers to a live UPR. On deletion, the FK becomes NULL; `OriginalUPRID`
  and old/new JSON preserve the UPR associated with the event. Reports can still
  find its history with `@UPRID`.
- Reference rows and shared/unlinked Addresses or Contacts have no single UPR;
  UPRID is NULL. Direct association-table events carry the affected UPR.
- Historical events retain their supplied fields. Unknown historical UPR attribution
  is not guessed. Legacy MERGE/STATUS_CHANGE action labels remain accepted for retained
  history; new row triggers emit INSERT/UPDATE/DELETE.
- A load summary uses the UPR_HIER_LOAD entity and EntityRecordID 0; RunID identifies
  that run. Summaries are excluded from the business-row report.

On upgrade, the original audit table is renamed to `AuditLog_PreSept17` and retained.
Its rows are copied once with their original audit IDs into AUDIT_LOG. Allow storage
for both copies, the new indexes, and the migration transaction log. `dbo.AuditLog` becomes a compatibility view for
old read queries. Existing explicit SELECT permissions are carried to that view;
legacy direct INSERT writers must adopt the new contract. Audit triggers cover the
previous 22 model/reference tables plus REF_ENTITY_IDENTIFICATION.

## Apply to a restored test database first

Stop concurrent loaders and application writers during migration. Take a database
backup and set the `USE` database name in each script that has one. The schema
diagnostic has no `USE`; select the intended database in SSMS for that file. Run the complete files in order;
stop if any file reports an error.

1. `scripts/check_upr_client_schema.sql` — save the initial schema inventory.
2. `scripts/install_upr_audit.sql` — atomic schema migration, history conversion and
   trigger installation. Requires database compatibility level 130 or higher.
3. `scripts/load_upr_master.sql` — load and guarded duplicate repair.
4. `scripts/search_upr_master.sql` — replace the stored search procedure.
5. `scripts/list_upr_hierarchy.sql` — inspect the hierarchy.
6. `scripts/list_upr_audit.sql` — install/run the latest-run audit report.
   It opens without field expansion; request details with the procedure parameters.
7. `test/run_test_and_results.sql`, `scripts/diagnose_upr_accounts.sql`, and
   `scripts/check_sept17_acceptance.sql` — save validation and source-link results.

Re-run the loader unchanged. Business counts and IDs should remain stable, with a
new run record and summary but no new business-row events. Confirm both source links
for each merged overlap and inspect any queued repair conflicts.

The installer also removes columns and renames a closure column, so application
queries outside this repository must be updated to the new schema. Reinstall the
supplied reports before resuming their use. Do not use the destructive DDL reset or
sample-data scripts against an existing database. They are excluded from the ZIP.

Example audit queries:

```sql
EXEC dbo.usp_UPR_AuditReport @LatestRun = 1;
EXEC dbo.usp_UPR_AuditReport @TableName = N'UNIT';
EXEC dbo.usp_UPR_AuditReport @UPRID = 123; -- includes retained deleted-UPR history
```

## Verification status

Passed here: static hierarchy checks, loader/schema contract checks, runner-mode tests, Python syntax,
SQL string/batch checks and whitespace checks. These do not replace database execution.

Added `test/check_sept17_review.py` to the integration runner. It uses the actual
September 17 commit to reproduce the old counts, then checks migration, both corrected
accounts, both correct examples, surviving MA IDs, preserved source links/history,
guarded repairs, deleted-UPR auditing, numbered-unit boundaries, and quiet reruns.
Unshown source IDs/types/CondoUnit fields in these screenshot fixtures are explicit
synthetic assumptions, not claims about the complete client data.

Run the full repository suite when a disposable SQL Server is available:

```bash
CONTAINER=<disposable-container> bash test/run_local_it.sh
```

The new suite has not yet run here. Client acceptance requires the corresponding
checks on a restored copy of the actual source/destination data.
