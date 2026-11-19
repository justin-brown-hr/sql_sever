/* Client samples of 2026-11-17 (Valid_Records_in_Review.docx): records sent to
   Review that should load. MA and SDAT values are copied from the document;
   the MA side of each SDAT sample is a fixture choice that exercises one R15
   matching tier. Isolated integration database only, never production. */
USE UPRXDB_TEST;
GO
IF COL_LENGTH(N'dbo.MAIncomingTableX1', N'StreetSuffix') IS NULL
    ALTER TABLE dbo.MAIncomingTableX1 ADD StreetSuffix NVARCHAR(10) NULL;
IF COL_LENGTH(N'dbo.SDATIncomingTableX1', N'CondoUnit') IS NULL
    ALTER TABLE dbo.SDATIncomingTableX1 ADD CondoUnit NVARCHAR(50) NULL;
GO
INSERT dbo.MAIncomingTableX1
    (MasterAddressID, Account, ParcelNumber, StreetNumber, StreetSuffix, StreetName, StreetType,
     Unit, City, ZipCode, LUCategory, XCoordinate, YCoordinate)
VALUES
    /* Document MA samples */
    (160719, N'00227620', NULL, N'2308', NULL, N'MCAULIFFE', N'DR', NULL, N'ROCKVILLE', N'20851', N'Single Family Detached', 1280637, 512837),
    (190001, N'01876952', NULL, N'18900', NULL, N'MCFARLIN', N'DR', NULL, N'GERMANTOWN', N'20874', N'Single Family Detached', 1232504, 545704),
    /* 822 ROCKVILLE PIKE retail shops: one account, StreetSuffix A..H */
    (216016, N'00142855', NULL, N'822', N'H', N'ROCKVILLE', N'PIKE', N'H', N'ROCKVILLE', N'20851', N'Retail', 1273121, 513663),
    (312950, N'00142855', NULL, N'822', N'D', N'ROCKVILLE', N'PIKE', N'D', N'ROCKVILLE', N'20851', N'Retail', 1273146, 513689),
    (433210, N'00142855', NULL, N'822', NULL, N'ROCKVILLE', N'PIKE', NULL, N'ROCKVILLE', N'20851', N'Retail', 1273018, 513579),
    (106862, N'00142855', NULL, N'822', N'B', N'ROCKVILLE', N'PIKE', N'B', N'ROCKVILLE', N'20851', N'Retail', 1273063, 513597),
    (109562, N'00142855', NULL, N'822', N'A', N'ROCKVILLE', N'PIKE', N'A', N'ROCKVILLE', N'20852', N'Retail', 1273037, 513569),
    (171725, N'00142855', NULL, N'822', N'C', N'ROCKVILLE', N'PIKE', N'C', N'ROCKVILLE', N'20851', N'Retail', 1273092, 513630),
    /* MA side of the SDAT samples */
    (180001, N'00017886', NULL, N'13123', NULL, N'SUNCREST', N'AVE', NULL, N'CLARKSBURG', N'20871', N'Single Family Detached', NULL, NULL),
    (180002, N'00016905', NULL, N'13601', NULL, N'W OLD BALTIMORE', N'RD', NULL, N'BOYDS', N'20841', N'Institutional/Community Facility', NULL, NULL),
    (180003, N'00016984', NULL, N'22518', NULL, N'SCHOOL FIELD', N'CT', NULL, N'CLARKSBURG', N'20871', N'Single Family Detached', NULL, NULL),
    (180004, N'00017580', NULL, N'23200', NULL, N'SHILOH CHURCH', N'RD', NULL, N'BOYDS', N'20841', N'Single Family Detached', NULL, NULL),
    (180005, N'00018001', NULL, N'100', NULL, N'FIRST', N'ST', NULL, N'BOYDS', N'20841', N'Single Family Detached', NULL, NULL),
    (180006, N'00018001', NULL, N'200', NULL, N'SECOND', N'ST', NULL, N'BOYDS', N'20841', N'Single Family Detached', NULL, NULL);
INSERT dbo.SDATIncomingTableX1
    (RealPropertyTaxInformationID, AccountNumber, Parcel, Owner, YearBuilt, DwellingUnits,
     PremisesNumber, PremisesStreetName, PremisesStreetType, PremisesCity, PremisesState,
     PremisesZipCode, CondoUnit)
VALUES
    /* Document SDAT samples (CondoUnit NULL, DwellingUnits 0/1) */
    (1426, N'00017886', N'0000', N'HUYNH HUNG QUOC', 2021, 1, N'13123', N'SUNCREST', N'AVE', N'CLARKSBURG', NULL, N'208710000', NULL),
    (1348, N'00016905', N'P150', N'ADVENTIST HEALTHCARE INC', 0, 0, N'13601', N'OLD BALTIMORE', N'RD', N'BOYDS', NULL, N'208410000', NULL),
    (1352, N'00016984', N'0000', N'CAMERON PATRICIA', 0, 0, N'22518', N'SCHOOLFIELD', N'CT', N'CLARKSBURG', NULL, N'208710000', NULL),
    (1402, N'00017580', N'P333', N'LEAL HOMES LLC', 1925, 1, N'23210', N'SHILOH CHURCH', N'RD', N'BOYDS', NULL, N'208410000', NULL),
    /* SDAT spelling of the MCAULIFFE sample */
    (1500, N'00227620', NULL, N'OWNER MCAULIFFE', 1990, 1, N'2308', N'MC AULIFFE', N'DR', N'ROCKVILLE', N'MD', N'20851', NULL),
    /* Account on two MA addresses, SDAT premises at a third */
    (1501, N'00018001', NULL, N'OWNER THIRD', 2000, 1, N'300', N'THIRD', N'ST', N'BOYDS', N'MD', N'20841', NULL),
    /* SDAT-only account, CondoUnit exported as the text NULL */
    (1502, N'00019999', NULL, N'OWNER NULLTEXT', 2001, 1, N'400', N'FOURTH', N'ST', N'BOYDS', N'MD', N'20841', N'NULL');
GO
