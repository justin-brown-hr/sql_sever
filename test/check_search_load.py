#!/usr/bin/env python3
"""SEARCH-002 loader normalization, parcel provenance, rerun and migration guard.
Runs only in a new disposable database on the integration test container.
"""
import os
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
CONTAINER = os.environ.get('CONTAINER', 'uprtest')
DATABASE = 'UPR_SearchLoad_' + uuid.uuid4().hex


def sql(text, expect_error=False):
    result = subprocess.run(
        ['docker', 'exec', '-i', CONTAINER, 'bash', '-lc',
         'exec /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa '
         '-P "$MSSQL_SA_PASSWORD" -C -b -W -h -1 -w 65535'],
        input=text.replace('UPRXDB_TEST', DATABASE), text=True, capture_output=True)
    output = result.stdout + result.stderr
    if bool(result.returncode) != expect_error:
        raise AssertionError(output[-8000:])
    return output


def script(path):
    return (ROOT / path).read_text()


def query(text):
    return sql('USE UPRXDB_TEST;\nGO\nSET NOCOUNT ON; SET QUOTED_IDENTIFIER ON;\n' + text)


sql(f'CREATE DATABASE [{DATABASE}];')
try:
    for path in ['test/local_it_setup.sql', 'ddl/03_new_upr_schema.sql', 'scripts/install_upr_audit.sql']:
        sql(script(path))
    query("""
DELETE dbo.MAIncomingTableX1;
DELETE dbo.SDATIncomingTableX1;
INSERT dbo.MAIncomingTableX1
(MasterAddressID,Account,ParcelNumber,StreetNumber,StreetName,StreetType,City,ZipCode,LUCategory,Unit)
VALUES(99101,'123-456-789','P-123','123','MAIN','ST','ROCKVILLE','20850','Multifamily','101'),
      (99102,'23456789',NULL,'456','OAK','RD','ROCKVILLE','20850','Multifamily','101');
""")
    sql(script('scripts/load_upr_master.sql'))
    query("""
IF (SELECT COUNT(*) FROM dbo.UPR WHERE ParentUPRID IS NULL AND AccountNumber IN('123456789','23456789'))<>2
    THROW 51800,'Long and short accounts collided.',1;
IF (SELECT COUNT(*) FROM dbo.EXTERNAL_IDENTIFIER_XREF WHERE IdentifierType='PARCEL_ID'
    AND SourceSystem='ADDRESS_MASTER' AND IdentifierValue='P-123')<>2
    THROW 51801,'Parcel source target/root links missing.',1;
IF EXISTS(SELECT 1 FROM dbo.EXTERNAL_IDENTIFIER_XREF WHERE IdentifierType='PARCEL_ID' AND IdentifierValue IN('','0','NULL'))
    THROW 51802,'Missing parcel generated a placeholder identifier.',1;
""")
    before = query("SELECT UPRID,ParentUPRID,AccountNumber FROM dbo.UPR ORDER BY UPRID;")
    sql(script('scripts/load_upr_master.sql'))
    assert query("SELECT UPRID,ParentUPRID,AccountNumber FROM dbo.UPR ORDER BY UPRID;") == before
    query("""
DECLARE @Run UNIQUEIDENTIFIER=(SELECT TOP(1) RunID FROM dbo.UPR_LOAD_RUN ORDER BY StartedAt DESC,RunID DESC);
IF EXISTS(SELECT 1 FROM dbo.AUDIT_LOG a JOIN dbo.REF_ENTITY_IDENTIFICATION e ON e.EntityID=a.EntityID
    WHERE a.RunID=@Run AND e.EntityName<>'UPR_HIER_LOAD')
    THROW 51803,'Unchanged search-data rerun wrote business changes.',1;
""")
    sql(script('scripts/search_upr_master.sql'))
    sql(script('test/local_it_search_v2.sql'))
    # Simulate the previous truncating normalizer while retaining the actual
    # source links. The updated loader must stop before making a competing root.
    query("UPDATE dbo.UPR SET AccountNumber='23456789' WHERE AccountNumber='123456789';")
    before_guard = query("SELECT UPRID,ParentUPRID,AccountNumber FROM dbo.UPR ORDER BY UPRID;")
    output = sql(script('scripts/load_upr_master.sql'), expect_error=True)
    assert 'truncated account' in output, output[-4000:]
    assert query("SELECT UPRID,ParentUPRID,AccountNumber FROM dbo.UPR ORDER BY UPRID;") == before_guard
    print('PASS: account preservation, source parcels, unchanged rerun, search contract and existing-account guard')
finally:
    sql(f'USE master; ALTER DATABASE [{DATABASE}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [{DATABASE}];')
