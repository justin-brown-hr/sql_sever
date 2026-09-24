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


listing = (ROOT / "scripts/list_upr_hierarchy.sql").read_text().replace(
    "USE UPRXDB_TEST;", f"USE [{DATABASE}];")


def report(account=None, limit=None):
    text = listing
    for variable, value in (("FilterAccount", account), ("MaxRows", limit)):
        literal = "NULL" if value is None else (
            "N'" + value.replace("'", "''") + "'" if isinstance(value, str) else str(value))
        text, changes = re.subn(
            rf"(DECLARE @{variable}\s+[^=;]+?=\s*)NULL;",
            lambda m: m[1] + literal + ";", text, count=1)
        assert changes == 1, f"Cannot set @{variable} in listing"
    return sql(text, expect_error=limit is not None and limit <= 0)


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
DECLARE @Condo INT = (SELECT EntityTypeID FROM dbo.REF_ENTITYTYPE WHERE Description = 'Condo');
DECLARE @Building INT = (SELECT EntityTypeID FROM dbo.REF_ENTITYTYPE WHERE Description = 'Building');
DECLARE @Unit INT = (SELECT EntityTypeID FROM dbo.REF_ENTITYTYPE WHERE Description = 'Unit');
;WITH Numbers AS (
    SELECT TOP (50001) n = ROW_NUMBER() OVER (ORDER BY a.object_id, b.object_id)
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT dbo.UPR (EntityTypeID, AccountNumber)
SELECT @Condo, CASE n
    WHEN 1 THEN '23456789' WHEN 2 THEN 'OTHER'
    WHEN 3 THEN '1234567890123' WHEN 4 THEN 'ABC-123'
    ELSE RIGHT('00000000' + CONVERT(VARCHAR(8), n), 8) END
FROM Numbers;
DECLARE @Root1 BIGINT = (SELECT UPRID FROM dbo.UPR WHERE AccountNumber = '23456789');
DECLARE @Root2 BIGINT = (SELECT UPRID FROM dbo.UPR WHERE AccountNumber = 'OTHER');
INSERT dbo.CONDO (UPRID) SELECT UPRID FROM dbo.UPR;
INSERT dbo.UPR (EntityTypeID, ParentUPRID) VALUES (@Building, @Root1);
DECLARE @BU1 BIGINT = SCOPE_IDENTITY();
INSERT dbo.BUILDING (UPRID) VALUES (@BU1);
DECLARE @B1 BIGINT = SCOPE_IDENTITY();
INSERT dbo.UPR (EntityTypeID, ParentUPRID) VALUES (@Building, @Root2);
DECLARE @BU2 BIGINT = SCOPE_IDENTITY();
INSERT dbo.BUILDING (UPRID) VALUES (@BU2);
DECLARE @B2 BIGINT = SCOPE_IDENTITY();
INSERT dbo.UPR (EntityTypeID, ParentUPRID) VALUES (@Unit, @BU1);
INSERT dbo.UNIT (UPRID, BuildingID, UnitNumber) VALUES (SCOPE_IDENTITY(), @B1, 'VALID_BUILDING');
INSERT dbo.UPR (EntityTypeID, ParentUPRID) VALUES (@Unit, @Root1);
INSERT dbo.UNIT (UPRID, BuildingID, UnitNumber) VALUES (SCOPE_IDENTITY(), @B1, 'VALID_CONDO');
INSERT dbo.UPR (EntityTypeID, ParentUPRID) VALUES (@Unit, @BU1);
INSERT dbo.UNIT (UPRID, BuildingID, UnitNumber) VALUES (SCOPE_IDENTITY(), @B2, 'WRONG_BUILDING');
INSERT dbo.UPR (EntityTypeID, ParentUPRID) VALUES (@Unit, @Root1);
INSERT dbo.UNIT (UPRID, BuildingID, UnitNumber) VALUES (SCOPE_IDENTITY(), @B2, 'WRONG_CONDO');
;WITH Closure AS (
    SELECT UPRAncestry = UPRID, DescendantUPRID = UPRID FROM dbo.UPR
    UNION ALL
    SELECT cl.UPRAncestry, u.UPRID FROM Closure cl
    INNER JOIN dbo.UPR u ON u.ParentUPRID = cl.DescendantUPRID
)
INSERT dbo.UPR_CLOSURE (UPRAncestry, DescendantUPRID, [Level])
SELECT cl.UPRAncestry, cl.DescendantUPRID,
    (SELECT COUNT(*) - 1 FROM Closure path WHERE path.DescendantUPRID = cl.DescendantUPRID)
FROM Closure cl;
""")
    full = report()
    rows = tree(full)
    assert len(rows) == 50007 and sum(r[0] == "0" for r in rows) == 50001
    assert "WARNING:" not in full
    print("PASS: default includes 50,001 roots and every child without loader functions")

    for account, expected in [
        ("123456789", "23456789"), ("00023456789", "23456789"),
        ("000023456789", "23456789"), ("23456789", "23456789"),
        (" 5 ", "00000005"), ("1234567890123", "1234567890123"),
        ("ABC-123", "ABC-123"),
    ]:
        output = report(account)
        roots = [r for r in tree(output) if r[0] == "0"]
        assert len(roots) == 1 and roots[0][5] == expected, account
    assert len(tree(report("   "))) == 50007
    assert not tree(report("NO_SUCH_ACCOUNT"))
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
    assert len(issues) == 2
    assert any("WRONG_BUILDING" in line for line in issues)
    assert any("WRONG_CONDO" in line for line in issues)
    assert all("VALID_" not in line for line in issues)
    units = [r for r in tree(filtered) if r[7] == "Unit"]
    assert len(units) == 4 and all(r[-2] != "NULL" for r in units)
    assert len(tree(filtered)) == 6
    print("PASS: valid Building/Condo units accepted; wrong links flagged; BuildingID displayed")
finally:
    sql(f"USE master; ALTER DATABASE [{DATABASE}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; "
        f"DROP DATABASE [{DATABASE}];")
