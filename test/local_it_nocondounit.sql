/*
  Rebuilds the throwaway incoming tables WITHOUT the CondoUnit column, to prove
  the load script's schema-ensure batch adds it and the next batch can read it.
*/
USE UPRXDB_TEST;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'dbo.SDATIncomingTableX1', N'U') IS NOT NULL DROP TABLE dbo.SDATIncomingTableX1;
GO

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
);
GO

INSERT INTO dbo.SDATIncomingTableX1
    (RealPropertyTaxInformationID, AccountNumber, Parcel, Owner, YearBuilt, DwellingUnits,
     PremisesNumber, PremisesStreetName, PremisesStreetType, PremisesCity, PremisesState, PremisesZipCode)
VALUES
    (2001, N'00123456', N'PX1', N'NO CONDOUNIT OWNER', 1990, 3, N'950', N'FRESH', N'ST', N'ROCKVILLE', N'MD', N'20850'),
    (2002, N'00123457', N'PX2', N'SECOND OWNER',       1991, 1, N'952', N'FRESH', N'ST', N'ROCKVILLE', N'MD', N'20850');
GO

SELECT HasCondoUnitBefore =
       CASE WHEN COL_LENGTH(N'dbo.SDATIncomingTableX1', N'CondoUnit') IS NULL THEN 0 ELSE 1 END;
GO
