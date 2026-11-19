# November 19 R15 — layout of 11/17/2026 and valid records sent to Review

Send **UPR_Main_Loader_2026-11-19_R15.zip**:

1. `load_upr_master_2026-11-19_R15.sql` — main loader for the 11/17/2026 layout.
2. `upr_layout_2026-11-17.sql` — your layout with the seed INSERTs fixed (see 1).
3. `list_upr_hierarchy_2026-11-19.sql` — full-records listing.
4. `search_upr_by_address_2026-11-19.sql` — search by address (unchanged from R14).
5. `demo_upr_property360_2026-11-19.sql` — Search / Property 360 demo.
6. `check_upr_client_schema_2026-11-19.sql` — read-only layout check (optional).

## 1. Layout of 11/17/2026

R15 uses every name exactly as in the layout:

- **DeletedInd** on every table. REF_CONTACTTYPE still says `DeleteInd`; R15 follows
  the layout, but it is probably a leftover from the rename.
- **UPR:** gets DeletedInd.
- **UPR_ADDRESS, UPR_CONTACT, REF_ENTITYTYPE, REF_ROLETYPE, REF_ADDRESSROLE,
  REF_CONTACTTYPE:** get CreationUserID, CreationDate, LastUpdateUserID and
  LastUpdateDate. **CONTACT:** gets CreationUserID.
- **Updates:** every update to a UPR_ADDRESS or UPR_CONTACT link sets
  LastUpdateUserID and LastUpdateDate.
- **AuditLog and UPRSTATUSHISTORY:** use `UpdatedBy` and `LastUpdated` (were
  ChangedBy and ChangeDate). AuditLog rows also fill the new metadata columns.
- **Listing, demo and audit check:** updated to the new names.

**Problem in the layout as sent:** REF_ENTITYTYPE, REF_CONTACTTYPE, REF_ROLETYPE
and REF_ADDRESSROLE now have `CreationUserID` and `LastUpdateUserID` as NOT NULL
without a default. The seed INSERTs at the end only give Code and Description, so
all four fail (Msg 515, "Cannot insert the value NULL into column
'CreationUserID'") and those tables stay empty.

`upr_layout_2026-11-17.sql` is your layout with only those four INSERTs changed to
supply the user columns, and the `USE` line. The loader re-adds only the few codes
it needs itself (entity types, OWNER, PHYSICAL, ORGANIZATION), so the layout script
should seed the rest.

## 2. Valid records sent to Review — cause and fix

We loaded your samples, as shown in the document, with R14 and with R15.

### SDAT rows (1426, 1348, 1352, 1402)

CondoUnit NULL was not the cause. These SDAT rows were rejected because their
**account number also exists in MA, but no MA row of that account has the same
street address**. Before R15 the only option was Review (`NO_ADDRESS_MATCH`). In
our test with R14, every SDAT row like this went to Review:

| Situation (SDAT vs MA, same account) | Example | R14 | R15 |
|---|---|---|---|
| Same address | 13123 SUNCREST AVE | Loaded | Loaded |
| Direction in the street name | `OLD BALTIMORE` vs `W OLD BALTIMORE` | Review | Joins the MA Property |
| Name spelled with or without a space | `SCHOOLFIELD` vs `SCHOOL FIELD`, `MC AULIFFE` vs `MCAULIFFE` | Review | Joins the MA Property |
| Different address; the account has one MA Property | 23210 vs 23200 SHILOH CHURCH RD | Review | Joins that Property (SDAT owner, parcel, account) |
| Different address; the account has several MA Properties | 300 THIRD ST | Review | Its own Property at the SDAT address |

Only an SDAT row that matches **more than one** MA Property of the account equally
well still goes to Review (`AMBIGUOUS_CANDIDATES`). That is a real choice for a
person to make.

### MA rows (2308 MCAULIFFE DR, 18900 MCFARLIN DR)

R14 already loads MA rows like these as a Property. MA rows are rejected only when
they have no account, no street name, or street number 0. The Review entry you see
for these accounts is most likely the **SDAT** row of the same account, with the
street spelled differently (as in the SDAT cases above, now loaded). Review_Q has
no column for the source record ID, so R15 now lists every Review row with its
source ID and exact reason (see 4).

### 822 ROCKVILLE PIKE (Retail, StreetSuffix A–H)

These were not rejected, but R14 ignored the MA `StreetSuffix`, so all six shops
became one address, "822 ROCKVILLE PIKE", with Units A–H. R15 adds the suffix to
the street number, as your MA FullAddress does. 822-A, 822-B, 822-C, 822-D and
822-H are now separate addresses, each with its own Property and Building, next
to 822.

### CondoUnit stored as the text 'NULL'

If a column holds the text `NULL` (from a file export) instead of a real NULL, R14
treated it as a value. For example, CondoUnit 'NULL' became a unit numbered
"NULL". R15 treats the text `NULL` and blanks as no value in all MA and SDAT
columns it reads.

## 3. Your open question — are SDAT rows without CondoUnit condos?

R15 keeps the current rule until you confirm: an SDAT row whose account is **not**
in MA and that has no CondoUnit loads as a **Condo**. Your samples (DwellingUnits 1,
owner-occupied, lot numbers) look like single-family homes, so we added one switch
near the top of the loader:

```sql
DECLARE @SdatOnlyWithoutCondoUnit NVARCHAR(10) = N'CONDO';   -- or N'PROPERTY'
```

`N'PROPERTY'` loads those rows as Properties instead (property type UNKNWN, because
SDAT has no land-use code). Rows with a CondoUnit are always condo units. SDAT rows
whose account is in MA always follow MA's classification.

## 4. New results grids

- **SDAT row on an MA account:** counts by how each was placed (FULL_ADDRESS,
  STREET_ADDRESS, MA_CONDO, STREET_SPELLING, ACCOUNT_ONLY, OWN_PROPERTY).
- **Review detail** (`@ShowReviewDetail = 1`, default): every row sent to Review
  with its SourceSystem, **SourceRecordID**, account, address and the exact
  reason. Examples: "Rejected: street number missing or 0", "Rejected: no account
  number", "SDAT address matches more than one MA parent of this account".
- **Relaxed matches:** each SDAT row loaded by spelling, account-only or
  own-Property, showing the SDAT address next to the MA address it joined.
  Worth a quick look on the first run.

## Run steps

Please load into a fresh schema. The 822-style addresses and newly accepted SDAT
rows would otherwise sit next to records an earlier run created.

1. Run `upr_layout_2026-11-17.sql` (edit its `USE` line). It drops and recreates
   the UPR tables.
2. Run the R15 loader (edit its `USE` line). The Messages tab shows
   `UPR MAIN LOADER 2026-11-19 R15` and `Record layout check passed.`
3. Compare **Review_Q inserted** with your R14 run, and look at the Review detail
   and Relaxed matches grids.

## Verification

SQL Server 2022 CU27, your 11/17/2026 layout, synthetic data plus your document's
sample rows:

- Your layout as sent: the four REF seed INSERTs fail with Msg 515. The fixed copy
  seeds all of them.
- All document samples load, with the placements in the table above. None is in
  Review_Q. An unchanged rerun writes nothing.
- All metadata columns are filled on every table, including UPR_ADDRESS,
  UPR_CONTACT, CONTACT, AuditLog and UPRSTATUSHISTORY.
- On the standard test data (which has no such samples), R15 gives exactly the same
  hierarchy, links, owners and addresses as delivered R10.
- The listing, Property 360 demo, schema check and closure index checks pass on the
  new layout.
- Larger test with 100,000 MA and 110,000 SDAT rows, including 8,000 SDAT rows with a
  respelled or different address:
  - R14 sent all 8,000 to Review.
  - R15 loaded them and sent only the 3 invalid rows to Review.
  - R15 took about 12% longer, mainly because it loads those extra rows and fills
    the new metadata columns.

Not yet run on your database.
