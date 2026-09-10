# UPR Master Load Project

SQL Server integration that loads **AddressMaster** and **SDAT** into the **hierarchical UPR** model (Complex / Property / Condo / Building / Unit), with address normalization, entity tables, XREF, review queue, closure, and audit logging.

**Model:** `docs/NewUPRTABLEUSED.docx` + `docs/Response.docx` (COMPLEX).  
**Old flat model** archived under `legacy/` for reference only - do not run it.

## Requirements

- SQL Server 2016 or later
- Target test DB (edit `USE` in scripts): e.g. `UPRXDB_TEST`

## Project Structure

```
SQL/
├── DELIVERY.md                    # Delivery package overview
├── CLIENT_REAL_DATA_TEST.md       # Client guide for real-data testing
├── ddl/
│   └── 03_new_upr_schema.sql      # Hierarchical schema (run first)
├── scripts/
│   ├── install_upr_audit.sql      # Persistent INSERT/UPDATE/DELETE auditing
│   ├── diagnose_upr_accounts.sql  # Read-only client account diagnostics
│   ├── load_upr_master.sql        # Hierarchical load (main deliverable)
│   ├── search_upr_master.sql      # dbo.usp_UPR_Search
│   └── run_all.sh                 # Full pipeline in one command
├── test/
│   ├── run_test_and_results.sql   # Validation report (works with real data)
│   ├── local_it_setup.sql         # Incoming tables + hostile sample data
│   ├── local_it_verify.sql        # 33 hierarchy / client-rule assertions
│   ├── run_local_it.sh            # End-to-end run on a throwaway SQL Server
│   ├── static_check_hier.py       # Hierarchical rule checks
│   └── schema_contract_check.py   # Every INSERT/MERGE vs the DDL contract
├── legacy/                        # Archived flat-model scripts (do not run)
└── docs/                          # Client specs (NewUPRTABLEUSED, Response, Program Spec)
```

For the September 10 corrections on an existing database, follow
[CLIENT_FIX_2026-09-10.md](CLIENT_FIX_2026-09-10.md). The client's source-only
requirement supersedes the older generated-name conventions.

## Run Steps

Everything at once (sample data by default; add `--real-data` to skip it):

```bash
chmod +x scripts/run_all.sh
./scripts/run_all.sh localhost sa 'YourPassword'
```

Or step by step:

### 1. Create hierarchical schema (drops + recreates UPR tables)

```bash
sqlcmd -S localhost -E -i ddl/03_new_upr_schema.sql
```

### 2. Load incoming data

Real data: load into `dbo.MAIncomingTableX1` / `dbo.SDATIncomingTableX1` with
your own process. Sample data instead:

```bash
sqlcmd -S localhost -E -i test/local_it_setup.sql
```

### 3. Install auditing and run the UPR load

```bash
sqlcmd -S localhost -E -i scripts/install_upr_audit.sql
sqlcmd -S localhost -E -i scripts/load_upr_master.sql
```

### 4. View the validation report

```bash
sqlcmd -S localhost -E -i test/run_test_and_results.sql
```

### 5. Search UPR

Create the search procedure once (edit `USE` database name first):

```bash
sqlcmd -S localhost -E -i scripts/search_upr_master.sql
```

Then search with any criteria (NULL / omitted = ignore):

```sql
EXEC dbo.usp_UPR_Search @AccountNumber = N'00272531';
EXEC dbo.usp_UPR_Search @EntityType = N'Complex', @StreetName = N'OAK RIDGE';
EXEC dbo.usp_UPR_Search @ReasonForNoMatch = N'INSUFFICIENT_DATA', @IncludeReviewQOnly = 1;
```

The load is re-runnable: unchanged incoming data adds no business rows; a batch
audit summary is still recorded. Wiping the hierarchical tables first is only needed for a clean rebuild.

## Pre-delivery Verification

Static checks (no database needed):

```bash
python3 test/static_check_hier.py       # client rules + known regressions
python3 test/schema_contract_check.py   # every INSERT/MERGE against the DDL
```

Full end-to-end run against a throwaway SQL Server container:

```bash
docker run -d --name uprtest -e ACCEPT_EULA=Y -e 'MSSQL_SA_PASSWORD=<pw>' \
  -e MSSQL_PID=Developer -p 14333:1433 mcr.microsoft.com/mssql/server:2022-latest
test/run_local_it.sh
```

`run_local_it.sh` seeds deliberately hostile data (long street names, YearBuilt
0 and 9999, bad street numbers, missing zips, one account on several addresses,
MA/SDAT overlaps), creates the schema and audit triggers, runs the load twice,
and checks 33 hierarchy invariants plus identical business counts. It also tests
50,001-root listings, source-only fields, targeted legacy repairs, and audit
INSERT/UPDATE/DELETE/MERGE events and rollback behavior.

## Source Specifications

The hierarchical model is built from the client documents in `docs/`:

- [docs/NewUPRTABLEUSED.docx](docs/NewUPRTABLEUSED.docx) - table definitions (source of truth)
- [docs/Response.docx](docs/Response.docx) - answers on COMPLEX, Condo hierarchy, AccountNumber
- [docs/Program SPEC_UPR_REC_LAYOUT_8_31_2026.docx](docs/Program%20SPEC_UPR_REC_LAYOUT_8_31_2026.docx)
- [docs/ProgramSpec_Script_8_19_2026.docx](docs/ProgramSpec_Script_8_19_2026.docx)

Each load step is commented in `scripts/load_upr_master.sql` (Steps 0-14).

## Assumptions

| Topic | Assumption |
|-------|------------|
| Incoming tables | `dbo.MAIncomingTableX1` (MasterAddress) and `dbo.SDATIncomingTableX1` (SDAT) |
| Join key | `MAIncomingTableX1.Account` = normalized `SDATIncomingTableX1.AccountNumber` (numeric accounts zero-padded to 8) |
| AccountNumber | Nullable and **not unique** on UPR (client Response.docx) |
| Complex rule | MA MultiFamily/Apartments + Account# + 2+ distinct addresses -> COMPLEX; addresses counted on MA rows only |
| Condo rule | Condo parent (ParentUPRID NULL); Buildings and numbered Units are its children; Units link to their Building by BuildingID |
| Unit numbers | Only incoming `CondoUnit` / MA `Unit`; blank fields do not create new Units. Source-proven legacy generated numbers are cleared to NULL without deleting existing Units |
| Record type | Blank `LUCategory` -> `UNKNWN` property type; never invented as SF |
| Building names | NULL when the incoming tables supply no building name |
| Complex name | NULL when the incoming tables supply no complex name |
| Owner data | Incoming owner or NULL; account numbers are not substituted for names. Required Contact links share the source contact across each tree |
| Addresses | Source street number/name create Building + Address regardless of record type; blank street type/city/ZIP do not block. Missing State/ZIP stay NULL. Direct Address links are added to parents and Units |
| Idempotency | Safe to re-run - existing UPR/XREF/contact rows are reused, not duplicated |
| Audit | Run `install_upr_audit.sql` first: persistent row auditing on 22 UPR model/reference tables, with full JSON before/after values |

## Address Normalization

Per client spec example:

- Uppercase and trim all components
- Standardize street types: STREET→ST, AVENUE→AVE, ROAD→RD, LANE→LN, etc.
- `NormalizedAddress` = StreetNumber + StreetName + StreetType
- `NormalizedFullAddress` = above + City + ZIP (5-digit)

## Rollback

The load script runs inside a **single transaction**. On any error it rolls back all changes.

For a clean rebuild of the hierarchical tables, simply re-run
`ddl/03_new_upr_schema.sql` - it drops and recreates every UPR table (the
incoming tables `MAIncomingTableX1` / `SDATIncomingTableX1` are untouched).

To reset data only, in dependency order:

```sql
USE UPRXDB_TEST;
DELETE FROM dbo.UPRMATCHREVIEW_Q;
DELETE FROM dbo.UPRSTATUSHISTORY;
DELETE FROM dbo.AuditLog;
DELETE FROM dbo.UPR_CLOSURE;
DELETE FROM dbo.EXTERNAL_IDENTIFIER_XREF;
DELETE FROM dbo.UPR_CONTACT;
DELETE FROM dbo.CONTACT;
DELETE FROM dbo.UPR_ADDRESS;
DELETE FROM dbo.ADDRESS;
DELETE FROM dbo.UNIT;
DELETE FROM dbo.BUILDING;
DELETE FROM dbo.CONDO;
DELETE FROM dbo.PROPERTY;
DELETE FROM dbo.COMPLEX;
DELETE FROM dbo.ADU;
DELETE FROM dbo.UPR;
```

Then re-run the load script.

## Test Data Scenarios

The sample data (`test/local_it_setup.sql`) deliberately covers hostile cases:

- Complex: one MULTI account with 3 distinct building addresses (some with units)
- MultiFamily with a single address (Property -> Building -> Unit)
- SDAT condos with and without `CondoUnit`; zero-padded account variants
- Warehouse / Office / Vacant / Park (building, no unit)
- Institutional/Community Facilities (long record type -> `INSTCF` short code)
- Blank record type (must become `UNKNWN`, not SF)
- One account on several non-multifamily addresses
- MA and SDAT rows for the same property (must merge, not duplicate)
- YearBuilt 0 and 9999; 300-character street name; garbage state; bad street
  numbers; missing zips; NULL and placeholder parcels

## Acceptance Criteria

- Hierarchy per NewUPRTABLEUSED + Response.docx (Complex / Property / Condo / Building / Unit)
- Idempotent execution (re-run adds no rows)
- Address normalization per client example
- Statistics printed at end of load
- INSERT/UPDATE/DELETE on the 22 UPR model/reference tables audited from installation onward; batch summaries and initial status history also retained
- Review queue for unmatched/insufficient records with mapped reasons




