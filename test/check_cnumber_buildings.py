#!/usr/bin/env python3
"""SQL Server regression for the R11 C Number rule and R12 record layout names.

Runs only in disposable databases in the existing test container
(CONTAINER=uprtest). Three parts:
  1. C Number fixture on a fresh client-layout database, then an unchanged rerun.
  2. Upgrade: the same fixture loaded by delivered R10 on the earlier layout,
     columns renamed to the November 2026 layout, then R12.
  3. Differential: the standard hostile seed (no C Numbers) loaded by R10 and by
     R12 into separate databases must produce identical hierarchies.
  4. R12 on an un-renamed database stops in the layout check, changing nothing.
"""
import os
import re
import subprocess
import uuid
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTAINER = os.environ.get('CONTAINER', 'uprtest')
LOADER = Path(os.environ.get('UPR_LOADER', ROOT / 'scripts/load_upr_master.sql')).read_text()
with zipfile.ZipFile(ROOT / 'UPR_Main_Loader_2026-10-14_R10.zip') as z:
    R10 = z.read('load_upr_master_2026-10-14_R10.sql').decode('utf-8-sig')
CREATED = []


def sql(database, text, error=False):
    result = subprocess.run(
        ['docker', 'exec', '-i', CONTAINER, 'bash', '-lc',
         'exec /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa '
         '-P "$MSSQL_SA_PASSWORD" -C -b -W -s "|" -h -1 -w 65535'],
        input=f'USE [{database}];\nGO\nSET QUOTED_IDENTIFIER ON; SET NOCOUNT ON;\n' + text,
        text=True, capture_output=True)
    output = result.stdout + result.stderr
    if (result.returncode != 0) != error:
        raise AssertionError(output[-7000:])
    return '\n'.join(x for x in output.splitlines()
                     if x.strip() and not x.startswith('Changed database context to'))


def new_database(label):
    database = f'UPR_{label}_IT_' + uuid.uuid4().hex
    subprocess.run(['docker', 'exec', CONTAINER, 'bash', '-lc',
                    'exec /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa '
                    f'-P "$MSSQL_SA_PASSWORD" -C -b -Q "CREATE DATABASE [{database}];"'],
                   check=True, capture_output=True, text=True)
    CREATED.append(database)
    return database


# November 2026 client record layout (new name, earlier name).
RENAMES = [('UpdateDate', 'UpdatedDate'), ('PrimaryInd', 'IsPrimary'), ('LastUpdateUserID', 'LastUpdatedUserID'),
           ('LastUpdateDate', 'LastUpdatedDate'), ('CreationDate', 'CreatedDate'), ('ActiveInd', 'IsActive')]


def earlier_names(text):
    """Earlier names for the fixture-owned audit dictionary only."""
    for new, old in RENAMES:
        text = re.sub(r'\b%s\b' % new, old, text)
    return text


def rename_to_november(database):
    """What the client did: rename existing columns in place with sp_rename.
    CHECK constraints on renamed columns block sp_rename; recreate them after."""
    checks = [line.split('|', 2) for line in sql(database, """
SELECT OBJECT_NAME(k.parent_object_id), k.name, k.[definition] FROM sys.check_constraints k
WHERE """ + ' OR '.join(f"k.[definition] LIKE N'%{old}%'" for _, old in RENAMES) + ";").splitlines()]
    for table, name, _ in checks:
        sql(database, f'ALTER TABLE dbo.{table} DROP CONSTRAINT {name};')
    sql(database, """
DROP INDEX UX_UPR_ADDRESS_Primary ON dbo.UPR_ADDRESS;
DECLARE @t SYSNAME, @c SYSNAME, @n SYSNAME, @path NVARCHAR(400);
DECLARE r CURSOR LOCAL FAST_FORWARD FOR
    SELECT t.name, c.name, v.NewName FROM sys.tables t JOIN sys.columns c ON c.object_id = t.object_id
    JOIN (VALUES """ + ','.join(f"(N'{old}',N'{new}')" for new, old in RENAMES) + """) v(OldName, NewName)
        ON v.OldName = c.name
    WHERE t.schema_id = SCHEMA_ID(N'dbo');
OPEN r; FETCH NEXT FROM r INTO @t, @c, @n;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @path = N'dbo.' + @t + N'.' + @c;
    EXEC sys.sp_rename @path, @n, N'COLUMN';
    FETCH NEXT FROM r INTO @t, @c, @n;
END;
CLOSE r; DEALLOCATE r;
GO
CREATE UNIQUE INDEX UX_UPR_ADDRESS_Primary ON dbo.UPR_ADDRESS (UPRID) WHERE PrimaryInd = 1;
""")
    for table, name, definition in checks:
        renamed = definition
        for new_name, old_name in RENAMES:
            renamed = re.sub(r'\b%s\b' % old_name, new_name, renamed)
        sql(database, f'ALTER TABLE dbo.{table} ADD CONSTRAINT {name} CHECK {renamed};')


# Project DDL as committed before the November 2026 renames (the earlier layout).
EARLIER_DDL = subprocess.run(['git', '-C', str(ROOT), 'show', '1e77e58:ddl/03_new_upr_schema.sql'],
                             check=True, capture_output=True, text=True).stdout


def client_layout(database, earlier=False):
    """Hostile seed + project DDL reduced to the client's audit layout."""
    names = earlier_names if earlier else (lambda text: text)
    ddl = EARLIER_DDL if earlier else (ROOT / 'ddl/03_new_upr_schema.sql').read_text()
    sql(database, (ROOT / 'test/local_it_setup.sql').read_text().replace('UPRXDB_TEST', database))
    sql(database, ddl.replace('UPRXDB_TEST', database))
    sql(database, names("""
DROP VIEW dbo.AUDIT_LOG;
DROP TABLE dbo.AUDIT_LOG_CONTEXT;
DROP TABLE dbo.UPR_LOAD_RUN;
DROP TABLE dbo.AUDIT_ENTITY_RECORD;
DROP TABLE dbo.UPR_CONDO_LEGACY;
DROP TABLE dbo.AuditLog;
GO
CREATE TABLE dbo.AuditLog(
    AuditID INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_AuditLog PRIMARY KEY CLUSTERED,
    UPRID BIGINT NULL,
    EntityNameID INT NOT NULL,
    EntityRecordID BIGINT NOT NULL,
    OperationType VARCHAR(20) NOT NULL,
    ChangedBy VARCHAR(100) NOT NULL,
    ChangedDate DATETIME2(3) NOT NULL CONSTRAINT DF_AuditLog_ChangedDate DEFAULT(SYSDATETIME()),
    OldValues VARCHAR(MAX) NULL,
    NewValue VARCHAR(MAX) NULL);
GO
/* Manually numbered dictionary: delivered R10 cannot compile against an
   IDENTITY EntityID (Msg 8102), and the client runs R10 successfully. */
DROP TABLE dbo.REF_ENTITY_IDENTIFICATION;
CREATE TABLE dbo.REF_ENTITY_IDENTIFICATION(
    EntityID INT NOT NULL CONSTRAINT PK_REF_ENTITY_IDENTIFICATION PRIMARY KEY,
    EntityName VARCHAR(100) NOT NULL CONSTRAINT UQ_REF_ENTITY_IDENTIFICATION_Name UNIQUE,
    EntityDescription VARCHAR(250) NULL,
    ActiveInd BIT NOT NULL DEFAULT (1),
    CreationDate DATETIME2 NOT NULL DEFAULT (SYSUTCDATETIME()),
    CreatedBy VARCHAR(100) NOT NULL DEFAULT (ORIGINAL_LOGIN()));
GO
INSERT dbo.REF_ENTITY_IDENTIFICATION(EntityID, EntityName) VALUES(1, 'UPR');
IF COL_LENGTH(N'dbo.SDATIncomingTableX1', N'CondoUnit') IS NULL
    ALTER TABLE dbo.SDATIncomingTableX1 ADD CondoUnit NVARCHAR(50) NULL;
"""))


def cnumber_fixture(database):
    sql(database, """
INSERT dbo.MAIncomingTableX1
 (MasterAddressID, Account, StreetNumber, StreetName, StreetType, Unit, City, ZipCode, LUCategory, XCoordinate, YCoordinate)
VALUES
 /* A: C Number Complex, two street addresses, leading zero + City variant */
 (9501,'C000901','2310','COLSTON','Drive','101','SILVER SPRING','20910','Multi-Family',100,200),
 (9502,'C000901','2310','COLSTON','DR','102','SILVER SPRING','20910','Multi-Family',100,200),
 (9503,'C000901','02310','COLSTON','DR','103',NULL,'20910','Multi-Family',NULL,NULL),
 (9504,'C000901','2312','COLSTON','DR','201','SILVER SPRING','20910','Multi-Family',100,200),
 /* B: one address also used by another MA account */
 (9511,'C000902','500','SHARED','WAY',NULL,'TEST CITY','20850','Multi-Family',NULL,NULL),
 (9512,'C000902','502','SHARED','WAY',NULL,'TEST CITY','20850','Multi-Family',NULL,NULL),
 (9513,'00259001','500','SHARED','WAY',NULL,'TEST CITY','20850','Office',NULL,NULL),
 /* C: two C Numbers share one street address */
 (9521,'C000903','700','TWIN','CT',NULL,'TEST CITY','20850','Multi-Family',NULL,NULL),
 (9522,'C000903','702','TWIN','CT',NULL,'TEST CITY','20850','Multi-Family',NULL,NULL),
 (9523,'C000904','700','TWIN','CT',NULL,'TEST CITY','20850','Multi-Family',NULL,NULL),
 (9524,'C000904','704','TWIN','CT',NULL,'TEST CITY','20850','Multi-Family',NULL,NULL),
 /* D: one street address in two ZIP codes */
 (9531,'C000905','900','ZIP','RD',NULL,'TEST CITY','20910','Multi-Family',NULL,NULL),
 (9532,'C000905','900','ZIP','RD',NULL,'TEST CITY','20911','Multi-Family',NULL,NULL),
 (9533,'C000905','902','ZIP','RD',NULL,'TEST CITY','20910','Multi-Family',NULL,NULL),
 /* E: single-address C Number stays Property -> Building */
 (9541,'C000906','1000','SOLO','LN',NULL,'TEST CITY','20850','Multi-Family',NULL,NULL),
 /* F: C Number without MultiFamily is not a candidate */
 (9551,'C000907','1100','OFFICE','PL',NULL,'TEST CITY','20850','Office',NULL,NULL);
INSERT dbo.SDATIncomingTableX1
 (RealPropertyTaxInformationID, AccountNumber, PremisesNumber, PremisesStreetName, PremisesStreetType,
  PremisesCity, PremisesState, PremisesZipCode, Parcel, Owner, CondoUnit)
VALUES
 (9601,'7000001','02310','COLSTON','DR','SILVER SPRING','MD','20910','P-A','OWNER A','101'),
 (9602,'07000002','2310','COLSTON','DRIVE','SILVER SPRING','MD','209101234','P-B','OWNER B','104'),
 (9603,'07000003',N'2312'+NCHAR(160),'COLSTON','DR','SILVER SPRING','MD','20910','P-C','OWNER C','202'),
 (9604,'07000004','2310','COLSTON','DR','SILVER SPRING','MD','20910','P-D','OWNER D',NULL),
 (9605,'07000005','2310','COLSTON','DR','SILVER SPRING','MD','20999','P-E','OWNER E','105'),
 (9606,'07000006','500','SHARED','WAY','TEST CITY','MD','20850',NULL,'OWNER F','1'),
 (9607,'07000007','502','SHARED','WAY','TEST CITY','MD','20850',NULL,'OWNER G','2'),
 (9608,'07000008','700','TWIN','CT','TEST CITY','MD','20850',NULL,'OWNER H','5'),
 (9609,'07000009','900','ZIP','RD','TEST CITY','MD','20910',NULL,'OWNER I','X'),
 (9610,'07000010','1000','SOLO','LN','TEST CITY','MD','20850',NULL,'OWNER S','A'),
 (9611,'07000011','1100','OFFICE','PL','TEST CITY','MD','20850',NULL,'OWNER O','1');
""")


def load(database, loader=None):
    return sql(database, (loader or LOADER).replace('UPRXDB_TEST', database))


def roots(database, account):
    return sql(database, "SELECT e.Description FROM dbo.UPR u JOIN dbo.REF_ENTITYTYPE e "
               f"ON e.EntityTypeID = u.EntityTypeID WHERE u.AccountNumber = '{account}' "
               "AND u.ParentUPRID IS NULL ORDER BY e.Description;").splitlines()


SNAPSHOT = """
WITH n AS (
    SELECT u.UPRID, u.ParentUPRID,
        Label = CONCAT(e.Description, ':', ISNULL(u.AccountNumber, '-'), ':',
            ISNULL(a.NormalizedAddress, '-'), ':', ISNULL(un.UnitNumber, '-'))
    FROM dbo.UPR u JOIN dbo.REF_ENTITYTYPE e ON e.EntityTypeID = u.EntityTypeID
    LEFT JOIN dbo.UPR_ADDRESS ua ON ua.UPRID = u.UPRID AND ua.PrimaryInd = 1
    LEFT JOIN dbo.ADDRESS a ON a.AddressID = ua.AddressID
    LEFT JOIN dbo.UNIT un ON un.UPRID = u.UPRID),
p AS (
    SELECT UPRID, CAST(Label AS NVARCHAR(MAX)) AS Path FROM n WHERE ParentUPRID IS NULL
    UNION ALL
    SELECT n.UPRID, p.Path + N' > ' + n.Label FROM n JOIN p ON n.ParentUPRID = p.UPRID)
SELECT 'NODE', p.Path, '', '' FROM p
UNION ALL
SELECT 'XREF', p.Path, x.SourceSystem + ':' + x.IdentifierType, x.IdentifierValue
FROM dbo.EXTERNAL_IDENTIFIER_XREF x JOIN p ON p.UPRID = x.UPRID
UNION ALL
SELECT 'OWNER', p.Path, ISNULL(c.OrganizationName, '<NULL>'), ''
FROM dbo.UPR_CONTACT uc JOIN dbo.CONTACT c ON c.ContactID = uc.ContactID JOIN p ON p.UPRID = uc.UPRID
UNION ALL
SELECT 'ADDRESS', p.Path, CONCAT(a.StreetNumber, '|', a.StreetName, '|', a.StreetType, '|', a.City, '|',
    a.State, '|', a.ZipCode), CONCAT(a.XCoordinate, ',', a.YCoordinate)
FROM dbo.UPR_ADDRESS ua JOIN dbo.ADDRESS a ON a.AddressID = ua.AddressID JOIN p ON p.UPRID = ua.UPRID
UNION ALL
SELECT 'LEVEL', pa.Path, pd.Path, CONVERT(VARCHAR(10), cl.[Level])
FROM dbo.UPR_CLOSURE cl JOIN p pa ON pa.UPRID = cl.AncestorUPRID JOIN p pd ON pd.UPRID = cl.DescendantUPRID
UNION ALL
SELECT 'REVIEW', ISNULL(q.SDAT_AccountNumber, '-') + '/' + ISNULL(q.MA_Account, '-'), q.ReasonForNoMatch,
    ISNULL(q.SDAT_NormalizedIncomingAddress, '') + ISNULL(q.MA_NormalizedIncomingAddress, '')
FROM dbo.UPRMATCHREVIEW_Q q
ORDER BY 1, 2, 3, 4
OPTION (MAXRECURSION 100);
"""


def check(database, condition, message):
    sql(database, f"IF NOT ({condition}) THROW 51200, '{message}', 1;")


def unit_under(account):
    return ("SELECT un.UnitNumber, u.AccountNumber, a.NormalizedAddress FROM dbo.UNIT un "
            "JOIN dbo.UPR u ON u.UPRID = un.UPRID JOIN dbo.UPR b ON b.UPRID = u.ParentUPRID "
            "JOIN dbo.UPR_ADDRESS ua ON ua.UPRID = b.UPRID AND ua.PrimaryInd = 1 "
            "JOIN dbo.ADDRESS a ON a.AddressID = ua.AddressID "
            f"JOIN dbo.UPR r ON r.UPRID = b.ParentUPRID AND r.AccountNumber = '{account}'")


def owners(database, unit_account):
    return sql(database, "SELECT c.OrganizationName FROM dbo.UPR u JOIN dbo.UPR_CONTACT uc ON uc.UPRID = u.UPRID "
               "JOIN dbo.CONTACT c ON c.ContactID = uc.ContactID "
               f"WHERE u.AccountNumber = '{unit_account}' AND c.OrganizationName IS NOT NULL;").splitlines()


try:
    # 1. Fresh client-layout database with the C Number fixture.
    db = new_database('CNumber')
    client_layout(db)
    cnumber_fixture(db)
    output = load(db)
    assert 'UPR MAIN LOADER 2026-11-03 R12' in output and 'Record layout check passed.' in output and 'C Number: groups=' in output, output[-3000:]
    run_id = re.search(r'Audit RunID: ([0-9a-fA-F-]{36})', output)[1]
    audit = sql(db, (ROOT / 'scripts/check_upr_audit_result.sql').read_text().replace(
        'DECLARE @RunID UNIQUEIDENTIFIER=NULL;', f"DECLARE @RunID UNIQUEIDENTIFIER='{run_id}';"))
    assert 'PASS' in audit and 'FAIL:' not in audit, audit
    for outcome in ('SHARED_WITH_OTHER_ACCOUNT', 'ZIP_CONFLICT', 'VALIDATED', 'NO_CONDO_UNIT',
                    'AMBIGUOUS_BUILDING', 'BUILDING_NOT_VALIDATED'):
        assert f'|{outcome}|' in output, outcome

    assert roots(db, 'C000901') == ['Complex'], roots(db, 'C000901')
    units = sql(db, unit_under('C000901') + ' ORDER BY a.NormalizedAddress, un.UnitNumber;').splitlines()
    assert units == [
        '101|07000001|2310 COLSTON DR SILVER SPRING 20910',
        '102|NULL|2310 COLSTON DR SILVER SPRING 20910',
        '103|NULL|2310 COLSTON DR SILVER SPRING 20910',
        '104|07000002|2310 COLSTON DR SILVER SPRING 20910',
        '201|NULL|2312 COLSTON DR SILVER SPRING 20910',
        '202|07000003|2312 COLSTON DR SILVER SPRING 20910'], units
    print('PASS: C Number Complex has one Building per street address; SDAT condo rows are its Units', flush=True)
    assert sql(db, "SELECT a.StreetNumber, a.City, a.ZipCode FROM dbo.ADDRESS a "
               "JOIN dbo.UPR_ADDRESS ua ON ua.AddressID = a.AddressID JOIN dbo.UPR b ON b.UPRID = ua.UPRID "
               "JOIN dbo.UPR r ON r.UPRID = b.ParentUPRID AND r.AccountNumber = 'C000901' "
               "WHERE a.NormalizedAddress = '2310 COLSTON DR SILVER SPRING 20910';") == '2310|SILVER SPRING|20910'
    print('PASS: leading zero, City variant and non-breaking space normalized; MA address kept', flush=True)

    for account in ('07000001', '07000002', '07000003', '07000007', '07000010'):
        assert roots(db, account) == [], (account, roots(db, account))
    for account in ('07000004', '07000005', '07000006', '07000008', '07000009', '07000011'):
        assert roots(db, account) == ['Condo'], (account, roots(db, account))
    print('PASS: unvalidated, ambiguous, non-unit and non-candidate SDAT rows keep the R10 Condo path', flush=True)

    assert owners(db, '07000001') == ['OWNER A'] and owners(db, '07000002') == ['OWNER B']
    check(db, "NOT EXISTS (SELECT 1 FROM dbo.UPR r JOIN dbo.UPR_CONTACT uc ON uc.UPRID = r.UPRID "
          "JOIN dbo.CONTACT c ON c.ContactID = uc.ContactID WHERE r.AccountNumber = 'C000901' "
          "AND r.ParentUPRID IS NULL AND c.OrganizationName IS NOT NULL)", 'Complex took a Unit owner.')
    check(db, "NOT EXISTS (SELECT 1 FROM dbo.EXTERNAL_IDENTIFIER_XREF x JOIN dbo.UPR r ON r.UPRID = x.UPRID "
          "WHERE r.AccountNumber = 'C000901' AND x.IdentifierValue IN ('07000001','P-A'))",
          'Complex took a Unit account or parcel.')
    check(db, "EXISTS (SELECT 1 FROM dbo.EXTERNAL_IDENTIFIER_XREF x JOIN dbo.UPR u ON u.UPRID = x.UPRID "
          "WHERE u.AccountNumber = '07000001' AND x.IdentifierType = 'ACCOUNT_NUMBER' AND x.IdentifierValue = '07000001') "
          "AND EXISTS (SELECT 1 FROM dbo.EXTERNAL_IDENTIFIER_XREF x JOIN dbo.UPR u ON u.UPRID = x.UPRID "
          "WHERE u.AccountNumber = '07000001' AND x.IdentifierType = 'PARCEL_ID' AND x.IdentifierValue = 'P-A') "
          "AND EXISTS (SELECT 1 FROM dbo.EXTERNAL_IDENTIFIER_XREF x JOIN dbo.UPR u ON u.UPRID = x.UPRID "
          "JOIN dbo.UNIT un ON un.UPRID = u.UPRID WHERE x.SourceSystem = 'KDAT' AND x.IdentifierValue = '9601' "
          "AND un.UnitNumber = '101')", 'Unit lost its SDAT account, parcel or source link.')
    check(db, "EXISTS (SELECT 1 FROM dbo.UPR_CLOSURE cl JOIN dbo.UPR u ON u.UPRID = cl.DescendantUPRID "
          "JOIN dbo.UPR r ON r.UPRID = cl.AncestorUPRID WHERE u.AccountNumber = '07000001' "
          "AND r.AccountNumber = 'C000901' AND cl.[Level] = 2)", 'Unit closure level is not 2.')
    print('PASS: Unit keeps its SDAT account, owner and parcel; parent does not; closure level 2', flush=True)

    # MA MultiFamily rows without a unit number keep their R10 N/A Unit (rule 9).
    assert sql(db, unit_under('C000902') + ' ORDER BY a.NormalizedAddress, un.UnitNumber;').splitlines() == [
        'N/A|NULL|500 SHARED WAY TEST CITY 20850',
        '2|07000007|502 SHARED WAY TEST CITY 20850',
        'N/A|NULL|502 SHARED WAY TEST CITY 20850'], sql(db, unit_under('C000902') + ';')
    assert roots(db, 'C000906') == ['Property']
    assert sql(db, unit_under('C000906') + " WHERE un.UnitNumber = 'A';") == 'A|07000010|1000 SOLO LN TEST CITY 20850'
    assert sql(db, "SELECT COUNT(*) FROM dbo.UPR b JOIN dbo.UPR r ON r.UPRID = b.ParentUPRID "
               "WHERE r.AccountNumber = 'C000905' AND b.EntityTypeID = (SELECT EntityTypeID FROM dbo.REF_ENTITYTYPE "
               "WHERE Description = 'Building');") == '3', 'ZIP conflict must not be consolidated'
    print('PASS: shared address blocks only that Building; single-address C Number Property gets its Unit', flush=True)

    before = sql(db, SNAPSHOT)
    last_audit = sql(db, 'SELECT MAX(AuditID) FROM dbo.AuditLog;')
    load(db)
    assert sql(db, SNAPSHOT) == before, 'unchanged rerun changed the hierarchy'
    business = sql(db, f"SELECT COUNT(*) FROM dbo.AuditLog a JOIN dbo.REF_ENTITY_IDENTIFICATION e "
                   f"ON e.EntityID = a.EntityNameID WHERE a.AuditID > {last_audit} AND e.EntityName <> 'UPR_HIER_LOAD';")
    assert business == '0', f'unchanged rerun wrote {business} business audit rows'
    print('PASS: unchanged rerun is idempotent (no business audit events)', flush=True)

    # Client read/search scripts compile and run against the November 2026 names.
    unit_101 = sql(db, "SELECT u.UPRID FROM dbo.UPR u WHERE u.AccountNumber = '07000001';")
    for script, edit in (('scripts/list_upr_hierarchy.sql', None),
                         ('scripts/demo_upr_property360.sql',
                          ("DECLARE @SearchValue NVARCHAR(300)=N'24';", f"DECLARE @SearchValue NVARCHAR(300)=N'{unit_101}';")),
                         ('scripts/search_upr_master.sql', None),
                         ('scripts/check_upr_client_schema.sql', None)):
        text = (ROOT / script).read_text().replace('UPRXDB_TEST', db)
        if edit:
            assert edit[0] in text, script
            text = text.replace(*edit)
        result = sql(db, text)
        assert 'Msg ' not in result, (script, result[-2000:])
        if script.endswith('check_upr_client_schema.sql'):
            assert 'PASS: required names visible' in result and 'CORE_MISSING' not in result, result[-2000:]
    # usp_UPR_Search is created here; executing it needs dbo.UPR_CONDO_LEGACY
    # (absent from the client layout) - a separate, pre-R12 limitation.
    print('PASS: listing, Property 360 demo and schema check run, search procedure compiles, on the new names', flush=True)

    # 2. Upgrade: R10 on the earlier layout, client renames columns, then R12.
    up = new_database('CNumberUpgrade')
    client_layout(up, earlier=True)
    cnumber_fixture(up)
    load(up, R10)
    rename_to_november(up)
    unit_9601 = sql(up, "SELECT UPRID FROM dbo.EXTERNAL_IDENTIFIER_XREF WHERE SourceSystem = 'KDAT' "
                    "AND IdentifierType = 'SOURCE_RECORD_ID' AND IdentifierValue = '9601';")
    r10_units = sql(up, 'SELECT COUNT(*) FROM dbo.UNIT;')
    output = load(up)
    assert '|LOADED_ELSEWHERE|' in output
    assert roots(up, '07000001') == ['Condo']
    assert sql(up, "SELECT UPRID FROM dbo.EXTERNAL_IDENTIFIER_XREF WHERE SourceSystem = 'KDAT' "
               "AND IdentifierType = 'SOURCE_RECORD_ID' AND IdentifierValue = '9601';") == unit_9601
    assert sql(up, 'SELECT COUNT(*) FROM dbo.UNIT;') == r10_units, 'R12 duplicated units loaded by R10'
    upgraded = sql(up, SNAPSHOT)
    load(up)
    assert sql(up, SNAPSHOT) == upgraded
    print('PASS: rows loaded by R10 are reported LOADED_ELSEWHERE, not moved or duplicated; rerun idempotent', flush=True)

    # 3. Differential: no C Numbers in the standard seed -> identical results.
    a, b = new_database('SeedR10'), new_database('SeedR12')
    client_layout(a, earlier=True)
    load(a, R10)
    rename_to_november(a)
    client_layout(b)
    load(b)
    snap_a, snap_b = sql(a, SNAPSHOT), sql(b, SNAPSHOT)
    assert snap_a == snap_b, '\n'.join(
        line for line in __import__('difflib').unified_diff(snap_a.splitlines(), snap_b.splitlines(), lineterm=''))
    print(f'PASS: standard hostile seed gives identical R10/R12 results ({len(snap_b.splitlines())} snapshot rows)', flush=True)

    # 4. Un-renamed database: the layout check lists the names and changes nothing.
    stale = new_database('EarlierLayout')
    client_layout(stale, earlier=True)
    cnumber_fixture(stale)
    output = sql(stale, LOADER.replace('UPRXDB_TEST', stale), error=True)
    assert 'Record layout check FAILED' in output, output[-3000:]
    for table, column in (('UPR', 'UpdateDate'), ('UPR_ADDRESS', 'PrimaryInd'), ('BUILDING', 'UpdateDate'),
                          ('UNIT', 'UpdateDate'), ('REF_PROPERTYTYPE', 'LastUpdateUserID'),
                          ('REF_PROPERTYTYPE', 'LastUpdateDate')):
        assert f'{table}|{column}|Column used by the loader is missing' in output, (table, column)
    assert 'Invalid column name' not in output, 'later batches were compiled into errors'
    assert sql(stale, "SELECT COUNT(*) FROM dbo.UPR; SELECT COUNT(*) FROM sys.objects WHERE name LIKE 'fn[_]UPR[_]%';"
               ).splitlines() == ['0', '0'], 'layout check let the script change the database'
    print('PASS: un-renamed database stops in the layout check with every missing name; nothing changed', flush=True)
finally:
    for database in CREATED:
        sql('master', f"ALTER DATABASE [{database}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; "
            f"DROP DATABASE [{database}];")
