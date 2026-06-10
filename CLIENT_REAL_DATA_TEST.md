# How to Test with Real Data

Hi,

Here is the updated validation script with **clear, meaningful test descriptions** (no more "scenario" wording). It works with **your real data**, not just sample accounts.

---

## Steps to test with your real data

### Step 1 — One-time setup (if not done already)

Run once in SSMS:

1. `ddl/01_create_schema.sql`
2. `test/seed_reference_data.sql` (optional)

### Step 2 — Load YOUR data into staging tables

Load your production data into:

- **`dbo.AddressMaster`**
- **`dbo.SDAT`**

Use your own import process (SSIS, BCP, INSERT scripts, etc.).

Column names must match the schema in `01_create_schema.sql`.

### Step 3 — Run the load

Execute:

```
scripts/load_upr_master.sql
```

Check the **Messages** tab for:

```
UPR LOAD COMPLETE - PROCESSING SUMMARY
  AddressMaster rows read: ...
  SDAT rows read: ...
  UPROPERTYRECORD total: ...
```

### Step 4 — Run the validation report

Execute:

```
test/run_test_and_results.sql
```

This produces a **Validation Report** with plain-English checks like:

| Check | What it means |
|-------|---------------|
| Incoming AddressMaster data loaded | Your staging data was read |
| UPR master records created | Properties loaded into UPROPERTYRECORD |
| Matched to eProperty system | Links created to eProperty |
| Matched to CASE system | Links created to CASE |
| Matched to MPDU system | Links created to MPDU |
| Review queue populated | Records needing manual review |
| No duplicate UPR records | No duplicate accounts |
| Audit log written | Processing was audited |

**PASS** = OK | **FAIL** = needs attention | **N/A** = that source system has no data (not a failure)

### Step 5 (optional) — Look up one account

At the top of `run_test_and_results.sql`, set:

```sql
DECLARE @SampleAccount NVARCHAR(50) = N'YOUR_ACCOUNT_HERE';
```

Re-run the script to see full detail for that one property.

---

## Files to use for real-data testing

| File | Purpose |
|------|---------|
| `scripts/load_upr_master.sql` | **Run this** to process your data |
| `test/run_test_and_results.sql` | **Run this after** to validate results |
| `scripts/search_upr_master.sql` | Search UPR anytime |

You do **NOT** need `test/seed_test_incoming.sql` for real data — that file is sample data only.

---

## What to send back after testing

Please share:

1. Screenshot or copy of **Section 4 - Validation Checks** (PASS/FAIL grid)
2. **Section 1 - Record counts**
3. Any **FAIL** rows or error messages from the load script

That will help confirm everything works with your production data.

Best regards,
[Your Name]
