# November 11 R14 — DeleteInd, listing speed, search by address

Send **UPR_Main_Loader_2026-11-11_R14.zip**:

1. `load_upr_master_2026-11-11_R14.sql` — main loader, DeleteInd on every table.
2. `list_upr_hierarchy_2026-11-11.sql` — full-records listing, fixed for the new indexes.
3. `search_upr_by_address_2026-11-11.sql` — your UPR_BYAddress_Listing script, corrected.
4. `demo_upr_property360_2026-11-11.sql` — Search / Property 360 demo (unchanged logic).
5. `check_upr_client_schema_2026-11-11.sql` — read-only layout check (optional).

## 1. DeleteInd

R14 writes `DeleteInd` on COMPLEX, PROPERTY, CONDO, BUILDING and REF_PROPERTYTYPE,
matching your renamed layout (ADDRESS, UNIT and CONTACT already used DeleteInd).
It is the same as your edited R13; using R14 keeps your copy and ours identical.
Nothing else in the loader changed.

## 2. Full-records listing (no output)

The listing did not fail because of UNIT.BuildingID. It ran too slowly to return:

- The earlier layout had `IX_UPRSTATUSHISTORY_ParcelLookup (UPRID, ...)`. The
  11/6/2026 layout has **no index on UPRSTATUSHISTORY.UPRID**. The listing reads each
  Condo's parcel from that table, so every Condo row scanned the whole history
  table (about 30,000 Condos × 315,000 history rows on your data).
- The owner lookup also compared each row against all owners instead of only
  that record's own parents.

R14 reads the history table once for all Condos and finds owners only through the
record's own ancestors (index seeks). It no longer needs the dropped index.

On a test database with 240,000 UPRs in your layout, R13 did not finish Section 2
in 15 minutes; R14 completes the whole listing in under 4 minutes (227 seconds, all 240,000 rows plus address and contact links).

The default lists **every** record (850,000 rows on your data, plus all address and
contact links). For a quick check, set `@FilterAccount` to one account number, or
`@MaxRows` to the number of roots you want to see.

## 3. Your search by address (empty grids)

Your script runs without errors but finds no address, for two reasons:

- `ADDRESS.NormalizedAddress` holds the full line the loader writes, for example
  `1200 EAST WEST HWY SILVER SPRING 20910`, so comparing it with the street alone
  (`1200 East West Hwy`) never matches.
- The CONCAT fallback leaves one space for every NULL part. StreetSuffix and
  StreetDirection are usually NULL, so it builds `1200  EAST WEST HWY` with a double
  space, which never matches either.

`search_upr_by_address_2026-11-11.sql` keeps your layout and grids, with these changes:

- Accepts the street alone, street + city, or the full line; case, commas and extra
  spaces do not matter. It uses `IX_ADDRESS_NormalizedAddress`.
- Falls back to the address parts (NULL parts skipped) only if that finds nothing.
- Unit rows show their Building (BuildingID, BuildingUPRID, BuildingName) through
  `ParentUPRID`, since UNIT has no BuildingID now.
- Adds each row's PrimaryAddress, and prints a message when no address matches.

Write the street type as stored: `HWY`, `DR`, `ST`, `AVE` (not `Highway`).

## Index notes (11/6/2026 layout)

| Index | Status |
|---|---|
| `IX_UPRSTATUSHISTORY_ParcelLookup` | Dropped in the new layout. R14 scripts no longer need it. Recommended back if you query history by UPRID: `CREATE INDEX IX_UPRSTATUSHISTORY_UPRID ON dbo.UPRSTATUSHISTORY (UPRID, ChangeSource, ChangeDate DESC) INCLUDE (ParcelID);` |
| `IX_AuditLog_UPRID`, `IX_AuditLog_Entity` | Dropped. The loader only inserts into AuditLog, so loading is not affected. Audit reports that look up one UPRID will be slow on 7.5 million audit rows. Recommended: `CREATE INDEX IX_AuditLog_UPRID ON dbo.AuditLog (UPRID, AuditID);` |
| `IX_UNIT_BuildingID` | Not needed. A Unit's Building is found through `IX_UPR_Parent_EntityType (ParentUPRID, EntityTypeID)`. |
| `IX_UNIT_Building_UnitNumber` | Now on UnitNumber only — fine, the name is just misleading. |
| `UX_UPR_CLOSURE_Ancestor_Descendant` | Duplicates the primary key; can be dropped. |

## Run steps

1. Loader: edit `USE UPRXDB_TEST;`, run the whole file. Messages show
   `UPR MAIN LOADER 2026-11-11 R14` and `Record layout check passed.`
2. Listing: select your database in SSMS, set `@FilterAccount` if you want one
   account, run.
3. Search: edit the `USE` line and `@SearchAddress`, run.

## Verification

SQL Server 2022, your 11/6/2026 DDL with DeleteInd on every table, synthetic data:

- Full load, C Number checks and an unchanged rerun pass with DeleteInd.
- Your search script reproduced the empty grids. The corrected one returns the
  Complex → Building → Units tree for `1200 East West Hwy`,
  `1200 east west hwy, Silver Spring` and the full stored line.
- Listing: 240,000-UPR test database, before/after as above. On the standard test
  data its output is identical to R13. The 50,000-root listing test now takes
  3 minutes (31 minutes with R13).

Not yet run on your database.
