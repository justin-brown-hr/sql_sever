# UPR Master Load Project

SQL Server integration that loads **AddressMaster** and **SDAT** staging data into the **Unified Property Record (UPR)** master, with address normalization, cross-system matching, audit logging, and review queue handling.

## Requirements

- SQL Server 2016 or later
- Database: `UPR_Master` (created by DDL script)

## Project Structure

```
SQL/
├── DELIVERY.md                    # Delivery cover sheet (start here)
├── ddl/
│   ├── 01_create_schema.sql       # Creates database and all tables
│   └── 02_normalize_functions.sql # Normalization helpers (optional)
├── scripts/
│   ├── load_upr_master.sql        # Main deliverable - single load script
│   ├── search_upr_master.sql      # UPR search script
│   └── diagnose_duplicate_reviewq.sql  # Find DUPLICATE Review_Q rows missing UPR
│   └── run_all.sh                 # Full pipeline runner
├── test/
│   ├── seed_reference_data.sql    # Reference/lookup seed data
│   ├── seed_test_incoming.sql     # ~100 test rows per incoming table
│   └── run_test_and_results.sql   # Test results with PASS/FAIL checks
└── docs/                          # Client specification + technical docs
    ├── load_upr_master_technical.md
    └── UPR_Master_Load_Technical_Description.docx
```

## Run Steps

### 1. Create schema

```bash
sqlcmd -S localhost -E -i ddl/01_create_schema.sql
sqlcmd -S localhost -E -i ddl/02_normalize_functions.sql
```

Or run everything at once:

```bash
chmod +x scripts/run_all.sh
./scripts/run_all.sh localhost sa 'YourPassword'
```

### 2. Seed reference data (optional — load script also seeds refs)

```bash
sqlcmd -S localhost -E -i test/seed_reference_data.sql
```

### 3. Load test incoming data (~100 records each)

```bash
sqlcmd -S localhost -E -i test/seed_test_incoming.sql
```

### 4. Run the UPR load

```bash
sqlcmd -S localhost -E -i scripts/load_upr_master.sql
```

### 5. View test results

```bash
sqlcmd -S localhost -E -i test/run_test_and_results.sql
```

### 6. Search UPR

Edit search parameters at the top of `scripts/search_upr_master.sql`, then:

```bash
sqlcmd -S localhost -E -i scripts/search_upr_master.sql
```

Edit `USE` database name and search parameters at the top of the script before running.

## Technical Documentation

Full section-by-section load script walkthrough for production programmers:

- **Word:** [docs/UPR_Master_Load_Technical_Description.docx](docs/UPR_Master_Load_Technical_Description.docx)
- **Markdown:** [docs/load_upr_master_technical.md](docs/load_upr_master_technical.md)

## Assumptions

| Topic | Assumption |
|-------|------------|
| Staging tables | `AddressMaster` and `SDAT` |
| Join key | `AddressMaster.Account` = `SDAT.AccountNumber` |
| Address match | `NormalizedAddress` OR `NormalizedFullAddress` |
| `NO_MATCH` | Spec typo `N0_MATCH` interpreted as `NO_MATCH` |
| Idempotency | MERGE/NOT EXISTS — safe to re-run without duplicate UPR or XREF rows |
| Owner data | SDAT `Owner` → `CONTACT` + `PROPERTYCONTACT` |
| CONDO/APT | `REF_PROPERTYTYPE.AllowsBuildings=1` and `AllowsUnits=1` → `Building` + `Unit` |
| External match | Address match against `eProperty`, `Case`, `MPDU`, `MultifamilyLoanAddress` |
| Confidence | Parcel/Account = HIGH; normalized address = MEDIUM |
| Street types | External addresses normalized (LANE→LN, STREET→ST) via `fn_UPR_NormalizeAddressLine` |
| Single script | `load_upr_master.sql` includes normalization functions + full load logic |

## Address Normalization

Per client spec example:

- Uppercase and trim all components
- Standardize street types: STREET→ST, AVENUE→AVE, ROAD→RD, LANE→LN, etc.
- `NormalizedAddress` = StreetNumber + StreetName + StreetType
- `NormalizedFullAddress` = above + City + ZIP (5-digit)

## Rollback

The load script runs inside a **single transaction**. On any error it rolls back all changes and logs the failure to `AuditLog`.

To manually reset for a fresh test run:

```sql
USE UPR_Master;
DELETE FROM dbo.UPROPERTYMATCHREVIEW_Q;
DELETE FROM dbo.UPROPERTYRECORD_XREF;
DELETE FROM dbo.UPR_STATUSHISTORY;
DELETE FROM dbo.UNITCONTACT;
DELETE FROM dbo.UNITOWNER;
DELETE FROM dbo.Unit;
DELETE FROM dbo.Building;
DELETE FROM dbo.PROPERTYCONTACT;
DELETE FROM dbo.CONTACT;
DELETE FROM dbo.UPROPERTYRECORD;
DELETE FROM dbo.AuditLog;
```

Then re-run the load script.

## Test Data Scenarios

The generated test data (100 `AddressMaster`, 102 `SDAT`) covers:

- MA + SDAT matched pairs (account + address)
- AddressMaster-only records
- SDAT-only records
- External matches: eProperty, CASE, MPDU, MultifamilyLoanAddress
- No external match → Review Queue
- Bad/incomplete address data
- Various street type formats (ST, STREET, LN, LANE, etc.)
- Client sample records (accounts 10001001–40004004)

## Acceptance Criteria

- Idempotent execution (re-run safe)
- Address normalization per client example
- Statistics printed at end of load
- Audit log written for all processing
- Review queue for unmatched/insufficient records




