# Descendant lookup and level 0 — September 28, 2026

> Latest September 29 contract: [retain the original AncestorUPRID API column](CLIENT_CLOSURE_API_2026-09-29.md).
> The level-0 display test is read-only and does not change UPR_CLOSURE.

The client asked why filtering `UPR_CLOSURE` by descendant 207075 shows no level 0,
while filtering by an ancestor shows level 0. The screenshot uses the earlier
column name `AncestorUPRID`; the latest scripts use `UPRAncestry`.

## Why the two results differ

The previous requirement defined stored `UPR_CLOSURE.Level` as the **descendant's
depth from the hierarchy root**. Every path to the same descendant therefore
has the same stored level. A descendant at depth 2 produces level 2 for its
root-to-descendant path, parent-to-descendant path and self-link. The root may
already be present in the ancestry column; its row's Level still refers to the
selected descendant. It does not mean that the root was excluded.

An ancestor filter returns different descendants. When that ancestor is the
root, its results include the root's self-link, whose descendant is itself at
level 0. That explains the different appearance in the screenshot.

The available prior specification and session notes explicitly use root depth.
This correction preserves that definition and displays **each ancestor's own
root level** in the ancestor-path report. Level 0 continues to mean the top-level
root. Making the selected record itself level 0 would be a different meaning
(distance from the selected record), not the existing hierarchy-level contract.

Illustration for a root -> parent -> selected descendant at depth 2 (not captured
client database output):

| Ancestor shown | Raw stored descendant Level | Corrected ancestor-report Level |
|---|---:|---:|
| Root | 2 | 0 |
| Immediate parent | 2 | 1 |
| Selected descendant itself | 2 | 2 |

## Apply the query correction

Open `scripts/list_upr_ancestor_path.sql` in SSMS, select the intended database,
and execute it. Its editable `@UPRID` is set to 207075 for the reported case.
It returns Level, the detected ancestry column, and DescendantUPRID, ordered
from root to selected record. It supports both column spellings automatically.

This is a read-only query file, with no new persistent object. It joins each path
ancestor to that ancestor's self-row to display the ancestor's own level.
Missing root/self rows or a root self-row without level 0 cause a diagnostic
error instead of silently hiding the root. Run after the loader has refreshed
the closure table; the report does not repair stale hierarchy data.

The original `SELECT * ... WHERE DescendantUPRID = 207075` will still return the
stored descendant levels. Use this corrected query to display ancestor levels.
No dummy level-0 rows are inserted and no UPR relationships or stored levels are
changed. Existing search, Property360 and the full hierarchy listing retain their
previous meanings. The loader change in this follow-up is only an explanatory
comment linking to the new report.

## Validation and delivery

- Executed the report's actual SELECT/EXISTS expressions in SQLite against six
  fixture nodes, including two roots and depth 3, under both column spellings:
  14 checks passed, including a missing-root-self-row diagnostic.
- Existing hierarchy static and loader/schema contract checks passed.
- Extended `test/check_closure_levels.py` to verify root/child/deep ancestor
  output against independent ParentUPRID traversal, both column spellings, and
  read-only behavior. Python syntax passed.
- **SQL Server integration remains unexecuted**: this workspace has neither
  sqlcmd nor a Docker/SQL Server runtime. SQLite checks do not validate T-SQL
  execution, object binding or behavior on the client's database.

The existing `UPR_Corrections_2026-09-23_Review_Update.zip` is refreshed in place
with this report and note, retaining the earlier three-work delivery. This query
can also be used alone with the client's earlier schema; the AuditLog migration
is not a prerequisite for it. The separate follow-up client draft is
`CLIENT_MESSAGE_2026-09-28.txt` and has not been sent externally.
