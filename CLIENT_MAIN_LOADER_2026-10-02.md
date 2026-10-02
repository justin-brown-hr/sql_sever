# Main loader with closure distances and indexes — October 2, 2026

Send `UPR_Main_Loader_2026-10-02.zip` for the client's requested main-script test.
It contains exactly two files, in run order:

1. `load_upr_master.sql` — the complete updated main loader.
2. `check_upr_closure_distance.sql` — read-only hierarchy and index verification.

This supersedes the October 1 standalone repair delivery for the current request.
No separate Level repair or manual Step 12 edits are needed with this loader.
No API changes are packaged; the client reports fixing their API separately.

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

## Client run instructions

1. Use a restored test database with the existing UPR schema, source tables and
   audit prerequisites used by the main project loader. Change the loader's
   `USE UPRXDB_TEST;` line to that database. Run the entire main file in SSMS using
   a dedicated session with no open transaction. This performs a full source load.
2. If the main script fails, share the first error and any duplicate-pair output.
   Do not truncate closure or recreate the schema to bypass the error. Existing
   audit prerequisites are checked by the loader; no new audit installer is
   included in this delivery.
3. After successful completion, select the same database and run the entire
   verification file with `@UPRID = 207075` (or a known UPR in that test copy).
   It checks indexes plus all closure paths/distances against ParentUPRID and
   shows actual stored rows, tree levels, distances and UnitID mapping.
4. Run the main loader again with unchanged input, followed by verification.
   Paths, values and indexes should remain stable without duplicate pairs.
5. Share both loader summaries and verification results. The API can then be
   checked against those stored results using the client's corrected endpoints.

## Validation performed here

- Hierarchy static checks, schema-contract checks, runner-mode checks, Python
  syntax and shell syntax checks passed.
- Actual closure SELECTs and independent upward verification passed offline
  fixtures containing 229 nodes and 6,068 paths, including 207075 and depth >100.
- Actual index-selection predicates passed simulated catalog cases for valid PKs,
  included columns, reverse indexes, and rejection of filtered/disabled/incorrect
  keys. SQLite pair uniqueness rejected a duplicate with a different Level while
  allowing repeated ancestors and descendants in different pairs.
- SQL Server integration cases were added for existing-PK reuse, automatic
  creation of missing indexes, stable repeated runs, duplicate insert rejection,
  and stopping on pre-existing duplicates without retaining business changes.
- SQL Server execution remains pending: docker/sqlcmd/SQL Server are unavailable
  in this workspace. Offline tests do not validate SQL Server DDL, locks, triggers
  or transaction rollback. No client database was accessed or changed.

The client ZIP excludes fresh-schema DDL, audit/search installers, historical
repair files and draft proposals. Local fresh DDL was aligned to include Level
in a newly created reverse index; it is not needed for this existing-database run.
