#!/usr/bin/env python3
"""Audit migration, load attribution, failure history and client report checks."""
import os
import re
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
CONTAINER = os.environ.get("CONTAINER", "uprtest")
DATABASE = "UPR_Audit_IT_" + uuid.uuid4().hex


def sql(text, expect_error=False, continue_after_error=False, full_values=False):
    result = subprocess.run(
        ["docker", "exec", "-i", CONTAINER, "bash", "-lc",
         'exec /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa '
         '-P "$MSSQL_SA_PASSWORD" -C -s "|" -w 65535 '
         + ('-y 0 ' if full_values else '-W -h -1 ')
         + ("" if continue_after_error else "-b")],
        input=f"USE [{DATABASE}];\nGO\nSET QUOTED_IDENTIFIER ON; SET NOCOUNT ON;\n" + text,
        text=True, capture_output=True,
    )
    if not continue_after_error and ((result.returncode != 0) != expect_error):
        raise AssertionError((result.stdout + result.stderr)[-6000:])
    return "\n".join(line for line in (result.stdout + result.stderr).splitlines()
                     if line.strip() and not line.startswith("Changed database context to "))


def script(path):
    return (ROOT / path).read_text().replace("USE UPRXDB_TEST;", f"USE [{DATABASE}];")


def latest_run():
    return sql("SELECT TOP (1) RunID FROM dbo.UPR_LOAD_RUN ORDER BY StartedAt DESC;").strip()


subprocess.run(
    ["docker", "exec", CONTAINER, "bash", "-lc",
     'exec /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa '
     f'-P "$MSSQL_SA_PASSWORD" -C -b -Q "CREATE DATABASE [{DATABASE}];"'],
    check=True, capture_output=True, text=True,
)
try:
    sql(script("test/local_it_setup.sql"))
    sql(script("ddl/03_new_upr_schema.sql"))
    # Reproduce the client's pre-upgrade AuditLog, with existing history.
    sql("""
DROP INDEX IX_AuditLog_RunID ON dbo.AuditLog;
ALTER TABLE dbo.AuditLog DROP COLUMN RunID, SessionID;
DROP TABLE dbo.UPR_LOAD_RUN;
INSERT dbo.AuditLog (EntityName, EntityKey, OperationType, ChangedBy, ChangeSummary, OldValues, NewValues)
VALUES ('UNIT', '{"UnitID":999}', 'UPDATE', 'legacy-test', 'KEEP HISTORY',
        '{"UnitNumber":"BEFORE"}', '{"UnitNumber":"AFTER"}');
""")
    sql(script("scripts/install_upr_audit.sql"))
    sql(script("scripts/install_upr_audit.sql"))
    sql("""
IF (SELECT COUNT(*) FROM dbo.AuditLog) <> 1
 OR NOT EXISTS (SELECT 1 FROM dbo.AuditLog WHERE ChangeSummary = 'KEEP HISTORY'
    AND RunID IS NULL AND SessionID IS NULL AND JSON_VALUE(NewValues, '$.UnitNumber') = 'AFTER')
    THROW 51001, 'Upgrade lost or reattributed existing audit history.', 1;
""")
    output = sql(script("scripts/list_upr_audit.sql"))
    assert "BEFORE|AFTER" in output, output[-4000:]
    print("PASS: existing audit history survives repeated installation and appears in the report", flush=True)

    # Same SQL connection: restore a caller context and then audit a manual edit.
    output = sql("EXEC sys.sp_set_session_context @key = N'UPR_AuditRunID', @value = N'caller-value';\nGO\n"
                 + script("scripts/load_upr_master.sql") + """
IF CONVERT(NVARCHAR(128), SESSION_CONTEXT(N'UPR_AuditRunID')) <> N'caller-value'
    THROW 51002, 'Successful load leaked session context.', 1;
INSERT dbo.REF_ENTITYTYPE (Description) VALUES ('MANUAL AFTER LOAD');
IF NOT EXISTS (SELECT 1 FROM dbo.AuditLog WHERE EntityName = 'REF_ENTITYTYPE'
    AND JSON_VALUE(NewValues, '$.Description') = 'MANUAL AFTER LOAD'
    AND RunID IS NULL AND SessionID = @@SPID)
    THROW 51003, 'Manual edit was lost or attributed to the completed load.', 1;
""")
    first = latest_run()
    sql(f"""
IF NOT EXISTS (SELECT 1 FROM dbo.UPR_LOAD_RUN WHERE RunID = '{first}'
    AND RunStatus = 'COMPLETED' AND FinishedAt >= StartedAt AND SourceRowsRead > 0 AND RejectedRows > 0)
    THROW 51004, 'First run lacks status/source counts.', 1;
IF (SELECT COUNT(*) FROM dbo.AuditLog WHERE RunID = '{first}' AND EntityName <> 'UPR_HIER_LOAD') < 100
    THROW 51005, 'First run did not collect its row events.', 1;
IF EXISTS (SELECT 1 FROM dbo.AuditLog WHERE RunID = '{first}' AND SessionID IS NULL)
    THROW 51006, 'Run event lost session metadata.', 1;
""")
    sql(script("scripts/load_upr_master.sql"))
    second = latest_run()
    assert first != second
    sql(f"""
IF (SELECT COUNT(*) FROM dbo.AuditLog WHERE RunID = '{second}') <> 1
 OR NOT EXISTS (SELECT 1 FROM dbo.UPR_LOAD_RUN WHERE RunID = '{second}' AND RunStatus = 'COMPLETED')
    THROW 51007, 'Unchanged run should retain its status and only its batch summary.', 1;
""")
    output = sql("EXEC dbo.usp_UPR_AuditReport @LatestRun = 1;")
    assert second.upper() in output.upper() and first.upper() not in output.upper()
    assert "|0|0|0|" in output
    print("PASS: distinct load IDs, complete row attribution, zero-change runs and same-session manual edits", flush=True)

    sql("""
INSERT dbo.REF_ENTITYTYPE (Description) VALUES ('Audit Case'), ('Audit Delete');
UPDATE dbo.REF_ENTITYTYPE SET Description = 'audit case ' WHERE Description = 'Audit Case';
DELETE dbo.REF_ENTITYTYPE WHERE Description = 'Audit Delete';
""")
    output = sql("EXEC dbo.usp_UPR_AuditReport @TableName = N'REF_ENTITYTYPE';")
    assert "|UPDATE|" in output and "|DELETE|" in output and "|INSERT|" in output
    assert "Audit Case|audit case |Value|Value" in output, output[-4000:]
    # Long values and NULL changes must survive the field view without JSON_VALUE truncation.
    sql("""
INSERT dbo.CONTACT (ContactTypeID, OrganizationName)
SELECT TOP (1) ContactTypeID, 'AUDIT NULL TEST' FROM dbo.REF_CONTACTTYPE;
UPDATE dbo.CONTACT SET OrganizationName = NULL WHERE OrganizationName = 'AUDIT NULL TEST';
INSERT dbo.AuditLog (EntityName, EntityKey, OperationType, ChangedBy, OldValues, NewValues)
VALUES ('REPORT_FIXTURE', '{}', 'UPDATE', 'test', '{"Text":null}',
    N'{"Text":"' + REPLICATE(CONVERT(NVARCHAR(MAX), N'X'), 5000) + N'"}');
""")
    output = sql("EXEC dbo.usp_UPR_AuditReport @TableName = N'CONTACT';")
    assert "AUDIT NULL TEST|NULL|Value|NULL" in output, output[-4000:]
    output = sql("EXEC dbo.usp_UPR_AuditReport @TableName = N'REPORT_FIXTURE';", full_values=True)
    assert "X" * 5000 in output
    output = sql("EXEC dbo.usp_UPR_AuditReport @Since = '9999-01-01';")
    assert "|INSERT|" not in output and "|UPDATE|" not in output
    print("PASS: report filters and field values preserve case, trailing spaces, NULL and long text", flush=True)

    # A new source row causes real writes before a disconnected cycle fails
    # Step 12. Neither the new property nor its row events may survive.
    sql("""
INSERT dbo.MAIncomingTableX1
    (MasterAddressID, Account, StreetNumber, StreetName, StreetType, City, ZipCode, LUCategory)
VALUES (99991, '99998888', '50', 'AUDIT ROLLBACK', 'ST', 'TEST CITY', '20850', 'Office');
DECLARE @Et INT = (SELECT TOP (1) EntityTypeID FROM dbo.REF_ENTITYTYPE);
INSERT dbo.UPR (EntityTypeID) VALUES (@Et);
DECLARE @A BIGINT = SCOPE_IDENTITY();
INSERT dbo.UPR (EntityTypeID, ParentUPRID) VALUES (@Et, @A);
DECLARE @B BIGINT = SCOPE_IDENTITY();
UPDATE dbo.UPR SET ParentUPRID = @B WHERE UPRID = @A;
""")
    before = sql("SELECT MAX(AuditID) FROM dbo.AuditLog;").strip()
    failed_output = sql("EXEC sys.sp_set_session_context @key = N'UPR_AuditRunID', @value = N'failure-caller';\nGO\n"
                        + script("scripts/load_upr_master.sql") + """
SELECT N'RESTORED=' + CONVERT(NVARCHAR(128), SESSION_CONTEXT(N'UPR_AuditRunID'));
""", continue_after_error=True)
    assert "cycle or an unreachable parent" in failed_output
    assert "RESTORED=failure-caller" in failed_output, failed_output[-4000:]
    failed = latest_run()
    sql(f"""
IF NOT EXISTS (SELECT 1 FROM dbo.UPR_LOAD_RUN WHERE RunID = '{failed}'
    AND RunStatus = 'FAILED' AND FinishedAt IS NOT NULL AND ErrorMessage LIKE '%cycle%')
    THROW 51008, 'Failed load status was not retained.', 1;
IF EXISTS (SELECT 1 FROM dbo.AuditLog WHERE AuditID > {before})
    THROW 51009, 'Failed load retained rolled-back row events.', 1;
IF EXISTS (SELECT 1 FROM dbo.UPR WHERE AccountNumber = '99998888')
    THROW 51010, 'Failed load retained business writes.', 1;
""")
    print("PASS: failed run retained with error, session restored, rolled-back events absent", flush=True)

    # A caller transaction must remain open and retain its own work.
    guarded_batches = [batch for batch in re.split(r'^\s*GO\s*$', script("scripts/load_upr_master.sql"), flags=re.M)
                       if "RAISERROR ('Run the loader outside" in batch]
    assert len(guarded_batches) == 2
    for batch in guarded_batches:
        # Catch in SQL so sqlcmd does not lose its cursor after RAISERROR/RETURN.
        output = sql("SET XACT_ABORT ON; BEGIN TRANSACTION; BEGIN TRY\n"
                     + "EXEC sys.sp_executesql N'" + batch.replace("'", "''") + "';\n"
                     + "END TRY BEGIN CATCH PRINT ERROR_MESSAGE(); END CATCH;\n"
                     + "SELECT N'CALLER_TRAN=' + CONVERT(NVARCHAR(10), @@TRANCOUNT); ROLLBACK;")
        assert "Run the loader outside an existing transaction" in output
        assert "CALLER_TRAN=1" in output, output[-4000:]
    print("PASS: caller-owned transaction is rejected without rollback", flush=True)
finally:
    sql(f"USE master; ALTER DATABASE [{DATABASE}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; "
        f"DROP DATABASE [{DATABASE}];")
