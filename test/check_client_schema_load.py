#!/usr/bin/env python3
"""SQL Server regression: load with client AuditLog and no support-table migration.

Runs only in a disposable database in the existing test container.
"""
import os
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
CONTAINER = os.environ.get('CONTAINER', 'uprtest')
DATABASE = 'UPR_ClientLayout_IT_' + uuid.uuid4().hex


def sql(text, error=False):
    result = subprocess.run(
        ['docker', 'exec', '-i', CONTAINER, 'bash', '-lc',
         'exec /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa '
         '-P "$MSSQL_SA_PASSWORD" -C -b -W -s "|" -h -1 -w 65535'],
        input=f'USE [{DATABASE}];\nGO\nSET QUOTED_IDENTIFIER ON; SET NOCOUNT ON;\n' + text,
        text=True, capture_output=True)
    output = result.stdout + result.stderr
    if (result.returncode != 0) != error:
        raise AssertionError(output[-7000:])
    return '\n'.join(x for x in output.splitlines()
                     if x.strip() and not x.startswith('Changed database context to'))


def run_file(name):
    # Setup also contains DB_ID/CREATE DATABASE, so replace every fixture DB
    # reference rather than only USE. Never create a second fixed-name database.
    return sql((ROOT / name).read_text().replace('UPRXDB_TEST', DATABASE))


subprocess.run(['docker', 'exec', CONTAINER, 'bash', '-lc',
                'exec /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa '
                f'-P "$MSSQL_SA_PASSWORD" -C -b -Q "CREATE DATABASE [{DATABASE}];"'],
               check=True, capture_output=True, text=True)
try:
    run_file('test/local_it_setup.sql')
    run_file('ddl/03_new_upr_schema.sql')
    sql("""
DROP VIEW dbo.AUDIT_LOG;
DROP TABLE dbo.AUDIT_LOG_CONTEXT;
DROP TABLE dbo.UPR_LOAD_RUN;
DROP TABLE dbo.AUDIT_ENTITY_RECORD;
DROP TABLE dbo.UPR_CONDO_LEGACY;
INSERT dbo.REF_ENTITY_IDENTIFICATION(EntityName) VALUES('UPR');
INSERT dbo.AuditLog(EntityNameID,EntityRecordID,OperationType,ChangedBy,NewValues)
SELECT EntityID,999,'INSERT','CLIENT_HISTORY',N'{"keep":true}'
FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityName='UPR';
GO
CREATE TRIGGER dbo.Client_UPR_Audit ON dbo.UPR AFTER INSERT,UPDATE,DELETE AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.AuditLog(UPRID,EntityNameID,EntityRecordID,OperationType,ChangedBy)
    SELECT COALESCE(i.UPRID,d.UPRID),e.EntityID,COALESCE(i.UPRID,d.UPRID),
        CASE WHEN i.UPRID IS NULL THEN 'DELETE' WHEN d.UPRID IS NULL THEN 'INSERT' ELSE 'UPDATE' END,
        'CLIENT_TRIGGER'
    FROM inserted i FULL JOIN deleted d ON d.UPRID=i.UPRID
    CROSS JOIN dbo.REF_ENTITY_IDENTIFICATION e WHERE e.EntityName='UPR';
END;
""")
    layout = sql("SELECT column_id,name,system_type_id,max_length,is_nullable FROM sys.columns WHERE object_id=OBJECT_ID(N'dbo.AuditLog') ORDER BY column_id;")
    objects = sql("SELECT object_id,name FROM sys.tables WHERE schema_id=SCHEMA_ID('dbo') ORDER BY name;")
    trigger = sql("SELECT OBJECT_DEFINITION(OBJECT_ID(N'dbo.Client_UPR_Audit'));")
    schema_report = run_file('scripts/check_upr_client_schema.sql')
    assert 'PASS: required names visible' in schema_report
    assert 'CORE_MISSING OR NOT VISIBLE' not in schema_report
    # Confirm the read-only diagnostic detects a missing source column, then
    # restore its name before loading. Renaming preserves the fixture data.
    sql("EXEC sys.sp_rename N'dbo.MAIncomingTableX1.LUCategory',N'LUCategoryHidden',N'COLUMN';")
    assert 'CORE_MISSING OR NOT VISIBLE' in run_file('scripts/check_upr_client_schema.sql')
    sql("EXEC sys.sp_rename N'dbo.MAIncomingTableX1.LUCategoryHidden',N'LUCategory',N'COLUMN';")
    output = run_file('scripts/load_upr_master.sql')
    assert 'Client AuditLog mode' in output and 'NOT_AVAILABLE' in output
    counts = run_file('test/local_it_counts.sql')
    run_file('scripts/load_upr_master.sql')
    assert run_file('test/local_it_counts.sql') == counts
    assert sql("SELECT column_id,name,system_type_id,max_length,is_nullable FROM sys.columns WHERE object_id=OBJECT_ID(N'dbo.AuditLog') ORDER BY column_id;") == layout
    assert sql("SELECT object_id,name FROM sys.tables WHERE schema_id=SCHEMA_ID('dbo') ORDER BY name;") == objects
    assert sql("SELECT OBJECT_DEFINITION(OBJECT_ID(N'dbo.Client_UPR_Audit'));") == trigger
    sql("""
IF NOT EXISTS(SELECT 1 FROM dbo.AuditLog WHERE ChangedBy='CLIENT_HISTORY' AND NewValues=N'{"keep":true}')
 OR NOT EXISTS(SELECT 1 FROM dbo.AuditLog WHERE ChangedBy='CLIENT_TRIGGER')
    THROW 51000,'Existing history or custom row trigger was lost.',1;
IF (SELECT COUNT(*) FROM dbo.AuditLog a JOIN dbo.REF_ENTITY_IDENTIFICATION e ON e.EntityID=a.EntityNameID
    WHERE e.EntityName='UPR_HIER_LOAD' AND ISJSON(a.NewValues)=1
      AND JSON_VALUE(a.NewValues,'$.runId') IS NOT NULL)<>2
    THROW 51000,'Native batch summary or run ID missing.',1;
""")
    selected = int(sql('SELECT MIN(UPRID) FROM dbo.UPR;'))
    check = (ROOT / 'test/check_upr_closure_distance.sql').read_text().replace(
        'DECLARE @UPRID BIGINT = 207075;', f'DECLARE @UPRID BIGINT = {selected};')
    assert 'PASS' in sql(check)
    # Optional live name remains usable without the removed archive.
    sql("ALTER TABLE dbo.CONDO ADD CondoName VARCHAR(200) NULL;")
    sql("UPDATE dbo.CONDO SET CondoName='CLIENT NAME';")
    run_file('scripts/load_upr_master.sql')
    assert sql("SELECT COUNT(*) FROM dbo.CONDO WHERE CondoName='CLIENT NAME';") != '0'
    print('PASS: native client schema, existing triggers/history, no new tables, repeated load and closure indexes')
    # The enhanced mode must no longer require its compatibility view either.
    sql('DROP TRIGGER dbo.Client_UPR_Audit;')
    run_file('scripts/install_upr_audit.sql')
    sql('DROP VIEW dbo.AUDIT_LOG;')
    run_file('scripts/load_upr_master.sql')
    sql("""
IF NOT EXISTS(SELECT 1 FROM dbo.UPR_LOAD_RUN WHERE RunStatus='COMPLETED')
 OR NOT EXISTS(SELECT 1 FROM dbo.AUDIT_LOG_CONTEXT WHERE RunID IS NOT NULL)
    THROW 51000,'Enhanced run/context auditing stopped working without the compatibility view.',1;
""")
    print('PASS: enhanced auditing also loads without AUDIT_LOG view')
finally:
    sql(f'USE master; ALTER DATABASE [{DATABASE}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [{DATABASE}];')
