/*
================================================================================
  LOCAL INTEGRATION SETUP - incoming tables + hostile test data

  Creates UPRXDB_TEST and the two incoming tables using the WORST-CASE column
  types found in the client schema (SDAT columns are NVARCHAR(MAX)), then seeds
  rows designed to break the load:

    - Complex: MULTI account with 3 distinct building addresses
    - MULTI with a single address (Property -> Building -> Unit)
    - SDAT condos with and without CondoUnit
    - Warehouse / Office / Vacant / Park (building, no unit)
    - Institutional/Community Facilities (long record type -> short code)
    - blank LUCategory (must not become SF)
    - same account on several NON-multifamily addresses (XREF uniqueness)
    - same account present in both MA and SDAT (must merge, not duplicate)
    - YearBuilt 0 and 9999 (CHECK constraint)
    - 300-character street name (truncation)
    - bad street number / missing zip (Review_Q, not loaded)
    - NULL parcel (loaded AND flagged)
    - garbage PremisesState (must fall back to MD)
================================================================================
*/
IF DB_ID(N'UPRXDB_TEST') IS NULL
BEGIN
    CREATE DATABASE UPRXDB_TEST;
END;
GO

USE UPRXDB_TEST;
GO

IF OBJECT_ID(N'dbo.MAIncomingTableX1', N'U') IS NOT NULL DROP TABLE dbo.MAIncomingTableX1;
IF OBJECT_ID(N'dbo.SDATIncomingTableX1', N'U') IS NOT NULL DROP TABLE dbo.SDATIncomingTableX1;
GO

CREATE TABLE dbo.MAIncomingTableX1
(
    MasterAddressID INT           NOT NULL PRIMARY KEY,
    Account         NCHAR(8)      NULL,
    ParcelNumber    NVARCHAR(50)  NULL,
    StreetNumber    NVARCHAR(20)  NULL,
    StreetName      NVARCHAR(100) NULL,
    StreetType      NVARCHAR(20)  NULL,
    Unit            NVARCHAR(20)  NULL,
    City            NVARCHAR(50)  NULL,
    ZipCode         NVARCHAR(10)  NULL,
    LUCategory      NVARCHAR(50)  NULL,
    XCoordinate     INT           NULL,
    YCoordinate     INT           NULL
);

/* Client schema: every SDAT text column is NVARCHAR(MAX) */
CREATE TABLE dbo.SDATIncomingTableX1
(
    RealPropertyTaxInformationID INT           NOT NULL PRIMARY KEY,
    AccountNumber        NVARCHAR(MAX) NULL,
    Parcel               NVARCHAR(MAX) NULL,
    Owner                NVARCHAR(MAX) NULL,
    YearBuilt            INT           NULL,
    DwellingUnits        INT           NULL,
    PremisesNumber       NVARCHAR(MAX) NULL,
    PremisesStreetName   NVARCHAR(MAX) NULL,
    PremisesStreetType   NVARCHAR(MAX) NULL,
    PremisesCity         NVARCHAR(MAX) NULL,
    PremisesState        NVARCHAR(MAX) NULL,
    PremisesZipCode      NVARCHAR(MAX) NULL
    /* CondoUnit deliberately absent - the load must add it */
);
GO

SET NOCOUNT ON;

/* ---------------------------------------------------------------- MA rows -- */
INSERT INTO dbo.MAIncomingTableX1
    (MasterAddressID, Account, ParcelNumber, StreetNumber, StreetName, StreetType,
     Unit, City, ZipCode, LUCategory, XCoordinate, YCoordinate)
VALUES
    /* 1. COMPLEX: one MULTI account, 3 distinct building addresses, units */
    (1, N'00272531', N'P1', N'100', N'GLENMONT', N'AVENUE', N'101', N'SILVER SPRING', N'20902', N'Multi-Family', 1, 2),
    (2, N'00272531', N'P1', N'100', N'GLENMONT', N'AVENUE', N'102', N'SILVER SPRING', N'20902', N'Multi-Family', 1, 2),
    (3, N'00272531', N'P1', N'102', N'GLENMONT', N'AVENUE', N'201', N'SILVER SPRING', N'20902', N'Multi-Family', 1, 2),
    (4, N'00272531', N'P1', N'104', N'GLENMONT', N'AVENUE', NULL,   N'SILVER SPRING', N'20902', N'Multi-Family', 1, 2),

    /* 2. MULTI, single address -> Property > Building > Unit (no Complex) */
    (10, N'00100001', N'P10', N'55', N'ELM', N'ST', NULL, N'ROCKVILLE', N'20850', N'Multi-Family', NULL, NULL),

    /* 3. Non-unit record types - building only */
    (20, N'00000011', N'P20', N'900', N'INDUSTRIAL', N'BLVD', NULL, N'GAITHERSBURG', N'20877', N'WAREHOUSE', NULL, NULL),
    (21, N'00000022', N'P21', N'901', N'INDUSTRIAL', N'BLVD', NULL, N'GAITHERSBURG', N'20877', N'Warehouse', NULL, NULL),
    (22, N'00000033', N'P22', N'10',  N'OFFICE',     N'PARK', NULL, N'BETHESDA',     N'20814', N'Office', NULL, NULL),
    (23, N'00000044', N'P23', N'11',  N'GREEN',      N'WAY',  NULL, N'OLNEY',        N'20832', N'Vacant', NULL, NULL),
    (24, N'00000055', N'P24', N'12',  N'CENTRAL',    N'PARK', NULL, N'ROCKVILLE',    N'20850', N'Park', NULL, NULL),
    (25, N'00000066', N'P25', N'13',  N'CIVIC',      N'CT',   NULL, N'ROCKVILLE',    N'20850', N'Institutional/Community Facilities', NULL, NULL),

    /* 4. Blank record type - must NOT become SF */
    (30, N'00000077', N'P30', N'14', N'UNKNOWN', N'RD', NULL, N'DAMASCUS', N'20872', NULL, NULL, NULL),
    (31, N'00000088', N'P31', N'15', N'BLANKTYPE', N'RD', NULL, N'DAMASCUS', N'20872', N'   ', NULL, NULL),

    /* 5. Same account, 3 addresses, NOT multifamily -> 3 Property parents,
          one account number (breaks a naive unique XREF) */
    (40, N'00000099', N'P40', N'20', N'SPLIT', N'ST', NULL, N'ROCKVILLE', N'20850', N'Single Family Detached', NULL, NULL),
    (41, N'00000099', N'P40', N'22', N'SPLIT', N'ST', NULL, N'ROCKVILLE', N'20850', N'Single Family Detached', NULL, NULL),
    (42, N'00000099', N'P40', N'24', N'SPLIT', N'ST', NULL, N'ROCKVILLE', N'20850', N'Single Family Detached', NULL, NULL),

    /* 6. Matches an SDAT row on account + address (must merge, not duplicate) */
    (50, N'00031023', N'P50', N'700', N'CONDO', N'DRIVE', NULL, N'BETHESDA', N'20814', N'Condominium', NULL, NULL),

    /* 7. Townhouse with a unit value from MA */
    (60, N'00000121', N'P60', N'31', N'ROW', N'LN', N'B', N'KENSINGTON', N'20895', N'Townhouse', NULL, NULL),

    /* 8. Rejects: street number 0, missing zip, no city */
    (70, N'00000131', N'P70', N'0',  N'BADNUM', N'ST', NULL, N'ROCKVILLE', N'20850', N'Single Family Detached', NULL, NULL),
    (71, N'00000141', N'P71', N'32', N'NOZIP',  N'ST', NULL, N'ROCKVILLE', NULL,     N'Single Family Detached', NULL, NULL),
    (72, N'00000151', N'P72', N'33', N'NOCITY', N'ST', NULL, NULL,         N'20850', N'Single Family Detached', NULL, NULL),

    /* 9. Loaded but flagged: parcel NULL and placeholder '000' */
    (80, N'00000161', NULL,    N'34', N'NOPARCEL', N'ST', NULL, N'ROCKVILLE', N'20850', N'Single Family Detached', NULL, NULL),
    (81, N'00000171', N'000',  N'35', N'ZEROPARCEL', N'ST', NULL, N'ROCKVILLE', N'20850', N'Single Family Detached', NULL, NULL),

    /* 10. No account and no condo unit -> INSUFFICIENT_DATA */
    (90, NULL, N'P90', N'36', N'NOACCOUNT', N'ST', NULL, N'ROCKVILLE', N'20850', N'Single Family Detached', NULL, NULL),

    /* 11. Apartment complex spelling + 2 addresses */
    (100, N'00000181', N'P100', N'400', N'TOWER', N'RD', N'1A', N'WHEATON', N'20902', N'Apartments', NULL, NULL),
    (101, N'00000181', N'P100', N'402', N'TOWER', N'RD', N'2A', N'WHEATON', N'20902', N'Apartments', NULL, NULL);

/* -------------------------------------------------------------- SDAT rows -- */
INSERT INTO dbo.SDATIncomingTableX1
    (RealPropertyTaxInformationID, AccountNumber, Parcel, Owner, YearBuilt, DwellingUnits,
     PremisesNumber, PremisesStreetName, PremisesStreetType, PremisesCity, PremisesState, PremisesZipCode)
VALUES
    /* Condo account with two condo units (CondoUnit set after the ALTER below) */
    (1001, N'31023', N'P50', N'BETHESDA CONDO LLC', 1998, 24, N'700', N'CONDO', N'DRIVE', N'BETHESDA', N'MD', N'20814'),
    (1002, N'31023', N'P50', N'BETHESDA CONDO LLC', 1998, 24, N'700', N'CONDO', N'DRIVE', N'BETHESDA', N'MD', N'20814'),

    /* Condo account with no condo unit at all */
    (1003, N'00044556', N'P1003', N'NOUNIT CONDO TRUST', 2005, 1, N'800', N'QUIET', N'CT', N'POTOMAC', N'md', N'20854'),

    /* YearBuilt 0 and 9999 - CK_BUILDING_YearBuilt must not fire */
    (1004, N'00055667', N'P1004', N'ZERO YEAR OWNER', 0,    2, N'810', N'ZEROYEAR', N'ST', N'ROCKVILLE', N'MD', N'20850'),
    (1005, N'00055668', N'P1005', N'BIG YEAR OWNER',  9999, 2, N'812', N'BIGYEAR',  N'ST', N'ROCKVILLE', N'MD', N'20850'),

    /* 300-character street name + garbage state + 9-digit zip */
    (1006, N'00066778', N'P1006', N'LONG STREET OWNER', 1975, 1,
     N'820', REPLICATE(N'VERYLONGSTREETNAME', 30), N'BOULEVARD', N'SILVER SPRING', N'MARYLAND-USA', N'209101234'),

    /* Owner NULL - contact must still be created */
    (1007, N'00077889', N'P1007', NULL, 1960, 1, N'830', N'NOOWNER', N'ST', N'ROCKVILLE', N'MD', N'20850'),

    /* Rejects: bad number, no zip digits */
    (1008, N'00088990', N'P1008', N'BAD NUMBER OWNER', 1980, 1, N'0',  N'BADNUM', N'ST', N'ROCKVILLE', N'MD', N'20850'),
    (1009, N'00099001', N'P1009', N'NO ZIP OWNER',     1980, 1, N'840', N'NOZIP',  N'ST', N'ROCKVILLE', N'MD', N'ABCDE'),

    /* Zero-padding: 31024 and 00031024 are the same account */
    (1010, N'31024',    N'P1010', N'PAD OWNER', 1990, 4, N'850', N'PADDED', N'ST', N'ROCKVILLE', N'MD', N'20850'),
    (1011, N'00031024', N'P1010', N'PAD OWNER', 1990, 4, N'850', N'PADDED', N'ST', N'ROCKVILLE', N'MD', N'20850');
GO

/* CondoUnit is added by the load script's schema-ensure batch; add it here too
   so this setup can populate it, then drop it again to prove the load's ALTER
   path works on a fresh table. */
IF COL_LENGTH(N'dbo.SDATIncomingTableX1', N'CondoUnit') IS NULL
    ALTER TABLE dbo.SDATIncomingTableX1 ADD CondoUnit NVARCHAR(50) NULL;
GO

UPDATE dbo.SDATIncomingTableX1 SET CondoUnit = N'101' WHERE RealPropertyTaxInformationID = 1001;
UPDATE dbo.SDATIncomingTableX1 SET CondoUnit = N'102' WHERE RealPropertyTaxInformationID = 1002;
UPDATE dbo.SDATIncomingTableX1 SET CondoUnit = N'PH1' WHERE RealPropertyTaxInformationID = 1010;
UPDATE dbo.SDATIncomingTableX1 SET CondoUnit = N'PH2' WHERE RealPropertyTaxInformationID = 1011;
GO

PRINT N'Setup complete.';
SELECT MA_Rows = (SELECT COUNT(*) FROM dbo.MAIncomingTableX1),
       SDAT_Rows = (SELECT COUNT(*) FROM dbo.SDATIncomingTableX1);
GO
