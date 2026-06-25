# UPR Load Script — How It Works

Script: `load_upr_master.sql`  
Database: `UPRDB_Test`  
Runs in **one transaction** (all succeed or all roll back).

---

## Input files (2 sources)

| Source | Table |
|--------|--------|
| Address Master | `DHCA_Internal.dbo.MasterAddress` |
| SDAT | `DHCA_Internal.dbo.RealPropertyTaxInformation` |

---

## Temp tables (staging)

| Temp table | What it holds |
|------------|----------------|
| `#MA` | Cleaned MasterAddress rows |
| `#SDAT` | Cleaned SDAT rows |
| `#Work` | All rows combined — matched, MA-only, or SDAT-only |
| `#UPRMap` | Links each work row to its UPR record ID |

---

## Main steps

**1. Reference data**  
Seeds lookup tables (property type, source system, match method, etc.) if missing.

**2. Build `#MA`**  
Reads MasterAddress. Trims and standardizes address (ST, AVE, RD…). Maps `LUCategory` → property type. State defaults to MD. Builds normalized address fields.

**3. Build `#SDAT`**  
Reads SDAT. Same address cleanup. Gets owner, year built, dwelling units. No unit column in SDAT.

**4. Build `#Work`**  
Three groups:
- **BOTH** — same account + same normalized address in MA and SDAT
- **MA only** — no SDAT match
- **SDAT only** — no MA match

**5. Write UPR**  
MERGE into `UPROPERTYRECORDS`:
- Inserts new properties or updates existing ones (by account, parcel, or address)
- Skips rows missing required address fields
- Fills required NOT NULL columns when source is blank
- **Unit is not stored on UPR** — only address and property info

**6. Build `#UPRMap`**  
Connects each `#Work` row to its `UPropertyRecordsID`.

**7. Related tables**

| Step | Writes to |
|------|-----------|
| Status history | `UPR_STATUSHISTORY` (new UPR rows only) |
| Source links | `UPROPERTYRECORDS_XREF` (MA + SDAT) |
| External match | XREF for eProperty, CASE, MPDU, Multifamily |
| Review queue | `UPRMATCHREVIEW_Q` (bad address or no external match) |
| Owner | `CONTACT`, `PROPERTYCONTACT` (from SDAT owner) |
| CONDO/APT | `Building`, `Unit` — MA.Unit goes here |
| Audit | `AuditLog` |

**8. Summary**  
Prints row counts for each step.

---

## Flow (simple)

```
MasterAddress  ──►  #MA  ──┐
                           ├──►  #Work  ──►  UPROPERTYRECORDS  ──►  XREF, Review, Contact, Building, Unit
SDAT           ──►  #SDAT ──┘
```

---

## Important rules

- **Re-run safe** — won’t duplicate UPR or XREF if you run again
- **Unit** — on `dbo.Unit` only, not on UPR
- **MA has no State** — defaults to MD
- **SDAT has no Unit**
- **Bad addresses** — go to review queue, not UPR

---

## What to check in review

1. Match logic: account + normalized address (Section 4)
2. Property type mapping from `LUCategory` (Section 2)
3. Derived account when MA has no Account (Section 5)
4. External system matching (Section 7)
5. CONDO/APT building + unit creation (Section 10)
