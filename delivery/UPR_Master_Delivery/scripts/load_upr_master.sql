/*
================================================================================
  UPR Master Load Script — based on client's running version (UPRDB_Test)
  
  Loads AddressMaster + SDAT, normalizes addresses, populates UPROPERTYRECORDS
  and all related tables (XREF, Review_Q, StatusHistory, Contact, Building/Unit,
  Reference data, AuditLog).

  Minimal fixes applied to client's script (structure unchanged):
    - MA uses LUCategory (not PropertyType); SD has no PropertyType
    - State/Lat/Long NULL or defaulted; UPROPERTYRECORDS uses PropertyTypeCode
    - UNION column alignment, UPropertyRecordsID typos, external XREF table names
  Lat/long remain commented out per client's production script.
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

CREATE OR ALTER FUNCTION dbo.fn_UPR_NormalizeFullAddressLine (
    @line NVARCHAR(300), @city NVARCHAR(100), @zip NVARCHAR(10)
)
RETURNS NVARCHAR(300)
AS
BEGIN
    RETURN LTRIM(RTRIM(CONCAT(
        dbo.fn_UPR_NormalizeAddressLine(@line), N' ',
        UPPER(LTRIM(RTRIM(ISNULL(@city, N'')))), N' ',
        LEFT(ISNULL(@zip, N''), 5)
    )));
END;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @RunUser NVARCHAR(100) = SUSER_SNAME();
DECLARE @Now     DATETIME2(0)  = SYSDATETIME();
DECLARE @DefaultState  CHAR(2)   = N'MD';

/* Processing statistics */
DECLARE @Stats TABLE (Metric NVARCHAR(100) NOT NULL, Cnt INT NOT NULL);

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
        StreetNumber         = NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(20), ma.StreetNumber))), N''),
        StreetName           = NULLIF(UPPER(LTRIM(RTRIM(ma.StreetName))), N''),
        StreetSuffix         = NULLIF(UPPER(LTRIM(RTRIM(ma.StreetSuffix))), N''),
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
        UnitNumber           = NULLIF(LTRIM(RTRIM(ma.Unit)), N''),
        City                 = NULLIF(UPPER(LTRIM(RTRIM(ma.City))), N''),
        [State]              = @DefaultState,
        ZipCode              = LEFT(NULLIF(LTRIM(RTRIM(ma.ZipCode)), N''), 10),
        /* MA has XCoordinate/YCoordinate but SD does not — NULL coords in temp table */
        Latitude             = CAST(NULL AS DECIMAL(10,6)),
        Longitude            = CAST(NULL AS DECIMAL(10,6)),
        PropertyTypeRaw      = NULLIF(UPPER(LTRIM(RTRIM(ma.LUCategory))), N''),
        PropertyType         = CASE UPPER(LTRIM(RTRIM(ma.LUCategory)))
            WHEN N'CONDOMINIUM'           THEN N'CONDO'
            WHEN N'MULTI-FAMILY'          THEN N'MULTI'
            WHEN N'SINGLE FAMILY DETACHED'THEN N'SF'
            WHEN N'VACANT'                THEN N'LAND'
            WHEN N'TOWNHOUSE'             THEN N'TH'
            WHEN N'MIXED USE'             THEN N'MIXED'
            ELSE NULLIF(UPPER(LTRIM(RTRIM(ma.LUCategory))), N'')
        END,
        OwnerName            = CAST(NULL AS NVARCHAR(200)),
        YearBuilt            = CAST(NULL AS INT),
        DwellingUnits        = CAST(NULL AS INT),
        NormalizedAddress    = UPPER(LTRIM(RTRIM(CONCAT(
            ISNULL(CONVERT(NVARCHAR(20), ma.StreetNumber), N''), N' ',
            ISNULL(UPPER(LTRIM(RTRIM(ma.StreetName))), N''), N' ',
            CASE UPPER(LTRIM(RTRIM(ma.StreetType)))
                WHEN N'STREET' THEN N'ST' WHEN N'AVENUE' THEN N'AVE' WHEN N'ROAD' THEN N'RD'
                WHEN N'LANE' THEN N'LN'   WHEN N'COURT' THEN N'CT'  WHEN N'DRIVE' THEN N'DR'
                WHEN N'BOULEVARD' THEN N'BLVD' WHEN N'PLACE' THEN N'PL'
                ELSE ISNULL(UPPER(LTRIM(RTRIM(ma.StreetType))), N'')
            END
        )))),
        NormalizedFullAddress = UPPER(LTRIM(RTRIM(CONCAT(
            ISNULL(CONVERT(NVARCHAR(20), ma.StreetNumber), N''), N' ',
            ISNULL(UPPER(LTRIM(RTRIM(ma.StreetName))), N''), N' ',
            CASE UPPER(LTRIM(RTRIM(ma.StreetType)))
                WHEN N'STREET' THEN N'ST' WHEN N'AVENUE' THEN N'AVE' WHEN N'ROAD' THEN N'RD'
                WHEN N'LANE' THEN N'LN'   WHEN N'COURT' THEN N'CT'  WHEN N'DRIVE' THEN N'DR'
                WHEN N'BOULEVARD' THEN N'BLVD' WHEN N'PLACE' THEN N'PL'
                ELSE ISNULL(UPPER(LTRIM(RTRIM(ma.StreetType))), N'')
            END, N' ',
            ISNULL(UPPER(LTRIM(RTRIM(ma.City))), N''), N' ',
            LEFT(ISNULL(ma.ZipCode, N''), 5)
        )))),
        HasRequiredAddress   = CASE
            WHEN NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(20), ma.StreetNumber))), N'') IS NULL THEN 0
            WHEN NULLIF(UPPER(LTRIM(RTRIM(ma.StreetName))), N'') IS NULL THEN 0
            WHEN NULLIF(UPPER(LTRIM(RTRIM(ma.City))), N'') IS NULL THEN 0
            WHEN NULLIF(LTRIM(RTRIM(ma.ZipCode)), N'') IS NULL THEN 0
            ELSE 1
        END
    INTO #MA
    FROM DHCA_Internal.dbo.MasterAddress ma;

    INSERT INTO @Stats (Metric, Cnt)
    SELECT N'AddressMaster rows read', COUNT(*) FROM #MA;

    /* ========================================================================
       3. NORMALIZE SDAT  
       ======================================================================== */
    IF OBJECT_ID('tempdb..#SDAT') IS NOT NULL DROP TABLE #SDAT;

    SELECT
        KdatRecordID         = s.RealPropertyTaxInformationID,
        SourceSystem         = N'KDAT',
        SourceRecordID       = CONVERT(VARCHAR(100), s.RealPropertyTaxInformationID),
        SourceEntityType     = N'SDATProperty',
        MasterAddressAccount = NULL,
        SDATAccountNumber    = NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), s.AccountNumber))), N''),
        ParcelID             = NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), s.Parcel))), N''),
        StreetNumber         = NULLIF(LTRIM(RTRIM(s.PremisesNumber)), N''),
        StreetName           = NULLIF(UPPER(LTRIM(RTRIM(s.PremisesStreetName))), N''),
        StreetSuffix         = NULL,
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
        UnitNumber           = CAST(NULL AS NVARCHAR(20)),
        City                 = NULLIF(UPPER(LTRIM(RTRIM(s.PremisesCity))), N''),
        /* [State] only once — do not add a second [State] line below */
        [State]              = COALESCE(NULLIF(UPPER(LTRIM(RTRIM(s.PremisesState))), N''), @DefaultState),
        ZipCode              = LEFT(NULLIF(LTRIM(RTRIM(s.PremisesZipCode)), N''), 10),
        Latitude             = CAST(NULL AS DECIMAL(10,6)),
        Longitude            = CAST(NULL AS DECIMAL(10,6)),
        PropertyTypeRaw      = CAST(NULL AS NVARCHAR(50)),
        PropertyType         = CASE WHEN ISNULL(TRY_CONVERT(INT, s.DwellingUnits), 0) > 1 THEN N'MULTI' ELSE N'SF' END,
        OwnerName            = NULLIF(LTRIM(RTRIM(CAST(s.Owner AS NVARCHAR(200)))), N''),
        YearBuilt            = TRY_CONVERT(INT, s.YearBuilt),
        DwellingUnits        = TRY_CONVERT(INT, s.DwellingUnits),
        NormalizedAddress    = UPPER(LTRIM(RTRIM(CONCAT(
            ISNULL(s.PremisesNumber, N''), N' ',
            ISNULL(UPPER(LTRIM(RTRIM(s.PremisesStreetName))), N''), N' ',
            CASE UPPER(LTRIM(RTRIM(s.PremisesStreetType)))
                WHEN N'STREET' THEN N'ST' WHEN N'AVENUE' THEN N'AVE' WHEN N'ROAD' THEN N'RD'
                WHEN N'LANE' THEN N'LN'   WHEN N'COURT' THEN N'CT'  WHEN N'DRIVE' THEN N'DR'
                WHEN N'BOULEVARD' THEN N'BLVD' WHEN N'PLACE' THEN N'PL'
                ELSE ISNULL(UPPER(LTRIM(RTRIM(s.PremisesStreetType))), N'')
            END
        )))),
        NormalizedFullAddress = UPPER(LTRIM(RTRIM(CONCAT(
            ISNULL(s.PremisesNumber, N''), N' ',
            ISNULL(UPPER(LTRIM(RTRIM(s.PremisesStreetName))), N''), N' ',
            CASE UPPER(LTRIM(RTRIM(s.PremisesStreetType)))
                WHEN N'STREET' THEN N'ST' WHEN N'AVENUE' THEN N'AVE' WHEN N'ROAD' THEN N'RD'
                WHEN N'LANE' THEN N'LN'   WHEN N'COURT' THEN N'CT'  WHEN N'DRIVE' THEN N'DR'
                WHEN N'BOULEVARD' THEN N'BLVD' WHEN N'PLACE' THEN N'PL'
                ELSE ISNULL(UPPER(LTRIM(RTRIM(s.PremisesStreetType))), N'')
            END, N' ',
            ISNULL(UPPER(LTRIM(RTRIM(s.PremisesCity))), N''), N' ',
            LEFT(ISNULL(s.PremisesZipCode, N''), 5)
        )))),
        HasRequiredAddress   = CASE
            WHEN NULLIF(LTRIM(RTRIM(s.PremisesNumber)), N'') IS NULL THEN 0
            WHEN NULLIF(UPPER(LTRIM(RTRIM(s.PremisesStreetName))), N'') IS NULL THEN 0
            WHEN NULLIF(UPPER(LTRIM(RTRIM(s.PremisesCity))), N'') IS NULL THEN 0
            WHEN NULLIF(LTRIM(RTRIM(s.PremisesZipCode)), N'') IS NULL THEN 0
            ELSE 1
        END
    INTO #SDAT
    FROM DHCA_Internal.dbo.RealPropertyTaxInformation s;

    INSERT INTO @Stats (Metric, Cnt)
    SELECT N'SDAT rows read', COUNT(*) FROM #SDAT;

    /* ========================================================================
       4. MATCH AddressMaster <-> SDAT on Account + Normalized Address
       Uses explicit #Work table + INSERT (no UNION — avoids column-count errors)
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
        StreetSuffix              NVARCHAR(20)   NULL,
        StreetType                NVARCHAR(20)   NULL,
        UnitNumber                NVARCHAR(20)   NULL,
        City                      NVARCHAR(100)  NULL,
        [State]                   CHAR(2)        NOT NULL,
        ZipCode                   NVARCHAR(10)   NULL,
        Latitude                  DECIMAL(10,6)  NULL,
        Longitude                 DECIMAL(10,6)  NULL,
        PropertyType              NVARCHAR(50)   NULL,
        OwnerName                 NVARCHAR(200)  NULL,
        YearBuilt                 INT            NULL,
        DwellingUnits             INT            NULL,
        NormalizedAddress         NVARCHAR(200)  NOT NULL,
        NormalizedFullAddress     NVARCHAR(300)  NOT NULL,
        HasRequiredAddress        BIT            NOT NULL,
        MatchSource               NVARCHAR(30)   NOT NULL,
        IncomingMatchConfidence   NVARCHAR(30)   NOT NULL,
        IncomingMatchMethod       NVARCHAR(30)   NOT NULL
    );

    /* 4a. Matched — MA + SDAT same account and address */
    INSERT INTO #Work (
        MasterAddressID, KdatRecordID, MasterAddressAccount, SDATAccountNumber, ParcelID,
        StreetNumber, StreetName, StreetSuffix, StreetType, UnitNumber,
        City, [State], ZipCode, Latitude, Longitude, PropertyType,
        OwnerName, YearBuilt, DwellingUnits,
        NormalizedAddress, NormalizedFullAddress, HasRequiredAddress,
        MatchSource, IncomingMatchConfidence, IncomingMatchMethod
    )
    SELECT
        ma.MasterAddressID,
        sd.KdatRecordID,
        ma.MasterAddressAccount,
        COALESCE(sd.SDATAccountNumber, ma.SDATAccountNumber),
        COALESCE(sd.ParcelID, ma.ParcelID),
        COALESCE(ma.StreetNumber, sd.StreetNumber),
        COALESCE(ma.StreetName, sd.StreetName),
        ma.StreetSuffix,
        COALESCE(ma.StreetType, sd.StreetType),
        COALESCE(ma.UnitNumber, sd.UnitNumber),
        COALESCE(ma.City, sd.City),
        COALESCE(sd.[State], @DefaultState),
        COALESCE(ma.ZipCode, sd.ZipCode),
        CAST(NULL AS DECIMAL(10,6)),
        CAST(NULL AS DECIMAL(10,6)),
        COALESCE(ma.PropertyType, sd.PropertyType),
        CAST(sd.OwnerName AS NVARCHAR(200)),
        CAST(sd.YearBuilt AS INT),
        CAST(sd.DwellingUnits AS INT),
        COALESCE(ma.NormalizedAddress, sd.NormalizedAddress),
        COALESCE(ma.NormalizedFullAddress, sd.NormalizedFullAddress),
        CASE WHEN ma.HasRequiredAddress = 1 AND sd.HasRequiredAddress = 1 THEN 1
             WHEN ma.HasRequiredAddress = 1 OR sd.HasRequiredAddress = 1 THEN 1
             ELSE 0 END,
        N'BOTH', N'HIGH', N'AddressNormalized'
    FROM #MA ma
    INNER JOIN #SDAT sd
        ON ma.MasterAddressAccount = sd.SDATAccountNumber
       AND (
            ma.NormalizedAddress = sd.NormalizedAddress
            OR ma.NormalizedFullAddress = sd.NormalizedFullAddress
       );

    /* 4b. AddressMaster only — no SDAT match */
    INSERT INTO #Work (
        MasterAddressID, KdatRecordID, MasterAddressAccount, SDATAccountNumber, ParcelID,
        StreetNumber, StreetName, StreetSuffix, StreetType, UnitNumber,
        City, [State], ZipCode, Latitude, Longitude, PropertyType,
        OwnerName, YearBuilt, DwellingUnits,
        NormalizedAddress, NormalizedFullAddress, HasRequiredAddress,
        MatchSource, IncomingMatchConfidence, IncomingMatchMethod
    )
    SELECT
        ma.MasterAddressID, NULL, ma.MasterAddressAccount, ma.SDATAccountNumber, ma.ParcelID,
        ma.StreetNumber, ma.StreetName, ma.StreetSuffix, ma.StreetType, ma.UnitNumber,
        ma.City, ma.[State], ma.ZipCode,
        CAST(NULL AS DECIMAL(10,6)), CAST(NULL AS DECIMAL(10,6)),
        ma.PropertyType,
        CAST(ma.OwnerName AS NVARCHAR(200)),
        CAST(ma.YearBuilt AS INT),
        CAST(ma.DwellingUnits AS INT),
        ma.NormalizedAddress, ma.NormalizedFullAddress, ma.HasRequiredAddress,
        N'ADDRESS_MASTER', N'MEDIUM', N'AddressNormalized'
    FROM #MA ma
    WHERE NOT EXISTS (
        SELECT 1
        FROM #MA ma2
        INNER JOIN #SDAT sd
            ON ma2.MasterAddressAccount = sd.SDATAccountNumber
           AND (
                ma2.NormalizedAddress = sd.NormalizedAddress
                OR ma2.NormalizedFullAddress = sd.NormalizedFullAddress
           )
        WHERE ma2.MasterAddressID = ma.MasterAddressID
    );

    /* 4c. SDAT only — no AddressMaster match */
    INSERT INTO #Work (
        MasterAddressID, KdatRecordID, MasterAddressAccount, SDATAccountNumber, ParcelID,
        StreetNumber, StreetName, StreetSuffix, StreetType, UnitNumber,
        City, [State], ZipCode, Latitude, Longitude, PropertyType,
        OwnerName, YearBuilt, DwellingUnits,
        NormalizedAddress, NormalizedFullAddress, HasRequiredAddress,
        MatchSource, IncomingMatchConfidence, IncomingMatchMethod
    )
    SELECT
        NULL, sd.KdatRecordID, sd.MasterAddressAccount, sd.SDATAccountNumber, sd.ParcelID,
        sd.StreetNumber, sd.StreetName, sd.StreetSuffix, sd.StreetType, sd.UnitNumber,
        sd.City, sd.[State], sd.ZipCode,
        CAST(NULL AS DECIMAL(10,6)), CAST(NULL AS DECIMAL(10,6)),
        sd.PropertyType,
        CAST(sd.OwnerName AS NVARCHAR(200)),
        CAST(sd.YearBuilt AS INT),
        CAST(sd.DwellingUnits AS INT),
        sd.NormalizedAddress, sd.NormalizedFullAddress, sd.HasRequiredAddress,
        N'KDAT', N'MEDIUM', N'AddressNormalized'
    FROM #SDAT sd
    WHERE NOT EXISTS (
        SELECT 1
        FROM #MA ma
        INNER JOIN #SDAT sd2
            ON ma.MasterAddressAccount = sd2.SDATAccountNumber
           AND (
                ma.NormalizedAddress = sd2.NormalizedAddress
                OR ma.NormalizedFullAddress = sd2.NormalizedFullAddress
           )
        WHERE sd2.KdatRecordID = sd.KdatRecordID
    );

    INSERT INTO @Stats (Metric, Cnt)
    SELECT N'Unified work rows', COUNT(*) FROM #Work;

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
        NormalizedFullAddress NVARCHAR(300) NOT NULL
    );

    MERGE dbo.UPROPERTYRECORDS AS tgt
    USING (
        SELECT
            w.MasterAddressID, w.KdatRecordID, w.MatchSource, w.HasRequiredAddress,
            w.SDATAccountNumber, w.ParcelID,
            w.StreetNumber, w.StreetName, w.StreetSuffix, w.StreetType, w.UnitNumber,
            w.City, w.[State], w.ZipCode, w.NormalizedAddress, w.NormalizedFullAddress, 
            --w.Latitude, w.Longitude,
            w.PropertyType, w.OwnerName,
            ROW_NUMBER() OVER (
                PARTITION BY COALESCE(w.SDATAccountNumber, w.ParcelID, w.NormalizedFullAddress)
                ORDER BY CASE w.MatchSource WHEN N'BOTH' THEN 1 WHEN N'KDAT' THEN 2 ELSE 3 END
            ) AS rn
        FROM #Work w
        WHERE w.HasRequiredAddress = 1
    ) AS src
    ON (
        (tgt.SDATAccountNumber = src.SDATAccountNumber AND src.SDATAccountNumber IS NOT NULL)
        OR (tgt.ParcelID = src.ParcelID AND src.ParcelID IS NOT NULL)
        OR (tgt.NormalizedFullAddress = src.NormalizedFullAddress)
    )
    WHEN MATCHED THEN UPDATE SET
        tgt.ParcelID          = COALESCE(tgt.ParcelID, src.ParcelID),
        tgt.Owner             = COALESCE(tgt.Owner, src.OwnerName),
        --tgt.Latitude          = COALESCE(tgt.Latitude, src.Latitude),
        --tgt.Longitude         = COALESCE(tgt.Longitude, src.Longitude),
        tgt.PropertyTypeCode  = COALESCE(tgt.PropertyTypeCode, src.PropertyType),
        tgt.UpdatedDate       = @Now,
        tgt.UpdatedBy         = @RunUser
    WHEN NOT MATCHED AND src.rn = 1 THEN INSERT (
        SDATAccountNumber, ParcelID, PropertyName, Owner,
        StreetNumber, StreetName, StreetSuffix, StreetType, UnitNumber,
        City, [State], ZipCode, NormalizedAddress, NormalizedFullAddress,
        PropertyTypeCode, StatusCode, IsActive,
        CreatedDate, CreatedBy, UpdatedDate, UpdatedBy
    ) VALUES (
        src.SDATAccountNumber, src.ParcelID, NULL, src.OwnerName,
        src.StreetNumber, src.StreetName, src.StreetSuffix, src.StreetType, src.UnitNumber,
        src.City, src.[State], src.ZipCode, src.NormalizedAddress, src.NormalizedFullAddress,
        src.PropertyType, N'ACTIVE', 1,
        @Now, @RunUser, @Now, @RunUser
    );

    DECLARE @UprInserted INT = @@ROWCOUNT;
    INSERT INTO @Stats VALUES (N'UPROPERTYRECORD merge actions', @UprInserted);

    /* Map work rows to UPR IDs (one UPR per work row, priority: account > parcel > address) */
    INSERT INTO #UPRMap (UPropertyRecordsID, MasterAddressID, KdatRecordID, MatchSource, IsNew, HasRequiredAddress, SDATAccountNumber, ParcelID, NormalizedFullAddress)
    SELECT
        x.UPropertyRecordsID, w.MasterAddressID, w.KdatRecordID, w.MatchSource,
        CASE WHEN x.CreatedDate >= @Now THEN 1 ELSE 0 END,
        w.HasRequiredAddress, w.SDATAccountNumber, w.ParcelID, w.NormalizedFullAddress
    FROM #Work w
    CROSS APPLY (
        SELECT TOP 1 upr.UPropertyRecordsID, upr.CreatedDate
        FROM dbo.UPROPERTYRECORDS upr
        WHERE (w.SDATAccountNumber IS NOT NULL AND upr.SDATAccountNumber = w.SDATAccountNumber)
           OR (w.ParcelID IS NOT NULL AND upr.ParcelID = w.ParcelID)
           OR (upr.NormalizedFullAddress = w.NormalizedFullAddress)
        ORDER BY
            CASE WHEN w.SDATAccountNumber IS NOT NULL AND upr.SDATAccountNumber = w.SDATAccountNumber THEN 1
                 WHEN w.ParcelID IS NOT NULL AND upr.ParcelID = w.ParcelID THEN 2
                 ELSE 3 END
    ) x;

    INSERT INTO @Stats (Metric, Cnt)
    SELECT N'UPROPERTYRECORDS total', COUNT(*) FROM dbo.UPROPERTYRECORDS;

    /* Status history for newly created UPR records only (idempotent re-runs) */
    INSERT INTO dbo.UPR_STATUSHISTORY (
        UPropertyRecordsID, SDATAccountNumber, OldStatusCode, NewStatusCode,
        ChangeReason, ParcelID, Owner, StreetNumber, StreetName, StreetType,
        City, ZipCode, PropertyTypeCode, ChangeSource, ChangedBy, ChangedDate
    )
    SELECT
        m.UPropertyRecordsID, upr.SDATAccountNumber,
        NULL, upr.StatusCode,
        N'Initial load - new UPR record',
        upr.ParcelID, upr.Owner, upr.StreetNumber, upr.StreetName, upr.StreetType,
        upr.City, upr.ZipCode, upr.PropertyTypeCode,
        N'UPR_LOAD', @RunUser, @Now
    FROM #UPRMap m
    INNER JOIN dbo.UPROPERTYRECORDS upr ON upr.UPropertyRecordsID = m.UPropertyRecordsID
    WHERE m.IsNew = 1;

    INSERT INTO @Stats VALUES (N'UPR_STATUSHISTORY written', @@ROWCOUNT);

    /* ========================================================================
       6. WRITE INCOMING SOURCE XREF (AddressMaster / SDAT)
       ======================================================================== */
    INSERT INTO dbo.UPROPERTYRECORDS_XREF (
        UPropertyRecordsID, SourceSystem, SourceRecordID, SourceEntityType,
        MatchMethodCode, MatchResult, MatchConfidence, ProcessingStatus,
        IsActive, EffectiveStartDate, CreatedDate, UpdatedDate, CreatedBy
    )
    SELECT
        m.UPropertyRecordsID, N'ADDRESS_MASTER', CONVERT(VARCHAR(100), m.MasterAddressID), N'MasterAddress',
        N'AddressNormalized', N'MATCH', N'HIGH', N'PROCESSED',
        1, @Now, @Now, @Now, @RunUser
    FROM #UPRMap m
    WHERE m.MasterAddressID IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM dbo.UPROPERTYRECORDS_XREF x
          WHERE x.UPropertyRecordsID = m.UPropertyRecordsID
            AND x.SourceSystem = N'ADDRESS_MASTER'
            AND x.SourceRecordID = CONVERT(VARCHAR(100), m.MasterAddressID)
      );

    INSERT INTO @Stats VALUES (N'XREF ADDRESS_MASTER written', @@ROWCOUNT);

    INSERT INTO dbo.UPROPERTYRECORDS_XREF (
        UPropertyRecordsID, SourceSystem, SourceRecordID, SourceEntityType,
        MatchMethodCode, MatchResult, MatchConfidence, ProcessingStatus,
        IsActive, EffectiveStartDate, CreatedDate, UpdatedDate, CreatedBy
    )
    SELECT
        m.UPropertyRecordsID, N'KDAT', CONVERT(VARCHAR(100), m.KdatRecordID), N'SDATProperty',
        N'AddressNormalized', N'MATCH', N'HIGH', N'PROCESSED',
        1, @Now, @Now, @Now, @RunUser
    FROM #UPRMap m
    WHERE m.KdatRecordID IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM dbo.UPROPERTYRECORDS_XREF x
          WHERE x.UPropertyRecordsID = m.UPropertyRecordsID
            AND x.SourceSystem = N'KDAT'
            AND x.SourceRecordID = CONVERT(VARCHAR(100), m.KdatRecordID)
      );

    INSERT INTO @Stats VALUES (N'XREF KDAT written', @@ROWCOUNT);

    /* ========================================================================
       7. MATCH EXTERNAL SYSTEMS: eProperty, CASE, MPDU, MULTIFAMILY
          Uses street-type normalization so LANE/LN, STREET/ST, etc. match.
       ======================================================================== */
    IF OBJECT_ID('tempdb..#ExtMatch') IS NOT NULL DROP TABLE #ExtMatch;

    CREATE TABLE #ExtMatch (
        UPropertyRecordsID INT NOT NULL,
        SourceSystem      VARCHAR(30) NOT NULL,
        SourceRecordID    VARCHAR(100) NOT NULL,
        SourceEntityType  VARCHAR(50) NOT NULL,
        MatchMethodCode   VARCHAR(30) NOT NULL,
        MatchResult       NVARCHAR(30) NOT NULL,
        MatchConfidence   NVARCHAR(30) NOT NULL,
        ProcessingStatus  NVARCHAR(50) NOT NULL,
        Notes             VARCHAR(1000) NULL
    );

    IF OBJECT_ID('tempdb..#ExtAddr') IS NOT NULL DROP TABLE #ExtAddr;
    CREATE TABLE #ExtAddr (
        SourceSystem   VARCHAR(30)  NOT NULL,
        SourceRecordID VARCHAR(100) NOT NULL,
        SourceEntityType VARCHAR(50) NOT NULL,
        TaxOrAccount   NVARCHAR(50) NULL,
        NormAddress    NVARCHAR(200) NOT NULL,
        NormFullAddress NVARCHAR(300) NOT NULL
    );

    /* Normalize external addresses using same street-type rules */
    INSERT INTO #ExtAddr (SourceSystem, SourceRecordID, SourceEntityType, TaxOrAccount, NormAddress, NormFullAddress)
    SELECT N'eProperty', CONVERT(VARCHAR(100), ep.PropertyID), N'Property', ep.TaxID,
        dbo.fn_UPR_NormalizeAddressLine(ep.StreetAddress),
        dbo.fn_UPR_NormalizeFullAddressLine(ep.StreetAddress, ep.City, ep.ZipCode)
    FROM DHCA_LicensingAndRegistration.dbo.Property ep;

    INSERT INTO #ExtAddr
    SELECT N'CASE', CONVERT(VARCHAR(100), c.CaseNumber), N'Case', NULL,
        dbo.fn_UPR_NormalizeAddressLine(c.StreetAddress),
        dbo.fn_UPR_NormalizeFullAddressLine(c.StreetAddress, c.City, c.ZipCode)
    FROM DHCA_OLTA.dbo.[Case] c;

    INSERT INTO #ExtAddr
    SELECT N'MPDU', CONVERT(VARCHAR(100), mp.DevelopmentID), N'Development', NULL,
        dbo.fn_UPR_NormalizeAddressLine(mp.StreetAddress),
        dbo.fn_UPR_NormalizeFullAddressLine(mp.StreetAddress, mp.City, mp.ZipCode)
    FROM DHCA_MPDU.dbo.Development mp;

    INSERT INTO #ExtAddr
    SELECT N'MULTIFAMILY', CONVERT(VARCHAR(100), mf.AddressID), N'MultifamilyLoan', NULL,
        dbo.fn_UPR_NormalizeAddressLine(CONCAT(mf.StreetNumber, N' ', mf.StreetName, N' ', mf.StreetType)),
        dbo.fn_UPR_NormalizeFullAddressLine(CONCAT(mf.StreetNumber, N' ', mf.StreetName, N' ', mf.StreetType), mf.City, mf.ZipCode)
    FROM DHCA_MultifamilyLoans.dbo.Address mf
    WHERE mf.DeletedInd = 0;

    INSERT INTO #ExtMatch
    SELECT DISTINCT
        m.UPropertyRecordsID, ea.SourceSystem, ea.SourceRecordID, ea.SourceEntityType,
        CASE
            WHEN m.SDATAccountNumber IS NOT NULL AND m.SDATAccountNumber = ea.TaxOrAccount THEN N'SDATAccount'
            WHEN m.ParcelID IS NOT NULL AND EXISTS (
                SELECT 1 FROM DHCA_LicensingAndRegistration.dbo.Property ep2
                WHERE CONVERT(VARCHAR(100), ep2.PropertyID) = ea.SourceRecordID
                  AND ep2.TaxID = m.ParcelID
            ) THEN N'ParcelID'
            ELSE N'AddressNormalized'
        END,
        N'MATCH',
        CASE
            WHEN m.SDATAccountNumber IS NOT NULL AND m.SDATAccountNumber = ea.TaxOrAccount THEN N'HIGH'
            ELSE N'MEDIUM'
        END,
        N'PROCESSED',
        CONCAT(N'Matched to ', ea.SourceSystem)
    FROM #UPRMap m
    INNER JOIN dbo.UPROPERTYRECORDS upr ON upr.UPropertyRecordsID = m.UPropertyRecordsID
    INNER JOIN #ExtAddr ea
        ON (m.SDATAccountNumber IS NOT NULL AND ea.TaxOrAccount IS NOT NULL AND m.SDATAccountNumber = ea.TaxOrAccount)
        OR ea.NormAddress = upr.NormalizedAddress
        OR ea.NormFullAddress = upr.NormalizedFullAddress;

    INSERT INTO dbo.UPROPERTYRECORDS_XREF (
        UPropertyRecordsID, SourceSystem, SourceRecordID, SourceEntityType,
        MatchMethodCode, MatchResult, MatchConfidence, ProcessingStatus,
        IsActive, EffectiveStartDate, Notes, CreatedDate, UpdatedDate, CreatedBy
    )
    SELECT
        e.UPropertyRecordsID, e.SourceSystem, e.SourceRecordID, e.SourceEntityType,
        e.MatchMethodCode, e.MatchResult, e.MatchConfidence, e.ProcessingStatus,
        1, @Now, e.Notes, @Now, @Now, @RunUser
    FROM #ExtMatch e
    WHERE NOT EXISTS (
        SELECT 1 FROM dbo.UPROPERTYRECORDS_XREF x
        WHERE x.UPropertyRecordsID = e.UPropertyRecordsID
          AND x.SourceSystem = e.SourceSystem
          AND x.SourceRecordID = e.SourceRecordID
    );

    INSERT INTO @Stats VALUES (N'XREF external systems written', @@ROWCOUNT);

    /* ========================================================================
       8. REVIEW QUEUE - no external match OR insufficient address data
       ======================================================================== */
    /* Insufficient address data - includes rows that never reached UPROPERTYRECORD */
    INSERT INTO dbo.UPRMATCHREVIEW_Q (
        UPropertyRecordsID, IncomingSourceSystem, NormalizedIncomingAddress,
        ParcelID, SDATAccountNumber, ReasonForNoMatch, ReviewStatus
    )
    SELECT
        m.UPropertyRecordsID,
        w.MatchSource,
        COALESCE(w.NormalizedFullAddress, w.NormalizedAddress, N'UNKNOWN'),
        w.ParcelID,
        w.SDATAccountNumber,
        N'INSUFFICIENT_DATA',
        N'PENDING_REVIEW'
    FROM #Work w
    LEFT JOIN #UPRMap m
        ON (w.MasterAddressID IS NOT NULL AND m.MasterAddressID = w.MasterAddressID)
        OR (w.KdatRecordID IS NOT NULL AND m.KdatRecordID = w.KdatRecordID)
    WHERE w.HasRequiredAddress = 0
      AND NOT EXISTS (
          SELECT 1 FROM dbo.UPRMATCHREVIEW_Q q
          WHERE q.SDATAccountNumber = w.SDATAccountNumber
            AND q.ReasonForNoMatch = N'INSUFFICIENT_DATA'
      );

    INSERT INTO @Stats VALUES (N'Review_Q insufficient data', @@ROWCOUNT);

    INSERT INTO dbo.UPRMATCHREVIEW_Q (
        UPropertyRecordsID, IncomingSourceSystem, NormalizedIncomingAddress,
        ParcelID, SDATAccountNumber, ReasonForNoMatch, ReviewStatus
    )
    SELECT
        m.UPropertyRecordsID,
        m.MatchSource,
        m.NormalizedFullAddress,
        m.ParcelID,
        m.SDATAccountNumber,
        N'NO_ADDRESS_MATCH',
        N'PENDING_REVIEW'
    FROM #UPRMap m
    WHERE m.HasRequiredAddress = 1
      AND NOT EXISTS (SELECT 1 FROM #ExtMatch e WHERE e.UPropertyRecordsID = m.UPropertyRecordsID)
      AND NOT EXISTS (
          SELECT 1 FROM dbo.UPRMATCHREVIEW_Q q
          WHERE q.UPropertyRecordsID = m.UPropertyRecordsID
            AND q.ReasonForNoMatch = N'NO_ADDRESS_MATCH'
      );

    INSERT INTO @Stats VALUES (N'Review_Q no external match', @@ROWCOUNT);

    /* ========================================================================
       9. CONTACT + PROPERTYCONTACT (owner from SDAT)
       ======================================================================== */
    INSERT INTO dbo.CONTACT (ContactTypeCode, OrganizationName, IsActive, CreatedDate, UpdatedDate)
    SELECT DISTINCT N'OWNER', w.OwnerName, 1, @Now, @Now
    FROM #Work w
    WHERE w.OwnerName IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM dbo.CONTACT c WHERE c.OrganizationName = w.OwnerName);

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

    INSERT INTO @Stats VALUES (N'PROPERTYCONTACT owners written', @@ROWCOUNT);

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
        upr.NormalizedFullAddress,
        N'ACTIVE', 1, @Now, @Now, @RunUser, @RunUser
    FROM dbo.UPROPERTYRECORDS upr
    INNER JOIN dbo.REF_PROPERTYTYPE pt ON pt.PropertyTypeCode = upr.PropertyTypeCode
    WHERE upr.PropertyTypeCode IN (N'CONDO', N'APT')
      AND pt.AllowsBuildings = 1 AND pt.AllowsUnits = 1
      AND NOT EXISTS (
          SELECT 1 FROM dbo.Building b
          WHERE b.UPropertyRecordsID = upr.UPropertyRecordsID AND b.BuildingCode = N'MAIN'
      );

    INSERT INTO @Stats VALUES (N'Buildings created', @@ROWCOUNT);

    INSERT INTO dbo.Unit (
        UPropertyRecordsID, BuildingID, SDATAccountNumber, --UnitNumber
        UnitTypeCode, UnitStatusCode, IsMPDU, IsActive, CreatedDate, UpdatedDate
    )
    SELECT
        upr.UPropertyRecordsID,
        b.BuildingID,
       --COALESCE(NULLIF(upr.UnitNumber, N''), N'U1'),
        upr.SDATAccountNumber,
        CASE upr.PropertyTypeCode WHEN N'CONDO' THEN N'COND' ELSE N'APT' END,
        N'ACTIVE', 0, 1, @Now, @Now  --@RunUser, @RunUser
    FROM dbo.UPROPERTYRECORDS upr
    INNER JOIN dbo.Building b ON b.UPropertyRecordsID = upr.UPropertyRecordsID AND b.BuildingCode = N'MAIN'
    INNER JOIN dbo.REF_PROPERTYTYPE pt ON pt.PropertyTypeCode = upr.PropertyTypeCode
    WHERE upr.PropertyTypeCode IN (N'CONDO', N'APT')
      AND pt.AllowsBuildings = 1 AND pt.AllowsUnits = 1
      AND NOT EXISTS (
          SELECT 1 FROM dbo.Unit u
          WHERE u.UPropertyRecordsID = upr.UPropertyRecordsID
            AND u.BuildingID = b.BuildingID
      );

    INSERT INTO @Stats VALUES (N'Units created', @@ROWCOUNT);

    /* ========================================================================
       11. AUDIT LOG
       ======================================================================== */
    INSERT INTO dbo.AuditLog (EntityName, EntityKey, OperationType, ChangedBy, ChangedDate, ChangeSummary)
    SELECT N'UPROPERTYRECORD', CONVERT(NVARCHAR(200), UPropertyRecordsID), N'INSERT', @RunUser, @Now,
           N'UPR load - record created'
    FROM dbo.UPROPERTYRECORDS WHERE CreatedDate >= @Now;

    INSERT INTO dbo.AuditLog (EntityName, EntityKey, OperationType, ChangedBy, ChangedDate, ChangeSummary)
    SELECT N'UPROPERTYRECORDS_XREF', CONVERT(NVARCHAR(200), UPropertyRecords_XrefID), N'INSERT', @RunUser, @Now,
           CONCAT(N'XREF: ', SourceSystem, N'/', SourceRecordID, N' ', MatchResult)
    FROM dbo.UPROPERTYRECORDS_XREF WHERE CreatedDate >= @Now;

    INSERT INTO dbo.AuditLog (EntityName, EntityKey, OperationType, ChangedBy, ChangedDate, ChangeSummary)
    SELECT N'UPRMATCHREVIEW_Q', CONVERT(NVARCHAR(200), UPRMatchReviewID), N'INSERT', @RunUser, @Now,
           CONCAT(N'Review: ', ReasonForNoMatch)
    FROM dbo.UPRMATCHREVIEW_Q WHERE ProcessingTimestamp >= @Now;

    INSERT INTO @Stats VALUES (N'AuditLog entries written', @@ROWCOUNT);

    COMMIT TRANSACTION;

    /* ========================================================================
       12. PRINT SUMMARY
       ======================================================================== */
    PRINT N'';
    PRINT N'============================================================';
    PRINT N'  UPR LOAD COMPLETE - PROCESSING SUMMARY';
    PRINT N'============================================================';

    DECLARE @metric NVARCHAR(100), @cnt INT;
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT Metric, Cnt FROM @Stats ORDER BY Metric;
    OPEN cur;
    FETCH NEXT FROM cur INTO @metric, @cnt;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        PRINT N'  ' + @metric + N': ' + CAST(@cnt AS NVARCHAR(20));
        FETCH NEXT FROM cur INTO @metric, @cnt;
    END
    CLOSE cur; DEALLOCATE cur;

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

