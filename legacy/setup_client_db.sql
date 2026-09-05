/*
  Client-aligned test database setup (docs/ddl.md + DHCA_Internal mock).
  Run BEFORE load_upr_master.sql in integration tests.
*/
USE master;
GO

IF DB_ID(N'UPRDB_Test') IS NULL
    CREATE DATABASE UPRDB_Test;
IF DB_ID(N'DHCA_Internal') IS NULL
    CREATE DATABASE DHCA_Internal;
IF DB_ID(N'DHCA_LicensingAndRegistration') IS NULL
    CREATE DATABASE DHCA_LicensingAndRegistration;
IF DB_ID(N'DHCA_OLTA') IS NULL
    CREATE DATABASE DHCA_OLTA;
IF DB_ID(N'DHCA_MPDU') IS NULL
    CREATE DATABASE DHCA_MPDU;
IF DB_ID(N'DHCA_MultifamilyLoans') IS NULL
    CREATE DATABASE DHCA_MultifamilyLoans;
GO

/* UPR tables — full client DDL */
USE UPRDB_Test;
GO

:r ../docs/ddl.md

GO
/* DHCA_Internal source tables (columns used by load_upr_master.sql) */
USE DHCA_Internal;
GO

IF OBJECT_ID('dbo.RealPropertyTaxInformation', 'U') IS NOT NULL
    DROP TABLE dbo.RealPropertyTaxInformation;
IF OBJECT_ID('dbo.MasterAddress', 'U') IS NOT NULL
    DROP TABLE dbo.MasterAddress;
GO

CREATE TABLE dbo.MasterAddress (
    MasterAddressID   INT           NOT NULL PRIMARY KEY,
    Account           NVARCHAR(50)  NULL,
    ParcelNumber      NVARCHAR(50)  NULL,
    StreetNumber      NVARCHAR(20)  NULL,
    StreetName        NVARCHAR(100) NULL,
    StreetType        NVARCHAR(10)  NULL,
    Unit              NVARCHAR(20)  NULL,
    City              NVARCHAR(100) NULL,
    ZipCode           NVARCHAR(10)  NULL,
    LUCategory        NVARCHAR(50)  NULL,
    XCoordinate       INT           NULL,
    YCoordinate       INT           NULL
);

CREATE TABLE dbo.RealPropertyTaxInformation (
    RealPropertyTaxInformationID INT           NOT NULL PRIMARY KEY,
    AccountNumber                NVARCHAR(50)  NULL,
    Parcel                       NVARCHAR(50)  NULL,
    PremisesNumber               NVARCHAR(20)  NULL,
    PremisesStreetName           NVARCHAR(100) NULL,
    PremisesStreetType           NVARCHAR(10)  NULL,
    PremisesCity                 NVARCHAR(100) NULL,
    PremisesState                NVARCHAR(2)   NULL,
    PremisesZipCode              NVARCHAR(10)  NULL,
    Owner                        NVARCHAR(200) NULL,
    YearBuilt                    INT           NULL,
    DwellingUnits                INT           NULL
);
GO

/* Minimal external source tables (optional XREF matching) */
USE DHCA_LicensingAndRegistration;
GO
IF OBJECT_ID('dbo.Property', 'U') IS NULL
CREATE TABLE dbo.Property (
    PropertyID    INT NOT NULL PRIMARY KEY,
    StreetAddress NVARCHAR(200) NULL,
    City          NVARCHAR(100) NULL,
    ZipCode       NVARCHAR(10)  NULL,
    TaxID         NVARCHAR(50)  NULL
);
GO

USE DHCA_OLTA;
GO
IF OBJECT_ID('dbo.[Case]', 'U') IS NULL
CREATE TABLE dbo.[Case] (
    CaseNumber    NVARCHAR(50) NOT NULL PRIMARY KEY,
    StreetAddress NVARCHAR(200) NULL,
    City          NVARCHAR(100) NULL,
    ZipCode       NVARCHAR(10)  NULL
);
GO

USE DHCA_MPDU;
GO
IF OBJECT_ID('dbo.Development', 'U') IS NULL
CREATE TABLE dbo.Development (
    DevelopmentID INT NOT NULL PRIMARY KEY,
    StreetAddress NVARCHAR(200) NULL,
    City          NVARCHAR(100) NULL,
    ZipCode       NVARCHAR(10)  NULL
);
GO

USE DHCA_MultifamilyLoans;
GO
IF OBJECT_ID('dbo.Address', 'U') IS NULL
CREATE TABLE dbo.Address (
    AddressID    INT NOT NULL PRIMARY KEY,
    StreetNumber NVARCHAR(20)  NULL,
    StreetName   NVARCHAR(100) NULL,
    StreetType   NVARCHAR(10)  NULL,
    City         NVARCHAR(100) NULL,
    ZipCode      NVARCHAR(10)  NULL,
    DeletedInd   BIT NOT NULL DEFAULT 0
);
GO

PRINT N'Client test databases ready (UPRDB_Test + DHCA_*).';
GO
