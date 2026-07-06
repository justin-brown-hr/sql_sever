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
check("MERGE parcel guard uses #UprMergeReady flag", "#UprMergeReady" in main_batch and "ParcelConflict" in main_batch)
check("No COL_LENGTH on temp table", "COL_LENGTH('tempdb.." not in main_batch)
check("THROW uses variable not inline concatenation", not re.search(r"THROW\s+\d+,\s*\n\s*N'[^']*'\s*\+", main_batch, re.I))
check("Summary is vertical PRINT only (no horizontal SELECT report)", "UPR LOAD COMPLETE" in main_batch and "AS LoadStatus" not in main_batch)
check("Summary reports UPR table count before/after", "UPR table count before load" in main_batch and "UPR table count after load" in main_batch)
check("No CONCAT in main batch", "CONCAT(" not in main_batch)
check("Status history idempotent", "Initial load - new UPR record" in main_batch
      and main_batch.count("NOT EXISTS") >= 5)
check("Uses single SELECT INTO #UprMergeSrc (no duplicate)",
      main_batch.count("INTO #UprMergeSrc") - main_batch.count("INSERT INTO #UprMergeSrc") == 1)
check("MA/SDAT mismatch detection (#MaSdMismatch)", "#MaSdMismatch" in main_batch)
check("Review_Q Missing ParcelID reason", "N'Missing ParcelID'" in main_batch)
check("Review_Q Address or Account Not Match reason", "N'Address or Account Not Match'" in main_batch)
check("CreateReview stage uses rp alias through Review_Q insert", "#CreateReview rp" in main_batch and "#ReviewQReady" in main_batch)
check("Review_Q preflight requires core Review_Q columns", "UPRMATCHREVIEW_Q missing required columns" in main_batch)
check("Review_Q preflight requires client MA/SDAT columns", "MA_NormalizedIncomingAddress" in main_batch and "SDAT_NormalizedIncomingAddress" in main_batch)
check("CreateReview stages client Review_Q column names", "MA_Account" in main_batch and "MA_ParcelID" in main_batch and "SDAT_ParcelID" in main_batch)
check("Review_Q mismatch uses BOTH incoming source", "N'BOTH'" in main_batch and "BOTH_MISMATCH" not in main_batch)
check("CreateReview deduped before Review_Q insert", "#CreateReviewDeduped" in main_batch)
check("XREF summary uses table before/after delta", "@XrefCountBefore" in main_batch and "@XrefTotalInsertedThisRun" in main_batch)
check("Review rejected XREF counted in summary", "@ReviewXrefRejectedInserted" in main_batch)
check("Review_Q skipped uses plain UPR parent wording", "no UPR parent to link" in main_batch)
check("Review_Q pipeline validates CreateReview required columns", "50038" in main_batch)
check("Review_Q #ReviewQReady matches UPRMATCHREVIEW_Q insert list",
      main_batch.count("INSERT INTO #ReviewQReady") == 1
      and main_batch.count("INSERT INTO dbo.UPRMATCHREVIEW_Q") == 1)
check("No MA-only SDAT enrichment via account-only join in step 4b",
      "not in account/address mismatch review" in main_batch)
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
