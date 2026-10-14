# October 8 R9 — Condo units under their buildings

Send **UPR_Main_Loader_2026-10-08_R9.zip**. It contains exactly two SQL files:

1. `load_upr_master_2026-10-08_R9.sql` — complete updated main loader.
2. `check_upr_unit_hierarchy.sql` — read-only parent/level verification.

The dated loader matches `scripts/load_upr_master.sql` byte for byte. Its first
line and Messages identify **UPR MAIN LOADER 2026-10-08 R9**. Existing R8 schema,
audit and full-closure check scripts remain applicable and are not resent.

## What the screenshots establish

The first screenshot shows Condo UPR 24, account **00118285**. Building 147901 and
Unit 345168 both have ParentUPRID 24. Consequently the closure algorithm records
the distance from 24 to each as 1. That distance matches the stored parent link,
but the unit's parent does not follow the newly required three-level hierarchy.

The second screenshot shows **Complex** UPR 24, account **02688618**, with Units
207074/207075 under Buildings 88787/88788. These are different property records/
datasets despite sharing UPRID 24. They cannot establish that the same property's
parent was changed by R8. Inspection of the archived R4 SQL confirmed the same
Condo-specific direct-parent rule existed there too.

The current client requirement is now applied consistently:

```text
Condo / Complex / Property       root level 0
    Building                    root level 1
        Unit                    root level 2
```

The correction changes the real parent link; it does not force a displayed or
stored Level of 2 while leaving ParentUPRID pointing to the root.

## Main-loader changes

- New Condo units use their Building UPRID as ParentUPRID, like Complex/Property
  units. UNIT.BuildingID and ParentUPRID describe the same building.
- Before source reuse/duplicate matching, existing direct Condo-to-Unit links are
  reviewed. The loader uses UNIT.BuildingID -> BUILDING.UPRID to identify the
  building. It repairs only when that UPR is a Building under the same root Condo.
- Missing/ambiguous UNIT records, missing/wrong-type buildings, another Condo's
  building, a non-root Condo or a Unit with children cause a diagnostic and rollback.
  No building is inferred from address, row order, example IDs or matching names.
- The repair preserves UnitID, UPRID, BuildingID and source identifiers. It changes
  UPR.ParentUPRID and the UPR updated-by/date fields. The repair itself does not
  insert/delete entities or identifiers. Existing source-loading/overlap rules
  remain in the full loader and still perform their normal work.
- Existing duplicate reconciliation now expects Condo units under buildings.
- Existing closure generation then derives all pair distances from ParentUPRID.
  Self=0, Building-to-Unit=1, root-to-Unit=2. No closure column alteration, index
  removal, forced level constant or table replacement is added.
- Each repaired UPR receives a readable before/after UPDATE audit entry. The
  summary reports **Existing Condo units reparented** alongside UPR totals.
  R8 audit behavior/history preservation remains in effect.
- Parent repairs, source changes, closure and new audits share the main transaction.
  A failure rolls them back. Earlier helper/schema-ensure batches have the same
  transaction boundaries as R8.

The repair covers existing direct Condo units even if their original source rows
are no longer in the incoming staging tables. Already-correct unit links are not
reparented. An unchanged rerun should report zero Condo reparent repairs.

For the first screenshot, **if UNIT.BuildingID verifies Building UPR 147901 under
Condo 24**, the expected result after loading is:

| Root-relative Level | UPRID | ParentUPRID | Entity |
|---:|---:|---:|---|
| 0 | 24 | NULL | Condo |
| 1 | 147901 | 24 | Building |
| 2 | 345168 | 147901 | Unit |

Selecting DescendantUPRID 345168 should also find self distance 0, Building 147901
distance 1, and Condo 24 distance 2. The screenshot does not display UNIT.BuildingID,
so the loader validates it instead of hard-coding that expected building.

## Client run order

1. Open the dated R9 main loader in the same test database. Set its USE line to
   that database and run the entire file in a dedicated session without an open
   transaction. No separate audit installation or table reset is required.
2. Confirm the R9 release marker, successful completion, UPR update counts and
   Condo reparent count in Messages. If a repair diagnostic appears, return its
   UnitUPRID/BuildingID/Issue results; do not manually overwrite Level.
3. Run `check_upr_unit_hierarchy.sql` in that same database. Its default root 24
   matches these screenshots. Confirm the displayed account/entity type as well
   as UPRID. The checker evaluates all units, then shows root 24 details.
4. Expect zero failing units and root-relative levels 0/1/2. Run the earlier full
   closure checker too: it additionally tests missing/extra pairs and indexes.
5. Run the existing audit checker using this run's printed RunID to reconcile
   new row audits. Historical audit values remain unchanged.
6. Repeat with unchanged incoming data to check stable business counts and zero
   additional Condo reparent repairs before proceeding to the full load/demo.

## Validation

- The actual repair candidate query was exercised locally against the first
  screenshot's IDs, linked through independent UnitID/BuildingID values. Repair
  preserves native IDs and source identifiers and is idempotent.
- Missing mappings, wrong building type, another root, duplicate UNIT rows,
  nested Condo and Unit-with-children fixtures are rejected.
- The actual client checker distinguishes a wrong parent from a wrong distance.
- Existing closure, index, schema/dependency, runner and demo checks passed.
- ScriptDom parsed the main loader, checker, validation reports and rendered
  dynamic SQL with zero syntax errors. All 63 business writes across 19 tables
  retain bound audit capture. The new repair's text images passed the existing
  NULL/quotes/line-break/long-value tests.
- A prepared SQL Server integration case now reproduces direct Condo links,
  reruns the loader and checks stable IDs/XREFs, audit events and rerun behavior.

**SQL Server integration has not run here**; there is no server/client connection.
Offline SQLite relational tests and parsing do not prove live execution, trigger
behavior, concurrency or throughput. The client test remains required. The earlier
200,000 synthetic audit-event check is not a SQL Server source-load benchmark.
