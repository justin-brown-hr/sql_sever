> The package also includes the [EntityKey explanation and readable audit report](CLIENT_AUDIT_KEY_UPDATE_2026-09-24.md).

> Current search behavior and installation notes: [September 24 search update](CLIENT_SEARCH_UPDATE_2026-09-24.md).
> The refreshed SQL candidate still requires SQL Server integration execution.

> Historical delivery notes. For the current schema, migration order and verification status,
> see [September 23 update](CLIENT_UPDATE_2026-09-23.md). Earlier test passes do not validate this update.

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
| 7 | **Persistent row auditing** (install before loading) | `scripts/install_upr_audit.sql` |
| 8 | **Current correction guide and account diagnostics** | `CLIENT_FIX_2026-09-16.md`, `scripts/diagnose_upr_accounts.sql` |

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

For an **existing database**, apply [CLIENT_FIX_2026-09-16.md](CLIENT_FIX_2026-09-16.md)
instead of the clean-schema setup below.

## Quick Start (SSMS)

Run scripts **in this order**:

1. `ddl/03_new_upr_schema.sql`  <- creates the hierarchical schema (drops + recreates)
2. Load your data into `dbo.MAIncomingTableX1` and `dbo.SDATIncomingTableX1`
   (or run `test/local_it_setup.sql` for sample data)
3. `scripts/install_upr_audit.sql` <- persistent auditing (also safe on existing databases)
4. `scripts/load_upr_master.sql`  <- **main deliverable**
5. `test/run_test_and_results.sql`  <- **validation report**
6. `scripts/search_upr_master.sql`  <- creates `dbo.usp_UPR_Search`; then EXEC with criteria

> After audit installation, `load_upr_master.sql` creates normalization functions,
> seeds REF codes, adds `CondoUnit` to the SDAT table when missing, runs the
> full load in one transaction, and prints statistics per step.

---

## Quick Start (sqlcmd)

```bash
sqlcmd -S YourServer -U sa -P 'YourPassword' -C -i ddl/03_new_upr_schema.sql
sqlcmd -S YourServer -U sa -P 'YourPassword' -C -i test/local_it_setup.sql   # sample data only
sqlcmd -S YourServer -U sa -P 'YourPassword' -C -i scripts/install_upr_audit.sql
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
8. Inserts Building UPRs per distinct source address, leaving missing names NULL
   with `ADDRESS` + `UPR_ADDRESS` (primary, PHYSICAL role)
9. Inserts numbered Unit UPRs + `UNIT` only from incoming `CondoUnit` / MA `Unit`;
   clears source-proven legacy generated numbers without deleting existing Units
10. Creates required `CONTACT` + `UPR_CONTACT` links with incoming owner or NULL;
    shares source Address/Contact links across the hierarchy
11. Writes `EXTERNAL_IDENTIFIER_XREF` (source record ids + account numbers)
12. Synchronizes `UPR_CLOSURE` (only changed paths are written)
13. Writes `UPRSTATUSHISTORY` and the batch summary; persistent triggers audit
    individual model/reference table changes with full before/after values

All steps run inside a **single transaction** (rollback on error).
**Re-runs are safe**: unchanged incoming data inserts no business rows; the
batch audit summary is still recorded.

---

## Business Rules Applied (from Response.docx)

- `NewUPRTABLEUSED.docx` is the source of truth; the flat model is fully replaced
- `AccountNumber` is **nullable and not unique** (one account can span records)
- The September 10 source-only requirement supersedes generated-name rules.
- `CommunityName` lives on **COMPLEX only**; absent source names remain NULL
- Buildings without a source name have NULL BuildingName
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
- Load executed **twice**: second run inserted zero business rows (idempotency)
- Source-only fields, legacy placeholder repairs, missing Address links, and
  persistent multirow audit/rollback/MERGE cases tested on SQL Server 2022
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
