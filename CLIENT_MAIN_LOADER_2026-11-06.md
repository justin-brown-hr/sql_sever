# November 6 R13 — data structure changes (record layout of 11/6/2026)

Send **UPR_Main_Loader_2026-11-06_R13.zip**:

1. `load_upr_master_2026-11-06_R13.sql` — complete main loader (R11 C Number rule included).
2. `list_upr_hierarchy_2026-11-06.sql` — full-records listing.
3. `demo_upr_property360_2026-11-06.sql` — Search / Property 360 demo.
4. `check_upr_client_schema_2026-11-06.sql` — read-only layout check (optional).
5. `check_upr_closure_indexes_2026-11-06.sql` — read-only closure index report (optional).

All of them work against your new DDL (`DataStructureChanges_Layout_11_6_2026`).

## What changed in the script

| Your change | R13 |
|---|---|
| No "N/A" unit numbers | A Unit without a source unit number gets **NULL**. Any "N/A" from an earlier load is changed to NULL (audited). |
| Metadata on the tables | Every new row fills CreationDate, CreationUserID, LastUpdateUserID, LastUpdateDate and DeletedInd/DeleteInd = 0, using the exact names in your DDL. Every update sets LastUpdateUserID and LastUpdateDate. Dates are UTC, like your column defaults. |
| UPR / COMPLEX `CreatedBy` removed | Not used any more; CreationUserID holds the loader user. |
| UPDATE dates renamed | BUILDING, UNIT, UPR, ADDRESS, CONTACT, COMPLEX: LastUpdateDate. |
| AuditLog / UPRSTATUSHISTORY `ChangeDate` | Used (was ChangedDate). |
| **UNIT.BuildingID removed** | A Unit's Building is now its **ParentUPRID** (the Unit sits directly under its Building UPR). Unit matching, address links and the listing all use that link. |

## Index review

**UNIT (BuildingID removed).** No UNIT index is needed for the Building link. The
loader finds a Building's Units through `UPR.ParentUPRID`, which your
`IX_UPR_Parent_EntityType (ParentUPRID, EntityTypeID)` covers, and joins UNIT by
`UQ_UNIT_UPRID`. Notes:

- `IX_UNIT_Building_UnitNumber` is now on `(UnitNumber)` only. It is fine for
  searching by unit number, but the name is misleading — consider `IX_UNIT_UnitNumber`.
- `IX_UPR_ParentUPRID` duplicates the leading key of `IX_UPR_Parent_EntityType`.
  It can be dropped to save write time; nothing in the scripts needs it.

**UPR_CLOSURE.**

- `PK_UPR_CLOSURE (AncestorUPRID, DescendantUPRID)` already makes each pair unique.
  `UX_UPR_CLOSURE_Ancestor_Descendant` is an exact duplicate of the primary key and
  only adds write cost on the largest table. Recommend removing it.
- `IX_UPR_CLOSURE_Descendant (DescendantUPRID, Level, AncestorUPRID)` is reused by
  R13 for descendant lookups. (R12 would have created an extra index next to it.)
- `IX_UPR_CLOSURE_Ancestor (AncestorUPRID, Level, DescendantUPRID)` is useful for
  "descendants at level N" queries; the loader itself does not need it.

## Points to check in the DDL

1. The DROP line for the audit dictionary is misspelled:
   `OBJECT_ID(N'dbo.REF_ENTITY_IDENTIFICAION', ...)`. On a second run the table is
   not dropped and its CREATE fails.
2. Names differ between tables: `DeleteInd` (ADDRESS, UNIT, CONTACT) and
   `DeletedInd` (COMPLEX, PROPERTY, CONDO, BUILDING, REF tables). R13 uses them
   exactly as written. If you align them later, the loader's layout check will
   list what to change.
3. The Word document lists `LastUpdateUserID` for ADU, but the DDL does not have it.
   (The loader does not write ADU rows.)
4. `REF_ENTITY_IDENTIFICATION` has no primary key or unique EntityName. The loader
   copes, but `PRIMARY KEY (EntityID)` and `UNIQUE (EntityName)` are recommended.
   In the seed data, COMPLEX has `ActiveInd = 2`; a BIT column stores that as 1.

## Run steps

1. Create the schema with your DDL (it drops and recreates the UPR tables).
2. Open the R13 loader, edit `USE UPRXDB_TEST;` to your database, run the whole file.
3. The Messages tab must show `UPR MAIN LOADER 2026-11-06 R13` and
   `Record layout check passed.` If the layout check fails instead, it lists every
   table/column involved and nothing is changed — send a screenshot.

## Verification

Run on SQL Server 2022 with your DDL exactly as sent (only the database name
changed), using synthetic data:

- Full load completes. All metadata columns are filled. No unit number is N/A.
  Every Unit's parent is a Building. An unchanged rerun writes no business changes.
- R11 C Number checks all pass on the new layout. N/A values from an earlier load
  are cleared to NULL with audit.
- The standard test data gives the same hierarchy, links, owners, addresses and
  levels as delivered R10, except that N/A is now NULL.
- Your closure indexes are reused; no extra index is created.
- The listing, Property 360 demo and layout check run on the new layout.

Not yet run on your database.
