# November 3 R12 — record layout metadata names

Send **UPR_Main_Loader_2026-11-03_R12.zip**. It contains:

1. `load_upr_master_2026-11-03_R12.sql` — complete main loader (R11 C Number rule included).
2. `list_upr_hierarchy_2026-11-03.sql` — the full-records listing, updated to the new names.
3. `demo_upr_property360_2026-11-03.sql` — the Search / Property 360 demo, updated.
4. `check_upr_client_schema_2026-11-03.sql` — read-only layout check (optional).

## Column names now used

| Table | Before | Now |
|---|---|---|
| UPR, BUILDING, UNIT | UpdatedDate | **UpdateDate** |
| UPR_ADDRESS | IsPrimary | **PrimaryInd** |
| REF_PROPERTYTYPE | LastUpdatedUserID, LastUpdatedDate | **LastUpdateUserID, LastUpdateDate** |
| REF_PROPERTYTYPE | CreationUserID, CreationDate, DeletedInd | unchanged |
| REF_ENTITY_IDENTIFICATION (audit dictionary) | IsActive, CreatedDate, CreatedBy | **ActiveInd, CreationDate**, CreationUserID — either name works |
| Listing / demo reads | IsPrimary, CreatedDate, UpdatedDate | PrimaryInd, CreationDate, UpdateDate |

`CreatedBy` and `UpdatedBy` on UPR/COMPLEX were not in your list, so R12 keeps
them. If they were renamed too, the new layout check will say so (below).

## New: layout check before anything runs

The loader now starts with a record layout check. If any column it uses is
missing, or a table has a new required column the loader does not fill (for
example a NOT NULL `CreationUserID` with no default), the check:

- shows one grid listing **every** such table and column,
- stops the whole script before any function, column or row is changed.

So instead of "Invalid column name" errors, you get the complete list at once.
If the grid shows anything, please send a screenshot and we will match it.

## Run steps

1. Edit `USE UPRXDB_TEST;` to your test database (loader only; the listing and
   demo use the database selected in SSMS).
2. Run the entire loader. The Messages tab must show
   `UPR MAIN LOADER 2026-11-03 R12` and then `Record layout check passed.`
3. Results are the same as R11, including the C Number review grids.

## Verification

Run on SQL Server 2022 (local test container, synthetic data in your layout):

- Your sequence: database loaded by R10, columns renamed with `sp_rename`, then
  R12. Nothing was moved or duplicated. Standard test data gives the same
  hierarchy, links, owners, addresses and levels as R10.
- All R11 C Number checks pass on the new names, and an unchanged rerun writes
  no business changes.
- A database still on the old names stops in the layout check with all six
  renamed columns listed. Nothing was changed.
- The listing, Property 360 demo and schema check run on the new names.

Not yet run on your database.
