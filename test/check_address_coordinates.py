#!/usr/bin/env python3
"""Coordinate pairs must come from one row; narrowly repair legacy MAX pairs."""
import os
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
CONTAINER = os.environ.get('CONTAINER', 'uprtest')
DATABASE = 'UPR_Coordinates_' + uuid.uuid4().hex


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


sql(f'CREATE DATABASE [{DATABASE}];')
try:
    setup = (ROOT / 'test/local_it_setup.sql').read_text()
    sql(setup.split('/* ---------------------------------------------------------------- MA rows -- */')[0])
    sql((ROOT / 'ddl/03_new_upr_schema.sql').read_text())
    sql((ROOT / 'scripts/install_upr_audit.sql').read_text())
    query("""
INSERT dbo.MAIncomingTableX1 (MasterAddressID, Account, StreetNumber, StreetName, LUCategory, XCoordinate, YCoordinate)
VALUES (1, '73000001', '1', 'PAIR', 'Office', 10, 90),
       (2, '73000001', '1', 'PAIR', 'Office', 20, 80),
       (3, '73000002', '2', 'PARTIAL', 'Office', 10, NULL),
       (4, '73000002', '2', 'PARTIAL', 'Office', NULL, 20),
       (5, '73000003', '3', 'MISSING', 'Office', NULL, NULL),
       (6, '73000004', '4', 'COMPLETE', 'Office', 1, NULL),
       (7, '73000004', '4', 'COMPLETE', 'Office', 2, 3);
SELECT 'SEEDED';
""")
    loader = (ROOT / 'scripts/load_upr_master.sql').read_text()
    sql(loader)
    verify = """
IF (SELECT COUNT(*) FROM dbo.ADDRESS) <> 4
    THROW 51400, 'Coordinate fixture created unexpected addresses.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.ADDRESS WHERE StreetName = 'PAIR' AND XCoordinate = 10 AND YCoordinate = 90)
 OR NOT EXISTS (SELECT 1 FROM dbo.ADDRESS WHERE StreetName = 'PARTIAL' AND XCoordinate = 10 AND YCoordinate IS NULL)
 OR NOT EXISTS (SELECT 1 FROM dbo.ADDRESS WHERE StreetName = 'MISSING' AND XCoordinate IS NULL AND YCoordinate IS NULL)
 OR NOT EXISTS (SELECT 1 FROM dbo.ADDRESS WHERE StreetName = 'COMPLETE' AND XCoordinate = 2 AND YCoordinate = 3)
    THROW 51401, 'Coordinates were combined across rows, fabricated or selected unstably.', 1;
SELECT 'PASS';
"""
    query(verify)
    identities = "SELECT CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', (SELECT * FROM dbo.UPR_ADDRESS ORDER BY UPRAddressID FOR JSON PATH)), 2);"
    before = query(identities)
    # Reproduce the two old independently aggregated coordinate pairs.
    query("""
UPDATE dbo.ADDRESS SET XCoordinate = 20, YCoordinate = 90 WHERE StreetName = 'PAIR';
UPDATE dbo.ADDRESS SET XCoordinate = 10, YCoordinate = 20 WHERE StreetName = 'PARTIAL';
SELECT 'LEGACY';
""")
    audit_id = int(query('SELECT MAX(AuditID) FROM dbo.AuditLog;'))
    sql(loader)
    query(verify)
    assert query(identities) == before, 'Legacy repair replaced IDs or address links'
    query(f"""
IF (SELECT COUNT(*) FROM dbo.AuditLog WHERE AuditID > {audit_id} AND EntityName = 'ADDRESS'
    AND OperationType = 'UPDATE' AND RunID IS NOT NULL) <> 2
    THROW 51402, 'Legacy coordinate repairs did not record both before/after events.', 1;
SELECT 'PASS';
""")
    print('PASS: complete, partial and missing pairs stay source-backed; legacy combinations repaired with IDs and audit preserved')
    audit_id = int(query('SELECT MAX(AuditID) FROM dbo.AuditLog;'))
    sql(loader)
    query(f"IF EXISTS (SELECT 1 FROM dbo.AuditLog WHERE AuditID > {audit_id} AND EntityName <> 'UPR_HIER_LOAD') "
          "THROW 51403, 'Coordinate selection changed on an unchanged rerun.', 1; SELECT 'PASS';")
    # Preserve a different real source pair and a manually maintained pair.
    query("""
UPDATE dbo.ADDRESS SET XCoordinate = 20, YCoordinate = 80 WHERE StreetName = 'PAIR';
UPDATE dbo.ADDRESS SET XCoordinate = 777, YCoordinate = 888 WHERE StreetName = 'PARTIAL';
SELECT 'EXISTING';
""")
    sql(loader)
    query("""
IF NOT EXISTS (SELECT 1 FROM dbo.ADDRESS WHERE StreetName = 'PAIR' AND XCoordinate = 20 AND YCoordinate = 80)
 OR NOT EXISTS (SELECT 1 FROM dbo.ADDRESS WHERE StreetName = 'PARTIAL' AND XCoordinate = 777 AND YCoordinate = 888)
    THROW 51404, 'Repair overwrote existing coordinates outside the legacy pattern.', 1;
SELECT 'PASS';
""")
    print('PASS: unchanged rerun is quiet; other existing source/manual coordinate pairs are preserved')
finally:
    sql(f'USE master; ALTER DATABASE [{DATABASE}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [{DATABASE}];')
