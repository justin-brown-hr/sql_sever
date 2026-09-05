# How to Test with Real Data (Hierarchical UPR)

Hi,

Here is how to test the new **hierarchical UPR model** with **your real data**.
The validation report uses plain-English checks and works with any data - it is
not tied to sample accounts.

---

## Steps to test with your real data

### Step 1 - One-time setup

Run once in SSMS (edit the `USE UPRXDB_TEST` line first if your database has a
different name - same edit in every script):

1. `ddl/03_new_upr_schema.sql`  - creates the hierarchical tables
   (UPR, COMPLEX, PROPERTY, CONDO, BUILDING, UNIT, ADDRESS, CONTACT, XREF, ...)

This drops and recreates the hierarchical tables, so only run it when you want
a clean rebuild.

### Step 2 - Load YOUR data into the incoming tables

Load your production data into:

- **`dbo.MAIncomingTableX1`** (MasterAddress)
- **`dbo.SDATIncomingTableX1`** (SDAT)

Use your own import process (SSIS, BCP, INSERT scripts, etc.).
If `SDATIncomingTableX1` has no `CondoUnit` column, the load script adds it
automatically.

### Step 3 - Run the load

Execute:

```
scripts/load_upr_master.sql
```

Check the **Messages** tab for:

```
UPR hierarchical load COMPLETE
  MA rows read                 : ...
  SDAT rows read               : ...
  Parent groups COMPLEX/PROP/CONDO: ...
  Building UPRs (new this run) : ...
  UNIT rows inserted           : ...
```

The load is safe to re-run: existing records are reused, not duplicated.

### Step 4 - Run the validation report

Execute:

```
test/run_test_and_results.sql
```

This produces a **Validation Report** with plain-English checks like:

| Check | What it means |
|-------|---------------|
| Incoming MasterAddress data loaded | Your staging data was read |
| UPR records created | Records loaded into the UPR hierarchy |
| Every UPR has its entity record | Each UPR row has its Complex/Property/Condo/Building/Unit row |
| Every Building has a primary Address | Address written through ADDRESS + UPR_ADDRESS |
| Every parent record has a Contact | Owner/organization contact linked |
| Every Unit has a Building | No orphan units |
| Hierarchy closure table complete | Parent-child paths are all recorded |
| Review queue populated | Records needing manual review |
| Audit log written | Processing was audited |

**PASS** = OK | **FAIL** = needs attention | **N/A** = nothing to check (not a failure)

### Step 5 (optional) - Look up one account

At the top of `test/run_test_and_results.sql`, set:

```sql
DECLARE @SampleAccount NVARCHAR(50) = N'YOUR_ACCOUNT_HERE';
```

Re-run the script to see the full hierarchy (Complex/Property/Condo down to
Buildings and Units) for that one account.

You can also search interactively. Run `scripts/search_upr_master.sql` once,
then:

```sql
EXEC dbo.usp_UPR_Search @AccountNumber = N'00272531';
EXEC dbo.usp_UPR_Search @EntityType = N'Complex';
EXEC dbo.usp_UPR_Search @StreetName = N'MAIN', @City = N'ROCKVILLE';
EXEC dbo.usp_UPR_Search @IncludeReviewQOnly = 1;
```

---

## Files to use for real-data testing

| File | Purpose |
|------|---------|
| `ddl/03_new_upr_schema.sql` | **Run first (once)** - creates the hierarchical schema |
| `scripts/load_upr_master.sql` | **Run this** to process your data |
| `test/run_test_and_results.sql` | **Run this after** to validate results |
| `scripts/search_upr_master.sql` | Creates `dbo.usp_UPR_Search` - EXEC search by criteria |

You do **NOT** need anything else from the `test/` folder for real data - those
files are sample data and development checks only.

---

## What to send back after testing

Please share:

1. Screenshot or copy of **Section 4 - Validation checks** (PASS/FAIL grid)
2. **Section 1 - Record counts**
3. Any **FAIL** rows or error messages from the load script

That will help confirm everything works with your production data.

Best regards,
[Your Name]
