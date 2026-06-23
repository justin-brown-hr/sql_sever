/*
================================================================================
  UPR Master Load Script
  
  Loads AddressMaster + SDAT, normalizes addresses, populates UPROPERTYRECORDS
  and all related tables (XREF, Review_Q, StatusHistory, Contact, Building/Unit,
  Reference data, AuditLog).

  CLIENT RULES:
    UPR  — every incoming row with valid Account#, valid address, AND ParcelID
    Review_Q — missing/invalid Account#, invalid address, OR NULL ParcelID only
    XREF   — incoming MA/SDAT links (MATCH) for UPR rows; external systems
             (eProperty, CASE, MPDU, MULTIFAMILY) only when address/account matches UPR
    External non-match does NOT send valid UPR rows to Review_Q

  MA Unit held in #Work/#UPRMap only — loaded to dbo.Unit (UPR has no unit column).
  UPR NOT NULL columns per client DDL: SDATAccountNumber, StreetNumber, StreetName,
  StreetType, City, ZipCode, NormalizedStreetAddress, NormalizedFullAddress, PropertyStatusCode,
  Aligns with docs/ddl.md CHECK: ZipCode #####/#####-####, State 2 uppercase A-Z,
  PropertyStatusCode ACTIVE|INACTIVE|PENDING|RETIRED. Column NormalizedFulldAddress per DDL.

  DHCA SOURCE DATA:
    DHCA_Internal.dbo.MasterAddress
    DHCA_Internal.dbo.RealPropertyTaxInformation
    DHCA_LicensingAndRegistration.dbo.Property
    DHCA_OLTA.dbo.[Case]
    DHCA_MPDU.dbo.Development
    DHCA_MultifamilyLoans.dbo.Address

  HOW TO RUN: Execute this script in SSMS against UPRDB_Test. No other scripts required.
================================================================================
*/
USE UPRDB_Test;
GO
/* ---- Inline normalization functions ---- */
CREATE OR ALTER FUNCTION dbo.fn_UPR_StdStreetToken (@token NVARCHAR(50))
RETURNS NVARCHAR(10)
AS
BEGIN
    RETURN CASE UPPER(LTRIM(RTRIM(@token)))
        WHEN N'STREET' THEN N'ST'  WHEN N'ST' THEN N'ST'
        WHEN N'AVENUE' THEN N'AVE' WHEN N'AVE' THEN N'AVE'
        WHEN N'ROAD'   THEN N'RD'  WHEN N'RD'  THEN N'RD'
        WHEN N'LANE'   THEN N'LN'  WHEN N'LN'  THEN N'LN'
        WHEN N'COURT'  THEN N'CT'  WHEN N'CT'  THEN N'CT'
        WHEN N'DRIVE'  THEN N'DR'  WHEN N'DR'  THEN N'DR'
        WHEN N'BOULEVARD' THEN N'BLVD' WHEN N'BLVD' THEN N'BLVD'
        WHEN N'PLACE'  THEN N'PL'  WHEN N'PL'  THEN N'PL'
        ELSE NULLIF(UPPER(LTRIM(RTRIM(@token))), N'')
    END;
END;
GO

CREATE OR ALTER FUNCTION dbo.fn_UPR_NormalizeAddressLine (@line NVARCHAR(300))
RETURNS NVARCHAR(200)
AS
BEGIN
    DECLARE @s NVARCHAR(300) = UPPER(LTRIM(RTRIM(ISNULL(@line, N''))));
    IF @s = N'' RETURN N'';

    DECLARE @lastSpace INT = CHARINDEX(N' ', REVERSE(@s));
    IF @lastSpace > 0
    BEGIN
        DECLARE @lastToken NVARCHAR(50) = RIGHT(@s, @lastSpace - 1);
        DECLARE @prefix NVARCHAR(250) = LEFT(@s, LEN(@s) - @lastSpace);
        SET @s = LTRIM(RTRIM(CONCAT(@prefix, N' ', dbo.fn_UPR_StdStreetToken(@lastToken))));
    END

    RETURN LTRIM(RTRIM(REPLACE(REPLACE(@s, N'  ', N' '), N'  ', N' ')));
END;
GO

/* UPR ZipCode CHECK: ##### or #####-#### — strip non-digits, pad/ format */
CREATE OR ALTER FUNCTION dbo.fn_UPR_NormalizeZipCode (@zip NVARCHAR(20))
RETURNS NVARCHAR(10)
AS
BEGIN
    DECLARE @raw   NVARCHAR(20) = LTRIM(RTRIM(ISNULL(@zip, N'')));
    DECLARE @digits NVARCHAR(20) = N'';
    DECLARE @i     INT = 1;

    WHILE @i <= LEN(@raw)
    BEGIN
        IF SUBSTRING(@raw, @i, 1) LIKE N'[0-9]'
            SET @digits = @digits + SUBSTRING(@raw, @i, 1);
        SET @i = @i + 1;
    END;

    IF LEN(@digits) >= 9
        RETURN LEFT(@digits, 5) + N'-' + SUBSTRING(@digits, 6, 4);
    IF LEN(@digits) >= 5
        RETURN LEFT(@digits, 5);
    IF LEN(@digits) > 0
        RETURN RIGHT(REPLICATE(N'0', 5) + @digits, 5);

    RETURN N'00000';
END;
GO

CREATE OR ALTER FUNCTION dbo.fn_UPR_IsValidZipCode (@zip NVARCHAR(20))
RETURNS BIT
AS
BEGIN
    DECLARE @n NVARCHAR(10) = dbo.fn_UPR_NormalizeZipCode(@zip);
    IF @n = N'00000' RETURN 0;
    IF @n LIKE N'[0-9][0-9][0-9][0-9][0-9]'
       OR @n LIKE N'[0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]'
        RETURN 1;
    RETURN 0;
END;
GO

/* Strip leading zeros from numeric street numbers — 02456 -> 2456 */
CREATE OR ALTER FUNCTION dbo.fn_UPR_NormalizeStreetNumber (@streetNumber NVARCHAR(20))
RETURNS NVARCHAR(20)
AS
BEGIN
    DECLARE @s NVARCHAR(20) = LTRIM(RTRIM(ISNULL(@streetNumber, N'')));
    IF @s = N'' RETURN N'';

    /* Pure digits: 02456 -> 2456 */
    IF @s NOT LIKE N'%[^0-9]%'
    BEGIN
        DECLARE @n BIGINT = TRY_CONVERT(BIGINT, @s);
        IF @n IS NOT NULL AND @n > 0
            RETURN CONVERT(NVARCHAR(20), @n);
        RETURN @s;
    END

    /* Leading-zero digit prefix before letters/suffix — 012A -> 12A */
    WHILE LEN(@s) > 1
      AND LEFT(@s, 1) = N'0'
      AND SUBSTRING(@s, 2, 1) LIKE N'[0-9]'
        SET @s = SUBSTRING(@s, 2, LEN(@s) - 1);

    RETURN @s;
END;
GO

/* Reject placeholder/bad street numbers (e.g. 0) — UQ_UPropertyRecords_Address */
CREATE OR ALTER FUNCTION dbo.fn_UPR_IsValidStreetNumber (@streetNumber NVARCHAR(20))
RETURNS BIT
AS
BEGIN
    DECLARE @s NVARCHAR(20) = dbo.fn_UPR_NormalizeStreetNumber(@streetNumber);
    IF @s = N'' OR @s = N'0' RETURN 0;
    DECLARE @n INT = TRY_CONVERT(INT, @s);
    IF @n IS NOT NULL AND @n <= 0 RETURN 0;
    RETURN 1;
END;
GO

/* DDL CK_UPropertyRecords_State: LEN=2, uppercase A-Z only */
CREATE OR ALTER FUNCTION dbo.fn_UPR_NormalizeState (
    @state NVARCHAR(10), @default CHAR(2)
)
RETURNS CHAR(2)
AS
BEGIN
    DECLARE @s CHAR(2) = UPPER(LTRIM(RTRIM(ISNULL(@state, N''))));
    IF LEN(@s) = 2 AND @s NOT LIKE N'%[^A-Z]%'
        RETURN @s;
    RETURN @default;
END;
GO

CREATE OR ALTER FUNCTION dbo.fn_UPR_NormalizeFullAddressLine (
    @line NVARCHAR(300), @city NVARCHAR(100), @zip NVARCHAR(10)
)
RETURNS NVARCHAR(300)
AS
BEGIN
    RETURN LTRIM(RTRIM(CONCAT(
        dbo.fn_UPR_NormalizeAddressLine(@line), N' ',
        UPPER(LTRIM(RTRIM(ISNULL(@city, N'')))), N' ',
        LEFT(REPLACE(dbo.fn_UPR_NormalizeZipCode(@zip), N'-', N''), 5)
    )));
END;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @RunUser NVARCHAR(100) = SUSER_SNAME();
DECLARE @Now     DATETIME2(0)  = SYSDATETIME();
DECLARE @BatchStartTime DATETIME2(0) = SYSDATETIME();
DECLARE @DefaultState  CHAR(2)   = N'MD';
DECLARE @DefaultSdatPropertyType NVARCHAR(10) = N'CONDO';  /* SDAT-only default — MA uses LUCategory */

/* Summary counters (printed at end) */
DECLARE @MasterAddressRead INT = 0, @SDATRead INT = 0, @IncomingUnifiedRows INT = 0;
DECLARE @RowsIncompleteData INT = 0, @RowsReviewDuplicate INT = 0, @RowsSentToReview INT = 0;
DECLARE @UPRInserted INT = 0, @UPRUpdated INT = 0, @UprEligibleRows INT = 0;
DECLARE @MasterAddressXrefInserted INT = 0, @SDATXrefInserted INT = 0;
DECLARE @CaseXrefInserted INT = 0, @MPDUXrefInserted INT = 0, @EPropertyXrefInserted INT = 0, @MultifamilyXrefInserted INT = 0, @TotalXrefInserted INT = 0;
DECLARE @ReviewIncomingInserted INT = 0, @ReviewExternalInserted INT = 0, @ReviewInserted INT = 0;
DECLARE @StatusHistoryInserted INT = 0, @AuditInserted INT = 0;
DECLARE @BuildingInserted INT = 0, @UnitInserted INT = 0, @ContactInserted INT = 0, @PropertyContactInserted INT = 0;
DECLARE @BatchEndTime DATETIME2(0);
DECLARE @UprCountBefore INT = 0;
DECLARE @UprMergeRowsAffected INT = 0;
DECLARE @Sql NVARCHAR(MAX);

BEGIN TRY
    BEGIN TRANSACTION;

    /* ========================================================================
       1. ENSURE REFERENCE DATA (idempotent MERGE)
       ======================================================================== */
    MERGE dbo.REF_PROPERTYTYPE AS t
    USING (VALUES
        (N'APT',   N'Apartment Complex',     1, 1),
        (N'CONDO', N'Condominium Property',  1, 1),
        (N'TH',    N'Townhouse Community',   1, 1),
        (N'MULTI', N'Multi-Family Property', 1, 1),
        (N'SF',    N'Single Family Property',1, 0),
        (N'LAND',  N'Vacant Land',           0, 0),
        (N'MIXED', N'Mixed Use Property',    1, 1)
    ) AS s(Code, Name, AllowBldg, AllowUnit)
    ON t.PropertyTypeCode = s.Code
    WHEN NOT MATCHED THEN
        INSERT (PropertyTypeCode, PropertyTypeName, AllowsBuildings, AllowsUnits, DeletedInd, CreationUSERID, LastUpdatedUserID)
        VALUES (s.Code, s.Name, s.AllowBldg, s.AllowUnit, 0, N'SYSTEM', N'SYSTEM');

    MERGE dbo.REF_SOURCESYSTEM AS t
    USING (VALUES
        (N'ADDRESS_MASTER', N'Address Master',      N'Incoming AddressMaster'),
        (N'KDAT',           N'KDAT',                N'Incoming SDAT/KDAT'),
        (N'eProperty',      N'eProperty',            N'Licensing property'),
        (N'CASE',           N'CASE',                N'Enforcement case'),
        (N'MPDU',           N'MPDU',                N'MPDU development'),
        (N'MULTIFAMILY',    N'Multifamily loans',   N'Multifamily loan address')
    ) AS s(Code, Name, Descr)
    ON t.SourceSystemCode = s.Code
    WHEN NOT MATCHED THEN
        INSERT (SourceSystemCode, SourceSystemName, [Description])
        VALUES (s.Code, s.Name, s.Descr);

    MERGE dbo.REF_MATCHMETHOD AS t
    USING (VALUES
        (N'ParcelID',          N'Parcel match',        N'Exact parcel'),
        (N'SDATAccount',       N'Tax/Account match',   N'Exact account / tax id'),
        (N'AddressExact',      N'Exact address',       N'Exact normalized match'),
        (N'AddressNormalized', N'Normalized address',  N'Normalized composite'),
        (N'GISProximity',      N'GIS proximity',       N'Coordinate proximity'),
        (N'Manual',            N'Manual',              N'Steward confirmed')
    ) AS s(Code, Name, Descr)
    ON t.MatchMethodCode = s.Code
    WHEN NOT MATCHED THEN
        INSERT (MatchMethodCode, MatchMethodName, [Description])
        VALUES (s.Code, s.Name, s.Descr);

    MERGE dbo.REF_MATCHCONFIDENCE AS t
    USING (VALUES
        (N'HIGH',     N'High',     100, N'Very reliable', @Now, @Now),
        (N'MEDIUM',   N'Medium',    75, N'Likely', @Now, @Now),
        (N'LOW',      N'Low',       55, N'Uncertain', @Now, @Now),
        (N'VERIFIED', N'Verified', 110, N'Human verified', @Now, @Now),
        (N'NONE',     N'None',       0, N'No confidence assigned', @Now, @Now)
    ) AS s(Code, Name, RankVal, Descr, CreationDate, UpdatedDate)
    ON t.MatchConfidenceCode = s.Code
    WHEN NOT MATCHED THEN
        INSERT (MatchConfidenceCode, MatchConfidenceName, ConfidenceRank, [Description], CreationDate, UpdatedDate)
        VALUES (s.Code, s.Name, s.RankVal, s.Descr, s.CreationDate, s.UpdatedDate);

    IF NOT EXISTS (SELECT 1 FROM dbo.REF_BUILDINGTYPE)
        INSERT INTO dbo.REF_BUILDINGTYPE (BuildingTypeCode, BuildingTypeName, [Description], IsResidential, IsActive)
        VALUES (N'MAIN', N'Main building', N'Default main structure', 1, 1);

    IF NOT EXISTS (SELECT 1 FROM dbo.REF_UNITTYPECODE)
        INSERT INTO dbo.REF_UNITTYPECODE (UnitTypeCode, UnitTypeName, [Description])
        VALUES (N'APT', N'Apartment unit', N'Apartment'), (N'CONDO', N'Condo unit', N'Condominium unit');

    /* ========================================================================
       2. NORMALIZE AddressMaster  
       ======================================================================== */
    IF OBJECT_ID('tempdb..#MA') IS NOT NULL DROP TABLE #MA;

    SELECT
        ma.MasterAddressID,
        SourceSystem         = N'ADDRESS_MASTER',
        SourceRecordID       = CONVERT(VARCHAR(100), ma.MasterAddressID),
        SourceEntityType     = N'MasterAddress',
        MasterAddressAccount = NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), ma.Account))), N''),
        SDATAccountNumber    = NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), ma.Account))), N''),
        ParcelID             = NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), ma.ParcelNumber))), N''),
        StreetNumber         = NULLIF(dbo.fn_UPR_NormalizeStreetNumber(CONVERT(NVARCHAR(20), ma.StreetNumber)), N''),
        StreetName           = NULLIF(UPPER(LTRIM(RTRIM(ma.StreetName))), N''),
        StreetType           = CASE UPPER(LTRIM(RTRIM(ma.StreetType)))
            WHEN N'STREET' THEN N'ST'  WHEN N'ST' THEN N'ST'
            WHEN N'AVENUE' THEN N'AVE' WHEN N'AVE' THEN N'AVE'
            WHEN N'ROAD'   THEN N'RD'  WHEN N'RD'  THEN N'RD'
            WHEN N'LANE'   THEN N'LN'  WHEN N'LN'  THEN N'LN'
            WHEN N'COURT'  THEN N'CT'  WHEN N'CT'  THEN N'CT'
            WHEN N'DRIVE'  THEN N'DR'  WHEN N'DR'  THEN N'DR'
            WHEN N'BOULEVARD' THEN N'BLVD' WHEN N'BLVD' THEN N'BLVD'
            WHEN N'PLACE'  THEN N'PL'  WHEN N'PL'  THEN N'PL'
            ELSE NULLIF(UPPER(LTRIM(RTRIM(ma.StreetType))), N'')
        END,
        Unit                = NULLIF(LTRIM(RTRIM(ma.Unit)), N''),
        City                 = NULLIF(UPPER(LTRIM(RTRIM(ma.City))), N''),
        [State]              = dbo.fn_UPR_NormalizeState(NULL, @DefaultState),
        ZipCode              = dbo.fn_UPR_NormalizeZipCode(ma.ZipCode),
        PropertyTypeRaw      = NULLIF(UPPER(LTRIM(RTRIM(ma.LUCategory))), N''),
        /* LUCategory → REF_PROPERTYTYPE (client-confirmed distinct values) */
        PropertyType         = CONVERT(NVARCHAR(50), CASE UPPER(LTRIM(RTRIM(ma.LUCategory)))
            WHEN N'CONDOMINIUM'            THEN N'CONDO'
            WHEN N'C'                      THEN N'CONDO'
            WHEN N'MULTI-FAMILY'           THEN N'MULTI'
            WHEN N'MULTI FAMILY'           THEN N'MULTI'
            WHEN N'MULTIFAMILY'            THEN N'MULTI'
            WHEN N'SINGLE FAMILY DETACHED' THEN N'SF'
            WHEN N'SINGLE FAMILY ATTACHED' THEN N'SF'
            WHEN N'VACANT'                 THEN N'LAND'
            WHEN N'TOWNHOUSE'              THEN N'TH'
            WHEN N'MIXED USE'              THEN N'MIXED'
            ELSE N'SF'  /* blank or unexpected LUCategory */
        END),
        OwnerName            = CAST(NULL AS NVARCHAR(200)),
        YearBuilt            = CAST(NULL AS INT),
        DwellingUnits        = CAST(NULL AS INT),
        Latitude             = TRY_CONVERT(DECIMAL(10, 6), NULLIF(ma.YCoordinate, 0)),
        Longitude            = TRY_CONVERT(DECIMAL(10, 6), NULLIF(ma.XCoordinate, 0)),
        NormalizedStreetAddress    = UPPER(LTRIM(RTRIM(CONCAT(
            ISNULL(dbo.fn_UPR_NormalizeStreetNumber(CONVERT(NVARCHAR(20), ma.StreetNumber)), N''), N' ',
            ISNULL(UPPER(LTRIM(RTRIM(ma.StreetName))), N''), N' ',
            CASE UPPER(LTRIM(RTRIM(ma.StreetType)))
                WHEN N'STREET' THEN N'ST' WHEN N'AVENUE' THEN N'AVE' WHEN N'ROAD' THEN N'RD'
                WHEN N'LANE' THEN N'LN'   WHEN N'COURT' THEN N'CT'  WHEN N'DRIVE' THEN N'DR'
                WHEN N'BOULEVARD' THEN N'BLVD' WHEN N'PLACE' THEN N'PL'
                ELSE ISNULL(UPPER(LTRIM(RTRIM(ma.StreetType))), N'')
            END
        )))),
        NormalizedFullAddress = UPPER(LTRIM(RTRIM(CONCAT(
            ISNULL(dbo.fn_UPR_NormalizeStreetNumber(CONVERT(NVARCHAR(20), ma.StreetNumber)), N''), N' ',
            ISNULL(UPPER(LTRIM(RTRIM(ma.StreetName))), N''), N' ',
            CASE UPPER(LTRIM(RTRIM(ma.StreetType)))
                WHEN N'STREET' THEN N'ST' WHEN N'AVENUE' THEN N'AVE' WHEN N'ROAD' THEN N'RD'
                WHEN N'LANE' THEN N'LN'   WHEN N'COURT' THEN N'CT'  WHEN N'DRIVE' THEN N'DR'
                WHEN N'BOULEVARD' THEN N'BLVD' WHEN N'PLACE' THEN N'PL'
                ELSE ISNULL(UPPER(LTRIM(RTRIM(ma.StreetType))), N'')
            END, N' ',
            ISNULL(UPPER(LTRIM(RTRIM(ma.City))), N''), N' ',
            LEFT(REPLACE(dbo.fn_UPR_NormalizeZipCode(ma.ZipCode), N'-', N''), 5)
        )))),
        HasRequiredAddress   = CASE
            WHEN NULLIF(UPPER(LTRIM(RTRIM(ma.StreetName))), N'') IS NULL THEN 0
            WHEN NULLIF(UPPER(LTRIM(RTRIM(ma.City))), N'') IS NULL THEN 0
            WHEN dbo.fn_UPR_IsValidStreetNumber(ma.StreetNumber) = 0 THEN 0
            WHEN dbo.fn_UPR_IsValidZipCode(ma.ZipCode) = 0 THEN 0
            ELSE 1
        END
    INTO #MA
    FROM DHCA_Internal.dbo.MasterAddress ma;

    SET @MasterAddressRead = (SELECT COUNT(*) FROM #MA);

    /* ========================================================================
       3. NORMALIZE SDAT  
       ======================================================================== */
    IF OBJECT_ID('tempdb..#SDAT') IS NOT NULL DROP TABLE #SDAT;

    SELECT
        KdatRecordID         = TRY_CONVERT(INT, s.RealPropertyTaxInformationID),
        SourceSystem         = N'KDAT',
        SourceRecordID       = CONVERT(VARCHAR(100), s.RealPropertyTaxInformationID),
        SourceEntityType     = N'SDATProperty',
        MasterAddressAccount = NULL,
        SDATAccountNumber    = NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), s.AccountNumber))), N''),
        ParcelID             = NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), s.Parcel))), N''),
        StreetNumber         = NULLIF(dbo.fn_UPR_NormalizeStreetNumber(LTRIM(RTRIM(s.PremisesNumber))), N''),
        StreetName           = NULLIF(UPPER(LTRIM(RTRIM(s.PremisesStreetName))), N''),
        StreetType           = CASE UPPER(LTRIM(RTRIM(s.PremisesStreetType)))
            WHEN N'STREET' THEN N'ST'  WHEN N'ST' THEN N'ST'
            WHEN N'AVENUE' THEN N'AVE' WHEN N'AVE' THEN N'AVE'
            WHEN N'ROAD'   THEN N'RD'  WHEN N'RD'  THEN N'RD'
            WHEN N'LANE'   THEN N'LN'  WHEN N'LN'  THEN N'LN'
            WHEN N'COURT'  THEN N'CT'  WHEN N'CT'  THEN N'CT'
            WHEN N'DRIVE'  THEN N'DR'  WHEN N'DR'  THEN N'DR'
            WHEN N'BOULEVARD' THEN N'BLVD' WHEN N'BLVD' THEN N'BLVD'
            WHEN N'PLACE'  THEN N'PL'  WHEN N'PL'  THEN N'PL'
            ELSE NULLIF(UPPER(LTRIM(RTRIM(s.PremisesStreetType))), N'')
        END,
        Unit            = CAST(NULL AS NVARCHAR(20)),  /* SDAT source has no Unit column */
        City                 = NULLIF(UPPER(LTRIM(RTRIM(s.PremisesCity))), N''),
        /* [State] only once — do not add a second [State] line below */
        [State]              = dbo.fn_UPR_NormalizeState(s.PremisesState, @DefaultState),
        ZipCode              = dbo.fn_UPR_NormalizeZipCode(s.PremisesZipCode),
        PropertyTypeRaw      = CAST(NULL AS NVARCHAR(50)),
        PropertyType         = N'CONDO',  /* SDAT has no LUCategory — default CONDO at load */
        OwnerName            = NULLIF(LTRIM(RTRIM(CAST(s.Owner AS NVARCHAR(200)))), N''),
        YearBuilt            = TRY_CONVERT(INT, s.YearBuilt),
        DwellingUnits        = TRY_CONVERT(INT, s.DwellingUnits),
        Latitude             = CAST(NULL AS DECIMAL(10, 6)),
        Longitude            = CAST(NULL AS DECIMAL(10, 6)),
        NormalizedStreetAddress    = UPPER(LTRIM(RTRIM(CONCAT(
            ISNULL(dbo.fn_UPR_NormalizeStreetNumber(LTRIM(RTRIM(s.PremisesNumber))), N''), N' ',
            ISNULL(UPPER(LTRIM(RTRIM(s.PremisesStreetName))), N''), N' ',
            CASE UPPER(LTRIM(RTRIM(s.PremisesStreetType)))
                WHEN N'STREET' THEN N'ST' WHEN N'AVENUE' THEN N'AVE' WHEN N'ROAD' THEN N'RD'
                WHEN N'LANE' THEN N'LN'   WHEN N'COURT' THEN N'CT'  WHEN N'DRIVE' THEN N'DR'
                WHEN N'BOULEVARD' THEN N'BLVD' WHEN N'PLACE' THEN N'PL'
                ELSE ISNULL(UPPER(LTRIM(RTRIM(s.PremisesStreetType))), N'')
            END
        )))),
        NormalizedFullAddress = UPPER(LTRIM(RTRIM(CONCAT(
            ISNULL(dbo.fn_UPR_NormalizeStreetNumber(LTRIM(RTRIM(s.PremisesNumber))), N''), N' ',
            ISNULL(UPPER(LTRIM(RTRIM(s.PremisesStreetName))), N''), N' ',
            CASE UPPER(LTRIM(RTRIM(s.PremisesStreetType)))
                WHEN N'STREET' THEN N'ST' WHEN N'AVENUE' THEN N'AVE' WHEN N'ROAD' THEN N'RD'
                WHEN N'LANE' THEN N'LN'   WHEN N'COURT' THEN N'CT'  WHEN N'DRIVE' THEN N'DR'
                WHEN N'BOULEVARD' THEN N'BLVD' WHEN N'PLACE' THEN N'PL'
                ELSE ISNULL(UPPER(LTRIM(RTRIM(s.PremisesStreetType))), N'')
            END, N' ',
            ISNULL(UPPER(LTRIM(RTRIM(s.PremisesCity))), N''), N' ',
            LEFT(REPLACE(dbo.fn_UPR_NormalizeZipCode(s.PremisesZipCode), N'-', N''), 5)
        )))),
        HasRequiredAddress   = CASE
            WHEN NULLIF(UPPER(LTRIM(RTRIM(s.PremisesStreetName))), N'') IS NULL THEN 0
            WHEN NULLIF(UPPER(LTRIM(RTRIM(s.PremisesCity))), N'') IS NULL THEN 0
            WHEN dbo.fn_UPR_IsValidStreetNumber(s.PremisesNumber) = 0 THEN 0
            WHEN dbo.fn_UPR_IsValidZipCode(s.PremisesZipCode) = 0 THEN 0
            ELSE 1
        END
    INTO #SDAT
    FROM DHCA_Internal.dbo.RealPropertyTaxInformation s;

    SET @SDATRead = (SELECT COUNT(*) FROM #SDAT);

    /* ========================================================================
       4. MATCH AddressMaster <-> SDAT → unified #Work (one row per property)
       Match on account, parcel, or normalized address (not all three required).
       ======================================================================== */
    IF OBJECT_ID('tempdb..#Work') IS NOT NULL DROP TABLE #Work;

    CREATE TABLE #Work (
        MasterAddressID         INT            NULL,
        KdatRecordID              INT            NULL,
        MasterAddressAccount      NVARCHAR(50)   NULL,
        SDATAccountNumber         NVARCHAR(50)   NULL,
        ParcelID                  NVARCHAR(50)   NULL,
        StreetNumber              NVARCHAR(20)   NULL,
        StreetName                NVARCHAR(150)  NULL,
        StreetType                NVARCHAR(20)   NULL,
        Unit                        NVARCHAR(20)   NULL,
        City                      NVARCHAR(100)  NULL,
        [State]                   CHAR(2)        NOT NULL,
        ZipCode                   NVARCHAR(10)   NULL,
        PropertyType              NVARCHAR(50)   NULL,
        OwnerName                 NVARCHAR(200)  NULL,
        YearBuilt                 INT            NULL,
        DwellingUnits             INT            NULL,
        Latitude                  DECIMAL(10, 6) NULL,
        Longitude                 DECIMAL(10, 6) NULL,
        NormalizedStreetAddress         NVARCHAR(200)  NOT NULL,
        NormalizedFullAddress     NVARCHAR(300)  NOT NULL,
        HasRequiredAddress        BIT            NOT NULL,
        MatchSource               NVARCHAR(30)   NOT NULL,
        IncomingMatchConfidence   NVARCHAR(30)   NOT NULL,
        IncomingMatchMethod       NVARCHAR(30)   NOT NULL
    );

    IF OBJECT_ID('tempdb..#MaSdMatch') IS NOT NULL DROP TABLE #MaSdMatch;

    SELECT
        ma.MasterAddressID,
        sd.KdatRecordID,
        MatchPriority = CASE
            WHEN ma.MasterAddressAccount IS NOT NULL
                 AND ma.MasterAddressAccount = sd.SDATAccountNumber
                 AND (
                    ma.NormalizedStreetAddress = sd.NormalizedStreetAddress
                    OR ma.NormalizedFullAddress = sd.NormalizedFullAddress
                 ) THEN 1
            WHEN ma.MasterAddressAccount IS NOT NULL
                 AND ma.MasterAddressAccount = sd.SDATAccountNumber THEN 2
            WHEN ma.ParcelID IS NOT NULL AND sd.ParcelID IS NOT NULL
                 AND ma.ParcelID = sd.ParcelID THEN 3
            WHEN ma.NormalizedFullAddress = sd.NormalizedFullAddress THEN 4
            WHEN ma.NormalizedStreetAddress = sd.NormalizedStreetAddress THEN 5
            ELSE 99
        END
    INTO #MaSdMatch
    FROM #MA ma
    INNER JOIN #SDAT sd
        ON (
            (ma.MasterAddressAccount IS NOT NULL AND ma.MasterAddressAccount = sd.SDATAccountNumber)
            OR (ma.ParcelID IS NOT NULL AND sd.ParcelID IS NOT NULL AND ma.ParcelID = sd.ParcelID)
            OR ma.NormalizedFullAddress = sd.NormalizedFullAddress
            OR ma.NormalizedStreetAddress = sd.NormalizedStreetAddress
        );

    IF OBJECT_ID('tempdb..#MaSdBest') IS NOT NULL DROP TABLE #MaSdBest;

    SELECT MasterAddressID, KdatRecordID, MatchPriority
    INTO #MaSdBest
    FROM (
        SELECT
            m.*,
            ROW_NUMBER() OVER (
                PARTITION BY m.MasterAddressID
                ORDER BY m.MatchPriority, m.KdatRecordID
            ) AS MaRn,
            ROW_NUMBER() OVER (
                PARTITION BY m.KdatRecordID
                ORDER BY m.MatchPriority, m.MasterAddressID
            ) AS SdRn
        FROM #MaSdMatch m
    ) x
    WHERE x.MaRn = 1 AND x.SdRn = 1;

    /* 4a. Matched MA + SDAT */
    INSERT INTO #Work (
        MasterAddressID, KdatRecordID, MasterAddressAccount, SDATAccountNumber, ParcelID,
        StreetNumber, StreetName, StreetType, Unit,
        City, [State], ZipCode, PropertyType,
        OwnerName, YearBuilt, DwellingUnits, Latitude, Longitude,
        NormalizedStreetAddress, NormalizedFullAddress, HasRequiredAddress,
        MatchSource, IncomingMatchConfidence, IncomingMatchMethod
    )
    SELECT
        ma.MasterAddressID,
        sd.KdatRecordID,
        ma.MasterAddressAccount,
        COALESCE(sd.SDATAccountNumber, ma.SDATAccountNumber),
        COALESCE(sd.ParcelID, ma.ParcelID),
        CASE
            WHEN dbo.fn_UPR_IsValidStreetNumber(ma.StreetNumber) = 1 THEN ma.StreetNumber
            WHEN dbo.fn_UPR_IsValidStreetNumber(sd.StreetNumber) = 1 THEN sd.StreetNumber
            ELSE COALESCE(ma.StreetNumber, sd.StreetNumber)
        END,
        COALESCE(ma.StreetName, sd.StreetName),
        COALESCE(ma.StreetType, sd.StreetType),
        ma.Unit,  /* SDAT has no Unit — MA only */
        COALESCE(ma.City, sd.City),
        COALESCE(sd.[State], @DefaultState),
        COALESCE(ma.ZipCode, sd.ZipCode),
        CONVERT(NVARCHAR(50), ma.PropertyType),  /* BOTH → MA LUCategory */
        CONVERT(NVARCHAR(200), sd.OwnerName),
        TRY_CONVERT(INT, sd.YearBuilt),        /* SDAT only — not ma */
        TRY_CONVERT(INT, sd.DwellingUnits),    /* SDAT only — not ma */
        COALESCE(ma.Latitude, sd.Latitude),
        COALESCE(ma.Longitude, sd.Longitude),
        COALESCE(ma.NormalizedStreetAddress, sd.NormalizedStreetAddress),
        COALESCE(ma.NormalizedFullAddress, sd.NormalizedFullAddress),
        CASE
            WHEN NULLIF(UPPER(LTRIM(RTRIM(COALESCE(ma.StreetName, sd.StreetName)))), N'') IS NULL THEN 0
            WHEN NULLIF(UPPER(LTRIM(RTRIM(COALESCE(ma.City, sd.City)))), N'') IS NULL THEN 0
            WHEN dbo.fn_UPR_IsValidStreetNumber(
                CASE
                    WHEN dbo.fn_UPR_IsValidStreetNumber(ma.StreetNumber) = 1 THEN ma.StreetNumber
                    WHEN dbo.fn_UPR_IsValidStreetNumber(sd.StreetNumber) = 1 THEN sd.StreetNumber
                    ELSE COALESCE(ma.StreetNumber, sd.StreetNumber)
                END
            ) = 0 THEN 0
            WHEN dbo.fn_UPR_IsValidZipCode(COALESCE(ma.ZipCode, sd.ZipCode)) = 0 THEN 0
            WHEN NULLIF(LTRIM(RTRIM(COALESCE(sd.ParcelID, ma.ParcelID))), N'') IS NULL THEN 0
            ELSE 1
        END,
        N'BOTH', N'HIGH', N'AddressNormalized'
    FROM #MaSdBest ms
    INNER JOIN #MA ma ON ma.MasterAddressID = ms.MasterAddressID
    INNER JOIN #SDAT sd ON sd.KdatRecordID = ms.KdatRecordID;

    /* 4b. AddressMaster only — enrich parcel/account from SDAT when account matches */
    INSERT INTO #Work (
        MasterAddressID, KdatRecordID, MasterAddressAccount, SDATAccountNumber, ParcelID,
        StreetNumber, StreetName, StreetType, Unit,
        City, [State], ZipCode, PropertyType,
        OwnerName, YearBuilt, DwellingUnits, Latitude, Longitude,
        NormalizedStreetAddress, NormalizedFullAddress, HasRequiredAddress,
        MatchSource, IncomingMatchConfidence, IncomingMatchMethod
    )
    SELECT
        ma.MasterAddressID, NULL, ma.MasterAddressAccount,
        COALESCE(sd.SDATAccountNumber, ma.SDATAccountNumber),
        COALESCE(NULLIF(LTRIM(RTRIM(ma.ParcelID)), N''), sd.ParcelID),
        COALESCE(ma.StreetNumber, sd.StreetNumber),
        COALESCE(ma.StreetName, sd.StreetName),
        COALESCE(ma.StreetType, sd.StreetType),
        ma.Unit,
        COALESCE(ma.City, sd.City),
        COALESCE(ma.[State], sd.[State], @DefaultState),
        COALESCE(ma.ZipCode, sd.ZipCode),
        CONVERT(NVARCHAR(50), ma.PropertyType),
        COALESCE(CONVERT(NVARCHAR(200), ma.OwnerName), CONVERT(NVARCHAR(200), sd.OwnerName)),
        TRY_CONVERT(INT, sd.YearBuilt),
        TRY_CONVERT(INT, sd.DwellingUnits),
        COALESCE(ma.Latitude, sd.Latitude),
        COALESCE(ma.Longitude, sd.Longitude),
        COALESCE(ma.NormalizedStreetAddress, sd.NormalizedStreetAddress),
        COALESCE(ma.NormalizedFullAddress, sd.NormalizedFullAddress),
        CASE
            WHEN NULLIF(UPPER(LTRIM(RTRIM(COALESCE(ma.StreetName, sd.StreetName)))), N'') IS NULL THEN 0
            WHEN NULLIF(UPPER(LTRIM(RTRIM(COALESCE(ma.City, sd.City)))), N'') IS NULL THEN 0
            WHEN dbo.fn_UPR_IsValidStreetNumber(COALESCE(ma.StreetNumber, sd.StreetNumber)) = 0 THEN 0
            WHEN dbo.fn_UPR_IsValidZipCode(COALESCE(ma.ZipCode, sd.ZipCode)) = 0 THEN 0
            ELSE 1
        END,
        N'ADDRESS_MASTER', N'MEDIUM', N'AddressNormalized'
    FROM #MA ma
    OUTER APPLY (
        SELECT TOP 1 sd.*
        FROM #SDAT sd
        WHERE ma.MasterAddressAccount IS NOT NULL
          AND sd.SDATAccountNumber = ma.MasterAddressAccount
        ORDER BY sd.KdatRecordID
    ) sd
    WHERE NOT EXISTS (
        SELECT 1 FROM #MaSdBest ms WHERE ms.MasterAddressID = ma.MasterAddressID
    );

    /* 4c. SDAT only — not paired to AddressMaster */
    INSERT INTO #Work (
        MasterAddressID, KdatRecordID, MasterAddressAccount, SDATAccountNumber, ParcelID,
        StreetNumber, StreetName, StreetType, Unit,
        City, [State], ZipCode, PropertyType,
        OwnerName, YearBuilt, DwellingUnits, Latitude, Longitude,
        NormalizedStreetAddress, NormalizedFullAddress, HasRequiredAddress,
        MatchSource, IncomingMatchConfidence, IncomingMatchMethod
    )
    SELECT
        NULL, sd.KdatRecordID, sd.MasterAddressAccount, sd.SDATAccountNumber, sd.ParcelID,
        sd.StreetNumber, sd.StreetName, sd.StreetType,
        CAST(NULL AS NVARCHAR(20)),  /* SDAT has no Unit */
        sd.City, sd.[State], sd.ZipCode,
        @DefaultSdatPropertyType,  /* SDAT-only → default CONDO */
        CONVERT(NVARCHAR(200), sd.OwnerName),
        TRY_CONVERT(INT, sd.YearBuilt),
        TRY_CONVERT(INT, sd.DwellingUnits),
        sd.Latitude, sd.Longitude,
        sd.NormalizedStreetAddress, sd.NormalizedFullAddress, sd.HasRequiredAddress,
        N'KDAT', N'MEDIUM', N'AddressNormalized'
    FROM #SDAT sd
    WHERE NOT EXISTS (
        SELECT 1 FROM #MaSdBest ms WHERE ms.KdatRecordID = sd.KdatRecordID
    );

    SET @IncomingUnifiedRows = (SELECT COUNT(*) FROM #Work);

    /* ========================================================================
       5. INSERT UPROPERTYRECORDS (idempotent - no duplicates)
       ======================================================================== */
    IF OBJECT_ID('tempdb..#UPRMap') IS NOT NULL DROP TABLE #UPRMap;
    CREATE TABLE #UPRMap (
        WorkKey               INT IDENTITY(1,1) PRIMARY KEY,
        UPropertyRecordsID     INT NULL,
        MasterAddressID       INT NULL,
        KdatRecordID          INT NULL,
        MatchSource           NVARCHAR(30) NOT NULL,
        IsNew                 BIT NOT NULL DEFAULT 0,
        HasRequiredAddress    BIT NOT NULL,
        SDATAccountNumber     NVARCHAR(50) NULL,
        ParcelID              NVARCHAR(50) NULL,
        NormalizedFullAddress NVARCHAR(300) NOT NULL,
        Unit                  NVARCHAR(20) NULL  /* MA only — dbo.Unit, not UPR */
    );

    IF OBJECT_ID('tempdb..#UprCandidate') IS NOT NULL DROP TABLE #UprCandidate;

    SELECT
        w.MasterAddressID, w.KdatRecordID, w.MatchSource, w.HasRequiredAddress,
        w.SDATAccountNumber, w.ParcelID, w.OwnerName,
        /* UPR requires a real source account — no synthetic MA-/KDAT- keys */
        EffectiveSDATAccountNumber = NULLIF(
            LTRIM(RTRIM(COALESCE(w.SDATAccountNumber, w.MasterAddressAccount))), N''),
        /* Real parcel required for UPR — no synthetic parcel IDs */
        EffectiveParcelID = NULLIF(LTRIM(RTRIM(w.ParcelID)), N''),
        EffectiveStreetNumber = LEFT(NULLIF(dbo.fn_UPR_NormalizeStreetNumber(w.StreetNumber), N''), 20),
        EffectiveStreetName   = LEFT(NULLIF(UPPER(LTRIM(RTRIM(w.StreetName))), N''), 100),
        EffectiveStreetType   = LEFT(COALESCE(NULLIF(UPPER(LTRIM(RTRIM(w.StreetType))), N''), N'UNK'), 4),
        EffectiveCity         = LEFT(NULLIF(UPPER(LTRIM(RTRIM(w.City))), N''), 100),
        EffectiveZipCode      = dbo.fn_UPR_NormalizeZipCode(w.ZipCode),
        EffectiveState        = dbo.fn_UPR_NormalizeState(w.[State], @DefaultState),
        EffectiveNormalizedStreetAddress = LEFT(
            COALESCE(
                NULLIF(LTRIM(RTRIM(w.NormalizedStreetAddress)), N''),
                NULLIF(LTRIM(RTRIM(w.NormalizedFullAddress)), N'')
            ), 100),
        EffectiveNormalizedFulldAddress  = LEFT(
            COALESCE(
                NULLIF(LTRIM(RTRIM(w.NormalizedFullAddress)), N''),
                NULLIF(LTRIM(RTRIM(w.NormalizedStreetAddress)), N''),
                CONCAT(
                    LEFT(NULLIF(dbo.fn_UPR_NormalizeStreetNumber(w.StreetNumber), N''), 20), N' ',
                    LEFT(NULLIF(UPPER(LTRIM(RTRIM(w.StreetName))), N''), 100), N' ',
                    LEFT(COALESCE(NULLIF(UPPER(LTRIM(RTRIM(w.StreetType))), N''), N'UNK'), 4), N' ',
                    LEFT(NULLIF(UPPER(LTRIM(RTRIM(w.City))), N''), 100), N' ',
                    dbo.fn_UPR_NormalizeZipCode(w.ZipCode)
                )
            ), 100),
        EffectiveOwnerName    = LEFT(NULLIF(LTRIM(RTRIM(w.OwnerName)), N''), 100),
        EffectiveLatitude     = w.Latitude,
        EffectiveLongitude    = w.Longitude,
        EffectivePropertyType = CASE UPPER(LTRIM(RTRIM(ISNULL(w.PropertyType, N''))))
            WHEN N'APT'   THEN N'APT'
            WHEN N'CONDO' THEN N'CONDO'
            WHEN N'TH'    THEN N'TH'
            WHEN N'MULTI' THEN N'MULTI'
            WHEN N'SF'    THEN N'SF'
            WHEN N'LAND'  THEN N'LAND'
            WHEN N'MIXED' THEN N'MIXED'
            ELSE @DefaultSdatPropertyType
        END,
        IsEligibleForUpr = CASE
            WHEN NULLIF(LTRIM(RTRIM(COALESCE(w.ParcelID, N''))), N'') IS NULL THEN 0
            WHEN NULLIF(LTRIM(RTRIM(COALESCE(w.SDATAccountNumber, w.MasterAddressAccount, N''))), N'') IS NULL THEN 0
            WHEN dbo.fn_UPR_IsValidStreetNumber(w.StreetNumber) = 0 THEN 0
            WHEN dbo.fn_UPR_IsValidZipCode(w.ZipCode) = 0 THEN 0
            WHEN NULLIF(UPPER(LTRIM(RTRIM(w.StreetName))), N'') IS NULL THEN 0
            WHEN NULLIF(UPPER(LTRIM(RTRIM(w.City))), N'') IS NULL THEN 0
            ELSE 1
        END
    INTO #UprCandidate
    FROM #Work w;

    IF OBJECT_ID('tempdb..#ReviewPending') IS NOT NULL DROP TABLE #ReviewPending;
    CREATE TABLE #ReviewPending (
        MasterAddressID            INT NULL,
        KdatRecordID               INT NULL,
        MatchSource                NVARCHAR(30) NOT NULL,
        NormalizedIncomingAddress  NVARCHAR(300) NOT NULL,
        ParcelID                   NVARCHAR(50) NULL,
        SDATAccountNumber          NVARCHAR(50) NULL,
        ReasonForNoMatch           NVARCHAR(255) NOT NULL,
        ReviewDetail               NVARCHAR(255) NOT NULL,
        StreetNumber               NVARCHAR(20) NULL,
        StreetName                 NVARCHAR(100) NULL,
        StreetType                 NVARCHAR(4) NULL,
        ZipCode                    NVARCHAR(10) NULL,
        EffectiveSDATAccountNumber NVARCHAR(50) NOT NULL
    );

    /* Review_Q staging — invalid identification only (client rule) */
    INSERT INTO #ReviewPending (
        MasterAddressID, KdatRecordID, MatchSource, NormalizedIncomingAddress,
        ParcelID, SDATAccountNumber, ReasonForNoMatch, ReviewDetail,
        StreetNumber, StreetName, StreetType, ZipCode, EffectiveSDATAccountNumber
    )
    SELECT
        w.MasterAddressID, w.KdatRecordID, w.MatchSource,
        COALESCE(w.NormalizedFullAddress, w.NormalizedStreetAddress, N'UNKNOWN'),
        w.ParcelID, w.SDATAccountNumber,
        CASE
            WHEN NULLIF(LTRIM(RTRIM(w.ParcelID)), N'') IS NULL THEN N'NO_PARCEL_MATCH'
            WHEN NULLIF(LTRIM(RTRIM(COALESCE(w.SDATAccountNumber, w.MasterAddressAccount))), N'') IS NULL THEN N'NO_SDAT_MATCH'
            WHEN dbo.fn_UPR_IsValidStreetNumber(w.StreetNumber) = 0 THEN N'SOURCE_RECORD_ERROR'
            WHEN dbo.fn_UPR_IsValidZipCode(w.ZipCode) = 0 THEN N'SOURCE_RECORD_ERROR'
            WHEN NULLIF(UPPER(LTRIM(RTRIM(w.StreetName))), N'') IS NULL THEN N'INSUFFICIENT_DATA'
            WHEN NULLIF(UPPER(LTRIM(RTRIM(w.City))), N'') IS NULL THEN N'INSUFFICIENT_DATA'
            WHEN w.HasRequiredAddress = 0 THEN N'INSUFFICIENT_DATA'
            ELSE N'INSUFFICIENT_DATA'
        END,
        CASE
            WHEN NULLIF(LTRIM(RTRIM(w.ParcelID)), N'') IS NULL THEN N'Missing parcel ID'
            WHEN NULLIF(LTRIM(RTRIM(COALESCE(w.SDATAccountNumber, w.MasterAddressAccount))), N'') IS NULL THEN N'Missing account number'
            WHEN dbo.fn_UPR_IsValidStreetNumber(w.StreetNumber) = 0 THEN N'Invalid street number'
            WHEN dbo.fn_UPR_IsValidZipCode(w.ZipCode) = 0 THEN N'Invalid zip code'
            WHEN NULLIF(UPPER(LTRIM(RTRIM(w.StreetName))), N'') IS NULL THEN N'Missing street name'
            WHEN NULLIF(UPPER(LTRIM(RTRIM(w.City))), N'') IS NULL THEN N'Missing city'
            WHEN w.HasRequiredAddress = 0 THEN N'Invalid or incomplete address'
            ELSE N'Insufficient identification data'
        END,
        w.StreetNumber, w.StreetName, w.StreetType, w.ZipCode,
        COALESCE(
            NULLIF(LTRIM(RTRIM(COALESCE(w.SDATAccountNumber, w.MasterAddressAccount))), N''),
            CASE WHEN w.MasterAddressID IS NOT NULL
                 THEN CONCAT(N'MA-', CONVERT(NVARCHAR(20), w.MasterAddressID)) END,
            CASE WHEN w.KdatRecordID IS NOT NULL
                 THEN CONCAT(N'KDAT-', CONVERT(NVARCHAR(20), w.KdatRecordID)) END,
            CONCAT(N'ADDR-', CONVERT(NVARCHAR(20), ABS(CHECKSUM(
                COALESCE(NULLIF(w.NormalizedFullAddress, N''), w.NormalizedStreetAddress, N'UNKNOWN')
            ))))
        )
    FROM #Work w
    INNER JOIN #UprCandidate c
        ON (w.MasterAddressID IS NOT NULL AND c.MasterAddressID = w.MasterAddressID)
        OR (w.KdatRecordID IS NOT NULL AND c.KdatRecordID = w.KdatRecordID)
    WHERE c.IsEligibleForUpr = 0;

    SET @UprCountBefore = (SELECT COUNT(*) FROM dbo.UPROPERTYRECORDS);

    IF OBJECT_ID('tempdb..#UprMergeRanked') IS NOT NULL DROP TABLE #UprMergeRanked;

    SELECT
        c.*,
        ROW_NUMBER() OVER (
            PARTITION BY COALESCE(UPPER(c.EffectiveParcelID), c.EffectiveSDATAccountNumber)
            ORDER BY CASE c.MatchSource WHEN N'BOTH' THEN 1 WHEN N'KDAT' THEN 2 ELSE 3 END,
                     c.MasterAddressID, c.KdatRecordID
        ) AS PropertyRn
    INTO #UprMergeRanked
    FROM #UprCandidate c
    WHERE c.IsEligibleForUpr = 1;

    INSERT INTO #ReviewPending (
        MasterAddressID, KdatRecordID, MatchSource, NormalizedIncomingAddress,
        ParcelID, SDATAccountNumber, ReasonForNoMatch, ReviewDetail,
        StreetNumber, StreetName, StreetType, ZipCode, EffectiveSDATAccountNumber
    )
    SELECT
        w.MasterAddressID, w.KdatRecordID, w.MatchSource,
        COALESCE(w.NormalizedFullAddress, w.NormalizedStreetAddress, N'UNKNOWN'),
        w.ParcelID, w.SDATAccountNumber,
        N'AMBIGUOUS_CANDIDATES', N'Duplicate property key in batch',
        w.StreetNumber, w.StreetName, w.StreetType, w.ZipCode,
        r.EffectiveSDATAccountNumber
    FROM #UprMergeRanked r
    INNER JOIN #Work w
        ON (w.MasterAddressID IS NOT NULL AND w.MasterAddressID = r.MasterAddressID)
        OR (w.KdatRecordID IS NOT NULL AND w.KdatRecordID = r.KdatRecordID)
    WHERE r.PropertyRn > 1;

    IF OBJECT_ID('tempdb..#UprMergeSrc') IS NOT NULL DROP TABLE #UprMergeSrc;

    SELECT
        r.MasterAddressID, r.KdatRecordID, r.MatchSource, r.HasRequiredAddress,
        r.SDATAccountNumber, r.ParcelID, r.OwnerName,
        r.EffectiveSDATAccountNumber, r.EffectiveParcelID,
        r.EffectiveStreetNumber, r.EffectiveStreetName, r.EffectiveStreetType,
        r.EffectiveCity, r.EffectiveState, r.EffectiveZipCode,
        r.EffectiveNormalizedStreetAddress, r.EffectiveNormalizedFulldAddress,
        r.EffectiveLatitude, r.EffectiveLongitude, r.EffectiveOwnerName, r.EffectivePropertyType
    INTO #UprMergeSrc
    FROM #UprMergeRanked r
    WHERE r.PropertyRn = 1;

    /* Align account key to existing UPR by parcel (idempotent re-run) */
    UPDATE s
    SET s.EffectiveSDATAccountNumber = e.SDATAccountNumber
    FROM #UprMergeSrc s
    INNER JOIN (
        SELECT ParcelID, SDATAccountNumber,
            ROW_NUMBER() OVER (PARTITION BY ParcelID ORDER BY UPropertyRecordsID) AS UprParcelRn
        FROM dbo.UPROPERTYRECORDS
        WHERE ParcelID IS NOT NULL
    ) e ON e.ParcelID = s.EffectiveParcelID AND e.UprParcelRn = 1
    WHERE s.EffectiveParcelID IS NOT NULL;

    IF OBJECT_ID('tempdb..#UprMergeFinal') IS NOT NULL DROP TABLE #UprMergeFinal;

    IF OBJECT_ID('tempdb..#UprAcctRanked') IS NOT NULL DROP TABLE #UprAcctRanked;

    SELECT
        s.*,
        ROW_NUMBER() OVER (
            PARTITION BY s.EffectiveSDATAccountNumber
            ORDER BY CASE s.MatchSource WHEN N'BOTH' THEN 1 WHEN N'KDAT' THEN 2 ELSE 3 END,
                     s.MasterAddressID, s.KdatRecordID
        ) AS AcctRn
    INTO #UprAcctRanked
    FROM #UprMergeSrc s;

    INSERT INTO #ReviewPending (
        MasterAddressID, KdatRecordID, MatchSource, NormalizedIncomingAddress,
        ParcelID, SDATAccountNumber, ReasonForNoMatch, ReviewDetail,
        StreetNumber, StreetName, StreetType, ZipCode, EffectiveSDATAccountNumber
    )
    SELECT
        w.MasterAddressID, w.KdatRecordID, w.MatchSource,
        COALESCE(w.NormalizedFullAddress, w.NormalizedStreetAddress, N'UNKNOWN'),
        w.ParcelID, w.SDATAccountNumber,
        N'AMBIGUOUS_CANDIDATES', N'Duplicate account key in batch',
        w.StreetNumber, w.StreetName, w.StreetType, w.ZipCode,
        r.EffectiveSDATAccountNumber
    FROM #UprAcctRanked r
    INNER JOIN #Work w
        ON (w.MasterAddressID IS NOT NULL AND w.MasterAddressID = r.MasterAddressID)
        OR (w.KdatRecordID IS NOT NULL AND w.KdatRecordID = r.KdatRecordID)
    WHERE r.AcctRn > 1
      AND NOT EXISTS (
          SELECT 1
          FROM #ReviewPending rp
          WHERE ISNULL(rp.MasterAddressID, -1) = ISNULL(w.MasterAddressID, -1)
            AND ISNULL(rp.KdatRecordID, -1) = ISNULL(w.KdatRecordID, -1)
      );

    SELECT
        MasterAddressID, KdatRecordID, MatchSource, HasRequiredAddress,
        SDATAccountNumber, ParcelID, OwnerName,
        EffectiveSDATAccountNumber, EffectiveParcelID,
        EffectiveStreetNumber, EffectiveStreetName, EffectiveStreetType,
        EffectiveCity, EffectiveState, EffectiveZipCode,
        EffectiveNormalizedStreetAddress, EffectiveNormalizedFulldAddress,
        EffectiveLatitude, EffectiveLongitude, EffectiveOwnerName, EffectivePropertyType
    INTO #UprMergeFinal
    FROM #UprAcctRanked
    WHERE AcctRn = 1;

    DROP TABLE #UprAcctRanked;

    IF OBJECT_ID('tempdb..#UprMergeAddr') IS NOT NULL DROP TABLE #UprMergeAddr;

    SELECT
        s.*,
        ROW_NUMBER() OVER (
            PARTITION BY s.EffectiveStreetNumber, s.EffectiveStreetName, s.EffectiveStreetType, s.EffectiveZipCode
            ORDER BY CASE s.MatchSource WHEN N'BOTH' THEN 1 WHEN N'KDAT' THEN 2 ELSE 3 END,
                     s.MasterAddressID, s.KdatRecordID
        ) AS AddrRn
    INTO #UprMergeAddr
    FROM #UprMergeFinal s;

    INSERT INTO #ReviewPending (
        MasterAddressID, KdatRecordID, MatchSource, NormalizedIncomingAddress,
        ParcelID, SDATAccountNumber, ReasonForNoMatch, ReviewDetail,
        StreetNumber, StreetName, StreetType, ZipCode, EffectiveSDATAccountNumber
    )
    SELECT
        w.MasterAddressID, w.KdatRecordID, w.MatchSource,
        COALESCE(w.NormalizedFullAddress, w.NormalizedStreetAddress, N'UNKNOWN'),
        w.ParcelID, w.SDATAccountNumber,
        N'AMBIGUOUS_CANDIDATES', N'Duplicate address key in batch',
        w.StreetNumber, w.StreetName, w.StreetType, w.ZipCode,
        r.EffectiveSDATAccountNumber
    FROM #UprMergeAddr r
    INNER JOIN #Work w
        ON (w.MasterAddressID IS NOT NULL AND w.MasterAddressID = r.MasterAddressID)
        OR (w.KdatRecordID IS NOT NULL AND w.KdatRecordID = r.KdatRecordID)
    WHERE r.AddrRn > 1
      AND NOT EXISTS (
          SELECT 1
          FROM #ReviewPending rp
          WHERE ISNULL(rp.MasterAddressID, -1) = ISNULL(w.MasterAddressID, -1)
            AND ISNULL(rp.KdatRecordID, -1) = ISNULL(w.KdatRecordID, -1)
      );

    TRUNCATE TABLE #UprMergeSrc;

    INSERT INTO #UprMergeSrc (
        MasterAddressID, KdatRecordID, MatchSource, HasRequiredAddress,
        SDATAccountNumber, ParcelID, OwnerName,
        EffectiveSDATAccountNumber, EffectiveParcelID,
        EffectiveStreetNumber, EffectiveStreetName, EffectiveStreetType,
        EffectiveCity, EffectiveState, EffectiveZipCode,
        EffectiveNormalizedStreetAddress, EffectiveNormalizedFulldAddress,
        EffectiveLatitude, EffectiveLongitude, EffectiveOwnerName, EffectivePropertyType
    )
    SELECT
        MasterAddressID, KdatRecordID, MatchSource, HasRequiredAddress,
        SDATAccountNumber, ParcelID, OwnerName,
        EffectiveSDATAccountNumber, EffectiveParcelID,
        EffectiveStreetNumber, EffectiveStreetName, EffectiveStreetType,
        EffectiveCity, EffectiveState, EffectiveZipCode,
        EffectiveNormalizedStreetAddress, EffectiveNormalizedFulldAddress,
        EffectiveLatitude, EffectiveLongitude, EffectiveOwnerName, EffectivePropertyType
    FROM #UprMergeAddr
    WHERE AddrRn = 1;
    DROP TABLE #UprMergeAddr;
    DROP TABLE #UprMergeFinal;

    SET @UprEligibleRows = (SELECT COUNT(*) FROM #UprMergeSrc);

    SET @RowsIncompleteData = (
        SELECT COUNT(*)
        FROM #ReviewPending rp
        WHERE rp.ReasonForNoMatch IN (
            N'NO_PARCEL_MATCH', N'NO_SDAT_MATCH', N'INSUFFICIENT_DATA', N'SOURCE_RECORD_ERROR'
        )
    );
    SET @RowsReviewDuplicate = (
        SELECT COUNT(*)
        FROM #ReviewPending rp
        WHERE rp.ReasonForNoMatch = N'AMBIGUOUS_CANDIDATES'
    );

    MERGE dbo.UPROPERTYRECORDS AS upr
    USING #UprMergeSrc AS s
    ON upr.SDATAccountNumber = s.EffectiveSDATAccountNumber
    WHEN MATCHED THEN UPDATE SET
        upr.ParcelID          = CASE
            WHEN NULLIF(s.EffectiveParcelID, N'') IS NOT NULL
                 AND EXISTS (
                     SELECT 1
                     FROM dbo.UPROPERTYRECORDS p
                     WHERE p.ParcelID = s.EffectiveParcelID
                       AND p.UPropertyRecordsID <> upr.UPropertyRecordsID
                 ) THEN upr.ParcelID
            ELSE COALESCE(
                NULLIF(LTRIM(RTRIM(s.ParcelID)), N''),
                upr.ParcelID,
                s.EffectiveParcelID
            )
        END,
        upr.Owner             = LEFT(COALESCE(upr.Owner, s.EffectiveOwnerName), 100),
        upr.Latitude          = COALESCE(upr.Latitude, s.EffectiveLatitude),
        upr.Longitude         = COALESCE(upr.Longitude, s.EffectiveLongitude),
        upr.PropertyTypeCode  = COALESCE(
            NULLIF(LTRIM(RTRIM(upr.PropertyTypeCode)), N''),
            s.EffectivePropertyType,
            @DefaultSdatPropertyType
        ),
        upr.UpdatedDate       = @Now,
        upr.UpdatedBy         = @RunUser
    WHEN NOT MATCHED THEN INSERT (
        SDATAccountNumber, ParcelID, PropertyName, Owner,
        StreetNumber, StreetName, StreetType,
        City, [State], ZipCode, NormalizedStreetAddress, NormalizedFulldAddress,
        Latitude, Longitude,
        PropertyTypeCode, PropertyStatusCode, IsActive,
        CreatedDate, CreatedBy, UpdatedDate, UpdatedBy
    ) VALUES (
        s.EffectiveSDATAccountNumber, s.EffectiveParcelID, NULL, s.EffectiveOwnerName,
        s.EffectiveStreetNumber, s.EffectiveStreetName, s.EffectiveStreetType,
        s.EffectiveCity, s.EffectiveState, s.EffectiveZipCode,
        s.EffectiveNormalizedStreetAddress, s.EffectiveNormalizedFulldAddress,
        s.EffectiveLatitude, s.EffectiveLongitude,
        s.EffectivePropertyType, N'ACTIVE', 1,
        @Now, @RunUser, @Now, @RunUser
    );

    SET @UprMergeRowsAffected = @@ROWCOUNT;
    SET @UPRInserted = (
        SELECT COUNT(*) FROM dbo.UPROPERTYRECORDS
        WHERE CreatedDate >= @Now AND CreatedBy = @RunUser
    );
    SET @UPRUpdated = @UprMergeRowsAffected - @UPRInserted;

    /* Map MERGE winners only (#UprMergeSrc) — duplicate losers stay in Review_Q, not XREF MATCH */
    INSERT INTO #UPRMap (UPropertyRecordsID, MasterAddressID, KdatRecordID, MatchSource, IsNew, HasRequiredAddress, SDATAccountNumber, ParcelID, NormalizedFullAddress, Unit)
    SELECT
        upr.UPropertyRecordsID,
        s.MasterAddressID,
        s.KdatRecordID,
        s.MatchSource,
        CASE WHEN upr.CreatedDate >= @Now AND upr.CreatedBy = @RunUser THEN 1 ELSE 0 END,
        s.HasRequiredAddress,
        s.SDATAccountNumber,
        s.ParcelID,
        COALESCE(w.NormalizedFullAddress, w.NormalizedStreetAddress, N'UNKNOWN'),
        w.Unit
    FROM #UprMergeSrc s
    INNER JOIN dbo.UPROPERTYRECORDS upr
        ON upr.SDATAccountNumber = s.EffectiveSDATAccountNumber
    OUTER APPLY (
        SELECT TOP 1
            w.NormalizedFullAddress,
            w.NormalizedStreetAddress,
            w.Unit
        FROM #Work w
        WHERE (s.MasterAddressID IS NOT NULL AND w.MasterAddressID = s.MasterAddressID)
           OR (s.KdatRecordID IS NOT NULL AND w.KdatRecordID = s.KdatRecordID)
        ORDER BY
            CASE
                WHEN s.MasterAddressID IS NOT NULL AND w.MasterAddressID = s.MasterAddressID
                 AND s.KdatRecordID IS NOT NULL AND w.KdatRecordID = s.KdatRecordID THEN 1
                WHEN s.MasterAddressID IS NOT NULL AND w.MasterAddressID = s.MasterAddressID THEN 2
                ELSE 3
            END
    ) w;

    /* Status history for newly created UPR records only (idempotent re-runs) */
    INSERT INTO dbo.UPRSTATUSHISTORY (
        UPropertyRecordsID, SDATAccountNumber, OldStatusCode, NewStatusCode,
        ChangeReason, ParcelID, Owner, StreetNumber, StreetName, StreetType,
        City, ZipCode, PropertyTypeCode, ChangeSource, ChangedBy, ChangedDate,
        LevelInd, BuildingID, UnitNumber, OwnershipStartDate
    )
    SELECT
        m.UPropertyRecordsID, upr.SDATAccountNumber,
        NULL, COALESCE(upr.PropertyStatusCode, N'ACTIVE'),
        N'Initial load - new UPR record',
        upr.ParcelID, upr.Owner, upr.StreetNumber, upr.StreetName,
        COALESCE(NULLIF(LTRIM(RTRIM(upr.StreetType)), N''), N'UNK'),
        upr.City, upr.ZipCode, upr.PropertyTypeCode,
        N'UPR_LOAD', @RunUser, @Now,
        0, 0, N'N/A', @Now  /* property-level snapshot — client table requires these NOT NULL */
    FROM #UPRMap m
    INNER JOIN dbo.UPROPERTYRECORDS upr ON upr.UPropertyRecordsID = m.UPropertyRecordsID
    WHERE m.IsNew = 1;

    SET @StatusHistoryInserted = @@ROWCOUNT;

    /* Collapse duplicate #UPRMap rows before XREF writes */
    ;WITH UprMapRanked AS (
        SELECT
            m.WorkKey,
            ROW_NUMBER() OVER (
                PARTITION BY
                    m.UPropertyRecordsID,
                    ISNULL(CAST(m.MasterAddressID AS NVARCHAR(20)), N'-'),
                    ISNULL(CAST(m.KdatRecordID AS NVARCHAR(20)), N'-')
                ORDER BY m.WorkKey
            ) AS MapRn
        FROM #UPRMap m
    )
    DELETE m
    FROM #UPRMap m
    INNER JOIN UprMapRanked r ON r.WorkKey = m.WorkKey
    WHERE r.MapRn > 1;

    /* ========================================================================
       6. WRITE INCOMING SOURCE XREF (AddressMaster / SDAT)
       NOT EXISTS matches client UX: SourceSystem + SourceRecordID + EntityType
       (active rows only). Dedupe source rows before insert.
       ======================================================================== */
    ;WITH MaXrefSrc AS (
        SELECT
            m.UPropertyRecordsID,
            SourceSystemCode = N'ADDRESS_MASTER',
            SourceRecordID   = CONVERT(NVARCHAR(100), m.MasterAddressID),
            SourceEntityType = N'MasterAddress',
            ROW_NUMBER() OVER (
                PARTITION BY CONVERT(NVARCHAR(100), m.MasterAddressID)
                ORDER BY m.UPropertyRecordsID
            ) AS SrcRn
        FROM #UPRMap m
        WHERE m.MasterAddressID IS NOT NULL
    )
    INSERT INTO dbo.UPROPERTYRECORDS_XREF (
        UPropertyRecordsID, SourceSystemCode, SourceRecordID, SourceEntityType,
        MatchMethodCode, MatchResult, MatchConfidence, ProcessingStatus,
        IsActive, EffectiveStartDate, CreatedDate, UpdatedDate, CreatedBy
    )
    SELECT
        s.UPropertyRecordsID, s.SourceSystemCode, s.SourceRecordID, s.SourceEntityType,
        N'AddressNormalized', N'MATCH', N'HIGH', N'PROCESSED',
        1, @Now, @Now, @Now, @RunUser
    FROM MaXrefSrc s
    WHERE s.SrcRn = 1
      AND NOT EXISTS (
          SELECT 1
          FROM dbo.UPROPERTYRECORDS_XREF x
          WHERE x.SourceSystemCode = s.SourceSystemCode
            AND x.SourceRecordID = s.SourceRecordID
            AND x.SourceEntityType = s.SourceEntityType
            AND x.IsActive = 1
      );

    SET @MasterAddressXrefInserted = @@ROWCOUNT;

    ;WITH KdatXrefSrc AS (
        SELECT
            m.UPropertyRecordsID,
            SourceSystemCode = N'KDAT',
            SourceRecordID   = CONVERT(NVARCHAR(100), m.KdatRecordID),
            SourceEntityType = N'SDATProperty',
            ROW_NUMBER() OVER (
                PARTITION BY CONVERT(NVARCHAR(100), m.KdatRecordID)
                ORDER BY m.UPropertyRecordsID
            ) AS SrcRn
        FROM #UPRMap m
        WHERE m.KdatRecordID IS NOT NULL
    )
    INSERT INTO dbo.UPROPERTYRECORDS_XREF (
        UPropertyRecordsID, SourceSystemCode, SourceRecordID, SourceEntityType,
        MatchMethodCode, MatchResult, MatchConfidence, ProcessingStatus,
        IsActive, EffectiveStartDate, CreatedDate, UpdatedDate, CreatedBy
    )
    SELECT
        s.UPropertyRecordsID, s.SourceSystemCode, s.SourceRecordID, s.SourceEntityType,
        N'AddressNormalized', N'MATCH', N'HIGH', N'PROCESSED',
        1, @Now, @Now, @Now, @RunUser
    FROM KdatXrefSrc s
    WHERE s.SrcRn = 1
      AND NOT EXISTS (
          SELECT 1
          FROM dbo.UPROPERTYRECORDS_XREF x
          WHERE x.SourceSystemCode = s.SourceSystemCode
            AND x.SourceRecordID = s.SourceRecordID
            AND x.SourceEntityType = s.SourceEntityType
            AND x.IsActive = 1
      );

    SET @SDATXrefInserted = @@ROWCOUNT;

    /* ========================================================================
       6b. INCOMING XREF FOR REVIEW-BOUND ROWS → UPRMATCHREVIEW_Q
           DDL: UPRMatchReviewID is IDENTITY (omit from INSERT);
           UPropertyRecords_XrefID NOT NULL FK — create rejected incoming XREF first.
       ======================================================================== */
    DECLARE @ReviewXrefOut TABLE (
        UPropertyRecords_XrefID INT NOT NULL,
        MasterAddressID         INT NULL,
        KdatRecordID            INT NULL,
        ReasonForNoMatch        NVARCHAR(255) NOT NULL
    );

    IF OBJECT_ID('tempdb..#ReviewXrefStage') IS NOT NULL DROP TABLE #ReviewXrefStage;
    CREATE TABLE #ReviewXrefStage (
        MasterAddressID     INT NULL,
        KdatRecordID        INT NULL,
        ReasonForNoMatch    NVARCHAR(255) NOT NULL,
        ReviewDetail        NVARCHAR(255) NOT NULL,
        UPropertyRecordsID  INT NOT NULL,
        SourceSystemCode    NVARCHAR(30) NOT NULL,
        SourceRecordID      NVARCHAR(100) NOT NULL,
        SourceEntityType    NVARCHAR(50) NOT NULL
    );

    INSERT INTO #ReviewXrefStage (
        MasterAddressID, KdatRecordID, ReasonForNoMatch, ReviewDetail,
        UPropertyRecordsID, SourceSystemCode, SourceRecordID, SourceEntityType
    )
    SELECT
        rp.MasterAddressID,
        rp.KdatRecordID,
        rp.ReasonForNoMatch,
        rp.ReviewDetail,
        anchor.UPropertyRecordsID,
        CASE WHEN rp.KdatRecordID IS NOT NULL THEN N'KDAT' ELSE N'ADDRESS_MASTER' END,
        CASE WHEN rp.KdatRecordID IS NOT NULL
             THEN CONVERT(NVARCHAR(100), rp.KdatRecordID)
             ELSE CONVERT(NVARCHAR(100), rp.MasterAddressID) END,
        CASE WHEN rp.KdatRecordID IS NOT NULL THEN N'SDATProperty' ELSE N'MasterAddress' END
    FROM #ReviewPending rp
    CROSS APPLY (
        SELECT TOP 1 x.UPropertyRecordsID
        FROM (
            SELECT win_map.UPropertyRecordsID, 1 AS MatchPriority
            FROM #UprCandidate loser
            INNER JOIN #UprMergeRanked winner
                ON winner.PropertyRn = 1
               AND winner.IsEligibleForUpr = 1
               AND winner.EffectiveStreetNumber = loser.EffectiveStreetNumber
               AND winner.EffectiveStreetName = loser.EffectiveStreetName
               AND winner.EffectiveStreetType = loser.EffectiveStreetType
               AND winner.EffectiveZipCode = loser.EffectiveZipCode
            INNER JOIN #UPRMap win_map
                ON (winner.MasterAddressID IS NOT NULL AND win_map.MasterAddressID = winner.MasterAddressID)
                OR (winner.KdatRecordID IS NOT NULL AND win_map.KdatRecordID = winner.KdatRecordID)
            WHERE rp.ReasonForNoMatch IN (N'NO_ADDRESS_MATCH', N'AMBIGUOUS_CANDIDATES', N'NO_PARCEL_MATCH')
              AND (
                    (loser.MasterAddressID IS NOT NULL AND loser.MasterAddressID = rp.MasterAddressID)
                 OR (loser.KdatRecordID IS NOT NULL AND loser.KdatRecordID = rp.KdatRecordID)
              )
              AND loser.MatchSource = rp.MatchSource

            UNION ALL

            SELECT upr.UPropertyRecordsID, 2
            FROM dbo.UPROPERTYRECORDS upr
            WHERE upr.SDATAccountNumber = rp.EffectiveSDATAccountNumber

            UNION ALL

            SELECT upr.UPropertyRecordsID, 3
            FROM dbo.UPROPERTYRECORDS upr
            WHERE rp.SDATAccountNumber IS NOT NULL
              AND upr.SDATAccountNumber = rp.SDATAccountNumber

            UNION ALL

            SELECT upr.UPropertyRecordsID, 4
            FROM dbo.UPROPERTYRECORDS upr
            WHERE rp.ParcelID IS NOT NULL
              AND upr.ParcelID = rp.ParcelID

            UNION ALL

            SELECT upr.UPropertyRecordsID, 5
            FROM dbo.UPROPERTYRECORDS upr
            WHERE upr.StreetNumber = LEFT(NULLIF(dbo.fn_UPR_NormalizeStreetNumber(rp.StreetNumber), N''), 20)
              AND upr.StreetName = LEFT(NULLIF(UPPER(LTRIM(RTRIM(rp.StreetName))), N''), 100)
              AND upr.StreetType = LEFT(COALESCE(NULLIF(UPPER(LTRIM(RTRIM(rp.StreetType))), N''), N'UNK'), 4)
              AND upr.ZipCode = dbo.fn_UPR_NormalizeZipCode(rp.ZipCode)
        ) x
        ORDER BY x.MatchPriority
    ) anchor
    WHERE anchor.UPropertyRecordsID IS NOT NULL;

    IF OBJECT_ID('tempdb..#ReviewXrefStageDeduped') IS NOT NULL DROP TABLE #ReviewXrefStageDeduped;

    SELECT
        MasterAddressID, KdatRecordID, ReasonForNoMatch, ReviewDetail,
        UPropertyRecordsID, SourceSystemCode, SourceRecordID, SourceEntityType
    INTO #ReviewXrefStageDeduped
    FROM (
        SELECT
            s.*,
            ROW_NUMBER() OVER (
                PARTITION BY s.UPropertyRecordsID, s.SourceSystemCode, s.SourceRecordID, s.SourceEntityType
                ORDER BY s.ReasonForNoMatch
            ) AS StageRn
        FROM #ReviewXrefStage s
    ) ranked
    WHERE StageRn = 1;

    DECLARE @ReviewXrefInserted TABLE (
        UPropertyRecords_XrefID INT NOT NULL,
        UPropertyRecordsID      INT NOT NULL,
        SourceSystemCode        NVARCHAR(30) NOT NULL,
        SourceRecordID          NVARCHAR(100) NOT NULL
    );

    INSERT INTO dbo.UPROPERTYRECORDS_XREF (
        UPropertyRecordsID, SourceSystemCode, SourceRecordID, SourceEntityType,
        MatchMethodCode, MatchResult, MatchConfidence, ProcessingStatus,
        IsActive, EffectiveStartDate, Notes, CreatedDate, UpdatedDate, CreatedBy
    )
    OUTPUT
        INSERTED.UPropertyRecords_XrefID,
        INSERTED.UPropertyRecordsID,
        INSERTED.SourceSystemCode,
        INSERTED.SourceRecordID
    INTO @ReviewXrefInserted
    SELECT
        src.UPropertyRecordsID, src.SourceSystemCode, src.SourceRecordID, src.SourceEntityType,
        N'AddressNormalized', N'REJECTED', N'NONE', N'PENDING_REVIEW',
        1, @Now, CONCAT(N'Review: ', src.ReviewDetail), @Now, @Now, @RunUser
    FROM #ReviewXrefStageDeduped src
    WHERE NOT EXISTS (
        SELECT 1
        FROM dbo.UPROPERTYRECORDS_XREF x
        WHERE x.SourceSystemCode = src.SourceSystemCode
          AND x.SourceRecordID = src.SourceRecordID
          AND x.SourceEntityType = src.SourceEntityType
          AND x.IsActive = 1
    );

    INSERT INTO @ReviewXrefOut (
        UPropertyRecords_XrefID, MasterAddressID, KdatRecordID, ReasonForNoMatch
    )
    SELECT
        i.UPropertyRecords_XrefID, s.MasterAddressID, s.KdatRecordID, s.ReasonForNoMatch
    FROM @ReviewXrefInserted i
    INNER JOIN #ReviewXrefStageDeduped s
        ON s.UPropertyRecordsID = i.UPropertyRecordsID
       AND s.SourceSystemCode = i.SourceSystemCode
       AND s.SourceRecordID = i.SourceRecordID;

    DROP TABLE #ReviewXrefStageDeduped;

    INSERT INTO dbo.UPRMATCHREVIEW_Q (
        UPropertyRecords_XrefID, IncomingSourceSystem, NormalizedIncomingAddress,
        ParcelID, SDATAccountNumber, ReasonForNoMatch, ReviewStatus
    )
    SELECT
        rx.UPropertyRecords_XrefID,
        rp.MatchSource,
        rp.NormalizedIncomingAddress,
        rp.ParcelID,
        rp.SDATAccountNumber,
        rp.ReasonForNoMatch,
        N'PENDING_REVIEW'
    FROM #ReviewPending rp
    INNER JOIN @ReviewXrefOut rx
        ON ISNULL(rx.MasterAddressID, -1) = ISNULL(rp.MasterAddressID, -1)
       AND ISNULL(rx.KdatRecordID, -1) = ISNULL(rp.KdatRecordID, -1)
       AND rx.ReasonForNoMatch = rp.ReasonForNoMatch
    WHERE NOT EXISTS (
        SELECT 1
        FROM dbo.UPRMATCHREVIEW_Q q
        WHERE q.UPropertyRecords_XrefID = rx.UPropertyRecords_XrefID
          AND q.ReasonForNoMatch = rp.ReasonForNoMatch
    );

    SET @ReviewIncomingInserted = @@ROWCOUNT;
    SET @RowsSentToReview = (SELECT COUNT(*) FROM #ReviewPending);

    /* ========================================================================
       7. MATCH EXTERNAL SYSTEMS — eProperty, CASE, MPDU, MULTIFAMILY
          Address/account match to UPR → XREF row (MATCH) for that system only.
          No external match does NOT affect UPR or Review_Q (valid UPR stays in UPR).
       ======================================================================== */
    IF OBJECT_ID('tempdb..#ExtMatch') IS NOT NULL DROP TABLE #ExtMatch;

    CREATE TABLE #ExtMatch (
        UPropertyRecordsID INT NOT NULL,
        SourceSystemCode   VARCHAR(30) NOT NULL,
        SourceRecordID     VARCHAR(100) NOT NULL,
        SourceEntityType   VARCHAR(50) NOT NULL,
        MatchMethodCode    VARCHAR(30) NOT NULL,
        MatchResult        NVARCHAR(30) NOT NULL,
        MatchConfidence    NVARCHAR(30) NOT NULL,
        ProcessingStatus   NVARCHAR(50) NOT NULL,
        Notes              VARCHAR(1000) NULL
    );

    IF OBJECT_ID('tempdb..#ExtAddr') IS NOT NULL DROP TABLE #ExtAddr;
    CREATE TABLE #ExtAddr (
        SourceSystemCode   VARCHAR(30)  NOT NULL,
        SourceRecordID     VARCHAR(100) NOT NULL,
        SourceEntityType   VARCHAR(50)  NOT NULL,
        TaxOrAccount       NVARCHAR(50) NULL,
        NormAddress        NVARCHAR(200) NOT NULL,
        NormFullAddress    NVARCHAR(300) NOT NULL
    );

    CREATE CLUSTERED INDEX IX_ExtAddr_System ON #ExtAddr (SourceSystemCode, NormAddress);
    CREATE NONCLUSTERED INDEX IX_ExtAddr_Full ON #ExtAddr (SourceSystemCode, NormFullAddress);

    SET @Sql = N'
    INSERT INTO #ExtAddr (SourceSystemCode, SourceRecordID, SourceEntityType, TaxOrAccount, NormAddress, NormFullAddress)
    SELECT N''eProperty'', CONVERT(VARCHAR(100), ep.PropertyID), N''Property'', ep.TaxID,
        dbo.fn_UPR_NormalizeAddressLine(ep.StreetAddress),
        dbo.fn_UPR_NormalizeFullAddressLine(ep.StreetAddress, ep.City, ep.ZipCode)
    FROM DHCA_LicensingAndRegistration.dbo.Property ep';
    EXEC sys.sp_executesql @Sql;

    SET @Sql = N'
    INSERT INTO #ExtAddr (SourceSystemCode, SourceRecordID, SourceEntityType, TaxOrAccount, NormAddress, NormFullAddress)
    SELECT N''CASE'', CONVERT(VARCHAR(100), c.CaseNumber), N''Case'', NULL,
        dbo.fn_UPR_NormalizeAddressLine(c.StreetAddress),
        dbo.fn_UPR_NormalizeFullAddressLine(c.StreetAddress, c.City, c.ZipCode)
    FROM DHCA_OLTA.dbo.[Case] c';
    EXEC sys.sp_executesql @Sql;

    SET @Sql = N'
    INSERT INTO #ExtAddr (SourceSystemCode, SourceRecordID, SourceEntityType, TaxOrAccount, NormAddress, NormFullAddress)
    SELECT N''MPDU'', CONVERT(VARCHAR(100), mp.DevelopmentID), N''Development'', NULL,
        dbo.fn_UPR_NormalizeAddressLine(mp.StreetAddress),
        dbo.fn_UPR_NormalizeFullAddressLine(mp.StreetAddress, mp.City, mp.ZipCode)
    FROM DHCA_MPDU.dbo.Development mp';
    EXEC sys.sp_executesql @Sql;

    SET @Sql = N'
    INSERT INTO #ExtAddr (SourceSystemCode, SourceRecordID, SourceEntityType, TaxOrAccount, NormAddress, NormFullAddress)
    SELECT N''MULTIFAMILY'', CONVERT(VARCHAR(100), mf.AddressID), N''MultifamilyLoan'', NULL,
        dbo.fn_UPR_NormalizeAddressLine(CONCAT(mf.StreetNumber, N'' '', mf.StreetName, N'' '', mf.StreetType)),
        dbo.fn_UPR_NormalizeFullAddressLine(CONCAT(mf.StreetNumber, N'' '', mf.StreetName, N'' '', mf.StreetType), mf.City, mf.ZipCode)
    FROM DHCA_MultifamilyLoans.dbo.Address mf
    WHERE mf.DeletedInd = 0';
    EXEC sys.sp_executesql @Sql;

    /* --- 7a. Property (eProperty): account/TaxID or normalized address --- */
    INSERT INTO #ExtMatch (
        UPropertyRecordsID, SourceSystemCode, SourceRecordID, SourceEntityType,
        MatchMethodCode, MatchResult, MatchConfidence, ProcessingStatus, Notes
    )
    SELECT DISTINCT
        m.UPropertyRecordsID, N'eProperty', ea.SourceRecordID, ea.SourceEntityType,
        CASE
            WHEN m.SDATAccountNumber IS NOT NULL AND ea.TaxOrAccount IS NOT NULL
                 AND m.SDATAccountNumber = ea.TaxOrAccount THEN N'SDATAccount'
            WHEN m.ParcelID IS NOT NULL AND ea.TaxOrAccount IS NOT NULL
                 AND m.ParcelID = ea.TaxOrAccount THEN N'ParcelID'
            ELSE N'AddressNormalized'
        END,
        N'MATCH',
        CASE
            WHEN m.SDATAccountNumber IS NOT NULL AND ea.TaxOrAccount IS NOT NULL
                 AND m.SDATAccountNumber = ea.TaxOrAccount THEN N'HIGH'
            WHEN m.ParcelID IS NOT NULL AND ea.TaxOrAccount IS NOT NULL
                 AND m.ParcelID = ea.TaxOrAccount THEN N'HIGH'
            ELSE N'MEDIUM'
        END,
        N'PROCESSED',
        N'Matched to eProperty'
    FROM #UPRMap m
    INNER JOIN dbo.UPROPERTYRECORDS upr ON upr.UPropertyRecordsID = m.UPropertyRecordsID
    INNER JOIN #ExtAddr ea
        ON ea.SourceSystemCode = N'eProperty'
       AND (
            (m.SDATAccountNumber IS NOT NULL AND ea.TaxOrAccount IS NOT NULL AND m.SDATAccountNumber = ea.TaxOrAccount)
            OR (m.ParcelID IS NOT NULL AND ea.TaxOrAccount IS NOT NULL AND m.ParcelID = ea.TaxOrAccount)
            OR ea.NormAddress = upr.NormalizedStreetAddress
            OR ea.NormFullAddress = upr.NormalizedFulldAddress
       )
    WHERE m.HasRequiredAddress = 1;

    /* --- 7b. CASE: normalized address only --- */
    INSERT INTO #ExtMatch (
        UPropertyRecordsID, SourceSystemCode, SourceRecordID, SourceEntityType,
        MatchMethodCode, MatchResult, MatchConfidence, ProcessingStatus, Notes
    )
    SELECT DISTINCT
        m.UPropertyRecordsID, N'CASE', ea.SourceRecordID, ea.SourceEntityType,
        N'AddressNormalized', N'MATCH', N'MEDIUM', N'PROCESSED', N'Matched to CASE'
    FROM #UPRMap m
    INNER JOIN dbo.UPROPERTYRECORDS upr ON upr.UPropertyRecordsID = m.UPropertyRecordsID
    INNER JOIN #ExtAddr ea
        ON ea.SourceSystemCode = N'CASE'
       AND (
            ea.NormAddress = upr.NormalizedStreetAddress
            OR ea.NormFullAddress = upr.NormalizedFulldAddress
       )
    WHERE m.HasRequiredAddress = 1;

    /* --- 7c. MPDU: normalized address only --- */
    INSERT INTO #ExtMatch (
        UPropertyRecordsID, SourceSystemCode, SourceRecordID, SourceEntityType,
        MatchMethodCode, MatchResult, MatchConfidence, ProcessingStatus, Notes
    )
    SELECT DISTINCT
        m.UPropertyRecordsID, N'MPDU', ea.SourceRecordID, ea.SourceEntityType,
        N'AddressNormalized', N'MATCH', N'MEDIUM', N'PROCESSED', N'Matched to MPDU'
    FROM #UPRMap m
    INNER JOIN dbo.UPROPERTYRECORDS upr ON upr.UPropertyRecordsID = m.UPropertyRecordsID
    INNER JOIN #ExtAddr ea
        ON ea.SourceSystemCode = N'MPDU'
       AND (
            ea.NormAddress = upr.NormalizedStreetAddress
            OR ea.NormFullAddress = upr.NormalizedFulldAddress
       )
    WHERE m.HasRequiredAddress = 1;

    /* --- 7d. Multifamily: normalized address only --- */
    INSERT INTO #ExtMatch (
        UPropertyRecordsID, SourceSystemCode, SourceRecordID, SourceEntityType,
        MatchMethodCode, MatchResult, MatchConfidence, ProcessingStatus, Notes
    )
    SELECT DISTINCT
        m.UPropertyRecordsID, N'MULTIFAMILY', ea.SourceRecordID, ea.SourceEntityType,
        N'AddressNormalized', N'MATCH', N'MEDIUM', N'PROCESSED', N'Matched to MULTIFAMILY'
    FROM #UPRMap m
    INNER JOIN dbo.UPROPERTYRECORDS upr ON upr.UPropertyRecordsID = m.UPropertyRecordsID
    INNER JOIN #ExtAddr ea
        ON ea.SourceSystemCode = N'MULTIFAMILY'
       AND (
            ea.NormAddress = upr.NormalizedStreetAddress
            OR ea.NormFullAddress = upr.NormalizedFulldAddress
       )
    WHERE m.HasRequiredAddress = 1;

    /* UX: one active XREF per SourceSystem + SourceRecordID + EntityType (client pattern) */
    IF OBJECT_ID('tempdb..#ExtMatchDeduped') IS NOT NULL DROP TABLE #ExtMatchDeduped;

    SELECT
        UPropertyRecordsID, SourceSystemCode, SourceRecordID, SourceEntityType,
        MatchMethodCode, MatchResult, MatchConfidence, ProcessingStatus, Notes
    INTO #ExtMatchDeduped
    FROM (
        SELECT
            e.*,
            ROW_NUMBER() OVER (
                PARTITION BY e.SourceSystemCode, e.SourceRecordID, e.SourceEntityType
                ORDER BY
                    CASE e.MatchMethodCode
                        WHEN N'SDATAccount' THEN 1
                        WHEN N'ParcelID' THEN 2
                        WHEN N'AddressNormalized' THEN 3
                        ELSE 4
                    END,
                    CASE e.MatchConfidence
                        WHEN N'HIGH' THEN 1
                        WHEN N'MEDIUM' THEN 2
                        WHEN N'LOW' THEN 3
                        ELSE 4
                    END,
                    e.UPropertyRecordsID
            ) AS MatchRn
        FROM #ExtMatch e
    ) ranked
    WHERE MatchRn = 1;

    DELETE FROM #ExtMatch;

    INSERT INTO #ExtMatch (
        UPropertyRecordsID, SourceSystemCode, SourceRecordID, SourceEntityType,
        MatchMethodCode, MatchResult, MatchConfidence, ProcessingStatus, Notes
    )
    SELECT
        UPropertyRecordsID, SourceSystemCode, SourceRecordID, SourceEntityType,
        MatchMethodCode, MatchResult, MatchConfidence, ProcessingStatus, Notes
    FROM #ExtMatchDeduped;

    DROP TABLE #ExtMatchDeduped;

    /* eProperty — NOT EXISTS on SourceSystem + SourceRecordID + EntityType + IsActive */
    INSERT INTO dbo.UPROPERTYRECORDS_XREF (
        UPropertyRecordsID, SourceSystemCode, SourceRecordID, SourceEntityType,
        MatchMethodCode, MatchResult, MatchConfidence, ProcessingStatus,
        IsActive, EffectiveStartDate, Notes, CreatedDate, UpdatedDate, CreatedBy
    )
    SELECT
        e.UPropertyRecordsID, e.SourceSystemCode, e.SourceRecordID, e.SourceEntityType,
        e.MatchMethodCode, e.MatchResult, e.MatchConfidence, e.ProcessingStatus,
        1, @Now, e.Notes, @Now, @Now, @RunUser
    FROM #ExtMatch e
    WHERE e.SourceSystemCode = N'eProperty'
      AND NOT EXISTS (
          SELECT 1
          FROM dbo.UPROPERTYRECORDS_XREF x
          WHERE x.SourceSystemCode = N'eProperty'
            AND x.SourceRecordID = e.SourceRecordID
            AND x.SourceEntityType = e.SourceEntityType
            AND x.IsActive = 1
      );

    SET @EPropertyXrefInserted = @@ROWCOUNT;

    /* CASE */
    INSERT INTO dbo.UPROPERTYRECORDS_XREF (
        UPropertyRecordsID, SourceSystemCode, SourceRecordID, SourceEntityType,
        MatchMethodCode, MatchResult, MatchConfidence, ProcessingStatus,
        IsActive, EffectiveStartDate, Notes, CreatedDate, UpdatedDate, CreatedBy
    )
    SELECT
        e.UPropertyRecordsID, e.SourceSystemCode, e.SourceRecordID, e.SourceEntityType,
        e.MatchMethodCode, e.MatchResult, e.MatchConfidence, e.ProcessingStatus,
        1, @Now, e.Notes, @Now, @Now, @RunUser
    FROM #ExtMatch e
    WHERE e.SourceSystemCode = N'CASE'
      AND NOT EXISTS (
          SELECT 1
          FROM dbo.UPROPERTYRECORDS_XREF x
          WHERE x.SourceSystemCode = N'CASE'
            AND x.SourceRecordID = e.SourceRecordID
            AND x.SourceEntityType = e.SourceEntityType
            AND x.IsActive = 1
      );

    SET @CaseXrefInserted = @@ROWCOUNT;

    /* MPDU */
    INSERT INTO dbo.UPROPERTYRECORDS_XREF (
        UPropertyRecordsID, SourceSystemCode, SourceRecordID, SourceEntityType,
        MatchMethodCode, MatchResult, MatchConfidence, ProcessingStatus,
        IsActive, EffectiveStartDate, Notes, CreatedDate, UpdatedDate, CreatedBy
    )
    SELECT
        e.UPropertyRecordsID, e.SourceSystemCode, e.SourceRecordID, e.SourceEntityType,
        e.MatchMethodCode, e.MatchResult, e.MatchConfidence, e.ProcessingStatus,
        1, @Now, e.Notes, @Now, @Now, @RunUser
    FROM #ExtMatch e
    WHERE e.SourceSystemCode = N'MPDU'
      AND NOT EXISTS (
          SELECT 1
          FROM dbo.UPROPERTYRECORDS_XREF x
          WHERE x.SourceSystemCode = N'MPDU'
            AND x.SourceRecordID = e.SourceRecordID
            AND x.SourceEntityType = e.SourceEntityType
            AND x.IsActive = 1
      );

    SET @MPDUXrefInserted = @@ROWCOUNT;

    /* MULTIFAMILY */
    INSERT INTO dbo.UPROPERTYRECORDS_XREF (
        UPropertyRecordsID, SourceSystemCode, SourceRecordID, SourceEntityType,
        MatchMethodCode, MatchResult, MatchConfidence, ProcessingStatus,
        IsActive, EffectiveStartDate, Notes, CreatedDate, UpdatedDate, CreatedBy
    )
    SELECT
        e.UPropertyRecordsID, e.SourceSystemCode, e.SourceRecordID, e.SourceEntityType,
        e.MatchMethodCode, e.MatchResult, e.MatchConfidence, e.ProcessingStatus,
        1, @Now, e.Notes, @Now, @Now, @RunUser
    FROM #ExtMatch e
    WHERE e.SourceSystemCode = N'MULTIFAMILY'
      AND NOT EXISTS (
          SELECT 1
          FROM dbo.UPROPERTYRECORDS_XREF x
          WHERE x.SourceSystemCode = N'MULTIFAMILY'
            AND x.SourceRecordID = e.SourceRecordID
            AND x.SourceEntityType = e.SourceEntityType
            AND x.IsActive = 1
      );

    SET @MultifamilyXrefInserted = @@ROWCOUNT;

    SET @TotalXrefInserted = @MasterAddressXrefInserted + @SDATXrefInserted
        + @EPropertyXrefInserted + @CaseXrefInserted + @MPDUXrefInserted + @MultifamilyXrefInserted;

    SET @ReviewExternalInserted = 0;
    SET @ReviewInserted = @ReviewIncomingInserted;

    /* ========================================================================
       8. CONTACT + PROPERTYCONTACT (owner from SDAT)
       ======================================================================== */
    INSERT INTO dbo.CONTACT (ContactTypeCode, OrganizationName, IsActive, CreatedDate, UpdatedDate)
    SELECT DISTINCT N'OWNER', w.OwnerName, 1, @Now, @Now
    FROM #Work w
    WHERE w.OwnerName IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM dbo.CONTACT c WHERE c.OrganizationName = w.OwnerName);

    SET @ContactInserted = @@ROWCOUNT;

    INSERT INTO dbo.PROPERTYCONTACT (UPropertyRecordsID, ContactID, ContactRoleCode, EffectiveStartDate, IsActive)
    SELECT m.UPropertyRecordsID, c.ContactID, N'OWNER', @Now, 1
    FROM #UPRMap m
    INNER JOIN #Work w ON (w.MasterAddressID = m.MasterAddressID OR w.KdatRecordID = m.KdatRecordID)
    INNER JOIN dbo.CONTACT c ON c.OrganizationName = w.OwnerName
    WHERE w.OwnerName IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM dbo.PROPERTYCONTACT pc
          WHERE pc.UPropertyRecordsID = m.UPropertyRecordsID AND pc.ContactID = c.ContactID
      );

    SET @PropertyContactInserted = @@ROWCOUNT;

    /* ========================================================================
       10. CONDO / APT - Building + Unit when REF_PROPERTYTYPE allows
       ======================================================================== */
    INSERT INTO dbo.Building (
        UPropertyRecordsID, BuildingCode, BuildingName, BuildingTypeCode,
        BuildingAddress, StatusCode, IsActive, CreatedDate, UpdatedDate, CreatedBy, UpdatedBy
    )
    SELECT
        upr.UPropertyRecordsID,
        N'MAIN',
        CONCAT(N'Building ', upr.UPropertyRecordsID),
        N'MAIN',
        upr.NormalizedFulldAddress,
        N'ACTIVE', 1, @Now, @Now, @RunUser, @RunUser
    FROM dbo.UPROPERTYRECORDS upr
    INNER JOIN dbo.REF_PROPERTYTYPE pt ON pt.PropertyTypeCode = upr.PropertyTypeCode
    WHERE upr.PropertyTypeCode IN (N'CONDO', N'APT')
      AND pt.AllowsBuildings = 1 AND pt.AllowsUnits = 1
      AND NOT EXISTS (
          SELECT 1 FROM dbo.Building b
          WHERE b.UPropertyRecordsID = upr.UPropertyRecordsID AND b.BuildingCode = N'MAIN'
      );

    SET @BuildingInserted = @@ROWCOUNT;

    /* UQ_Unit_UPropertyRecords_UnitNumber: (UPropertyRecordsID, UnitNumber) — dedupe + NOT EXISTS */
    ;WITH UnitSrc AS (
        SELECT
            upr.UPropertyRecordsID,
            b.BuildingID,
            UnitNumber = COALESCE(NULLIF(LTRIM(RTRIM(m.Unit)), N''), N'U1'),
            upr.SDATAccountNumber,
            UnitTypeCode = CASE upr.PropertyTypeCode WHEN N'CONDO' THEN N'CONDO' ELSE N'APT' END,
            ROW_NUMBER() OVER (
                PARTITION BY
                    upr.UPropertyRecordsID,
                    COALESCE(NULLIF(LTRIM(RTRIM(m.Unit)), N''), N'U1')
                ORDER BY
                    CASE WHEN NULLIF(LTRIM(RTRIM(m.Unit)), N'') IS NOT NULL THEN 0 ELSE 1 END,
                    CASE m.MatchSource WHEN N'BOTH' THEN 1 WHEN N'ADDRESS_MASTER' THEN 2 ELSE 3 END,
                    m.WorkKey
            ) AS UnitRn
        FROM dbo.UPROPERTYRECORDS upr
        INNER JOIN #UPRMap m ON m.UPropertyRecordsID = upr.UPropertyRecordsID
        INNER JOIN dbo.Building b
            ON b.UPropertyRecordsID = upr.UPropertyRecordsID AND b.BuildingCode = N'MAIN'
        INNER JOIN dbo.REF_PROPERTYTYPE pt ON pt.PropertyTypeCode = upr.PropertyTypeCode
        WHERE upr.PropertyTypeCode IN (N'CONDO', N'APT')
          AND pt.AllowsBuildings = 1 AND pt.AllowsUnits = 1
    )
    INSERT INTO dbo.Unit (
        UPropertyRecordsID, BuildingID, UnitNumber, SDATAccountNumber,
        UnitTypeCode, UnitStatusCode, IsMPDU, IsActive, CreatedDate, UpdatedDate
    )
    SELECT
        s.UPropertyRecordsID,
        s.BuildingID,
        s.UnitNumber,
        s.SDATAccountNumber,
        s.UnitTypeCode,
        N'ACTIVE', 0, 1, @Now, @Now
    FROM UnitSrc s
    WHERE s.UnitRn = 1
      AND NOT EXISTS (
          SELECT 1
          FROM dbo.Unit u
          WHERE u.UPropertyRecordsID = s.UPropertyRecordsID
            AND u.UnitNumber = s.UnitNumber
      );

    SET @UnitInserted = @@ROWCOUNT;

    /* ========================================================================
       11. AUDIT LOG
       ======================================================================== */
    INSERT INTO dbo.AuditLog (EntityName, EntityKey, OperationType, ChangedBy, ChangedDate, ChangeSummary)
    SELECT N'UPROPERTYRECORD', CONVERT(NVARCHAR(200), UPropertyRecordsID), N'INSERT', @RunUser, @Now,
           N'UPR load - record created'
    FROM dbo.UPROPERTYRECORDS WHERE CreatedDate >= @Now;

    INSERT INTO dbo.AuditLog (EntityName, EntityKey, OperationType, ChangedBy, ChangedDate, ChangeSummary)
    SELECT N'UPROPERTYRECORDS_XREF', CONVERT(NVARCHAR(200), UPropertyRecords_XrefID), N'INSERT', @RunUser, @Now,
           CONCAT(N'XREF: ', SourceSystemCode, N'/', SourceRecordID, N' ', MatchResult)
    FROM dbo.UPROPERTYRECORDS_XREF WHERE CreatedDate >= @Now;

    INSERT INTO dbo.AuditLog (EntityName, EntityKey, OperationType, ChangedBy, ChangedDate, ChangeSummary)
    SELECT N'UPRMATCHREVIEW_Q', CONVERT(NVARCHAR(200), UPRMatchReviewID), N'INSERT', @RunUser, @Now,
           CONCAT(N'Review: ', ReasonForNoMatch)
    FROM dbo.UPRMATCHREVIEW_Q WHERE ProcessingTimestamp >= @Now;

    SET @AuditInserted = (
        SELECT COUNT(*) FROM dbo.AuditLog WHERE ChangedDate >= @BatchStartTime
    );

    COMMIT TRANSACTION;

    SET @BatchEndTime = SYSDATETIME();

    /* ========================================================================
       12. PRINT SUMMARY (client format)
       ======================================================================== */
    PRINT N'============================================================';
    PRINT N' UPR LOAD SUMMARY';
    PRINT N'============================================================';
    PRINT N'Batch Start Time: ' + CONVERT(VARCHAR(30), @BatchStartTime, 120);
    PRINT N'Batch End Time: ' + CONVERT(VARCHAR(30), @BatchEndTime, 120);
    PRINT N' ';
    PRINT N'MasterAddress records read: ' + CONVERT(VARCHAR(20), @MasterAddressRead);
    PRINT N'SDAT records read: ' + CONVERT(VARCHAR(20), @SDATRead);
    PRINT N'Unified property rows prepared: ' + CONVERT(VARCHAR(20), @IncomingUnifiedRows);
    PRINT N' ';
    PRINT N'UPR eligible rows (parcel + address): ' + CONVERT(VARCHAR(20), @UprEligibleRows);
    PRINT N'UPR records inserted (new): ' + CONVERT(VARCHAR(20), @UPRInserted);
    PRINT N'UPR records updated (existing): ' + CONVERT(VARCHAR(20), @UPRUpdated);
    PRINT N'UPR total processed this run: ' + CONVERT(VARCHAR(20), @UPRInserted + @UPRUpdated);
    PRINT N' ';
    PRINT N'Rows with incomplete data (Review_Q): ' + CONVERT(VARCHAR(20), @RowsIncompleteData);
    PRINT N'Rows duplicate property in batch (Review_Q): ' + CONVERT(VARCHAR(20), @RowsReviewDuplicate);
    PRINT N'Rows sent to Review_Q (incoming): ' + CONVERT(VARCHAR(20), @ReviewIncomingInserted);
    PRINT N' ';
    PRINT N'MasterAddress XREF inserted: ' + CONVERT(VARCHAR(20), @MasterAddressXrefInserted);
    PRINT N'SDAT XREF inserted: ' + CONVERT(VARCHAR(20), @SDATXrefInserted);
    PRINT N'CASE XREF inserted: ' + CONVERT(VARCHAR(20), @CaseXrefInserted);
    PRINT N'MPDU XREF inserted: ' + CONVERT(VARCHAR(20), @MPDUXrefInserted);
    PRINT N'eProperty XREF inserted: ' + CONVERT(VARCHAR(20), @EPropertyXrefInserted);
    PRINT N'Total XREF inserted: ' + CONVERT(VARCHAR(20), @TotalXrefInserted);
    PRINT N' ';
    PRINT N'Review_Q records inserted (invalid identification only): ' + CONVERT(VARCHAR(20), @ReviewInserted);
    PRINT N'Status history inserted: ' + CONVERT(VARCHAR(20), @StatusHistoryInserted);
    PRINT N'AuditLog inserted: ' + CONVERT(VARCHAR(20), @AuditInserted);
    PRINT N' ';
    PRINT N'Building records inserted: ' + CONVERT(VARCHAR(20), @BuildingInserted);
    PRINT N'Unit records inserted: ' + CONVERT(VARCHAR(20), @UnitInserted);
    PRINT N'Contact records inserted: ' + CONVERT(VARCHAR(20), @ContactInserted);
    PRINT N'PropertyContact records inserted: ' + CONVERT(VARCHAR(20), @PropertyContactInserted);
    PRINT N'============================================================';

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

    DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
    DECLARE @ErrNum INT = ERROR_NUMBER();
    DECLARE @ErrLine INT = ERROR_LINE();

    PRINT N'';
    PRINT N'*** UPR LOAD FAILED ***';
    PRINT N'Error ' + CAST(@ErrNum AS NVARCHAR(10)) + N' at line ' + CAST(@ErrLine AS NVARCHAR(10)) + N': ' + @ErrMsg;

    BEGIN TRY
        INSERT INTO dbo.AuditLog (EntityName, EntityKey, OperationType, ChangedBy, ChangedDate, ChangeSummary)
        VALUES (N'UPR_LOAD', N'ERROR', N'INSERT', @RunUser, SYSDATETIME(),
                CONCAT(N'Load failed: ', @ErrMsg));
    END TRY
    BEGIN CATCH
        /* Audit table may not exist if failure happened before schema ready */
    END CATCH;

    THROW;
END CATCH;
GO
