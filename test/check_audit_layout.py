#!/usr/bin/env python3
"""Client AuditLog layout and prior normalized-history migration; disposable DBs only.
Requires Docker SQL Server as used by run_local_it.sh and repository commit fce184f.
"""
import os
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
CONTAINER = os.environ.get('CONTAINER', 'uprtest')
DATABASE = 'UPR_Layout_IT_' + uuid.uuid4().hex


def sql(text, expect_error=False, database=None):
    result = subprocess.run(
        ['docker', 'exec', '-i', CONTAINER, 'bash', '-lc',
         'exec /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa '
         '-P "$MSSQL_SA_PASSWORD" -C -b -W -h -1 -s "|" -w 65535'],
        input=f'USE [{database or DATABASE}];\nGO\nSET QUOTED_IDENTIFIER ON; SET NOCOUNT ON;\n' + text,
        text=True, capture_output=True)
    output = result.stdout + result.stderr
    if (result.returncode != 0) != expect_error:
        raise AssertionError(output[-8000:])
    return output


def script(path, revision=None):
    contents = (subprocess.check_output(['git', 'show', f'{revision}:{path}'], cwd=ROOT, text=True)
                if revision else (ROOT / path).read_text())
    return contents.replace('USE UPRXDB_TEST;', f'USE [{DATABASE}];')


LAYOUT_CHECK = """
IF OBJECT_ID(N'dbo.AuditLog',N'U') IS NULL OR OBJECT_ID(N'dbo.AUDIT_LOG',N'V') IS NULL
 OR OBJECT_ID(N'dbo.AUDIT_LOG_CONTEXT',N'U') IS NULL
    THROW 51000,'Incorrect audit object types.',1;
IF (SELECT COUNT(*) FROM sys.columns WHERE object_id=OBJECT_ID(N'dbo.AuditLog'))<>9
 OR COL_LENGTH(N'dbo.AuditLog',N'EntityKey') IS NOT NULL
 OR COL_LENGTH(N'dbo.AuditLog',N'AuditID')<>4
 OR COLUMNPROPERTY(OBJECT_ID(N'dbo.AuditLog'),N'AuditID','IsIdentity')<>1
    THROW 51000,'Main AuditLog does not match the client column contract.',1;
IF EXISTS(SELECT 1 FROM (VALUES(N'AuditID'),(N'UPRID'),(N'EntityNameID'),(N'EntityRecordID'),
    (N'OperationType'),(N'ChangedBy'),(N'ChangedDate'),(N'OldValues'),(N'NewValues')) expected(name)
 WHERE NOT EXISTS(SELECT 1 FROM sys.columns c WHERE c.object_id=OBJECT_ID(N'dbo.AuditLog') AND c.name=expected.name))
    THROW 51000,'Client column missing.',1;
IF (SELECT COUNT(*) FROM sys.triggers WHERE name LIKE N'tr[_]UPR[_]Audit[_]%' AND is_disabled=0)<>23
    THROW 51000,'Expected all 23 audit triggers enabled.',1;
"""

sql(f'CREATE DATABASE [{DATABASE}];', database='master')
try:
    # Already-client-shaped database: no original key/run data to recover.
    sql(script('ddl/03_new_upr_schema.sql'))
    sql("""
INSERT dbo.REF_ENTITY_IDENTIFICATION(EntityName) VALUES('CLIENT_HISTORY');
INSERT dbo.AuditLog(EntityNameID,EntityRecordID,OperationType,ChangedBy,OldValues,NewValues)
SELECT EntityID,42,'UPDATE','client-history','{"Flag":0}','{"Flag":1}'
FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityName='CLIENT_HISTORY';
""")
    sql(script('scripts/install_upr_audit.sql'))
    sql(script('scripts/install_upr_audit.sql'))
    sql(LAYOUT_CHECK + """
IF (SELECT COUNT(*) FROM dbo.AuditLog)<>1 OR (SELECT COUNT(*) FROM dbo.AUDIT_LOG_CONTEXT)<>1
 OR EXISTS(SELECT 1 FROM dbo.AUDIT_LOG_CONTEXT WHERE EntityKey IS NOT NULL OR RunID IS NOT NULL OR SessionID IS NOT NULL)
    THROW 51000,'Client history duplicated or missing context fabricated.',1;
""")
    sql(script('scripts/list_upr_audit.sql'))
    readable = sql("EXEC dbo.usp_UPR_AuditReport @TableName=N'CLIENT_HISTORY';")
    raw = sql("EXEC dbo.usp_UPR_AuditReport @TableName=N'CLIENT_HISTORY',@RawRecordKey=1;")
    assert readable.count('[EntityRecordID] = 42 (original key not recorded)') == 2, readable
    assert 'original key not recorded' not in raw and '|NULL|' in raw, raw
    # Failure must leave the client's existing row and trigger state intact.
    sql("""
INSERT dbo.AuditLog(EntityNameID,EntityRecordID,OperationType,ChangedBy)
VALUES(2147483647,1,'INSERT','unmapped-test');
""")
    error = sql(script('scripts/install_upr_audit.sql'), expect_error=True)
    assert 'no mapping' in error, error
    sql(LAYOUT_CHECK + """
IF NOT EXISTS(SELECT 1 FROM dbo.AuditLog WHERE ChangedBy='unmapped-test')
    THROW 51000,'Failed installation changed existing client history.',1;
""")
    print('PASS: client layout, repeat install, unknown key reporting and unmapped-ID rollback', flush=True)

    # Rebuild the disposable DB with the exact previous implementation.
    sql(script('ddl/03_new_upr_schema.sql'))
    sql('DROP VIEW dbo.AUDIT_LOG; DROP TABLE dbo.AUDIT_LOG_CONTEXT; DROP TABLE dbo.AuditLog;')
    sql(script('ddl/03_new_upr_schema.sql', 'fce184f'))
    sql(script('scripts/install_upr_audit.sql', 'fce184f'))
    sql("""
INSERT dbo.REF_ENTITYTYPE(Description) VALUES('Layout A'),('Layout B');
UPDATE dbo.REF_ENTITYTYPE SET Description=Description+' changed' WHERE Description LIKE 'Layout %';
DELETE dbo.REF_ENTITYTYPE WHERE Description LIKE 'Layout %';
INSERT dbo.REF_ENTITY_IDENTIFICATION(EntityName) VALUES('LAYOUT_HISTORY');
INSERT dbo.AUDIT_LOG(OriginalUPRID,EntityID,EntityRecordID,EntityKey,ActionType,ChangedBy,
 OldValues,NewValues,RunID,SessionID,ChangeSummary)
SELECT 987654321,EntityID,99,N'{"UnitID":99}','UPDATE','history-test',N'{"UnitNumber":"before"}',
 N'{"UnitNumber":"after"}','12345678-1234-1234-1234-123456789012',987,N'Preserve all context'
FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityName='LAYOUT_HISTORY';
CREATE USER LayoutReader WITHOUT LOGIN;
GRANT SELECT ON OBJECT::dbo.AUDIT_LOG TO LayoutReader;
GRANT SELECT (AuditID) ON OBJECT::dbo.AuditLog TO LayoutReader;
-- Larger BIGINT IDs must never be cast/truncated into the client's INT field.
SET IDENTITY_INSERT dbo.AUDIT_LOG ON;
INSERT dbo.AUDIT_LOG(AuditLogID,EntityID,EntityRecordID,EntityKey,ActionType,ChangedBy)
SELECT 2147483648,EntityID,1,N'{"ID":1}','INSERT','overflow-test'
FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityName='LAYOUT_HISTORY';
SET IDENTITY_INSERT dbo.AUDIT_LOG OFF;
""")
    error = sql(script('scripts/install_upr_audit.sql'), expect_error=True)
    assert 'do not fit' in error, error
    sql("""
IF OBJECT_ID(N'dbo.AUDIT_LOG',N'U') IS NULL OR OBJECT_ID(N'dbo.AuditLog',N'V') IS NULL
 OR OBJECT_ID(N'dbo.AUDIT_LOG_PreClientLayout') IS NOT NULL
    THROW 51000,'Overflow failure did not roll back object renames.',1;
IF (SELECT COUNT(*) FROM sys.triggers WHERE name LIKE N'tr[_]UPR[_]Audit[_]%' AND is_disabled=0)<>23
    THROW 51000,'Overflow failure left triggers disabled.',1;
DELETE dbo.AUDIT_LOG WHERE ChangedBy='overflow-test';
""")
    sql(script('scripts/install_upr_audit.sql'))
    sql(script('scripts/install_upr_audit.sql'))
    sql(LAYOUT_CHECK + """
IF EXISTS(SELECT AuditLogID,OriginalUPRID,EntityID,EntityRecordID,EntityKey,ActionType,ChangedBy,
 ChangedDate,OldValues,NewValues,RunID,SessionID,ChangeSummary FROM dbo.AUDIT_LOG_PreClientLayout
 EXCEPT SELECT AuditLogID,OriginalUPRID,EntityID,EntityRecordID,EntityKey,ActionType,ChangedBy,
 ChangedDate,OldValues,NewValues,RunID,SessionID,ChangeSummary FROM dbo.AUDIT_LOG)
 OR (SELECT COUNT(*) FROM dbo.AUDIT_LOG_PreClientLayout)<>(SELECT COUNT(*) FROM dbo.AUDIT_LOG)
    THROW 51000,'Normalized migration lost, changed or duplicated audit history.',1;
IF NOT EXISTS(SELECT 1 FROM dbo.AuditLog WHERE UPRID=987654321 AND ChangedBy='history-test')
    THROW 51000,'Historical event UPR association was not retained in main table.',1;
EXECUTE AS USER='LayoutReader';
SELECT TOP(1) AuditLogID,EntityKey FROM dbo.AUDIT_LOG;
SELECT TOP(1) AuditID FROM dbo.AuditLog;
REVERT;
DECLARE @Before INT=(SELECT MAX(AuditID) FROM dbo.AuditLog);
INSERT dbo.REF_ENTITYTYPE(Description) VALUES('Client A'),('Client B');
UPDATE dbo.REF_ENTITYTYPE SET Description=Description+' updated' WHERE Description LIKE 'Client %';
DELETE dbo.REF_ENTITYTYPE WHERE Description LIKE 'Client %';
IF (SELECT COUNT(*) FROM dbo.AuditLog WHERE AuditID>@Before)<>6
 OR (SELECT COUNT(*) FROM dbo.AUDIT_LOG_CONTEXT WHERE AuditID>@Before)<>6
 OR EXISTS(SELECT 1 FROM dbo.AUDIT_LOG WHERE AuditID>@Before AND (EntityKey IS NULL OR SessionID<>@@SPID))
    THROW 51000,'Multirow events did not retain paired event context.',1;
SET @Before=(SELECT MAX(AuditID) FROM dbo.AuditLog);
BEGIN TRANSACTION;
INSERT dbo.REF_ENTITYTYPE(Description) VALUES('Must Roll Back');
ROLLBACK;
IF EXISTS(SELECT 1 FROM dbo.AuditLog WHERE AuditID>@Before)
 OR EXISTS(SELECT 1 FROM dbo.AUDIT_LOG_CONTEXT WHERE AuditID>@Before)
    THROW 51000,'Business rollback left audit/context rows.',1;
""")
    print('PASS: prior normalized migration, INT overflow rollback, permissions, history, multirow and transaction pairing', flush=True)
finally:
    sql(f'ALTER DATABASE [{DATABASE}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [{DATABASE}];', database='master')
