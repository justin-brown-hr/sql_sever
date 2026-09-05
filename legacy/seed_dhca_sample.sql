/*
  Seed ~100 MasterAddress + ~100 SDAT rows into DHCA_Internal for integration test.
*/
USE DHCA_Internal;
GO
SET NOCOUNT ON;

DELETE FROM dbo.RealPropertyTaxInformation;
DELETE FROM dbo.MasterAddress;
GO

/* 100 MasterAddress rows */
;WITH n AS (
    SELECT TOP (100) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT INTO dbo.MasterAddress (
    MasterAddressID, Account, ParcelNumber, StreetNumber, StreetName, StreetType,
    Unit, City, ZipCode, LUCategory, XCoordinate, YCoordinate
)
SELECT
    100 + n.i,
    RIGHT(N'00000' + CONVERT(NVARCHAR(10), 10000 + n.i), 8),
    CONCAT(N'P', 100 + n.i),
    CONVERT(NVARCHAR(20), 100 + n.i),
    CASE (n.i % 5)
        WHEN 0 THEN N'MAIN' WHEN 1 THEN N'OAK' WHEN 2 THEN N'MARKET'
        WHEN 3 THEN N'PINE' ELSE N'MAPLE'
    END,
    CASE (n.i % 4) WHEN 0 THEN N'STREET' WHEN 1 THEN N'LANE' WHEN 2 THEN N'ROAD' ELSE N'AVENUE' END,
    CASE WHEN n.i % 10 = 0 THEN CONCAT(N'U', n.i % 100) END,
    CASE (n.i % 3) WHEN 0 THEN N'ROCKVILLE' WHEN 1 THEN N'SILVER SPRING' ELSE N'GERMANTOWN' END,
    RIGHT(N'208' + CONVERT(NVARCHAR(10), 50 + (n.i % 50)), 5),
    CASE (n.i % 6)
        WHEN 0 THEN N'CONDOMINIUM' WHEN 1 THEN N'MULTI-FAMILY' WHEN 2 THEN N'SINGLE FAMILY DETACHED'
        WHEN 3 THEN N'VACANT' WHEN 4 THEN N'TOWNHOUSE' ELSE N'MIXED USE'
    END,
    CASE WHEN n.i % 2 = 0 THEN -77000000 - n.i * 1000 ELSE NULL END,
    CASE WHEN n.i % 2 = 0 THEN 39000000 + n.i * 1000 ELSE NULL END
FROM n;
GO

/* 100 SDAT rows — ~80 match MA by account, 20 SDAT-only */
;WITH n AS (
    SELECT TOP (100) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT INTO dbo.RealPropertyTaxInformation (
    RealPropertyTaxInformationID, AccountNumber, Parcel,
    PremisesNumber, PremisesStreetName, PremisesStreetType,
    PremisesCity, PremisesState, PremisesZipCode,
    Owner, YearBuilt, DwellingUnits
)
SELECT
    200 + n.i,
    CASE WHEN n.i <= 80
         THEN RIGHT(N'00000' + CONVERT(NVARCHAR(10), 10000 + n.i), 8)
         ELSE RIGHT(N'00000' + CONVERT(NVARCHAR(10), 90000 + n.i), 8)
    END,
    CONCAT(N'P', CASE WHEN n.i <= 80 THEN 100 + n.i ELSE 900 + n.i END),
    CONVERT(NVARCHAR(20), CASE WHEN n.i <= 80 THEN 100 + n.i ELSE 900 + n.i END),
    CASE (n.i % 5)
        WHEN 0 THEN N'MAIN' WHEN 1 THEN N'OAK' WHEN 2 THEN N'MARKET'
        WHEN 3 THEN N'PINE' ELSE N'MAPLE'
    END,
    CASE (n.i % 4) WHEN 0 THEN N'STREET' WHEN 1 THEN N'LANE' WHEN 2 THEN N'ROAD' ELSE N'AVENUE' END,
    CASE (n.i % 3) WHEN 0 THEN N'ROCKVILLE' WHEN 1 THEN N'SILVER SPRING' ELSE N'GERMANTOWN' END,
    N'MD',
    RIGHT(N'208' + CONVERT(NVARCHAR(10), 50 + (n.i % 50)), 5),
    CONCAT(N'Owner ', n.i),
    1980 + (n.i % 40),
    1 + (n.i % 8)
FROM n;
GO

DECLARE @MaCnt INT = (SELECT COUNT(*) FROM dbo.MasterAddress);
DECLARE @SdCnt INT = (SELECT COUNT(*) FROM dbo.RealPropertyTaxInformation);
PRINT N'DHCA_Internal seeded: MA=' + CAST(@MaCnt AS VARCHAR(10)) + N' SDAT=' + CAST(@SdCnt AS VARCHAR(10));
GO
