#!/usr/bin/env python3
"""SQL Server regression: load with client AuditLog and no support-table migration.

Runs only in a disposable database in the existing test container.
"""
import os
import re
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
    # Test the actual seed block against independent dictionary definitions before
    # the main fixture is installed. Nothing uses this disposable database yet.
    loader = (ROOT / 'scripts/load_upr_master.sql').read_text()
    seed_start = loader.index('BEGIN TRANSACTION;\n/* Create the batch-summary dictionary')
    seed_end = loader.index('/* Reject existing duplicate pairs', seed_start)
    seed = ("DECLARE @Now DATETIME2(0)='2026-10-05T12:00:00',@AuditUser NVARCHAR(100)=N'FixtureUser',@SummaryEntityID INT;\n"
            + loader[seed_start:seed_end] + '\nCOMMIT TRANSACTION;')
    for mode in ('identity_defaults','identity_no_defaults','manual_no_defaults','manual_exhausted','unknown_required'):
        manual = mode.startswith('manual')
        defaults = mode == 'identity_defaults'
        identity = '' if manual else ' IDENTITY(1,1)'
        initial_id = 2147483647 if mode=='manual_exhausted' else 41
        unknown_definition = ',TenantCode INT NOT NULL' if mode=='unknown_required' else ''
        sql('DROP TABLE IF EXISTS dbo.REF_ENTITY_IDENTIFICATION;')
        sql(f"""CREATE TABLE dbo.REF_ENTITY_IDENTIFICATION(
            EntityID INT{identity} NOT NULL PRIMARY KEY,EntityName VARCHAR(100) NOT NULL UNIQUE,
            EntityDescription VARCHAR(250) NOT NULL {"DEFAULT('default description')" if defaults else ''},
            IsActive BIT NOT NULL {'DEFAULT(1)' if defaults else ''},
            CreatedDate DATETIME2(3) NOT NULL {'DEFAULT(SYSDATETIME())' if defaults else ''},
            CreatedBy VARCHAR(100) NOT NULL {"DEFAULT('default creator')" if defaults else ''}
            {unknown_definition});
            INSERT dbo.REF_ENTITY_IDENTIFICATION(
                {'EntityID,' if manual else ''}EntityName,EntityDescription,IsActive,CreatedDate,CreatedBy
                {',TenantCode' if mode=='unknown_required' else ''})
            VALUES({str(initial_id)+',' if manual else ''}'UPR','Keep existing',1,SYSDATETIME(),'Existing'
                {',7' if mode=='unknown_required' else ''});""")
        original = sql('SELECT EntityID,EntityName,CreatedBy FROM dbo.REF_ENTITY_IDENTIFICATION;')
        should_fail = mode in ('manual_exhausted','unknown_required')
        result = sql(seed,error=should_fail)
        if should_fail:
            assert ('no higher available INT ID' if mode=='manual_exhausted' else 'TenantCode') in result
            assert sql('SELECT EntityID,EntityName,CreatedBy FROM dbo.REF_ENTITY_IDENTIFICATION;') == original
        else:
            assert sql("SELECT EntityID,EntityName,CreatedBy FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityName='UPR';") == original
            if manual:
                assert int(sql("SELECT EntityID FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityName='UPR_HIER_LOAD';")) > 41
            expected = sql('SELECT EntityID,EntityName,CreatedBy FROM dbo.REF_ENTITY_IDENTIFICATION ORDER BY EntityID;')
            sql(seed)
            assert sql('SELECT EntityID,EntityName,CreatedBy FROM dbo.REF_ENTITY_IDENTIFICATION ORDER BY EntityID;') == expected
        print('PASS: actual dictionary seed:',mode)
    # Actual T-SQL metadata/control-flow coverage for the October 6 NULL-key bug.
    for mode in ('nullable_absent','nullable_existing_null','nullable_existing_valid',
                 'null_default','duplicate_name','duplicate_id','trigger_clears_id'):
        sql('DROP TABLE IF EXISTS dbo.REF_ENTITY_IDENTIFICATION;')
        sql("CREATE TABLE dbo.REF_ENTITY_IDENTIFICATION(EntityID INT NULL "
            + ('DEFAULT(NULL)' if mode=='null_default' else '')
            + ",EntityName VARCHAR(100) NOT NULL); INSERT dbo.REF_ENTITY_IDENTIFICATION VALUES(41,'UPR');")
        if mode in ('nullable_existing_null','duplicate_name'):
            sql("INSERT dbo.REF_ENTITY_IDENTIFICATION VALUES(NULL,'UPR_HIER_LOAD');")
        if mode in ('nullable_existing_valid','duplicate_name'):
            sql("INSERT dbo.REF_ENTITY_IDENTIFICATION VALUES(42,'UPR_HIER_LOAD');")
        if mode=='duplicate_id':
            sql("INSERT dbo.REF_ENTITY_IDENTIFICATION VALUES(41,'UPR_HIER_LOAD');")
        if mode=='trigger_clears_id':
            sql("CREATE TRIGGER dbo.ClearSummaryKey ON dbo.REF_ENTITY_IDENTIFICATION AFTER INSERT AS "
                "UPDATE dbo.REF_ENTITY_IDENTIFICATION SET EntityID=NULL WHERE EntityName='UPR_HIER_LOAD';")
        original=sql('SELECT EntityID,EntityName FROM dbo.REF_ENTITY_IDENTIFICATION ORDER BY EntityName,EntityID;')
        failures={'null_default':'EntityID is NULL','duplicate_name':'duplicate entity dictionary names',
                  'duplicate_id':'shared by multiple dictionary rows','trigger_clears_id':'EntityID is NULL'}
        result=sql(seed,error=mode in failures)
        if mode in failures:
            assert failures[mode] in result,result
            assert sql('SELECT EntityID,EntityName FROM dbo.REF_ENTITY_IDENTIFICATION ORDER BY EntityName,EntityID;')==original
        else:
            assert int(sql("SELECT EntityID FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityName='UPR_HIER_LOAD';"))>=42
            assert sql("SELECT EntityID FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityName='UPR';")=='41'
            sql(seed)
            assert int(sql("SELECT EntityID FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityName='UPR_HIER_LOAD';"))>=42
        print('PASS: actual dictionary NULL/ambiguous-key regression:',mode)
    sql('DROP TABLE dbo.REF_ENTITY_IDENTIFICATION;')
    # Run the actual audit preflight alone against independent table variants.
    audit_guard=("DECLARE @AuditNewColumn SYSNAME=N'NewValue';\n"
        +loader[loader.index('/* AUDIT_INSERT_PREFLIGHT_BEGIN'):loader.index('/* AUDIT_INSERT_PREFLIGHT_END */')])
    for mode in ('client','extra_required','extra_default','uprid_required','oldvalues_required','nonidentity','computed_payload'):
        sql('DROP TABLE IF EXISTS dbo.AuditLog;')
        identity='DEFAULT(1)' if mode=='nonidentity' else 'IDENTITY(1,1)'
        payload="NewValue AS CONVERT(VARCHAR(MAX),'{}')" if mode=='computed_payload' else 'NewValue VARCHAR(MAX) NULL'
        extra=',ClientRequired INT NOT NULL' if mode=='extra_required' else ',ClientDefault INT NOT NULL DEFAULT(1)' if mode=='extra_default' else ''
        sql(f"""CREATE TABLE dbo.AuditLog(AuditID INT {identity} NOT NULL,
            UPRID BIGINT {'NOT NULL' if mode=='uprid_required' else 'NULL'},
            EntityNameID INT NOT NULL,EntityRecordID BIGINT NOT NULL,
            OperationType VARCHAR(20) NOT NULL,ChangedBy VARCHAR(100) NOT NULL,
            ChangedDate DATETIME2(3) NOT NULL,
            OldValues VARCHAR(MAX) {'NOT NULL' if mode=='oldvalues_required' else 'NULL'},
            {payload}{extra});""")
        failures={'extra_required':'ClientRequired','uprid_required':'UPRID','oldvalues_required':'OldValues',
                  'nonidentity':'INT IDENTITY','computed_payload':'generated or computed column'}
        result=sql(audit_guard,error=mode in failures)
        if mode in failures: assert failures[mode] in result,result
        assert sql('SELECT COUNT(*) FROM dbo.AuditLog;')=='0'
        print('PASS: actual audit metadata preflight:',mode)
    sql('DROP TABLE dbo.AuditLog;')
    run_file('test/local_it_setup.sql')
    run_file('ddl/03_new_upr_schema.sql')
    sql("""
DROP VIEW dbo.AUDIT_LOG;
DROP TABLE dbo.AUDIT_LOG_CONTEXT;
DROP TABLE dbo.UPR_LOAD_RUN;
DROP TABLE dbo.AUDIT_ENTITY_RECORD;
DROP TABLE dbo.UPR_CONDO_LEGACY;
/* Exact October 5 client layout, independent of the project's fresh DDL. */
DROP TABLE dbo.AuditLog;
CREATE TABLE dbo.AuditLog(
    AuditID INT IDENTITY(1,1) NOT NULL,
    UPRID BIGINT NULL,
    EntityNameID INT NOT NULL,
    EntityRecordID BIGINT NOT NULL,
    OperationType VARCHAR(20) NOT NULL,
    ChangedBy VARCHAR(100) NOT NULL,
    ChangedDate DATETIME2(3) NOT NULL CONSTRAINT DF_AuditLog_ChangedDate DEFAULT(SYSDATETIME()),
    OldValues VARCHAR(MAX) NULL,
    NewValue VARCHAR(MAX) NULL,
    CONSTRAINT PK_AuditLog PRIMARY KEY CLUSTERED(AuditID),
    CONSTRAINT CK_AuditLog_OperationType CHECK(OperationType IN('INSERT','UPDATE','DELETE','MERGE','STATUS_CHANGE')),
    CONSTRAINT CK_AuditLog_ChangedDate CHECK(ChangedDate<=DATEADD(MINUTE,1,SYSDATETIME()))
);
INSERT dbo.REF_ENTITY_IDENTIFICATION(EntityName) VALUES('UPR');
INSERT dbo.AuditLog(EntityNameID,EntityRecordID,OperationType,ChangedBy,NewValue)
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
    # Reproduce the client error: existing nullable Level and ancestor index
    # includes Level. Fixture setup only; the loader must preserve this shape.
    sql("""
ALTER TABLE dbo.UPR_CLOSURE DROP CONSTRAINT CK_UPR_CLOSURE_Level;
DROP INDEX IX_UPR_CLOSURE_Descendant ON dbo.UPR_CLOSURE;
ALTER TABLE dbo.UPR_CLOSURE ALTER COLUMN [Level] INT NULL;
DROP INDEX IX_UPR_CLOSURE_Ancestor ON dbo.UPR_CLOSURE;
CREATE INDEX IX_UPR_CLOSURE_Ancestor ON dbo.UPR_CLOSURE(AncestorUPRID) INCLUDE(DescendantUPRID,[Level]);
CREATE INDEX IX_UPR_CLOSURE_Descendant ON dbo.UPR_CLOSURE(DescendantUPRID,AncestorUPRID) INCLUDE([Level]);
""")
    closure_layout_query="SELECT column_id,name,system_type_id,max_length,is_nullable FROM sys.columns WHERE object_id=OBJECT_ID(N'dbo.UPR_CLOSURE') ORDER BY column_id;"
    closure_indexes_query="SELECT i.index_id,i.name,i.is_unique,k.column_id,k.key_ordinal,k.is_included_column FROM sys.indexes i JOIN sys.index_columns k ON k.object_id=i.object_id AND k.index_id=i.index_id WHERE i.object_id=OBJECT_ID(N'dbo.UPR_CLOSURE') ORDER BY i.index_id,k.index_column_id;"
    closure_layout=sql(closure_layout_query)
    closure_indexes=sql(closure_indexes_query)
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
    conflict=sql(loader.replace('UPRXDB_TEST',DATABASE),error=True)
    assert 'require review before loader-owned auditing' in conflict
    assert sql('SELECT COUNT(*) FROM dbo.UPR;')=='0'
    assert sql("SELECT OBJECT_DEFINITION(OBJECT_ID(N'dbo.Client_UPR_Audit'));")==trigger
    # Fixture-owned trigger removal represents the test's native no-installer case.
    sql('DROP TRIGGER dbo.Client_UPR_Audit;')
    output=run_file('scripts/load_upr_master.sql')
    assert 'Loader audit mode' in output and 'UPR MAIN LOADER 2026-10-06 R8' in output
    assert 'Audit payload column: dbo.AuditLog.[NewValue]' in output
    assert 'UPR rows inserted' in output and 'Row audit entries written' in output
    run_id=re.search(r'Audit RunID: ([0-9a-fA-F-]{36})',output)[1]
    audit_check=(ROOT/'scripts/check_upr_audit_result.sql').read_text().replace(
        'DECLARE @RunID UNIQUEIDENTIFIER=NULL;',f"DECLARE @RunID UNIQUEIDENTIFIER='{run_id}';")
    check_output=sql(audit_check)
    assert 'PASS' in check_output and 'FAIL:' not in check_output,check_output
    counts = run_file('test/local_it_counts.sql')
    closure_before_nulls=sql('SELECT AncestorUPRID,DescendantUPRID,[Level] FROM dbo.UPR_CLOSURE ORDER BY AncestorUPRID,DescendantUPRID;')
    sql('UPDATE dbo.UPR_CLOSURE SET [Level]=NULL;')
    run_file('scripts/load_upr_master.sql')
    assert sql('SELECT AncestorUPRID,DescendantUPRID,[Level] FROM dbo.UPR_CLOSURE ORDER BY AncestorUPRID,DescendantUPRID;')==closure_before_nulls
    assert sql(closure_layout_query)==closure_layout
    assert sql(closure_indexes_query)==closure_indexes
    assert sql("SELECT COUNT(*) FROM sys.check_constraints WHERE parent_object_id=OBJECT_ID(N'dbo.UPR_CLOSURE') AND name='CK_UPR_CLOSURE_Level';")=='0'
    print('PASS: indexed nullable Level preserved and NULL distances repaired on repeated load')
    assert run_file('test/local_it_counts.sql') == counts
    assert sql("SELECT column_id,name,system_type_id,max_length,is_nullable FROM sys.columns WHERE object_id=OBJECT_ID(N'dbo.AuditLog') ORDER BY column_id;") == layout
    assert sql("SELECT object_id,name FROM sys.tables WHERE schema_id=SCHEMA_ID('dbo') ORDER BY name;") == objects
    assert sql("SELECT COUNT(*) FROM sys.triggers WHERE parent_class=1;")=='0'
    sql("""
IF NOT EXISTS(SELECT 1 FROM dbo.AuditLog WHERE ChangedBy='CLIENT_HISTORY' AND NewValue=N'{"keep":true}')
    THROW 51000,'Existing audit history was changed.',1;
IF (SELECT COUNT(*) FROM dbo.AuditLog a JOIN dbo.REF_ENTITY_IDENTIFICATION e ON e.EntityID=a.EntityNameID
    WHERE e.EntityName='UPR_HIER_LOAD' AND a.NewValue LIKE N'RunID = %')<>2
    THROW 51000,'Plain batch summaries missing.',1;
IF EXISTS(SELECT 1 FROM dbo.AuditLog WHERE ChangedBy<>'CLIENT_HISTORY' AND (ISJSON(OldValues)=1 OR ISJSON(NewValue)=1))
    THROW 51000,'New audit contains JSON.',1;
IF EXISTS(SELECT 1 FROM dbo.UPR u WHERE NOT EXISTS(
    SELECT 1 FROM dbo.AuditLog a JOIN dbo.REF_ENTITY_IDENTIFICATION e ON e.EntityID=a.EntityNameID
    WHERE e.EntityName='UPR' AND a.UPRID=u.UPRID AND a.EntityRecordID=u.UPRID AND a.OperationType='INSERT'))
    THROW 51000,'A new UPR has no row audit.',1;
IF EXISTS(SELECT 1 FROM dbo.AuditLog a JOIN dbo.REF_ENTITY_IDENTIFICATION e ON e.EntityID=a.EntityNameID
    WHERE e.EntityName='UNIT' AND NOT EXISTS(SELECT 1 FROM dbo.UNIT u WHERE u.UnitID=a.EntityRecordID AND u.UPRID=a.UPRID))
    THROW 51000,'Unit native key/UPRID association incorrect.',1;
IF NOT EXISTS(SELECT 1 FROM dbo.AuditLog a JOIN dbo.REF_ENTITY_IDENTIFICATION e ON e.EntityID=a.EntityNameID
    WHERE e.EntityName='UPR_CLOSURE' AND a.OperationType='UPDATE' AND a.OldValues LIKE '%Level = <NULL>%')
    THROW 51000,'Closure repair UPDATE was not audited.',1;
""")
    # A real audit INSERT error must roll back pending hierarchy changes.
    sql('UPDATE dbo.UPR_CLOSURE SET [Level]=NULL;')
    audit_count_before=sql('SELECT COUNT(*) FROM dbo.AuditLog;')
    sql("ALTER TABLE dbo.AuditLog WITH NOCHECK ADD CONSTRAINT RejectPlainTest CHECK(NewValue NOT LIKE 'RunID = %');")
    failed=sql(loader.replace('UPRXDB_TEST',DATABASE),error=True)
    assert 'RejectPlainTest' in failed,failed
    assert sql('SELECT COUNT(*) FROM dbo.AuditLog;')==audit_count_before
    assert sql('SELECT COUNT(*) FROM dbo.UPR_CLOSURE WHERE [Level] IS NOT NULL;')=='0'
    sql('ALTER TABLE dbo.AuditLog DROP CONSTRAINT RejectPlainTest;')
    run_file('scripts/load_upr_master.sql')
    assert run_file('test/local_it_counts.sql')==counts
    print('PASS: native row audit, preserved historical JSON, readable new values, closure UPDATE audit and rollback on audit failure')
    # R9: reproduce old direct Condo -> Unit links using the existing BuildingID.
    # Source/Unit IDs must be reused; the repair itself must be audited.
    condo_links=sql("""SELECT n.UnitID,n.UPRID,n.BuildingID,b.UPRID
        FROM dbo.UNIT n JOIN dbo.BUILDING b ON b.BuildingID=n.BuildingID
        JOIN dbo.UPR bu ON bu.UPRID=b.UPRID JOIN dbo.CONDO c ON c.UPRID=bu.ParentUPRID
        ORDER BY n.UnitID;""")
    assert condo_links, 'Fixture needs Condo units'
    xrefs_before=sql('SELECT ExternalIdentifierID,UPRID,SourceSystem,IdentifierType,IdentifierValue FROM dbo.EXTERNAL_IDENTIFIER_XREF ORDER BY ExternalIdentifierID;')
    sql("""UPDATE u SET ParentUPRID=bu.ParentUPRID
        FROM dbo.UPR u JOIN dbo.UNIT n ON n.UPRID=u.UPRID
        JOIN dbo.BUILDING b ON b.BuildingID=n.BuildingID
        JOIN dbo.UPR bu ON bu.UPRID=b.UPRID JOIN dbo.CONDO c ON c.UPRID=bu.ParentUPRID;""")
    old_audit_max=int(sql('SELECT MAX(AuditID) FROM dbo.AuditLog;'))
    r9_output=run_file('scripts/load_upr_master.sql')
    assert 'Existing Condo units moved under their linked Building:' in r9_output
    assert run_file('test/local_it_counts.sql')==counts
    assert sql('SELECT ExternalIdentifierID,UPRID,SourceSystem,IdentifierType,IdentifierValue FROM dbo.EXTERNAL_IDENTIFIER_XREF ORDER BY ExternalIdentifierID;')==xrefs_before
    assert sql("""SELECT n.UnitID,n.UPRID,n.BuildingID,b.UPRID
        FROM dbo.UNIT n JOIN dbo.BUILDING b ON b.BuildingID=n.BuildingID
        JOIN dbo.UPR bu ON bu.UPRID=b.UPRID JOIN dbo.CONDO c ON c.UPRID=bu.ParentUPRID
        ORDER BY n.UnitID;""")==condo_links
    check_result=run_file('scripts/check_upr_unit_hierarchy.sql')
    assert 'PASS' in check_result and 'FAIL' not in check_result,check_result
    sql(f"""IF EXISTS(SELECT 1 FROM dbo.UNIT n JOIN dbo.BUILDING b ON b.BuildingID=n.BuildingID
        JOIN dbo.UPR bu ON bu.UPRID=b.UPRID JOIN dbo.CONDO c ON c.UPRID=bu.ParentUPRID
        WHERE NOT EXISTS(SELECT 1 FROM dbo.AuditLog a JOIN dbo.REF_ENTITY_IDENTIFICATION e ON e.EntityID=a.EntityNameID
          WHERE a.AuditID>{old_audit_max} AND e.EntityName='UPR' AND a.UPRID=n.UPRID AND a.OperationType='UPDATE'
            AND a.OldValues LIKE '%ParentUPRID = "'+CONVERT(VARCHAR(30),c.UPRID)+'"%'
            AND a.NewValue LIKE '%ParentUPRID = "'+CONVERT(VARCHAR(30),b.UPRID)+'"%'))
        THROW 51000,'Condo unit reparent event not audited.',1;""")
    rerun=run_file('scripts/load_upr_master.sql')
    assert 'Existing Condo units moved under their linked Building: 0' in rerun
    assert run_file('test/local_it_counts.sql')==counts
    print('PASS: R9 repairs direct Condo units without replacing IDs/XREFs, writes audit and reruns without reparenting')
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
    # Both/neither payload names must fail before a business load starts.
    sql('ALTER TABLE dbo.AuditLog ADD NewValues VARCHAR(MAX) NULL;')
    assert 'both NewValue and NewValues' in sql(
        (ROOT / 'scripts/load_upr_master.sql').read_text().replace('UPRXDB_TEST',DATABASE),error=True)
    sql('ALTER TABLE dbo.AuditLog DROP COLUMN NewValues;')
    sql("EXEC sys.sp_rename N'dbo.AuditLog.NewValue',N'PayloadHidden',N'COLUMN';")
    assert 'Expected the client AuditLog columns' in sql(
        (ROOT / 'scripts/load_upr_master.sql').read_text().replace('UPRXDB_TEST',DATABASE),error=True)
    sql("EXEC sys.sp_rename N'dbo.AuditLog.PayloadHidden',N'NewValues',N'COLUMN';")
    output=run_file('scripts/load_upr_master.sql')
    assert 'Audit payload column: dbo.AuditLog.[NewValues]' in output
    assert run_file('test/local_it_counts.sql')==counts
    print('PASS: both/neither payload names rejected; prior plural layout still works')
    # Optional full SQL Server stress run, separate from the SQLite correctness test.
    stress=int(os.environ.get('UPR_STRESS_ROWS','0'))
    if stress:
        assert 100<=stress<=200000 and stress%100==0,'Stress rows must be a multiple of 100, up to 200000'
        before_upr=int(sql('SELECT COUNT_BIG(*) FROM dbo.UPR;'))
        sql(f""";WITH digits AS(SELECT n FROM(VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) d(n)),
        numbers AS(SELECT TOP({stress}) ROW_NUMBER() OVER(ORDER BY (SELECT NULL))-1 AS n
            FROM digits a CROSS JOIN digits b CROSS JOIN digits c CROSS JOIN digits d CROSS JOIN digits e CROSS JOIN digits f)
        INSERT dbo.MAIncomingTableX1(MasterAddressID,Account,StreetNumber,StreetName,StreetType,Unit,City,ZipCode,LUCategory)
        SELECT 1000001+n,CONVERT(NCHAR(8),80000000+n/100),CONVERT(NVARCHAR(20),100+n/10),
            N'STRESS',N'ST',CONVERT(NVARCHAR(20),1+n%10),N'ROCKVILLE',N'20850',N'Multi-Family' FROM numbers;""")
        stress_output=run_file('scripts/load_upr_master.sql')
        expected=stress+stress//10+stress//100
        assert int(sql('SELECT COUNT_BIG(*) FROM dbo.UPR;'))-before_upr==expected
        stress_run=re.search(r'Audit RunID: ([0-9a-fA-F-]{36})',stress_output)[1]
        checked=sql((ROOT/'scripts/check_upr_audit_result.sql').read_text().replace(
            'DECLARE @RunID UNIQUEIDENTIFIER=NULL;',f"DECLARE @RunID UNIQUEIDENTIFIER='{stress_run}';"))
        assert 'PASS' in checked and 'FAIL:' not in checked
        after=run_file('test/local_it_counts.sql')
        run_file('scripts/load_upr_master.sql')
        assert run_file('test/local_it_counts.sql')==after
        print(f'PASS: SQL Server stress {stress} additional source rows, {expected} new UPRs, row audit and stable repeat')
    # Legacy JSON-producing audit writers must be detected, not silently mixed.
    run_file('scripts/install_upr_audit.sql')
    output=sql(loader.replace('UPRXDB_TEST',DATABASE),error=True)
    assert 'require review before loader-owned auditing' in output,output
    print('PASS: legacy JSON audit writer rejected without disabling or replacing triggers')
finally:
    sql(f'USE master; ALTER DATABASE [{DATABASE}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [{DATABASE}];')
