/* Exact sample supplied by the client for account 01297731.
   Fixture for the isolated integration database only, never production.
   Extra input columns are included to preserve the full supplied row;
   their types here are test schema definitions, not a production migration. */
USE UPRXDB_TEST;
GO
ALTER TABLE dbo.MAIncomingTableX1 ADD
    AddressStatus INT NULL,
    AddressType INT NULL,
    AddressDate DATETIME NULL,
    StreetSuffix NVARCHAR(50) NULL,
    StreetSuffixDirection NVARCHAR(50) NULL,
    FullAddress NVARCHAR(300) NULL,
    Comments NVARCHAR(MAX) NULL;
GO
INSERT dbo.MAIncomingTableX1 (
    MasterAddressID, AddressStatus, AddressType, AddressDate,
    StreetNumber, StreetSuffix, StreetName, StreetType, StreetSuffixDirection, Unit,
    XCoordinate, YCoordinate, FullAddress, City, ZipCode, Comments,
    Account, ParcelNumber, LUCategory
)
VALUES (
    20977, 1, 1, '2001-04-16T12:04:00',
    N'13414', NULL, N'DOWLAIS', N'DR', NULL, NULL,
    1283026, 513743, N'13414 DOWLAIS DR', N'ROCKVILLE', N'20853', NULL,
    N'01297731', NULL, N'Single Family Detached'
);
GO
