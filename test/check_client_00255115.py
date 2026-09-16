#!/usr/bin/env python3
"""Verify the attachment's visible MA subset; SDAT routing needs cropped fields.

Optional BASELINE_LOADER verifies an earlier script against this same subset
before the current loader. No synthetic SDAT address is substituted.
"""
import json
import os
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
DATABASE = 'UPR_Client255115_' + uuid.uuid4().hex
CONTAINER = os.environ.get('CONTAINER', 'uprtest')


def sql(text):
    result = subprocess.run(
        ['docker', 'exec', '-i', CONTAINER, 'bash', '-lc',
         'exec /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa '
         '-P "$MSSQL_SA_PASSWORD" -C -b -W -h -1 -w 65535'],
        input=text.replace('UPRXDB_TEST', DATABASE), text=True, capture_output=True,
    )
    if result.returncode:
        raise AssertionError((result.stdout + result.stderr)[-6000:])
    return result.stdout.strip()


def query(text):
    return sql('USE UPRXDB_TEST; SET NOCOUNT ON; SET QUOTED_IDENTIFIER ON;\n' + text).splitlines()[-1]


counts = """
SELECT Complexes = (SELECT COUNT(*) FROM dbo.COMPLEX),
    Properties = (SELECT COUNT(*) FROM dbo.PROPERTY), Condos = (SELECT COUNT(*) FROM dbo.CONDO),
    Buildings = (SELECT COUNT(*) FROM dbo.BUILDING), Units = (SELECT COUNT(*) FROM dbo.UNIT),
    MASourceLinks = (SELECT COUNT(*) FROM dbo.EXTERNAL_IDENTIFIER_XREF
                    WHERE SourceSystem = 'ADDRESS_MASTER' AND IdentifierType = 'SOURCE_RECORD_ID')
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
"""
expected = dict(Complexes=1, Properties=0, Condos=0, Buildings=2, Units=13, MASourceLinks=13)
identities = "SELECT CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', (SELECT UPRID, ParentUPRID FROM dbo.UPR ORDER BY UPRID FOR JSON PATH)), 2);"
source_rows = "SELECT CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', (SELECT * FROM dbo.MAIncomingTableX1 ORDER BY MasterAddressID FOR JSON PATH, INCLUDE_NULL_VALUES)), 2);"

sql(f'CREATE DATABASE [{DATABASE}];')
try:
    setup = (ROOT / 'test/local_it_setup.sql').read_text()
    sql(setup.split('/* ---------------------------------------------------------------- MA rows -- */')[0])
    sql((ROOT / 'ddl/03_new_upr_schema.sql').read_text())
    sql((ROOT / 'scripts/install_upr_audit.sql').read_text())
    sql((ROOT / 'test/client_00255115_visible.sql').read_text())
    source_before = query(source_rows)
    baseline_ids = None
    if os.environ.get('BASELINE_LOADER'):
        sql(Path(os.environ['BASELINE_LOADER']).read_text())
        baseline_counts = json.loads(query(counts))
        print('PRIOR LOADER, VISIBLE SUBSET:', baseline_counts, flush=True)
        assert baseline_counts == expected, baseline_counts
        baseline_ids = query(identities)

    loader = Path(os.environ.get('CLIENT_VISIBLE_LOADER', ROOT / 'scripts/load_upr_master.sql')).read_text()
    sql(loader + """
/* Inspect the actual staged SDAT row in the same connection. Its account
   classification is testable even though its address is not in the document. */
IF NOT EXISTS (SELECT 1 FROM #Stage WHERE SourceSystem = 'KDAT' AND SourceRecordID = '22265'
    AND AccountNumber = '00255115' AND IsComplexAccount = 1
    AND DistinctAddrOnAccount = 2 AND PropertyType = 'MULTI'
    AND IsValid = 0 AND ReviewReason = 'NO_ADDRESS_MATCH')
    THROW 51201, 'Visible SDAT account did not inherit MA classification before address validation.', 1;
""")
    actual = json.loads(query(counts))
    print('UPDATED LOADER, VISIBLE SUBSET:', actual, flush=True)
    assert actual == expected, actual
    if baseline_ids is not None:
        assert query(identities) == baseline_ids, 'Upgrading the visible subset changed existing IDs'
    sql("""
USE UPRXDB_TEST;
SET NOCOUNT ON;
IF dbo.fn_UPR_NormalizeSDATAccount('255115') <> '00255115'
 OR dbo.fn_UPR_NormalizeSDATAccount('00255115') <> '00255115'
    THROW 51202, 'Account formatting split the MA buildings.', 1;
IF EXISTS (SELECT 1 FROM dbo.UPR WHERE ParentUPRID IS NULL AND AccountNumber <> '00255115')
    THROW 51203, 'Unexpected root account.', 1;
IF EXISTS (SELECT 1 FROM dbo.BUILDING WHERE BuildingName IS NOT NULL)
    THROW 51204, 'Screenshot Building B/C annotations were invented as source names.', 1;
IF EXISTS (SELECT 1 FROM dbo.ADDRESS a WHERE NOT EXISTS (
    SELECT 1 FROM dbo.MAIncomingTableX1 ma
    WHERE ma.StreetNumber = a.StreetNumber AND ma.StreetName = a.StreetName
      AND ma.XCoordinate = a.XCoordinate AND ma.YCoordinate = a.YCoordinate))
    THROW 51211, 'Building coordinate pair does not occur in any supplied MA row.', 1;
IF EXISTS (
    SELECT 1 FROM dbo.MAIncomingTableX1 ma
    LEFT JOIN dbo.EXTERNAL_IDENTIFIER_XREF x ON x.SourceSystem = 'ADDRESS_MASTER'
        AND x.IdentifierType = 'SOURCE_RECORD_ID' AND x.IdentifierValue = CONVERT(VARCHAR(150), ma.MasterAddressID)
    LEFT JOIN dbo.UNIT un ON un.UPRID = x.UPRID
    LEFT JOIN dbo.UPR u ON u.UPRID = un.UPRID
    LEFT JOIN dbo.BUILDING b ON b.BuildingID = un.BuildingID
    LEFT JOIN dbo.UPR_ADDRESS ua ON ua.UPRID = b.UPRID AND ua.IsPrimary = 1
    LEFT JOIN dbo.ADDRESS a ON a.AddressID = ua.AddressID
    WHERE un.UnitID IS NULL OR a.AddressID IS NULL OR EXISTS (
        SELECT un.UnitNumber, u.ParentUPRID, a.StreetNumber, a.StreetName, a.StreetType, a.City, a.ZipCode
        EXCEPT SELECT ma.Unit, b.UPRID, ma.StreetNumber, ma.StreetName, ma.StreetType, ma.City, ma.ZipCode)
) THROW 51205, 'A visible MA unit lost its source number, building address or parent.', 1;
IF (SELECT COUNT(*) FROM dbo.UNIT WHERE UnitNumber = '101') <> 2
 OR (SELECT COUNT(*) FROM dbo.UNIT WHERE UnitNumber = '102') <> 2
 OR (SELECT COUNT(*) FROM dbo.UNIT WHERE UnitNumber = '103') <> 2
    THROW 51206, 'Same-number units in different buildings were collapsed.', 1;
IF EXISTS (SELECT 1 FROM dbo.UNIT WHERE UnitNumber IN ('746', 'N/A'))
    THROW 51207, 'DwellingUnits count or a placeholder replaced actual MA unit numbers.', 1;
IF EXISTS (SELECT 1 FROM dbo.EXTERNAL_IDENTIFIER_XREF WHERE SourceSystem = 'KDAT'
    AND IdentifierType = 'SOURCE_RECORD_ID' AND IdentifierValue = '22265')
    THROW 51208, 'Unseen SDAT address was silently filled from MA.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.UPRMATCHREVIEW_Q WHERE SDAT_AccountNumber = '00255115'
    AND ReasonForNoMatch = 'NO_ADDRESS_MATCH')
    THROW 51209, 'Partial SDAT test fixture was not explicitly rejected for its missing address.', 1;
""")
    assert query(source_rows) == source_before, 'MA incoming rows were changed'
    before_ids = query(identities)
    before_audit = query('SELECT MAX(AuditID) FROM dbo.AuditLog;')
    sql(loader)
    assert json.loads(query(counts)) == expected
    assert query(identities) == before_ids
    query(f"IF EXISTS (SELECT 1 FROM dbo.AuditLog WHERE AuditID > {before_audit} AND EntityName <> 'UPR_HIER_LOAD') "
          "THROW 51210, 'Unchanged client subset produced business changes.', 1; SELECT 'PASS';")
    print('PASS: visible MA subset forms one Complex, two Buildings and 13 real-numbered Units', flush=True)
    print('PASS: account padding, repeated unit numbers across buildings, IDs and unchanged rerun', flush=True)
    print('LIMIT: SDAT address/CondoUnit are cropped; its exact final routing and full account totals remain unverified', flush=True)
finally:
    sql(f'USE master; ALTER DATABASE [{DATABASE}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [{DATABASE}];')
