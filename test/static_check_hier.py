#!/usr/bin/env python3
"""Static checks for hierarchical UPR schema + load (v2)."""
from __future__ import annotations
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
failures = 0

def check(name: str, ok: bool, detail: str = "") -> None:
    global failures
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f" — {detail}" if detail and not ok else ""))
    if not ok:
        failures += 1

print("=" * 60)
print("  HIERARCHICAL UPR STATIC CHECK")
print("=" * 60)

ddl = (ROOT / "ddl/03_new_upr_schema.sql").read_text(encoding="utf-8", errors="replace")
load = (ROOT / "scripts/load_upr_master.sql").read_text(encoding="utf-8", errors="replace")
search = (ROOT / "scripts/search_upr_master.sql").read_text(encoding="utf-8", errors="replace")

check("DDL file exists", len(ddl) > 1000)
check("DDL creates dbo.UPR", "CREATE TABLE dbo.UPR" in ddl)
check("DDL creates dbo.COMPLEX", "CREATE TABLE dbo.COMPLEX" in ddl)
check("DDL creates dbo.PROPERTY", "CREATE TABLE dbo.PROPERTY" in ddl)
check("DDL creates dbo.CONDO", "CREATE TABLE dbo.CONDO" in ddl)
check("DDL creates dbo.BUILDING", "CREATE TABLE dbo.BUILDING" in ddl)
check("DDL creates dbo.UNIT", "CREATE TABLE dbo.UNIT" in ddl)
check("DDL creates dbo.ADDRESS", "CREATE TABLE dbo.ADDRESS" in ddl)
check("DDL creates dbo.UPR_ADDRESS", "CREATE TABLE dbo.UPR_ADDRESS" in ddl)
check("DDL creates dbo.UPR_CONTACT", "CREATE TABLE dbo.UPR_CONTACT" in ddl)
check("DDL creates EXTERNAL_IDENTIFIER_XREF", "EXTERNAL_IDENTIFIER_XREF" in ddl)
check("DDL creates UPR_CLOSURE", "CREATE TABLE dbo.UPR_CLOSURE" in ddl)
check("DDL seeds EntityTypes", "'Complex'" in ddl and "'Condo'" in ddl and "'ADU'" in ddl)
check("DDL CommunityName on COMPLEX only (not UPR)",
      "CommunityName" in ddl
      and "CommunityName" not in re.search(r"CREATE TABLE dbo\.UPR\s*\((.*?)\);", ddl, re.S).group(1))

check("Load is hierarchical (no flat UPROPERTYRECORDS MERGE)",
      "MERGE dbo.UPROPERTYRECORDS" not in load
      and "INSERT INTO dbo.UPR" in load)
check("Load PathType COMPLEX/PROPERTY/CONDO",
      "N'COMPLEX'" in load and "N'PROPERTY'" in load and "N'CONDO'" in load)
check("Load Complex rule: MULTI + account + 2+ addresses",
      "DistinctAddrOnAccount" in load and "> 1" in load)
check("Load writes COMPLEX entity", "INSERT INTO dbo.COMPLEX" in load)
check("Load writes PROPERTY entity", "INSERT INTO dbo.PROPERTY" in load)
check("Load writes CONDO entity", "INSERT INTO dbo.CONDO" in load)
check("Load writes BUILDING + UNIT", "INSERT INTO dbo.BUILDING" in load and "INSERT INTO dbo.UNIT" in load)
check("Load writes ADDRESS + UPR_ADDRESS",
      ("INSERT INTO dbo.ADDRESS" in load or "MERGE dbo.ADDRESS" in load)
      and "INSERT INTO dbo.UPR_ADDRESS" in load)
check("Load writes CONTACT + UPR_CONTACT",
      ("INSERT INTO dbo.CONTACT" in load or "MERGE dbo.CONTACT" in load)
      and "INSERT INTO dbo.UPR_CONTACT" in load)
check("Load rebuilds UPR_CLOSURE", "INSERT INTO dbo.UPR_CLOSURE" in load)
check("Load Review_Q uses new reason codes",
      "MISSING PARCELID" in load and "NO_ADDRESS_MATCH" in load and "INSUFFICIENT_DATA" in load)
check("Load preflight requires COMPLEX", "COMPLEX" in load and "Preflight" in load)
check("Load has TRY/CATCH", "BEGIN TRY" in load and "BEGIN CATCH" in load)
check("Search procedure usp_UPR_Search", "usp_UPR_Search" in search)
check("Search reads UPR + ENTITYTYPE", "REF_ENTITYTYPE" in search and "FROM dbo.UPR" in search)
check("Legacy flat load archived in legacy/",
      (ROOT / "legacy/load_upr_master_legacy_flat.sql").exists())

# --- regressions found during pre-delivery review -------------------------
check("CondoUnit column added in its own batch (needs GO before it is read)",
      "ADD CondoUnit" in load
      and "\nGO\n" in load[load.index("ADD CondoUnit"):load.index("s.CondoUnit")])
check("YearBuilt range-guarded before BUILDING insert",
      "BETWEEN 1600 AND YEAR(DATEADD(YEAR, 1, SYSDATETIME()))" in load)
check("Buildings labelled Building A / Building B",
      "N'Building '" in load and "BuildingSeq" in load)
check("Complex name is a business label, not Account# + COMPLEX",
      "BUILDING COMPLEX" in load and "N' COMPLEX'" not in load)
check("No invented SF property type (UNKNWN fallback)",
      "UNKNWN" in load and "N'SF')" not in load)
check("Account# XREF cannot break the source-record unique index",
      "UX_EXTERNAL_IDENTIFIER_SourceRecord" in ddl
      and "IdentifierType = 'SOURCE_RECORD_ID'" in ddl)
check("Building/Unit temp keys are not oversized text keys",
      "NVARCHAR(500) NOT NULL PRIMARY KEY" not in load
      and "NVARCHAR(550) NOT NULL PRIMARY KEY" not in load)
check("Review_Q dedupe is indexed",
      "IX_UPRMATCHREVIEW_Q_Dedupe" in load)
check("Complex address count uses MA rows only",
      "SourceSystem = N'ADDRESS_MASTER'" in load)
check("Scripts are pure ASCII (sqlcmd safe)",
      all(ord(c) < 128 for c in ddl + load + search))

# --- regressions found by the live SQL Server run -------------------------
check("All scripts SET QUOTED_IDENTIFIER ON (filtered indexes)",
      all("SET QUOTED_IDENTIFIER ON" in s for s in (ddl, load, search)))
check("No subquery inside PRINT (not allowed by T-SQL)",
      not re.search(r"PRINT[^;]*\(SELECT", load, re.S))
check("Timestamps truncated, not rounded, for <= SYSDATETIME checks",
      "CONVERT(VARCHAR(19), SYSDATETIME(), 126)" in load
      and "ChangedDate <= SYSDATETIME()" not in ddl)
check("Property re-run guard walks UPR_CLOSURE",
      "UPR_CLOSURE cl ON cl.DescendantUPRID = x.UPRID" in load)

print("=" * 60)
if failures:
    print(f"STATIC CHECK: {failures} FAILED")
    raise SystemExit(1)
print("STATIC CHECK: ALL PASSED")
