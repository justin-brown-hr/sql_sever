#!/usr/bin/env python3
"""Missing parcels load without review; independent rejection reasons survive."""
import os
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
CONTAINER = os.environ.get('CONTAINER', 'uprtest')
DATABASE = 'UPR_OptionalParcel_' + uuid.uuid4().hex


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
    return sql('USE UPRXDB_TEST; SET NOCOUNT ON; SET QUOTED_IDENTIFIER ON;\n' + text)


sql(f'CREATE DATABASE [{DATABASE}];')
try:
    setup = (ROOT / 'test/local_it_setup.sql').read_text()
    sql(setup.split('/* ---------------------------------------------------------------- MA rows -- */')[0])
    sql((ROOT / 'ddl/03_new_upr_schema.sql').read_text())
    sql((ROOT / 'scripts/install_upr_audit.sql').read_text())
    # Every accepted missing-parcel representation in each incoming source.
    parcels = ['NULL', "N''", "N'   '", "N'0'", "N'000'", "N'NULL'", "N'N/A'", "N'NA'", "N'NONE'"]
    for i, parcel in enumerate(parcels, 1):
        query(f"""
INSERT dbo.MAIncomingTableX1 (MasterAddressID, Account, ParcelNumber,
    StreetNumber, StreetName, StreetType, LUCategory)
VALUES ({i}, '710000{i:02}', {parcel}, '{i}', 'MA PARCEL', 'ST', 'Single Family Detached');
INSERT dbo.SDATIncomingTableX1 (RealPropertyTaxInformationID, AccountNumber, Parcel,
    PremisesNumber, PremisesStreetName, PremisesStreetType)
VALUES ({i}, '720000{i:02}', {parcel}, '{i}', 'SDAT PARCEL', 'ST');
""")
    query("""
INSERT dbo.MAIncomingTableX1 (MasterAddressID, Account, StreetNumber, StreetName, LUCategory)
VALUES (100, NULL, '100', 'NO ACCOUNT MA', 'Office'),
       (101, '71000101', '0', 'BAD ADDRESS MA', 'Office'),
       (102, '71000102', '10', 'COMPLEX PARCEL', 'Multi-Family'),
       (103, '71000102', '12', 'COMPLEX PARCEL', 'Multi-Family'),
       (104, '71000104', '14', 'SHARED PARCEL', 'Office');
INSERT dbo.SDATIncomingTableX1 (RealPropertyTaxInformationID, AccountNumber,
    PremisesNumber, PremisesStreetName)
VALUES (100, NULL, '100', 'NO ACCOUNT SDAT'),
       (101, '72000101', '0', 'BAD ADDRESS SDAT'),
       (102, '71000102', '10', 'COMPLEX PARCEL'),
       (104, '71000104', '99', 'UNMATCHED PARCEL');
""")
    loader = (ROOT / 'scripts/load_upr_master.sql').read_text()
    sql(loader + """
IF (SELECT COUNT(*) FROM #Stage WHERE IsValid = 1 AND ParcelID IS NULL AND ReviewReason IS NULL) <> 22
    THROW 51300, 'Optional-parcel records did not stage as accepted without a reason.', 1;
""")
    query("""
IF (SELECT COUNT(*) FROM dbo.UPR WHERE ParentUPRID IS NULL) <> 20
    THROW 51301, 'Optional-parcel records failed to load or created extra parents.', 1;
IF EXISTS (SELECT 1 FROM dbo.PROPERTY WHERE Parcel IS NOT NULL)
    THROW 51302, 'A missing parcel was replaced with a fabricated value.', 1;
IF (SELECT COUNT(*) FROM dbo.EXTERNAL_IDENTIFIER_XREF WHERE IdentifierType = 'SOURCE_RECORD_ID') <> 22
    THROW 51303, 'Accepted records lost source links.', 1;
IF (SELECT COUNT(*) FROM dbo.UPRMATCHREVIEW_Q) <> 5
   OR (SELECT COUNT(*) FROM dbo.UPRMATCHREVIEW_Q WHERE ReasonForNoMatch = 'INSUFFICIENT_DATA') <> 2
   OR (SELECT COUNT(*) FROM dbo.UPRMATCHREVIEW_Q WHERE ReasonForNoMatch = 'NO_ADDRESS_MATCH') <> 3
    THROW 51304, 'Missing parcel caused review, or suppressed another rejection reason.', 1;
IF EXISTS (SELECT 1 FROM dbo.UPRMATCHREVIEW_Q WHERE MA_Account LIKE '710000%'
    OR SDAT_AccountNumber LIKE '720000%' OR MA_Account = '71000102' OR SDAT_AccountNumber = '71000102')
    THROW 51305, 'An accepted optional-parcel record was queued for review.', 1;
""")
    print('PASS: NULL, blank, zero and text placeholders accepted for MA and SDAT; no parcel-only reviews')
    print('PASS: missing accounts, invalid addresses and unmatched shared SDAT still require review')
    # A client may already have an old parcel-only review. Preserve historical
    # entries, and prove that neither the upgrade nor rerun writes another one.
    query("""
INSERT dbo.UPRMATCHREVIEW_Q (IncomingSourceSystem, MA_Account,
    SDAT_NormalizedIncomingAddress, MA_NormalizedIncomingAddress,
    ReasonForNoMatch, ReviewStatus)
VALUES ('ADDRESS_MASTER', '71000001', '', '1 MA PARCEL ST', 'MISSING PARCELID', 'PENDING_REVIEW');
""")
    snapshot_query = """
SELECT CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', (
    SELECT UPRID, ParentUPRID, AccountNumber FROM dbo.UPR ORDER BY UPRID FOR JSON PATH)), 2);
"""
    before = query(snapshot_query)
    audit_id = int(query('SELECT MAX(AuditID) FROM dbo.AuditLog;').splitlines()[-1])
    sql(loader)
    assert query(snapshot_query) == before, 'Rerun changed the hierarchy or identities'
    query(f"""
IF (SELECT COUNT(*) FROM dbo.UPRMATCHREVIEW_Q) <> 6
   OR (SELECT COUNT(*) FROM dbo.UPRMATCHREVIEW_Q WHERE ReasonForNoMatch = 'MISSING PARCELID') <> 1
    THROW 51306, 'Rerun duplicated reviews or removed a historical entry.', 1;
IF EXISTS (SELECT 1 FROM dbo.AuditLog WHERE AuditID > {audit_id} AND EntityName <> 'UPR_HIER_LOAD')
    THROW 51307, 'Unchanged rerun wrote business audit events.', 1;
""")
    print('PASS: existing review history retained; rerun adds no reviews or business changes')
finally:
    sql(f'USE master; ALTER DATABASE [{DATABASE}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; '
        f'DROP DATABASE [{DATABASE}];')
