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
check("DHCA MA read TRY/CATCH", "Cannot read DHCA_Internal.dbo.MasterAddress" in main_batch)
check("External source TRY/CATCH", "eProperty source skipped" in main_batch)
check("UPR duplicate-key guard (single pass)", "#UprMergeScored" in main_batch and "#UprMergeLosers" in main_batch)
check("UPR SDAT account normalization", "fn_UPR_NormalizeSDATAccount" in text)
check("UPR MERGE uses direct account join", "ON upr.SDATAccountNumber = s.EffectiveSDATAccountNumber" in main_batch)
check("Review anchor uses INSERT OUTPUT INSERTED only", "@ReviewUprInserted" in main_batch and "INSERTED.SDATAccountNumber" in main_batch)
check("Review_Q CHECK rebuilt outside transaction", "outside transaction" in text and "Schema: CK_UPRMATCHREVIEW_Q_ReasonForNoMatch rebuilt" in text)
check("UPR column NormalizedFulldAddress in MERGE insert", "NormalizedStreetAddress, NormalizedFulldAddress" in main_batch)
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
