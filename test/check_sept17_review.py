#!/usr/bin/env python3
"""September 17 review: screenshot shapes, prior-loader reproduction and migration.

Requires a disposable SQL Server container, as does run_local_it.sh. Source IDs,
LUCategory and blank SDAT CondoUnit are fixture assumptions: the screenshots do
not show them. Account/address inventories and requested counts are transcribed.
The baseline comes from the repository's September 17 commit, not a simulation.
"""
import json
import os
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
CONTAINER = os.environ.get('CONTAINER', 'uprtest')
BASELINE = 'fdba4d0966b6349ac917fb1a7f62fddb0ac0d0a2'
DATABASE = 'UPR_Sept17_' + uuid.uuid4().hex


def sql(text, expect_error=False):
    result = subprocess.run(
        ['docker', 'exec', '-i', CONTAINER, 'bash', '-lc',
         'exec /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa '
         '-P "$MSSQL_SA_PASSWORD" -C -b -W -h -1 -w 65535'],
        input=text.replace('UPRXDB_TEST', DATABASE), text=True, capture_output=True)
    if bool(result.returncode) != expect_error:
        raise AssertionError((result.stdout + result.stderr)[-8000:])
    return '\n'.join(x for x in result.stdout.splitlines()
                     if x.strip() and not x.startswith('Changed database context'))


def query(text):
    return sql('USE UPRXDB_TEST;\nGO\nSET NOCOUNT ON; SET QUOTED_IDENTIFIER ON;\n' + text)


def script(name, baseline=False):
    if baseline:
        return subprocess.check_output(['git', 'show', f'{BASELINE}:{name}'], cwd=ROOT, text=True)
    return (ROOT / name).read_text()


def load():
    sql(script('scripts/load_upr_master.sql'))


def inventory():
    return json.loads(query('''
SELECT root.AccountNumber,
    Buildings = (SELECT COUNT(*) FROM dbo.BUILDING b JOIN dbo.UPR u ON u.UPRID = b.UPRID WHERE u.ParentUPRID = root.UPRID),
    Units = (SELECT COUNT(*) FROM dbo.UNIT un JOIN dbo.BUILDING b ON b.BuildingID = un.BuildingID
             JOIN dbo.UPR u ON u.UPRID = b.UPRID WHERE u.ParentUPRID = root.UPRID)
FROM dbo.UPR root WHERE root.ParentUPRID IS NULL AND root.AccountNumber IN ('00050037','00261025','00050048','00272520')
ORDER BY root.AccountNumber FOR JSON PATH;
'''))


FIXTURE = '''
INSERT dbo.MAIncomingTableX1
(MasterAddressID, Account, StreetNumber, StreetName, StreetType, City, ZipCode, LUCategory)
VALUES
(9701,'00050037','12309','VILLAGE SQUARE','TER','ROCKVILLE','20852','Multifamily'),
(9702,'00050037','12201','VILLAGE SQUARE','TER','ROCKVILLE','20852','Multifamily'),
(9703,'00050037','12300','VILLAGE SQUARE','TER','ROCKVILLE','20852','Multifamily'),
(9711,'00261025','13820','CASTLE','BLVD','SILVER SPRING','20904','Multifamily'),
(9712,'00261025','13812','CASTLE','BLVD','SILVER SPRING','20904','Multifamily'),
(9713,'00261025','13800','CASTLE','BLVD','SILVER SPRING','20904','Multifamily'),
(9721,'00050048','12509','VILLAGE SQUARE','TER','ROCKVILLE','20852','Multifamily'),
(9722,'00050048','12503','VILLAGE SQUARE','TER','ROCKVILLE','20852','Multifamily'),
(9723,'00050048','12406','VILLAGE SQUARE','TER','ROCKVILLE','20852','Multifamily'),
(9724,'00050048','12511','VILLAGE SQUARE','TER','ROCKVILLE','20852','Multifamily'),
(9725,'00050048','12405','VILLAGE SQUARE','TER','ROCKVILLE','20852','Multifamily'),
(9726,'00050048','12401','VILLAGE SQUARE','TER','ROCKVILLE','20852','Multifamily'),
(9731,'00272520','375','SOUTHAMPTON','DR','SILVER SPRING','20903','Multifamily'),
(9732,'00272520','351','SOUTHAMPTON','DR','SILVER SPRING','20903','Multifamily'),
(9733,'00272520','379','SOUTHAMPTON','DR','SILVER SPRING','20903','Multifamily');
INSERT dbo.SDATIncomingTableX1
(RealPropertyTaxInformationID, AccountNumber, PremisesNumber, PremisesStreetName, PremisesStreetType, PremisesCity, PremisesZipCode)
VALUES
(9801,'50037','12201','VILLAGE SQUARE','TER','ROCKVILLE','208520000'),
(9811,'00261025','13800','CASTLE','BLV','SILVER SPRING','209040000'),
(9821,'00050048','12300','VILLAGE SQUARE','TER','ROCKVILLE','208520000'),
(9831,'00272520','00335','SOUTHAMPTON','DR','SILVER SPRING','209030000');
'''
EXPECTED = [('00050037', 3, 3), ('00050048', 7, 7), ('00261025', 3, 3), ('00272520', 4, 4)]


def assert_inventory(expected=EXPECTED):
    actual = [(r['AccountNumber'], r['Buildings'], r['Units']) for r in inventory()]
    assert actual == expected, actual


def verify(guarded=False):
    expected = [(a,b,4 if guarded and a == "00050037" else u) for a,b,u in EXPECTED]
    assert_inventory(expected)
    pairs = "('9713','9811')" if guarded else "('9702','9801'),('9713','9811')"
    query(f'''
IF EXISTS (SELECT 1 FROM (VALUES {pairs}) p(MAID,SDID)
    JOIN dbo.EXTERNAL_IDENTIFIER_XREF ma ON ma.SourceSystem = 'ADDRESS_MASTER' AND ma.IdentifierType = 'SOURCE_RECORD_ID' AND ma.IdentifierValue = p.MAID
    JOIN dbo.EXTERNAL_IDENTIFIER_XREF sd ON sd.SourceSystem = 'KDAT' AND sd.IdentifierType = 'SOURCE_RECORD_ID' AND sd.IdentifierValue = p.SDID
    WHERE ma.UPRID <> sd.UPRID)
    THROW 51701, 'Overlapping sources do not share one Unit.', 1;
IF (SELECT COUNT(*) FROM dbo.EXTERNAL_IDENTIFIER_XREF WHERE IdentifierType = 'SOURCE_RECORD_ID') <> 19
    THROW 51702, 'Source links were lost.', 1;
IF COL_LENGTH('dbo.CONDO','CondoName') IS NOT NULL OR COL_LENGTH('dbo.CONDO','Parcel') IS NOT NULL
    THROW 51703, 'Removed Condo columns remain.', 1;
IF COL_LENGTH('dbo.UPR_CLOSURE','AncestorUPRID') IS NOT NULL OR COL_LENGTH('dbo.UPR_CLOSURE','UPRAncestry') IS NULL
    THROW 51704, 'Closure rename was not applied.', 1;
IF EXISTS (SELECT 1 FROM dbo.AUDIT_LOG WHERE EntityID IS NULL OR EntityRecordID IS NULL)
    THROW 51705, 'Normalized audit identity is missing.', 1;
IF EXISTS (SELECT 1 FROM dbo.AUDIT_LOG a JOIN dbo.REF_ENTITY_IDENTIFICATION e ON e.EntityID = a.EntityID
    WHERE e.EntityName = 'UNIT' AND a.OriginalUPRID IS NULL)
    THROW 51706, 'Unit audit lost UPR identification.', 1;
DBCC CHECKCONSTRAINTS WITH ALL_CONSTRAINTS;
''')
    before = query('SELECT MAX(AuditLogID) FROM dbo.AUDIT_LOG;')
    load()
    assert_inventory(expected)
    query(f'''IF EXISTS (SELECT 1 FROM dbo.AUDIT_LOG a JOIN dbo.REF_ENTITY_IDENTIFICATION e ON e.EntityID = a.EntityID
    WHERE a.AuditLogID > {before} AND e.EntityName <> 'UPR_HIER_LOAD')
    THROW 51707, 'Unchanged rerun changed business data.', 1;''')


def test_delete_audit():
    query('''
DECLARE @ID BIGINT;
INSERT dbo.UPR (EntityTypeID) SELECT EntityTypeID FROM dbo.REF_ENTITYTYPE WHERE Description = 'Property';
SET @ID = SCOPE_IDENTITY();
DELETE dbo.UPR WHERE UPRID = @ID;
IF (SELECT COUNT(*) FROM dbo.AUDIT_LOG WHERE OriginalUPRID = @ID AND ActionType IN ('INSERT','DELETE')) <> 2
    THROW 51708, 'UPR deletion lost event identity.', 1;
IF EXISTS (SELECT 1 FROM dbo.AUDIT_LOG WHERE OriginalUPRID = @ID AND UPRID IS NOT NULL)
    THROW 51709, 'Deleted UPR left an invalid live FK.', 1;
EXEC dbo.usp_UPR_AuditReport @UPRID = @ID;
''')


def test_closure_audit_identity():
    query("""
BEGIN TRANSACTION;
DECLARE @Ancestor BIGINT, @Descendant BIGINT, @RecordID BIGINT, @Before BIGINT;
SELECT TOP (1) @Ancestor = c.UPRAncestry, @Descendant = c.DescendantUPRID, @RecordID = a.EntityRecordID
FROM dbo.UPR_CLOSURE c JOIN dbo.AUDIT_LOG a
    ON TRY_CONVERT(BIGINT, JSON_VALUE(a.EntityKey,'$.AncestorUPRID')) = c.UPRAncestry
   AND TRY_CONVERT(BIGINT, JSON_VALUE(a.EntityKey,'$.DescendantUPRID')) = c.DescendantUPRID
JOIN dbo.REF_ENTITY_IDENTIFICATION e ON e.EntityID = a.EntityID AND e.EntityName = 'UPR_CLOSURE';
IF @RecordID IS NULL THROW 51717, 'No migrated closure event for identity test.', 1;
SELECT @Before = MAX(AuditLogID) FROM dbo.AUDIT_LOG;
UPDATE dbo.UPR_CLOSURE SET [Level] = [Level] + 1 WHERE UPRAncestry = @Ancestor AND DescendantUPRID = @Descendant;
IF NOT EXISTS (SELECT 1 FROM dbo.AUDIT_LOG WHERE AuditLogID > @Before AND EntityRecordID = @RecordID
    AND JSON_VALUE(EntityKey,'$.UPRAncestry') = CONVERT(NVARCHAR(30),@Ancestor))
    THROW 51718, 'Column rename split the audit identity of an existing closure row.', 1;
ROLLBACK;
""")


def test_boundaries():
    query("""
INSERT dbo.MAIncomingTableX1 (MasterAddressID, Account, StreetNumber, StreetName, StreetType, City, ZipCode, LUCategory, Unit)
VALUES
(9901,'00990001','10','BOUNDARY','ST','TEST','20850','Multifamily','101'),
(9902,'00990001','10','BOUNDARY','ST','TEST','20850','Multifamily','102'),
(9903,'00990002','20','BOUNDARY','ST','TEST','20850','Multifamily',NULL),
(9904,'00990002','20','BOUNDARY','ST','TEST','20850','Multifamily',NULL),
(9905,'00990003','10','BOUNDARY','ST','TEST','20850','Multifamily','101');
INSERT dbo.SDATIncomingTableX1
(RealPropertyTaxInformationID, AccountNumber, PremisesNumber, PremisesStreetName, PremisesStreetType, PremisesCity, PremisesZipCode, CondoUnit)
VALUES
(9901,'00990001','10','BOUNDARY','ST','TEST','20850','101'),
(9902,'00990002','20','BOUNDARY','ST','TEST','20850',NULL);
INSERT dbo.SDATIncomingTableX1
(RealPropertyTaxInformationID, AccountNumber, Parcel, PremisesNumber, PremisesStreetName, PremisesStreetType, PremisesCity, PremisesZipCode)
VALUES (9903,'00999998','FRESH-PARCEL','30','BOUNDARY','ST','TEST','20850');
""")
    load()
    query("""
IF (SELECT COUNT(DISTINCT x.UPRID) FROM dbo.EXTERNAL_IDENTIFIER_XREF x
    WHERE x.IdentifierType = 'SOURCE_RECORD_ID' AND
        ((x.SourceSystem = 'ADDRESS_MASTER' AND x.IdentifierValue IN ('9901','9902','9905'))
          OR (x.SourceSystem = 'KDAT' AND x.IdentifierValue = '9901'))) <> 3
    THROW 51714, 'Numbered units or different accounts were collapsed incorrectly.', 1;
IF (SELECT COUNT(DISTINCT x.UPRID) FROM dbo.EXTERNAL_IDENTIFIER_XREF x
    WHERE x.IdentifierType = 'SOURCE_RECORD_ID' AND
        ((x.SourceSystem = 'ADDRESS_MASTER' AND x.IdentifierValue IN ('9903','9904'))
          OR (x.SourceSystem = 'KDAT' AND x.IdentifierValue = '9902'))) <> 3
    THROW 51715, 'Ambiguous blank rows were arbitrarily paired.', 1;
""")
    result = query("EXEC dbo.usp_UPR_Search @AccountNumber = N'00999998', @ParcelID = N'FRESH-PARCEL';")
    assert '00999998' in result, 'Fresh Condo parcel is no longer searchable'


def test_blank_key_collision():
    query("""
INSERT dbo.MAIncomingTableX1 (MasterAddressID, Account, StreetNumber, StreetName, StreetType, City, ZipCode, LUCategory, Unit)
VALUES (9991,'00999991','90','KEY COLLISION','ST','TEST','20850','Multifamily',NULL),
       (9992,'00999991','90','KEY COLLISION','ST','TEST','20850','Multifamily','TEMP');
""")
    # Force a real source Unit value to equal this run's internal blank-row key.
    # This is test-only input preparation; the actual unit matching code runs intact.
    marker = "PRINT N'Step 5: Write UPRMATCHREVIEW_Q for rejected rows...';"
    preparation = """
DECLARE @CollisionValue NVARCHAR(50) = N'#' + CONVERT(NVARCHAR(20),
    (SELECT StageKey FROM #Stage WHERE SourceSystem = N'ADDRESS_MASTER' AND SourceRecordID = N'9991'));
UPDATE dbo.MAIncomingTableX1 SET Unit = @CollisionValue WHERE MasterAddressID = 9992;
UPDATE #Stage SET UnitNumber = @CollisionValue WHERE SourceSystem = N'ADDRESS_MASTER' AND SourceRecordID = N'9992';
"""
    loader = script('scripts/load_upr_master.sql')
    assert loader.count(marker) == 1
    sql(loader.replace(marker, preparation + marker))
    query("""
IF (SELECT COUNT(DISTINCT x.UPRID) FROM dbo.EXTERNAL_IDENTIFIER_XREF x
    WHERE x.SourceSystem = 'ADDRESS_MASTER' AND x.IdentifierType = 'SOURCE_RECORD_ID'
      AND x.IdentifierValue IN ('9991','9992')) <> 2
    THROW 51719, 'A real unit number collided with an internal blank-row key.', 1;
""")


sql(f'CREATE DATABASE [{DATABASE}];')
try:
    for baseline, guarded in ((True, False), (True, True), (False, False)):
        if guarded or not baseline:
            query(f'USE master; ALTER DATABASE [{DATABASE}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [{DATABASE}];')
            sql(f'CREATE DATABASE [{DATABASE}];')
        setup = script('test/local_it_setup.sql').split('/* ---------------------------------------------------------------- MA rows -- */')[0]
        sql(setup)
        sql(script('ddl/03_new_upr_schema.sql', baseline))
        sql(script('scripts/install_upr_audit.sql', baseline))
        query(FIXTURE)
        if baseline:
            sql(script('scripts/load_upr_master.sql', True))
            assert_inventory([('00050037',3,4),('00050048',7,7),('00261025',4,4),('00272520',4,4)])
            if guarded:
                query("UPDATE u SET FloorNumber = 'MANUAL' FROM dbo.UNIT u JOIN dbo.EXTERNAL_IDENTIFIER_XREF x ON x.UPRID = u.UPRID WHERE x.SourceSystem = 'KDAT' AND x.IdentifierType = 'SOURCE_RECORD_ID' AND x.IdentifierValue = '9801';")
            kept_ids = query("SELECT UPRID FROM dbo.EXTERNAL_IDENTIFIER_XREF WHERE SourceSystem = 'ADDRESS_MASTER' AND IdentifierType = 'SOURCE_RECORD_ID' ORDER BY IdentifierValue;")
            query('''INSERT dbo.UPR (EntityTypeID, AccountNumber)
SELECT EntityTypeID, '00999999' FROM dbo.REF_ENTITYTYPE WHERE Description = 'Condo';
DECLARE @NamedCondo BIGINT = SCOPE_IDENTITY();
INSERT dbo.CONDO (UPRID, CondoName, Parcel) VALUES (@NamedCondo, 'KEEP MANUAL NAME', 'KEEP-PARCEL');''')
            history_count = query('SELECT COUNT(*) FROM dbo.AuditLog;')
            sql(script('scripts/install_upr_audit.sql'))
            sql(script('scripts/install_upr_audit.sql'))
            query(f'''IF (SELECT COUNT(*) FROM dbo.AUDIT_LOG) <> {history_count}
    THROW 51710, 'Repeated migration changed historical event count.', 1;
IF EXISTS (SELECT AuditID, EntityName, EntityKey, OperationType, OldValues, NewValues FROM dbo.AuditLog_PreSept17
    EXCEPT SELECT AuditID, EntityName, EntityKey, OperationType, OldValues, NewValues FROM dbo.AuditLog)
    THROW 51711, 'Migration changed retained history.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.UPR_CONDO_LEGACY WHERE CondoName = 'KEEP MANUAL NAME' AND Parcel = 'KEEP-PARCEL')
    THROW 51716, 'Removed Condo values were not archived.', 1;''')
        load()
        verify(guarded)
        if baseline:
            assert kept_ids == query("SELECT UPRID FROM dbo.EXTERNAL_IDENTIFIER_XREF WHERE SourceSystem = 'ADDRESS_MASTER' AND IdentifierType = 'SOURCE_RECORD_ID' ORDER BY IdentifierValue;"), 'MA IDs changed during upgrade'
            expected_deletes = 1 if guarded else 2
            query(f'''IF (SELECT COUNT(*) FROM dbo.AUDIT_LOG a JOIN dbo.REF_ENTITY_IDENTIFICATION e ON e.EntityID = a.EntityID
                WHERE e.EntityName = 'UNIT' AND ActionType = 'DELETE') <> {expected_deletes}
                THROW 51712, 'Duplicate Unit deletion was not audited.', 1;''')
        if guarded:
            query("IF NOT EXISTS (SELECT 1 FROM dbo.UPRMATCHREVIEW_Q WHERE Decision LIKE 'MA/SDAT blank-unit overlap%' AND SDAT_AccountNumber = '00050037') THROW 51713, 'Unsafe overlap was not queued.', 1;")
        sql(script('scripts/list_upr_audit.sql'))
        sql(script('scripts/search_upr_master.sql'))
        sql(script('scripts/list_upr_hierarchy.sql'))
        acceptance = sql(script('scripts/check_sept17_acceptance.sql'))
        assert acceptance.count('MATCHES SCREENSHOT COUNTS') == (3 if guarded else 4), acceptance
        assert acceptance.count('SHARED UNIT') == (1 if guarded else 2), acceptance
        if baseline:
            test_closure_audit_identity()
            result = query("EXEC dbo.usp_UPR_Search @AccountNumber = N'00999999', @ParcelID = N'KEEP-PARCEL';")
            assert '00999999' in result, 'Archived Condo parcel is no longer searchable'
        test_delete_audit()
        if not baseline:
            test_boundaries()
            test_blank_key_collision()
        print('PASS:', ('guarded existing-data upgrade' if guarded else 'prior-loader reproduction and existing-data upgrade') if baseline else 'fresh schema and load', flush=True)
finally:
    query(f'USE master; ALTER DATABASE [{DATABASE}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [{DATABASE}];')
