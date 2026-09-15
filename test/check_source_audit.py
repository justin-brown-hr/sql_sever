#!/usr/bin/env python3
"""Run after the normal integration pipeline, in its throwaway SQL container.

The account IDs reproduce the reported cases, but addresses below are explicitly
synthetic test fixtures, not the client's source rows. Never run against real data.
"""
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CONTAINER = os.environ.get("CONTAINER", "uprtest")


def sql(text):
    result = subprocess.run(
        ["docker", "exec", "-i", CONTAINER, "bash", "-lc",
         'exec /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa '
         '-P "$MSSQL_SA_PASSWORD" -C -b -W -h -1 -w 65535'],
        input="USE UPRXDB_TEST;\nGO\nSET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON; SET NOCOUNT ON;\n" + text,
        text=True, capture_output=True,
    )
    if result.returncode:
        raise AssertionError((result.stdout + result.stderr)[-6000:])
    return result.stdout.strip()


def load():
    sql((ROOT / "scripts/load_upr_master.sql").read_text())


sql("""
INSERT dbo.MAIncomingTableX1
    (MasterAddressID, Account, StreetNumber, StreetName, StreetType, City, ZipCode, LUCategory, Unit)
VALUES
    (9001, '01297731', '10', 'SYNTHETIC SF TEST', NULL, 'TEST CITY', '20850', 'Single Family Detached', NULL),
    (9002, '09999999', '20', 'SYNTHETIC REAL UNIT', 'ST', NULL, NULL, 'MultiFamily', 'SD-7352');
INSERT dbo.SDATIncomingTableX1
    (RealPropertyTaxInformationID, AccountNumber, PremisesNumber, PremisesStreetName,
     PremisesStreetType, PremisesCity, PremisesState, PremisesZipCode, Owner, CondoUnit)
VALUES (7352, '00089876', '30', 'SYNTHETIC CONDO TEST', NULL, NULL, NULL, NULL, NULL, NULL);
""")
load()
sql("""
IF NOT EXISTS (
    SELECT 1 FROM dbo.UNIT un
    INNER JOIN dbo.UPR_CLOSURE cl ON cl.DescendantUPRID = un.UPRID
    INNER JOIN dbo.UPR root ON root.UPRID = cl.AncestorUPRID
    WHERE root.AccountNumber = '00089876' AND un.UnitNumber IS NULL
) THROW 51001, 'Condo record with an AccountNumber but no CondoUnit value must still get a Unit row (NULL, not skipped).', 1;
IF NOT EXISTS (
    SELECT 1 FROM dbo.UNIT un
    INNER JOIN dbo.EXTERNAL_IDENTIFIER_XREF x ON x.UPRID = un.UPRID
    WHERE x.SourceSystem = 'ADDRESS_MASTER' AND x.IdentifierType = 'SOURCE_RECORD_ID'
      AND x.IdentifierValue = '9002' AND un.UnitNumber = 'SD-7352'
) THROW 51002, 'A genuine source UnitNumber resembling a placeholder was lost.', 1;
IF (SELECT COUNT(*) FROM dbo.UPR u
    INNER JOIN dbo.UPR_ADDRESS ua ON ua.UPRID = u.UPRID
    INNER JOIN dbo.ADDRESS a ON a.AddressID = ua.AddressID
    WHERE u.AccountNumber = '01297731' AND a.StreetName = 'SYNTHETIC SF TEST'
      AND a.StreetType IS NULL AND a.State IS NULL) <> 1
    THROW 51003, 'Single Family with blank street type lost its address or invented State.', 1;
IF EXISTS (SELECT 1 FROM dbo.UPR u
    WHERE NOT EXISTS (SELECT 1 FROM dbo.UPR_CONTACT uc WHERE uc.UPRID = u.UPRID)
       OR NOT EXISTS (SELECT 1 FROM dbo.UPR_ADDRESS ua WHERE ua.UPRID = u.UPRID))
    THROW 51004, 'An entity lacks a direct source Address or Contact link.', 1;
IF EXISTS (SELECT 1 FROM dbo.UPR u
    INNER JOIN dbo.UPR_CONTACT uc ON uc.UPRID = u.UPRID
    INNER JOIN dbo.CONTACT c ON c.ContactID = uc.ContactID
    WHERE u.AccountNumber IN ('01297731', '00089876', '09999999') AND c.OrganizationName IS NOT NULL)
    THROW 51005, 'Missing owner details were invented.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.UPR u
    INNER JOIN dbo.UPR_ADDRESS ua ON ua.UPRID = u.UPRID
    INNER JOIN dbo.ADDRESS a ON a.AddressID = ua.AddressID
    WHERE u.AccountNumber = '00089876' AND a.City IS NULL AND a.ZipCode IS NULL AND a.State IS NULL)
    THROW 51006, 'Partial source address was dropped or filled with guesses.', 1;
""")
print("PASS: source-only UnitNumbers/names, blank street type, partial addresses, direct links")

# Simulate the old loader's exact erroneous value, retaining an XREF proving its origin.
sql("""
DECLARE @Root BIGINT = (SELECT UPRID FROM dbo.UPR WHERE AccountNumber = '00089876');
DECLARE @B BIGINT = (SELECT b.BuildingID FROM dbo.BUILDING b
    INNER JOIN dbo.UPR u ON u.UPRID = b.UPRID WHERE u.ParentUPRID = @Root);
INSERT dbo.UPR (ParentUPRID, EntityTypeID)
SELECT @Root, EntityTypeID FROM dbo.REF_ENTITYTYPE WHERE Description = 'Unit';
DECLARE @LegacyUnit BIGINT = SCOPE_IDENTITY();
INSERT dbo.UNIT (UPRID, BuildingID, UnitNumber) VALUES (@LegacyUnit, @B, 'SD-7352');
UPDATE dbo.EXTERNAL_IDENTIFIER_XREF SET UPRID = @LegacyUnit
WHERE SourceSystem = 'KDAT' AND IdentifierType = 'SOURCE_RECORD_ID' AND IdentifierValue = '7352';
UPDATE c SET OrganizationName = '00089876'
FROM dbo.CONTACT c INNER JOIN dbo.UPR_CONTACT uc ON uc.ContactID = c.ContactID WHERE uc.UPRID = @Root;
DELETE ua FROM dbo.UPR_ADDRESS ua
INNER JOIN dbo.UPR b ON b.UPRID = ua.UPRID
INNER JOIN dbo.UPR root ON root.UPRID = b.ParentUPRID
WHERE root.AccountNumber = '01297731';
""")
load()
sql("""
IF NOT EXISTS (SELECT 1 FROM dbo.UNIT un
    INNER JOIN dbo.EXTERNAL_IDENTIFIER_XREF x ON x.UPRID = un.UPRID
    WHERE x.SourceSystem = 'KDAT' AND x.IdentifierType = 'SOURCE_RECORD_ID'
      AND x.IdentifierValue = '7352' AND un.UnitNumber IS NULL)
    THROW 51007, 'Legacy generated UnitNumber was not cleared in place.', 1;
IF (SELECT COUNT(*) FROM dbo.UPR b
    INNER JOIN dbo.UPR root ON root.UPRID = b.ParentUPRID
    INNER JOIN dbo.BUILDING entity ON entity.UPRID = b.UPRID
    INNER JOIN dbo.UPR_ADDRESS ua ON ua.UPRID = b.UPRID
    WHERE root.AccountNumber = '01297731') <> 1
    THROW 51008, 'Missing address repair duplicated or failed to repair the Building.', 1;
IF (SELECT COUNT(*) FROM dbo.ADDRESS WHERE StreetName = 'SYNTHETIC SF TEST') <> 1
    THROW 51009, 'Missing address link repair duplicated the Address.', 1;
IF EXISTS (SELECT 1 FROM dbo.CONTACT WHERE OrganizationName = '00089876')
    THROW 51010, 'Legacy account-as-owner fallback remains.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.AuditLog WHERE EntityName = 'UNIT' AND OperationType = 'UPDATE'
    AND JSON_VALUE(OldValues, '$.UnitNumber') = 'SD-7352'
    AND JSON_VALUE(NewValues, '$.UnitNumber') IS NULL)
    THROW 51011, 'Legacy repair has no before/after audit.', 1;
""")
print("PASS: source-proven legacy repair preserves IDs; missing Address link repaired without duplicates")

baseline = int(sql("SELECT MAX(AuditID) FROM dbo.AuditLog;").splitlines()[-1])
load()
sql(f"IF EXISTS (SELECT 1 FROM dbo.AuditLog WHERE AuditID > {baseline} "
    "AND EntityName <> 'UPR_HIER_LOAD') THROW 51012, 'Unchanged rerun mutated business rows.', 1;")
print("PASS: unchanged rerun produces only the batch summary, no business changes")

sql("""
DECLARE @Before INT = (SELECT MAX(AuditID) FROM dbo.AuditLog);
BEGIN TRANSACTION;
INSERT dbo.REF_ENTITYTYPE (Description) VALUES ('AUDIT TEST A'), ('AUDIT TEST B');
UPDATE dbo.REF_ENTITYTYPE SET Description = Description + ' UPDATED' WHERE Description LIKE 'AUDIT TEST%';
DELETE dbo.REF_ENTITYTYPE WHERE Description LIKE 'AUDIT TEST%';
IF (SELECT COUNT(*) FROM dbo.AuditLog WHERE AuditID > @Before AND EntityName = 'REF_ENTITYTYPE'
    AND OperationType = 'INSERT' AND OldValues IS NULL AND ISJSON(NewValues) = 1) <> 2
    THROW 51013, 'Multirow INSERT audit failed.', 1;
IF (SELECT COUNT(*) FROM dbo.AuditLog WHERE AuditID > @Before AND EntityName = 'REF_ENTITYTYPE'
    AND OperationType = 'UPDATE' AND ISJSON(OldValues) = 1 AND ISJSON(NewValues) = 1) <> 2
    THROW 51014, 'Multirow UPDATE audit failed.', 1;
IF (SELECT COUNT(*) FROM dbo.AuditLog WHERE AuditID > @Before AND EntityName = 'REF_ENTITYTYPE'
    AND OperationType = 'DELETE' AND ISJSON(OldValues) = 1 AND NewValues IS NULL) <> 2
    THROW 51015, 'Multirow DELETE audit failed.', 1;
ROLLBACK TRANSACTION;
IF EXISTS (SELECT 1 FROM dbo.AuditLog WHERE AuditID > @Before)
    THROW 51016, 'Rolled-back changes left misleading committed audit records.', 1;
IF (SELECT COUNT(*) FROM sys.triggers WHERE name LIKE 'tr_UPR_Audit[_]%' AND is_disabled = 0) <> 22
    THROW 51017, 'Not all 22 model/reference tables are audited.', 1;
BEGIN TRANSACTION;
INSERT dbo.REF_ENTITYTYPE (Description) VALUES ('AUDIT MERGE A'), ('AUDIT MERGE B');
SET @Before = (SELECT MAX(AuditID) FROM dbo.AuditLog);
MERGE dbo.REF_ENTITYTYPE AS t
USING (VALUES ('AUDIT MERGE A'), ('AUDIT MERGE C')) AS s(Description)
ON t.Description = s.Description
WHEN MATCHED THEN UPDATE SET Description = s.Description + ' UPDATED'
WHEN NOT MATCHED THEN INSERT (Description) VALUES (s.Description)
WHEN NOT MATCHED BY SOURCE AND t.Description = 'AUDIT MERGE B' THEN DELETE;
IF (SELECT COUNT(DISTINCT OperationType) FROM dbo.AuditLog WHERE AuditID > @Before) <> 3
    THROW 51018, 'Mixed-action MERGE audit failed.', 1;
ROLLBACK TRANSACTION;
""")
print("PASS: external multirow INSERT/UPDATE/DELETE, MERGE, rollback and 22-table audit coverage")

# Both key columns must be retained in every closure event, including same-ancestor rows.
sql("""
IF EXISTS (SELECT 1 FROM dbo.AuditLog WHERE EntityName = 'UPR_CLOSURE'
    AND (JSON_VALUE(EntityKey, '$.AncestorUPRID') IS NULL
      OR JSON_VALUE(EntityKey, '$.DescendantUPRID') IS NULL))
    THROW 51019, 'Composite audit key is incomplete.', 1;
""")
print("PASS: composite closure audit keys retain both ancestor and descendant IDs")

unit_count = int(sql("SELECT COUNT(*) FROM dbo.UNIT;").splitlines()[-1])
sql("""
INSERT dbo.MAIncomingTableX1
    (MasterAddressID, Account, StreetNumber, StreetName, StreetType, City, ZipCode, LUCategory, Unit)
SELECT 9003, Account, StreetNumber, StreetName, StreetType, City, ZipCode, LUCategory, Unit
FROM dbo.MAIncomingTableX1 WHERE MasterAddressID = 9002;
""")
load()
sql(f"IF (SELECT COUNT(*) FROM dbo.UNIT) <> {unit_count} "
    "THROW 51020, 'New source alias duplicated an existing numbered Unit.', 1;")
sql("""
IF (SELECT COUNT(*) FROM dbo.EXTERNAL_IDENTIFIER_XREF
    WHERE SourceSystem = 'ADDRESS_MASTER' AND IdentifierType = 'SOURCE_RECORD_ID'
      AND IdentifierValue IN ('9002', '9003')) <> 2
    THROW 51021, 'New source alias is not linked.', 1;
IF (SELECT COUNT(DISTINCT UPRID) FROM dbo.EXTERNAL_IDENTIFIER_XREF
    WHERE SourceSystem = 'ADDRESS_MASTER' AND IdentifierType = 'SOURCE_RECORD_ID'
      AND IdentifierValue IN ('9002', '9003')) <> 1
    THROW 51022, 'Source aliases did not resolve to the same Unit.', 1;
""")
print("PASS: additional source rows reuse the existing numbered Unit and preserve source XREFs")
