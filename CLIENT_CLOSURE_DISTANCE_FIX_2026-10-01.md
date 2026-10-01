# UPR closure distance correction — October 1, 2026

The client's raw-table screenshot confirms a loader defect under the clarified
contract: Level must count parent links from AncestorUPRID to DescendantUPRID.
The previous loader copied descendant root depth into every pair. The earlier
ancestor report only changed the display; it did not correct stored values.
The earlier suggestion that this might be API-only was incomplete.

For the supplied chain, the corrected raw rows must be:

| Level | AncestorUPRID | DescendantUPRID |
| ---: | ---: | ---: |
| 2 | 24 | 207075 |
| 1 | 88788 | 207075 |
| 0 | 207075 | 207075 |

The correction derives distances from actual ParentUPRID links across the entire
table, not these hard-coded IDs. The table name, column names/types/order and
relationship pairs remain unchanged. It does not modify UPR parent links or UNIT
identifiers. Root-to-descendant distances continue to match absolute tree depth.

## Review of the client's subsequent “Bigger Picture” explanation

The diagnosis and distance examples are correct and match the prepared repair
and loader changes. Walking upward from each descendant or extending downward
from each ancestor yields the same closure pairs and distances in a valid
single-parent tree. The loader uses downward expansion; the independent verifier
walks upward. It is not necessary to rewrite the loader to walk upward.

Three qualifications matter:

- Keep the physical column named `Level` for the current API contract. Document
  it as relationship distance. `Depth` is a reasonable future name, but renaming
  it now could break queries and response mappings. A future rename requires a
  coordinated migration; it is not part of this repair.
- This establishes a population defect for the observed stored values. It does
  not prove all API behavior is correct. Endpoint direction, identifier mapping
  and response interpretation remain independently testable concerns.
- Correct distances alone do not make a unit request return the complete property
  tree. The service must resolve the selected unit's root and fetch that root's
  descendants, preserving access controls and marking the selected UPR. The
  current local Property360 mode still returns the selected node's ancestors and
  descendants, not all sibling branches. The two-file repair does not implement
  or claim to validate the client's full-tree endpoint.

For the stated chain, `24` has child `88788`, which has child `207075`. The
client's first small ASCII diagram indents both nodes equally, but their explicit
chain, tables and distance examples make the intended relationship clear.

## Send only the new two-file ZIP for this test

`UPR_Closure_Distance_Fix_2026-10-01.zip` contains:

1. `repair_upr_closure_distance.sql`: transactional update of incorrect Level
   values. First checks all UPR nodes form rooted trees and that the closure pairs
   exactly match ParentUPRID. Missing/extra pairs, cycles or missing parents stop
   the repair. A post-update check runs before commit. Repeated repair updates zero
   rows when values are already correct. Existing audit triggers remain active.
2. `check_upr_closure_distance.sql`: read-only, independent upward parent-chain
   verification of all closure pairs and distances. Shows raw results for 207075,
   separately labelled TreeLevel/HierarchyDistance, and UPR-to-UnitID mapping.

Do not send the earlier September 29 level-0 report ZIP as the data correction.
Other historical ZIPs have not been rebuilt and do not contain this fix.

## Client test order

1. Use a restored test copy of the API database. Select it in SSMS. Run outside an
   existing transaction and with loaders paused while testing; the scripts hold
   locks while validating the hierarchy.
2. Run the entire repair file. It should return PASS and the actual UpdatedRows.
   If it reports a path/parent mismatch, send that error for review; do not change
   ParentUPRID merely to force the expected screenshot.
3. Run the entire verification file with `@UPRID = 207075`. It should return PASS
   and the three raw rows above if the supplied parent chain is present.
4. Query the table directly and retest `/api/upr/207075/ancestors`. Compare values
   and identifier direction. The package does not modify endpoint code, mappings
   or caches; any remaining response mismatch needs the deployed endpoint query.
5. Before resuming normal loads, apply the loader correction below. Otherwise an
   old load will put the wrong values back. Repeat verification after the next load.

```sql
SELECT [Level], AncestorUPRID, DescendantUPRID
FROM dbo.UPR_CLOSURE
WHERE DescendantUPRID = 207075
ORDER BY [Level] DESC, AncestorUPRID;
```

## Permanent loader correction

The local `scripts/load_upr_master.sql` Step 12 is already corrected. To avoid
replacing the client's unrelated customizations, apply the equivalent small edits
to their active version before the next load:

- Seed each self path with `SELECT UPRID, UPRID, 0 FROM #UPRLevels;` instead of
  taking the root-depth Level from #UPRLevels.
- Extend paths with `SELECT c.AncestorUPRID, child.UPRID, c.[Level] + 1` instead of
  taking the child's root depth. Keep the child-to-parent join and duplicate guard.
- Remove the unused `#UPRLevels l` join from this extension SELECT. Keep the earlier
  root traversal that checks for cycles and missing parents.

The repair header repeats these instructions. The ZIP updates existing data; it
cannot automatically edit whichever loader file/job the client has deployed.

## Why related local files changed

Zero-valued self rows mean consumers must stop using self.Level as root depth.
The local ancestor report now uses root-to-ancestor paths. Property360 obtains
root depth from root-to-node paths. Search chooses the closest authorized
Property/Complex by ascending pair distance. Output interfaces are retained.
The hierarchy listing calculates its own depth; only its explanatory comment
changed. DDL has a corrected comment, not a schema migration.

Existing deployed consumers should be checked for assumptions about self.Level.
The two-file ZIP does not reinstall search, audit or schema scripts. Tests and
fixtures were updated locally to verify the new meaning. No new address-search
features or API endpoints were introduced in this correction.

The UNIT screenshot confirms a detail row exists for UPRID 207075. Its earlier
`/api/unit/207075` null response remains a separate investigation: UnitID and
UPRID are different fields, and the endpoint's identifier contract is unknown.
Use the verification output to identify the linked UnitID; do not change IDs.

## Validation and limits

- Static hierarchy, schema-contract and runner-mode checks passed.
- Actual relational SELECTs were exercised in SQLite against an independent
  parent-chain oracle: 229 nodes / 6,068 paths, including the exact 207075 example,
  multiple roots, direct root children and a chain beyond 100 levels.
- Verified upward traversal and cycle detection, report root levels under both
  old/new closure meanings and both historical ancestry-column spellings, and
  search's nearest authorized Property and Property360 root-depth projections.
- SQL Server integration assertions cover data repair, unchanged table identity
  and parent links, idempotency, rollback on missing paths/cycles, and report/API
  projections. They are prepared but not executed: no SQL Server runtime is
  available here. SQLite does not validate T-SQL batches, transactions or triggers.
- No client database change or API deployment has occurred. No client PASS result
  or UpdatedRows count has been fabricated. Verification against ParentUPRID does
  not prove that every parent assignment matches the real-world property source.
