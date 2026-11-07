#!/usr/bin/env python3
"""Exercise the actual listing SQL in a disposable database in CONTAINER.

Requires the SQL Server container used by run_local_it.sh (default: uprtest).
The loader functions are deliberately absent to test the client's reported error.
"""
import os
from pathlib import Path
import re
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
DATABASE = "UPR_Listing_IT_" + uuid.uuid4().hex
CONTAINER = os.environ.get("CONTAINER", "uprtest")


def sql(text, expect_error=False):
    result = subprocess.run(
        ["docker", "exec", "-i", CONTAINER, "bash", "-lc",
         'exec /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa '
         '-P "$MSSQL_SA_PASSWORD" -C -b -W -s "|" -h -1 -w 65535'],
        input=text, text=True, capture_output=True, check=False,
    )
    if (result.returncode != 0) != expect_error:
        raise AssertionError((result.stdout + result.stderr)[-4000:])
    return result.stdout + result.stderr


listing = f"USE [{DATABASE}];\nGO\n" + (ROOT / "scripts/list_upr_hierarchy.sql").read_text()


def report(account=None, limit=None, entity=None, expect_error=False):
    text = listing
    for variable, value in (("FilterAccount", account), ("MaxRows", limit), ("FilterEntity", entity)):
        literal = "NULL" if value is None else (
            "N'" + value.replace("'", "''") + "'" if isinstance(value, str) else str(value))
        text, changes = re.subn(
            rf"(DECLARE @{variable}\s+[^=;]+?=\s*)NULL;",
            lambda m: m[1] + literal + ";", text, count=1)
        assert changes == 1, f"Cannot set @{variable} in listing"
    return sql(text, expect_error=expect_error or (limit is not None and limit <= 0))


def tree(output):
    return [line.split("|") for line in output.splitlines()
            if re.match(r"^\d+\|", line)]


sql(f"CREATE DATABASE [{DATABASE}];")
try:
    sql((ROOT / "ddl/03_new_upr_schema.sql").read_text().replace(
        "USE UPRXDB_TEST;", f"USE [{DATABASE}];"))
    sql(f"USE [{DATABASE}];\n" + """
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
DROP TABLE dbo.ADU;
DECLARE @Condo INT = (SELECT EntityTypeID FROM dbo.REF_ENTITYTYPE WHERE Description = 'Condo');
DECLARE @Building INT = (SELECT EntityTypeID FROM dbo.REF_ENTITYTYPE WHERE Description = 'Building');
DECLARE @Unit INT = (SELECT EntityTypeID FROM dbo.REF_ENTITYTYPE WHERE Description = 'Unit');
;WITH Numbers AS (
    SELECT TOP (50001) n = ROW_NUMBER() OVER (ORDER BY a.object_id, b.object_id)
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT dbo.UPR (EntityTypeID, CreationUserID, LastUpdateUserID, LastUpdateDate, AccountNumber)
SELECT @Condo, 'fixture', 'fixture', SYSUTCDATETIME(), CASE n
    WHEN 1 THEN '123456789' WHEN 2 THEN 'OTHER'
    WHEN 6 THEN '23456789' WHEN 3 THEN '1234567890123' WHEN 4 THEN 'ABC-123'
    ELSE RIGHT('00000000' + CONVERT(VARCHAR(8), n), 8) END
FROM Numbers;
DECLARE @Root1 BIGINT = (SELECT UPRID FROM dbo.UPR WHERE AccountNumber = '123456789');
DECLARE @Root2 BIGINT = (SELECT UPRID FROM dbo.UPR WHERE AccountNumber = 'OTHER');
INSERT dbo.CONDO (UPRID, DeletedInd, CreationUserID, LastUpdateUserID, LastUpdateDate)
SELECT UPRID, 0, 'fixture', 'fixture', SYSUTCDATETIME() FROM dbo.UPR;
INSERT dbo.UPR (EntityTypeID, ParentUPRID, CreationUserID, LastUpdateUserID, LastUpdateDate) VALUES (@Building, @Root1, 'fixture', 'fixture', SYSUTCDATETIME());
DECLARE @BU1 BIGINT = SCOPE_IDENTITY();
INSERT dbo.BUILDING (UPRID, DeletedInd, CreationUserID, LastUpdateUserID, LastUpdateDate) VALUES (@BU1, 0, 'fixture', 'fixture', SYSUTCDATETIME());
DECLARE @B1 BIGINT = SCOPE_IDENTITY();
INSERT dbo.UPR (EntityTypeID, ParentUPRID, CreationUserID, LastUpdateUserID, LastUpdateDate) VALUES (@Building, @Root2, 'fixture', 'fixture', SYSUTCDATETIME());
DECLARE @BU2 BIGINT = SCOPE_IDENTITY();
INSERT dbo.BUILDING (UPRID, DeletedInd, CreationUserID, LastUpdateUserID, LastUpdateDate) VALUES (@BU2, 0, 'fixture', 'fixture', SYSUTCDATETIME());
DECLARE @B2 BIGINT = SCOPE_IDENTITY();
INSERT dbo.UPR (EntityTypeID, ParentUPRID, CreationUserID, LastUpdateUserID, LastUpdateDate) VALUES (@Unit, @BU1, 'fixture', 'fixture', SYSUTCDATETIME());
INSERT dbo.UNIT (UPRID, UnitNumber, DeleteInd, CreationUserID, LastUpdateUserID) VALUES (SCOPE_IDENTITY(), 'VALID_BUILDING', 0, 'fixture', 'fixture');
INSERT dbo.UPR (EntityTypeID, ParentUPRID, CreationUserID, LastUpdateUserID, LastUpdateDate) VALUES (@Unit, @Root1, 'fixture', 'fixture', SYSUTCDATETIME());
INSERT dbo.UNIT (UPRID, UnitNumber, DeleteInd, CreationUserID, LastUpdateUserID) VALUES (SCOPE_IDENTITY(), 'DIRECT_CONDO', 0, 'fixture', 'fixture');
INSERT dbo.UPR (EntityTypeID, ParentUPRID, CreationUserID, LastUpdateUserID, LastUpdateDate) VALUES (@Unit, @BU1, 'fixture', 'fixture', SYSUTCDATETIME());
INSERT dbo.UNIT (UPRID, UnitNumber, DeleteInd, CreationUserID, LastUpdateUserID) VALUES (SCOPE_IDENTITY(), 'SECOND_BUILDING_UNIT', 0, 'fixture', 'fixture');
INSERT dbo.UPR (EntityTypeID, ParentUPRID, CreationUserID, LastUpdateUserID, LastUpdateDate) VALUES (@Unit, @Root1, 'fixture', 'fixture', SYSUTCDATETIME());
INSERT dbo.UNIT (UPRID, UnitNumber, DeleteInd, CreationUserID, LastUpdateUserID) VALUES (SCOPE_IDENTITY(), 'WRONG_CONDO', 0, 'fixture', 'fixture');
;WITH Closure AS (
    SELECT AncestorUPRID = UPRID, DescendantUPRID = UPRID, Distance = 0 FROM dbo.UPR
    UNION ALL
    SELECT cl.AncestorUPRID, u.UPRID, cl.Distance + 1 FROM Closure cl
    INNER JOIN dbo.UPR u ON u.ParentUPRID = cl.DescendantUPRID
)
INSERT dbo.UPR_CLOSURE (AncestorUPRID, DescendantUPRID, [Level])
SELECT cl.AncestorUPRID, cl.DescendantUPRID, cl.Distance
FROM Closure cl;
""")
    full = report()
    rows = tree(full)
    assert len(rows) == 50007 and sum(r[0] == "0" for r in rows) == 50001
    assert "WARNING:" not in full
    print("PASS: default includes 50,001 roots and every child without loader functions")

    for account, expected in [
        ("123456789", "123456789"), ("123-456-789", "123456789"),
        ("23456789", "23456789"),
        (" 5 ", "00000005"), ("1234567890123", "1234567890123"),
        ("ABC-123", "ABC-123"),
    ]:
        output = report(account)
        roots = [r for r in tree(output) if r[0] == "0"]
        assert len(roots) == 1 and roots[0][5] == expected, account
    assert len(tree(report("   "))) == 50007
    assert not tree(report("NO_SUCH_ACCOUNT"))
    assert not tree(report("00023456789"))
    assert not tree(report("000023456789"))
    print("PASS: numeric boundaries, whitespace, alphanumeric and absent account filters")

    capped = report(limit=1)
    assert sum(r[0] == "0" for r in tree(capped)) == 1
    assert "WARNING:" in capped and "|50001|1|50000" in capped
    assert "@MaxRows must be NULL" in report(limit=0)
    assert "@MaxRows must be NULL" in report(limit=-1)
    assert "WARNING:" not in report("123456789", limit=1)
    print("PASS: cap warning, omitted counts, exact cap and invalid limits")

    filtered = report("123456789")
    issues = [line for line in filtered.splitlines()
              if line.startswith("Unit has invalid Building link|")]
    # No UNIT.BuildingID in the client layout: a Unit is valid when its parent is a Building.
    assert len(issues) == 2
    assert any("DIRECT_CONDO" in line for line in issues)
    assert any("WRONG_CONDO" in line for line in issues)
    assert all("VALID_" not in line and "SECOND_BUILDING_UNIT" not in line for line in issues)
    units = [r for r in tree(filtered) if r[7] == "Unit"]
    assert len(units) == 4
    assert sum(r[-2] != "NULL" for r in units) == 2, "BuildingID shown for Units under a Building"
    assert len(tree(filtered)) == 6
    assert all(r[6] == "123456789" for r in units), "Units need root account context"
    print("PASS: Building units accepted; Units under a Condo flagged; parent BuildingID and account displayed")
    for entity, count in (("Condo",1),("Building",1),("Unit",4),("Complex",0),("Property",0),("ADU",0)):
        selected=tree(report("123456789",entity=entity))
        assert len(selected)==count and all(r[7]==entity for r in selected),entity
    selected=tree(report("123456789",entity="  unit  "))
    assert len(selected)==4 and all(r[6]=="123456789" for r in selected)
    assert {r[0] for r in selected}=={"1","2"}, "Do not renumber depth after filtering"
    for entity in ("ALL","", "  "):
        assert len(tree(report("123456789",entity=entity)))==6
    assert "Use Complex" in report(entity="Unitt",expect_error=True)
    assert len(tree(report(entity="Unit",limit=1)))==0 # root cap precedes entity filter
    print("PASS: entity filters and normalization, combined account scope, invalid names and root caps")

finally:
    sql(f"USE master; ALTER DATABASE [{DATABASE}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; "
        f"DROP DATABASE [{DATABASE}];")
