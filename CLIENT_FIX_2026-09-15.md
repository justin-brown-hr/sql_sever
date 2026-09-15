# September 15: row changes for every load and later edits

Use `UPR_Audit_Corrections_2026-09-15.zip`. It includes the previous Unit,
AccountNumber and closure Level corrections.

## Run these scripts in order

Set the `USE` database name in each script, then run:

1. `scripts/install_upr_audit.sql` - upgrades existing auditing and preserves
   existing records. Run this updated version even if auditing is installed.
2. `scripts/load_upr_master.sql` - runs the load and displays its row changes.
3. `scripts/list_upr_audit.sql` - displays load history, changed rows, and
   individual fields with their old and new values.

No table rebuild or data reset is needed. Run the loader in a connection with
no open transaction.

## What the client will see

- One load-history record for each started run: its ID, start/end time, status,
  user, source/rejected row counts, and any failure message.
- One AuditLog event for each inserted, updated, or deleted row: table, record
  key, action, date/time, user, session, and full old/new row values.
- A shared RunID connecting a load to all its row events.
- Updates made outside the loader also appear, marked `Outside load`.
- A field view showing each changed column's old and new value. Inserts and
  deletes show all fields. NULL and empty strings remain distinct.

An unchanged rerun appears as completed with zero row changes. It still has
its batch-summary record; unchanged data is not represented as a new change.
An UPDATE statement that assigns the same values still has a row event, with
equal old/new values and no changed fields.

## Select the records to review

The report defaults to all retained history, including edits outside loads.
After running `list_upr_audit.sql` once, these commands are available:

```sql
-- Most recent load, including an unchanged or failed load:
EXEC dbo.usp_UPR_AuditReport @LatestRun = 1;

-- All recorded Unit changes, including edits outside the loader:
EXEC dbo.usp_UPR_AuditReport @TableName = N'UNIT';

-- A date range; the end time is exclusive:
EXEC dbo.usp_UPR_AuditReport @Since = '2026-09-15', @Until = '2026-09-16';

-- A specific run: replace the value with its actual RunID:
-- EXEC dbo.usp_UPR_AuditReport @RunID = 'paste-run-id-here';
```

## Coverage and existing history

Auditing covers INSERT, UPDATE and DELETE on the 22 UPR model/reference tables,
including UPR, UNIT, BUILDING, ADDRESS, contacts, XREF, closure and Review_Q.
Incoming staging tables and audit bookkeeping are excluded. Reads, schema
changes, and TRUNCATE are not row-change events captured by these triggers.
Bulk-import tools must be configured to fire triggers when writing model tables.

Existing audit records are preserved. Older records have no RunID unless it
was captured at the time; the report labels them `Earlier audit (run unknown)`.
Past changes made before auditing was installed cannot be recovered by this upgrade.

On failure, business writes and their row events roll back together; the run
record remains marked FAILED with its error. An interrupted connection/server
can leave a RUNNING record without a finish time, which should be reviewed.
Audit values are stored in full. Export/report tools may impose their own display
limits. The field view uses OPENJSON and requires database compatibility level
130 or later; lower levels still show the complete stored row values.
See Microsoft's [OPENJSON documentation](https://learn.microsoft.com/en-us/sql/t-sql/functions/openjson-transact-sql)
for the compatibility requirement.

## Verification

Verified on an isolated SQL Server 2022 instance: 43 hierarchy checks on both
loads, 16 client validation checks, and all existing source, listing, audit and
closure regressions passed. The new audit tests and updated diagnostics passed.

See `test/check_audit_runs.py` for upgrade preservation, run attribution,
unchanged-run reporting, manual edits, field values, failure history and
caller-transaction checks. The full integration runner includes these tests
alongside the hierarchy, source-data, closure and audit-trigger regressions.
