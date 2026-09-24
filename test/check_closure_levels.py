#!/usr/bin/env python3
"""Exercise closure upgrade and mutations in a disposable SQL Server database."""
import os
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
CONTAINER = os.environ.get("CONTAINER", "uprtest")
DATABASE = "UPR_Closure_IT_" + uuid.uuid4().hex


def sql(text, expect_error=False):
    result = subprocess.run(
        ["docker", "exec", "-i", CONTAINER, "bash", "-lc",
         'exec /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa '
         '-P "$MSSQL_SA_PASSWORD" -C -b -W -s "|" -h -1 -w 65535'],
        input=f"USE [{DATABASE}];\nGO\nSET QUOTED_IDENTIFIER ON; SET NOCOUNT ON;\n" + text,
        text=True, capture_output=True,
    )
    if (result.returncode != 0) != expect_error:
        raise AssertionError((result.stdout + result.stderr)[-6000:])
    return "\n".join(line for line in (result.stdout + result.stderr).splitlines()
                     if line.strip() and not line.startswith("Changed database context to "))


def run_file(path):
    return sql((ROOT / path).read_text().replace("USE UPRXDB_TEST;", f"USE [{DATABASE}];"))


def load():
    return run_file("scripts/load_upr_master.sql")


def closure():
    return {tuple(map(int, line.split("|"))) for line in sql(
        "SELECT UPRAncestry, DescendantUPRID, [Level] FROM dbo.UPR_CLOSURE;"
    ).splitlines() if line.strip()}


def verify():
    # Independent oracle: follow each descendant's parent chain in Python.
    parents = {}
    for line in sql("SELECT UPRID, COALESCE(ParentUPRID, 0) FROM dbo.UPR;").splitlines():
        if line.strip():
            child, parent = map(int, line.split("|"))
            parents[child] = parent
    expected = set()
    for descendant in parents:
        chain = [descendant]
        while parents[chain[-1]]:
            parent = parents[chain[-1]]
            assert parent not in chain, "Unexpected cycle in fixture"
            chain.append(parent)
        expected.update((ancestor, descendant, len(chain) - 1) for ancestor in chain)
    actual = closure()
    assert actual == expected, f"Closure mismatch: missing {expected - actual}, extra {actual - expected}"
    return actual


def audit_id():
    return int(sql("SELECT COALESCE(MAX(AuditID), 0) FROM dbo.AuditLog;").strip())


def assert_quiet_rerun():
    before = verify()
    last = audit_id()
    load()
    assert verify() == before
    sql(f"""
IF EXISTS (SELECT 1 FROM dbo.AuditLog WHERE AuditID > {last}
           AND EntityName <> 'UPR_HIER_LOAD')
    THROW 51001, 'Unchanged rerun wrote business audit events.', 1;
""")


# Creation is the only command that cannot select the database yet.
subprocess.run(
    ["docker", "exec", CONTAINER, "bash", "-lc",
     'exec /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa '
     f'-P "$MSSQL_SA_PASSWORD" -C -b -Q "CREATE DATABASE [{DATABASE}];"'],
    check=True, capture_output=True, text=True,
)
try:
    run_file("test/local_it_setup.sql")
    run_file("ddl/03_new_upr_schema.sql")
    run_file("scripts/install_upr_audit.sql")
    load()
    verify()
    assert_quiet_rerun()
    print("PASS: new schema stores exact ancestor paths and root levels; unchanged rerun is quiet")

    # Another_UPR_Illustration.docx: explicit Property > Buildings > Units/Condo.
    # These parent relationships are supplied by the fixture, not inferred from
    # MA/SDAT accounts. A child Condo keeps its own account and entity type.
    sql("""
DECLARE @Nodes TABLE (NodeID INT PRIMARY KEY, ParentID INT, Kind VARCHAR(20),
    AccountNumber VARCHAR(50), UnitNumber VARCHAR(50), UPRID BIGINT);
INSERT @Nodes (NodeID, ParentID, Kind, AccountNumber, UnitNumber) VALUES
 (1, NULL, 'Property', '01231829', NULL), (2, 1, 'Building', NULL, NULL),
 (3, 1, 'Building', NULL, NULL), (4, 2, 'Unit', NULL, 'Apt 101'),
 (5, 2, 'Unit', NULL, 'Basement 2'), (6, 2, 'Unit', NULL, 'Loft 5'),
 (7, 3, 'Unit', NULL, 'Building 5'), (8, 3, 'Unit', NULL, 'Apt 102'),
 (9, 3, 'Condo', '08123748', NULL);
DECLARE @NodeID INT = 1;
WHILE @NodeID <= 9
BEGIN
    INSERT dbo.UPR (EntityTypeID, ParentUPRID, AccountNumber)
    SELECT e.EntityTypeID, p.UPRID, n.AccountNumber FROM @Nodes n
    INNER JOIN dbo.REF_ENTITYTYPE e ON e.Description = n.Kind
    LEFT JOIN @Nodes p ON p.NodeID = n.ParentID WHERE n.NodeID = @NodeID;
    UPDATE @Nodes SET UPRID = SCOPE_IDENTITY() WHERE NodeID = @NodeID;
    SET @NodeID += 1;
END;
INSERT dbo.PROPERTY (UPRID, PropertyTypeID)
SELECT n.UPRID, pt.PropertyTypeID FROM @Nodes n CROSS JOIN dbo.REF_PROPERTYTYPE pt
WHERE n.NodeID = 1 AND pt.PropertyTypeCode = 'UNKNWN';
INSERT dbo.BUILDING (UPRID, YearBuilt)
SELECT UPRID, CASE NodeID WHEN 2 THEN 1968 ELSE 2025 END FROM @Nodes WHERE Kind = 'Building';
INSERT dbo.UNIT (UPRID, BuildingID, UnitNumber)
SELECT n.UPRID, b.BuildingID, n.UnitNumber FROM @Nodes n
INNER JOIN @Nodes p ON p.NodeID = n.ParentID
INNER JOIN dbo.BUILDING b ON b.UPRID = p.UPRID WHERE n.Kind = 'Unit';
INSERT dbo.CONDO (UPRID) SELECT UPRID FROM @Nodes WHERE Kind = 'Condo';
""")
    load()
    verify()
    sql("""
DECLARE @Root BIGINT = (SELECT UPRID FROM dbo.UPR WHERE AccountNumber = '01231829');
DECLARE @Condo BIGINT = (SELECT UPRID FROM dbo.UPR WHERE AccountNumber = '08123748');
IF (SELECT COUNT(*) FROM dbo.UPR_CLOSURE WHERE UPRAncestry = @Root) <> 9
   OR (SELECT COUNT(*) FROM dbo.UPR_CLOSURE WHERE DescendantUPRID = @Condo AND [Level] = 2) <> 3
    THROW 51006, 'Illustrated Property tree or child Condo ancestor paths were lost.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.CONDO c INNER JOIN dbo.UPR u ON u.UPRID = c.UPRID
    INNER JOIN dbo.BUILDING b ON b.UPRID = u.ParentUPRID WHERE c.UPRID = @Condo)
    THROW 51007, 'Illustrated Condo no longer belongs to its Building.', 1;
""")
    listing = run_file('scripts/list_upr_hierarchy.sql')
    assert '01231829|08123748|Condo' in listing, 'Report lost the child Condo account or type'
    assert_quiet_rerun()
    print('PASS: illustrated nine-node tree retains child Condo account, parent, ancestor paths and report')

    # Reproduce an already populated two-column client closure table. Reinstall
    # auditing against that old shape to also test trigger behavior on upgrade.
    before = verify()
    sql("""
ALTER TABLE dbo.UPR_CLOSURE DROP CONSTRAINT CK_UPR_CLOSURE_Level;
ALTER TABLE dbo.UPR_CLOSURE DROP COLUMN [Level];
""")
    run_file("scripts/install_upr_audit.sql")
    last = audit_id()
    load()
    assert verify() == before, "Upgrade changed the existing hierarchy"
    sql(f"""
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.UPR_CLOSURE')
           AND name = 'Level' AND (is_nullable = 1 OR TYPE_NAME(user_type_id) <> 'int'))
    THROW 51002, 'Upgrade did not enforce Level INT NOT NULL.', 1;
IF (SELECT COUNT(*) FROM dbo.AuditLog WHERE AuditID > {last}
    AND EntityName = 'UPR_CLOSURE' AND OperationType = 'UPDATE') <> {len(before)}
    THROW 51003, 'Existing closure level backfill was not fully audited.', 1;
IF EXISTS (SELECT 1 FROM dbo.AuditLog WHERE AuditID > {last}
    AND EntityName = 'UPR_CLOSURE' AND JSON_VALUE(NewValues, '$.Level') IS NULL)
    THROW 51004, 'Audit trigger omitted the added Level column.', 1;
""")
    assert_quiet_rerun()
    print("PASS: populated legacy schema upgrades in place, audits Level, and reruns without changes")

    # Source-independent branches exercise arbitrary depth and a moved subtree.
    sql("""
DECLARE @Et INT = (SELECT EntityTypeID FROM dbo.REF_ENTITYTYPE WHERE Description = 'Property');
INSERT dbo.UPR (EntityTypeID, AccountNumber) VALUES (@Et, 'LEVEL_ROOT');
DECLARE @Root BIGINT = SCOPE_IDENTITY();
INSERT dbo.UPR (EntityTypeID, ParentUPRID) VALUES (@Et, @Root);
DECLARE @Branch BIGINT = SCOPE_IDENTITY();
INSERT dbo.UPR (EntityTypeID, ParentUPRID) VALUES (@Et, @Branch);
INSERT dbo.UPR (EntityTypeID, AccountNumber) VALUES (@Et, 'LEVEL_OTHER');
DECLARE @Other BIGINT = SCOPE_IDENTITY();
INSERT dbo.UPR (EntityTypeID, ParentUPRID) VALUES (@Et, @Other);
""")
    load()
    before = verify()
    sql("""
DECLARE @Root BIGINT = (SELECT UPRID FROM dbo.UPR WHERE AccountNumber = 'LEVEL_ROOT');
DECLARE @Other BIGINT = (SELECT UPRID FROM dbo.UPR WHERE AccountNumber = 'LEVEL_OTHER');
DECLARE @NewParent BIGINT = (SELECT UPRID FROM dbo.UPR WHERE ParentUPRID = @Other);
UPDATE dbo.UPR SET ParentUPRID = @NewParent WHERE ParentUPRID = @Root;
""")
    last = audit_id()
    load()
    after = verify()
    assert max(level for _, _, level in after) == 3
    assert before != after
    sql(f"""
IF NOT EXISTS (SELECT 1 FROM dbo.AuditLog WHERE AuditID > {last}
    AND EntityName = 'UPR_CLOSURE' AND OperationType = 'UPDATE'
    AND JSON_VALUE(OldValues, '$.Level') <> JSON_VALUE(NewValues, '$.Level'))
    THROW 51005, 'Surviving subtree closure rows did not audit their changed level.', 1;
""")
    assert_quiet_rerun()
    print("PASS: reparenting repairs paths and surviving rows' levels, including depth 3")

    sql("UPDATE dbo.UPR_CLOSURE SET [Level] = 99;")
    load()
    assert verify() == after
    result = sql("UPDATE dbo.UPR_CLOSURE SET [Level] = -1;", expect_error=True)
    assert "CK_UPR_CLOSURE_Level" in result
    print("PASS: incorrect levels are repaired and negative levels are rejected")

    sql("""
DECLARE @Other BIGINT = (SELECT UPRID FROM dbo.UPR WHERE AccountNumber = 'LEVEL_OTHER');
DECLARE @Child BIGINT = (SELECT UPRID FROM dbo.UPR WHERE ParentUPRID = @Other);
UPDATE dbo.UPR SET ParentUPRID = @Child WHERE UPRID = @Other;
""")
    last = audit_id()
    result = sql((ROOT / "scripts/load_upr_master.sql").read_text().replace(
        "USE UPRXDB_TEST;", f"USE [{DATABASE}];"), expect_error=True)
    assert "cycle or an unreachable parent" in result
    assert closure() == after, "Failed load changed closure"
    assert audit_id() == last, "Failed load retained transactional audit events"
    print("PASS: cyclic hierarchy fails clearly and rolls back the load")
finally:
    sql(f"USE master; ALTER DATABASE [{DATABASE}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; "
        f"DROP DATABASE [{DATABASE}];")
