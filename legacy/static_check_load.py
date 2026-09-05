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
check("Review_Q CHECK rebuilt outside transaction", "Schema: Review_Q ReasonForNoMatch CHECK rebuilt and verified" in text)
check("UPR pre-MERGE duplicate guards", "50030" in main_batch and "50031" in main_batch)
check("Review_Q inserts directly without PENDING UPR anchor", "no PENDING UPR rows" in main_batch and "PND-MA-" not in main_batch)
check("Review_Q XrefID nullable for rejected rows", "UPropertyRecords_XrefID nullable" in text)
check("UPR column NormalizedFullAddress in MERGE insert", "NormalizedStreetAddress, NormalizedFullAddress" in main_batch)
check("No PRINT with inline SELECT subquery", not re.search(r"PRINT[^\n]*\(SELECT", main_batch, re.I))
check("MERGE parcel guard uses #UprMergeReady flag", "#UprMergeReady" in main_batch and "ParcelConflict" in main_batch)
check("No COL_LENGTH on temp table", "COL_LENGTH('tempdb.." not in main_batch)
check("THROW uses variable not inline concatenation", not re.search(r"THROW\s+\d+,\s*\n\s*N'[^']*'\s*\+", main_batch, re.I))
check("Summary is vertical PRINT only (no horizontal SELECT report)", "UPR LOAD COMPLETE" in main_batch and "AS LoadStatus" not in main_batch)
check("Summary reports UPR table count", "UPR table count:" in main_batch and "UPR table count before load" not in main_batch)
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
check("CreateReview deduped without SELECT INTO recreate",
      "TRUNCATE TABLE #CreateReview" in main_batch
      and not re.search(r"SELECT\s+\*?\s*INTO\s+#CreateReview\b", main_batch, re.I))
check("Review_Q unique count subquery has column aliases", "AS MasterAddressID" in main_batch and "AS KdatRecordID" in main_batch)
check("XREF summary uses table count", "XREF table count:" in main_batch and "@XrefTotalInsertedThisRun" in main_batch)
check("Review rejected XREF counted in summary", "@ReviewXrefRejectedInserted" in main_batch)
check("Summary UPR rows written matches client expectation", "UPR rows written this run" in main_batch and "PENDING status" not in main_batch)
check("Review_Q pipeline validates CreateReview required columns", "50038" in main_batch)
check("Review_Q #ReviewQReady matches UPRMATCHREVIEW_Q insert list",
      main_batch.count("INSERT INTO #ReviewQReady") == 1
      and main_batch.count("INSERT INTO dbo.UPRMATCHREVIEW_Q") == 1)
check("No MA-only SDAT enrichment via account-only join in step 4b",
      "not in account/address mismatch review" in main_batch)
check("#UprMergeSrc rebuilt from guard pass",
      "INSERT INTO #UprMergeSrc" in main_batch and "#UprMergeScored" in main_batch)
check("Migration #IncomingUnique (dedupe before UPR)",
      "#IncomingUnique" in main_batch and "IncomingDupRn" in main_batch)
check("Placeholder ParcelID normalized",
      "fn_UPR_NormalizeParcelID" in text and "fn_UPR_IsValidParcelID" in text)
check("Multi-unit property flag / Unit load",
      "IsMultiUnitProperty" in main_batch
      and "multi-unit extras→Unit" in main_batch
      and "PropertyTypeCode IN (N'CONDO', N'MULTI', N'APT')" in main_batch)
check("Mismatch reconcile helpers",
      "fn_UPR_IsPreferredAccount" in text
      and "fn_UPR_AddressQualityScore" in text
      and "MismatchReconciled" in main_batch)
check("Multi-unit extras excluded from DUPLICATE",
      "u.IsMultiUnitProperty = 0" in main_batch)
check("Multi-unit UQ losers attach as Unit",
      "#UprMergeLosersToUnit" in main_batch
      and "multi-unit UQ collisions attached as Unit" in main_batch)
check("Multi-unit LUCategory substring mapping",
      "%MULT%FAMILY%" in text and "%CONDO%" in text)
check("SDAT CondoUnit carried to #Work and Unit",
      "CondoUnit" in main_batch
      and "s.CondoUnit" in main_batch
      and "CLIENT RULES IMPACT" in main_batch)
check("UnitNumber from CondoUnit or MA Unit (no street address)",
      "COALESCE(" in main_batch
      and "NULLIF(LTRIM(RTRIM(u.CondoUnit))" in main_batch
      and "NULLIF(LTRIM(RTRIM(u.Unit))" in main_batch
      and "UnitNumber = c.EffectiveUnit" in main_batch
      and "unit id from street address" not in main_batch
      and "UID-" not in main_batch)
check("No blanket UnitTypeCode overwrite from UPR PropertyType",
      "u.UnitTypeCode = upr.PropertyTypeCode" not in main_batch)
check("CondoUnit UnitTypeCode forced to CONDO",
      "WHEN c.UnitFromCondo = 1 THEN N'CONDO'" in main_batch)
check("MERGE preserves existing MULTI/CONDO/APT PropertyType",
      "upr.PropertyTypeCode IN (N'CONDO', N'MULTI', N'APT')" in main_batch
      and "NOT IN (N'CONDO', N'MULTI', N'APT')" in main_batch)
check("UnitTargetMap one UPR per PropertyGroupKey (no OR fan-out)",
      "PARTITION BY u.PropertyGroupKey" in main_batch
      and "OR upr.SDATAccountNumber = u.PropertyGroupKey" not in main_batch)
check("IsMultiUnitProperty keys off CondoUnit and MA Unit",
      "WHEN NULLIF(LTRIM(RTRIM(w.CondoUnit)), N'') IS NOT NULL THEN CAST(1 AS BIT)" in main_batch
      and "WHEN NULLIF(LTRIM(RTRIM(w.Unit)), N'') IS NOT NULL THEN CAST(1 AS BIT)" in main_batch)
check("External full-address match truncates to UPR length 100",
      "LEFT(ea.NormFullAddress, 100) = upr.NormalizedFullAddress" in main_batch)
check("ReviewDetail SELECT INTO uses CONVERT NVARCHAR(255)",
      "CONVERT(NVARCHAR(255), CASE" in main_batch
      and "CONVERT forces ReviewDetail width" in main_batch)
check("MULTI mapped before CONDO in LUCategory CASE",
      text.find("%MULTI%FAMILY%") < text.find("LIKE N'%CONDO%'"))
check("SDAT CONDO + MA LUCategory discovery documented",
      "SDAT — always CONDO" in text
      and "MA   — PropertyType from LUCategory" in text
      and "use ONLY what incoming SDAT and MA have" in text)
check("MULTY-Family / Multi-Family maps to MULTI",
      "%MULT%FAMILY%" in text
      and "%MULTY%FAMILY%" in text
      and "N'MULTI'" in text)
check("Building for WAREHOUSE/OFFICE/LAND/PARK",
      "N'WAREHS'" in main_batch
      and "N'OFFICE'" in main_batch
      and "N'LAND'" in main_batch
      and "N'PARK'" in main_batch
      and "AllowsBuildings" in main_batch)
# Building is 1:1 with UPR — no property-type gate on the insert
building_insert = re.search(
    r"INSERT INTO dbo\.Building\s*\((.|\n)*?;", main_batch, re.I)
building_sql = building_insert.group(0) if building_insert else ""
check("Building insert is 1:1 with UPR (no property-type filter)",
      bool(building_sql)
      and "UPR : Building is 1:1" in building_sql
      and "ISNULL(pt.AllowsBuildings, 0) = 1" not in building_sql
      and "REF_PROPERTYTYPE" not in building_sql)
# PropertyContact is 1:1 with UPR — driven from UPR, not from owner name presence
check("PropertyContact driven from every active UPR",
      "#UprContactSrc" in main_batch
      and "FROM dbo.UPROPERTYRECORDS upr" in main_batch
      and re.search(
          r"INSERT INTO dbo\.PROPERTYCONTACT(.|\n)*?FROM #UprContactSrc",
          main_batch, re.I) is not None)
check("PropertyContact guard is per UPR (1:1, not per contact)",
      re.search(
          r"INSERT INTO dbo\.PROPERTYCONTACT(.|\n)*?NOT EXISTS\s*\(\s*"
          r"SELECT 1 FROM dbo\.PROPERTYCONTACT pc\s*"
          r"WHERE pc\.UPropertyRecordsID = s\.UPropertyRecordsID\s*\)",
          main_batch, re.I) is not None)
check("Contact falls back to incoming Account#/CNumber (no invented names)",
      "NULLIF(LTRIM(RTRIM(upr.SDATAccountNumber)), N'')" in main_batch
      and "NULLIF(LTRIM(RTRIM(upr.CNumber)), N'')" in main_batch
      and "HasOwnerName" in main_batch)
check("Owner lookup avoids OR fan-out between #UPRMap and #Work",
      "OwnerBySource" in main_batch
      and "w.MasterAddressID = m.MasterAddressID OR w.KdatRecordID = m.KdatRecordID"
          not in main_batch)
check("Summary verifies UPR = Building = PropertyContact",
      "UPR rows missing a Building" in main_batch
      and "UPR rows missing a PropertyContact" in main_batch)
check("Multi-Family blank unit uses source row id not street",
      "N'MA-' + CONVERT(NVARCHAR(20), u.MasterAddressID)" in main_batch
      and "N'SD-' + CONVERT(NVARCHAR(20), u.KdatRecordID)" in main_batch
      and "unit id from street address" not in main_batch)
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
