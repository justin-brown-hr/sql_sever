/*
================================================================================
  UPR Master Load Script
  
  Loads AddressMaster + SDAT, normalizes addresses, populates UPROPERTYRECORDS
  and all related tables (XREF, Review_Q, StatusHistory, Contact, Building/Unit,
  Reference data, AuditLog).

  CLIENT RULES:
    MA↔SDAT match — Account# AND valid normalized address ONLY (no ParcelID) to avoid UPR dupes
    UPR  — valid Account# + valid address + ParcelID (MA/SDAT match not required)
    Review_Q — NOT written to UPR: invalid account/address, missing ParcelID, or Duplicate
               ReasonForNoMatch: NO_PARCEL_MATCH | NO_ADDRESS_MATCH | DUPLICATE only
               All Review_Q candidates are inserted (incoming REJECTED XREF + Review_Q row)
    External XREF (eProperty, CASE, MPDU, MULTIFAMILY) — address/normalized-address match only;
               always write XREF per UPR per system: MATCH or NO_MATCH (Notes: No Address Match)
    External non-match does NOT send rows to Review_Q

  MA Unit held in #Work/#UPRMap only — loaded to dbo.Unit (UPR has no unit column).
  UPR NOT NULL columns DDL: SDATAccountNumber, StreetNumber, StreetName,
  StreetType, City, ZipCode, NormalizedStreetAddress, NormalizedFullAddress, PropertyStatusCode,
  Aligns with docs/ddl.md CHECK: ZipCode #####/#####-####, State 2 uppercase A-Z,
  PropertyStatusCode ACTIVE|INACTIVE|PENDING|RETIRED. Column NormalizedFullAddress per DDL.

  DHCA SOURCE DATA:
    DHCA_Internal.dbo.MasterAddress
    DHCA_Internal.dbo.RealPropertyTaxInformation
    DHCA_LicensingAndRegistration.dbo.Property
    DHCA_OLTA.dbo.[Case]
    DHCA_MPDU.dbo.Development
    DHCA_MultifamilyLoans.dbo.Address

  ROBUSTNESS:
    Preflight checks required tables/columns before any writes
    REF seeds populate IsActive, CreatedDate, UpdatedDate, audit user IDs
    Application source reads wrapped in TRY/CATCH (external sources warn, MA/SDAT fail clear)
    UPR MERGE guarded against SDAT/address/parcel duplicates and invalid rows
    Safe to re-run (idempotent MERGE / NOT EXISTS patterns)

  ================================================================================
*/
USE UPRXDB_TEST;  
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
        SET @s = LTRIM(RTRIM(@prefix + N' ' + ISNULL(dbo.fn_UPR_StdStreetToken(@lastToken), N'')));
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

/* Numeric SDAT accounts — zero-pad to 8 so 31023 and 00031023 dedupe/MERGE consistently */
CREATE OR ALTER FUNCTION dbo.fn_UPR_NormalizeSDATAccount (@acct NVARCHAR(50))
RETURNS NVARCHAR(50)
AS
BEGIN
    DECLARE @s NVARCHAR(50) = NULLIF(LTRIM(RTRIM(ISNULL(@acct, N''))), N'');
    IF @s IS NULL RETURN NULL;
    IF @s NOT LIKE N'%[^0-9]%' AND LEN(@s) BETWEEN 1 AND 12
        RETURN RIGHT(REPLICATE(N'0', 8) + @s, 8);
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
    RETURN LTRIM(RTRIM(
        ISNULL(dbo.fn_UPR_NormalizeAddressLine(@line), N'') + N' ' +
        UPPER(LTRIM(RTRIM(ISNULL(@city, N'')))) + N' ' +
        LEFT(REPLACE(dbo.fn_UPR_NormalizeZipCode(@zip), N'-', N''), 5)
    ));
END;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @RunUser NVARCHAR(100) = SUSER_SNAME();
DECLARE @AuditUser NVARCHAR(128) = COALESCE(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(128), SUSER_SNAME()))), N''), N'SYSTEM');
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
DECLARE @ReviewNoParcel INT = 0, @ReviewDuplicate INT = 0, @ReviewIncomplete INT = 0;
DECLARE @ReviewSkippedNoAnchor INT = 0;
DECLARE @ReviewAnchorCount INT = 0;
DECLARE @ReviewAnchorStaged INT = 0;
DECLARE @EPropertyXrefNoMatch INT = 0, @CaseXrefNoMatch INT = 0;
DECLARE @MPDUXrefNoMatch INT = 0, @MultifamilyXrefNoMatch INT = 0;
DECLARE @StatusHistoryInserted INT = 0, @AuditInserted INT = 0;
DECLARE @BuildingInserted INT = 0, @UnitInserted INT = 0, @ContactInserted INT = 0, @PropertyContactInserted INT = 0;
DECLARE @BatchEndTime DATETIME2(0);
DECLARE @UprCountBefore INT = 0;
DECLARE @UprMergeRowsAffected INT = 0;
DECLARE @Sql NVARCHAR(MAX);
DECLARE @PreflightErrors NVARCHAR(MAX) = N'';
DECLARE @SourceWarning NVARCHAR(500);
DECLARE @ErrorMessage  NVARCHAR(500);

/* Resolve audit-user column names */
DECLARE @RefUserCreateCol SYSNAME = CASE
    WHEN COL_LENGTH('dbo.REF_PROPERTYTYPE', 'CreationUserID')  IS NOT NULL THEN N'CreationUserID'
    WHEN COL_LENGTH('dbo.REF_PROPERTYTYPE', 'CreationUSERID')  IS NOT NULL THEN N'CreationUSERID'
    ELSE NULL END;
DECLARE @RefUserUpdateCol SYSNAME = CASE
    WHEN COL_LENGTH('dbo.REF_PROPERTYTYPE', 'LastUpdatedUserID')  IS NOT NULL THEN N'LastUpdatedUserID'
    WHEN COL_LENGTH('dbo.REF_PROPERTYTYPE', 'LastUpdatedUSERID')  IS NOT NULL THEN N'LastUpdatedUSERID'
    ELSE NULL END;

/* ========================================================================
   SCHEMA FIX (outside transaction — persists even if load fails/rolls back)
   Rebuild Review_Q ReasonForNoMatch CHECK every run; verify DUPLICATE allowed.
   ======================================================================== */
IF OBJECT_ID(N'dbo.UPRMATCHREVIEW_Q', N'U') IS NOT NULL
BEGIN
    DECLARE @ReviewCkDrop NVARCHAR(MAX) = N'';
    SELECT @ReviewCkDrop = @ReviewCkDrop
        + N'ALTER TABLE dbo.UPRMATCHREVIEW_Q DROP CONSTRAINT '
        + QUOTENAME(cc.name) + N';' + CHAR(13)
    FROM sys.check_constraints cc
    WHERE cc.parent_object_id = OBJECT_ID(N'dbo.UPRMATCHREVIEW_Q')
      AND cc.definition LIKE N'%ReasonForNoMatch%';

    IF @ReviewCkDrop <> N''
        EXEC sys.sp_executesql @ReviewCkDrop;

    IF EXISTS (
        SELECT 1
        FROM sys.check_constraints cc
        WHERE cc.parent_object_id = OBJECT_ID(N'dbo.UPRMATCHREVIEW_Q')
          AND cc.name = N'CK_UPRMATCHREVIEW_Q_ReasonForNoMatch'
    )
        ALTER TABLE dbo.UPRMATCHREVIEW_Q DROP CONSTRAINT CK_UPRMATCHREVIEW_Q_ReasonForNoMatch;

    ALTER TABLE dbo.UPRMATCHREVIEW_Q ADD CONSTRAINT CK_UPRMATCHREVIEW_Q_ReasonForNoMatch
        CHECK (ReasonForNoMatch IN (
            N'NO_PARCEL_MATCH',
            N'NO_SDAT_MATCH',
            N'NO_ADDRESS_MATCH',
            N'INSUFFICIENT_DATA',
            N'AMBIGUOUS_CANDIDATES',
            N'DUPLICATE',
            N'LOW_CONFIDENCE_ONLY',
            N'SOURCE_RECORD_ERROR',
            N'OTHER'
        ));

    IF NOT EXISTS (
        SELECT 1
        FROM sys.check_constraints cc
        WHERE cc.parent_object_id = OBJECT_ID(N'dbo.UPRMATCHREVIEW_Q')
          AND cc.name = N'CK_UPRMATCHREVIEW_Q_ReasonForNoMatch'
          AND cc.definition LIKE N'%DUPLICATE%'
    )
        THROW 50021,
            N'Schema repair failed: UPRMATCHREVIEW_Q ReasonForNoMatch CHECK must allow DUPLICATE. Run as user with ALTER permission.',
            1;

    PRINT N'Schema: Review_Q ReasonForNoMatch CHECK rebuilt and verified (includes DUPLICATE).';
END

BEGIN TRY
    BEGIN TRANSACTION;

    /* ========================================================================
       0. PREFLIGHT — required tables / functions before any writes
       ======================================================================== */
    SELECT @PreflightErrors = STRING_AGG(v.ObjName, N', ')
    FROM (VALUES
        (N'dbo.UPROPERTYRECORDS',        N'UPROPERTYRECORDS'),
        (N'dbo.UPROPERTYRECORDS_XREF',   N'UPROPERTYRECORDS_XREF'),
        (N'dbo.UPRMATCHREVIEW_Q',        N'UPRMATCHREVIEW_Q'),
        (N'dbo.UPRSTATUSHISTORY',        N'UPRSTATUSHISTORY'),
        (N'dbo.AuditLog',                N'AuditLog'),
        (N'dbo.REF_PROPERTYTYPE',        N'REF_PROPERTYTYPE'),
        (N'dbo.REF_SOURCESYSTEM',        N'REF_SOURCESYSTEM'),
        (N'dbo.REF_MATCHMETHOD',         N'REF_MATCHMETHOD'),
        (N'dbo.REF_MATCHCONFIDENCE',     N'REF_MATCHCONFIDENCE')
    ) AS v(ObjName, Label)
    WHERE OBJECT_ID(v.ObjName, N'U') IS NULL;

   
    SET @ErrorMessage = N'Missing required tables: ' + @PreflightErrors + N'. Recreate UPR schema DDL (docs/ddl.md), then re-run.';
    IF @PreflightErrors IS NOT NULL
       THROW 50001, @ErrorMessage, 1;

    IF OBJECT_ID(N'dbo.fn_UPR_NormalizeZipCode', N'FN') IS NULL
        OR OBJECT_ID(N'dbo.fn_UPR_NormalizeSDATAccount', N'FN') IS NULL
        THROW 50002,
            N'Normalization functions not found. Run this script from the beginning (includes CREATE FUNCTION block).',
            1;

    IF COL_LENGTH('dbo.REF_MATCHCONFIDENCE', 'IsActive') IS NULL
        THROW 50003,
            N'REF_MATCHCONFIDENCE.IsActive column missing. Recreate REF tables from client DDL.',
            1;

    IF @RefUserCreateCol IS NULL OR @RefUserUpdateCol IS NULL
        THROW 50004,
            N'REF_PROPERTYTYPE audit columns (CreationUserID / LastUpdatedUserID) missing. Recreate from client DDL.',
            1;

    PRINT N'Preflight OK - database: ' + DB_NAME() + N' | started: ' + CONVERT(NVARCHAR(30), @BatchStartTime, 120);

    /* ========================================================================
       1. ENSURE REFERENCE DATA (idempotent — all NOT NULL / audit columns per DDL)
       ======================================================================== */
    SET @Sql = N'
    MERGE dbo.REF_PROPERTYTYPE AS t
    USING (VALUES
        (N''APT'',   N''Apartment Complex'',     1, 1),
        (N''CONDO'', N''Condominium Property'',  1, 1),
        (N''TH'',    N''Townhouse Community'',   1, 1),
        (N''MULTI'', N''Multi-Family Property'', 1, 1),
        (N''SF'',    N''Single Family Property'',1, 0),
        (N''LAND'',  N''Vacant Land'',           0, 0),
        (N''MIXED'', N''Mixed Use Property'',    1, 1)
    ) AS s(Code, Name, AllowBldg, AllowUnit)
    ON t.PropertyTypeCode = s.Code
    WHEN MATCHED THEN UPDATE SET
        t.PropertyTypeName    = s.Name,
        t.AllowsBuildings     = s.AllowBldg,
        t.AllowsUnits         = s.AllowUnit,
        t.DeletedInd          = 0,
        t.' + QUOTENAME(@RefUserCreateCol) + N' = COALESCE(NULLIF(t.' + QUOTENAME(@RefUserCreateCol) + N', N''''), @AuditUser),
        t.CreationDate        = COALESCE(t.CreationDate, @Now),
        t.' + QUOTENAME(@RefUserUpdateCol) + N' = COALESCE(NULLIF(t.' + QUOTENAME(@RefUserUpdateCol) + N', N''''), @AuditUser),
        t.LastUpdatedDate     = @Now
    WHEN NOT MATCHED THEN
        INSERT (
            PropertyTypeCode, PropertyTypeName, AllowsBuildings, AllowsUnits, DeletedInd,
            ' + QUOTENAME(@RefUserCreateCol) + N', CreationDate, ' + QUOTENAME(@RefUserUpdateCol) + N', LastUpdatedDate
        )
        VALUES (s.Code, s.Name, s.AllowBldg, s.AllowUnit, 0, @AuditUser, @Now, @AuditUser, @Now);';
    EXEC sys.sp_executesql @Sql,
        N'@AuditUser NVARCHAR(128), @Now DATETIME2(0)',
        @AuditUser = @AuditUser, @Now = @Now;

    IF OBJECT_ID('dbo.REF_PROPERTY_STATUSCODE', 'U') IS NOT NULL
    BEGIN
        MERGE dbo.REF_PROPERTY_STATUSCODE AS t
        USING (VALUES
            (N'ACTIVE',   N'Active property'),
            (N'INACTIVE', N'Inactive property'),
            (N'PENDING',  N'Pending property'),
            (N'RETIRED',  N'Retired property')
        ) AS s(Code, Descr)
        ON t.StatusCode = s.Code
        WHEN MATCHED THEN UPDATE SET
            t.[Description]       = s.Descr,
            t.DeletedInd          = 0,
            t.CreationUserID      = COALESCE(NULLIF(t.CreationUserID, N''), @AuditUser),
            t.CreationDate        = COALESCE(t.CreationDate, @Now),
            t.LastUpdatedUserID   = COALESCE(NULLIF(t.LastUpdatedUserID, N''), @AuditUser),
            t.LastUpdatedDate     = @Now
        WHEN NOT MATCHED THEN
            INSERT (StatusCode, [Description], DeletedInd, CreationUserID, CreationDate, LastUpdatedUserID, LastUpdatedDate)
            VALUES (s.Code, s.Descr, 0, @AuditUser, @Now, @AuditUser, @Now);
    END;

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
    WHEN MATCHED THEN UPDATE SET
        t.SourceSystemName = s.Name,
        t.[Description]    = s.Descr,
        t.IsActive         = 1,
        t.CreatedDate      = COALESCE(t.CreatedDate, @Now),
        t.UpdatedDate      = @Now
    WHEN NOT MATCHED THEN
        INSERT (SourceSystemCode, SourceSystemName, [Description], IsActive, CreatedDate, UpdatedDate)
        VALUES (s.Code, s.Name, s.Descr, 1, @Now, @Now);

    IF COL_LENGTH('dbo.REF_MATCHMETHOD', 'IsAutomated') IS NOT NULL
    BEGIN
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
        WHEN MATCHED THEN UPDATE SET
            t.MatchMethodName = s.Name,
            t.[Description]   = s.Descr,
            t.IsAutomated     = 1,
            t.IsActive        = 1,
            t.CreatedDate     = COALESCE(t.CreatedDate, @Now),
            t.UpdatedDate     = @Now
        WHEN NOT MATCHED THEN
            INSERT (
                MatchMethodCode, MatchMethodName, [Description],
                IsAutomated, IsActive, CreatedDate, UpdatedDate
            )
            VALUES (s.Code, s.Name, s.Descr, 1, 1, @Now, @Now);
    END
    ELSE
    BEGIN
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
        WHEN MATCHED THEN UPDATE SET
            t.MatchMethodName = s.Name,
            t.[Description]   = s.Descr,
            t.IsActive        = 1,
            t.CreatedDate     = COALESCE(t.CreatedDate, @Now),
            t.UpdatedDate     = @Now
        WHEN NOT MATCHED THEN
            INSERT (MatchMethodCode, MatchMethodName, [Description], IsActive, CreatedDate, UpdatedDate)
            VALUES (s.Code, s.Name, s.Descr, 1, @Now, @Now);
    END;

    MERGE dbo.REF_MATCHCONFIDENCE AS t
    USING (VALUES
        (N'HIGH',     N'High',     100, N'Very reliable'),
        (N'MEDIUM',   N'Medium',    75, N'Likely'),
        (N'LOW',      N'Low',       55, N'Uncertain'),
        (N'VERIFIED', N'Verified', 110, N'Human verified'),
        (N'NONE',     N'None',       0, N'No confidence assigned')
    ) AS s(Code, Name, RankVal, Descr)
    ON t.MatchConfidenceCode = s.Code
    WHEN MATCHED THEN UPDATE SET
        t.MatchConfidenceName = s.Name,
        t.ConfidenceRank      = s.RankVal,
        t.[Description]       = s.Descr,
        t.IsActive            = 1,
        t.CreationDate        = COALESCE(t.CreationDate, @Now),
        t.UpdatedDate         = @Now
    WHEN NOT MATCHED THEN
        INSERT (
            MatchConfidenceCode, MatchConfidenceName, ConfidenceRank, [Description],
            IsActive, CreationDate, UpdatedDate
        )
        VALUES (s.Code, s.Name, s.RankVal, s.Descr, 1, @Now, @Now);

    IF OBJECT_ID('dbo.REF_BUILDINGTYPE', 'U') IS NOT NULL
    BEGIN
        SET @Sql = N'
        MERGE dbo.REF_BUILDINGTYPE AS t
        USING (VALUES
            (N''MAIN'', N''Main building'', N''Default main structure'', 1)
        ) AS s(Code, Name, Descr, IsRes)
        ON t.BuildingTypeCode = s.Code
        WHEN MATCHED THEN UPDATE SET
            t.BuildingTypeName    = s.Name,
            t.[Description]       = s.Descr,
            t.IsResidential       = s.IsRes,
            t.IsActive            = 1,
            t.DeletedInd          = 0,
            t.' + QUOTENAME(@RefUserCreateCol) + N' = COALESCE(NULLIF(t.' + QUOTENAME(@RefUserCreateCol) + N', N''''), @AuditUser),
            t.CreationDate        = COALESCE(t.CreationDate, @Now),
            t.' + QUOTENAME(@RefUserUpdateCol) + N' = COALESCE(NULLIF(t.' + QUOTENAME(@RefUserUpdateCol) + N', N''''), @AuditUser),
            t.LastUpdatedDate     = @Now
        WHEN NOT MATCHED THEN
            INSERT (
                BuildingTypeCode, BuildingTypeName, [Description],
                IsResidential, IsActive, DeletedInd,
                ' + QUOTENAME(@RefUserCreateCol) + N', CreationDate, ' + QUOTENAME(@RefUserUpdateCol) + N', LastUpdatedDate
            )
            VALUES (s.Code, s.Name, s.Descr, s.IsRes, 1, 0, @AuditUser, @Now, @AuditUser, @Now);';
        EXEC sys.sp_executesql @Sql,
            N'@AuditUser NVARCHAR(128), @Now DATETIME2(0)',
            @AuditUser = @AuditUser, @Now = @Now;
    END;

    IF OBJECT_ID('dbo.REF_UNITTYPECODE', 'U') IS NOT NULL
    BEGIN
        SET @Sql = N'
        MERGE dbo.REF_UNITTYPECODE AS t
        USING (VALUES
            (N''APT'',   N''Apartment unit'',   N''Apartment''),
            (N''CONDO'', N''Condo unit'',       N''Condominium unit'')
        ) AS s(Code, Name, Descr)
        ON t.UnitTypeCode = s.Code
        WHEN MATCHED THEN UPDATE SET
            t.UnitTypeName      = s.Name,
            t.[Description]     = s.Descr,
            t.IsActive          = 1,
            t.DeletedInd        = 0,
            t.' + QUOTENAME(@RefUserCreateCol) + N' = COALESCE(NULLIF(t.' + QUOTENAME(@RefUserCreateCol) + N', N''''), @AuditUser),
            t.CreationDate      = COALESCE(t.CreationDate, @Now),
            t.' + QUOTENAME(@RefUserUpdateCol) + N' = COALESCE(NULLIF(t.' + QUOTENAME(@RefUserUpdateCol) + N', N''''), @AuditUser),
            t.LastUpdatedDate   = @Now
        WHEN NOT MATCHED THEN
            INSERT (
                UnitTypeCode, UnitTypeName, [Description],
                IsActive, DeletedInd, ' + QUOTENAME(@RefUserCreateCol) + N', CreationDate, ' + QUOTENAME(@RefUserUpdateCol) + N', LastUpdatedDate
            )
            VALUES (s.Code, s.Name, s.Descr, 1, 0, @AuditUser, @Now, @AuditUser, @Now);';
        EXEC sys.sp_executesql @Sql,
            N'@AuditUser NVARCHAR(128), @Now DATETIME2(0)',
            @AuditUser = @AuditUser, @Now = @Now;
    END;

    IF OBJECT_ID('dbo.REF_STATUSCODE', 'U') IS NOT NULL
    BEGIN
        MERGE dbo.REF_STATUSCODE AS t
        USING (VALUES
            (N'ACTIVE',   N'UNIT', N'Active',   N'Active unit'),
            (N'INACTIVE', N'UNIT', N'Inactive', N'Inactive unit'),
            (N'VACANT',   N'UNIT', N'Vacant',   N'Vacant unit'),
            (N'OCCUPIED', N'UNIT', N'Occupied', N'Occupied unit')
        ) AS s(Code, Entity, Name, Descr)
        ON t.StatusCode = s.Code AND t.EntityType = s.Entity
        WHEN MATCHED THEN UPDATE SET
            t.StatusName          = s.Name,
            t.[Description]       = s.Descr,
            t.DeletedInd          = 0,
            t.CreationUserID      = COALESCE(NULLIF(t.CreationUserID, N''), @AuditUser),
            t.CreationDate        = COALESCE(t.CreationDate, @Now),
            t.LastUpdatedUserID   = COALESCE(NULLIF(t.LastUpdatedUserID, N''), @AuditUser),
            t.LastUpdatedDate     = @Now
        WHEN NOT MATCHED THEN
            INSERT (StatusCode, EntityType, StatusName, [Description], DeletedInd, CreationUserID, CreationDate, LastUpdatedUserID, LastUpdatedDate)
            VALUES (s.Code, s.Entity, s.Name, s.Descr, 0, @AuditUser, @Now, @AuditUser, @Now);
    END;

    /* ========================================================================
       2. NORMALIZE AddressMaster
       ======================================================================== */
    IF OBJECT_ID('tempdb..#MA') IS NOT NULL DROP TABLE #MA;

    BEGIN TRY
    SELECT
        ma.MasterAddressID,
        SourceSystem         = N'ADDRESS_MASTER',
        SourceRecordID       = CONVERT(VARCHAR(100), ma.MasterAddressID),
        SourceEntityType     = N'MasterAddress',
        MasterAddressAccount = dbo.fn_UPR_NormalizeSDATAccount(
            NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), ma.Account))), N'')),
        SDATAccountNumber    = dbo.fn_UPR_NormalizeSDATAccount(
            NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), ma.Account))), N'')),
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
        NormalizedStreetAddress    = UPPER(LTRIM(RTRIM(
            ISNULL(dbo.fn_UPR_NormalizeStreetNumber(CONVERT(NVARCHAR(20), ma.StreetNumber)), N'') + N' ' +
            ISNULL(UPPER(LTRIM(RTRIM(ma.StreetName))), N'') + N' ' +
            CASE UPPER(LTRIM(RTRIM(ma.StreetType)))
                WHEN N'STREET' THEN N'ST' WHEN N'AVENUE' THEN N'AVE' WHEN N'ROAD' THEN N'RD'
                WHEN N'LANE' THEN N'LN'   WHEN N'COURT' THEN N'CT'  WHEN N'DRIVE' THEN N'DR'
                WHEN N'BOULEVARD' THEN N'BLVD' WHEN N'PLACE' THEN N'PL'
                ELSE ISNULL(UPPER(LTRIM(RTRIM(ma.StreetType))), N'')
            END
        ))),
        NormalizedFullAddress = UPPER(LTRIM(RTRIM(
            ISNULL(dbo.fn_UPR_NormalizeStreetNumber(CONVERT(NVARCHAR(20), ma.StreetNumber)), N'') + N' ' +
            ISNULL(UPPER(LTRIM(RTRIM(ma.StreetName))), N'') + N' ' +
            CASE UPPER(LTRIM(RTRIM(ma.StreetType)))
                WHEN N'STREET' THEN N'ST' WHEN N'AVENUE' THEN N'AVE' WHEN N'ROAD' THEN N'RD'
                WHEN N'LANE' THEN N'LN'   WHEN N'COURT' THEN N'CT'  WHEN N'DRIVE' THEN N'DR'
                WHEN N'BOULEVARD' THEN N'BLVD' WHEN N'PLACE' THEN N'PL'
                ELSE ISNULL(UPPER(LTRIM(RTRIM(ma.StreetType))), N'')
            END + N' ' +
            ISNULL(UPPER(LTRIM(RTRIM(ma.City))), N'') + N' ' +
            LEFT(REPLACE(dbo.fn_UPR_NormalizeZipCode(ma.ZipCode), N'-', N''), 5)
        ))),
        HasRequiredAddress   = CASE
            WHEN NULLIF(UPPER(LTRIM(RTRIM(ma.StreetName))), N'') IS NULL THEN 0
            WHEN NULLIF(UPPER(LTRIM(RTRIM(ma.City))), N'') IS NULL THEN 0
            WHEN dbo.fn_UPR_IsValidStreetNumber(ma.StreetNumber) = 0 THEN 0
            WHEN dbo.fn_UPR_IsValidZipCode(ma.ZipCode) = 0 THEN 0
            ELSE 1
        END
    INTO #MA
    FROM dbo.MAIncomingTableX1 ma  --DHCA_Internal.dbo.MasterAddress ma;
    END TRY
    BEGIN CATCH
        SET @ErrorMessage = N'Cannot read MasterAddress source: ' + ERROR_MESSAGE()
            + N' - verify table access (dbo.MAIncomingTableX1 or DHCA_Internal.dbo.MasterAddress).';
        THROW 50010, @ErrorMessage, 1;
    END CATCH;

    SET @MasterAddressRead = (SELECT COUNT(*) FROM #MA);
    PRINT N'Step 2 complete - MasterAddress rows: ' + CONVERT(NVARCHAR(20), @MasterAddressRead);

    /* ========================================================================
       3. NORMALIZE SDAT  
       ======================================================================== */
    IF OBJECT_ID('tempdb..#SDAT') IS NOT NULL DROP TABLE #SDAT;

    BEGIN TRY
    SELECT
        KdatRecordID         = TRY_CONVERT(INT, s.RealPropertyTaxInformationID),
        SourceSystem         = N'KDAT',
        SourceRecordID       = CONVERT(VARCHAR(100), s.RealPropertyTaxInformationID),
        SourceEntityType     = N'SDATProperty',
        MasterAddressAccount = NULL,
        SDATAccountNumber    = dbo.fn_UPR_NormalizeSDATAccount(
            NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), s.AccountNumber))), N'')),
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
        NormalizedStreetAddress    = UPPER(LTRIM(RTRIM(
            ISNULL(dbo.fn_UPR_NormalizeStreetNumber(LTRIM(RTRIM(s.PremisesNumber))), N'') + N' ' +
            ISNULL(UPPER(LTRIM(RTRIM(s.PremisesStreetName))), N'') + N' ' +
            CASE UPPER(LTRIM(RTRIM(s.PremisesStreetType)))
                WHEN N'STREET' THEN N'ST' WHEN N'AVENUE' THEN N'AVE' WHEN N'ROAD' THEN N'RD'
                WHEN N'LANE' THEN N'LN'   WHEN N'COURT' THEN N'CT'  WHEN N'DRIVE' THEN N'DR'
                WHEN N'BOULEVARD' THEN N'BLVD' WHEN N'PLACE' THEN N'PL'
                ELSE ISNULL(UPPER(LTRIM(RTRIM(s.PremisesStreetType))), N'')
            END
        ))),
        NormalizedFullAddress = UPPER(LTRIM(RTRIM(
            ISNULL(dbo.fn_UPR_NormalizeStreetNumber(LTRIM(RTRIM(s.PremisesNumber))), N'') + N' ' +
            ISNULL(UPPER(LTRIM(RTRIM(s.PremisesStreetName))), N'') + N' ' +
            CASE UPPER(LTRIM(RTRIM(s.PremisesStreetType)))
                WHEN N'STREET' THEN N'ST' WHEN N'AVENUE' THEN N'AVE' WHEN N'ROAD' THEN N'RD'
                WHEN N'LANE' THEN N'LN'   WHEN N'COURT' THEN N'CT'  WHEN N'DRIVE' THEN N'DR'
                WHEN N'BOULEVARD' THEN N'BLVD' WHEN N'PLACE' THEN N'PL'
                ELSE ISNULL(UPPER(LTRIM(RTRIM(s.PremisesStreetType))), N'')
            END + N' ' +
            ISNULL(UPPER(LTRIM(RTRIM(s.PremisesCity))), N'') + N' ' +
            LEFT(REPLACE(dbo.fn_UPR_NormalizeZipCode(s.PremisesZipCode), N'-', N''), 5)
        ))),
        HasRequiredAddress   = CASE
            WHEN NULLIF(UPPER(LTRIM(RTRIM(s.PremisesStreetName))), N'') IS NULL THEN 0
            WHEN NULLIF(UPPER(LTRIM(RTRIM(s.PremisesCity))), N'') IS NULL THEN 0
            WHEN dbo.fn_UPR_IsValidStreetNumber(s.PremisesNumber) = 0 THEN 0
            WHEN dbo.fn_UPR_IsValidZipCode(s.PremisesZipCode) = 0 THEN 0
            ELSE 1
        END
    INTO #SDAT
    FROM dbo.SDATIncomingTableX1 s; --DHCA_Internal.dbo.RealPropertyTaxInformation s;
    END TRY
    BEGIN CATCH
        SET @ErrorMessage = N'Cannot read SDAT source: ' + ERROR_MESSAGE()
            + N' - verify table access (dbo.SDATIncomingTableX1 or DHCA_Internal.dbo.RealPropertyTaxInformation).';
        THROW 50011, @ErrorMessage, 1;
    END CATCH;

    SET @SDATRead = (SELECT COUNT(*) FROM #SDAT);
    PRINT N'Step 3 complete - SDAT rows: ' + CONVERT(NVARCHAR(20), @SDATRead);

    /* ========================================================================
       4. MATCH AddressMaster <-> SDAT → unified #Work
       Match ONLY when Account# AND normalized address both match (no ParcelID).
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
        MatchPriority = 1
    INTO #MaSdMatch
    FROM #MA ma
    INNER JOIN #SDAT sd
        ON ma.MasterAddressAccount IS NOT NULL
       AND ma.MasterAddressAccount = sd.SDATAccountNumber
       AND (
            ma.NormalizedStreetAddress = sd.NormalizedStreetAddress
            OR ma.NormalizedFullAddress = sd.NormalizedFullAddress
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

    CREATE NONCLUSTERED INDEX IX_Work_MasterAddressID ON #Work(MasterAddressID)
        WHERE MasterAddressID IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_Work_KdatRecordID ON #Work(KdatRecordID)
        WHERE KdatRecordID IS NOT NULL;

    PRINT N'Step 4 complete - unified #Work rows: ' + CONVERT(NVARCHAR(20), @IncomingUnifiedRows);

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
        EffectiveSDATAccountNumber = dbo.fn_UPR_NormalizeSDATAccount(
            NULLIF(LTRIM(RTRIM(COALESCE(w.SDATAccountNumber, w.MasterAddressAccount))), N'')),
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
        EffectiveNormalizedFullAddress  = LEFT(
            COALESCE(
                NULLIF(LTRIM(RTRIM(w.NormalizedFullAddress)), N''),
                NULLIF(LTRIM(RTRIM(w.NormalizedStreetAddress)), N''),
                LEFT(NULLIF(dbo.fn_UPR_NormalizeStreetNumber(w.StreetNumber), N''), 20) + N' ' +
                LEFT(NULLIF(UPPER(LTRIM(RTRIM(w.StreetName))), N''), 100) + N' ' +
                LEFT(COALESCE(NULLIF(UPPER(LTRIM(RTRIM(w.StreetType))), N''), N'UNK'), 4) + N' ' +
                LEFT(NULLIF(UPPER(LTRIM(RTRIM(w.City))), N''), 100) + N' ' +
                dbo.fn_UPR_NormalizeZipCode(w.ZipCode)
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
            WHEN NULLIF(LTRIM(RTRIM(COALESCE(w.SDATAccountNumber, w.MasterAddressAccount, N''))), N'') IS NULL THEN 0
            WHEN dbo.fn_UPR_IsValidStreetNumber(w.StreetNumber) = 0 THEN 0
            WHEN dbo.fn_UPR_IsValidZipCode(w.ZipCode) = 0 THEN 0
            WHEN NULLIF(UPPER(LTRIM(RTRIM(w.StreetName))), N'') IS NULL THEN 0
            WHEN NULLIF(UPPER(LTRIM(RTRIM(w.City))), N'') IS NULL THEN 0
            WHEN NULLIF(LTRIM(RTRIM(COALESCE(w.ParcelID, N''))), N'') IS NULL THEN 0
            ELSE 1
        END,
        NeedsNoParcelReview = CASE
            WHEN NULLIF(LTRIM(RTRIM(COALESCE(w.SDATAccountNumber, w.MasterAddressAccount, N''))), N'') IS NULL THEN 0
            WHEN dbo.fn_UPR_IsValidStreetNumber(w.StreetNumber) = 0 THEN 0
            WHEN dbo.fn_UPR_IsValidZipCode(w.ZipCode) = 0 THEN 0
            WHEN NULLIF(UPPER(LTRIM(RTRIM(w.StreetName))), N'') IS NULL THEN 0
            WHEN NULLIF(UPPER(LTRIM(RTRIM(w.City))), N'') IS NULL THEN 0
            WHEN NULLIF(LTRIM(RTRIM(COALESCE(w.ParcelID, N''))), N'') IS NOT NULL THEN 0
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
    CREATE NONCLUSTERED INDEX IX_ReviewPending_Src
        ON #ReviewPending(MasterAddressID, KdatRecordID);

    /* Review_Q staging — invalid identification / no parcel (not UPR-eligible) */
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
            WHEN c.NeedsNoParcelReview = 1 THEN N'NO_PARCEL_MATCH'
            ELSE N'NO_ADDRESS_MATCH'
        END,
        CASE
            WHEN c.NeedsNoParcelReview = 1 THEN N'NoParcelID'
            WHEN NULLIF(LTRIM(RTRIM(COALESCE(w.SDATAccountNumber, w.MasterAddressAccount))), N'') IS NULL
                THEN N'Missing account number'
            WHEN dbo.fn_UPR_IsValidStreetNumber(w.StreetNumber) = 0 THEN N'Invalid street number'
            WHEN dbo.fn_UPR_IsValidZipCode(w.ZipCode) = 0 THEN N'Invalid zip code'
            WHEN NULLIF(UPPER(LTRIM(RTRIM(w.StreetName))), N'') IS NULL THEN N'Missing street name'
            WHEN NULLIF(UPPER(LTRIM(RTRIM(w.City))), N'') IS NULL THEN N'Missing city'
            WHEN w.HasRequiredAddress = 0 THEN N'Invalid or incomplete address'
            ELSE N'Invalid account or address'
        END,
        w.StreetNumber, w.StreetName, w.StreetType, w.ZipCode,
        COALESCE(
            dbo.fn_UPR_NormalizeSDATAccount(
                NULLIF(LTRIM(RTRIM(COALESCE(w.SDATAccountNumber, w.MasterAddressAccount))), N'')),
            CASE WHEN w.MasterAddressID IS NOT NULL
                 THEN N'MA-' + CONVERT(NVARCHAR(20), w.MasterAddressID) END,
            CASE WHEN w.KdatRecordID IS NOT NULL
                 THEN N'KDAT-' + CONVERT(NVARCHAR(20), w.KdatRecordID) END,
            N'ADDR-' + CONVERT(NVARCHAR(20), ABS(CHECKSUM(
                COALESCE(NULLIF(w.NormalizedFullAddress, N''), w.NormalizedStreetAddress, N'UNKNOWN')
            )))
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
            PARTITION BY
                c.EffectiveSDATAccountNumber,
                COALESCE(c.EffectiveNormalizedFullAddress, c.EffectiveNormalizedStreetAddress)
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
        N'DUPLICATE', N'Duplicate account and normalized address in batch',
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
        r.EffectiveNormalizedStreetAddress, r.EffectiveNormalizedFullAddress,
        r.EffectiveLatitude, r.EffectiveLongitude, r.EffectiveOwnerName, r.EffectivePropertyType
    INTO #UprMergeSrc
    FROM #UprMergeRanked r
    WHERE r.PropertyRn = 1;

    /* Final MERGE safety — drop rows that would violate UPR NOT NULL / CHECK */
    INSERT INTO #ReviewPending (
        MasterAddressID, KdatRecordID, MatchSource, NormalizedIncomingAddress,
        ParcelID, SDATAccountNumber, ReasonForNoMatch, ReviewDetail,
        StreetNumber, StreetName, StreetType, ZipCode, EffectiveSDATAccountNumber
    )
    SELECT
        w.MasterAddressID, w.KdatRecordID, w.MatchSource,
        COALESCE(w.NormalizedFullAddress, w.NormalizedStreetAddress, N'UNKNOWN'),
        w.ParcelID, w.SDATAccountNumber,
        N'NO_ADDRESS_MATCH', N'Failed final UPR validation before insert',
        w.StreetNumber, w.StreetName, w.StreetType, w.ZipCode,
        s.EffectiveSDATAccountNumber
    FROM #UprMergeSrc s
    INNER JOIN #Work w
        ON (w.MasterAddressID IS NOT NULL AND w.MasterAddressID = s.MasterAddressID)
        OR (w.KdatRecordID IS NOT NULL AND w.KdatRecordID = s.KdatRecordID)
    WHERE (NULLIF(s.EffectiveStreetNumber, N'') IS NULL
       OR NULLIF(s.EffectiveStreetName, N'') IS NULL
       OR NULLIF(s.EffectiveCity, N'') IS NULL
       OR NULLIF(s.EffectiveNormalizedStreetAddress, N'') IS NULL
       OR NULLIF(s.EffectiveNormalizedFullAddress, N'') IS NULL
       OR dbo.fn_UPR_IsValidZipCode(s.EffectiveZipCode) = 0
       OR NULLIF(s.EffectiveSDATAccountNumber, N'') IS NULL
       OR NULLIF(s.EffectiveParcelID, N'') IS NULL)
      AND NOT EXISTS (
          SELECT 1
          FROM #ReviewPending rp
          WHERE ISNULL(rp.MasterAddressID, -1) = ISNULL(w.MasterAddressID, -1)
            AND ISNULL(rp.KdatRecordID, -1) = ISNULL(w.KdatRecordID, -1)
      );

    DELETE s
    FROM #UprMergeSrc s
    WHERE NULLIF(s.EffectiveStreetNumber, N'') IS NULL
       OR NULLIF(s.EffectiveStreetName, N'') IS NULL
       OR NULLIF(s.EffectiveCity, N'') IS NULL
       OR NULLIF(s.EffectiveNormalizedStreetAddress, N'') IS NULL
       OR NULLIF(s.EffectiveNormalizedFullAddress, N'') IS NULL
       OR dbo.fn_UPR_IsValidZipCode(s.EffectiveZipCode) = 0
       OR NULLIF(s.EffectiveSDATAccountNumber, N'') IS NULL
       OR NULLIF(s.EffectiveParcelID, N'') IS NULL;

    SET @RowsIncompleteData = (
        SELECT COUNT(*)
        FROM #ReviewPending rp
        WHERE rp.ReasonForNoMatch IN (N'NO_PARCEL_MATCH', N'NO_ADDRESS_MATCH')
    );
    SET @RowsReviewDuplicate = (
        SELECT COUNT(*)
        FROM #ReviewPending rp
        WHERE rp.ReasonForNoMatch = N'DUPLICATE'
    );

    /* UQ guard — one scored pass; losers → Review_Q DUPLICATE (set-based, indexed) */
    PRINT N'Step 5b - UPR duplicate-key guard started: ' + CONVERT(NVARCHAR(30), SYSDATETIME(), 120);

    IF OBJECT_ID('tempdb..#ExistingUprKeys') IS NOT NULL DROP TABLE #ExistingUprKeys;

    SELECT
        SDATAccountNumber,
        StreetNumber,
        StreetName,
        StreetType,
        ZipCode,
        ParcelID
    INTO #ExistingUprKeys
    FROM dbo.UPROPERTYRECORDS;

    IF EXISTS (SELECT 1 FROM #ExistingUprKeys)
    BEGIN
        CREATE UNIQUE CLUSTERED INDEX IX_ExistingUpr_SDAT ON #ExistingUprKeys(SDATAccountNumber);
        CREATE UNIQUE INDEX IX_ExistingUpr_Addr
            ON #ExistingUprKeys(StreetNumber, StreetName, StreetType, ZipCode);
        CREATE UNIQUE INDEX IX_ExistingUpr_Parcel ON #ExistingUprKeys(ParcelID)
            WHERE ParcelID IS NOT NULL;
    END

    IF OBJECT_ID('tempdb..#UprMergeScored') IS NOT NULL DROP TABLE #UprMergeScored;

    SELECT
        s.*,
        ROW_NUMBER() OVER (
            PARTITION BY s.EffectiveSDATAccountNumber
            ORDER BY CASE s.MatchSource WHEN N'BOTH' THEN 1 WHEN N'KDAT' THEN 2 ELSE 3 END,
                     s.MasterAddressID, s.KdatRecordID
        ) AS BatchAccountRn,
        ROW_NUMBER() OVER (
            PARTITION BY s.EffectiveStreetNumber, s.EffectiveStreetName, s.EffectiveStreetType, s.EffectiveZipCode
            ORDER BY CASE s.MatchSource WHEN N'BOTH' THEN 1 WHEN N'KDAT' THEN 2 ELSE 3 END,
                     s.MasterAddressID, s.KdatRecordID
        ) AS BatchAddrRn,
        ROW_NUMBER() OVER (
            PARTITION BY s.EffectiveParcelID
            ORDER BY CASE s.MatchSource WHEN N'BOTH' THEN 1 WHEN N'KDAT' THEN 2 ELSE 3 END,
                     s.MasterAddressID, s.KdatRecordID
        ) AS BatchParcelRn
    INTO #UprMergeScored
    FROM #UprMergeSrc s;

    CREATE NONCLUSTERED INDEX IX_UprMergeScored_Ma ON #UprMergeScored(MasterAddressID)
        WHERE MasterAddressID IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_UprMergeScored_Kd ON #UprMergeScored(KdatRecordID)
        WHERE KdatRecordID IS NOT NULL;

    IF OBJECT_ID('tempdb..#UprMergeLosers') IS NOT NULL DROP TABLE #UprMergeLosers;

    SELECT
        s.MasterAddressID,
        s.KdatRecordID,
        s.EffectiveSDATAccountNumber,
        ReviewDetail = CASE
            WHEN s.BatchAccountRn > 1
                THEN N'Duplicate SDAT account key in batch (UQ_UPropertyRecords_SDATAccountNumber)'
            WHEN s.BatchAddrRn > 1
                THEN N'Duplicate address key in batch (UQ_UPropertyRecords_Address)'
            WHEN s.BatchParcelRn > 1
                THEN N'Duplicate parcel key in batch (UQ_UPropertyRecords_ParcelID)'
            WHEN ea.SDATAccountNumber IS NOT NULL
                THEN N'Duplicate address on existing UPR (different account)'
            WHEN ep.SDATAccountNumber IS NOT NULL
                THEN N'Duplicate parcel on existing UPR (different account)'
            ELSE N'UPR unique key collision'
        END
    INTO #UprMergeLosers
    FROM #UprMergeScored s
    LEFT JOIN #ExistingUprKeys ea
        ON ea.StreetNumber = s.EffectiveStreetNumber
       AND ea.StreetName   = s.EffectiveStreetName
       AND ea.StreetType   = s.EffectiveStreetType
       AND ea.ZipCode      = s.EffectiveZipCode
       AND ea.SDATAccountNumber <> s.EffectiveSDATAccountNumber
    LEFT JOIN #ExistingUprKeys ep
        ON ep.ParcelID = s.EffectiveParcelID
       AND ep.SDATAccountNumber <> s.EffectiveSDATAccountNumber
    WHERE s.BatchAccountRn > 1
       OR s.BatchAddrRn > 1
       OR s.BatchParcelRn > 1
       OR ea.SDATAccountNumber IS NOT NULL
       OR ep.SDATAccountNumber IS NOT NULL;

    CREATE NONCLUSTERED INDEX IX_UprMergeLosers_Ma ON #UprMergeLosers(MasterAddressID)
        WHERE MasterAddressID IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_UprMergeLosers_Kd ON #UprMergeLosers(KdatRecordID)
        WHERE KdatRecordID IS NOT NULL;

    INSERT INTO #ReviewPending (
        MasterAddressID, KdatRecordID, MatchSource, NormalizedIncomingAddress,
        ParcelID, SDATAccountNumber, ReasonForNoMatch, ReviewDetail,
        StreetNumber, StreetName, StreetType, ZipCode, EffectiveSDATAccountNumber
    )
    SELECT
        w.MasterAddressID, w.KdatRecordID, w.MatchSource,
        COALESCE(w.NormalizedFullAddress, w.NormalizedStreetAddress, N'UNKNOWN'),
        w.ParcelID, w.SDATAccountNumber,
        N'DUPLICATE', l.ReviewDetail,
        w.StreetNumber, w.StreetName, w.StreetType, w.ZipCode,
        l.EffectiveSDATAccountNumber
    FROM #UprMergeLosers l
    INNER JOIN #Work w ON w.MasterAddressID = l.MasterAddressID
    WHERE l.MasterAddressID IS NOT NULL
      AND NOT EXISTS (
          SELECT 1
          FROM #ReviewPending rp
          WHERE rp.MasterAddressID = w.MasterAddressID
            AND ISNULL(rp.KdatRecordID, -1) = ISNULL(w.KdatRecordID, -1)
      );

    INSERT INTO #ReviewPending (
        MasterAddressID, KdatRecordID, MatchSource, NormalizedIncomingAddress,
        ParcelID, SDATAccountNumber, ReasonForNoMatch, ReviewDetail,
        StreetNumber, StreetName, StreetType, ZipCode, EffectiveSDATAccountNumber
    )
    SELECT
        w.MasterAddressID, w.KdatRecordID, w.MatchSource,
        COALESCE(w.NormalizedFullAddress, w.NormalizedStreetAddress, N'UNKNOWN'),
        w.ParcelID, w.SDATAccountNumber,
        N'DUPLICATE', l.ReviewDetail,
        w.StreetNumber, w.StreetName, w.StreetType, w.ZipCode,
        l.EffectiveSDATAccountNumber
    FROM #UprMergeLosers l
    INNER JOIN #Work w ON w.KdatRecordID = l.KdatRecordID
    WHERE l.MasterAddressID IS NULL
      AND l.KdatRecordID IS NOT NULL
      AND NOT EXISTS (
          SELECT 1
          FROM #ReviewPending rp
          WHERE rp.KdatRecordID = w.KdatRecordID
      );

    DELETE FROM #UprMergeSrc;

    INSERT INTO #UprMergeSrc (
        MasterAddressID, KdatRecordID, MatchSource, HasRequiredAddress,
        SDATAccountNumber, ParcelID, OwnerName,
        EffectiveSDATAccountNumber, EffectiveParcelID,
        EffectiveStreetNumber, EffectiveStreetName, EffectiveStreetType,
        EffectiveCity, EffectiveState, EffectiveZipCode,
        EffectiveNormalizedStreetAddress, EffectiveNormalizedFullAddress,
        EffectiveLatitude, EffectiveLongitude, EffectiveOwnerName, EffectivePropertyType
    )
    SELECT
        s.MasterAddressID, s.KdatRecordID, s.MatchSource, s.HasRequiredAddress,
        s.SDATAccountNumber, s.ParcelID, s.OwnerName,
        s.EffectiveSDATAccountNumber, s.EffectiveParcelID,
        s.EffectiveStreetNumber, s.EffectiveStreetName, s.EffectiveStreetType,
        s.EffectiveCity, s.EffectiveState, s.EffectiveZipCode,
        s.EffectiveNormalizedStreetAddress, s.EffectiveNormalizedFullAddress,
        s.EffectiveLatitude, s.EffectiveLongitude, s.EffectiveOwnerName, s.EffectivePropertyType
    FROM #UprMergeScored s
    LEFT JOIN #UprMergeLosers l
        ON ISNULL(l.MasterAddressID, -1) = ISNULL(s.MasterAddressID, -1)
       AND ISNULL(l.KdatRecordID, -1) = ISNULL(s.KdatRecordID, -1)
    WHERE l.EffectiveSDATAccountNumber IS NULL;

    DROP TABLE #UprMergeScored;
    DROP TABLE #UprMergeLosers;
    /* keep #ExistingUprKeys until after MERGE (parcel conflict check uses temp table, not target table) */

    CREATE NONCLUSTERED INDEX IX_UprMergeSrc_Acct ON #UprMergeSrc(EffectiveSDATAccountNumber);

    SET @UprEligibleRows = (SELECT COUNT(*) FROM #UprMergeSrc);
    PRINT N'Step 5b complete - UPR MERGE candidates: ' + CONVERT(NVARCHAR(20), @UprEligibleRows);

    SET @RowsReviewDuplicate = (
        SELECT COUNT(*)
        FROM #ReviewPending rp
        WHERE rp.ReasonForNoMatch = N'DUPLICATE'
    );

    /* Hard stop if #UprMergeSrc still has duplicate UPR keys (would fail MERGE) */
    IF EXISTS (
        SELECT 1
        FROM (
            SELECT EffectiveSDATAccountNumber
            FROM #UprMergeSrc
            GROUP BY EffectiveSDATAccountNumber
            HAVING COUNT(*) > 1
        ) dup
    )
        THROW 50030, N'Internal guard: duplicate EffectiveSDATAccountNumber in #UprMergeSrc.', 1;

    IF EXISTS (
        SELECT 1
        FROM (
            SELECT EffectiveStreetNumber, EffectiveStreetName, EffectiveStreetType, EffectiveZipCode
            FROM #UprMergeSrc
            GROUP BY EffectiveStreetNumber, EffectiveStreetName, EffectiveStreetType, EffectiveZipCode
            HAVING COUNT(*) > 1
        ) dup
    )
        THROW 50031, N'Internal guard: duplicate address key in #UprMergeSrc.', 1;

    IF EXISTS (
        SELECT 1
        FROM (
            SELECT EffectiveParcelID
            FROM #UprMergeSrc
            WHERE EffectiveParcelID IS NOT NULL
            GROUP BY EffectiveParcelID
            HAVING COUNT(*) > 1
        ) dup
    )
        THROW 50032, N'Internal guard: duplicate EffectiveParcelID in #UprMergeSrc.', 1;

    IF OBJECT_ID('tempdb..#UprMergeReady') IS NOT NULL DROP TABLE #UprMergeReady;

    SELECT
        s.MasterAddressID,
        s.KdatRecordID,
        s.MatchSource,
        s.HasRequiredAddress,
        s.SDATAccountNumber,
        s.ParcelID,
        s.OwnerName,
        s.EffectiveSDATAccountNumber,
        s.EffectiveParcelID,
        s.EffectiveStreetNumber,
        s.EffectiveStreetName,
        s.EffectiveStreetType,
        s.EffectiveCity,
        s.EffectiveState,
        s.EffectiveZipCode,
        s.EffectiveNormalizedStreetAddress,
        s.EffectiveNormalizedFullAddress,
        s.EffectiveLatitude,
        s.EffectiveLongitude,
        s.EffectiveOwnerName,
        s.EffectivePropertyType,
        CAST(CASE WHEN ep.ParcelID IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS ParcelConflict
    INTO #UprMergeReady
    FROM #UprMergeSrc s
    LEFT JOIN #ExistingUprKeys ep
        ON ep.ParcelID = s.EffectiveParcelID
       AND ep.SDATAccountNumber <> s.EffectiveSDATAccountNumber
       AND NULLIF(s.EffectiveParcelID, N'') IS NOT NULL;

    PRINT N'Step 5c - UPR MERGE started: ' + CONVERT(NVARCHAR(30), SYSDATETIME(), 120);

    MERGE dbo.UPROPERTYRECORDS AS upr
    USING #UprMergeReady AS s
    ON upr.SDATAccountNumber = s.EffectiveSDATAccountNumber
    WHEN MATCHED THEN UPDATE SET
        upr.ParcelID          = CASE
            WHEN NULLIF(s.EffectiveParcelID, N'') IS NOT NULL AND s.ParcelConflict = 1 THEN upr.ParcelID
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
        City, [State], ZipCode, NormalizedStreetAddress, NormalizedFullAddress,
        Latitude, Longitude,
        PropertyTypeCode, PropertyStatusCode, IsActive,
        CreatedDate, CreatedBy, UpdatedDate, UpdatedBy
    ) VALUES (
        s.EffectiveSDATAccountNumber, s.EffectiveParcelID, NULL, s.EffectiveOwnerName,
        s.EffectiveStreetNumber, s.EffectiveStreetName, s.EffectiveStreetType,
        s.EffectiveCity, s.EffectiveState, s.EffectiveZipCode,
        s.EffectiveNormalizedStreetAddress, s.EffectiveNormalizedFullAddress,
        s.EffectiveLatitude, s.EffectiveLongitude,
        s.EffectivePropertyType, N'ACTIVE', 1,
        @Now, @RunUser, @Now, @RunUser
    );

    DROP TABLE #ExistingUprKeys;
    DROP TABLE #UprMergeReady;

    PRINT N'Step 5c complete - UPR MERGE finished: ' + CONVERT(NVARCHAR(30), SYSDATETIME(), 120);

    SET @UprMergeRowsAffected = @@ROWCOUNT;
    SET @UPRInserted = (
        SELECT COUNT(*) FROM dbo.UPROPERTYRECORDS
        WHERE CreatedDate >= @Now AND CreatedBy = @RunUser AND PropertyStatusCode = N'ACTIVE'
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
           OR (s.KdatRecordID IS NOT NULL AND w.KdatRecordID = s.KdatRecordID AND s.MasterAddressID IS NULL)
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
    WHERE m.IsNew = 1
      AND NOT EXISTS (
          SELECT 1
          FROM dbo.UPRSTATUSHISTORY h
          WHERE h.UPropertyRecordsID = m.UPropertyRecordsID
            AND h.ChangeReason = N'Initial load - new UPR record'
      );

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
       6b. REVIEW-BOUND ROWS → incoming REJECTED XREF + UPRMATCHREVIEW_Q
           All #ReviewPending rows are written (PENDING anchor UPR when no winner).
       ======================================================================== */
    SET @RowsSentToReview = (SELECT COUNT(*) FROM #ReviewPending);
    PRINT N'Step 6b - Review_Q processing started: ' + CONVERT(NVARCHAR(20), @RowsSentToReview) + N' candidates';
    DECLARE @ReviewXrefOut TABLE (
        UPropertyRecords_XrefID INT NOT NULL,
        MasterAddressID         INT NULL,
        KdatRecordID            INT NULL,
        ReasonForNoMatch        NVARCHAR(255) NOT NULL
    );

    IF OBJECT_ID('tempdb..#ReviewAnchor') IS NOT NULL DROP TABLE #ReviewAnchor;
    CREATE TABLE #ReviewAnchor (
        MasterAddressID    INT NULL,
        KdatRecordID       INT NULL,
        ReasonForNoMatch   NVARCHAR(255) NOT NULL,
        UPropertyRecordsID INT NOT NULL
    );

    INSERT INTO #ReviewAnchor (MasterAddressID, KdatRecordID, ReasonForNoMatch, UPropertyRecordsID)
    SELECT
        rp.MasterAddressID,
        rp.KdatRecordID,
        rp.ReasonForNoMatch,
        win.UPropertyRecordsID
    FROM #ReviewPending rp
    CROSS APPLY (
        SELECT TOP 1 m.UPropertyRecordsID
        FROM #UprCandidate lc
        INNER JOIN #UprMergeRanked r
            ON r.PropertyRn = 1
           AND r.EffectiveSDATAccountNumber = lc.EffectiveSDATAccountNumber
           AND COALESCE(r.EffectiveNormalizedFullAddress, r.EffectiveNormalizedStreetAddress)
               = COALESCE(lc.EffectiveNormalizedFullAddress, lc.EffectiveNormalizedStreetAddress)
        INNER JOIN #UPRMap m
            ON (r.MasterAddressID IS NOT NULL AND m.MasterAddressID = r.MasterAddressID)
            OR (r.KdatRecordID IS NOT NULL AND m.KdatRecordID = r.KdatRecordID)
        WHERE (rp.MasterAddressID IS NOT NULL AND lc.MasterAddressID = rp.MasterAddressID)
           OR (rp.KdatRecordID IS NOT NULL AND lc.KdatRecordID = rp.KdatRecordID)
        ORDER BY
            CASE WHEN r.MatchSource = N'BOTH' THEN 1 WHEN r.MatchSource = N'KDAT' THEN 2 ELSE 3 END,
            m.UPropertyRecordsID
    ) win
    WHERE rp.ReasonForNoMatch = N'DUPLICATE';

    IF OBJECT_ID('tempdb..#ReviewAnchorSrc') IS NOT NULL DROP TABLE #ReviewAnchorSrc;

    CREATE TABLE #ReviewAnchorSrc (
        SrcKey                   INT            IDENTITY(1, 1) NOT NULL PRIMARY KEY,
        MasterAddressID          INT            NULL,
        KdatRecordID             INT            NULL,
        ReasonForNoMatch         NVARCHAR(255)  NOT NULL,
        SDATAccountNumber        NVARCHAR(50)   NOT NULL,
        ParcelID                 NVARCHAR(50)   NULL,
        OwnerName                NVARCHAR(100)  NULL,
        StreetNumber             NVARCHAR(20)   NOT NULL,
        StreetName               NVARCHAR(100)  NOT NULL,
        StreetType               NVARCHAR(4)    NOT NULL,
        City                     NVARCHAR(100)  NOT NULL,
        ZipCode                  NVARCHAR(10)   NOT NULL,
        NormalizedStreetAddress  NVARCHAR(100)  NOT NULL,
        NormalizedFullAddress   NVARCHAR(100)  NOT NULL,
        Latitude                 DECIMAL(10, 6) NULL,
        Longitude                DECIMAL(10, 6) NULL
    );

    INSERT INTO #ReviewAnchorSrc (
        MasterAddressID, KdatRecordID, ReasonForNoMatch, SDATAccountNumber,
        ParcelID, OwnerName, StreetNumber, StreetName, StreetType,
        City, ZipCode, NormalizedStreetAddress, NormalizedFullAddress,
        Latitude, Longitude
    )
    SELECT
        rp.MasterAddressID,
        rp.KdatRecordID,
        rp.ReasonForNoMatch,
        N'__PENDING__',
        N'__PENDING__',
        LEFT(NULLIF(LTRIM(RTRIM(w.OwnerName)), N''), 100),
        N'0',
        COALESCE(LEFT(NULLIF(UPPER(LTRIM(RTRIM(rp.StreetName))), N''), 100), N'PENDING'),
        LEFT(COALESCE(NULLIF(UPPER(LTRIM(RTRIM(rp.StreetType))), N''), N'UNK'), 4),
        COALESCE(LEFT(NULLIF(UPPER(LTRIM(RTRIM(w.City))), N''), 100), N'PENDING'),
        CASE
            WHEN dbo.fn_UPR_IsValidZipCode(rp.ZipCode) = 1 THEN dbo.fn_UPR_NormalizeZipCode(rp.ZipCode)
            ELSE N'00000'
        END,
        LEFT(COALESCE(
            NULLIF(w.NormalizedStreetAddress, N''),
            N'PENDING-' + COALESCE(CONVERT(NVARCHAR(20), rp.MasterAddressID), CONVERT(NVARCHAR(20), rp.KdatRecordID))
        ), 100),
        LEFT(COALESCE(
            NULLIF(w.NormalizedFullAddress, N''),
            N'PENDING-' + COALESCE(CONVERT(NVARCHAR(20), rp.MasterAddressID), CONVERT(NVARCHAR(20), rp.KdatRecordID))
        ), 100),
        w.Latitude,
        w.Longitude
    FROM #ReviewPending rp
    CROSS APPLY (
        SELECT TOP 1
            w.OwnerName,
            w.StreetName,
            w.StreetType,
            w.City,
            w.ZipCode,
            w.NormalizedStreetAddress,
            w.NormalizedFullAddress,
            w.Latitude,
            w.Longitude
        FROM #Work w
        WHERE (rp.MasterAddressID IS NOT NULL AND w.MasterAddressID = rp.MasterAddressID)
           OR (rp.KdatRecordID IS NOT NULL AND w.KdatRecordID = rp.KdatRecordID)
        ORDER BY
            CASE
                WHEN rp.MasterAddressID IS NOT NULL AND w.MasterAddressID = rp.MasterAddressID
                 AND rp.KdatRecordID IS NOT NULL AND w.KdatRecordID = rp.KdatRecordID THEN 1
                WHEN rp.MasterAddressID IS NOT NULL AND w.MasterAddressID = rp.MasterAddressID THEN 2
                WHEN rp.KdatRecordID IS NOT NULL AND w.KdatRecordID = rp.KdatRecordID THEN 3
                ELSE 4
            END,
            w.MasterAddressID,
            w.KdatRecordID
    ) w
    WHERE rp.ReasonForNoMatch IN (N'NO_PARCEL_MATCH', N'NO_ADDRESS_MATCH')
      AND NOT EXISTS (
          SELECT 1
          FROM #ReviewAnchor a
          WHERE ISNULL(a.MasterAddressID, -1) = ISNULL(rp.MasterAddressID, -1)
            AND ISNULL(a.KdatRecordID, -1) = ISNULL(rp.KdatRecordID, -1)
            AND a.ReasonForNoMatch = rp.ReasonForNoMatch
      );

    UPDATE #ReviewAnchorSrc
    SET SDATAccountNumber = LEFT(
            CASE
                WHEN MasterAddressID IS NOT NULL
                    THEN N'PND-MA-' + CONVERT(NVARCHAR(20), MasterAddressID)
                ELSE N'PND-KD-' + CONVERT(NVARCHAR(20), KdatRecordID)
            END, 50),
        ParcelID = LEFT(
            CASE
                WHEN MasterAddressID IS NOT NULL
                    THEN N'PND-P-MA-' + CONVERT(NVARCHAR(20), MasterAddressID)
                ELSE N'PND-P-KD-' + CONVERT(NVARCHAR(20), KdatRecordID)
            END, 50),
        StreetNumber = LEFT(
            CASE
                WHEN MasterAddressID IS NOT NULL
                    THEN N'RMA' + CONVERT(NVARCHAR(20), MasterAddressID)
                ELSE N'RKD' + CONVERT(NVARCHAR(20), KdatRecordID)
            END, 20)
    WHERE SDATAccountNumber = N'__PENDING__';

    IF EXISTS (
        SELECT 1 FROM #ReviewAnchorSrc
        GROUP BY SDATAccountNumber HAVING COUNT(*) > 1
    )
        THROW 50033, N'Internal guard: duplicate synthetic SDATAccountNumber in #ReviewAnchorSrc.', 1;

    IF EXISTS (
        SELECT 1 FROM #ReviewAnchorSrc
        GROUP BY StreetNumber, StreetName, StreetType, ZipCode HAVING COUNT(*) > 1
    )
        THROW 50034, N'Internal guard: duplicate address key in #ReviewAnchorSrc.', 1;

    IF EXISTS (
        SELECT 1 FROM #ReviewAnchorSrc
        WHERE ParcelID IS NOT NULL
        GROUP BY ParcelID HAVING COUNT(*) > 1
    )
        THROW 50035, N'Internal guard: duplicate synthetic ParcelID in #ReviewAnchorSrc.', 1;

    SET @ReviewAnchorStaged = (SELECT COUNT(*) FROM #ReviewAnchorSrc);
    PRINT N'Step 6b - PENDING anchor rows staged: ' + CONVERT(NVARCHAR(20), @ReviewAnchorStaged);

    DECLARE @ReviewUprInserted TABLE (
        SDATAccountNumber    NVARCHAR(50) NOT NULL PRIMARY KEY,
        UPropertyRecordsID   INT          NOT NULL
    );

    INSERT INTO @ReviewUprInserted (SDATAccountNumber, UPropertyRecordsID)
    SELECT s.SDATAccountNumber, upr.UPropertyRecordsID
    FROM #ReviewAnchorSrc s
    INNER JOIN dbo.UPROPERTYRECORDS upr
        ON upr.SDATAccountNumber = s.SDATAccountNumber;

    INSERT INTO dbo.UPROPERTYRECORDS (
        SDATAccountNumber, ParcelID, PropertyName, Owner,
        StreetNumber, StreetName, StreetType,
        City, [State], ZipCode, NormalizedStreetAddress, NormalizedFullAddress,
        Latitude, Longitude,
        PropertyTypeCode, PropertyStatusCode, IsActive,
        CreatedDate, CreatedBy, UpdatedDate, UpdatedBy
    )
    OUTPUT
        INSERTED.SDATAccountNumber,
        INSERTED.UPropertyRecordsID
    INTO @ReviewUprInserted (SDATAccountNumber, UPropertyRecordsID)
    SELECT
        s.SDATAccountNumber,
        s.ParcelID,
        NULL,
        s.OwnerName,
        s.StreetNumber,
        s.StreetName,
        s.StreetType,
        s.City,
        @DefaultState,
        s.ZipCode,
        s.NormalizedStreetAddress,
        s.NormalizedFullAddress,
        s.Latitude,
        s.Longitude,
        @DefaultSdatPropertyType,
        N'PENDING',
        0,
        @Now,
        @RunUser,
        @Now,
        @RunUser
    FROM #ReviewAnchorSrc s
    WHERE NOT EXISTS (
        SELECT 1
        FROM @ReviewUprInserted i
        WHERE i.SDATAccountNumber = s.SDATAccountNumber
    );

    SET @ReviewAnchorCount = (SELECT COUNT(*) FROM @ReviewUprInserted);
    PRINT N'Step 6b - PENDING anchor UPR rows ready: ' + CONVERT(NVARCHAR(20), @ReviewAnchorCount);

    INSERT INTO #ReviewAnchor (MasterAddressID, KdatRecordID, ReasonForNoMatch, UPropertyRecordsID)
    SELECT
        s.MasterAddressID,
        s.KdatRecordID,
        s.ReasonForNoMatch,
        i.UPropertyRecordsID
    FROM #ReviewAnchorSrc s
    INNER JOIN @ReviewUprInserted i
        ON i.SDATAccountNumber = s.SDATAccountNumber;

    DROP TABLE #ReviewAnchorSrc;

    SET @ReviewAnchorCount = (SELECT COUNT(*) FROM @ReviewUprInserted);
    PRINT N'Step 6b - Review anchor UPR rows created: ' + CONVERT(NVARCHAR(20), @ReviewAnchorCount);

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
        rp.MasterAddressID, rp.KdatRecordID, rp.ReasonForNoMatch, rp.ReviewDetail,
        a.UPropertyRecordsID,
        CASE WHEN rp.KdatRecordID IS NOT NULL THEN N'KDAT' ELSE N'ADDRESS_MASTER' END,
        CASE WHEN rp.KdatRecordID IS NOT NULL
             THEN CONVERT(NVARCHAR(100), rp.KdatRecordID)
             ELSE CONVERT(NVARCHAR(100), rp.MasterAddressID) END,
        CASE WHEN rp.KdatRecordID IS NOT NULL THEN N'SDATProperty' ELSE N'MasterAddress' END
    FROM #ReviewPending rp
    INNER JOIN #ReviewAnchor a
        ON ISNULL(a.MasterAddressID, -1) = ISNULL(rp.MasterAddressID, -1)
       AND ISNULL(a.KdatRecordID, -1) = ISNULL(rp.KdatRecordID, -1)
       AND a.ReasonForNoMatch = rp.ReasonForNoMatch;

    SET @ReviewSkippedNoAnchor = (
        SELECT COUNT(*)
        FROM #ReviewPending rp
        WHERE NOT EXISTS (
            SELECT 1
            FROM #ReviewAnchor a
            WHERE ISNULL(a.MasterAddressID, -1) = ISNULL(rp.MasterAddressID, -1)
              AND ISNULL(a.KdatRecordID, -1) = ISNULL(rp.KdatRecordID, -1)
              AND a.ReasonForNoMatch = rp.ReasonForNoMatch
        )
    );

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
        1, @Now, N'Review: ' + src.ReviewDetail, @Now, @Now, @RunUser
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
    DROP TABLE #ReviewAnchor;

    IF EXISTS (
        SELECT 1
        FROM #ReviewPending rp
        WHERE rp.ReasonForNoMatch NOT IN (
            N'NO_PARCEL_MATCH', N'NO_ADDRESS_MATCH', N'DUPLICATE'
        )
    )
        THROW 50036,
            N'Review_Q blocked: #ReviewPending contains ReasonForNoMatch outside allowed load values.',
            1;

    IF NOT EXISTS (
        SELECT 1
        FROM sys.check_constraints cc
        WHERE cc.parent_object_id = OBJECT_ID(N'dbo.UPRMATCHREVIEW_Q')
          AND cc.name = N'CK_UPRMATCHREVIEW_Q_ReasonForNoMatch'
          AND cc.definition LIKE N'%DUPLICATE%'
    )
        THROW 50037,
            N'Review_Q blocked: ReasonForNoMatch CHECK missing DUPLICATE. Re-run full script from top.',
            1;

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
    WHERE rp.ReasonForNoMatch IN (N'NO_PARCEL_MATCH', N'NO_ADDRESS_MATCH', N'DUPLICATE')
      AND NOT EXISTS (
        SELECT 1
        FROM dbo.UPRMATCHREVIEW_Q q
        WHERE q.UPropertyRecords_XrefID = rx.UPropertyRecords_XrefID
          AND q.ReasonForNoMatch = rp.ReasonForNoMatch
    );

    SET @ReviewIncomingInserted = @@ROWCOUNT;

    PRINT N'Step 6c - Review_Q rows inserted: ' + CONVERT(NVARCHAR(20), @ReviewIncomingInserted);
    SET @ReviewNoParcel = (
        SELECT COUNT(*) FROM dbo.UPRMATCHREVIEW_Q
        WHERE ProcessingTimestamp >= @Now AND ReasonForNoMatch = N'NO_PARCEL_MATCH'
    );
    SET @ReviewDuplicate = (
        SELECT COUNT(*) FROM dbo.UPRMATCHREVIEW_Q
        WHERE ProcessingTimestamp >= @Now AND ReasonForNoMatch = N'DUPLICATE'
    );
    SET @ReviewIncomplete = (
        SELECT COUNT(*) FROM dbo.UPRMATCHREVIEW_Q
        WHERE ProcessingTimestamp >= @Now AND ReasonForNoMatch = N'NO_ADDRESS_MATCH'
    );

    SET @UPRInserted = (
        SELECT COUNT(*) FROM dbo.UPROPERTYRECORDS
        WHERE CreatedDate >= @Now AND CreatedBy = @RunUser AND PropertyStatusCode = N'ACTIVE'
    );

    /* ========================================================================
       7. EXTERNAL SYSTEMS — eProperty, CASE, MPDU, MULTIFAMILY
          Address/normalized-address match only; always write XREF (MATCH or NO_MATCH).
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
    BEGIN TRY
        EXEC sys.sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        SET @SourceWarning = N'Warning: eProperty source skipped — ' + ERROR_MESSAGE();
        PRINT @SourceWarning;
    END CATCH;

    SET @Sql = N'
    INSERT INTO #ExtAddr (SourceSystemCode, SourceRecordID, SourceEntityType, TaxOrAccount, NormAddress, NormFullAddress)
    SELECT N''CASE'', CONVERT(VARCHAR(100), c.CaseNumber), N''Case'', NULL,
        dbo.fn_UPR_NormalizeAddressLine(c.StreetAddress),
        dbo.fn_UPR_NormalizeFullAddressLine(c.StreetAddress, c.City, c.ZipCode)
    FROM DHCA_OLTA.dbo.[Case] c';
    BEGIN TRY
        EXEC sys.sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        SET @SourceWarning = N'Warning: CASE source skipped — ' + ERROR_MESSAGE();
        PRINT @SourceWarning;
    END CATCH;

    SET @Sql = N'
    INSERT INTO #ExtAddr (SourceSystemCode, SourceRecordID, SourceEntityType, TaxOrAccount, NormAddress, NormFullAddress)
    SELECT N''MPDU'', CONVERT(VARCHAR(100), mp.DevelopmentID), N''Development'', NULL,
        dbo.fn_UPR_NormalizeAddressLine(mp.StreetAddress),
        dbo.fn_UPR_NormalizeFullAddressLine(mp.StreetAddress, mp.City, mp.ZipCode)
    FROM DHCA_MPDU.dbo.Development mp';
    BEGIN TRY
        EXEC sys.sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        SET @SourceWarning = N'Warning: MPDU source skipped — ' + ERROR_MESSAGE();
        PRINT @SourceWarning;
    END CATCH;

    SET @Sql = N'
    INSERT INTO #ExtAddr (SourceSystemCode, SourceRecordID, SourceEntityType, TaxOrAccount, NormAddress, NormFullAddress)
    SELECT N''MULTIFAMILY'', CONVERT(VARCHAR(100), mf.AddressID), N''MultifamilyLoan'', NULL,
        dbo.fn_UPR_NormalizeAddressLine(ISNULL(mf.StreetNumber, N'''') + N'' '' + ISNULL(mf.StreetName, N'''') + N'' '' + ISNULL(mf.StreetType, N'''')),
        dbo.fn_UPR_NormalizeFullAddressLine(ISNULL(mf.StreetNumber, N'''') + N'' '' + ISNULL(mf.StreetName, N'''') + N'' '' + ISNULL(mf.StreetType, N''''), mf.City, mf.ZipCode)
    FROM DHCA_MultifamilyLoans.dbo.Address mf
    WHERE mf.DeletedInd = 0';
    BEGIN TRY
        EXEC sys.sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        SET @SourceWarning = N'Warning: MULTIFAMILY source skipped — ' + ERROR_MESSAGE();
        PRINT @SourceWarning;
    END CATCH;

    /* One XREF per ACTIVE UPR per external system — address match only */
    INSERT INTO #ExtMatch (
        UPropertyRecordsID, SourceSystemCode, SourceRecordID, SourceEntityType,
        MatchMethodCode, MatchResult, MatchConfidence, ProcessingStatus, Notes
    )
    SELECT
        m.UPropertyRecordsID,
        sys.SystemCode,
        COALESCE(ea.SourceRecordID, N'NM-' + CONVERT(NVARCHAR(20), m.UPropertyRecordsID) + N'-' + sys.SystemCode),
        COALESCE(ea.SourceEntityType, sys.EntityType),
        N'AddressNormalized',
        CASE WHEN ea.SourceRecordID IS NOT NULL THEN N'MATCH' ELSE N'NO_MATCH' END,
        CASE WHEN ea.SourceRecordID IS NOT NULL THEN N'MEDIUM' ELSE N'NONE' END,
        CASE WHEN ea.SourceRecordID IS NOT NULL THEN N'PROCESSED' ELSE N'PENDING_REVIEW' END,
        CASE WHEN ea.SourceRecordID IS NOT NULL
             THEN N'Matched to ' + sys.SystemCode
             ELSE N'No Address Match' END
    FROM #UPRMap m
    INNER JOIN dbo.UPROPERTYRECORDS upr
        ON upr.UPropertyRecordsID = m.UPropertyRecordsID
       AND upr.PropertyStatusCode = N'ACTIVE'
    CROSS JOIN (
        VALUES
            (N'eProperty',   N'Property'),
            (N'CASE',        N'Case'),
            (N'MPDU',        N'Development'),
            (N'MULTIFAMILY', N'MultifamilyLoan')
    ) sys(SystemCode, EntityType)
    OUTER APPLY (
        SELECT TOP 1 ea.SourceRecordID, ea.SourceEntityType
        FROM #ExtAddr ea
        WHERE ea.SourceSystemCode = sys.SystemCode
          AND (
                ea.NormAddress = upr.NormalizedStreetAddress
             OR ea.NormFullAddress = upr.NormalizedFullAddress
          )
        ORDER BY ea.SourceRecordID
    ) ea;

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
          SELECT 1 FROM dbo.UPROPERTYRECORDS_XREF x
          WHERE x.UPropertyRecordsID = e.UPropertyRecordsID
            AND x.SourceSystemCode = N'eProperty' AND x.IsActive = 1
      );
    SET @EPropertyXrefInserted = (SELECT COUNT(*) FROM #ExtMatch WHERE SourceSystemCode = N'eProperty' AND MatchResult = N'MATCH');
    SET @EPropertyXrefNoMatch = (SELECT COUNT(*) FROM #ExtMatch WHERE SourceSystemCode = N'eProperty' AND MatchResult = N'NO_MATCH');

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
          SELECT 1 FROM dbo.UPROPERTYRECORDS_XREF x
          WHERE x.UPropertyRecordsID = e.UPropertyRecordsID
            AND x.SourceSystemCode = N'CASE' AND x.IsActive = 1
      );
    SET @CaseXrefInserted = (SELECT COUNT(*) FROM #ExtMatch WHERE SourceSystemCode = N'CASE' AND MatchResult = N'MATCH');
    SET @CaseXrefNoMatch = (SELECT COUNT(*) FROM #ExtMatch WHERE SourceSystemCode = N'CASE' AND MatchResult = N'NO_MATCH');

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
          SELECT 1 FROM dbo.UPROPERTYRECORDS_XREF x
          WHERE x.UPropertyRecordsID = e.UPropertyRecordsID
            AND x.SourceSystemCode = N'MPDU' AND x.IsActive = 1
      );
    SET @MPDUXrefInserted = (SELECT COUNT(*) FROM #ExtMatch WHERE SourceSystemCode = N'MPDU' AND MatchResult = N'MATCH');
    SET @MPDUXrefNoMatch = (SELECT COUNT(*) FROM #ExtMatch WHERE SourceSystemCode = N'MPDU' AND MatchResult = N'NO_MATCH');

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
          SELECT 1 FROM dbo.UPROPERTYRECORDS_XREF x
          WHERE x.UPropertyRecordsID = e.UPropertyRecordsID
            AND x.SourceSystemCode = N'MULTIFAMILY' AND x.IsActive = 1
      );
    SET @MultifamilyXrefInserted = (SELECT COUNT(*) FROM #ExtMatch WHERE SourceSystemCode = N'MULTIFAMILY' AND MatchResult = N'MATCH');
    SET @MultifamilyXrefNoMatch = (SELECT COUNT(*) FROM #ExtMatch WHERE SourceSystemCode = N'MULTIFAMILY' AND MatchResult = N'NO_MATCH');


    SET @TotalXrefInserted = @MasterAddressXrefInserted + @SDATXrefInserted
        + @EPropertyXrefInserted + @EPropertyXrefNoMatch
        + @CaseXrefInserted + @CaseXrefNoMatch
        + @MPDUXrefInserted + @MPDUXrefNoMatch
        + @MultifamilyXrefInserted + @MultifamilyXrefNoMatch;

    SET @ReviewExternalInserted = 0;
    SET @ReviewInserted = @ReviewIncomingInserted;

    /* ========================================================================
       8. CONTACT + PROPERTYCONTACT (owner from SDAT)
       ======================================================================== */
    INSERT INTO dbo.CONTACT (ContactTypeCode, OrganizationName, IsActive, CreatedDate, UpdatedDate)
    SELECT DISTINCT N'OWNER', LEFT(LTRIM(RTRIM(w.OwnerName)), 200), 1, @Now, @Now
    FROM #Work w
    WHERE NULLIF(LTRIM(RTRIM(w.OwnerName)), N'') IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM dbo.CONTACT c WHERE c.OrganizationName = LTRIM(RTRIM(w.OwnerName)));

    SET @ContactInserted = @@ROWCOUNT;

    INSERT INTO dbo.PROPERTYCONTACT (UPropertyRecordsID, ContactID, ContactRoleCode, EffectiveStartDate, IsActive)
    SELECT m.UPropertyRecordsID, c.ContactID, N'OWNER', @Now, 1
    FROM #UPRMap m
    INNER JOIN #Work w ON (w.MasterAddressID = m.MasterAddressID OR w.KdatRecordID = m.KdatRecordID)
    INNER JOIN dbo.CONTACT c ON c.OrganizationName = LTRIM(RTRIM(w.OwnerName))
    WHERE NULLIF(LTRIM(RTRIM(w.OwnerName)), N'') IS NOT NULL
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
        N'Building ' + CONVERT(NVARCHAR(20), upr.UPropertyRecordsID),
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
           N'XREF: ' + SourceSystemCode + N'/' + SourceRecordID + N' ' + MatchResult
    FROM dbo.UPROPERTYRECORDS_XREF WHERE CreatedDate >= @Now;

    INSERT INTO dbo.AuditLog (EntityName, EntityKey, OperationType, ChangedBy, ChangedDate, ChangeSummary)
    SELECT N'UPRMATCHREVIEW_Q', CONVERT(NVARCHAR(200), UPRMatchReviewID), N'INSERT', @RunUser, @Now,
           N'Review: ' + ReasonForNoMatch
    FROM dbo.UPRMATCHREVIEW_Q WHERE ProcessingTimestamp >= @Now;

    SET @AuditInserted = (
        SELECT COUNT(*) FROM dbo.AuditLog WHERE ChangedDate >= @BatchStartTime
    );

    /* Client-visible completion marker (Results tab) */
    SELECT
        N'UPR LOAD COMPLETE' AS LoadStatus,
        @MasterAddressRead AS MasterAddressRead,
        @SDATRead AS SDATRead,
        @IncomingUnifiedRows AS UnifiedRows,
        @UprEligibleRows AS UprEligibleRows,
        @UPRInserted AS UprInserted,
        @UPRUpdated AS UprUpdated,
        @ReviewIncomingInserted AS ReviewQInserted,
        @RowsSentToReview AS ReviewQCandidates,
        @TotalXrefInserted AS TotalXrefInserted,
        CONVERT(NVARCHAR(30), @BatchStartTime, 120) AS BatchStart,
        CONVERT(NVARCHAR(30), SYSDATETIME(), 120) AS BatchEnd;

    COMMIT TRANSACTION;

    SET @BatchEndTime = SYSDATETIME();

    /* ========================================================================
       12. PRINT SUMMARY 
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
    PRINT N'UPR eligible rows (account + address + parcel): ' + CONVERT(VARCHAR(20), @UprEligibleRows);
    PRINT N'UPR records inserted (new ACTIVE): ' + CONVERT(VARCHAR(20), @UPRInserted);
    PRINT N'UPR records updated (existing): ' + CONVERT(VARCHAR(20), @UPRUpdated);
    PRINT N'UPR total processed this run: ' + CONVERT(VARCHAR(20), @UPRInserted + @UPRUpdated);
    PRINT N' ';
    PRINT N'Review_Q staged (total candidates): ' + CONVERT(VARCHAR(20), @RowsSentToReview);
    PRINT N'Review_Q - NoParcelID (NO_PARCEL_MATCH): ' + CONVERT(VARCHAR(20), @ReviewNoParcel);
    PRINT N'Review_Q - incomplete (NO_ADDRESS_MATCH): ' + CONVERT(VARCHAR(20), @ReviewIncomplete);
    PRINT N'Review_Q - Duplicate: ' + CONVERT(VARCHAR(20), @ReviewDuplicate);
    PRINT N'Review_Q records inserted: ' + CONVERT(VARCHAR(20), @ReviewIncomingInserted);
    IF @ReviewSkippedNoAnchor > 0
        PRINT N'Review_Q skipped (no anchor): ' + CONVERT(VARCHAR(20), @ReviewSkippedNoAnchor);
    PRINT N' ';
    PRINT N'MasterAddress XREF inserted: ' + CONVERT(VARCHAR(20), @MasterAddressXrefInserted);
    PRINT N'SDAT XREF inserted: ' + CONVERT(VARCHAR(20), @SDATXrefInserted);
    PRINT N'eProperty XREF match: ' + CONVERT(VARCHAR(20), @EPropertyXrefInserted);
    PRINT N'eProperty XREF no match: ' + CONVERT(VARCHAR(20), @EPropertyXrefNoMatch);
    PRINT N'CASE XREF match: ' + CONVERT(VARCHAR(20), @CaseXrefInserted);
    PRINT N'CASE XREF no match: ' + CONVERT(VARCHAR(20), @CaseXrefNoMatch);
    PRINT N'MPDU XREF match: ' + CONVERT(VARCHAR(20), @MPDUXrefInserted);
    PRINT N'MPDU XREF no match: ' + CONVERT(VARCHAR(20), @MPDUXrefNoMatch);
    PRINT N'MULTIFAMILY XREF match: ' + CONVERT(VARCHAR(20), @MultifamilyXrefInserted);
    PRINT N'MULTIFAMILY XREF no match: ' + CONVERT(VARCHAR(20), @MultifamilyXrefNoMatch);
    PRINT N'Total XREF inserted: ' + CONVERT(VARCHAR(20), @TotalXrefInserted);
    PRINT N' ';
    PRINT N'Review_Q total (same as inserted): ' + CONVERT(VARCHAR(20), @ReviewInserted);
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
                N'Load failed: ' + @ErrMsg);
    END TRY
    BEGIN CATCH
        /* Audit table may not exist if failure happened before schema ready */
    END CATCH;

    THROW;
END CATCH;
GO
