#!/usr/bin/env python3
"""Synthetic MA/SDAT overlaps; actual visible client rows are tested separately."""
import os
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
CONTAINER = os.environ.get("CONTAINER", "uprtest")
DATABASE = "UPR_MA_IT_" + uuid.uuid4().hex
LOADER = Path(os.environ.get("UPR_CLASSIFICATION_LOADER", ROOT / "scripts/load_upr_master.sql"))


def sql(text):
    result = subprocess.run(
        ["docker", "exec", "-i", CONTAINER, "bash", "-lc",
         'exec /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa '
         '-P "$MSSQL_SA_PASSWORD" -C -b -W -s "|" -h -1 -w 65535'],
        input=f"USE [{DATABASE}];\nGO\nSET QUOTED_IDENTIFIER ON; SET NOCOUNT ON;\n" + text,
        text=True, capture_output=True,
    )
    if result.returncode:
        raise AssertionError((result.stdout + result.stderr)[-6000:])
    return "\n".join(line for line in result.stdout.splitlines()
                     if line.strip() and not line.startswith("Changed database context to "))


def script(path):
    return Path(path).read_text().replace("USE UPRXDB_TEST;", f"USE [{DATABASE}];")


def load():
    return sql(script(LOADER))


def roots(account):
    return sql(f"SELECT e.Description FROM dbo.UPR u JOIN dbo.REF_ENTITYTYPE e ON e.EntityTypeID = u.EntityTypeID "
               f"WHERE u.AccountNumber = '{account}' AND u.ParentUPRID IS NULL ORDER BY e.Description;").splitlines()


subprocess.run(
    ["docker", "exec", CONTAINER, "bash", "-lc",
     'exec /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa '
     f'-P "$MSSQL_SA_PASSWORD" -C -b -Q "CREATE DATABASE [{DATABASE}];"'],
    check=True, capture_output=True, text=True,
)
try:
    sql(script(ROOT / "test/local_it_setup.sql"))
    sql(script(ROOT / "ddl/03_new_upr_schema.sql"))
    sql(script(ROOT / "scripts/install_upr_audit.sql"))
    sql("""
INSERT dbo.MAIncomingTableX1
    (MasterAddressID, Account, StreetNumber, StreetName, StreetType, City, ZipCode, LUCategory, ParcelNumber)
VALUES
 (9101,'00255115','100','SYNTHETIC OVERLAP','ST','TEST CITY','20850','Multifamily','P9101'),
 (9102,'00255115','102','SYNTHETIC OVERLAP','ST','TEST CITY','20850','Multi Family','P9101'),
 (9103,'00255115','104','SYNTHETIC OVERLAP','ST','TEST CITY','20850',NULL,'P9101'),
 (9111,'00255116','110','SYNTHETIC APT','ST','TEST CITY','20850','Apartments','P9111'),
 (9112,'00255116','112','SYNTHETIC APT','ST','TEST CITY','20850','Apartment','P9111'),
 (9121,'00255117','120','SYNTHETIC SINGLE MULTI','ST','TEST CITY','20850','Multifamily','P9121'),
 (9131,'00255118','130','SYNTHETIC OFFICE','ST','TEST CITY','20850','Office','P9131'),
 (9141,'00255119','140','SYNTHETIC TWO OFFICES','ST','TEST CITY','20850','Office','P9141'),
 (9142,'00255119','142','SYNTHETIC TWO OFFICES','ST','TEST CITY','20850','Office','P9141'),
 (9151,'00255120','0','SYNTHETIC INVALID MA','ST','TEST CITY','20850','Multifamily','P9151'),
 (9161,'00255121','160','SYNTHETIC POSTAL VARIANT','ST','TEST CITY','20850','Multifamily','P9161'),
 (9162,'00255121','160','SYNTHETIC POSTAL VARIANT','ST','TEST CITY','20851','Multifamily','P9161'),
 (9181,'00255124','180','SYNTHETIC BASIC MULTI','ST','TEST CITY','20850','Multifamily','P9181'),
 (9182,'00255124','182','SYNTHETIC BASIC MULTI','ST','TEST CITY','20850','Multifamily','P9181');
IF COL_LENGTH(N'dbo.SDATIncomingTableX1', N'CondoUnit') IS NULL
    ALTER TABLE dbo.SDATIncomingTableX1 ADD CondoUnit NVARCHAR(50) NULL;
GO
INSERT dbo.SDATIncomingTableX1
 (RealPropertyTaxInformationID, AccountNumber, PremisesNumber, PremisesStreetName, PremisesStreetType,
  PremisesCity, PremisesZipCode, Parcel, Owner, CondoUnit)
VALUES
 (9201,'255115','100','SYNTHETIC OVERLAP','ST','TEST CITY','20850','P9101','SYNTHETIC OWNER',NULL),
 (9211,'00255116','110','SYNTHETIC APT','ST','TEST CITY','20850','P9111','SYNTHETIC OWNER','A'),
 (9221,'00255117','120','SYNTHETIC SINGLE MULTI','ST','TEST CITY','20850','P9121','SYNTHETIC OWNER','B'),
 (9231,'00255118','130','SYNTHETIC OFFICE','ST','TEST CITY','20850','P9131','SYNTHETIC OWNER',NULL),
 (9241,'00255119','142','SYNTHETIC TWO OFFICES','ST','TEST CITY','20850','P9141','SYNTHETIC OWNER',NULL),
 (9242,'00255119','144','SYNTHETIC UNMATCHED OFFICE','ST','TEST CITY','20850','P9141','SYNTHETIC OWNER',NULL),
 (9251,'00255120','150','SYNTHETIC INVALID MA','ST','TEST CITY','20850','P9151','SYNTHETIC OWNER',NULL),
 (9261,'00255121','160','SYNTHETIC POSTAL VARIANT','ST','TEST CITY',NULL,'P9161','SYNTHETIC OWNER',NULL),
 (9271,'00255122','170','SYNTHETIC RECLASSIFY','ST','TEST CITY','20850','P9171','SYNTHETIC OWNER',NULL),
 (9281,'00255124','180','SYNTHETIC BASIC MULTI','ST','TEST CITY','20850','P9181','SYNTHETIC OWNER','C'),
 (9291,'00255125','190','SYNTHETIC NAMED CONDO','ST','TEST CITY','20850','P9191','SYNTHETIC OWNER',NULL);
""")
    load()
    assert roots('00255124') == ['Complex'], "Basic reported shape should already be a Complex"
    old_root = sql("SELECT UPRID FROM dbo.UPR WHERE AccountNumber = '00255122';")
    old_unit = sql("SELECT UPRID FROM dbo.EXTERNAL_IDENTIFIER_XREF WHERE SourceSystem = 'KDAT' "
                   "AND IdentifierType = 'SOURCE_RECORD_ID' AND IdentifierValue = '9271';")
    sql("""
UPDATE d SET CondoName = 'MANUALLY MAINTAINED CONDO'
FROM dbo.CONDO d JOIN dbo.UPR u ON u.UPRID = d.UPRID WHERE u.AccountNumber = '00255125';
INSERT dbo.MAIncomingTableX1
 (MasterAddressID, Account, StreetNumber, StreetName, StreetType, City, ZipCode, LUCategory, ParcelNumber)
VALUES
 (9171,'00255122','170','SYNTHETIC RECLASSIFY','ST','TEST CITY','20850','Multifamily','P9171'),
 (9172,'00255122','172','SYNTHETIC RECLASSIFY','ST','TEST CITY','20850','Multifamily','P9171'),
 (9191,'00255125','190','SYNTHETIC NAMED CONDO','ST','TEST CITY','20850','Multifamily','P9191'),
 (9192,'00255125','192','SYNTHETIC NAMED CONDO','ST','TEST CITY','20850','Multifamily','P9191');
""")
    output = load()
    if os.environ.get("BASELINE_ONLY"):
        for account in ('00255124', '00255115', '00255117', '00255118', '00255122'):
            print(f"BASELINE {account}: {roots(account)}", flush=True)
    else:
        assert roots('00255115') == ['Complex'], roots('00255115')
        assert roots('00255116') == ['Complex'], roots('00255116')
        assert roots('00255117') == ['Property'], roots('00255117')
        assert roots('00255118') == ['Property'], roots('00255118')
        assert roots('00255119') == ['Property', 'Property'], roots('00255119')
        assert roots('00255120') == [], roots('00255120')
        assert 'Complex' not in roots('00255121'), roots('00255121')
        assert roots('00255122') == ['Complex'], roots('00255122')
        assert roots('00255125') == ['Condo'], "Unreviewed existing data must not get another competing tree"
        assert "MA multifamily/apartment account" in output and "review required" in output
        assert "|KDAT|9201|00255115|NULL|MULTI|" in output, "SDAT staging did not inherit MA's account type"
        sql(f"""
IF (SELECT COUNT(*) FROM dbo.BUILDING b JOIN dbo.UPR u ON u.UPRID = b.UPRID
    JOIN dbo.UPR root ON root.UPRID = u.ParentUPRID WHERE root.AccountNumber = '00255115') <> 3
    THROW 51112, 'Complex lost or duplicated an MA building address.', 1;
IF (SELECT COUNT(*) FROM dbo.UNIT un JOIN dbo.UPR_CLOSURE cl ON cl.DescendantUPRID = un.UPRID
    JOIN dbo.UPR root ON root.UPRID = cl.AncestorUPRID WHERE root.AccountNumber = '00255115') <> 4
    THROW 51113, 'Complex lost or duplicated source Unit rows.', 1;
IF (SELECT COUNT(*) FROM dbo.EXTERNAL_IDENTIFIER_XREF x
    JOIN dbo.UPR_CLOSURE cl ON cl.DescendantUPRID = x.UPRID
    JOIN dbo.UPR root ON root.UPRID = cl.AncestorUPRID
    WHERE root.AccountNumber = '00255115' AND x.IdentifierType = 'SOURCE_RECORD_ID') <> 4
    THROW 51114, 'MA and SDAT source records did not all resolve into the Complex.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.UPR WHERE AccountNumber = '00255122' AND UPRID = {old_root})
    THROW 51101, 'Existing Condo root ID was replaced rather than reclassified.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.EXTERNAL_IDENTIFIER_XREF WHERE SourceSystem = 'KDAT'
    AND IdentifierType = 'SOURCE_RECORD_ID' AND IdentifierValue = '9271' AND UPRID = {old_unit})
    THROW 51102, 'Reclassification changed the source Unit ID.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.UNIT un JOIN dbo.BUILDING b ON b.BuildingID = un.BuildingID
    JOIN dbo.UPR bu ON bu.UPRID = b.UPRID JOIN dbo.UPR u ON u.UPRID = un.UPRID
    WHERE un.UPRID = {old_unit} AND u.ParentUPRID = b.UPRID AND bu.ParentUPRID = {old_root})
    THROW 51103, 'Existing Unit was not moved under its Building.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.AuditLog WHERE EntityName = 'CONDO' AND OperationType = 'DELETE'
    AND JSON_VALUE(OldValues, '$.UPRID') = '{old_root}')
    THROW 51104, 'Old Condo subtype was removed without a full audit record.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.UPR u JOIN dbo.COMPLEX c ON c.UPRID = u.UPRID
    JOIN dbo.REF_PROPERTYTYPE pt ON pt.PropertyTypeID = c.PropertyTypeID
    WHERE u.AccountNumber = '00255116' AND pt.PropertyTypeCode = 'APT')
    THROW 51105, 'SDAT Condo classification replaced MA Apartment type.', 1;
IF EXISTS (SELECT 1 FROM dbo.UPR root JOIN dbo.UPR_CLOSURE cl ON cl.AncestorUPRID = root.UPRID
    JOIN dbo.UNIT un ON un.UPRID = cl.DescendantUPRID WHERE root.AccountNumber = '00255118')
    THROW 51106, 'Blank SDAT CondoUnit manufactured a Unit for an MA office.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.UPRMATCHREVIEW_Q WHERE SDAT_AccountNumber = '00255119'
    AND ReasonForNoMatch = 'NO_ADDRESS_MATCH')
    THROW 51107, 'Unmatched shared SDAT address was not sent for review.', 1;
IF EXISTS (SELECT 1 FROM dbo.EXTERNAL_IDENTIFIER_XREF WHERE SourceSystem = 'KDAT'
    AND IdentifierType = 'SOURCE_RECORD_ID' AND IdentifierValue IN ('9242', '9251', '9261'))
    THROW 51108, 'Rejected SDAT rows leaked into UPR links.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.UPRMATCHREVIEW_Q WHERE SDAT_AccountNumber = '00255121'
    AND ReasonForNoMatch = 'AMBIGUOUS_CANDIDATES')
    THROW 51115, 'Equally plausible MA address groups were resolved arbitrarily.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.UPR_CLOSURE WHERE AncestorUPRID = {old_root}
    AND DescendantUPRID = {old_unit} AND [Level] = 2)
    THROW 51109, 'Reclassified Unit closure/Level is incorrect.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.UPRMATCHREVIEW_Q WHERE SDAT_AccountNumber = '00255125'
    AND UPRID IS NOT NULL AND ReasonForNoMatch = 'AMBIGUOUS_CANDIDATES'
    AND Decision LIKE 'MA requires Complex; existing parents%')
    THROW 51111, 'Existing named Condo conflict was not queued for review.', 1;
""")
        print("PASS: mixed MA rows stay in one Complex; MA Apartment, MultiFamily and Office types win", flush=True)
        print("PASS: ambiguous/unmatched overlaps go to review; postal variations do not invent a Complex", flush=True)
        print("PASS: source-proven Condo reclassified with root/Unit IDs, XREFs, audit and Level preserved", flush=True)
        print("PASS: ambiguous existing parent is queued without creating another tree", flush=True)
        before = sql("SELECT MAX(AuditID) FROM dbo.AuditLog;")
        load()
        sql(f"IF EXISTS (SELECT 1 FROM dbo.AuditLog WHERE AuditID > {before} AND EntityName <> 'UPR_HIER_LOAD') "
            "THROW 51110, 'Unchanged rerun mutated business data after MA precedence repair.', 1;")
        print("PASS: unchanged rerun produces no additional business events", flush=True)
finally:
    sql(f"USE master; ALTER DATABASE [{DATABASE}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; "
        f"DROP DATABASE [{DATABASE}];")
