#!/usr/bin/env python3
"""Static checks on load_upr_master.sql (no SQL Server required)."""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SQL = ROOT / "scripts/load_upr_master.sql"
text = SQL.read_text(encoding="utf-8", errors="replace")

failures = 0

def check(name: str, ok: bool, detail: str = "") -> None:
    global failures
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f" — {detail}" if detail and not ok else ""))
    if not ok:
        failures += 1

print("=" * 60)
print("  LOAD SCRIPT STATIC CHECK")
print("=" * 60)

# Main load batch = after last normalization function GO, before trailing GO
chunks = re.split(r"^\s*GO\s*$", text, flags=re.M | re.I)
main_batch = chunks[-2] if len(chunks) >= 2 else text
if "SET NOCOUNT ON" not in main_batch:
    m = re.search(r"SET NOCOUNT ON.*", text, re.S)
    main_batch = m.group(0) if m else text

check("File exists and non-empty", SQL.is_file() and len(text) > 1000)

# Temp table SELECT INTO duplicates in same batch (Msg 2714) — ignore INSERT INTO
select_into: list[str] = []
for stmt in re.split(r";", main_batch):
    if re.search(r"\bINSERT\s+INTO\s+#", stmt, re.I):
        continue
    select_into.extend(re.findall(r"\bINTO\s+(#\w+)", stmt, re.I))
dup_into = {t for t in select_into if select_into.count(t) > 1}
check("No duplicate SELECT INTO same #temp in main batch", len(dup_into) == 0,
      f"duplicates: {', '.join(sorted(dup_into))}" if dup_into else "")

# TRY/CATCH balance in main batch
try_count = len(re.findall(r"\bBEGIN\s+TRY\b", main_batch, re.I))
catch_count = len(re.findall(r"\bBEGIN\s+CATCH\b", main_batch, re.I))
check("BEGIN TRY / BEGIN CATCH balanced", try_count == catch_count,
      f"TRY={try_count} CATCH={catch_count}")

# Required REF seed columns
for col in ("IsActive", "CreationDate", "UpdatedDate", "CreatedDate"):
    check(f"REF seed sets {col}", col in text)

check("Preflight checks UPROPERTYRECORDS", "dbo.UPROPERTYRECORDS" in main_batch and "Missing required tables" in main_batch)
check("Preflight checks REF_MATCHCONFIDENCE.IsActive", "REF_MATCHCONFIDENCE.IsActive" in main_batch)
check("DHCA MA read TRY/CATCH", "Cannot read MasterAddress source" in main_batch)
check("SDAT read TRY/CATCH", "Cannot read SDAT source" in main_batch)
check("External source TRY/CATCH", "eProperty source skipped" in main_batch)
check("UPR duplicate-key guard (single pass)", "#UprMergeScored" in main_batch and "#UprMergeLosers" in main_batch)
check("UPR SDAT account normalization", "fn_UPR_NormalizeSDATAccount" in text)
check("UPR MERGE uses direct account join", "ON upr.SDATAccountNumber = s.EffectiveSDATAccountNumber" in main_batch)
check("Review anchor uses INSERT OUTPUT INSERTED only", "@ReviewUprInserted" in main_batch and "INSERTED.SDATAccountNumber" in main_batch)
check("Review_Q CHECK rebuilt outside transaction", "Schema: Review_Q ReasonForNoMatch CHECK rebuilt and verified" in text)
check("UPR pre-MERGE duplicate guards", "50030" in main_batch and "50031" in main_batch)
check("Review anchor unique synthetic keys", "PND-MA-" in main_batch and "50034" in main_batch)
check("Review anchor re-run idempotent", "NOT EXISTS" in main_batch and "PND-MA-" in main_batch)
check("UPR column NormalizedFullAddress in MERGE insert", "NormalizedStreetAddress, NormalizedFullAddress" in main_batch)
check("No PRINT with inline SELECT subquery", not re.search(r"PRINT[^\n]*\(SELECT", main_batch, re.I))
check("MERGE parcel guard uses flag not subquery", "ParcelConflict" in main_batch and "EXISTS (" not in main_batch.split("MERGE dbo.UPROPERTYRECORDS")[1].split("DROP TABLE #ExistingUprKeys")[0])
check("No CONCAT in main batch", "CONCAT(" not in main_batch)
check("Status history idempotent", "Initial load - new UPR record" in main_batch
      and main_batch.count("NOT EXISTS") >= 5)
check("Uses single SELECT INTO #UprMergeSrc (no duplicate)",
      main_batch.count("INTO #UprMergeSrc") - main_batch.count("INSERT INTO #UprMergeSrc") == 1)
check("#UprMergeSrc rebuilt from guard pass",
      "INSERT INTO #UprMergeSrc" in main_batch and "#UprMergeScored" in main_batch)

# MERGE blocks have WHEN NOT MATCHED
merge_count = len(re.findall(r"\bMERGE\s+dbo\.", main_batch, re.I))
not_matched = len(re.findall(r"WHEN\s+NOT\s+MATCHED", main_batch, re.I))
check("MERGE statements have WHEN NOT MATCHED", not_matched >= 5,
      f"MERGE={merge_count} NOT_MATCHED={not_matched}")

print()
if failures:
    print(f"STATIC CHECK: {failures} failure(s)")
    sys.exit(1)
print("STATIC CHECK: ALL PASSED")
sys.exit(0)
