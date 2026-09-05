# UPR Master Load - Delivery Package (Hierarchical Model)

**Project:** Unified Property Record (UPR) - Hierarchical Load
**Platform:** SQL Server 2016+
**Database:** `UPRXDB_TEST` (edit the `USE` line in each script if yours differs)
**Model source:** `docs/NewUPRTABLEUSED.docx` + `docs/Response.docx`
**Delivered:** September 2026

---

## Deliverables Checklist

| # | Item | File |
|---|------|------|
| 1 | **Hierarchical schema** (UPR, COMPLEX, PROPERTY, CONDO, BUILDING, UNIT, ADDRESS, CONTACT, XREF, CLOSURE, Review_Q, history, audit) | `ddl/03_new_upr_schema.sql` |
| 2 | **Load script** (MA + SDAT to full hierarchy) | `scripts/load_upr_master.sql` |
| 3 | **Search procedure** | `scripts/search_upr_master.sql` -> `dbo.usp_UPR_Search` |
| 4 | **Validation report** (PASS/FAIL checks, works with real data) | `test/run_test_and_results.sql` |
| 5 | **Real-data test guide** | `CLIENT_REAL_DATA_TEST.md` |
| 6 | **README** (structure, run steps, assumptions) | `README.md` |

Supporting files:

| File | Purpose |
|------|---------|
| `test/local_it_setup.sql` | Creates incoming tables + hostile sample data (for a sandbox run) |
| `test/local_it_verify.sql` | 33 hierarchy / business-rule assertions for the sample data |
| `test/run_local_it.sh` | Full end-to-end run against a throwaway SQL Server container |
| `test/static_check_hier.py` | Static rule checks + regression guards |
| `test/schema_contract_check.py` | Validates every INSERT/MERGE against the DDL |
| `legacy/` | Archived flat-model scripts and old test harness (do not run) |

---

## Quick Start (SSMS)

Run scripts **in this order**:

1. `ddl/03_new_upr_schema.sql`  <- creates the hierarchical schema (drops + recreates)
2. Load your data into `dbo.MAIncomingTableX1` and `dbo.SDATIncomingTableX1`
   (or run `test/local_it_setup.sql` for sample data)
3. `scripts/load_upr_master.sql`  <- **main deliverable**
4. `test/run_test_and_results.sql`  <- **validation report**
5. `scripts/search_upr_master.sql`  <- creates `dbo.usp_UPR_Search`; then EXEC with criteria

> `load_upr_master.sql` is self-contained: it creates normalization functions,
> seeds REF codes, adds `CondoUnit` to the SDAT table when missing, runs the
> full load in one transaction, and prints statistics per step.

---

## Quick Start (sqlcmd)

```bash
sqlcmd -S YourServer -U sa -P 'YourPassword' -C -i ddl/03_new_upr_schema.sql
sqlcmd -S YourServer -U sa -P 'YourPassword' -C -i test/local_it_setup.sql   # sample data only
sqlcmd -S YourServer -U sa -P 'YourPassword' -C -i scripts/load_upr_master.sql
sqlcmd -S YourServer -U sa -P 'YourPassword' -C -i test/run_test_and_results.sql
sqlcmd -S YourServer -U sa -P 'YourPassword' -C -i scripts/search_upr_master.sql
```

Or: `chmod +x scripts/run_all.sh && ./scripts/run_all.sh YourServer sa 'YourPassword'`

---

## What the Load Script Does

1. Ensures `SDATIncomingTableX1.CondoUnit` exists (own batch, before the load)
2. Preflight: verifies all hierarchical tables and functions exist
3. Seeds REF codes (entity types, roles, address roles, property type short codes)
4. Reads and normalizes MA (`MAIncomingTableX1`) and SDAT (`SDATIncomingTableX1`)
5. Validates rows; invalid rows go to `UPRMATCHREVIEW_Q` with a mapped reason
6. Classifies each group:
   - **COMPLEX** - MA MultiFamily/Apartments + Account# + 2 or more distinct addresses
   - **CONDO** - SDAT rows (or MA condo records); Condo parent has Parent NULL
   - **PROPERTY** - everything else (SF, Townhouse, Office, Warehouse, Vacant, Park, ...)
7. Inserts parent UPRs + `COMPLEX` / `PROPERTY` / `CONDO` entity rows
8. Inserts Building UPRs per distinct address ("Building A", "Building B", ...)
   with `ADDRESS` + `UPR_ADDRESS` (primary, PHYSICAL role)
9. Inserts Unit UPRs + `UNIT` (from `CondoUnit`, then MA `Unit`; generated
   MA-/SD- ids only for multi-unit records with blank unit fields)
10. Creates `CONTACT` + `UPR_CONTACT` (OWNER role) for every parent
11. Writes `EXTERNAL_IDENTIFIER_XREF` (source record ids + account numbers)
12. Rebuilds `UPR_CLOSURE` (full ancestor/descendant paths)
13. Writes `UPRSTATUSHISTORY` and `AuditLog`, prints the summary

All steps run inside a **single transaction** (rollback on error).
**Re-runs are safe**: a second run against unchanged incoming data inserts nothing.

---

## Business Rules Applied (from Response.docx)

- `NewUPRTABLEUSED.docx` is the source of truth; the flat model is fully replaced
- `AccountNumber` is **nullable and not unique** (one account can span records)
- `CommunityName` lives on **COMPLEX only**; label built from city
  (e.g. `SILVER SPRING BUILDING COMPLEX`) since sources carry no complex name
- Buildings without a source name are labelled **Building A, Building B, ...**
- MultiFamily with **one** address stays Property -> Building -> Unit
- Condo (SDAT): **Condo (Parent NULL) -> Unit**; account stored on the Condo UPR
- Addresses only via **ADDRESS + UPR_ADDRESS**; contact required when address valid
- Owner/organization name may be NULL when the source has none
- Blank record type is stored as **UNKNWN** - never invented as SF

---

## Search Procedure Usage

Run `scripts/search_upr_master.sql` once to create `dbo.usp_UPR_Search`, then
EXEC with any combination of criteria (omit unused params):

```sql
EXEC dbo.usp_UPR_Search @AccountNumber = N'00272531';
EXEC dbo.usp_UPR_Search @EntityType = N'Complex';
EXEC dbo.usp_UPR_Search @StreetName = N'MAIN', @City = N'ROCKVILLE';
EXEC dbo.usp_UPR_Search @ReasonForNoMatch = N'INSUFFICIENT_DATA', @IncludeReviewQOnly = 1;
```

Parameters (all optional / NULL = ignore): `@AccountNumber`, `@ParcelID`,
`@StreetNumber`, `@StreetName`, `@City`, `@ZipCode`, `@OwnerName`,
`@EntityType`, `@PropertyTypeCode`, `@StatusCode`, `@NormalizedAddress`,
`@SourceSystem`, `@ReasonForNoMatch`, `@IncludeReviewQOnly`, `@MaxRows`.

Results include the UPR hub rows, XREF links, hierarchy (closure) and Review
Queue entries.

---

## Verification Performed Before Delivery

- 40+ static checks (`test/static_check_hier.py`) including regression guards
  for every issue found during review
- Contract check: every INSERT/MERGE validated against the DDL
  (`test/schema_contract_check.py`)
- End-to-end run on SQL Server 2022 with deliberately hostile data
  (NVARCHAR(MAX) sources, 300-char street names, YearBuilt 0/9999, bad street
  numbers, missing zips, shared accounts, MA/SDAT overlaps)
- Load executed **twice**: second run inserted zero rows (idempotency)
- All 7 search procedure variants executed without error

---

## Rollback / Reset

Re-running `ddl/03_new_upr_schema.sql` drops and recreates all hierarchical
tables (incoming tables are untouched). The load script itself rolls back
automatically on any failure.

---

## Support

Available for questions on table layouts, hierarchy rules, or adjustments to
normalization logic.
