/*
================================================================================
  UPR Master Load Script
  
  Loads AddressMaster + SDAT, normalizes addresses, populates UPROPERTYRECORDS
  and all related tables (XREF, Review_Q, StatusHistory, Contact, Building/Unit,
  Reference data, AuditLog).

  CLIENT RULES:
    MA↔SDAT match — Account# AND valid normalized address ONLY (ParcelID is NOT part of match key)
    When MA+SDAT match on account+address: write ONE UPR row if any ParcelID present; else Review_Q
    When MA+SDAT do NOT match (account-only or address-only overlap): Review_Q, not UPR
    UPR  — valid Account# + valid address + ParcelID
    Review_Q — Missing ParcelID | Address or Account Not Match | NO_ADDRESS_MATCH | DUPLICATE
               IncomingSourceSystem = ADDRESS_MASTER | KDAT | BOTH only
               MA+SDAT match on account+address → ONE UPR row if valid; else ONE Review_Q row (both sides)
               MA-only or SDAT-only invalid → Review_Q with that source system
               Invalid records → Review_Q only — never PENDING or placeholder rows in UPR
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
DECLARE @UPRActiveInserted INT = 0;
DECLARE @UPRTotalInsertedThisRun INT = 0, @UPRTableCountAfter INT = 0;
DECLARE @MasterAddressXrefInserted INT = 0, @SDATXrefInserted INT = 0;
DECLARE @CaseXrefInserted INT = 0, @MPDUXrefInserted INT = 0, @EPropertyXrefInserted INT = 0, @MultifamilyXrefInserted INT = 0;
DECLARE @ReviewXrefRejectedInserted INT = 0, @TotalXrefInserted INT = 0;
DECLARE @XrefCountBefore INT = 0, @XrefTableCountAfter INT = 0, @XrefTotalInsertedThisRun INT = 0;
DECLARE @ReviewIncomingInserted INT = 0, @ReviewExternalInserted INT = 0, @ReviewInserted INT = 0;
DECLARE @ReviewMissingParcel INT = 0, @ReviewMismatch INT = 0;
DECLARE @ReviewDuplicate INT = 0, @ReviewIncomplete INT = 0;
DECLARE @MaSdMismatchCount INT = 0;
DECLARE @ReviewQTableCountAfter INT = 0;
DECLARE @RowsSentToReviewUnique INT = 0;
DECLARE @ReviewQExpected INT = 0, @IncomingDispositionTotal INT = 0;
DECLARE @IncomingDupGroups INT = 0, @IncomingDupExtraRows INT = 0;
DECLARE @UprEligibleSourceRows INT = 0, @UprUniqueKeysMerged INT = 0;
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
            N'Missing ParcelID',
            N'Address or Account Not Match',
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

    IF EXISTS (
        SELECT 1
        FROM sys.foreign_keys fk
        WHERE fk.parent_object_id = OBJECT_ID(N'dbo.UPRMATCHREVIEW_Q')
          AND fk.name = N'FK_UPRMATCHREVIEW_Q_XREF'
    )
        ALTER TABLE dbo.UPRMATCHREVIEW_Q DROP CONSTRAINT FK_UPRMATCHREVIEW_Q_XREF;

    IF COL_LENGTH(N'dbo.UPRMATCHREVIEW_Q', N'UPropertyRecords_XrefID') IS NOT NULL
       AND EXISTS (
           SELECT 1
           FROM sys.columns c
           WHERE c.object_id = OBJECT_ID(N'dbo.UPRMATCHREVIEW_Q')
             AND c.name = N'UPropertyRecords_XrefID'
             AND c.is_nullable = 0
       )
        ALTER TABLE dbo.UPRMATCHREVIEW_Q ALTER COLUMN UPropertyRecords_XrefID INT NULL;

    IF NOT EXISTS (
        SELECT 1
        FROM sys.foreign_keys fk
        WHERE fk.parent_object_id = OBJECT_ID(N'dbo.UPRMATCHREVIEW_Q')
          AND fk.name = N'FK_UPRMATCHREVIEW_Q_XREF'
    )
        ALTER TABLE dbo.UPRMATCHREVIEW_Q ADD CONSTRAINT FK_UPRMATCHREVIEW_Q_XREF
            FOREIGN KEY (UPropertyRecords_XrefID)
            REFERENCES dbo.UPropertyRecords_XREF (UPropertyRecords_XrefID);

    PRINT N'Schema: Review_Q UPropertyRecords_XrefID nullable (Review_Q does not require a UPR parent row).';
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

    SELECT @PreflightErrors = STRING_AGG(v.ColName, N', ')
    FROM (VALUES
        (N'IncomingSourceSystem'),
        (N'MA_Account'),
        (N'MA_NormalizedIncomingAddress'),
        (N'MA_ParcelID'),
        (N'SDAT_AccountNumber'),
        (N'SDAT_NormalizedIncomingAddress'),
        (N'SDAT_ParcelID'),
        (N'ReasonForNoMatch'),
        (N'ReviewStatus')
    ) AS v(ColName)
    WHERE COL_LENGTH(N'dbo.UPRMATCHREVIEW_Q', v.ColName) IS NULL;

    SET @ErrorMessage = N'UPRMATCHREVIEW_Q missing required columns: '
        + ISNULL(@PreflightErrors, N'') + N'. Recreate Review_Q from client DDL, then re-run.';
    IF @PreflightErrors IS NOT NULL
        THROW 50005, @ErrorMessage, 1;

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

    /* Account-only or address-only overlap (not full match) → Review_Q, not UPR */
    IF OBJECT_ID('tempdb..#MaSdMismatchRaw') IS NOT NULL DROP TABLE #MaSdMismatchRaw;

    SELECT
        ma.MasterAddressID,
        sd.KdatRecordID,
        MismatchType = CASE
            WHEN ma.MasterAddressAccount IS NOT NULL
             AND ma.MasterAddressAccount = sd.SDATAccountNumber THEN N'ACCOUNT'
            ELSE N'ADDRESS'
        END
    INTO #MaSdMismatchRaw
    FROM #MA ma
    INNER JOIN #SDAT sd
        ON (
            (
                ma.MasterAddressAccount IS NOT NULL
                AND ma.MasterAddressAccount = sd.SDATAccountNumber
                AND NOT (
                    ma.NormalizedStreetAddress = sd.NormalizedStreetAddress
                    OR ma.NormalizedFullAddress = sd.NormalizedFullAddress
                )
            )
            OR (
                (
                    ma.NormalizedStreetAddress = sd.NormalizedStreetAddress
                    OR ma.NormalizedFullAddress = sd.NormalizedFullAddress
                )
                AND (
                    ma.MasterAddressAccount IS NULL
                    OR sd.SDATAccountNumber IS NULL
                    OR ma.MasterAddressAccount <> sd.SDATAccountNumber
                )
            )
        )
    WHERE NOT EXISTS (
        SELECT 1
        FROM #MaSdBest b
        WHERE b.MasterAddressID = ma.MasterAddressID
          AND b.KdatRecordID = sd.KdatRecordID
    );

    IF OBJECT_ID('tempdb..#MaSdMismatch') IS NOT NULL DROP TABLE #MaSdMismatch;

    SELECT MasterAddressID, KdatRecordID, MismatchType
    INTO #MaSdMismatch
    FROM (
        SELECT
            r.*,
            ROW_NUMBER() OVER (
                PARTITION BY r.MasterAddressID
                ORDER BY r.KdatRecordID
            ) AS MaRn,
            ROW_NUMBER() OVER (
                PARTITION BY r.KdatRecordID
                ORDER BY r.MasterAddressID
            ) AS SdRn
        FROM #MaSdMismatchRaw r
    ) x
    WHERE x.MaRn = 1 AND x.SdRn = 1;

    /* 4a. Matched MA + SDAT (account + address — ParcelID checked later, not in match key) */
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

    /* 4b. AddressMaster only — not full-matched and not in account/address mismatch review */
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
        ma.SDATAccountNumber,
        ma.ParcelID,
        ma.StreetNumber, ma.StreetName, ma.StreetType, ma.Unit,
        ma.City, COALESCE(ma.[State], @DefaultState), ma.ZipCode,
        CONVERT(NVARCHAR(50), ma.PropertyType),
        CONVERT(NVARCHAR(200), ma.OwnerName),
        CAST(NULL AS INT), CAST(NULL AS INT),
        ma.Latitude, ma.Longitude,
        ma.NormalizedStreetAddress, ma.NormalizedFullAddress,
        CASE
            WHEN NULLIF(UPPER(LTRIM(RTRIM(ma.StreetName))), N'') IS NULL THEN 0
            WHEN NULLIF(UPPER(LTRIM(RTRIM(ma.City))), N'') IS NULL THEN 0
            WHEN dbo.fn_UPR_IsValidStreetNumber(ma.StreetNumber) = 0 THEN 0
            WHEN dbo.fn_UPR_IsValidZipCode(ma.ZipCode) = 0 THEN 0
            ELSE 1
        END,
        N'ADDRESS_MASTER', N'MEDIUM', N'AddressNormalized'
    FROM #MA ma
    WHERE NOT EXISTS (
        SELECT 1 FROM #MaSdBest ms WHERE ms.MasterAddressID = ma.MasterAddressID
    )
      AND NOT EXISTS (
        SELECT 1 FROM #MaSdMismatch mm WHERE mm.MasterAddressID = ma.MasterAddressID
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
    )
      AND NOT EXISTS (
        SELECT 1 FROM #MaSdMismatch mm WHERE mm.KdatRecordID = sd.KdatRecordID
    );

    SET @IncomingUnifiedRows = (SELECT COUNT(*) FROM #Work);

    CREATE NONCLUSTERED INDEX IX_Work_MasterAddressID ON #Work(MasterAddressID)
        WHERE MasterAddressID IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_Work_KdatRecordID ON #Work(KdatRecordID)
        WHERE KdatRecordID IS NOT NULL;

    SET @MaSdMismatchCount = (SELECT COUNT(*) FROM #MaSdMismatch);

    PRINT N'Step 4 complete - unified #Work rows: ' + CONVERT(NVARCHAR(20), @IncomingUnifiedRows)
        + N'; MA/SDAT mismatch pairs (Review): ' + CONVERT(NVARCHAR(20), @MaSdMismatchCount);

    /* 4d. Single incoming staging table — every MA/SDAT row with early duplicate rank
       (same account + normalized address = one property key; rank 1 = UPR candidate) */
    IF OBJECT_ID('tempdb..#IncomingUnified') IS NOT NULL DROP TABLE #IncomingUnified;

    SELECT
        w.MasterAddressID,
        w.KdatRecordID,
        w.MasterAddressAccount,
        w.SDATAccountNumber,
        w.ParcelID,
        w.StreetNumber,
        w.StreetName,
        w.StreetType,
        w.Unit,
        w.City,
        w.[State],
        w.ZipCode,
        w.PropertyType,
        w.OwnerName,
        w.YearBuilt,
        w.DwellingUnits,
        w.Latitude,
        w.Longitude,
        w.NormalizedStreetAddress,
        w.NormalizedFullAddress,
        w.HasRequiredAddress,
        w.MatchSource,
        w.IncomingMatchConfidence,
        w.IncomingMatchMethod,
        IncomingNormAccount = dbo.fn_UPR_NormalizeSDATAccount(
            NULLIF(LTRIM(RTRIM(COALESCE(w.SDATAccountNumber, w.MasterAddressAccount))), N'')),
        IncomingNormAddress = COALESCE(w.NormalizedFullAddress, w.NormalizedStreetAddress),
        IncomingDupRn = ROW_NUMBER() OVER (
            PARTITION BY
                dbo.fn_UPR_NormalizeSDATAccount(
                    NULLIF(LTRIM(RTRIM(COALESCE(w.SDATAccountNumber, w.MasterAddressAccount))), N'')),
                COALESCE(w.NormalizedFullAddress, w.NormalizedStreetAddress)
            ORDER BY
                CASE w.MatchSource WHEN N'BOTH' THEN 1 WHEN N'KDAT' THEN 2 ELSE 3 END,
                CASE WHEN NULLIF(LTRIM(RTRIM(w.ParcelID)), N'') IS NOT NULL THEN 0 ELSE 1 END,
                CASE WHEN NULLIF(LTRIM(RTRIM(w.OwnerName)), N'') IS NOT NULL THEN 0 ELSE 1 END,
                w.MasterAddressID,
                w.KdatRecordID
        )
    INTO #IncomingUnified
    FROM #Work w;

    SET @IncomingDupGroups = (
        SELECT COUNT(*)
        FROM (
            SELECT IncomingNormAccount, IncomingNormAddress
            FROM #IncomingUnified
            WHERE IncomingNormAccount IS NOT NULL
              AND NULLIF(IncomingNormAddress, N'') IS NOT NULL
            GROUP BY IncomingNormAccount, IncomingNormAddress
            HAVING COUNT(*) > 1
        ) g
    );
    SET @IncomingDupExtraRows = (
        SELECT COUNT(*) FROM #IncomingUnified WHERE IncomingDupRn > 1
    );

    CREATE NONCLUSTERED INDEX IX_IncomingUnified_Ma ON #IncomingUnified(MasterAddressID)
        WHERE MasterAddressID IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_IncomingUnified_Kd ON #IncomingUnified(KdatRecordID)
        WHERE KdatRecordID IS NOT NULL;

    PRINT N'Step 4d - #IncomingUnified rows: ' + CONVERT(NVARCHAR(20), @IncomingUnifiedRows)
        + N'; duplicate property keys: ' + CONVERT(NVARCHAR(20), @IncomingDupGroups)
        + N'; extra source rows (dup rank>1): ' + CONVERT(NVARCHAR(20), @IncomingDupExtraRows);

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
    FROM #IncomingUnified w;

    /* ========================================================================
       CreateReview stage — #CreateReview mirrors UPRMATCHREVIEW_Q MA/SDAT column set
       (internal keys used for anchor/XREF only)
       ======================================================================== */
    IF OBJECT_ID('tempdb..#CreateReview') IS NOT NULL DROP TABLE #CreateReview;
    CREATE TABLE #CreateReview (
        IncomingSourceSystem              NVARCHAR(100) NOT NULL,
        MA_Account                        NVARCHAR(30)  NULL,
        MA_NormalizedIncomingAddress      NVARCHAR(300) NOT NULL,
        MA_ParcelID                       NVARCHAR(50)  NULL,
        SDAT_AccountNumber                NVARCHAR(30)  NULL,
        SDAT_NormalizedIncomingAddress    NVARCHAR(300) NOT NULL,
        SDAT_ParcelID                     NVARCHAR(50)  NULL,
        ReasonForNoMatch                  NVARCHAR(255) NOT NULL,
        ReviewStatus                      NVARCHAR(128) NOT NULL,
        MasterAddressID                   INT           NULL,
        KdatRecordID                      INT           NULL,
        ReviewDetail                      NVARCHAR(255) NOT NULL,
        StreetNumber                      NVARCHAR(20)  NULL,
        StreetName                        NVARCHAR(100) NULL,
        StreetType                        NVARCHAR(4)   NULL,
        ZipCode                           NVARCHAR(10)  NULL,
        EffectiveSDATAccountNumber        NVARCHAR(50)  NOT NULL
    );
    CREATE NONCLUSTERED INDEX IX_CreateReview_Src
        ON #CreateReview(MasterAddressID, KdatRecordID);

    /* MA/SDAT partial overlap — account or address differs; write both sides to Review_Q */
    INSERT INTO #CreateReview (
        IncomingSourceSystem,
        MA_Account, MA_NormalizedIncomingAddress, MA_ParcelID,
        SDAT_AccountNumber, SDAT_NormalizedIncomingAddress, SDAT_ParcelID,
        ReasonForNoMatch, ReviewStatus,
        MasterAddressID, KdatRecordID, ReviewDetail,
        StreetNumber, StreetName, StreetType, ZipCode, EffectiveSDATAccountNumber
    )
    SELECT
        N'BOTH'                                                    AS IncomingSourceSystem,
        ma.MasterAddressAccount,
        LEFT(COALESCE(ma.NormalizedFullAddress, ma.NormalizedStreetAddress, N''), 300),
        NULLIF(LTRIM(RTRIM(ma.ParcelID)), N''),
        sd.SDATAccountNumber,
        LEFT(COALESCE(sd.NormalizedFullAddress, sd.NormalizedStreetAddress, N''), 300),
        NULLIF(LTRIM(RTRIM(sd.ParcelID)), N''),
        N'Address or Account Not Match'                            AS ReasonForNoMatch,
        N'PENDING_REVIEW'                                          AS ReviewStatus,
        mm.MasterAddressID,
        mm.KdatRecordID,
        CASE mm.MismatchType
            WHEN N'ACCOUNT' THEN N'Same account number, different normalized address'
            ELSE N'Same normalized address, different account number'
        END,
        COALESCE(ma.StreetNumber, sd.StreetNumber),
        COALESCE(ma.StreetName, sd.StreetName),
        COALESCE(ma.StreetType, sd.StreetType),
        COALESCE(ma.ZipCode, sd.ZipCode),
        COALESCE(
            dbo.fn_UPR_NormalizeSDATAccount(
                NULLIF(LTRIM(RTRIM(COALESCE(ma.MasterAddressAccount, sd.SDATAccountNumber))), N'')),
            N'MX-' + CONVERT(NVARCHAR(20), mm.MasterAddressID) + N'-' + CONVERT(NVARCHAR(20), mm.KdatRecordID)
        )
    FROM #MaSdMismatch mm
    INNER JOIN #MA ma ON ma.MasterAddressID = mm.MasterAddressID
    INNER JOIN #SDAT sd ON sd.KdatRecordID = mm.KdatRecordID;

    /* CreateReview — invalid identification / missing ParcelID (not UPR-eligible) */
    INSERT INTO #CreateReview (
        IncomingSourceSystem,
        MA_Account, MA_NormalizedIncomingAddress, MA_ParcelID,
        SDAT_AccountNumber, SDAT_NormalizedIncomingAddress, SDAT_ParcelID,
        ReasonForNoMatch, ReviewStatus,
        MasterAddressID, KdatRecordID, ReviewDetail,
        StreetNumber, StreetName, StreetType, ZipCode, EffectiveSDATAccountNumber
    )
    SELECT
        w.MatchSource                                              AS IncomingSourceSystem,
        CASE WHEN w.MasterAddressID IS NOT NULL
             THEN COALESCE(ma.MasterAddressAccount, w.MasterAddressAccount) END,
        LEFT(COALESCE(
            CASE WHEN w.MasterAddressID IS NOT NULL
                 THEN COALESCE(ma.NormalizedFullAddress, ma.NormalizedStreetAddress,
                               w.NormalizedFullAddress, w.NormalizedStreetAddress)
            END,
            N''
        ), 300),
        CASE WHEN w.MasterAddressID IS NOT NULL
             THEN NULLIF(LTRIM(RTRIM(COALESCE(ma.ParcelID, w.ParcelID))), N'') END,
        CASE WHEN w.KdatRecordID IS NOT NULL
             THEN COALESCE(sd.SDATAccountNumber, w.SDATAccountNumber) END,
        LEFT(COALESCE(
            CASE WHEN w.KdatRecordID IS NOT NULL
                 THEN COALESCE(sd.NormalizedFullAddress, sd.NormalizedStreetAddress,
                               w.NormalizedFullAddress, w.NormalizedStreetAddress)
            END,
            N''
        ), 300),
        CASE WHEN w.KdatRecordID IS NOT NULL
             THEN NULLIF(LTRIM(RTRIM(COALESCE(sd.ParcelID, w.ParcelID))), N'') END,
        CASE
            WHEN c.NeedsNoParcelReview = 1 THEN N'Missing ParcelID'
            ELSE N'NO_ADDRESS_MATCH'
        END                                                        AS ReasonForNoMatch,
        N'PENDING_REVIEW'                                          AS ReviewStatus,
        w.MasterAddressID,
        w.KdatRecordID,
        CASE
            WHEN c.NeedsNoParcelReview = 1 THEN N'Missing ParcelID'
            WHEN NULLIF(LTRIM(RTRIM(COALESCE(w.SDATAccountNumber, w.MasterAddressAccount))), N'') IS NULL
                THEN N'Missing account number'
            WHEN dbo.fn_UPR_IsValidStreetNumber(w.StreetNumber) = 0 THEN N'Invalid street number'
            WHEN dbo.fn_UPR_IsValidZipCode(w.ZipCode) = 0 THEN N'Invalid zip code'
            WHEN NULLIF(UPPER(LTRIM(RTRIM(w.StreetName))), N'') IS NULL THEN N'Missing street name'
            WHEN NULLIF(UPPER(LTRIM(RTRIM(w.City))), N'') IS NULL THEN N'Missing city'
            WHEN w.HasRequiredAddress = 0 THEN N'Invalid or incomplete address'
            ELSE N'Invalid account or address'
        END,
        w.StreetNumber,
        w.StreetName,
        w.StreetType,
        w.ZipCode,
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
    LEFT JOIN #MA ma ON ma.MasterAddressID = w.MasterAddressID
    LEFT JOIN #SDAT sd ON sd.KdatRecordID = w.KdatRecordID
    INNER JOIN #UprCandidate c
        ON ISNULL(c.MasterAddressID, -1) = ISNULL(w.MasterAddressID, -1)
       AND ISNULL(c.KdatRecordID, -1) = ISNULL(w.KdatRecordID, -1)
    WHERE c.IsEligibleForUpr = 0
      AND NOT EXISTS (
          SELECT 1
          FROM #CreateReview rp
          WHERE ISNULL(rp.MasterAddressID, -1) = ISNULL(w.MasterAddressID, -1)
            AND ISNULL(rp.KdatRecordID, -1) = ISNULL(w.KdatRecordID, -1)
      );

    SET @UprCountBefore = (SELECT COUNT(*) FROM dbo.UPROPERTYRECORDS);

    IF OBJECT_ID('tempdb..#UprMergeRanked') IS NOT NULL DROP TABLE #UprMergeRanked;

    SELECT
        c.*,
        ROW_NUMBER() OVER (
            PARTITION BY
                c.EffectiveSDATAccountNumber,
                COALESCE(c.EffectiveNormalizedFullAddress, c.EffectiveNormalizedStreetAddress)
            ORDER BY
                CASE c.MatchSource WHEN N'BOTH' THEN 1 WHEN N'KDAT' THEN 2 ELSE 3 END,
                CASE WHEN NULLIF(LTRIM(RTRIM(c.EffectiveParcelID)), N'') IS NOT NULL THEN 0 ELSE 1 END,
                CASE WHEN NULLIF(LTRIM(RTRIM(c.EffectiveOwnerName)), N'') IS NOT NULL THEN 0 ELSE 1 END,
                c.MasterAddressID,
                c.KdatRecordID
        ) AS PropertyRn
    INTO #UprMergeRanked
    FROM #UprCandidate c
    WHERE c.IsEligibleForUpr = 1;

    IF OBJECT_ID('tempdb..#UprMergeSrc') IS NOT NULL DROP TABLE #UprMergeSrc;

    /* All eligible candidates enter scoring — final UPR winner chosen after UQ guard */
    SELECT
        r.MasterAddressID, r.KdatRecordID, r.MatchSource, r.HasRequiredAddress,
        r.SDATAccountNumber, r.ParcelID, r.OwnerName,
        r.EffectiveSDATAccountNumber, r.EffectiveParcelID,
        r.EffectiveStreetNumber, r.EffectiveStreetName, r.EffectiveStreetType,
        r.EffectiveCity, r.EffectiveState, r.EffectiveZipCode,
        r.EffectiveNormalizedStreetAddress, r.EffectiveNormalizedFullAddress,
        r.EffectiveLatitude, r.EffectiveLongitude, r.EffectiveOwnerName, r.EffectivePropertyType,
        r.PropertyRn
    INTO #UprMergeSrc
    FROM #UprMergeRanked r;

    /* Final MERGE safety — drop rows that would violate UPR NOT NULL / CHECK */
    INSERT INTO #CreateReview (
        IncomingSourceSystem,
        MA_Account, MA_NormalizedIncomingAddress, MA_ParcelID,
        SDAT_AccountNumber, SDAT_NormalizedIncomingAddress, SDAT_ParcelID,
        ReasonForNoMatch, ReviewStatus,
        MasterAddressID, KdatRecordID, ReviewDetail,
        StreetNumber, StreetName, StreetType, ZipCode, EffectiveSDATAccountNumber
    )
    SELECT
        w.MatchSource                                              AS IncomingSourceSystem,
        CASE WHEN w.MasterAddressID IS NOT NULL
             THEN COALESCE(ma.MasterAddressAccount, w.MasterAddressAccount) END,
        LEFT(COALESCE(
            CASE WHEN w.MasterAddressID IS NOT NULL
                 THEN COALESCE(ma.NormalizedFullAddress, ma.NormalizedStreetAddress,
                               w.NormalizedFullAddress, w.NormalizedStreetAddress)
            END,
            N''
        ), 300),
        CASE WHEN w.MasterAddressID IS NOT NULL
             THEN NULLIF(LTRIM(RTRIM(COALESCE(ma.ParcelID, w.ParcelID))), N'') END,
        CASE WHEN w.KdatRecordID IS NOT NULL
             THEN COALESCE(sd.SDATAccountNumber, w.SDATAccountNumber) END,
        LEFT(COALESCE(
            CASE WHEN w.KdatRecordID IS NOT NULL
                 THEN COALESCE(sd.NormalizedFullAddress, sd.NormalizedStreetAddress,
                               w.NormalizedFullAddress, w.NormalizedStreetAddress)
            END,
            N''
        ), 300),
        CASE WHEN w.KdatRecordID IS NOT NULL
             THEN NULLIF(LTRIM(RTRIM(COALESCE(sd.ParcelID, w.ParcelID))), N'') END,
        N'NO_ADDRESS_MATCH'                                        AS ReasonForNoMatch,
        N'PENDING_REVIEW'                                          AS ReviewStatus,
        w.MasterAddressID,
        w.KdatRecordID,
        N'Failed final UPR validation before insert',
        w.StreetNumber,
        w.StreetName,
        w.StreetType,
        w.ZipCode,
        s.EffectiveSDATAccountNumber
    FROM #UprMergeSrc s
    INNER JOIN #Work w
        ON ISNULL(w.MasterAddressID, -1) = ISNULL(s.MasterAddressID, -1)
       AND ISNULL(w.KdatRecordID, -1) = ISNULL(s.KdatRecordID, -1)
    LEFT JOIN #MA ma ON ma.MasterAddressID = w.MasterAddressID
    LEFT JOIN #SDAT sd ON sd.KdatRecordID = w.KdatRecordID
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
          FROM #CreateReview rp
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
            ORDER BY
                CASE s.MatchSource WHEN N'BOTH' THEN 1 WHEN N'KDAT' THEN 2 ELSE 3 END,
                CASE WHEN NULLIF(LTRIM(RTRIM(s.EffectiveParcelID)), N'') IS NOT NULL THEN 0 ELSE 1 END,
                s.PropertyRn,
                s.MasterAddressID,
                s.KdatRecordID
        ) AS BatchAccountRn,
        ROW_NUMBER() OVER (
            PARTITION BY s.EffectiveStreetNumber, s.EffectiveStreetName, s.EffectiveStreetType, s.EffectiveZipCode
            ORDER BY
                CASE s.MatchSource WHEN N'BOTH' THEN 1 WHEN N'KDAT' THEN 2 ELSE 3 END,
                CASE WHEN NULLIF(LTRIM(RTRIM(s.EffectiveParcelID)), N'') IS NOT NULL THEN 0 ELSE 1 END,
                s.PropertyRn,
                s.MasterAddressID,
                s.KdatRecordID
        ) AS BatchAddrRn,
        ROW_NUMBER() OVER (
            PARTITION BY s.EffectiveParcelID
            ORDER BY
                CASE s.MatchSource WHEN N'BOTH' THEN 1 WHEN N'KDAT' THEN 2 ELSE 3 END,
                s.PropertyRn,
                s.MasterAddressID,
                s.KdatRecordID
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

    SET @UprEligibleSourceRows = (SELECT COUNT(*) FROM #UprMergeScored);

    /* Best row per account+normalized address — prefer non-batch-loser, then lowest PropertyRn */
    IF OBJECT_ID('tempdb..#UprAddrBest') IS NOT NULL DROP TABLE #UprAddrBest;

    SELECT
        s.*,
        IsBatchLoser = CASE WHEN l.MasterAddressID IS NOT NULL OR l.KdatRecordID IS NOT NULL THEN 1 ELSE 0 END,
        ROW_NUMBER() OVER (
            PARTITION BY
                s.EffectiveSDATAccountNumber,
                COALESCE(s.EffectiveNormalizedFullAddress, s.EffectiveNormalizedStreetAddress)
            ORDER BY
                CASE WHEN l.MasterAddressID IS NOT NULL OR l.KdatRecordID IS NOT NULL THEN 1 ELSE 0 END,
                s.PropertyRn,
                s.MasterAddressID,
                s.KdatRecordID
        ) AS AddrBestRn
    INTO #UprAddrBest
    FROM #UprMergeScored s
    LEFT JOIN #UprMergeLosers l
        ON ISNULL(l.MasterAddressID, -1) = ISNULL(s.MasterAddressID, -1)
       AND ISNULL(l.KdatRecordID, -1) = ISNULL(s.KdatRecordID, -1);

    DELETE FROM #UprMergeSrc;

    IF OBJECT_ID('tempdb..#UprMergePool') IS NOT NULL DROP TABLE #UprMergePool;

    SELECT *
    INTO #UprMergePool
    FROM #UprAddrBest
    WHERE AddrBestRn = 1;

    DROP TABLE #UprAddrBest;

    /* Global UPR unique keys — one MERGE row per account, physical address, and parcel */
    IF OBJECT_ID('tempdb..#UprAcctPick') IS NOT NULL DROP TABLE #UprAcctPick;

    SELECT
        p.*,
        ROW_NUMBER() OVER (
            PARTITION BY p.EffectiveSDATAccountNumber
            ORDER BY
                p.IsBatchLoser,
                CASE p.MatchSource WHEN N'BOTH' THEN 1 WHEN N'KDAT' THEN 2 ELSE 3 END,
                CASE WHEN NULLIF(LTRIM(RTRIM(p.EffectiveParcelID)), N'') IS NOT NULL THEN 0 ELSE 1 END,
                p.PropertyRn,
                p.MasterAddressID,
                p.KdatRecordID
        ) AS AccountPickRn
    INTO #UprAcctPick
    FROM #UprMergePool p;

    /* Account-key losers (same account, different normalized address) → Review_Q */
    INSERT INTO #CreateReview (
        IncomingSourceSystem,
        MA_Account, MA_NormalizedIncomingAddress, MA_ParcelID,
        SDAT_AccountNumber, SDAT_NormalizedIncomingAddress, SDAT_ParcelID,
        ReasonForNoMatch, ReviewStatus,
        MasterAddressID, KdatRecordID, ReviewDetail,
        StreetNumber, StreetName, StreetType, ZipCode, EffectiveSDATAccountNumber
    )
    SELECT
        w.MatchSource,
        CASE WHEN w.MasterAddressID IS NOT NULL THEN COALESCE(ma.MasterAddressAccount, w.MasterAddressAccount) END,
        LEFT(COALESCE(CASE WHEN w.MasterAddressID IS NOT NULL
             THEN COALESCE(ma.NormalizedFullAddress, ma.NormalizedStreetAddress,
                           w.NormalizedFullAddress, w.NormalizedStreetAddress) END, N''), 300),
        CASE WHEN w.MasterAddressID IS NOT NULL
             THEN NULLIF(LTRIM(RTRIM(COALESCE(ma.ParcelID, w.ParcelID))), N'') END,
        CASE WHEN w.KdatRecordID IS NOT NULL THEN COALESCE(sd.SDATAccountNumber, w.SDATAccountNumber) END,
        LEFT(COALESCE(CASE WHEN w.KdatRecordID IS NOT NULL
             THEN COALESCE(sd.NormalizedFullAddress, sd.NormalizedStreetAddress,
                           w.NormalizedFullAddress, w.NormalizedStreetAddress) END, N''), 300),
        CASE WHEN w.KdatRecordID IS NOT NULL
             THEN NULLIF(LTRIM(RTRIM(COALESCE(sd.ParcelID, w.ParcelID))), N'') END,
        N'DUPLICATE',
        N'PENDING_REVIEW',
        p.MasterAddressID,
        p.KdatRecordID,
        N'Duplicate SDAT account key in batch (one UPR row per account)',
        w.StreetNumber,
        w.StreetName,
        w.StreetType,
        w.ZipCode,
        p.EffectiveSDATAccountNumber
    FROM #UprAcctPick p
    INNER JOIN #IncomingUnified w
        ON ISNULL(w.MasterAddressID, -1) = ISNULL(p.MasterAddressID, -1)
       AND ISNULL(w.KdatRecordID, -1) = ISNULL(p.KdatRecordID, -1)
    LEFT JOIN #MA ma ON ma.MasterAddressID = w.MasterAddressID
    LEFT JOIN #SDAT sd ON sd.KdatRecordID = w.KdatRecordID
    WHERE p.AccountPickRn > 1
      AND NOT EXISTS (
          SELECT 1 FROM #CreateReview rp
          WHERE ISNULL(rp.MasterAddressID, -1) = ISNULL(p.MasterAddressID, -1)
            AND ISNULL(rp.KdatRecordID, -1) = ISNULL(p.KdatRecordID, -1)
      );

    IF OBJECT_ID('tempdb..#UprAddrKeyPick') IS NOT NULL DROP TABLE #UprAddrKeyPick;

    SELECT
        p.*,
        ROW_NUMBER() OVER (
            PARTITION BY p.EffectiveStreetNumber, p.EffectiveStreetName, p.EffectiveStreetType, p.EffectiveZipCode
            ORDER BY
                p.IsBatchLoser,
                CASE p.MatchSource WHEN N'BOTH' THEN 1 WHEN N'KDAT' THEN 2 ELSE 3 END,
                CASE WHEN NULLIF(LTRIM(RTRIM(p.EffectiveParcelID)), N'') IS NOT NULL THEN 0 ELSE 1 END,
                p.EffectiveSDATAccountNumber,
                p.PropertyRn,
                p.MasterAddressID,
                p.KdatRecordID
        ) AS AddressPickRn
    INTO #UprAddrKeyPick
    FROM #UprAcctPick p
    WHERE p.AccountPickRn = 1;

    DROP TABLE #UprAcctPick;

    INSERT INTO #CreateReview (
        IncomingSourceSystem,
        MA_Account, MA_NormalizedIncomingAddress, MA_ParcelID,
        SDAT_AccountNumber, SDAT_NormalizedIncomingAddress, SDAT_ParcelID,
        ReasonForNoMatch, ReviewStatus,
        MasterAddressID, KdatRecordID, ReviewDetail,
        StreetNumber, StreetName, StreetType, ZipCode, EffectiveSDATAccountNumber
    )
    SELECT
        w.MatchSource,
        CASE WHEN w.MasterAddressID IS NOT NULL THEN COALESCE(ma.MasterAddressAccount, w.MasterAddressAccount) END,
        LEFT(COALESCE(CASE WHEN w.MasterAddressID IS NOT NULL
             THEN COALESCE(ma.NormalizedFullAddress, ma.NormalizedStreetAddress,
                           w.NormalizedFullAddress, w.NormalizedStreetAddress) END, N''), 300),
        CASE WHEN w.MasterAddressID IS NOT NULL
             THEN NULLIF(LTRIM(RTRIM(COALESCE(ma.ParcelID, w.ParcelID))), N'') END,
        CASE WHEN w.KdatRecordID IS NOT NULL THEN COALESCE(sd.SDATAccountNumber, w.SDATAccountNumber) END,
        LEFT(COALESCE(CASE WHEN w.KdatRecordID IS NOT NULL
             THEN COALESCE(sd.NormalizedFullAddress, sd.NormalizedStreetAddress,
                           w.NormalizedFullAddress, w.NormalizedStreetAddress) END, N''), 300),
        CASE WHEN w.KdatRecordID IS NOT NULL
             THEN NULLIF(LTRIM(RTRIM(COALESCE(sd.ParcelID, w.ParcelID))), N'') END,
        N'DUPLICATE',
        N'PENDING_REVIEW',
        p.MasterAddressID,
        p.KdatRecordID,
        N'Duplicate address key in batch (one UPR row per street address)',
        w.StreetNumber,
        w.StreetName,
        w.StreetType,
        w.ZipCode,
        p.EffectiveSDATAccountNumber
    FROM #UprAddrKeyPick p
    INNER JOIN #IncomingUnified w
        ON ISNULL(w.MasterAddressID, -1) = ISNULL(p.MasterAddressID, -1)
       AND ISNULL(w.KdatRecordID, -1) = ISNULL(p.KdatRecordID, -1)
    LEFT JOIN #MA ma ON ma.MasterAddressID = w.MasterAddressID
    LEFT JOIN #SDAT sd ON sd.KdatRecordID = w.KdatRecordID
    WHERE p.AddressPickRn > 1
      AND NOT EXISTS (
          SELECT 1 FROM #CreateReview rp
          WHERE ISNULL(rp.MasterAddressID, -1) = ISNULL(p.MasterAddressID, -1)
            AND ISNULL(rp.KdatRecordID, -1) = ISNULL(p.KdatRecordID, -1)
      );

    IF OBJECT_ID('tempdb..#UprParcelPick') IS NOT NULL DROP TABLE #UprParcelPick;

    SELECT
        p.*,
        ROW_NUMBER() OVER (
            PARTITION BY p.EffectiveParcelID
            ORDER BY
                p.IsBatchLoser,
                CASE p.MatchSource WHEN N'BOTH' THEN 1 WHEN N'KDAT' THEN 2 ELSE 3 END,
                p.EffectiveSDATAccountNumber,
                p.PropertyRn,
                p.MasterAddressID,
                p.KdatRecordID
        ) AS ParcelPickRn
    INTO #UprParcelPick
    FROM #UprAddrKeyPick p
    WHERE p.AddressPickRn = 1;

    DROP TABLE #UprAddrKeyPick;
    DROP TABLE #UprMergePool;

    INSERT INTO #CreateReview (
        IncomingSourceSystem,
        MA_Account, MA_NormalizedIncomingAddress, MA_ParcelID,
        SDAT_AccountNumber, SDAT_NormalizedIncomingAddress, SDAT_ParcelID,
        ReasonForNoMatch, ReviewStatus,
        MasterAddressID, KdatRecordID, ReviewDetail,
        StreetNumber, StreetName, StreetType, ZipCode, EffectiveSDATAccountNumber
    )
    SELECT
        w.MatchSource,
        CASE WHEN w.MasterAddressID IS NOT NULL THEN COALESCE(ma.MasterAddressAccount, w.MasterAddressAccount) END,
        LEFT(COALESCE(CASE WHEN w.MasterAddressID IS NOT NULL
             THEN COALESCE(ma.NormalizedFullAddress, ma.NormalizedStreetAddress,
                           w.NormalizedFullAddress, w.NormalizedStreetAddress) END, N''), 300),
        CASE WHEN w.MasterAddressID IS NOT NULL
             THEN NULLIF(LTRIM(RTRIM(COALESCE(ma.ParcelID, w.ParcelID))), N'') END,
        CASE WHEN w.KdatRecordID IS NOT NULL THEN COALESCE(sd.SDATAccountNumber, w.SDATAccountNumber) END,
        LEFT(COALESCE(CASE WHEN w.KdatRecordID IS NOT NULL
             THEN COALESCE(sd.NormalizedFullAddress, sd.NormalizedStreetAddress,
                           w.NormalizedFullAddress, w.NormalizedStreetAddress) END, N''), 300),
        CASE WHEN w.KdatRecordID IS NOT NULL
             THEN NULLIF(LTRIM(RTRIM(COALESCE(sd.ParcelID, w.ParcelID))), N'') END,
        N'DUPLICATE',
        N'PENDING_REVIEW',
        p.MasterAddressID,
        p.KdatRecordID,
        N'Duplicate parcel key in batch (one UPR row per parcel)',
        w.StreetNumber,
        w.StreetName,
        w.StreetType,
        w.ZipCode,
        p.EffectiveSDATAccountNumber
    FROM #UprParcelPick p
    INNER JOIN #IncomingUnified w
        ON ISNULL(w.MasterAddressID, -1) = ISNULL(p.MasterAddressID, -1)
       AND ISNULL(w.KdatRecordID, -1) = ISNULL(p.KdatRecordID, -1)
    LEFT JOIN #MA ma ON ma.MasterAddressID = w.MasterAddressID
    LEFT JOIN #SDAT sd ON sd.KdatRecordID = w.KdatRecordID
    WHERE NULLIF(p.EffectiveParcelID, N'') IS NOT NULL
      AND p.ParcelPickRn > 1
      AND NOT EXISTS (
          SELECT 1 FROM #CreateReview rp
          WHERE ISNULL(rp.MasterAddressID, -1) = ISNULL(p.MasterAddressID, -1)
            AND ISNULL(rp.KdatRecordID, -1) = ISNULL(p.KdatRecordID, -1)
      );

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
        f.MasterAddressID, f.KdatRecordID, f.MatchSource, f.HasRequiredAddress,
        f.SDATAccountNumber, f.ParcelID, f.OwnerName,
        f.EffectiveSDATAccountNumber, f.EffectiveParcelID,
        f.EffectiveStreetNumber, f.EffectiveStreetName, f.EffectiveStreetType,
        f.EffectiveCity, f.EffectiveState, f.EffectiveZipCode,
        f.EffectiveNormalizedStreetAddress, f.EffectiveNormalizedFullAddress,
        f.EffectiveLatitude, f.EffectiveLongitude, f.EffectiveOwnerName, f.EffectivePropertyType
    FROM #UprParcelPick f
    WHERE NULLIF(f.EffectiveParcelID, N'') IS NULL
       OR f.ParcelPickRn = 1;

    DROP TABLE #UprParcelPick;

    /* Eligible duplicates that did not win UPR → Review_Q DUPLICATE (exact source key only) */
    INSERT INTO #CreateReview (
        IncomingSourceSystem,
        MA_Account, MA_NormalizedIncomingAddress, MA_ParcelID,
        SDAT_AccountNumber, SDAT_NormalizedIncomingAddress, SDAT_ParcelID,
        ReasonForNoMatch, ReviewStatus,
        MasterAddressID, KdatRecordID, ReviewDetail,
        StreetNumber, StreetName, StreetType, ZipCode, EffectiveSDATAccountNumber
    )
    SELECT
        w.MatchSource                                              AS IncomingSourceSystem,
        CASE WHEN w.MasterAddressID IS NOT NULL
             THEN COALESCE(ma.MasterAddressAccount, w.MasterAddressAccount) END,
        LEFT(COALESCE(
            CASE WHEN w.MasterAddressID IS NOT NULL
                 THEN COALESCE(ma.NormalizedFullAddress, ma.NormalizedStreetAddress,
                               w.NormalizedFullAddress, w.NormalizedStreetAddress)
            END,
            N''
        ), 300),
        CASE WHEN w.MasterAddressID IS NOT NULL
             THEN NULLIF(LTRIM(RTRIM(COALESCE(ma.ParcelID, w.ParcelID))), N'') END,
        CASE WHEN w.KdatRecordID IS NOT NULL
             THEN COALESCE(sd.SDATAccountNumber, w.SDATAccountNumber) END,
        LEFT(COALESCE(
            CASE WHEN w.KdatRecordID IS NOT NULL
                 THEN COALESCE(sd.NormalizedFullAddress, sd.NormalizedStreetAddress,
                               w.NormalizedFullAddress, w.NormalizedStreetAddress)
            END,
            N''
        ), 300),
        CASE WHEN w.KdatRecordID IS NOT NULL
             THEN NULLIF(LTRIM(RTRIM(COALESCE(sd.ParcelID, w.ParcelID))), N'') END,
        N'DUPLICATE'                                               AS ReasonForNoMatch,
        N'PENDING_REVIEW'                                          AS ReviewStatus,
        w.MasterAddressID,
        w.KdatRecordID,
        COALESCE(l.ReviewDetail, N'Extra incoming source row — duplicate account and normalized address'),
        w.StreetNumber,
        w.StreetName,
        w.StreetType,
        w.ZipCode,
        r.EffectiveSDATAccountNumber
    FROM #UprMergeRanked r
    INNER JOIN #IncomingUnified w
        ON ISNULL(w.MasterAddressID, -1) = ISNULL(r.MasterAddressID, -1)
       AND ISNULL(w.KdatRecordID, -1) = ISNULL(r.KdatRecordID, -1)
    LEFT JOIN #MA ma ON ma.MasterAddressID = w.MasterAddressID
    LEFT JOIN #SDAT sd ON sd.KdatRecordID = w.KdatRecordID
    LEFT JOIN #UprMergeLosers l
        ON ISNULL(l.MasterAddressID, -1) = ISNULL(r.MasterAddressID, -1)
       AND ISNULL(l.KdatRecordID, -1) = ISNULL(r.KdatRecordID, -1)
    WHERE NOT EXISTS (
          SELECT 1
          FROM #UprMergeSrc s
          WHERE ISNULL(s.MasterAddressID, -1) = ISNULL(r.MasterAddressID, -1)
            AND ISNULL(s.KdatRecordID, -1) = ISNULL(r.KdatRecordID, -1)
      )
      AND NOT EXISTS (
          SELECT 1
          FROM #CreateReview rp
          WHERE ISNULL(rp.MasterAddressID, -1) = ISNULL(w.MasterAddressID, -1)
            AND ISNULL(rp.KdatRecordID, -1) = ISNULL(w.KdatRecordID, -1)
      );

    DELETE rp
    FROM #CreateReview rp
    WHERE rp.ReasonForNoMatch = N'DUPLICATE'
      AND EXISTS (
          SELECT 1
          FROM #CreateReview x
          WHERE ISNULL(x.MasterAddressID, -1) = ISNULL(rp.MasterAddressID, -1)
            AND ISNULL(x.KdatRecordID, -1) = ISNULL(rp.KdatRecordID, -1)
            AND x.ReasonForNoMatch <> N'DUPLICATE'
      );

    IF OBJECT_ID('tempdb..#CreateReviewDeduped') IS NOT NULL DROP TABLE #CreateReviewDeduped;

    SELECT
        IncomingSourceSystem,
        MA_Account, MA_NormalizedIncomingAddress, MA_ParcelID,
        SDAT_AccountNumber, SDAT_NormalizedIncomingAddress, SDAT_ParcelID,
        ReasonForNoMatch, ReviewStatus,
        MasterAddressID, KdatRecordID, ReviewDetail,
        StreetNumber, StreetName, StreetType, ZipCode, EffectiveSDATAccountNumber
    INTO #CreateReviewDeduped
    FROM (
        SELECT
            cr.*,
            ROW_NUMBER() OVER (
                PARTITION BY
                    ISNULL(cr.MasterAddressID, -1),
                    ISNULL(cr.KdatRecordID, -1),
                    cr.ReasonForNoMatch
                ORDER BY cr.IncomingSourceSystem
            ) AS DedupeRn
        FROM #CreateReview cr
    ) ranked
    WHERE ranked.DedupeRn = 1;

    TRUNCATE TABLE #CreateReview;

    INSERT INTO #CreateReview (
        IncomingSourceSystem,
        MA_Account, MA_NormalizedIncomingAddress, MA_ParcelID,
        SDAT_AccountNumber, SDAT_NormalizedIncomingAddress, SDAT_ParcelID,
        ReasonForNoMatch, ReviewStatus,
        MasterAddressID, KdatRecordID, ReviewDetail,
        StreetNumber, StreetName, StreetType, ZipCode, EffectiveSDATAccountNumber
    )
    SELECT
        IncomingSourceSystem,
        MA_Account, MA_NormalizedIncomingAddress, MA_ParcelID,
        SDAT_AccountNumber, SDAT_NormalizedIncomingAddress, SDAT_ParcelID,
        ReasonForNoMatch, ReviewStatus,
        MasterAddressID, KdatRecordID, ReviewDetail,
        StreetNumber, StreetName, StreetType, ZipCode, EffectiveSDATAccountNumber
    FROM #CreateReviewDeduped;

    DROP TABLE #CreateReviewDeduped;

    DROP TABLE #UprMergeScored;
    DROP TABLE #UprMergeLosers;
    /* keep #ExistingUprKeys until after MERGE (parcel conflict check uses temp table, not target table) */

    CREATE NONCLUSTERED INDEX IX_UprMergeSrc_Acct ON #UprMergeSrc(EffectiveSDATAccountNumber);

    SET @UprEligibleRows = (SELECT COUNT(*) FROM #UprMergeSrc);
    SET @UprUniqueKeysMerged = @UprEligibleRows;
    PRINT N'Step 5b complete - UPR MERGE candidates: ' + CONVERT(NVARCHAR(20), @UprEligibleRows)
        + N' (from ' + CONVERT(NVARCHAR(20), @UprEligibleSourceRows) + N' eligible source rows)';

    /* Review_Q staging counts — final #CreateReview (Review_Q table columns / reasons) */
    SET @ReviewMissingParcel = (
        SELECT COUNT(*) FROM #CreateReview rp WHERE rp.ReasonForNoMatch = N'Missing ParcelID'
    );
    SET @ReviewMismatch = (
        SELECT COUNT(*) FROM #CreateReview rp WHERE rp.ReasonForNoMatch = N'Address or Account Not Match'
    );
    SET @ReviewIncomplete = (
        SELECT COUNT(*) FROM #CreateReview rp WHERE rp.ReasonForNoMatch = N'NO_ADDRESS_MATCH'
    );
    SET @RowsReviewDuplicate = (
        SELECT COUNT(*) FROM #CreateReview rp WHERE rp.ReasonForNoMatch = N'DUPLICATE'
    );
    SET @RowsIncompleteData = @ReviewIncomplete;
    SET @ReviewQExpected = @ReviewMissingParcel + @ReviewMismatch + @ReviewIncomplete + @RowsReviewDuplicate;
    SET @IncomingDispositionTotal = @IncomingUnifiedRows + @MaSdMismatchCount;

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

    SET @UprMergeRowsAffected = @@ROWCOUNT;
    SET @UPRActiveInserted = (
        SELECT COUNT(*) FROM dbo.UPROPERTYRECORDS
        WHERE CreatedDate >= @Now AND CreatedBy = @RunUser AND PropertyStatusCode = N'ACTIVE'
    );
    SET @UPRInserted = @UPRActiveInserted;
    SET @UPRUpdated = CASE
        WHEN @UprMergeRowsAffected > @UPRActiveInserted THEN @UprMergeRowsAffected - @UPRActiveInserted
        ELSE 0
    END;

    DROP TABLE #ExistingUprKeys;
    DROP TABLE #UprMergeReady;

    PRINT N'Step 5c complete - UPR MERGE finished: ' + CONVERT(NVARCHAR(30), SYSDATETIME(), 120);

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
        WHERE ISNULL(w.MasterAddressID, -1) = ISNULL(s.MasterAddressID, -1)
          AND ISNULL(w.KdatRecordID, -1) = ISNULL(s.KdatRecordID, -1)
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
    SET @XrefCountBefore = (SELECT COUNT(*) FROM dbo.UPROPERTYRECORDS_XREF);

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
       6b. REVIEW-BOUND ROWS → UPRMATCHREVIEW_Q only (no PENDING UPR rows)
           Valid incoming → UPR (ACTIVE). Invalid → Review_Q with reason + source.
       ======================================================================== */
    SET @RowsSentToReview = (SELECT COUNT(*) FROM #CreateReview);
    SET @RowsSentToReviewUnique = (
        SELECT COUNT(*)
        FROM (
            SELECT DISTINCT
                ISNULL(rp.MasterAddressID, -1) AS MasterAddressID,
                ISNULL(rp.KdatRecordID, -1) AS KdatRecordID,
                rp.ReasonForNoMatch
            FROM #CreateReview rp
        ) u
    );
    PRINT N'Step 6b - Review_Q processing started: ' + CONVERT(NVARCHAR(20), @RowsSentToReview) + N' candidates';

    IF EXISTS (
        SELECT 1
        FROM #CreateReview rp
        WHERE rp.ReasonForNoMatch NOT IN (
            N'Missing ParcelID',
            N'Address or Account Not Match',
            N'NO_ADDRESS_MATCH',
            N'DUPLICATE'
        )
    )
        THROW 50036,
            N'Review_Q blocked: #CreateReview contains ReasonForNoMatch outside allowed load values.',
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

    IF EXISTS (
        SELECT 1
        FROM #CreateReview rp
        WHERE NULLIF(LTRIM(RTRIM(rp.IncomingSourceSystem)), N'') IS NULL
           OR NULLIF(LTRIM(RTRIM(rp.ReasonForNoMatch)), N'') IS NULL
           OR NULLIF(LTRIM(RTRIM(rp.ReviewStatus)), N'') IS NULL
           OR (
                NULLIF(LTRIM(RTRIM(rp.MA_Account)), N'') IS NULL
                AND NULLIF(LTRIM(RTRIM(rp.SDAT_AccountNumber)), N'') IS NULL
                AND NULLIF(LTRIM(RTRIM(rp.MA_NormalizedIncomingAddress)), N'') IS NULL
                AND NULLIF(LTRIM(RTRIM(rp.SDAT_NormalizedIncomingAddress)), N'') IS NULL
              )
    )
        THROW 50038,
            N'Review_Q blocked: #CreateReview row missing required Review_Q column value.',
            1;

    SET @ReviewXrefRejectedInserted = 0;

    DECLARE @ReviewDupXrefOut TABLE (
        UPropertyRecords_XrefID INT NOT NULL,
        MasterAddressID         INT NULL,
        KdatRecordID            INT NULL,
        ReasonForNoMatch        NVARCHAR(255) NOT NULL
    );

    IF OBJECT_ID('tempdb..#ReviewDupXrefStage') IS NOT NULL DROP TABLE #ReviewDupXrefStage;
    CREATE TABLE #ReviewDupXrefStage (
        MasterAddressID     INT NULL,
        KdatRecordID        INT NULL,
        ReasonForNoMatch    NVARCHAR(255) NOT NULL,
        ReviewDetail        NVARCHAR(255) NOT NULL,
        UPropertyRecordsID  INT NOT NULL,
        SourceSystemCode    NVARCHAR(30) NOT NULL,
        SourceRecordID      NVARCHAR(100) NOT NULL,
        SourceEntityType    NVARCHAR(50) NOT NULL
    );

    INSERT INTO #ReviewDupXrefStage (
        MasterAddressID, KdatRecordID, ReasonForNoMatch, ReviewDetail,
        UPropertyRecordsID, SourceSystemCode, SourceRecordID, SourceEntityType
    )
    SELECT
        rp.MasterAddressID,
        rp.KdatRecordID,
        rp.ReasonForNoMatch,
        rp.ReviewDetail,
        upr.UPropertyRecordsID,
        CASE WHEN rp.KdatRecordID IS NOT NULL THEN N'KDAT' ELSE N'ADDRESS_MASTER' END,
        CASE WHEN rp.KdatRecordID IS NOT NULL
             THEN CONVERT(NVARCHAR(100), rp.KdatRecordID)
             ELSE CONVERT(NVARCHAR(100), rp.MasterAddressID) END,
        CASE WHEN rp.KdatRecordID IS NOT NULL THEN N'SDATProperty' ELSE N'MasterAddress' END
    FROM #CreateReview rp
    INNER JOIN #UprMergeRanked r_lose
        ON ISNULL(r_lose.MasterAddressID, -1) = ISNULL(rp.MasterAddressID, -1)
       AND ISNULL(r_lose.KdatRecordID, -1) = ISNULL(rp.KdatRecordID, -1)
    INNER JOIN #UprMergeSrc r_win
        ON r_win.EffectiveSDATAccountNumber = r_lose.EffectiveSDATAccountNumber
       AND COALESCE(r_win.EffectiveNormalizedFullAddress, r_win.EffectiveNormalizedStreetAddress)
           = COALESCE(r_lose.EffectiveNormalizedFullAddress, r_lose.EffectiveNormalizedStreetAddress)
    INNER JOIN dbo.UPROPERTYRECORDS upr
        ON upr.SDATAccountNumber = r_win.EffectiveSDATAccountNumber
       AND upr.PropertyStatusCode = N'ACTIVE'
    WHERE rp.ReasonForNoMatch = N'DUPLICATE';

    IF OBJECT_ID('tempdb..#ReviewDupXrefStageDeduped') IS NOT NULL DROP TABLE #ReviewDupXrefStageDeduped;

    SELECT
        MasterAddressID, KdatRecordID, ReasonForNoMatch, ReviewDetail,
        UPropertyRecordsID, SourceSystemCode, SourceRecordID, SourceEntityType
    INTO #ReviewDupXrefStageDeduped
    FROM (
        SELECT
            s.*,
            ROW_NUMBER() OVER (
                PARTITION BY s.UPropertyRecordsID, s.SourceSystemCode, s.SourceRecordID, s.SourceEntityType
                ORDER BY s.ReasonForNoMatch
            ) AS StageRn
        FROM #ReviewDupXrefStage s
    ) ranked
    WHERE StageRn = 1;

    DROP TABLE #ReviewDupXrefStage;

    DECLARE @ReviewDupXrefInserted TABLE (
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
    INTO @ReviewDupXrefInserted
    SELECT
        src.UPropertyRecordsID, src.SourceSystemCode, src.SourceRecordID, src.SourceEntityType,
        N'AddressNormalized', N'REJECTED', N'NONE', N'PENDING_REVIEW',
        1, @Now, N'Review: ' + src.ReviewDetail, @Now, @Now, @RunUser
    FROM #ReviewDupXrefStageDeduped src
    WHERE NOT EXISTS (
        SELECT 1
        FROM dbo.UPROPERTYRECORDS_XREF x
        WHERE x.SourceSystemCode = src.SourceSystemCode
          AND x.SourceRecordID = src.SourceRecordID
          AND x.SourceEntityType = src.SourceEntityType
          AND x.IsActive = 1
    );

    SET @ReviewXrefRejectedInserted = @@ROWCOUNT;

    INSERT INTO @ReviewDupXrefOut (
        UPropertyRecords_XrefID, MasterAddressID, KdatRecordID, ReasonForNoMatch
    )
    SELECT
        i.UPropertyRecords_XrefID, s.MasterAddressID, s.KdatRecordID, s.ReasonForNoMatch
    FROM @ReviewDupXrefInserted i
    INNER JOIN #ReviewDupXrefStageDeduped s
        ON s.UPropertyRecordsID = i.UPropertyRecordsID
       AND s.SourceSystemCode = i.SourceSystemCode
       AND s.SourceRecordID = i.SourceRecordID;

    DROP TABLE #ReviewDupXrefStageDeduped;

    IF OBJECT_ID('tempdb..#ReviewQReady') IS NOT NULL DROP TABLE #ReviewQReady;

    CREATE TABLE #ReviewQReady (
        UPropertyRecords_XrefID           INT            NULL,
        IncomingSourceSystem              NVARCHAR(100)  NOT NULL,
        MA_Account                        NVARCHAR(30)   NULL,
        MA_NormalizedIncomingAddress      NVARCHAR(300)  NOT NULL,
        MA_ParcelID                       NVARCHAR(50)   NULL,
        SDAT_AccountNumber                NVARCHAR(30)   NULL,
        SDAT_NormalizedIncomingAddress    NVARCHAR(300)  NOT NULL,
        SDAT_ParcelID                     NVARCHAR(50)   NULL,
        ReasonForNoMatch                  NVARCHAR(255)  NOT NULL,
        ReviewStatus                      NVARCHAR(128)  NOT NULL
    );

    INSERT INTO #ReviewQReady (
        UPropertyRecords_XrefID,
        IncomingSourceSystem,
        MA_Account, MA_NormalizedIncomingAddress, MA_ParcelID,
        SDAT_AccountNumber, SDAT_NormalizedIncomingAddress, SDAT_ParcelID,
        ReasonForNoMatch,
        ReviewStatus
    )
    SELECT
        rx.UPropertyRecords_XrefID,
        rp.IncomingSourceSystem,
        rp.MA_Account,
        rp.MA_NormalizedIncomingAddress,
        rp.MA_ParcelID,
        rp.SDAT_AccountNumber,
        rp.SDAT_NormalizedIncomingAddress,
        rp.SDAT_ParcelID,
        rp.ReasonForNoMatch,
        rp.ReviewStatus
    FROM #CreateReview rp
    LEFT JOIN @ReviewDupXrefOut rx
        ON ISNULL(rx.MasterAddressID, -1) = ISNULL(rp.MasterAddressID, -1)
       AND ISNULL(rx.KdatRecordID, -1) = ISNULL(rp.KdatRecordID, -1)
       AND rx.ReasonForNoMatch = rp.ReasonForNoMatch
    WHERE rp.ReasonForNoMatch IN (
        N'Missing ParcelID',
        N'Address or Account Not Match',
        N'NO_ADDRESS_MATCH',
        N'DUPLICATE'
    );

    INSERT INTO dbo.UPRMATCHREVIEW_Q (
        UPropertyRecords_XrefID,
        IncomingSourceSystem,
        MA_Account,
        MA_NormalizedIncomingAddress,
        MA_ParcelID,
        SDAT_AccountNumber,
        SDAT_NormalizedIncomingAddress,
        SDAT_ParcelID,
        ReasonForNoMatch,
        ReviewStatus
    )
    SELECT
        rq.UPropertyRecords_XrefID,
        rq.IncomingSourceSystem,
        rq.MA_Account,
        rq.MA_NormalizedIncomingAddress,
        rq.MA_ParcelID,
        rq.SDAT_AccountNumber,
        rq.SDAT_NormalizedIncomingAddress,
        rq.SDAT_ParcelID,
        rq.ReasonForNoMatch,
        rq.ReviewStatus
    FROM #ReviewQReady rq
    WHERE NOT EXISTS (
        SELECT 1
        FROM dbo.UPRMATCHREVIEW_Q q
        WHERE q.IncomingSourceSystem = rq.IncomingSourceSystem
          AND ISNULL(q.MA_Account, N'') = ISNULL(rq.MA_Account, N'')
          AND q.MA_NormalizedIncomingAddress = rq.MA_NormalizedIncomingAddress
          AND ISNULL(q.SDAT_AccountNumber, N'') = ISNULL(rq.SDAT_AccountNumber, N'')
          AND q.SDAT_NormalizedIncomingAddress = rq.SDAT_NormalizedIncomingAddress
          AND q.ReasonForNoMatch = rq.ReasonForNoMatch
    );

    SET @ReviewIncomingInserted = @@ROWCOUNT;

    DROP TABLE #ReviewQReady;

    PRINT N'Step 6c - Review_Q rows inserted: ' + CONVERT(NVARCHAR(20), @ReviewIncomingInserted);
    SET @ReviewMissingParcel = (
        SELECT COUNT(*) FROM dbo.UPRMATCHREVIEW_Q
        WHERE ProcessingTimestamp >= @Now AND ReasonForNoMatch = N'Missing ParcelID'
    );
    SET @ReviewMismatch = (
        SELECT COUNT(*) FROM dbo.UPRMATCHREVIEW_Q
        WHERE ProcessingTimestamp >= @Now AND ReasonForNoMatch = N'Address or Account Not Match'
    );
    SET @ReviewDuplicate = (
        SELECT COUNT(*) FROM dbo.UPRMATCHREVIEW_Q
        WHERE ProcessingTimestamp >= @Now AND ReasonForNoMatch = N'DUPLICATE'
    );
    SET @ReviewIncomplete = (
        SELECT COUNT(*) FROM dbo.UPRMATCHREVIEW_Q
        WHERE ProcessingTimestamp >= @Now AND ReasonForNoMatch = N'NO_ADDRESS_MATCH'
    );
    SET @ReviewQTableCountAfter = (
        SELECT COUNT(*) FROM dbo.UPRMATCHREVIEW_Q WHERE ProcessingTimestamp >= @Now
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
    SET @EPropertyXrefInserted = @@ROWCOUNT;
    SET @EPropertyXrefNoMatch = (
        SELECT COUNT(*) FROM #ExtMatch
        WHERE SourceSystemCode = N'eProperty' AND MatchResult = N'NO_MATCH'
    );

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
    SET @CaseXrefInserted = @@ROWCOUNT;
    SET @CaseXrefNoMatch = (
        SELECT COUNT(*) FROM #ExtMatch
        WHERE SourceSystemCode = N'CASE' AND MatchResult = N'NO_MATCH'
    );

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
    SET @MPDUXrefInserted = @@ROWCOUNT;
    SET @MPDUXrefNoMatch = (
        SELECT COUNT(*) FROM #ExtMatch
        WHERE SourceSystemCode = N'MPDU' AND MatchResult = N'NO_MATCH'
    );

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
    SET @MultifamilyXrefInserted = @@ROWCOUNT;
    SET @MultifamilyXrefNoMatch = (
        SELECT COUNT(*) FROM #ExtMatch
        WHERE SourceSystemCode = N'MULTIFAMILY' AND MatchResult = N'NO_MATCH'
    );

    SET @TotalXrefInserted = @MasterAddressXrefInserted + @SDATXrefInserted + @ReviewXrefRejectedInserted
        + @EPropertyXrefInserted + @CaseXrefInserted + @MPDUXrefInserted + @MultifamilyXrefInserted;

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

    COMMIT TRANSACTION;

    SET @BatchEndTime = SYSDATETIME();

    SET @UPRTableCountAfter = (SELECT COUNT(*) FROM dbo.UPROPERTYRECORDS);
    SET @UPRTotalInsertedThisRun = @UPRTableCountAfter - @UprCountBefore;
    SET @UPRActiveInserted = (
        SELECT COUNT(*)
        FROM dbo.UPROPERTYRECORDS
        WHERE CreatedDate >= @Now
          AND CreatedBy = @RunUser
          AND PropertyStatusCode = N'ACTIVE'
    );
    SET @UPRInserted = @UPRActiveInserted;
    SET @UPRUpdated = (
        SELECT COUNT(*)
        FROM dbo.UPROPERTYRECORDS
        WHERE UpdatedDate >= @Now
          AND UpdatedBy = @RunUser
          AND CreatedDate < @Now
    );

    SET @XrefTableCountAfter = (SELECT COUNT(*) FROM dbo.UPROPERTYRECORDS_XREF);
    SET @XrefTotalInsertedThisRun = @XrefTableCountAfter - @XrefCountBefore;

    /* ========================================================================
       12. PRINT SUMMARY (vertical report — original specification)
       View in SSMS Messages tab, not Results tab.
       ======================================================================== */
    PRINT N'============================================================';
    PRINT N' UPR LOAD SUMMARY';
    PRINT N' Script build: 2026-07-10 incoming-unified-dedup';
    PRINT N'============================================================';
    PRINT N'Batch Start Time: ' + CONVERT(VARCHAR(30), @BatchStartTime, 120);
    PRINT N'Batch End Time: ' + CONVERT(VARCHAR(30), @BatchEndTime, 120);
    PRINT N' ';
    PRINT N'MasterAddress records read: ' + CONVERT(VARCHAR(20), @MasterAddressRead);
    PRINT N'SDAT records read: ' + CONVERT(VARCHAR(20), @SDATRead);
    PRINT N'Unified property rows prepared (#IncomingUnified): ' + CONVERT(VARCHAR(20), @IncomingUnifiedRows);
    PRINT N'Incoming duplicate property keys (account+address): ' + CONVERT(VARCHAR(20), @IncomingDupGroups);
    PRINT N'Extra incoming source rows (duplicate rank > 1): ' + CONVERT(VARCHAR(20), @IncomingDupExtraRows);
    PRINT N' ';
    PRINT N'UPR eligible source rows (account+address+parcel): ' + CONVERT(VARCHAR(20), @UprEligibleSourceRows);
    PRINT N'UPR unique keys written (after dedup + UQ): ' + CONVERT(VARCHAR(20), @UprUniqueKeysMerged);
    PRINT N'UPR MERGE candidates this run: ' + CONVERT(VARCHAR(20), @UprEligibleRows);
    PRINT N'UPR table count before load: ' + CONVERT(VARCHAR(20), @UprCountBefore);
    PRINT N'UPR table count after load: ' + CONVERT(VARCHAR(20), @UPRTableCountAfter);
    PRINT N'UPR rows written this run: ' + CONVERT(VARCHAR(20), @UPRActiveInserted);
    PRINT N'  (Valid properties only — invalid records go to Review_Q, not UPR)';
    PRINT N'UPR existing rows updated this run: ' + CONVERT(VARCHAR(20), @UPRUpdated);
    IF @UPRActiveInserted <> @UPRTotalInsertedThisRun
        PRINT N'WARNING: UPR rows written does not equal UPR table delta (unexpected non-ACTIVE inserts).';
    PRINT N' ';
    PRINT N'Incoming disposition total (unified rows + mismatch pairs): ' + CONVERT(VARCHAR(20), @IncomingDispositionTotal);
    PRINT N'Review_Q expected candidates (staging): ' + CONVERT(VARCHAR(20), @ReviewQExpected);
    PRINT N'Review_Q staged (total staging rows): ' + CONVERT(VARCHAR(20), @RowsSentToReview);
    PRINT N'Review_Q staged (unique source + reason): ' + CONVERT(VARCHAR(20), @RowsSentToReviewUnique);
    PRINT N'Review_Q - Missing ParcelID: ' + CONVERT(VARCHAR(20), @ReviewMissingParcel);
    PRINT N'Review_Q - Address or Account Not Match: ' + CONVERT(VARCHAR(20), @ReviewMismatch);
    PRINT N'Review_Q - incomplete (NO_ADDRESS_MATCH): ' + CONVERT(VARCHAR(20), @ReviewIncomplete);
    PRINT N'Review_Q - Duplicate: ' + CONVERT(VARCHAR(20), @ReviewDuplicate);
    PRINT N'  (extra SOURCE rows sharing account+address/parcel — not missing UPR properties)';
    PRINT N'Review_Q records inserted: ' + CONVERT(VARCHAR(20), @ReviewIncomingInserted);
    PRINT N'Review_Q table count this run (verify): ' + CONVERT(VARCHAR(20), @ReviewQTableCountAfter);
    IF @ReviewIncomingInserted <> @ReviewQTableCountAfter
        PRINT N'WARNING: Review_Q insert count does not match table count for this run.';
    IF (@ReviewMissingParcel + @ReviewMismatch + @ReviewIncomplete + @ReviewDuplicate) <> @ReviewQTableCountAfter
        PRINT N'WARNING: Review_Q reason breakdown does not sum to table count for this run.';
    IF (@UPRActiveInserted + @ReviewIncomingInserted) <> @IncomingDispositionTotal
        PRINT N'NOTE: UPR properties + Review_Q inserted this run differs from disposition total (re-run may skip existing rows).';
    ELSE
        PRINT N'Check OK: UPR properties + Review_Q inserted = incoming disposition total (one row per MA/SDAT source or pair).';
    PRINT N' ';
    PRINT N'XREF table count before load: ' + CONVERT(VARCHAR(20), @XrefCountBefore);
    PRINT N'XREF table count after load: ' + CONVERT(VARCHAR(20), @XrefTableCountAfter);
    PRINT N'XREF rows inserted this run (table delta): ' + CONVERT(VARCHAR(20), @XrefTotalInsertedThisRun);
    PRINT N'MasterAddress XREF inserted: ' + CONVERT(VARCHAR(20), @MasterAddressXrefInserted);
    PRINT N'SDAT XREF inserted: ' + CONVERT(VARCHAR(20), @SDATXrefInserted);
    PRINT N'Review rejected XREF inserted (duplicate losers linked to ACTIVE UPR only): ' + CONVERT(VARCHAR(20), @ReviewXrefRejectedInserted);
    PRINT N'eProperty XREF inserted: ' + CONVERT(VARCHAR(20), @EPropertyXrefInserted);
    PRINT N'eProperty XREF staged no-match (not inserted if row exists): ' + CONVERT(VARCHAR(20), @EPropertyXrefNoMatch);
    PRINT N'CASE XREF inserted: ' + CONVERT(VARCHAR(20), @CaseXrefInserted);
    PRINT N'CASE XREF staged no-match (not inserted if row exists): ' + CONVERT(VARCHAR(20), @CaseXrefNoMatch);
    PRINT N'MPDU XREF inserted: ' + CONVERT(VARCHAR(20), @MPDUXrefInserted);
    PRINT N'MPDU XREF staged no-match (not inserted if row exists): ' + CONVERT(VARCHAR(20), @MPDUXrefNoMatch);
    PRINT N'MULTIFAMILY XREF inserted: ' + CONVERT(VARCHAR(20), @MultifamilyXrefInserted);
    PRINT N'MULTIFAMILY XREF staged no-match (not inserted if row exists): ' + CONVERT(VARCHAR(20), @MultifamilyXrefNoMatch);
    PRINT N'Total XREF inserted (sum of inserts above): ' + CONVERT(VARCHAR(20), @TotalXrefInserted);
    IF @TotalXrefInserted <> @XrefTotalInsertedThisRun
        PRINT N'WARNING: XREF insert sum does not match XREF table delta (re-run may skip existing rows).';
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
    PRINT N'UPR LOAD COMPLETE';

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
