# September 14 corrections

Answers and fixes for today's 5-point review. Apply `scripts/load_upr_master.sql`
the same way as the September 10 package: install auditing first (or confirm it
is already installed - see point 1 below), then run the loader. No schema rebuild
is needed. The follow-up closure change below adds and fills `UPR_CLOSURE.Level`
automatically when the loader runs.

## 1. "No AuditLog records written except for 1 record"

Not a bug in the current scripts - `scripts/load_upr_master.sql` already refuses
to run at all if auditing is not installed (`Error 50004: Run
scripts/install_upr_audit.sql before loading data.`), so a successful load can
only happen with the row-level triggers already active.

The "1 record" is the batch-summary row the loader always writes to `AuditLog`
itself. When incoming data is unchanged since the previous run, the loader is
designed to add **no new business rows** - so a rerun correctly produces only
that 1 summary row. This is very likely what happened: the account/address data
had already been loaded once (possibly with an earlier version of the scripts,
before this month's corrections), and a later run - after auditing was
installed - found nothing new to write.

Row-level auditing cannot be created retroactively for changes made before it
was installed; only auditing going forward is possible.

`scripts/diagnose_upr_accounts.sql` now prints an **Audit coverage summary**
(read-only) with trigger count, row-level vs. batch-summary row counts, and the
earliest audit event vs. the earliest UPR row - run it to see whether auditing
is installed for all 22 tables and how far back its coverage goes.

## 2. Never MA-7479 / SD-7123 (or any invented) UnitNumber

Fixed. `scripts/load_upr_master.sql` now repairs **any** leftover
`MA-<id>` / `SD-<id>` legacy label it finds on `dbo.UNIT`, even if the exact
source row that produced it is no longer in the current incoming batch (the
previous repair only fired when that exact row was present). Nothing is
invented in its place - see point 3 for what is stored instead.
`scripts/diagnose_upr_accounts.sql` also lists any such label still present, so
you can confirm zero remain in your database.

## 3. Every unit-eligible record gets a Unit table row

Fixed - this was the cause of `00086862` (and others) missing from `dbo.UNIT`.
Previously, a MultiFamily/Apartment/Condo record with no incoming unit number
was silently skipped entirely: no Unit row was written for it at all. Now every
such record gets one, distinguishing two different situations:

- **A Condo/SDAT record with an AccountNumber but a blank `CondoUnit`** - the
  Unit row is still created, and `UnitNumber` is recorded as whatever the
  source actually had (NULL when the source field is empty). The column exists
  on that record type; we record its real value, we do not substitute one.
- **An MA MultiFamily/Apartment record counted as a unit within its building or
  Complex address, where MA has no unit-number field for it** - the Unit row
  is created with `UnitNumber = N'N/A'`. This is a literal marker meaning "no
  such field exists to report," distinct from a real blank value (NULL) on a
  Condo record. Never an invented number or label.

This also fixed a related idempotency issue the change surfaced: re-running the
loader with unchanged data no longer creates duplicate Units for these records,
and duplicate incoming rows for the same real unit number still correctly
share one Unit (unaffected by this fix).

## 4. Reject any record with no AccountNumber

Fixed. Previously, an incoming record with a usable address but no
`AccountNumber` was still written to UPR (as a Property/Condo) in addition to
being flagged in `UPRMATCHREVIEW_Q`. Now: **any incoming record without an
AccountNumber is rejected outright** - written only to `UPRMATCHREVIEW_Q`
(reason `INSUFFICIENT_DATA`) and never inserted into UPR, regardless of
address, property type, or CondoUnit value.

## 5. Purpose of RootAccount and RootUPRID in the listing

`scripts/list_upr_hierarchy.sql` walks each top-level parent (Complex, Property,
or Condo) down through every Building/Unit/ADU beneath it in one flat result
set, one row per UPR record at any depth. `AccountNumber` on a row is that
record's **own** account, which is populated only on the top-level parent row
itself - a Building or Unit row's `AccountNumber` is NULL, because accounts are
assigned to parents, not to their Buildings/Units.

`RootUPRID` and `RootAccount` are copied down onto **every descendant row**
from its top-level ancestor, precisely so a Building or Unit row - whose own
`AccountNumber` is NULL - still tells you which account/parent it ultimately
belongs to, without a separate lookup or recursive join. They let you filter or
group the flat listing by "everything under this account" directly.

## 6. Follow-up: UPR_CLOSURE layout and Level

`UPR_CLOSURE` now has `AncestorUPRID`, `DescendantUPRID`, and `[Level]`.
Level follows the hierarchy report's `LevelNo`: the descendant's depth from
its top-level root, starting at 0. It is derived from `UPR.ParentUPRID`, not
from an entity's name or type. A Unit directly below a Condo is level 1;
a Unit below that Condo's Building is level 2.

The ancestor is the UPR above the descendant, possibly several generations
above. The descendant is the child/grandchild's `UPRID`. `ParentUPRID` on
that descendant is its **immediate parent**, so it is not the descendant ID.
Existing column names and all ancestor paths are retained for search and
account lookups. Self-links are also retained.

For example, Complex 100 -> Building 200 -> Unit 300 stores:

| AncestorUPRID | DescendantUPRID | Level |
|---|---|---|
| 100 | 100 | 0 |
| 100 | 200 | 1 |
| 200 | 200 | 1 |
| 100 | 300 | 2 |
| 200 | 300 | 2 |
| 300 | 300 | 2 |

Here Level always describes the descendant's report level, including self-links;
it is not the number of steps from the particular ancestor in that row.
To see one row per UPR with the root, immediate parent, and descendant:

```sql
SELECT c.[Level], RootUPRID = c.AncestorUPRID,
       d.ParentUPRID, c.DescendantUPRID, RootAccount = r.AccountNumber
FROM dbo.UPR_CLOSURE c
INNER JOIN dbo.UPR r ON r.UPRID = c.AncestorUPRID
INNER JOIN dbo.UPR d ON d.UPRID = c.DescendantUPRID
WHERE r.ParentUPRID IS NULL
ORDER BY r.UPRID, c.[Level], d.ParentUPRID, c.DescendantUPRID;
```

On an existing database, run `scripts/install_upr_audit.sql`, then the updated
`scripts/load_upr_master.sql` with the correct `USE` database name. The loader
adds the column if missing, backfills every existing closure row, and enforces
`INT NOT NULL` and a nonnegative check. Do **not** run the drop/recreate schema
script on an existing database. The initial backfill creates real UPDATE audit
events; an unchanged rerun creates only the usual batch summary.

If the load fails, its data changes roll back. The newly added column may remain
nullable until a successful rerun fills it. A cycle in `ParentUPRID` stops the
load with an explicit error. Reparenting a subtree followed by a successful load
updates both its paths and levels.

## Verification

Tested on an isolated SQL Server 2022 instance: 43 hierarchy checks and 16 client
validation checks pass; both the first load and an idempotent second load pass
the hierarchy checks. All prior listing, source-audit, and client-row-20977
regressions still pass. The focused closure suite also verifies an upgrade of
a populated two-column table, full audit coverage of the new Level values,
unchanged reruns, reparenting through level 3, repair of incorrect levels,
rejection of negative levels, and rollback on a cyclic hierarchy.
