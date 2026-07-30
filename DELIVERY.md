# UPR Master Load — Delivery Package

**Project:** Unified Property Record (UPR) Load & Address Matching  
**Platform:** SQL Server 2016+  
**Database:** `UPR_Master`  
**Delivered:** June 2026

---

## Deliverables Checklist

| # | Item | File |
|---|------|------|
| 1 | **Single load script** (all tables + REF + AuditLog) | `scripts/load_upr_master.sql` |
| 2 | **Search procedure** | `scripts/search_upr_master.sql` → `dbo.usp_UPR_Search` |
| 3 | **Test data** (~100 records each) | `test/seed_test_incoming.sql` |
| 4 | **Test results script** (PASS/FAIL checks) | `test/run_test_and_results.sql` |
| 5 | **README** (assumptions, normalization, run/rollback) | `README.md` |

Supporting files (setup & convenience):

| File | Purpose |
|------|---------|
| `ddl/01_create_schema.sql` | Creates database and all tables |
| `ddl/02_normalize_functions.sql` | Standalone normalization functions (also embedded in load script) |
| `test/seed_reference_data.sql` | Reference table seed data |
| `scripts/run_all.sh` | Runs full pipeline in one command (Linux/macOS/sqlcmd) |

---

## Quick Start (SSMS)

Run scripts **in this order**:

1. `ddl/01_create_schema.sql`
2. `test/seed_reference_data.sql`
3. `test/seed_test_incoming.sql`
4. `scripts/load_upr_master.sql` ← **main deliverable**
5. `test/run_test_and_results.sql` ← **test results**
6. `scripts/search_upr_master.sql` ← creates `dbo.usp_UPR_Search`; then EXEC with criteria

> `load_upr_master.sql` is self-contained: it creates normalization functions, seeds REF data, runs the full load, and prints statistics.

---

## Quick Start (sqlcmd)

```bash
sqlcmd -S YourServer -U sa -P YourPassword -C -i ddl/01_create_schema.sql
sqlcmd -S YourServer -U sa -P YourPassword -C -i test/seed_reference_data.sql
sqlcmd -S YourServer -U sa -P YourPassword -C -i test/seed_test_incoming.sql
sqlcmd -S YourServer -U sa -P YourPassword -C -i scripts/load_upr_master.sql
sqlcmd -S YourServer -U sa -P YourPassword -C -i test/run_test_and_results.sql
```

Or: `chmod +x scripts/run_all.sh && ./scripts/run_all.sh YourServer sa 'YourPassword'`

---

## What the Load Script Does

1. Seeds `REF_SOURCESYSTEM`, `REF_MATCHMETHOD`, `REF_MATCHCONFIDENCE`, `REF_PROPERTYTYPE`
2. Normalizes `AddressMaster` and `SDAT` addresses (per your spec example)
3. Matches incoming records on **Account + Normalized Address**
4. Inserts/updates `UPROPERTYRECORD` (no duplicates)
5. Writes `UPROPERTYRECORD_XREF` for incoming and external sources
6. Matches addresses against **eProperty, CASE, MPDU, MultifamilyLoanAddress**
7. Routes unmatched/insufficient records to `UPROPERTYMATCHREVIEW_Q`
8. Creates `CONTACT` / `PROPERTYCONTACT` for SDAT owners
9. Creates `Building` / `Unit` for CONDO/APT property types
10. Writes `UPR_STATUSHISTORY` and `AuditLog`
11. Prints processing statistics

All steps run inside a **single transaction** (rollback on error).

---

## Test Data Summary

| Table | Rows | Notes |
|-------|------|-------|
| AddressMaster | 100 | Includes your 4 sample records (101–104) |
| SDAT | 102 | Matched pairs, SDAT-only, bad data rows |
| eProperty | 15 | Address/account matches |
| CASE | 13 | Includes LANE/LN normalization test |
| MPDU | 10 | Address matches |
| MultifamilyLoanAddress | 23 | Address matches |

### Key Test Scenarios (from your samples)

| Account | Expected Result |
|---------|-----------------|
| `10001001` | MA+SDAT match, eProperty XREF, Multifamily XREF |
| `20002002` | MA-only, CASE XREF (`500 OAK LANE` ↔ `500 OAK LN`) |
| `30003003` | MA+SDAT match, MPDU XREF |
| `40004004` | Loaded to UPR, no external match → Review Queue |

Run `test/run_test_and_results.sql` to see **PASS/FAIL** for each scenario.

---

## Assumptions & Notes

- `N0_MATCH` in spec interpreted as **`NO_MATCH`**
- Staging table names: `AddressMaster`, `SDAT` (per `Incoming_Test_Data.docx`)
- Re-runs are **idempotent** — existing XREF rows are not duplicated
- Status history written only for **new** UPR records on each run
- Owner stored as `CONTACT.OrganizationName` → `PROPERTYCONTACT` role `OWNER`

---

## Search Procedure Usage

Run `scripts/search_upr_master.sql` once to create `dbo.usp_UPR_Search`, then EXEC with any combination of criteria (omit unused params):

```sql
EXEC dbo.usp_UPR_Search @SDATAccountNumber = N'C000461';
EXEC dbo.usp_UPR_Search @StreetName = N'MAIN', @City = N'ROCKVILLE';
EXEC dbo.usp_UPR_Search @SourceSystemCode = N'MPDU', @PropertyTypeCode = N'CONDO';
EXEC dbo.usp_UPR_Search @ReasonForNoMatch = N'DUPLICATE', @IncludeReviewQOnly = 1;
```

Parameters (all optional / NULL = ignore): `@SDATAccountNumber`, `@MA_Account`, `@ParcelID`, `@StreetNumber`, `@StreetName`, `@City`, `@ZipCode`, `@Owner`, `@PropertyTypeCode`, `@PropertyStatusCode`, `@NormalizedAddress`, `@SourceSystemCode`, `@ReasonForNoMatch`, `@IncomingSourceSystem`, `@IncludeReviewQOnly`, `@MaxRows`.

Results include UPR rows, XREF links, and Review Queue entries (or Review_Q only when `@IncludeReviewQOnly = 1`).

---

## Rollback / Reset

See `README.md` for manual reset SQL. The load script itself rolls back automatically on failure.

---

## Support

Available for questions on table layouts, matching rules, or adjustments to normalization logic.
