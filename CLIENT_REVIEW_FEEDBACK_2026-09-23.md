> This review describes the September 23 baseline. The refreshed package also
> includes [September 24 search changes](CLIENT_SEARCH_UPDATE_2026-09-24.md), pending SQL Server execution.

# Client-perspective review and correction guide — September 23

**Verdict: revised test candidate, not yet approved for production.**
I found and corrected issues in the first September 23 implementation. The ZIP
has been refreshed in place. Its manifest identifies the revised files; replace
the earlier extracted files as a complete set.

## Findings and fixes

| Client-visible issue | Correction | Verification available here |
|---|---|---|
| Removing `CONDO.Parcel` also removed Condo parcel search and made its displayed parcel disappear. | Search and hierarchy reporting now use the archived Condo parcel for migrated records, or the latest loader history for newly created Condos. The report labels the parcel's source. The removed column is not recreated. | Dependency review and schema checks passed. Archived/fresh Condo search cases added to SQL integration tests; execution pending. |
| A missing mode or mistyped `--real-data` option could run the schema reset. | The repository runner now defaults to upgrading existing data. Only explicit `--sample-data` runs the reset; unknown modes stop before any SQL call. | Executed a mock-sqlcmd test: default, real-data, explicit sample-data, and typo cases all pass. |
| Renaming the closure column changed its serialized composite key and could give one closure record two audit record IDs. | Registry keys use `UPRAncestry` consistently. Original historical event JSON remains intact. Reinstalling also reconciles registry IDs created by the earlier September 23 candidate. | Migration/data-flow review passed. Before/after record identity checks added to the SQL suite; execution pending. |
| Opening the audit report could return the entire retained history and every changed field. | Opening the script now shows the latest run without field expansion. Explicit procedure calls still support history, UPR/entity filters, and detailed field changes. | Call-site review completed; report integration checks updated. |
| A genuine Unit number resembling an internal blank-row key could collide with a blank Unit. | Numbered and blank Units now occupy separate matching groups, even if their internal string representations coincide. | Static/schema checks passed; focused database regression added. |
| The package required the client to manually reconstruct the document's acceptance checks. | Added `scripts/check_sept17_acceptance.sql`: account counts, paired MA/SDAT source IDs, destination IDs, review entries, and latest-run changes in one report. | SQL source review completed; fixture assertions added to the integration suite. |

The parcel fallback shows **retained values**, not a fresh live SDAT lookup. An
archived NULL remains NULL; historical data must not overwrite an intentionally
empty archived value. Later changes to source parcel data require the appropriate
load/update behavior; the original loader also populated these fields on insertion.

## Run and assess the revised candidate

Follow [the update guide](CLIENT_UPDATE_2026-09-23.md) on a restored test database.
Run the updated installer first, even if the initial candidate was already
installed, then run the loader and reinstall the search/audit reports.
The installer also adds an index for the history-based parcel lookup.

Run `scripts/check_sept17_acceptance.sql` after the first load and again after an
unchanged rerun. Select the intended database by editing its `USE` statement.
For `scripts/check_upr_client_schema.sql`, select the database in SSMS instead;
that diagnostic intentionally has no `USE` statement.

Compare the visible document examples:

| Account | Buildings | Units | What to inspect |
|---|---:|---:|---|
| 00050037 | 3 | 3 | MA and SDAT for 12201 VILLAGE SQUARE TER point to the same Unit. |
| 00261025 | 3 | 3 | 13800 CASTLE BLV/BLVD resolves to one Building and one Unit. |
| 00050048 | 7 | 7 | The distinct SDAT address remains represented. |
| 00272520 | 4 | 4 | The distinct SDAT address remains represented. |

These are screenshot-inventory counts. A match alone does not prove correct
routing, and a difference is not automatically a defect if the current source
file contains additional records. Check the source inventory and destination IDs.

A pair marked `REVIEW: SEPARATE RECORDS` may have been deliberately retained
because one existing record has manually maintained values or conflicting
relationships. Inspect the accompanying review queue before merging it manually.
Do not delete a record simply to force the screenshot count.

The latest run can still contain many events after a large first load. Use the
acceptance report for counts, and filter the audit procedure by table or UPR when
inspecting individual changes.

An unchanged successful rerun should show zero business-row changes. A failed
run with zero committed changes is still a failure: inspect RunStatus and
ErrorMessage. Save the first-load and rerun outputs separately.

## Verification and remaining limit

Completed here: static hierarchy checks, loader/schema contract checks, Python
and shell syntax checks, runner-mode behavioral tests, SQL lexical checks, and
ZIP byte/manifest verification.

The SQL integration suite still cannot execute here: Docker/SQL Server tools
are unavailable (`docker: command not found`). No successful execution of this
revised migration or loader on the client's database has been established.
The added SQL tests are prepared checks, not recorded passes.

Before acceptance, execute the full suite against a disposable SQL Server,
then inspect the account/source-link and rerun results on a restored client
database. The installer retains historical audit data and removed Condo values;
allow space for the archive, new event table/indexes and migration transaction log.
