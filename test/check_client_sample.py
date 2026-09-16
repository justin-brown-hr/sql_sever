#!/usr/bin/env python3
"""Verify the actual client-supplied row in a disposable SQL Server database.

CONTAINER defaults to uprtest. Optional BASELINE_LOADER points to an earlier
loader SQL file: run it first, report its links, then test upgrading in place.
"""
import os
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
DATABASE = "UPR_Client20977_" + uuid.uuid4().hex
CONTAINER = os.environ.get("CONTAINER", "uprtest")


def sql(text):
    result = subprocess.run(
        ["docker", "exec", "-i", CONTAINER, "bash", "-lc",
         'exec /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa '
         '-P "$MSSQL_SA_PASSWORD" -C -b -W -h -1 -w 65535'],
        input=text.replace("UPRXDB_TEST", DATABASE), text=True, capture_output=True,
    )
    if result.returncode:
        raise AssertionError((result.stdout + result.stderr)[-6000:])
    return result.stdout.strip()


def query(text):
    return sql("USE UPRXDB_TEST; SET NOCOUNT ON; SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;\n" + text).splitlines()[-1]


sql(f"CREATE DATABASE [{DATABASE}];")
try:
    # Use the existing integration source schemas, without synthetic data.
    setup = (ROOT / "test/local_it_setup.sql").read_text()
    sql(setup.split("/* ---------------------------------------------------------------- MA rows -- */")[0])
    sql((ROOT / "ddl/03_new_upr_schema.sql").read_text())
    sql((ROOT / "scripts/install_upr_audit.sql").read_text())
    sql((ROOT / "test/client_20977.sql").read_text())
    original_source = query("SELECT * FROM dbo.MAIncomingTableX1 FOR JSON PATH, INCLUDE_NULL_VALUES;")

    counts = """
SELECT
    Properties = (SELECT COUNT(*) FROM dbo.PROPERTY),
    Buildings = (SELECT COUNT(*) FROM dbo.BUILDING),
    Addresses = (SELECT COUNT(*) FROM dbo.ADDRESS),
    Units = (SELECT COUNT(*) FROM dbo.UNIT),
    Contacts = (SELECT COUNT(*) FROM dbo.CONTACT),
    ParentAddressLinks = (SELECT COUNT(*) FROM dbo.UPR_ADDRESS ua
        INNER JOIN dbo.UPR u ON u.UPRID = ua.UPRID WHERE u.ParentUPRID IS NULL),
    BuildingContactLinks = (SELECT COUNT(*) FROM dbo.UPR_CONTACT uc
        INNER JOIN dbo.BUILDING b ON b.UPRID = uc.UPRID)
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
"""
    identity_query = "SELECT UPRID, ParentUPRID FROM dbo.UPR ORDER BY UPRID FOR JSON PATH;"
    previous_ids = None
    baseline = os.environ.get("BASELINE_LOADER")
    if baseline:
        sql(Path(baseline).read_text())
        previous_ids = query(identity_query)
        print("PRIOR REPOSITORY LOADER:", query(counts))

    current = (ROOT / "scripts/load_upr_master.sql").read_text()
    sql(current)
    sql("""
USE UPRXDB_TEST;
SET NOCOUNT ON;
IF (SELECT COUNT(*) FROM dbo.UPR) <> 2 OR (SELECT COUNT(*) FROM dbo.PROPERTY) <> 1
   OR (SELECT COUNT(*) FROM dbo.BUILDING) <> 1 OR (SELECT COUNT(*) FROM dbo.ADDRESS) <> 1
   OR (SELECT COUNT(*) FROM dbo.CONTACT) <> 1 OR EXISTS (SELECT 1 FROM dbo.UNIT)
    THROW 51001, 'Client sample has missing or invented entities.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.UPR u
    INNER JOIN dbo.PROPERTY p ON p.UPRID = u.UPRID
    INNER JOIN dbo.REF_PROPERTYTYPE pt ON pt.PropertyTypeID = p.PropertyTypeID
    WHERE u.AccountNumber = '01297731' AND u.ParentUPRID IS NULL
      AND pt.PropertyTypeCode = 'SF' AND p.Parcel IS NULL AND p.OwnerName IS NULL)
    THROW 51002, 'Client account, property type, parcel or owner changed.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.ADDRESS
    WHERE StreetNumber = '13414' AND StreetName = 'DOWLAIS' AND StreetType = 'DR'
      AND City = 'ROCKVILLE' AND ZipCode = '20853' AND State IS NULL
      AND XCoordinate = 1283026 AND YCoordinate = 513743)
    THROW 51003, 'Client source address/coordinates were lost or State invented.', 1;
IF EXISTS (SELECT 1 FROM dbo.UPR u
    WHERE NOT EXISTS (SELECT 1 FROM dbo.UPR_ADDRESS ua WHERE ua.UPRID = u.UPRID AND ua.IsPrimary = 1)
       OR NOT EXISTS (SELECT 1 FROM dbo.UPR_CONTACT uc WHERE uc.UPRID = u.UPRID))
    THROW 51004, 'Parent or Building lacks a direct Address/Contact link.', 1;
IF EXISTS (SELECT 1 FROM dbo.CONTACT WHERE OrganizationName IS NOT NULL)
    THROW 51005, 'Contact name was invented for the supplied MA-only row.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.EXTERNAL_IDENTIFIER_XREF
    WHERE SourceSystem = 'ADDRESS_MASTER' AND IdentifierType = 'SOURCE_RECORD_ID'
      AND IdentifierValue = '20977')
    THROW 51006, 'Client source record provenance missing.', 1;
IF EXISTS (SELECT 1 FROM dbo.UPRMATCHREVIEW_Q
    WHERE MA_Account = '01297731' AND ReasonForNoMatch = 'MISSING PARCELID')
    THROW 51007, 'Missing parcel incorrectly caused a review entry.', 1;
IF (SELECT COUNT(DISTINCT EntityName) FROM dbo.AuditLog
    WHERE EntityName IN ('UPR', 'PROPERTY', 'BUILDING', 'ADDRESS', 'CONTACT', 'UPR_ADDRESS', 'UPR_CONTACT')) <> 7
    THROW 51008, 'Client sample writes lack individual audit events.', 1;
""")
    if previous_ids is not None:
        assert query(identity_query) == previous_ids, "Upgrade replaced existing UPR IDs"
    print("UPDATED LOADER:", query(counts))
    ids = query(identity_query)
    before = int(query("SELECT MAX(AuditID) FROM dbo.AuditLog;"))
    sql(current)
    assert query(identity_query) == ids
    query(f"IF EXISTS (SELECT 1 FROM dbo.AuditLog WHERE AuditID > {before} "
          "AND EntityName <> 'UPR_HIER_LOAD') THROW 51009, 'Rerun changed business data.', 1; SELECT 'PASS';")
    assert query("SELECT * FROM dbo.MAIncomingTableX1 FOR JSON PATH, INCLUDE_NULL_VALUES;") == original_source
    print("PASS: client row 20977 loads with exact address/coordinates, required links, no Unit or invented names")
    print("PASS: missing parcel accepted without review; source row unchanged; rerun preserves records")

    # Partially populated client databases may have links that are not primary.
    query("UPDATE dbo.UPR_ADDRESS SET IsPrimary = 0; SELECT 'PREPARED';")
    sql(current)
    assert query(identity_query) == ids, "Non-primary address link created a duplicate Building"
    query("IF (SELECT COUNT(*) FROM dbo.UPR_ADDRESS WHERE IsPrimary = 1) <> 2 "
          "THROW 51010, 'Existing source address links were not made primary.', 1; SELECT 'PASS';")
    print("PASS: existing non-primary Address links repaired without duplicating Buildings")

    # An orphan address with different coordinates must not override the source.
    query("DELETE FROM dbo.UPR_ADDRESS; UPDATE dbo.ADDRESS SET XCoordinate = 1, YCoordinate = 2; SELECT 'PREPARED';")
    sql(current)
    query("IF EXISTS (SELECT 1 FROM dbo.UPR_ADDRESS ua INNER JOIN dbo.ADDRESS a ON a.AddressID = ua.AddressID "
          "WHERE a.XCoordinate <> 1283026 OR a.YCoordinate <> 513743 "
          "OR a.XCoordinate IS NULL OR a.YCoordinate IS NULL) "
          "THROW 51011, 'Reused an Address with coordinates different from the source.', 1; SELECT 'PASS';")
    assert query(identity_query) == ids
    print("PASS: Address reuse preserves the incoming coordinates")
finally:
    sql(f"USE master; ALTER DATABASE [{DATABASE}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; "
        f"DROP DATABASE [{DATABASE}];")
