/*
================================================================================
  UPR Master Load Script - Hierarchical model (v2)

  Source of truth: docs/NewUPRTABLEUSED.docx + docs/Response.docx
  Schema:          ddl/03_new_upr_schema.sql

  Replaces the flat UPROPERTYRECORDS load completely.
  Legacy flat loader archived as: legacy/load_upr_master_legacy_flat.sql

  CLIENT RULES (Response.docx):
    1) NewUPRTABLEUSED is source of truth; replace old model completely
    2) COMPLEX when MA MultiFamily + Account# + 2+ distinct building addresses
    3) MultiFamily with 1 address -> Property -> Building -> Unit
    4) Condo (SDAT): Condo (Parent NULL) -> Unit; account on Condo UPR
    5) SF / Warehouse / Office / Park / etc -> Property -> Building -> Unit
    6) Address via ADDRESS + UPR_ADDRESS only; Contact required when address valid
    7) Staging in temp tables after validate/normalize; print statistics
    8) AccountNumber nullable, not unique; CommunityName on COMPLEX only

  Prerequisites: run ddl/03_new_upr_schema.sql first.
  Re-runnable: a second run against unchanged incoming data inserts nothing.

  EDIT USE database name to match your environment.
================================================================================
*/
USE UPRXDB_TEST;
GO

/* Required for filtered indexes. SSMS sets these ON, sqlcmd does not:
   without them CREATE INDEX and later INSERTs fail with error 1934. */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET ARITHABORT ON;
SET NUMERIC_ROUNDABORT OFF;
GO

/* ---- Inline normalization functions (same helpers as legacy flat load) ---- */
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
        WHEN N'WAY' THEN N'WAY' WHEN N'CIRCLE' THEN N'CIR' WHEN N'CIR' THEN N'CIR'
        WHEN N'TERRACE' THEN N'TER' WHEN N'TER' THEN N'TER'
        WHEN N'PARKWAY' THEN N'PKWY' WHEN N'PKWY' THEN N'PKWY'
        WHEN N'HIGHWAY' THEN N'HWY' WHEN N'HWY' THEN N'HWY'
        WHEN N'TRAIL' THEN N'TRL' WHEN N'TRL' THEN N'TRL'
        WHEN N'SQUARE' THEN N'SQ' WHEN N'SQ' THEN N'SQ'
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

/* UPR ZipCode CHECK: ##### or #####-#### - strip non-digits, pad/ format */
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

/* Strip leading zeros from numeric street numbers - 02456 -> 2456 */
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

    /* Leading-zero digit prefix before letters/suffix - 012A -> 12A */
    WHILE LEN(@s) > 1
      AND LEFT(@s, 1) = N'0'
      AND SUBSTRING(@s, 2, 1) LIKE N'[0-9]'
        SET @s = SUBSTRING(@s, 2, LEN(@s) - 1);

    RETURN @s;
END;
GO

/* Numeric SDAT accounts - zero-pad to 8 so 31023 and 00031023 dedupe/MERGE consistently */
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

/* Reject placeholder/bad street numbers (e.g. 0) - UQ_UPropertyRecords_Address */
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

/* Real ParcelID only - reject blank / all-zeros placeholders (0000, 0, 00000) that
   falsely collide thousands of distinct properties on UQ_UPropertyRecords_ParcelID */
CREATE OR ALTER FUNCTION dbo.fn_UPR_NormalizeParcelID (@parcel NVARCHAR(50))
RETURNS NVARCHAR(50)
AS
BEGIN
    DECLARE @p NVARCHAR(50) = NULLIF(LTRIM(RTRIM(ISNULL(@parcel, N''))), N'');
    IF @p IS NULL RETURN NULL;
    /* all zeros / numeric zero -> not a real parcel */
    IF @p NOT LIKE N'%[^0]%' RETURN NULL;
    IF TRY_CONVERT(BIGINT, @p) = 0 RETURN NULL;
    RETURN @p;
END;
GO

CREATE OR ALTER FUNCTION dbo.fn_UPR_IsValidParcelID (@parcel NVARCHAR(50))
RETURNS BIT
AS
BEGIN
    IF dbo.fn_UPR_NormalizeParcelID(@parcel) IS NULL RETURN 0;
    RETURN 1;
END;
GO

/* Prefer 8-digit numeric SDAT-style accounts over alphanumeric / short keys */
CREATE OR ALTER FUNCTION dbo.fn_UPR_IsPreferredAccount (@acct NVARCHAR(50))
RETURNS BIT
AS
BEGIN
    DECLARE @n NVARCHAR(50) = dbo.fn_UPR_NormalizeSDATAccount(NULLIF(LTRIM(RTRIM(@acct)), N''));
    IF @n IS NULL RETURN 0;
    IF @n LIKE N'[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]' AND LEN(@n) = 8 RETURN 1;
    RETURN 0;
END;
GO

/* Address quality score 0-4 for MA vs SDAT reconciliation on mismatch */
CREATE OR ALTER FUNCTION dbo.fn_UPR_AddressQualityScore (
    @StreetNumber NVARCHAR(20),
    @StreetName NVARCHAR(150),
    @City NVARCHAR(100),
    @ZipCode NVARCHAR(10)
)
RETURNS INT
AS
BEGIN
    DECLARE @s INT = 0;
    IF dbo.fn_UPR_IsValidStreetNumber(@StreetNumber) = 1 SET @s = @s + 1;
    IF NULLIF(UPPER(LTRIM(RTRIM(@StreetName))), N'') IS NOT NULL SET @s = @s + 1;
    IF NULLIF(UPPER(LTRIM(RTRIM(@City))), N'') IS NOT NULL SET @s = @s + 1;
    IF dbo.fn_UPR_IsValidZipCode(@ZipCode) = 1 SET @s = @s + 1;
    RETURN @s;
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


/* ========================================================================
   SCHEMA ENSURE BATCH
   Must run in its own batch (before GO) because the main batch reads
   SDATIncomingTableX1.CondoUnit. A column added in the same batch that
   reads it fails with "Invalid column name".
   ======================================================================== */
SET NOCOUNT ON;

IF OBJECT_ID(N'dbo.SDATIncomingTableX1', N'U') IS NOT NULL
   AND COL_LENGTH(N'dbo.SDATIncomingTableX1', N'CondoUnit') IS NULL
BEGIN
    ALTER TABLE dbo.SDATIncomingTableX1 ADD CondoUnit NVARCHAR(50) NULL;
    PRINT N'Schema: added CondoUnit NVARCHAR(50) NULL to dbo.SDATIncomingTableX1.';
END;
GO

/* ========================================================================
   MAIN LOAD BATCH - hierarchical UPR write
   ======================================================================== */
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @RunUser     NVARCHAR(100) = SUSER_SNAME();
DECLARE @AuditUser   NVARCHAR(128) = COALESCE(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(128), SUSER_SNAME()))), N''), N'SYSTEM');
/* Truncated to the second: assigning SYSDATETIME() to DATETIME2(0) ROUNDS,
   which can produce a timestamp in the future and trip <= SYSDATETIME() checks */
DECLARE @Now         DATETIME2(0)  = CONVERT(DATETIME2(0), CONVERT(VARCHAR(19), SYSDATETIME(), 126));
DECLARE @BatchStart  DATETIME2(0)  = SYSDATETIME();
DECLARE @DefaultState CHAR(2)      = N'MD';
DECLARE @ErrorMessage NVARCHAR(500);
DECLARE @PreflightErrors NVARCHAR(MAX) = N'';

DECLARE @MARead INT = 0, @SDATRead INT = 0, @StageRows INT = 0;
DECLARE @ValidRows INT = 0, @InvalidRows INT = 0, @ReviewInserted INT = 0;
DECLARE @ParentInserted INT = 0, @ComplexInserted INT = 0, @PropertyInserted INT = 0, @CondoInserted INT = 0;
DECLARE @BuildingInserted INT = 0, @UnitInserted INT = 0, @AddressInserted INT = 0;
DECLARE @ContactInserted INT = 0, @UPRContactInserted INT = 0;
DECLARE @XrefInserted INT = 0, @ClosureRows INT = 0, @StatusHistInserted INT = 0, @AuditInserted INT = 0;
DECLARE @ComplexGroups INT = 0, @PropertyGroups INT = 0, @CondoGroups INT = 0, @ParentSkipped INT = 0;

DECLARE @EtComplex INT, @EtProperty INT, @EtBuilding INT, @EtUnit INT, @EtCondo INT;
DECLARE @RoleOwner INT, @AddrPhysical INT, @CtOrg INT;

BEGIN TRY
BEGIN TRANSACTION;

PRINT N'================================================================';
PRINT N'UPR hierarchical load starting: ' + CONVERT(NVARCHAR(30), @BatchStart, 121);
PRINT N'================================================================';

/* ============================================================================
   0. PREFLIGHT - required hierarchical tables
   ============================================================================ */
PRINT N'Step 0: Preflight required tables...';

IF OBJECT_ID(N'dbo.REF_ENTITYTYPE', N'U') IS NULL SET @PreflightErrors = @PreflightErrors + N'REF_ENTITYTYPE; ';
IF OBJECT_ID(N'dbo.REF_PROPERTYTYPE', N'U') IS NULL SET @PreflightErrors = @PreflightErrors + N'REF_PROPERTYTYPE; ';
IF OBJECT_ID(N'dbo.REF_CONTACTTYPE', N'U') IS NULL SET @PreflightErrors = @PreflightErrors + N'REF_CONTACTTYPE; ';
IF OBJECT_ID(N'dbo.REF_ROLETYPE', N'U') IS NULL SET @PreflightErrors = @PreflightErrors + N'REF_ROLETYPE; ';
IF OBJECT_ID(N'dbo.REF_ADDRESSROLE', N'U') IS NULL SET @PreflightErrors = @PreflightErrors + N'REF_ADDRESSROLE; ';
IF OBJECT_ID(N'dbo.UPR', N'U') IS NULL SET @PreflightErrors = @PreflightErrors + N'UPR; ';
IF OBJECT_ID(N'dbo.ADDRESS', N'U') IS NULL SET @PreflightErrors = @PreflightErrors + N'ADDRESS; ';
IF OBJECT_ID(N'dbo.COMPLEX', N'U') IS NULL SET @PreflightErrors = @PreflightErrors + N'COMPLEX; ';
IF OBJECT_ID(N'dbo.PROPERTY', N'U') IS NULL SET @PreflightErrors = @PreflightErrors + N'PROPERTY; ';
IF OBJECT_ID(N'dbo.CONDO', N'U') IS NULL SET @PreflightErrors = @PreflightErrors + N'CONDO; ';
IF OBJECT_ID(N'dbo.BUILDING', N'U') IS NULL SET @PreflightErrors = @PreflightErrors + N'BUILDING; ';
IF OBJECT_ID(N'dbo.UNIT', N'U') IS NULL SET @PreflightErrors = @PreflightErrors + N'UNIT; ';
IF OBJECT_ID(N'dbo.UPR_ADDRESS', N'U') IS NULL SET @PreflightErrors = @PreflightErrors + N'UPR_ADDRESS; ';
IF OBJECT_ID(N'dbo.EXTERNAL_IDENTIFIER_XREF', N'U') IS NULL SET @PreflightErrors = @PreflightErrors + N'EXTERNAL_IDENTIFIER_XREF; ';
IF OBJECT_ID(N'dbo.CONTACT', N'U') IS NULL SET @PreflightErrors = @PreflightErrors + N'CONTACT; ';
IF OBJECT_ID(N'dbo.UPR_CONTACT', N'U') IS NULL SET @PreflightErrors = @PreflightErrors + N'UPR_CONTACT; ';
IF OBJECT_ID(N'dbo.UPR_CLOSURE', N'U') IS NULL SET @PreflightErrors = @PreflightErrors + N'UPR_CLOSURE; ';
IF OBJECT_ID(N'dbo.AuditLog', N'U') IS NULL SET @PreflightErrors = @PreflightErrors + N'AuditLog; ';
IF OBJECT_ID(N'dbo.UPRMATCHREVIEW_Q', N'U') IS NULL SET @PreflightErrors = @PreflightErrors + N'UPRMATCHREVIEW_Q; ';
IF OBJECT_ID(N'dbo.UPRSTATUSHISTORY', N'U') IS NULL SET @PreflightErrors = @PreflightErrors + N'UPRSTATUSHISTORY; ';

IF OBJECT_ID(N'dbo.fn_UPR_NormalizeSDATAccount', N'FN') IS NULL
   AND OBJECT_ID(N'dbo.fn_UPR_NormalizeSDATAccount', N'FS') IS NULL
    SET @PreflightErrors = @PreflightErrors + N'fn_UPR_NormalizeSDATAccount; ';
IF OBJECT_ID(N'dbo.fn_UPR_NormalizeStreetNumber', N'FN') IS NULL
    SET @PreflightErrors = @PreflightErrors + N'fn_UPR_NormalizeStreetNumber; ';
IF OBJECT_ID(N'dbo.fn_UPR_NormalizeZipCode', N'FN') IS NULL
    SET @PreflightErrors = @PreflightErrors + N'fn_UPR_NormalizeZipCode; ';
IF OBJECT_ID(N'dbo.fn_UPR_IsValidStreetNumber', N'FN') IS NULL
    SET @PreflightErrors = @PreflightErrors + N'fn_UPR_IsValidStreetNumber; ';
IF OBJECT_ID(N'dbo.fn_UPR_IsValidZipCode', N'FN') IS NULL
    SET @PreflightErrors = @PreflightErrors + N'fn_UPR_IsValidZipCode; ';
IF OBJECT_ID(N'dbo.fn_UPR_StdStreetToken', N'FN') IS NULL
    SET @PreflightErrors = @PreflightErrors + N'fn_UPR_StdStreetToken; ';

IF NULLIF(LTRIM(RTRIM(@PreflightErrors)), N'') IS NOT NULL
BEGIN
    SET @ErrorMessage = N'Preflight failed - missing objects: ' + @PreflightErrors;
    THROW 50001, @ErrorMessage, 1;
END;

PRINT N'Step 0 complete - required tables/functions present.';

/* ============================================================================
   1. SEED / ENSURE REF codes used by load
   ============================================================================ */
PRINT N'Step 1: Ensure REF entity / role / address / contact / property types...';

IF NOT EXISTS (SELECT 1 FROM dbo.REF_ENTITYTYPE WHERE Description = N'Complex')
    INSERT INTO dbo.REF_ENTITYTYPE (Description) VALUES (N'Complex');
IF NOT EXISTS (SELECT 1 FROM dbo.REF_ENTITYTYPE WHERE Description = N'Property')
    INSERT INTO dbo.REF_ENTITYTYPE (Description) VALUES (N'Property');
IF NOT EXISTS (SELECT 1 FROM dbo.REF_ENTITYTYPE WHERE Description = N'Building')
    INSERT INTO dbo.REF_ENTITYTYPE (Description) VALUES (N'Building');
IF NOT EXISTS (SELECT 1 FROM dbo.REF_ENTITYTYPE WHERE Description = N'Unit')
    INSERT INTO dbo.REF_ENTITYTYPE (Description) VALUES (N'Unit');
IF NOT EXISTS (SELECT 1 FROM dbo.REF_ENTITYTYPE WHERE Description = N'Condo')
    INSERT INTO dbo.REF_ENTITYTYPE (Description) VALUES (N'Condo');
IF NOT EXISTS (SELECT 1 FROM dbo.REF_ENTITYTYPE WHERE Description = N'ADU')
    INSERT INTO dbo.REF_ENTITYTYPE (Description) VALUES (N'ADU');

IF NOT EXISTS (SELECT 1 FROM dbo.REF_ROLETYPE WHERE RoleTypeCode = N'OWNER')
    INSERT INTO dbo.REF_ROLETYPE (RoleTypeCode, Description) VALUES (N'OWNER', N'Owner');

IF NOT EXISTS (SELECT 1 FROM dbo.REF_ADDRESSROLE WHERE AddressRoleCode = N'PHYSICAL')
    INSERT INTO dbo.REF_ADDRESSROLE (AddressRoleCode, Description) VALUES (N'PHYSICAL', N'Physical Address');

IF NOT EXISTS (SELECT 1 FROM dbo.REF_CONTACTTYPE WHERE ContactTypeCode = N'ORGANIZATION')
    INSERT INTO dbo.REF_CONTACTTYPE (ContactTypeCode, Description) VALUES (N'ORGANIZATION', N'Organization');

/* Ensure core property-type short codes (incl. INSTCF used by MA mapping) */
IF OBJECT_ID('tempdb..#SeedPT') IS NOT NULL DROP TABLE #SeedPT;
CREATE TABLE #SeedPT (
    Code NVARCHAR(128) NOT NULL PRIMARY KEY,
    Name NVARCHAR(128) NOT NULL,
    AllowBldg BIT NOT NULL,
    AllowUnit BIT NOT NULL
);
INSERT INTO #SeedPT (Code, Name, AllowBldg, AllowUnit) VALUES
    (N'SF',     N'Single Family', 1, 1),
    (N'MULTI',  N'Multi-Family', 1, 1),
    (N'TH',     N'Townhouse', 1, 1),
    (N'CONDO',  N'Condominium', 1, 1),
    (N'MIXED',  N'Mixed Use', 1, 1),
    (N'LAND',   N'Vacant Land', 1, 0),
    (N'WAREHS', N'Warehouse', 1, 0),
    (N'OFFICE', N'Office', 1, 0),
    (N'PARK',   N'Park', 1, 0),
    (N'APT',    N'Apartment Complex', 1, 1),
    (N'INSTCF', N'Institutional/Community Facilities', 1, 0),
    (N'UNKNWN', N'Unknown / not supplied by source', 1, 1);

INSERT INTO dbo.REF_PROPERTYTYPE
    (PropertyTypeCode, PropertyTypeName, AllowsBuildings, AllowsUnits, DeletedInd,
     CreationUserID, CreationDate, LastUpdatedUserID, LastUpdatedDate)
SELECT
    s.Code, s.Name, s.AllowBldg, s.AllowUnit, 0,
    @AuditUser, @Now, @AuditUser, @Now
FROM #SeedPT s
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.REF_PROPERTYTYPE t WHERE t.PropertyTypeCode = s.Code
);

SELECT @EtComplex  = EntityTypeID FROM dbo.REF_ENTITYTYPE WHERE Description = N'Complex';
SELECT @EtProperty = EntityTypeID FROM dbo.REF_ENTITYTYPE WHERE Description = N'Property';
SELECT @EtBuilding = EntityTypeID FROM dbo.REF_ENTITYTYPE WHERE Description = N'Building';
SELECT @EtUnit     = EntityTypeID FROM dbo.REF_ENTITYTYPE WHERE Description = N'Unit';
SELECT @EtCondo    = EntityTypeID FROM dbo.REF_ENTITYTYPE WHERE Description = N'Condo';
SELECT @RoleOwner  = RoleTypeID FROM dbo.REF_ROLETYPE WHERE RoleTypeCode = N'OWNER';
SELECT @AddrPhysical = AddressRoleID FROM dbo.REF_ADDRESSROLE WHERE AddressRoleCode = N'PHYSICAL';
SELECT @CtOrg = ContactTypeID FROM dbo.REF_CONTACTTYPE WHERE ContactTypeCode = N'ORGANIZATION';

IF @EtComplex IS NULL OR @EtProperty IS NULL OR @EtBuilding IS NULL OR @EtUnit IS NULL OR @EtCondo IS NULL
    THROW 50002, N'REF_ENTITYTYPE missing Complex/Property/Building/Unit/Condo.', 1;
IF @RoleOwner IS NULL OR @AddrPhysical IS NULL OR @CtOrg IS NULL
    THROW 50003, N'REF OWNER / PHYSICAL / ORGANIZATION missing.', 1;

PRINT N'Step 1 complete.';

/* ============================================================================
   2. READ MA -> #MA
   ============================================================================ */
PRINT N'Step 2: Read MasterAddress (MAIncomingTableX1)...';

IF OBJECT_ID(N'dbo.MAIncomingTableX1', N'U') IS NULL
    THROW 50010, N'MA source table dbo.MAIncomingTableX1 not found.', 1;

IF OBJECT_ID('tempdb..#MA') IS NOT NULL DROP TABLE #MA;

BEGIN TRY
    SELECT
        ma.MasterAddressID,
        SourceSystem         = CONVERT(VARCHAR(50), N'ADDRESS_MASTER'),
        SourceRecordID       = CONVERT(VARCHAR(150), ma.MasterAddressID),
        MasterAddressID_Out  = ma.MasterAddressID,
        KdatRecordID         = CAST(NULL AS INT),
        AccountNumber        = dbo.fn_UPR_NormalizeSDATAccount(
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
            WHEN N'WAY' THEN N'WAY' WHEN N'CIRCLE' THEN N'CIR' WHEN N'CIR' THEN N'CIR'
            WHEN N'TERRACE' THEN N'TER' WHEN N'TER' THEN N'TER'
            WHEN N'PARKWAY' THEN N'PKWY' WHEN N'PKWY' THEN N'PKWY'
            WHEN N'HIGHWAY' THEN N'HWY' WHEN N'HWY' THEN N'HWY'
            WHEN N'TRAIL' THEN N'TRL' WHEN N'TRL' THEN N'TRL'
            WHEN N'SQUARE' THEN N'SQ' WHEN N'SQ' THEN N'SQ'
            ELSE NULLIF(UPPER(LTRIM(RTRIM(ma.StreetType))), N'')
        END,
        UnitNumber           = NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), ma.Unit))), N''),
        CondoUnit            = CAST(NULL AS NVARCHAR(50)),
        City                 = NULLIF(UPPER(LTRIM(RTRIM(ma.City))), N''),
        [State]              = @DefaultState,
        ZipCode              = dbo.fn_UPR_NormalizeZipCode(ma.ZipCode),
        PropertyTypeRaw      = NULLIF(UPPER(LTRIM(RTRIM(ma.LUCategory))), N''),
        PropertyType         = CONVERT(NVARCHAR(6), CASE
            WHEN NULLIF(LTRIM(RTRIM(ma.LUCategory)), N'') IS NULL THEN NULL
            WHEN UPPER(LTRIM(RTRIM(ma.LUCategory))) LIKE N'%MULT%FAMILY%' THEN N'MULTI'
            WHEN UPPER(LTRIM(RTRIM(ma.LUCategory))) LIKE N'%MULTIFAMILY%' THEN N'MULTI'
            WHEN UPPER(LTRIM(RTRIM(ma.LUCategory))) LIKE N'%MULTY%FAMILY%' THEN N'MULTI'
            WHEN UPPER(LTRIM(RTRIM(ma.LUCategory))) IN (N'MULTI', N'MULTY', N'MULTI-FAMILY', N'MULTY-FAMILY') THEN N'MULTI'
            WHEN UPPER(LTRIM(RTRIM(ma.LUCategory))) LIKE N'%APART%' THEN N'APT'
            WHEN UPPER(LTRIM(RTRIM(ma.LUCategory))) IN (N'APT', N'APARTMENT', N'APARTMENTS') THEN N'APT'
            WHEN UPPER(LTRIM(RTRIM(ma.LUCategory))) LIKE N'%CONDO%' THEN N'CONDO'
            WHEN UPPER(LTRIM(RTRIM(ma.LUCategory))) IN (N'C') THEN N'CONDO'
            WHEN UPPER(LTRIM(RTRIM(ma.LUCategory))) = N'SINGLE FAMILY DETACHED' THEN N'SF'
            WHEN UPPER(LTRIM(RTRIM(ma.LUCategory))) = N'SINGLE FAMILY ATTACHED' THEN N'SF'
            WHEN UPPER(LTRIM(RTRIM(ma.LUCategory))) = N'VACANT' THEN N'LAND'
            WHEN UPPER(LTRIM(RTRIM(ma.LUCategory))) LIKE N'%VACANT%' THEN N'LAND'
            WHEN UPPER(LTRIM(RTRIM(ma.LUCategory))) = N'TOWNHOUSE' THEN N'TH'
            WHEN UPPER(LTRIM(RTRIM(ma.LUCategory))) = N'MIXED USE' THEN N'MIXED'
            WHEN UPPER(LTRIM(RTRIM(ma.LUCategory))) = N'OFFICE' THEN N'OFFICE'
            WHEN UPPER(LTRIM(RTRIM(ma.LUCategory))) LIKE N'%OFFICE%' THEN N'OFFICE'
            WHEN UPPER(LTRIM(RTRIM(ma.LUCategory))) LIKE N'%WAREHOUSE%' THEN N'WAREHS'
            WHEN UPPER(LTRIM(RTRIM(ma.LUCategory))) = N'PARK' THEN N'PARK'
            WHEN UPPER(LTRIM(RTRIM(ma.LUCategory))) LIKE N'%PARK%'
             AND UPPER(LTRIM(RTRIM(ma.LUCategory))) NOT LIKE N'%PARKWAY%' THEN N'PARK'
            WHEN UPPER(LTRIM(RTRIM(ma.LUCategory))) LIKE N'%INSTITUTIONAL%COMMUNITY%' THEN N'INSTCF'
            WHEN UPPER(LTRIM(RTRIM(ma.LUCategory))) LIKE N'INSTITUTIONAL/%' THEN N'INSTCF'
            ELSE LEFT(
                REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                    UPPER(LTRIM(RTRIM(ma.LUCategory))),
                    N'/', N''), N' ', N''), N'-', N''), N'&', N''), N'''', N''),
                6)
        END),
        OwnerName            = CAST(NULL AS NVARCHAR(200)),
        YearBuilt            = CAST(NULL AS SMALLINT),
        DwellingUnits        = CAST(NULL AS INT),
        YCoordinate          = TRY_CONVERT(INT, NULLIF(ma.YCoordinate, 0)),
        XCoordinate          = TRY_CONVERT(INT, NULLIF(ma.XCoordinate, 0)),
        NormalizedStreetAddress = UPPER(LTRIM(RTRIM(
            ISNULL(dbo.fn_UPR_NormalizeStreetNumber(CONVERT(NVARCHAR(20), ma.StreetNumber)), N'') + N' ' +
            ISNULL(UPPER(LTRIM(RTRIM(ma.StreetName))), N'') + N' ' +
            ISNULL(dbo.fn_UPR_StdStreetToken(CONVERT(NVARCHAR(50), ma.StreetType)),
                   NULLIF(UPPER(LTRIM(RTRIM(ma.StreetType))), N''))
        ))),
        NormalizedFullAddress = UPPER(LTRIM(RTRIM(
            ISNULL(dbo.fn_UPR_NormalizeStreetNumber(CONVERT(NVARCHAR(20), ma.StreetNumber)), N'') + N' ' +
            ISNULL(UPPER(LTRIM(RTRIM(ma.StreetName))), N'') + N' ' +
            ISNULL(dbo.fn_UPR_StdStreetToken(CONVERT(NVARCHAR(50), ma.StreetType)),
                   NULLIF(UPPER(LTRIM(RTRIM(ma.StreetType))), N'')) + N' ' +
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
    FROM dbo.MAIncomingTableX1 ma;
END TRY
BEGIN CATCH
    SET @ErrorMessage = N'Cannot read MasterAddress source: ' + ERROR_MESSAGE()
        + N' - verify dbo.MAIncomingTableX1.';
    THROW 50010, @ErrorMessage, 1;
END CATCH;

SET @MARead = (SELECT COUNT(*) FROM #MA);
PRINT N'Step 2 complete - MA rows: ' + CONVERT(NVARCHAR(20), @MARead);

/* Seed any new MA-derived property type codes */
IF OBJECT_ID('tempdb..#MaPT') IS NOT NULL DROP TABLE #MaPT;
SELECT
    PropertyType AS Code,
    COALESCE(MAX(PropertyTypeRaw), PropertyType) AS TypeName
INTO #MaPT
FROM #MA
WHERE NULLIF(LTRIM(RTRIM(PropertyType)), N'') IS NOT NULL
GROUP BY PropertyType;

INSERT INTO dbo.REF_PROPERTYTYPE
    (PropertyTypeCode, PropertyTypeName, AllowsBuildings, AllowsUnits, DeletedInd,
     CreationUserID, CreationDate, LastUpdatedUserID, LastUpdatedDate)
SELECT
    m.Code,
    LEFT(m.TypeName, 128),
    1,
    CASE WHEN m.Code IN (N'SF', N'LAND', N'OFFICE', N'WAREHS', N'PARK', N'INSTCF') THEN 0 ELSE 1 END,
    0, @AuditUser, @Now, @AuditUser, @Now
FROM #MaPT m
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.REF_PROPERTYTYPE t WHERE t.PropertyTypeCode = m.Code
);
DROP TABLE #MaPT;

/* ============================================================================
   3. READ SDAT -> #SDAT
   ============================================================================ */
PRINT N'Step 3: Read SDAT (SDATIncomingTableX1)...';

IF OBJECT_ID(N'dbo.SDATIncomingTableX1', N'U') IS NULL
    THROW 50011, N'SDAT source table dbo.SDATIncomingTableX1 not found.', 1;

IF COL_LENGTH(N'dbo.SDATIncomingTableX1', N'CondoUnit') IS NULL
    THROW 50012, N'SDATIncomingTableX1.CondoUnit missing. Run the whole script from the top (schema-ensure batch adds it).', 1;

IF OBJECT_ID('tempdb..#SDAT') IS NOT NULL DROP TABLE #SDAT;

BEGIN TRY
    SELECT
        KdatRecordID         = TRY_CONVERT(INT, s.RealPropertyTaxInformationID),
        SourceSystem         = CONVERT(VARCHAR(50), N'KDAT'),
        SourceRecordID       = CONVERT(VARCHAR(150), s.RealPropertyTaxInformationID),
        MasterAddressID_Out  = CAST(NULL AS INT),
        AccountNumber        = dbo.fn_UPR_NormalizeSDATAccount(
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
            WHEN N'WAY' THEN N'WAY' WHEN N'CIRCLE' THEN N'CIR' WHEN N'CIR' THEN N'CIR'
            WHEN N'TERRACE' THEN N'TER' WHEN N'TER' THEN N'TER'
            WHEN N'PARKWAY' THEN N'PKWY' WHEN N'PKWY' THEN N'PKWY'
            WHEN N'HIGHWAY' THEN N'HWY' WHEN N'HWY' THEN N'HWY'
            WHEN N'TRAIL' THEN N'TRL' WHEN N'TRL' THEN N'TRL'
            WHEN N'SQUARE' THEN N'SQ' WHEN N'SQ' THEN N'SQ'
            ELSE NULLIF(UPPER(LTRIM(RTRIM(s.PremisesStreetType))), N'')
        END,
        UnitNumber           = NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), s.CondoUnit))), N''),
        CondoUnit            = NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), s.CondoUnit))), N''),
        City                 = NULLIF(UPPER(LTRIM(RTRIM(s.PremisesCity))), N''),
        [State]              = CASE
            WHEN LEN(UPPER(LTRIM(RTRIM(ISNULL(s.PremisesState, N''))))) = 2
             AND UPPER(LTRIM(RTRIM(s.PremisesState))) NOT LIKE N'%[^A-Z]%'
                THEN UPPER(LTRIM(RTRIM(s.PremisesState)))
            ELSE @DefaultState
        END,
        ZipCode              = dbo.fn_UPR_NormalizeZipCode(s.PremisesZipCode),
        PropertyTypeRaw      = CAST(NULL AS NVARCHAR(50)),
        PropertyType         = CONVERT(NVARCHAR(6), N'CONDO'),
        OwnerName            = NULLIF(LTRIM(RTRIM(CAST(s.Owner AS NVARCHAR(200)))), N''),
        YearBuilt            = TRY_CONVERT(SMALLINT, s.YearBuilt),
        DwellingUnits        = TRY_CONVERT(INT, s.DwellingUnits),
        YCoordinate          = CAST(NULL AS INT),
        XCoordinate          = CAST(NULL AS INT),
        NormalizedStreetAddress = UPPER(LTRIM(RTRIM(
            ISNULL(dbo.fn_UPR_NormalizeStreetNumber(LTRIM(RTRIM(s.PremisesNumber))), N'') + N' ' +
            ISNULL(UPPER(LTRIM(RTRIM(s.PremisesStreetName))), N'') + N' ' +
            ISNULL(dbo.fn_UPR_StdStreetToken(CONVERT(NVARCHAR(50), s.PremisesStreetType)),
                   NULLIF(UPPER(LTRIM(RTRIM(s.PremisesStreetType))), N''))
        ))),
        NormalizedFullAddress = UPPER(LTRIM(RTRIM(
            ISNULL(dbo.fn_UPR_NormalizeStreetNumber(LTRIM(RTRIM(s.PremisesNumber))), N'') + N' ' +
            ISNULL(UPPER(LTRIM(RTRIM(s.PremisesStreetName))), N'') + N' ' +
            ISNULL(dbo.fn_UPR_StdStreetToken(CONVERT(NVARCHAR(50), s.PremisesStreetType)),
                   NULLIF(UPPER(LTRIM(RTRIM(s.PremisesStreetType))), N'')) + N' ' +
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
    FROM dbo.SDATIncomingTableX1 s;
END TRY
BEGIN CATCH
    SET @ErrorMessage = N'Cannot read SDAT source: ' + ERROR_MESSAGE()
        + N' - verify dbo.SDATIncomingTableX1.';
    THROW 50011, @ErrorMessage, 1;
END CATCH;

SET @SDATRead = (SELECT COUNT(*) FROM #SDAT);
PRINT N'Step 3 complete - SDAT rows: ' + CONVERT(NVARCHAR(20), @SDATRead);

/* ============================================================================
   4. BUILD #Stage (UNION MA + SDAT) + validate + PathType + GroupKey
   ============================================================================ */
PRINT N'Step 4: Build #Stage unified rows, validate, assign PathType/GroupKey...';

IF OBJECT_ID('tempdb..#Stage') IS NOT NULL DROP TABLE #Stage;

CREATE TABLE #Stage (
    StageKey                INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    SourceSystem            VARCHAR(50)  NOT NULL,
    SourceRecordID          VARCHAR(150) NOT NULL,
    MasterAddressID         INT          NULL,
    KdatRecordID            INT          NULL,
    AccountNumber           VARCHAR(50)  NULL,
    ParcelID                NVARCHAR(50) NULL,
    StreetNumber            VARCHAR(20)  NULL,
    StreetName              VARCHAR(200) NULL,
    StreetType              VARCHAR(30)  NULL,
    City                    VARCHAR(100) NULL,
    [State]                 CHAR(2)      NULL,
    ZipCode                 VARCHAR(10)  NULL,
    UnitNumber              VARCHAR(50)  NULL,
    CondoUnit               VARCHAR(50)  NULL,
    PropertyType            NVARCHAR(6)  NULL,
    OwnerName               NVARCHAR(200) NULL,
    YearBuilt               SMALLINT     NULL,
    DwellingUnits           INT          NULL,
    YCoordinate             INT          NULL,
    XCoordinate             INT          NULL,
    NormalizedStreetAddress NVARCHAR(300) NULL,
    NormalizedFullAddress   NVARCHAR(300) NULL,
    HasRequiredAddress      BIT          NOT NULL,
    IsValid                 BIT          NOT NULL CONSTRAINT DF_Stage_IsValid DEFAULT (0),
    ReviewReason            NVARCHAR(255) NULL,
    PathType                VARCHAR(20)  NULL,  /* COMPLEX | PROPERTY | CONDO */
    GroupKey                NVARCHAR(450) NULL,
    DistinctAddrOnAccount   INT          NULL
);

INSERT INTO #Stage (
    SourceSystem, SourceRecordID, MasterAddressID, KdatRecordID, AccountNumber, ParcelID,
    StreetNumber, StreetName, StreetType, City, [State], ZipCode,
    UnitNumber, CondoUnit, PropertyType, OwnerName, YearBuilt, DwellingUnits,
    YCoordinate, XCoordinate, NormalizedStreetAddress, NormalizedFullAddress, HasRequiredAddress
)
/* LEFT() on every text column: the SDAT incoming table is NVARCHAR(MAX) in the
   client schema, so any wide value would otherwise abort the load with
   "String or binary data would be truncated". */
SELECT
    SourceSystem, LEFT(SourceRecordID, 150), MasterAddressID_Out, KdatRecordID,
    LEFT(AccountNumber, 50), LEFT(ParcelID, 50),
    LEFT(StreetNumber, 20), LEFT(StreetName, 200), LEFT(StreetType, 30),
    LEFT(City, 100), LEFT([State], 2), LEFT(ZipCode, 10),
    LEFT(UnitNumber, 50), LEFT(CondoUnit, 50), LEFT(PropertyType, 6),
    LEFT(OwnerName, 200), YearBuilt, DwellingUnits,
    YCoordinate, XCoordinate,
    LEFT(NormalizedStreetAddress, 300), LEFT(NormalizedFullAddress, 300), HasRequiredAddress
FROM #MA
UNION ALL
SELECT
    SourceSystem, LEFT(SourceRecordID, 150), MasterAddressID_Out, KdatRecordID,
    LEFT(AccountNumber, 50), LEFT(ParcelID, 50),
    LEFT(StreetNumber, 20), LEFT(StreetName, 200), LEFT(StreetType, 30),
    LEFT(City, 100), LEFT([State], 2), LEFT(ZipCode, 10),
    LEFT(UnitNumber, 50), LEFT(CondoUnit, 50), LEFT(PropertyType, 6),
    LEFT(OwnerName, 200), YearBuilt, DwellingUnits,
    YCoordinate, XCoordinate,
    LEFT(NormalizedStreetAddress, 300), LEFT(NormalizedFullAddress, 300), HasRequiredAddress
FROM #SDAT;

SET @StageRows = (SELECT COUNT(*) FROM #Stage);

/* Placeholder parcels -> NULL */
UPDATE #Stage
SET ParcelID = NULL
WHERE ParcelID IS NOT NULL
  AND (
        REPLACE(ParcelID, N'0', N'') = N''
     OR UPPER(LTRIM(RTRIM(ParcelID))) IN (N'NULL', N'N/A', N'NA', N'NONE')
  );

/* Distinct building addresses per account.
   Counted on MA rows only: the Complex rule is "MA MultiFamily + Account# +
   2+ distinct building addresses". Counting SDAT premises addresses too would
   create false Complexes when SDAT spells the same address differently. */
IF OBJECT_ID('tempdb..#AcctAddrCnt') IS NOT NULL DROP TABLE #AcctAddrCnt;
SELECT
    AccountNumber,
    COUNT(DISTINCT NormalizedFullAddress) AS DistinctAddrCnt
INTO #AcctAddrCnt
FROM #Stage
WHERE AccountNumber IS NOT NULL
  AND SourceSystem = N'ADDRESS_MASTER'
  AND HasRequiredAddress = 1
  AND NULLIF(LTRIM(RTRIM(NormalizedFullAddress)), N'') IS NOT NULL
GROUP BY AccountNumber;

UPDATE s
SET s.DistinctAddrOnAccount = a.DistinctAddrCnt
FROM #Stage s
INNER JOIN #AcctAddrCnt a ON a.AccountNumber = s.AccountNumber;

/*
   IsValid for UPR write:
     - required address present
     - AccountNumber present, OR Condo path (PropertyType CONDO / CondoUnit)
   Missing ParcelID does NOT block load (still flagged to Review_Q).
*/
UPDATE #Stage
SET
    IsValid = CASE
        WHEN HasRequiredAddress = 0 THEN 0
        WHEN AccountNumber IS NOT NULL THEN 1
        WHEN PropertyType = N'CONDO' OR CondoUnit IS NOT NULL THEN 1
        ELSE 0
    END,
    ReviewReason = CASE
        WHEN HasRequiredAddress = 0 THEN N'NO_ADDRESS_MATCH'
        WHEN AccountNumber IS NULL
         AND ISNULL(PropertyType, N'') <> N'CONDO'
         AND CondoUnit IS NULL THEN N'INSUFFICIENT_DATA'
        WHEN ParcelID IS NULL THEN N'MISSING PARCELID'
        ELSE NULL
    END;

UPDATE s
SET
    PathType = CASE
        WHEN s.PropertyType = N'CONDO' OR s.CondoUnit IS NOT NULL THEN N'CONDO'
        WHEN s.PropertyType IN (N'MULTI', N'APT')
         AND s.AccountNumber IS NOT NULL
         AND ISNULL(s.DistinctAddrOnAccount, 0) > 1 THEN N'COMPLEX'
        ELSE N'PROPERTY'
    END,
    GroupKey = CASE
        WHEN s.PropertyType = N'CONDO' OR s.CondoUnit IS NOT NULL THEN
            N'CONDO|' + ISNULL(s.AccountNumber, N'NOACCT') + N'|' +
            CASE WHEN s.AccountNumber IS NULL THEN ISNULL(s.NormalizedFullAddress, N'') ELSE N'' END
        WHEN s.PropertyType IN (N'MULTI', N'APT')
         AND s.AccountNumber IS NOT NULL
         AND ISNULL(s.DistinctAddrOnAccount, 0) > 1 THEN
            N'COMPLEX|' + s.AccountNumber
        ELSE
            N'PROPERTY|' + ISNULL(s.AccountNumber, N'NOACCT') + N'|' + ISNULL(s.NormalizedFullAddress, N'')
    END
FROM #Stage s
WHERE s.IsValid = 1;

/* Working indexes - #Stage is joined on GroupKey many times below */
CREATE INDEX IX_Stage_GroupKey ON #Stage (GroupKey) WHERE IsValid = 1;
CREATE INDEX IX_Stage_Source ON #Stage (SourceSystem, SourceRecordID);

SET @ValidRows = (SELECT COUNT(*) FROM #Stage WHERE IsValid = 1);
SET @InvalidRows = (SELECT COUNT(*) FROM #Stage WHERE IsValid = 0);
PRINT N'Step 4 complete - Stage=' + CONVERT(NVARCHAR(20), @StageRows)
    + N'; Valid=' + CONVERT(NVARCHAR(20), @ValidRows)
    + N'; Invalid=' + CONVERT(NVARCHAR(20), @InvalidRows);

/* ============================================================================
   5. Review_Q for invalid / missing parcel (mapped reasons only)
   ============================================================================ */
PRINT N'Step 5: Write UPRMATCHREVIEW_Q for non-load / flagged rows...';

IF OBJECT_ID('tempdb..#ReviewSrc') IS NOT NULL DROP TABLE #ReviewSrc;
SELECT
    StageKey,
    SourceSystem,
    SourceRecordID,
    MasterAddressID,
    KdatRecordID,
    AccountNumber,
    ParcelID,
    NormalizedFullAddress,
    ReviewReason = CASE
        WHEN HasRequiredAddress = 0 THEN N'NO_ADDRESS_MATCH'
        WHEN AccountNumber IS NULL AND ISNULL(PropertyType, N'') <> N'CONDO' AND CondoUnit IS NULL THEN N'INSUFFICIENT_DATA'
        WHEN IsValid = 0 THEN ISNULL(ReviewReason, N'OTHER')
        WHEN ParcelID IS NULL THEN N'MISSING PARCELID'
        ELSE ISNULL(ReviewReason, N'OTHER')
    END,
    IsValid
INTO #ReviewSrc
FROM #Stage
WHERE IsValid = 0
   OR (IsValid = 1 AND ParcelID IS NULL);

/* Re-run dedupe below scans UPRMATCHREVIEW_Q per row - index it or the load crawls */
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.UPRMATCHREVIEW_Q')
      AND name = N'IX_UPRMATCHREVIEW_Q_Dedupe'
)
    CREATE INDEX IX_UPRMATCHREVIEW_Q_Dedupe
        ON dbo.UPRMATCHREVIEW_Q (IncomingSourceSystem, ReasonForNoMatch, MA_Account, SDAT_AccountNumber);

INSERT INTO dbo.UPRMATCHREVIEW_Q (
    UPRID,
    IncomingSourceSystem,
    SDAT_NormalizedIncomingAddress,
    MA_NormalizedIncomingAddress,
    SDAT_ParcelID,
    MA_ParcelID,
    SDAT_AccountNumber,
    MA_Account,
    ReasonForNoMatch,
    ProcessingTimestamp,
    ReviewStatus
)
SELECT
    NULL,
    r.SourceSystem,
    CASE WHEN r.SourceSystem = N'KDAT' THEN ISNULL(r.NormalizedFullAddress, N'') ELSE N'' END,
    CASE WHEN r.SourceSystem = N'ADDRESS_MASTER' THEN ISNULL(r.NormalizedFullAddress, N'') ELSE N'' END,
    CASE WHEN r.SourceSystem = N'KDAT' THEN r.ParcelID ELSE NULL END,
    CASE WHEN r.SourceSystem = N'ADDRESS_MASTER' THEN r.ParcelID ELSE NULL END,
    CASE WHEN r.SourceSystem = N'KDAT' THEN LEFT(r.AccountNumber, 30) ELSE NULL END,
    CASE WHEN r.SourceSystem = N'ADDRESS_MASTER' THEN LEFT(r.AccountNumber, 30) ELSE NULL END,
    CASE
        WHEN r.ReviewReason IN (
            N'MISSING PARCELID', N'NO_SDAT_MATCH', N'NO_ADDRESS_MATCH', N'INSUFFICIENT_DATA',
            N'AMBIGUOUS_CANDIDATES', N'LOW_CONFIDENCE_ONLY', N'SOURCE_RECORD_ERROR', N'OTHER'
        ) THEN r.ReviewReason
        ELSE N'OTHER'
    END,
    @Now,
    N'PENDING_REVIEW'
FROM #ReviewSrc r
WHERE NOT EXISTS (
    SELECT 1
    FROM dbo.UPRMATCHREVIEW_Q q
    WHERE q.IncomingSourceSystem = r.SourceSystem
      AND q.ReasonForNoMatch = CASE
            WHEN r.ReviewReason IN (
                N'MISSING PARCELID', N'NO_SDAT_MATCH', N'NO_ADDRESS_MATCH', N'INSUFFICIENT_DATA',
                N'AMBIGUOUS_CANDIDATES', N'LOW_CONFIDENCE_ONLY', N'SOURCE_RECORD_ERROR', N'OTHER'
            ) THEN r.ReviewReason
            ELSE N'OTHER'
        END
      AND ISNULL(q.MA_Account, N'') = ISNULL(CASE WHEN r.SourceSystem = N'ADDRESS_MASTER' THEN LEFT(r.AccountNumber, 30) END, N'')
      AND ISNULL(q.SDAT_AccountNumber, N'') = ISNULL(CASE WHEN r.SourceSystem = N'KDAT' THEN LEFT(r.AccountNumber, 30) END, N'')
      AND ISNULL(q.MA_NormalizedIncomingAddress, N'') = ISNULL(CASE WHEN r.SourceSystem = N'ADDRESS_MASTER' THEN r.NormalizedFullAddress END, N'')
      AND ISNULL(q.SDAT_NormalizedIncomingAddress, N'') = ISNULL(CASE WHEN r.SourceSystem = N'KDAT' THEN r.NormalizedFullAddress END, N'')
);

SET @ReviewInserted = @@ROWCOUNT;
PRINT N'Step 5 complete - Review_Q rows inserted: ' + CONVERT(NVARCHAR(20), @ReviewInserted);

/* ============================================================================
   6. #ParentGroup - one row per GroupKey among valid staged rows
   ============================================================================ */
PRINT N'Step 6: Build parent groups...';

IF OBJECT_ID('tempdb..#ParentGroup') IS NOT NULL DROP TABLE #ParentGroup;

SELECT
    s.GroupKey,
    s.PathType,
    AccountNumber = MAX(s.AccountNumber),
    PropertyType  = COALESCE(
        MAX(CASE WHEN s.PropertyType = N'MULTI' THEN s.PropertyType END),
        MAX(CASE WHEN s.PropertyType = N'CONDO' THEN s.PropertyType END),
        MAX(s.PropertyType),
        /* Nothing usable in the incoming record type - never invent SF */
        CASE s.PathType WHEN N'CONDO' THEN N'CONDO' WHEN N'COMPLEX' THEN N'MULTI' ELSE N'UNKNWN' END
    ),
    OwnerName = MAX(s.OwnerName),
    /* Complex has no name in MA/SDAT - business label from city, per client */
    CommunityName = CASE WHEN s.PathType = N'COMPLEX' THEN
        LEFT(COALESCE(MAX(s.City) + N' BUILDING COMPLEX',
                      MAX(s.AccountNumber) + N' BUILDING COMPLEX',
                      N'BUILDING COMPLEX'), 200) END,
    ParcelID = MAX(s.ParcelID),
    EntityTypeID = CASE s.PathType
        WHEN N'COMPLEX' THEN @EtComplex
        WHEN N'CONDO' THEN @EtCondo
        ELSE @EtProperty
    END
INTO #ParentGroup
FROM #Stage s
WHERE s.IsValid = 1
  AND s.GroupKey IS NOT NULL
GROUP BY s.GroupKey, s.PathType;

/* Skip parents already present (re-run guard): same Account + EntityType for COMPLEX/CONDO;
   PROPERTY: same Account + already linked source XREF for any stage row in group */
IF OBJECT_ID('tempdb..#ParentSkip') IS NOT NULL DROP TABLE #ParentSkip;
CREATE TABLE #ParentSkip (GroupKey NVARCHAR(450) NOT NULL PRIMARY KEY, ExistingUPRID BIGINT NOT NULL);

INSERT INTO #ParentSkip (GroupKey, ExistingUPRID)
SELECT g.GroupKey, MIN(u.UPRID)
FROM #ParentGroup g
INNER JOIN dbo.UPR u
    ON u.EntityTypeID = g.EntityTypeID
   AND u.AccountNumber = g.AccountNumber
   AND g.AccountNumber IS NOT NULL
   AND g.PathType IN (N'COMPLEX', N'CONDO')
GROUP BY g.GroupKey;

INSERT INTO #ParentSkip (GroupKey, ExistingUPRID)
SELECT g.GroupKey, MIN(anc.UPRID)
FROM #ParentGroup g
INNER JOIN #Stage s ON s.GroupKey = g.GroupKey AND s.IsValid = 1
INNER JOIN dbo.EXTERNAL_IDENTIFIER_XREF x
    ON x.SourceSystem = s.SourceSystem
   AND x.IdentifierType = N'SOURCE_RECORD_ID'
   AND x.IdentifierValue = s.SourceRecordID
/* The source row is linked to its Unit UPR when a unit was created for it, so
   walk up the closure to the Property parent instead of matching x.UPRID.
   The closure contains self rows, which covers rows linked to the parent. */
INNER JOIN dbo.UPR_CLOSURE cl ON cl.DescendantUPRID = x.UPRID
INNER JOIN dbo.UPR anc ON anc.UPRID = cl.AncestorUPRID AND anc.EntityTypeID = g.EntityTypeID
WHERE g.PathType = N'PROPERTY'
  AND NOT EXISTS (SELECT 1 FROM #ParentSkip p WHERE p.GroupKey = g.GroupKey)
GROUP BY g.GroupKey;

SET @ComplexGroups  = (SELECT COUNT(*) FROM #ParentGroup WHERE PathType = N'COMPLEX');
SET @PropertyGroups = (SELECT COUNT(*) FROM #ParentGroup WHERE PathType = N'PROPERTY');
SET @CondoGroups    = (SELECT COUNT(*) FROM #ParentGroup WHERE PathType = N'CONDO');
SET @ParentSkipped  = (SELECT COUNT(*) FROM #ParentSkip);
PRINT N'Step 6 complete - Groups COMPLEX=' + CONVERT(NVARCHAR(20), @ComplexGroups)
    + N' PROPERTY=' + CONVERT(NVARCHAR(20), @PropertyGroups)
    + N' CONDO=' + CONVERT(NVARCHAR(20), @CondoGroups)
    + N' skip-existing=' + CONVERT(NVARCHAR(20), @ParentSkipped);

/* ============================================================================
   7. INSERT parent UPRs + entity tables
   ============================================================================ */
PRINT N'Step 7: Insert parent UPR + COMPLEX/PROPERTY/CONDO...';

IF OBJECT_ID('tempdb..#ParentMap') IS NOT NULL DROP TABLE #ParentMap;
CREATE TABLE #ParentMap (
    GroupKey NVARCHAR(450) NOT NULL PRIMARY KEY,
    UPRID BIGINT NOT NULL,
    PathType VARCHAR(20) NOT NULL,
    AccountNumber VARCHAR(50) NULL,
    PropertyType NVARCHAR(6) NULL,
    OwnerName NVARCHAR(200) NULL,
    CommunityName VARCHAR(200) NULL,
    ParcelID NVARCHAR(50) NULL
);

/* Reuse existing parents */
INSERT INTO #ParentMap (GroupKey, UPRID, PathType, AccountNumber, PropertyType, OwnerName, CommunityName, ParcelID)
SELECT g.GroupKey, p.ExistingUPRID, g.PathType, g.AccountNumber, g.PropertyType, g.OwnerName, g.CommunityName, g.ParcelID
FROM #ParentGroup g
INNER JOIN #ParentSkip p ON p.GroupKey = g.GroupKey;

/* New parents via MERGE...OUTPUT (source columns available) */
MERGE dbo.UPR AS t
USING (
    SELECT g.*
    FROM #ParentGroup g
    WHERE NOT EXISTS (SELECT 1 FROM #ParentSkip p WHERE p.GroupKey = g.GroupKey)
) AS s
ON 1 = 0
WHEN NOT MATCHED THEN
    INSERT (ParentUPRID, EntityTypeID, AccountNumber, StatusCode, CreatedBy)
    VALUES (NULL, s.EntityTypeID, s.AccountNumber, N'ACTIVE', @RunUser)
OUTPUT
    s.GroupKey,
    inserted.UPRID,
    s.PathType,
    s.AccountNumber,
    s.PropertyType,
    s.OwnerName,
    s.CommunityName,
    s.ParcelID
INTO #ParentMap (GroupKey, UPRID, PathType, AccountNumber, PropertyType, OwnerName, CommunityName, ParcelID);

SET @ParentInserted = (
    SELECT COUNT(*) FROM #ParentMap pm
    WHERE NOT EXISTS (SELECT 1 FROM #ParentSkip ps WHERE ps.GroupKey = pm.GroupKey)
);

INSERT INTO dbo.COMPLEX (UPRID, CommunityName, PropertyTypeID, StatusCode, CreatedBy)
SELECT
    pm.UPRID,
    pm.CommunityName,
    pt.PropertyTypeID,
    N'ACTIVE',
    @RunUser
FROM #ParentMap pm
LEFT JOIN dbo.REF_PROPERTYTYPE pt ON pt.PropertyTypeCode = ISNULL(pm.PropertyType, N'MULTI')
WHERE pm.PathType = N'COMPLEX'
  AND NOT EXISTS (SELECT 1 FROM dbo.COMPLEX c WHERE c.UPRID = pm.UPRID);
SET @ComplexInserted = @@ROWCOUNT;

INSERT INTO dbo.PROPERTY (UPRID, PropertyTypeID, PropertyName, OwnerName, Parcel, StatusCode)
SELECT
    pm.UPRID,
    COALESCE(pt.PropertyTypeID, (SELECT TOP 1 PropertyTypeID FROM dbo.REF_PROPERTYTYPE WHERE PropertyTypeCode = N'UNKNWN')),
    NULL,   /* MA/SDAT carry no property name - address lives in ADDRESS, owner in OwnerName */
    pm.OwnerName,
    LEFT(pm.ParcelID, 20),
    N'ACTIVE'
FROM #ParentMap pm
LEFT JOIN dbo.REF_PROPERTYTYPE pt ON pt.PropertyTypeCode = ISNULL(pm.PropertyType, N'UNKNWN')
WHERE pm.PathType = N'PROPERTY'
  AND NOT EXISTS (SELECT 1 FROM dbo.PROPERTY p WHERE p.UPRID = pm.UPRID);
SET @PropertyInserted = @@ROWCOUNT;

INSERT INTO dbo.CONDO (UPRID, CondoName, OwnerName, Parcel, StatusCode)
SELECT
    pm.UPRID,
    NULL,   /* SDAT carries no condo name */
    pm.OwnerName,
    LEFT(pm.ParcelID, 20),
    N'ACTIVE'
FROM #ParentMap pm
WHERE pm.PathType = N'CONDO'
  AND NOT EXISTS (SELECT 1 FROM dbo.CONDO c WHERE c.UPRID = pm.UPRID);
SET @CondoInserted = @@ROWCOUNT;

PRINT N'Step 7 complete - new parents=' + CONVERT(NVARCHAR(20), @ParentInserted)
    + N' COMPLEX=' + CONVERT(NVARCHAR(20), @ComplexInserted)
    + N' PROPERTY=' + CONVERT(NVARCHAR(20), @PropertyInserted)
    + N' CONDO=' + CONVERT(NVARCHAR(20), @CondoInserted);

/* ============================================================================
   8. Buildings (distinct address per group) + ADDRESS + UPR_ADDRESS
   ============================================================================ */
PRINT N'Step 8: Insert Building UPRs, BUILDING, ADDRESS, UPR_ADDRESS...';

IF OBJECT_ID('tempdb..#BuildingSrc') IS NOT NULL DROP TABLE #BuildingSrc;
SELECT
    /* Surrogate key - a text key of GroupKey+address can exceed the 900-byte
       index limit, so number the rows instead */
    BuildingKey = ROW_NUMBER() OVER (ORDER BY pm.UPRID, s.NormalizedFullAddress),
    s.GroupKey,
    ParentUPRID = pm.UPRID,
    PathType = pm.PathType,
    s.NormalizedFullAddress,
    /* Building A, Building B, ... within each parent (client rule: no source name) */
    BuildingSeq = ROW_NUMBER() OVER (PARTITION BY pm.UPRID ORDER BY s.NormalizedFullAddress),
    StreetNumber = MAX(s.StreetNumber),
    StreetName   = MAX(s.StreetName),
    StreetType   = MAX(s.StreetType),
    City         = MAX(s.City),
    [State]      = MAX(s.[State]),
    ZipCode      = MAX(s.ZipCode),
    YCoordinate  = MAX(s.YCoordinate),
    XCoordinate  = MAX(s.XCoordinate),
    /* CK_BUILDING_YearBuilt allows 1600..next year - sources carry 0 / 9999,
       so anything outside the range is stored as NULL instead of failing */
    YearBuilt    = MAX(CASE WHEN s.YearBuilt BETWEEN 1600 AND YEAR(DATEADD(YEAR, 1, SYSDATETIME()))
                            THEN s.YearBuilt END)
INTO #BuildingSrc
FROM #Stage s
INNER JOIN #ParentMap pm ON pm.GroupKey = s.GroupKey
WHERE s.IsValid = 1
  AND NULLIF(LTRIM(RTRIM(s.NormalizedFullAddress)), N'') IS NOT NULL
GROUP BY s.GroupKey, pm.UPRID, pm.PathType, s.NormalizedFullAddress;

IF OBJECT_ID('tempdb..#BuildingMap') IS NOT NULL DROP TABLE #BuildingMap;
CREATE TABLE #BuildingMap (
    BuildingKey BIGINT NOT NULL PRIMARY KEY,
    GroupKey NVARCHAR(450) NOT NULL,
    BuildingUPRID BIGINT NOT NULL,
    NormalizedFullAddress NVARCHAR(300) NULL,
    PathType VARCHAR(20) NOT NULL
);

/* Skip buildings already under parent with same normalized address.
   MIN() keeps one row per BuildingKey if an earlier run left duplicates. */
INSERT INTO #BuildingMap (BuildingKey, GroupKey, BuildingUPRID, NormalizedFullAddress, PathType)
SELECT b.BuildingKey, MIN(b.GroupKey), MIN(ua.UPRID), MIN(b.NormalizedFullAddress), MIN(b.PathType)
FROM #BuildingSrc b
INNER JOIN dbo.UPR u ON u.ParentUPRID = b.ParentUPRID AND u.EntityTypeID = @EtBuilding
INNER JOIN dbo.UPR_ADDRESS ua ON ua.UPRID = u.UPRID AND ua.IsPrimary = 1
INNER JOIN dbo.ADDRESS a ON a.AddressID = ua.AddressID AND a.NormalizedAddress = b.NormalizedFullAddress
GROUP BY b.BuildingKey;

MERGE dbo.UPR AS t
USING (
    SELECT b.*
    FROM #BuildingSrc b
    WHERE NOT EXISTS (SELECT 1 FROM #BuildingMap m WHERE m.BuildingKey = b.BuildingKey)
) AS s
ON 1 = 0
WHEN NOT MATCHED THEN
    INSERT (ParentUPRID, EntityTypeID, AccountNumber, StatusCode, CreatedBy)
    VALUES (s.ParentUPRID, @EtBuilding, NULL, N'ACTIVE', @RunUser)
OUTPUT s.BuildingKey, s.GroupKey, inserted.UPRID, s.NormalizedFullAddress, s.PathType
INTO #BuildingMap (BuildingKey, GroupKey, BuildingUPRID, NormalizedFullAddress, PathType);

SET @BuildingInserted = @@ROWCOUNT;

INSERT INTO dbo.BUILDING (UPRID, BuildingName, YearBuilt, StatusCode)
SELECT
    bm.BuildingUPRID,
    /* Building A .. Building Z, then Building 27, Building 28, ... */
    CASE WHEN b.BuildingSeq <= 26
         THEN N'Building ' + CHAR(64 + CONVERT(INT, b.BuildingSeq))
         ELSE N'Building ' + CONVERT(NVARCHAR(20), b.BuildingSeq)
    END,
    b.YearBuilt,
    N'ACTIVE'
FROM #BuildingMap bm
INNER JOIN #BuildingSrc b ON b.BuildingKey = bm.BuildingKey
WHERE NOT EXISTS (SELECT 1 FROM dbo.BUILDING x WHERE x.UPRID = bm.BuildingUPRID);

CREATE INDEX IX_BuildingMap_Lookup ON #BuildingMap (GroupKey, NormalizedFullAddress);

/* ADDRESS rows for building keys not yet linked */
IF OBJECT_ID('tempdb..#AddressSrc') IS NOT NULL DROP TABLE #AddressSrc;
SELECT
    AddressKey = b.BuildingKey,
    b.StreetNumber,
    b.StreetName,
    b.StreetType,
    b.City,
    [State] = b.[State],
    b.ZipCode,
    NormalizedAddress = b.NormalizedFullAddress,
    b.YCoordinate,
    b.XCoordinate
INTO #AddressSrc
FROM #BuildingSrc b
WHERE NOT EXISTS (
    SELECT 1
    FROM dbo.UPR_ADDRESS ua
    INNER JOIN dbo.ADDRESS a ON a.AddressID = ua.AddressID
    INNER JOIN #BuildingMap bm ON bm.BuildingUPRID = ua.UPRID
    WHERE bm.BuildingKey = b.BuildingKey
);

IF OBJECT_ID('tempdb..#AddressMap') IS NOT NULL DROP TABLE #AddressMap;
CREATE TABLE #AddressMap (
    AddressKey BIGINT NOT NULL PRIMARY KEY,
    AddressID BIGINT NOT NULL
);

MERGE dbo.ADDRESS AS t
USING #AddressSrc AS s
ON 1 = 0
WHEN NOT MATCHED THEN
    INSERT (StreetNumber, StreetName, StreetType, City, State, ZipCode, NormalizedAddress, YCoordinate, XCoordinate)
    VALUES (
        s.StreetNumber, s.StreetName, s.StreetType, s.City, s.[State], s.ZipCode,
        s.NormalizedAddress, s.YCoordinate, s.XCoordinate
    )
OUTPUT s.AddressKey, inserted.AddressID INTO #AddressMap (AddressKey, AddressID);

SET @AddressInserted = @@ROWCOUNT;

INSERT INTO dbo.UPR_ADDRESS (UPRID, AddressID, AddressRoleID, IsPrimary, EffectiveDate)
SELECT
    bm.BuildingUPRID,
    am.AddressID,
    @AddrPhysical,
    1,
    CONVERT(DATE, @Now)
FROM #AddressMap am
INNER JOIN #BuildingMap bm ON bm.BuildingKey = am.AddressKey
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.UPR_ADDRESS ua WHERE ua.UPRID = bm.BuildingUPRID AND ua.IsPrimary = 1
);

PRINT N'Step 8 complete - Building UPRs this run~' + CONVERT(NVARCHAR(20), @BuildingInserted)
    + N'; ADDRESS inserted=' + CONVERT(NVARCHAR(20), @AddressInserted);

/* ============================================================================
   9. Units
      PROPERTY/COMPLEX: Unit child of Building (ParentUPRID=Building)
      CONDO: Unit child of Condo (ParentUPRID=Condo); BuildingID still required
   ============================================================================ */
PRINT N'Step 9: Insert Unit UPRs + UNIT...';

IF OBJECT_ID('tempdb..#UnitSrc') IS NOT NULL DROP TABLE #UnitSrc;

;WITH UnitBase AS (
    SELECT
        s.StageKey,
        s.GroupKey,
        s.PathType,
        s.SourceSystem,
        s.SourceRecordID,
        s.NormalizedFullAddress,
        UnitNumber = COALESCE(
            NULLIF(LTRIM(RTRIM(s.CondoUnit)), N''),
            NULLIF(LTRIM(RTRIM(s.UnitNumber)), N''),
            CASE
                WHEN s.PathType IN (N'COMPLEX', N'CONDO')
                  OR s.PropertyType IN (N'MULTI', N'APT', N'CONDO')
                THEN CASE
                    WHEN s.SourceSystem = N'ADDRESS_MASTER'
                        THEN N'MA-' + CONVERT(VARCHAR(50), s.MasterAddressID)
                    ELSE N'SD-' + CONVERT(VARCHAR(50), ISNULL(s.KdatRecordID, 0))
                END
                ELSE NULL
            END
        ),
        NeedsUnit = CASE
            WHEN s.PathType = N'CONDO' THEN 1
            WHEN NULLIF(LTRIM(RTRIM(s.CondoUnit)), N'') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(s.UnitNumber)), N'') IS NOT NULL THEN 1
            WHEN s.PathType = N'COMPLEX' THEN 1
            WHEN s.PropertyType IN (N'MULTI', N'APT', N'CONDO') THEN 1
            ELSE 0
        END
    FROM #Stage s
    WHERE s.IsValid = 1
),
UnitJoined AS (
    SELECT
        ub.StageKey,
        ub.GroupKey,
        ub.PathType,
        ub.NormalizedFullAddress,
        ub.UnitNumber,
        ParentUPRID = CASE
            WHEN ub.PathType = N'CONDO' THEN pm.UPRID
            ELSE bm.BuildingUPRID
        END,
        BuildingUPRID = bm.BuildingUPRID,
        BuildingTableID = CAST(NULL AS BIGINT),
        Rn = ROW_NUMBER() OVER (
            PARTITION BY ub.GroupKey, ub.NormalizedFullAddress, ub.UnitNumber
            ORDER BY
                CASE ub.SourceSystem WHEN N'KDAT' THEN 0 ELSE 1 END,
                ub.StageKey
        )
    FROM UnitBase ub
    INNER JOIN #ParentMap pm ON pm.GroupKey = ub.GroupKey
    INNER JOIN #BuildingMap bm
        ON bm.GroupKey = ub.GroupKey
       AND bm.NormalizedFullAddress = ub.NormalizedFullAddress
    WHERE ub.NeedsUnit = 1
      AND ub.UnitNumber IS NOT NULL
)
SELECT
    StageKey, GroupKey, PathType, NormalizedFullAddress, UnitNumber,
    ParentUPRID, BuildingUPRID, BuildingTableID
INTO #UnitSrc
FROM UnitJoined
WHERE Rn = 1;

CREATE UNIQUE INDEX UX_UnitSrc_StageKey ON #UnitSrc (StageKey);
CREATE INDEX IX_UnitSrc_Lookup ON #UnitSrc (GroupKey, NormalizedFullAddress, UnitNumber);

UPDATE us
SET BuildingTableID = b.BuildingID
FROM #UnitSrc us
INNER JOIN dbo.BUILDING b ON b.UPRID = us.BuildingUPRID;

DELETE FROM #UnitSrc WHERE BuildingTableID IS NULL OR ParentUPRID IS NULL;

IF OBJECT_ID('tempdb..#UnitMap') IS NOT NULL DROP TABLE #UnitMap;
CREATE TABLE #UnitMap (
    StageKey INT NOT NULL PRIMARY KEY,
    UnitUPRID BIGINT NOT NULL,
    GroupKey NVARCHAR(450) NOT NULL
);

MERGE dbo.UPR AS t
USING (
    SELECT u.*
    FROM #UnitSrc u
    WHERE NOT EXISTS (
        SELECT 1
        FROM dbo.EXTERNAL_IDENTIFIER_XREF x
        INNER JOIN #Stage s ON s.StageKey = u.StageKey
        WHERE x.SourceSystem = s.SourceSystem
          AND x.IdentifierType = N'SOURCE_RECORD_ID'
          AND x.IdentifierValue = s.SourceRecordID
          AND EXISTS (
              SELECT 1 FROM dbo.UPR uu
              WHERE uu.UPRID = x.UPRID AND uu.EntityTypeID = @EtUnit
          )
    )
) AS s
ON 1 = 0
WHEN NOT MATCHED THEN
    INSERT (ParentUPRID, EntityTypeID, AccountNumber, StatusCode, CreatedBy)
    VALUES (s.ParentUPRID, @EtUnit, NULL, N'ACTIVE', @RunUser)
OUTPUT s.StageKey, inserted.UPRID, s.GroupKey
INTO #UnitMap (StageKey, UnitUPRID, GroupKey);

INSERT INTO dbo.UNIT (UPRID, BuildingID, UnitNumber, StatusCode)
SELECT
    um.UnitUPRID,
    us.BuildingTableID,
    LEFT(us.UnitNumber, 50),
    N'ACTIVE'
FROM #UnitMap um
INNER JOIN #UnitSrc us ON us.StageKey = um.StageKey
WHERE NOT EXISTS (SELECT 1 FROM dbo.UNIT x WHERE x.UPRID = um.UnitUPRID);

SET @UnitInserted = @@ROWCOUNT;
PRINT N'Step 9 complete - UNIT rows inserted: ' + CONVERT(NVARCHAR(20), @UnitInserted);

/* ============================================================================
   10. CONTACT + UPR_CONTACT on parent (required when address present)
   ============================================================================ */
PRINT N'Step 10: CONTACT + UPR_CONTACT on parent UPRs...';

IF OBJECT_ID('tempdb..#ContactSrc') IS NOT NULL DROP TABLE #ContactSrc;
SELECT
    pm.GroupKey,
    pm.UPRID AS ParentUPRID,
    /* Owner name, else the Account# so the row is traceable, else NULL
       (client: owner/organization name may be NULL when not supplied) */
    OrgName = CONVERT(VARCHAR(200),
        COALESCE(
            NULLIF(LTRIM(RTRIM(pm.OwnerName)), N''),
            NULLIF(LTRIM(RTRIM(pm.AccountNumber)), N'')
        ))
INTO #ContactSrc
FROM #ParentMap pm
WHERE EXISTS (
    SELECT 1 FROM #Stage s
    WHERE s.GroupKey = pm.GroupKey AND s.IsValid = 1 AND s.HasRequiredAddress = 1
);

IF OBJECT_ID('tempdb..#ContactMap') IS NOT NULL DROP TABLE #ContactMap;
CREATE TABLE #ContactMap (
    GroupKey NVARCHAR(450) NOT NULL PRIMARY KEY,
    ContactID BIGINT NOT NULL,
    ParentUPRID BIGINT NOT NULL
);

MERGE dbo.CONTACT AS t
USING (
    SELECT c.*
    FROM #ContactSrc c
    WHERE NOT EXISTS (
        SELECT 1 FROM dbo.UPR_CONTACT uc
        WHERE uc.UPRID = c.ParentUPRID AND uc.RoleTypeID = @RoleOwner
    )
) AS s
ON 1 = 0
WHEN NOT MATCHED THEN
    INSERT (ContactTypeID, OrganizationName, StatusCode)
    VALUES (@CtOrg, s.OrgName, N'ACTIVE')
OUTPUT s.GroupKey, inserted.ContactID, s.ParentUPRID
INTO #ContactMap (GroupKey, ContactID, ParentUPRID);

SET @ContactInserted = @@ROWCOUNT;

INSERT INTO dbo.UPR_CONTACT (UPRID, ContactID, RoleTypeID, EffectiveDate)
SELECT
    cm.ParentUPRID,
    cm.ContactID,
    @RoleOwner,
    CONVERT(DATE, @Now)
FROM #ContactMap cm
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.UPR_CONTACT uc
    WHERE uc.UPRID = cm.ParentUPRID
      AND uc.ContactID = cm.ContactID
      AND uc.RoleTypeID = @RoleOwner
);
SET @UPRContactInserted = @@ROWCOUNT;
PRINT N'Step 10 complete - CONTACT=' + CONVERT(NVARCHAR(20), @ContactInserted)
    + N' UPR_CONTACT=' + CONVERT(NVARCHAR(20), @UPRContactInserted);

/* ============================================================================
   11. EXTERNAL_IDENTIFIER_XREF (MA / SDAT source record IDs)
       Link to Unit UPR when unit created for that stage row; else parent UPR
   ============================================================================ */
PRINT N'Step 11: EXTERNAL_IDENTIFIER_XREF...';

IF OBJECT_ID('tempdb..#XrefSrc') IS NOT NULL DROP TABLE #XrefSrc;

;WITH StageUnit AS (
    SELECT
        s.StageKey,
        s.SourceSystem,
        s.SourceRecordID,
        s.GroupKey,
        s.AccountNumber,
        UnitNumber = COALESCE(
            NULLIF(LTRIM(RTRIM(s.CondoUnit)), N''),
            NULLIF(LTRIM(RTRIM(s.UnitNumber)), N''),
            CASE
                WHEN s.PathType IN (N'COMPLEX', N'CONDO')
                  OR s.PropertyType IN (N'MULTI', N'APT', N'CONDO')
                THEN CASE
                    WHEN s.SourceSystem = N'ADDRESS_MASTER'
                        THEN N'MA-' + CONVERT(VARCHAR(50), s.MasterAddressID)
                    ELSE N'SD-' + CONVERT(VARCHAR(50), ISNULL(s.KdatRecordID, 0))
                END
                ELSE NULL
            END
        ),
        s.NormalizedFullAddress
    FROM #Stage s
    WHERE s.IsValid = 1
)
SELECT
    su.StageKey,
    su.SourceSystem,
    su.SourceRecordID,
    su.AccountNumber,
    TargetUPRID = COALESCE(um.UnitUPRID, pm.UPRID)
INTO #XrefSrc
FROM StageUnit su
INNER JOIN #ParentMap pm ON pm.GroupKey = su.GroupKey
LEFT JOIN #UnitSrc us
    ON us.GroupKey = su.GroupKey
   AND us.NormalizedFullAddress = su.NormalizedFullAddress
   AND us.UnitNumber = su.UnitNumber
LEFT JOIN #UnitMap um ON um.StageKey = us.StageKey;

INSERT INTO dbo.EXTERNAL_IDENTIFIER_XREF (
    UPRID, SourceSystem, IdentifierType, IdentifierValue
)
/* MIN() guards the one-row-per-source-record index if the incoming table
   was loaded with duplicate source IDs */
SELECT
    MIN(x.TargetUPRID),
    x.SourceSystem,
    N'SOURCE_RECORD_ID',
    x.SourceRecordID
FROM #XrefSrc x
WHERE x.TargetUPRID IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM dbo.EXTERNAL_IDENTIFIER_XREF e
    WHERE e.SourceSystem = x.SourceSystem
      AND e.IdentifierType = N'SOURCE_RECORD_ID'
      AND e.IdentifierValue = x.SourceRecordID
)
GROUP BY x.SourceSystem, x.SourceRecordID;
SET @XrefInserted = @@ROWCOUNT;

/* Also store AccountNumber identifiers on parent when present.
   One Account# can legitimately sit on several parents (client: AccountNumber
   is not unique), so every distinct account-to-parent link is kept. */
INSERT INTO dbo.EXTERNAL_IDENTIFIER_XREF (
    UPRID, SourceSystem, IdentifierType, IdentifierValue
)
SELECT DISTINCT
    pm.UPRID,
    CASE WHEN s.SourceSystem = N'KDAT' THEN N'KDAT' ELSE N'ADDRESS_MASTER' END,
    N'ACCOUNT_NUMBER',
    s.AccountNumber
FROM #Stage s
INNER JOIN #ParentMap pm ON pm.GroupKey = s.GroupKey
WHERE s.IsValid = 1
  AND s.AccountNumber IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM dbo.EXTERNAL_IDENTIFIER_XREF e
      WHERE e.UPRID = pm.UPRID
        AND e.SourceSystem = CASE WHEN s.SourceSystem = N'KDAT' THEN N'KDAT' ELSE N'ADDRESS_MASTER' END
        AND e.IdentifierType = N'ACCOUNT_NUMBER'
        AND e.IdentifierValue = s.AccountNumber
  );
SET @XrefInserted = @XrefInserted + @@ROWCOUNT;

PRINT N'Step 11 complete - XREF inserted: ' + CONVERT(NVARCHAR(20), @XrefInserted);

/* ============================================================================
   12. Rebuild UPR_CLOSURE from ParentUPRID
   ============================================================================ */
PRINT N'Step 12: Rebuild UPR_CLOSURE...';

DELETE FROM dbo.UPR_CLOSURE;

INSERT INTO dbo.UPR_CLOSURE (AncestorUPRID, DescendantUPRID)
SELECT u.UPRID, u.UPRID
FROM dbo.UPR u;

DECLARE @ClosureAdded INT = 1;
WHILE @ClosureAdded > 0
BEGIN
    INSERT INTO dbo.UPR_CLOSURE (AncestorUPRID, DescendantUPRID)
    SELECT c.AncestorUPRID, child.UPRID
    FROM dbo.UPR_CLOSURE c
    INNER JOIN dbo.UPR child ON child.ParentUPRID = c.DescendantUPRID
    WHERE NOT EXISTS (
        SELECT 1 FROM dbo.UPR_CLOSURE x
        WHERE x.AncestorUPRID = c.AncestorUPRID
          AND x.DescendantUPRID = child.UPRID
    );
    SET @ClosureAdded = @@ROWCOUNT;
END;

SET @ClosureRows = (SELECT COUNT(*) FROM dbo.UPR_CLOSURE);
PRINT N'Step 12 complete - UPR_CLOSURE rows: ' + CONVERT(NVARCHAR(20), @ClosureRows);

/* ============================================================================
   13. UPRSTATUSHISTORY for new parent UPRs
   ============================================================================ */
PRINT N'Step 13: UPRSTATUSHISTORY for new parents...';

INSERT INTO dbo.UPRSTATUSHISTORY (
    UPRID, SDATAccountNumber, OldStatusCode, NewStatusCode, ChangeReason,
    ParcelID, Owner, PropertyTypeCode, ChangeSource, ChangedBy, ChangedDate, Notes
)
SELECT
    pm.UPRID,
    pm.AccountNumber,
    NULL,
    N'ACTIVE',
    N'Initial hierarchical load',
    pm.ParcelID,
    LEFT(pm.OwnerName, 100),
    pm.PropertyType,
    N'HIER_LOAD',
    @RunUser,
    @Now,
    N'Parent UPR created PathType=' + pm.PathType
FROM #ParentMap pm
WHERE NOT EXISTS (SELECT 1 FROM #ParentSkip ps WHERE ps.GroupKey = pm.GroupKey)
  AND NOT EXISTS (
      SELECT 1 FROM dbo.UPRSTATUSHISTORY h
      WHERE h.UPRID = pm.UPRID AND h.NewStatusCode = N'ACTIVE' AND h.ChangeSource = N'HIER_LOAD'
  );
SET @StatusHistInserted = @@ROWCOUNT;
PRINT N'Step 13 complete - status history: ' + CONVERT(NVARCHAR(20), @StatusHistInserted);

/* ============================================================================
   14. AuditLog summary counts
   ============================================================================ */
PRINT N'Step 14: AuditLog...';

INSERT INTO dbo.AuditLog (EntityName, EntityKey, OperationType, ChangedBy, ChangedDate, ChangeSummary)
VALUES
    (N'UPR_HIER_LOAD', N'BATCH', N'INSERT', @AuditUser, @Now,
     N'Parents=' + CONVERT(NVARCHAR(20), @ParentInserted)
     + N'; Complex=' + CONVERT(NVARCHAR(20), @ComplexInserted)
     + N'; Property=' + CONVERT(NVARCHAR(20), @PropertyInserted)
     + N'; Condo=' + CONVERT(NVARCHAR(20), @CondoInserted)
     + N'; Building~' + CONVERT(NVARCHAR(20), @BuildingInserted)
     + N'; Unit=' + CONVERT(NVARCHAR(20), @UnitInserted)
     + N'; Address=' + CONVERT(NVARCHAR(20), @AddressInserted)
     + N'; Contact=' + CONVERT(NVARCHAR(20), @ContactInserted)
     + N'; XREF=' + CONVERT(NVARCHAR(20), @XrefInserted)
     + N'; ReviewQ=' + CONVERT(NVARCHAR(20), @ReviewInserted)
     + N'; Closure=' + CONVERT(NVARCHAR(20), @ClosureRows));
SET @AuditInserted = @@ROWCOUNT;

COMMIT TRANSACTION;

PRINT N'================================================================';
PRINT N'UPR hierarchical load COMPLETE';
PRINT N'----------------------------------------------------------------';
PRINT N'MA rows read                 : ' + CONVERT(NVARCHAR(20), @MARead);
PRINT N'SDAT rows read               : ' + CONVERT(NVARCHAR(20), @SDATRead);
PRINT N'Stage rows                   : ' + CONVERT(NVARCHAR(20), @StageRows);
PRINT N'Valid loadable rows          : ' + CONVERT(NVARCHAR(20), @ValidRows);
PRINT N'Invalid rows                 : ' + CONVERT(NVARCHAR(20), @InvalidRows);
PRINT N'Review_Q inserted            : ' + CONVERT(NVARCHAR(20), @ReviewInserted);
PRINT N'Parent groups COMPLEX/PROP/CONDO: '
    + CONVERT(NVARCHAR(20), @ComplexGroups) + N' / '
    + CONVERT(NVARCHAR(20), @PropertyGroups) + N' / '
    + CONVERT(NVARCHAR(20), @CondoGroups);
PRINT N'New parent UPRs              : ' + CONVERT(NVARCHAR(20), @ParentInserted);
PRINT N'COMPLEX / PROPERTY / CONDO   : '
    + CONVERT(NVARCHAR(20), @ComplexInserted) + N' / '
    + CONVERT(NVARCHAR(20), @PropertyInserted) + N' / '
    + CONVERT(NVARCHAR(20), @CondoInserted);
PRINT N'Building UPRs (new this run) : ' + CONVERT(NVARCHAR(20), @BuildingInserted);
PRINT N'UNIT rows inserted           : ' + CONVERT(NVARCHAR(20), @UnitInserted);
PRINT N'ADDRESS rows inserted        : ' + CONVERT(NVARCHAR(20), @AddressInserted);
PRINT N'CONTACT / UPR_CONTACT        : '
    + CONVERT(NVARCHAR(20), @ContactInserted) + N' / '
    + CONVERT(NVARCHAR(20), @UPRContactInserted);
PRINT N'XREF inserted                : ' + CONVERT(NVARCHAR(20), @XrefInserted);
PRINT N'UPR_CLOSURE rows             : ' + CONVERT(NVARCHAR(20), @ClosureRows);
PRINT N'StatusHistory inserted       : ' + CONVERT(NVARCHAR(20), @StatusHistInserted);
PRINT N'AuditLog inserted            : ' + CONVERT(NVARCHAR(20), @AuditInserted);
PRINT N'Elapsed seconds              : '
    + CONVERT(NVARCHAR(20), DATEDIFF(SECOND, @BatchStart, SYSDATETIME()));
PRINT N'NOTE: Safe to re-run - existing UPRs are reused, not duplicated.';
PRINT N'================================================================';

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    DECLARE @ErrNum INT = ERROR_NUMBER();
    DECLARE @ErrLine INT = ERROR_LINE();
    DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
    PRINT N'*** UPR hierarchical load FAILED ***';
    PRINT N'Error ' + CONVERT(NVARCHAR(20), @ErrNum)
        + N' at line ' + CONVERT(NVARCHAR(20), @ErrLine)
        + N': ' + @ErrMsg;
    THROW;
END CATCH;
GO
