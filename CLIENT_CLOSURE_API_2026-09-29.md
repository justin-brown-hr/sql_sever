# Preserve the original UPR_CLOSURE API contract — September 29, 2026

Historical notes: the later client clarification changed Level to pair distance.
Use [the October 2 main-loader delivery](CLIENT_MAIN_LOADER_2026-10-02.md) for the
current contract and test instructions. The interpretation below is superseded.

The client's latest instruction supersedes the earlier column rename. Keep the
existing physical `dbo.UPR_CLOSURE` table with `AncestorUPRID`, `DescendantUPRID`
and `Level`. Stored Level continues to mean the descendant's depth from its root.
The level-0 report correction does not require a table change or API field rename.

## What the client should run now

Select the intended database in SSMS. These two files have no USE statement and
work with the existing client table; no audit installation or loader run is needed
for this report test.

1. Run `scripts/list_upr_ancestor_path.sql` with `@UPRID = 207075`. It displays each
   ancestor's own depth from the root, ordered by Level. A depth-2 record should
   show its root at 0, its parent at 1, and itself at 2.
2. Run `test/check_descendant_level0.sql` with the same UPRID. It verifies the
   original API column names and compares the displayed path with an independently
   calculated path from `dbo.UPR.ParentUPRID`. Expected output: one PASS row with
   the root UPRID, then the ancestor path starting at Level 0.
3. Return both result sets or the exact error. The test uses temporary tables only;
   it does not update client data. If the test fails, it makes no repairs.

The raw `SELECT * FROM UPR_CLOSURE WHERE DescendantUPRID = 207075` still shows the
stored descendant level on every row. To display each ancestor's own level, use
the corrected report query. The report's Level describes the node identified by
AncestorUPRID; its DescendantUPRID remains the selected record. No dummy level-0
row is inserted. The existing table and stored values retain their meaning.

## Full script-set changes

- Fresh-test DDL, loader, search/Property360, hierarchy report, source diagnostics
  and validation queries now use the original `AncestorUPRID` name.
- The audit installer no longer renames an existing `AncestorUPRID` column.
  If a previous candidate was already installed with only `UPRAncestry`, the full
  installer restores that column's name to `AncestorUPRID` in its transaction and
  regenerates its managed audit triggers. It preserves the table object, column
  position, closure rows and stored levels. If both names exist it stops.
- Historical audit JSON keeps whichever column name it originally recorded.
  Closure registry references using the abandoned candidate spelling are reconciled
  to the original spelling so new row events use the current key. This concerns
  audit metadata, not UPR_CLOSURE relationship data.
- The standalone ancestor report can also read `UPRAncestry` on a database still
  using that candidate, without renaming anything. The new client test deliberately
  requires `AncestorUPRID`, because that is the requested API contract.

For the complete search/audit update, replace the extracted script set together
and follow the latest audit installation order on a restored database. If a
previous candidate changed the column name, stop writers and reinstall the
updated installer, loader and query procedures together; existing custom modules
using the candidate name also need review. The installer includes other previously
requested audit/Condo changes, so it is **not required for the read-only level-0
check**. Never run the destructive fresh-schema DDL on an existing client database.

## Verification status

The hierarchy static checks, loader/schema contract checks, runner-mode checks,
modified Python syntax checks and whitespace checks passed locally. The extracted
ancestor query and root/self-row guards were exercised with both column spellings
using SQLite fixture data (14 checks). This validates the SELECT projection, not
SQL Server's batch execution or API integration.

The SQL Server regression now also checks that installation leaves the original
closure table object/columns in place, a prior candidate can restore its name
without changing closure rows/levels, repeated installation is stable, and the
client's read-only test passes for a known fixture descendant. These SQL Server
checks are prepared but **not executed here**: no SQL Server/sqlcmd/Docker runtime
is available. No client database or API has been modified by this workspace work.

The historical full release is retained at
`archive/deliveries/UPR_Corrections_2026-09-23_Review_Update.zip` for comparison.
The superseded reply was removed during October 2 cleanup. Use
[the current main-loader delivery](CLIENT_MAIN_LOADER_2026-10-02.md) and
`CLIENT_MESSAGE_2026-10-02.txt` for the current test.
