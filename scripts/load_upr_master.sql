/*
================================================================================
  UPR Master Load Script - Hierarchical model (v2)

  Source of truth: docs/NewUPRTABLEUSED.docx + docs/Response.docx
  Schema:          ddl/03_new_upr_schema.sql

  Replaces the flat UPROPERTYRECORDS load completely.
  Legacy flat loader archived as: legacy/load_upr_master_legacy_flat.sql

  CLIENT RULES (Response.docx):
    1) NewUPRTABLEUSED is source of truth; replace old model completely
    2) COMPLEX when MA MultiFamily + Account# + 2+ distinct building addresses.
       Every incoming row for that account - including SDAT / condo-typed rows -
       stays inside the one Complex. The account never also becomes a Condo.
    3) MultiFamily with 1 address -> Property -> Building -> Unit
    4) SDAT-only account: Condo (Parent NULL) -> Unit; account on Condo UPR.
       Shared accounts follow MA's Complex or uniquely matched MA group;
       unmatched/ambiguous shared SDAT rows go to Review_Q, never default Condo.
    5) SF / Warehouse / Office / Park / etc -> Property -> Building only, no Unit
       (not a dwelling-unit record type)
    6) Address via ADDRESS + UPR_ADDRESS only; Contact required when address valid
    7) Staging in temp tables after validate/normalize; print statistics
    8) AccountNumber required on every incoming record; no account -> reject to
       Review_Q (INSUFFICIENT_DATA), never written to UPR. Not unique on UPR
       (one account can span several UPR rows). CommunityName on COMPLEX only.
    9) Every MULTI/APT/CONDO record that needs a Unit gets one - never silently
       dropped. Real source value when given. A KDAT/Condo record with none
       keeps NULL (the column exists, source left it blank). An MA record with
       no UnitNumber field, counted as a unit in its building/Complex address,
       gets literal N'N/A' - never an invented MA-<id>/SD-<id> label.
   10) Missing/placeholder Parcel numbers stay NULL and do not cause Review_Q.

  Prerequisites: create the schema once, then run scripts/install_upr_audit.sql.
  Re-runnable: unchanged incoming data inserts no business rows (batch audit remains).

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
/* Run status must survive a rolled-back load, so use a dedicated connection
   without a caller-owned transaction. Never roll back a caller's work. */
IF @@TRANCOUNT <> 0
BEGIN
    /* RAISERROR leaves a caller transaction intact even with XACT_ABORT ON. */
    RAISERROR ('Run the loader outside an existing transaction.', 16, 1);
    RETURN;
END;
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

/* Preserve supported source ZIP formats; never manufacture missing digits. */
CREATE OR ALTER FUNCTION dbo.fn_UPR_NormalizeZipCode (@zip NVARCHAR(20))
RETURNS NVARCHAR(10)
AS
BEGIN
    DECLARE @raw NVARCHAR(20) = NULLIF(LTRIM(RTRIM(@zip)), N'');
    IF @raw NOT LIKE N'%[^0-9]%' AND LEN(@raw) = 9
        RETURN LEFT(@raw, 5) + N'-' + RIGHT(@raw, 4);
    IF LEN(@raw) = 5 AND @raw NOT LIKE N'%[^0-9]%'
        RETURN @raw;
    IF LEN(@raw) = 10 AND @raw LIKE N'[0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]'
        RETURN @raw;
    RETURN NULL;
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
        ISNULL(LEFT(REPLACE(dbo.fn_UPR_NormalizeZipCode(@zip), N'-', N''), 5), N'')
    ));
END;
GO


/* ========================================================================
   SCHEMA ENSURE BATCH
   Must run in its own batch (before GO) because the main batch reads
   SDATIncomingTableX1.CondoUnit and UPR_CLOSURE.Level. A column added in the same batch that
   reads it fails with "Invalid column name".
   ======================================================================== */
SET NOCOUNT ON;

IF OBJECT_ID(N'dbo.SDATIncomingTableX1', N'U') IS NOT NULL
   AND COL_LENGTH(N'dbo.SDATIncomingTableX1', N'CondoUnit') IS NULL
BEGIN
    ALTER TABLE dbo.SDATIncomingTableX1 ADD CondoUnit NVARCHAR(50) NULL;
    PRINT N'Schema: added CondoUnit NVARCHAR(50) NULL to dbo.SDATIncomingTableX1.';
END;

/* Existing databases: add without a guessed default. Step 12 backfills the
   actual report levels and enforces NOT NULL inside the load transaction. */
IF OBJECT_ID(N'dbo.UPR_CLOSURE', N'U') IS NOT NULL
   AND COL_LENGTH(N'dbo.UPR_CLOSURE', N'Level') IS NULL
BEGIN
    ALTER TABLE dbo.UPR_CLOSURE ADD [Level] INT NULL;
    PRINT N'Schema: added UPR_CLOSURE.Level; Step 12 will populate it.';
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
DECLARE @AuditRunID UNIQUEIDENTIFIER = NEWID();
DECLARE @PreviousAuditRun SQL_VARIANT = SESSION_CONTEXT(N'UPR_AuditRunID');
DECLARE @RunRecorded BIT = 0;
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

IF @@TRANCOUNT <> 0
BEGIN
    /* RAISERROR leaves a caller transaction intact even with XACT_ABORT ON. */
    RAISERROR ('Run the loader outside an existing transaction.', 16, 1);
    RETURN;
END;
BEGIN TRY

/* Install/upgrade audit support before the main load. Dynamic SQL gives a
   useful prerequisite error even when the run-history table is absent. */
IF OBJECT_ID(N'dbo.UPR_LOAD_RUN', N'U') IS NULL
   OR COL_LENGTH(N'dbo.AuditLog', N'RunID') IS NULL
   OR COL_LENGTH(N'dbo.AuditLog', N'SessionID') IS NULL
    THROW 50004, 'Run the updated scripts/install_upr_audit.sql before loading data.', 1;
EXEC sys.sp_executesql N'
    INSERT dbo.UPR_LOAD_RUN (RunID, StartedAt, RunStatus, StartedBy, SessionID)
    VALUES (@id, SYSDATETIME(), ''RUNNING'', @who, @@SPID);',
    N'@id UNIQUEIDENTIFIER, @who NVARCHAR(100)', @AuditRunID, @AuditUser;
SET @RunRecorded = 1;
EXEC sys.sp_set_session_context @key = N'UPR_AuditRunID', @value = @AuditRunID;

PRINT N'================================================================';
PRINT N'UPR hierarchical load starting: ' + CONVERT(NVARCHAR(30), @BatchStart, 121);
PRINT N'Staging rules: MA-FIRST-2026-09-15';
PRINT N'Parcel rules: OPTIONAL-PARCEL-2026-09-16';
PRINT N'Coordinate rules: SOURCE-PAIR-2026-09-16';
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

IF EXISTS (
    SELECT 1 FROM sys.tables t
    WHERE t.schema_id = SCHEMA_ID(N'dbo')
      AND t.name IN (N'UPR', N'ADDRESS', N'COMPLEX', N'PROPERTY', N'CONDO',
          N'BUILDING', N'UNIT', N'ADU', N'CONTACT', N'UPR_ADDRESS', N'UPR_CONTACT',
          N'EXTERNAL_IDENTIFIER_XREF', N'UPR_CLOSURE', N'UPRMATCHREVIEW_Q', N'UPRSTATUSHISTORY',
          N'REF_ENTITYTYPE', N'REF_PROPERTYTYPE', N'REF_PROPERTY_STATUSCODE',
          N'REF_CONTACTTYPE', N'REF_ROLETYPE', N'REF_ADDRESSROLE', N'REF_UNITTYPECODE')
      AND NOT EXISTS (
          SELECT 1 FROM sys.triggers tr WHERE tr.parent_id = t.object_id
            AND tr.name = N'tr_UPR_Audit_' + t.name AND tr.is_disabled = 0
            AND OBJECT_DEFINITION(tr.object_id) LIKE N'%UPR_AuditRunID%'
            AND (SELECT COUNT(*) FROM sys.trigger_events ev
                 WHERE ev.object_id = tr.object_id AND ev.type_desc IN (N'INSERT', N'UPDATE', N'DELETE')) = 3
      )
)
    THROW 50004, 'Run scripts/install_upr_audit.sql before loading data.', 1;

BEGIN TRANSACTION;
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
        [State]              = CAST(NULL AS CHAR(2)),
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
            COALESCE(dbo.fn_UPR_StdStreetToken(CONVERT(NVARCHAR(50), ma.StreetType)),
                   NULLIF(UPPER(LTRIM(RTRIM(ma.StreetType))), N''), N'')
        ))),
        NormalizedFullAddress = UPPER(LTRIM(RTRIM(
            ISNULL(dbo.fn_UPR_NormalizeStreetNumber(CONVERT(NVARCHAR(20), ma.StreetNumber)), N'') + N' ' +
            ISNULL(UPPER(LTRIM(RTRIM(ma.StreetName))), N'') + N' ' +
            COALESCE(dbo.fn_UPR_StdStreetToken(CONVERT(NVARCHAR(50), ma.StreetType)),
                   NULLIF(UPPER(LTRIM(RTRIM(ma.StreetType))), N''), N'') + N' ' +
            ISNULL(UPPER(LTRIM(RTRIM(ma.City))), N'') + N' ' +
            ISNULL(LEFT(REPLACE(dbo.fn_UPR_NormalizeZipCode(ma.ZipCode), N'-', N''), 5), N'')
        ))),
        HasRequiredAddress   = CASE
            WHEN NULLIF(UPPER(LTRIM(RTRIM(ma.StreetName))), N'') IS NULL THEN 0
            WHEN dbo.fn_UPR_IsValidStreetNumber(ma.StreetNumber) = 0 THEN 0
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
            ELSE NULL
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
            COALESCE(dbo.fn_UPR_StdStreetToken(CONVERT(NVARCHAR(50), s.PremisesStreetType)),
                   NULLIF(UPPER(LTRIM(RTRIM(s.PremisesStreetType))), N''), N'')
        ))),
        NormalizedFullAddress = UPPER(LTRIM(RTRIM(
            ISNULL(dbo.fn_UPR_NormalizeStreetNumber(LTRIM(RTRIM(s.PremisesNumber))), N'') + N' ' +
            ISNULL(UPPER(LTRIM(RTRIM(s.PremisesStreetName))), N'') + N' ' +
            COALESCE(dbo.fn_UPR_StdStreetToken(CONVERT(NVARCHAR(50), s.PremisesStreetType)),
                   NULLIF(UPPER(LTRIM(RTRIM(s.PremisesStreetType))), N''), N'') + N' ' +
            ISNULL(UPPER(LTRIM(RTRIM(s.PremisesCity))), N'') + N' ' +
            ISNULL(LEFT(REPLACE(dbo.fn_UPR_NormalizeZipCode(s.PremisesZipCode), N'-', N''), 5), N'')
        ))),
        HasRequiredAddress   = CASE
            WHEN NULLIF(UPPER(LTRIM(RTRIM(s.PremisesStreetName))), N'') IS NULL THEN 0
            WHEN dbo.fn_UPR_IsValidStreetNumber(s.PremisesNumber) = 0 THEN 0
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
    RawPropertyType         NVARCHAR(128) NULL,
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
    DistinctAddrOnAccount   INT          NULL,
    HasMAAccount            BIT          NOT NULL DEFAULT (0),
    ClassificationReason    NVARCHAR(255) NULL,
    /* All valid rows on a qualifying account inherit MA's type and Complex
       group, including blank/different MA types and default SDAT Condo rows. */
    IsComplexAccount        BIT          NOT NULL CONSTRAINT DF_Stage_IsComplexAccount DEFAULT (0)
);

INSERT INTO #Stage (
    SourceSystem, SourceRecordID, MasterAddressID, KdatRecordID, AccountNumber, ParcelID,
    StreetNumber, StreetName, StreetType, City, [State], ZipCode,
    UnitNumber, CondoUnit, PropertyType, RawPropertyType, OwnerName, YearBuilt, DwellingUnits,
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
    LEFT(UnitNumber, 50), LEFT(CondoUnit, 50), LEFT(PropertyType, 6), LEFT(PropertyTypeRaw, 128),
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
    LEFT(UnitNumber, 50), LEFT(CondoUnit, 50), LEFT(PropertyType, 6), LEFT(PropertyTypeRaw, 128),
    LEFT(OwnerName, 200), YearBuilt, DwellingUnits,
    YCoordinate, XCoordinate,
    LEFT(NormalizedStreetAddress, 300), LEFT(NormalizedFullAddress, 300), HasRequiredAddress
FROM #SDAT;

SET @StageRows = (SELECT COUNT(*) FROM #Stage);
CREATE INDEX IX_Stage_Account_Source ON #Stage (AccountNumber, SourceSystem);

/* Repair ANY leftover legacy generated UnitNumber (N'MA-<id>' / N'SD-<id>'),
   even when its exact source row is no longer in the current incoming batch -
   a stale invented label must never be shown or stored, per se. Never invent a
   replacement value either: KDAT/condo records keep NULL (the source column
   exists, it is just empty); ADDRESS_MASTER "unit" rows get N'N/A' (MA has no
   UnitNumber field for these - distinguishes "no data" from "empty value").
   Keep the existing Unit/UPR IDs and links. Skip only when another CURRENT
   linked source record proves a real unit value for this same Unit. */
UPDATE un
SET UnitNumber = CASE x.SourceSystem WHEN N'KDAT' THEN NULL ELSE N'N/A' END
FROM dbo.UNIT un
INNER JOIN dbo.EXTERNAL_IDENTIFIER_XREF x ON x.UPRID = un.UPRID
    AND x.IdentifierType = N'SOURCE_RECORD_ID'
WHERE (
        (x.SourceSystem = N'ADDRESS_MASTER' AND un.UnitNumber LIKE N'MA-%'
         AND SUBSTRING(un.UnitNumber, 4, 50) NOT LIKE N'%[^0-9]%')
     OR (x.SourceSystem = N'KDAT' AND un.UnitNumber LIKE N'SD-%'
         AND SUBSTRING(un.UnitNumber, 4, 50) NOT LIKE N'%[^0-9]%')
      )
  AND NOT EXISTS (
      SELECT 1 FROM dbo.EXTERNAL_IDENTIFIER_XREF other
      INNER JOIN #Stage os ON os.SourceSystem = other.SourceSystem AND os.SourceRecordID = other.IdentifierValue
      WHERE other.UPRID = un.UPRID AND other.IdentifierType = N'SOURCE_RECORD_ID'
        AND (os.UnitNumber IS NOT NULL OR os.CondoUnit IS NOT NULL)
  );

/* Placeholder parcels -> NULL */
UPDATE #Stage
SET ParcelID = NULL
WHERE ParcelID IS NOT NULL
  AND (
        REPLACE(ParcelID, N'0', N'') = N''
     OR UPPER(LTRIM(RTRIM(ParcelID))) IN (N'NULL', N'N/A', N'NA', N'NONE')
  );

/* Distinct street addresses per account; City/ZIP variants are not buildings.
   Counted on MA rows only: the Complex rule is "MA MultiFamily + Account# +
   2+ distinct building addresses". Counting SDAT premises addresses too would
   create false Complexes when SDAT spells the same address differently. */
IF OBJECT_ID('tempdb..#AcctAddrCnt') IS NOT NULL DROP TABLE #AcctAddrCnt;
SELECT
    AccountNumber,
    COUNT(*) AS MARowCount,
    SUM(CASE WHEN HasRequiredAddress = 1 THEN 1 ELSE 0 END) AS ValidMARowCount,
    COUNT(DISTINCT CASE WHEN HasRequiredAddress = 1 THEN NormalizedStreetAddress END) AS DistinctAddrCnt,
    /* Does the account carry at least one MA MultiFamily / Apartment row? */
    MAX(CASE WHEN HasRequiredAddress = 1 AND PropertyType IN (N'MULTI', N'APT') THEN 1 ELSE 0 END) AS HasMultiFamilyRow,
    COALESCE(MAX(CASE WHEN HasRequiredAddress = 1 AND PropertyType = N'MULTI' THEN PropertyType END),
             MAX(CASE WHEN HasRequiredAddress = 1 AND PropertyType = N'APT' THEN PropertyType END)) AS ComplexPropertyType
INTO #AcctAddrCnt
FROM #Stage
WHERE AccountNumber IS NOT NULL
  AND SourceSystem = N'ADDRESS_MASTER'
GROUP BY AccountNumber;
CREATE UNIQUE INDEX IX_AcctAddrCnt_Account ON #AcctAddrCnt (AccountNumber);

/* An account is a Complex (rule 2) when it has an MA MultiFamily/Apartment row
   and 2+ distinct MA building addresses. Flag every staged row on that account -
   MA and SDAT alike - so its condo-typed rows join the Complex, not a new Condo. */
UPDATE s
SET s.DistinctAddrOnAccount = a.DistinctAddrCnt, s.HasMAAccount = 1,
    s.PropertyType = CASE WHEN a.HasMultiFamilyRow = 1 AND a.DistinctAddrCnt > 1
                         THEN a.ComplexPropertyType ELSE s.PropertyType END,
    s.IsComplexAccount = CASE
        WHEN a.HasMultiFamilyRow = 1 AND a.DistinctAddrCnt > 1 THEN 1 ELSE 0 END
FROM #Stage s
INNER JOIN #AcctAddrCnt a ON a.AccountNumber = s.AccountNumber;

/*
   IsValid for UPR write:
     - AccountNumber required (client rule: no account -> reject to Review_Q, never in UPR)
     - required address present
     - City, ZIP and parcel may be missing; never fill them with guesses
   Missing ParcelID is accepted and never causes a Review_Q entry by itself.
*/
UPDATE #Stage
SET
    IsValid = CASE
        WHEN AccountNumber IS NULL THEN 0
        WHEN HasRequiredAddress = 0 THEN 0
        ELSE 1
    END,
    ReviewReason = CASE
        WHEN AccountNumber IS NULL THEN N'INSUFFICIENT_DATA'
        WHEN HasRequiredAddress = 0 THEN N'NO_ADDRESS_MATCH'
        ELSE NULL
    END;

/* AccountNumber is guaranteed non-NULL here - rows without one are IsValid = 0
   (rejected to Review_Q, never in UPR). GroupKey no longer needs a NOACCT branch. */
UPDATE s
SET
    PathType = CASE
        /* MA's account decision owns EVERY row, including mixed MA types. */
        WHEN s.IsComplexAccount = 1 THEN N'COMPLEX'
        WHEN s.PropertyType = N'CONDO' OR s.CondoUnit IS NOT NULL THEN N'CONDO'
        WHEN s.PropertyType IN (N'MULTI', N'APT')
         AND ISNULL(s.DistinctAddrOnAccount, 0) > 1 THEN N'COMPLEX'
        ELSE N'PROPERTY'
    END,
    GroupKey = CASE
        WHEN s.IsComplexAccount = 1 THEN
            N'COMPLEX|' + s.AccountNumber
        WHEN s.PropertyType = N'CONDO' OR s.CondoUnit IS NOT NULL THEN
            N'CONDO|' + s.AccountNumber
        WHEN s.PropertyType IN (N'MULTI', N'APT')
         AND ISNULL(s.DistinctAddrOnAccount, 0) > 1 THEN
            N'COMPLEX|' + s.AccountNumber
        ELSE
            N'PROPERTY|' + s.AccountNumber + N'|' + ISNULL(s.NormalizedFullAddress, N'')
    END
FROM #Stage s
WHERE s.IsValid = 1
  AND (s.SourceSystem = N'ADDRESS_MASTER' OR s.HasMAAccount = 0 OR s.IsComplexAccount = 1);

/* MA groups exist before shared SDAT accounts are considered. SDAT never
   gets its default Condo classification when MA already owns the account.
   Prefer an exact full-address match, then street address, then an existing
   MA Condo group. Multiple equally plausible groups go to review. */
IF OBJECT_ID('tempdb..#SDATMaMatch') IS NOT NULL DROP TABLE #SDATMaMatch;
;WITH Candidates AS (
    SELECT sd.StageKey, ma.GroupKey, ma.PathType, ma.PropertyType,
        MatchRank = DENSE_RANK() OVER (PARTITION BY sd.StageKey ORDER BY CASE
            WHEN ma.NormalizedFullAddress = sd.NormalizedFullAddress THEN 0
            WHEN ma.NormalizedStreetAddress = sd.NormalizedStreetAddress THEN 1 ELSE 2 END)
    FROM #Stage sd
    INNER JOIN #Stage ma ON ma.AccountNumber = sd.AccountNumber
        AND ma.SourceSystem = N'ADDRESS_MASTER' AND ma.IsValid = 1
    WHERE sd.SourceSystem = N'KDAT' AND sd.IsValid = 1
      AND sd.HasMAAccount = 1 AND sd.IsComplexAccount = 0
      AND (ma.NormalizedStreetAddress = sd.NormalizedStreetAddress OR ma.PathType = N'CONDO')
)
SELECT StageKey, MatchingGroups = COUNT(DISTINCT GroupKey),
    MatchingTypes = COUNT(DISTINCT PropertyType),
    GroupKey = MAX(GroupKey), PathType = MAX(PathType), PropertyType = MAX(PropertyType)
INTO #SDATMaMatch FROM Candidates WHERE MatchRank = 1 GROUP BY StageKey;
CREATE UNIQUE INDEX IX_SDATMaMatch_StageKey ON #SDATMaMatch (StageKey);

UPDATE sd SET GroupKey = m.GroupKey, PathType = m.PathType, PropertyType = m.PropertyType
FROM #Stage sd INNER JOIN #SDATMaMatch m ON m.StageKey = sd.StageKey
WHERE m.MatchingGroups = 1 AND m.MatchingTypes <= 1;

UPDATE sd SET IsValid = 0,
    ReviewReason = CASE WHEN m.StageKey IS NULL THEN N'NO_ADDRESS_MATCH' ELSE N'AMBIGUOUS_CANDIDATES' END
FROM #Stage sd LEFT JOIN #SDATMaMatch m ON m.StageKey = sd.StageKey
WHERE sd.IsValid = 1 AND sd.SourceSystem = N'KDAT' AND sd.HasMAAccount = 1
  AND sd.IsComplexAccount = 0 AND sd.GroupKey IS NULL;

UPDATE s SET ClassificationReason = CASE
    WHEN IsValid = 0 AND SourceSystem = N'KDAT' AND HasMAAccount = 1 AND HasRequiredAddress = 1
        THEN N'SDAT account exists in MA but has no single matching valid MA group; review required'
    WHEN IsValid = 0 THEN N'Rejected: ' + COALESCE(ReviewReason, N'Invalid source row')
    WHEN IsComplexAccount = 1 THEN N'MA multifamily/apartment account with multiple street addresses: Complex'
    WHEN SourceSystem = N'ADDRESS_MASTER' THEN N'MA record type and address determine the parent'
    WHEN HasMAAccount = 1 THEN N'SDAT matched the MA parent; MA classification takes precedence'
    ELSE N'SDAT-only account: Condo' END
FROM #Stage s;

/* Working indexes - #Stage is joined on GroupKey many times below */
CREATE INDEX IX_Stage_GroupKey ON #Stage (GroupKey) WHERE IsValid = 1;
CREATE INDEX IX_Stage_Source ON #Stage (SourceSystem, SourceRecordID);

SET @ValidRows = (SELECT COUNT(*) FROM #Stage WHERE IsValid = 1);
SET @InvalidRows = (SELECT COUNT(*) FROM #Stage WHERE IsValid = 0);
PRINT N'Step 4 complete - Stage=' + CONVERT(NVARCHAR(20), @StageRows)
    + N'; Valid=' + CONVERT(NVARCHAR(20), @ValidRows)
    + N'; Invalid=' + CONVERT(NVARCHAR(20), @InvalidRows);

/* ============================================================================
   5. Review_Q for rejected records (mapped reasons only)
   ============================================================================ */
PRINT N'Step 5: Write UPRMATCHREVIEW_Q for rejected rows...';

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
        WHEN AccountNumber IS NULL THEN N'INSUFFICIENT_DATA'
        WHEN HasRequiredAddress = 0 THEN N'NO_ADDRESS_MATCH'
        WHEN IsValid = 0 THEN ISNULL(ReviewReason, N'OTHER')
        ELSE ISNULL(ReviewReason, N'OTHER')
    END,
    IsValid
INTO #ReviewSrc
FROM #Stage
WHERE IsValid = 0;

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
            N'NO_SDAT_MATCH', N'NO_ADDRESS_MATCH', N'INSUFFICIENT_DATA',
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
                N'NO_SDAT_MATCH', N'NO_ADDRESS_MATCH', N'INSUFFICIENT_DATA',
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
        MAX(CASE WHEN s.SourceSystem = N'ADDRESS_MASTER' AND s.PropertyType = N'MULTI' THEN s.PropertyType END),
        MAX(CASE WHEN s.SourceSystem = N'ADDRESS_MASTER' AND s.PropertyType = N'APT' THEN s.PropertyType END),
        MAX(CASE WHEN s.SourceSystem = N'ADDRESS_MASTER' THEN s.PropertyType END),
        MAX(s.PropertyType),
        /* Nothing usable in the incoming record type - never invent SF */
        CASE s.PathType WHEN N'CONDO' THEN N'CONDO' WHEN N'COMPLEX' THEN N'MULTI' ELSE N'UNKNWN' END
    ),
    OwnerName = MAX(s.OwnerName),
    /* Neither incoming table supplies a community name. */
    CommunityName = CAST(NULL AS VARCHAR(200)),
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

/* Repair a source-proven, single old Condo root in place when MA now proves
   this account is a Complex. Preserve UPR/building/unit IDs and XREFs. Named
   Condos, multiple existing roots, or incompatible Unit links need review. */
IF OBJECT_ID('tempdb..#CondoToComplex') IS NOT NULL DROP TABLE #CondoToComplex;
SELECT g.GroupKey, u.UPRID
INTO #CondoToComplex
FROM #ParentGroup g
INNER JOIN dbo.UPR u ON u.AccountNumber = g.AccountNumber
    AND u.ParentUPRID IS NULL AND u.EntityTypeID = @EtCondo
INNER JOIN dbo.CONDO d ON d.UPRID = u.UPRID
WHERE g.PathType = N'COMPLEX' AND d.CondoName IS NULL
  AND (SELECT COUNT(*) FROM dbo.UPR other
       WHERE other.AccountNumber = g.AccountNumber AND other.ParentUPRID IS NULL) = 1
  AND EXISTS (SELECT 1 FROM dbo.EXTERNAL_IDENTIFIER_XREF x
              WHERE x.UPRID = u.UPRID AND x.SourceSystem = N'KDAT'
                AND x.IdentifierType = N'ACCOUNT_NUMBER' AND x.IdentifierValue = g.AccountNumber)
  AND NOT EXISTS (
      SELECT 1 FROM dbo.UPR child LEFT JOIN dbo.UNIT un ON un.UPRID = child.UPRID
      LEFT JOIN dbo.BUILDING b ON b.BuildingID = un.BuildingID
      LEFT JOIN dbo.UPR bu ON bu.UPRID = b.UPRID
      WHERE child.ParentUPRID = u.UPRID AND child.EntityTypeID = @EtUnit
        AND (bu.UPRID IS NULL OR bu.ParentUPRID IS NULL OR bu.ParentUPRID <> u.UPRID)
  );
UPDATE u SET EntityTypeID = @EtComplex, UpdatedBy = @RunUser, UpdatedDate = @Now
FROM dbo.UPR u INNER JOIN #CondoToComplex r ON r.UPRID = u.UPRID;
DELETE d FROM dbo.CONDO d INNER JOIN #CondoToComplex r ON r.UPRID = d.UPRID;
UPDATE child SET ParentUPRID = b.UPRID, UpdatedBy = @RunUser, UpdatedDate = @Now
FROM dbo.UPR child INNER JOIN #CondoToComplex r ON r.UPRID = child.ParentUPRID
INNER JOIN dbo.UNIT un ON un.UPRID = child.UPRID
INNER JOIN dbo.BUILDING b ON b.BuildingID = un.BuildingID;
/* Step 7 fills COMPLEX for this reused UPR; Step 12 rebuilds closure/Level.
   The old Condo subtype and entity/parent changes are retained by audit. */

INSERT INTO dbo.UPRMATCHREVIEW_Q
    (UPRID, IncomingSourceSystem, SDAT_NormalizedIncomingAddress, MA_NormalizedIncomingAddress,
     SDAT_AccountNumber, MA_Account, ReasonForNoMatch, ProcessingTimestamp, ReviewStatus, Decision)
SELECT u.UPRID, CASE WHEN u.EntityTypeID = @EtCondo THEN N'KDAT' ELSE N'ADDRESS_MASTER' END, N'', N'',
    CASE WHEN u.EntityTypeID = @EtCondo THEN LEFT(g.AccountNumber, 30) END,
    CASE WHEN u.EntityTypeID = @EtProperty THEN LEFT(g.AccountNumber, 30) END, N'AMBIGUOUS_CANDIDATES',
    @Now, N'PENDING_REVIEW', N'MA requires Complex; existing parents need review before loading this account. Check roots and Unit BuildingID links.'
FROM #ParentGroup g INNER JOIN dbo.UPR u ON u.AccountNumber = g.AccountNumber
    AND u.ParentUPRID IS NULL AND u.EntityTypeID IN (@EtCondo, @EtProperty)
WHERE g.PathType = N'COMPLEX'
  AND NOT EXISTS (SELECT 1 FROM dbo.UPRMATCHREVIEW_Q q WHERE q.UPRID = u.UPRID
                  AND q.Decision = N'MA requires Complex; existing parents need review before loading this account. Check roots and Unit BuildingID links.');
SET @ReviewInserted = @ReviewInserted + @@ROWCOUNT;

/* Do not build a second competing tree when existing data cannot be safely
   reclassified. Keep its staged evidence and queue the existing root IDs. */
UPDATE s SET IsValid = 0, ReviewReason = N'AMBIGUOUS_CANDIDATES',
    ClassificationReason = N'MA requires Complex; existing parent records need review before this account can load'
FROM #Stage s INNER JOIN #ParentGroup g ON g.GroupKey = s.GroupKey
WHERE g.PathType = N'COMPLEX' AND EXISTS (
    SELECT 1 FROM dbo.UPR u WHERE u.AccountNumber = g.AccountNumber AND u.ParentUPRID IS NULL
      AND u.EntityTypeID IN (@EtCondo, @EtProperty));
DELETE g FROM #ParentGroup g
WHERE NOT EXISTS (SELECT 1 FROM #Stage s WHERE s.GroupKey = g.GroupKey AND s.IsValid = 1);
SET @ValidRows = (SELECT COUNT(*) FROM #Stage WHERE IsValid = 1);
SET @InvalidRows = (SELECT COUNT(*) FROM #Stage WHERE IsValid = 0);

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
WHERE (g.PathType = N'PROPERTY' OR (g.PathType = N'CONDO' AND g.AccountNumber IS NULL))
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
    /* Sequence is used only to recognize legacy generated names for repair. */
    BuildingSeq = ROW_NUMBER() OVER (PARTITION BY pm.UPRID ORDER BY s.NormalizedFullAddress),
    StreetNumber = MAX(s.StreetNumber),
    StreetName   = MAX(s.StreetName),
    StreetType   = MAX(s.StreetType),
    City         = MAX(s.City),
    [State]      = MAX(s.[State]),
    ZipCode      = MAX(s.ZipCode),
    YCoordinate  = CAST(NULL AS INT),
    XCoordinate  = CAST(NULL AS INT),
    LegacyMaxY   = MAX(s.YCoordinate),
    LegacyMaxX   = MAX(s.XCoordinate),
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

/* A coordinate is a pair from ONE source row. Prefer a complete pair, then
   an incomplete pair without filling its missing component from another row.
   Use the lowest source ID for a stable representative of this address. */
UPDATE b SET XCoordinate = chosen.XCoordinate, YCoordinate = chosen.YCoordinate
FROM #BuildingSrc b
OUTER APPLY (
    SELECT TOP (1) s.XCoordinate, s.YCoordinate
    FROM #Stage s
    WHERE s.GroupKey = b.GroupKey AND s.NormalizedFullAddress = b.NormalizedFullAddress
      AND s.IsValid = 1 AND (s.XCoordinate IS NOT NULL OR s.YCoordinate IS NOT NULL)
    ORDER BY CASE WHEN s.XCoordinate IS NOT NULL AND s.YCoordinate IS NOT NULL THEN 0 ELSE 1 END,
        CASE s.SourceSystem WHEN N'ADDRESS_MASTER' THEN 0 ELSE 1 END,
        TRY_CONVERT(BIGINT, s.SourceRecordID), s.SourceRecordID, s.StageKey
) chosen;

IF OBJECT_ID('tempdb..#BuildingMap') IS NOT NULL DROP TABLE #BuildingMap;
CREATE TABLE #BuildingMap (
    BuildingKey BIGINT NOT NULL PRIMARY KEY,
    GroupKey NVARCHAR(450) NOT NULL,
    BuildingUPRID BIGINT NOT NULL,
    NormalizedFullAddress NVARCHAR(300) NULL,
    PathType VARCHAR(20) NOT NULL
);

/* A source-matching Address link may already exist with IsPrimary = 0.
   Restore its primary flag before looking for reusable Buildings. */
;WITH PrimaryBuildingAddress AS (
    SELECT u.UPRID, UPRAddressID = MIN(ua.UPRAddressID)
    FROM #BuildingSrc src
    INNER JOIN dbo.UPR u ON u.ParentUPRID = src.ParentUPRID AND u.EntityTypeID = @EtBuilding
    INNER JOIN dbo.UPR_ADDRESS ua ON ua.UPRID = u.UPRID
    INNER JOIN dbo.ADDRESS a ON a.AddressID = ua.AddressID
        AND a.NormalizedAddress = src.NormalizedFullAddress
    WHERE NOT EXISTS (SELECT 1 FROM dbo.UPR_ADDRESS p WHERE p.UPRID = u.UPRID AND p.IsPrimary = 1)
    GROUP BY u.UPRID
)
UPDATE ua SET IsPrimary = 1
FROM dbo.UPR_ADDRESS ua
INNER JOIN PrimaryBuildingAddress p ON p.UPRAddressID = ua.UPRAddressID;

/* Skip buildings already under parent with same normalized address.
   MIN() keeps one row per BuildingKey if an earlier run left duplicates. */
INSERT INTO #BuildingMap (BuildingKey, GroupKey, BuildingUPRID, NormalizedFullAddress, PathType)
SELECT b.BuildingKey, MIN(b.GroupKey), MIN(ua.UPRID), MIN(b.NormalizedFullAddress), MIN(b.PathType)
FROM #BuildingSrc b
INNER JOIN dbo.UPR u ON u.ParentUPRID = b.ParentUPRID AND u.EntityTypeID = @EtBuilding
INNER JOIN dbo.UPR_ADDRESS ua ON ua.UPRID = u.UPRID AND ua.IsPrimary = 1
INNER JOIN dbo.ADDRESS a ON a.AddressID = ua.AddressID AND a.NormalizedAddress = b.NormalizedFullAddress
GROUP BY b.BuildingKey;

/* An earlier load may have left a Building without an address. Reuse it only
   when both the source address and unaddressed Building are unambiguous. */
INSERT INTO #BuildingMap (BuildingKey, GroupKey, BuildingUPRID, NormalizedFullAddress, PathType)
SELECT b.BuildingKey, MIN(b.GroupKey), MIN(u.UPRID), MIN(b.NormalizedFullAddress), MIN(b.PathType)
FROM #BuildingSrc b
INNER JOIN dbo.UPR u ON u.ParentUPRID = b.ParentUPRID AND u.EntityTypeID = @EtBuilding
INNER JOIN dbo.BUILDING entity ON entity.UPRID = u.UPRID
WHERE NOT EXISTS (SELECT 1 FROM #BuildingMap m WHERE m.BuildingKey = b.BuildingKey)
  AND NOT EXISTS (SELECT 1 FROM dbo.UPR_ADDRESS ua WHERE ua.UPRID = u.UPRID)
  AND NOT EXISTS (SELECT 1 FROM #BuildingSrc other WHERE other.ParentUPRID = b.ParentUPRID
                    AND other.BuildingKey <> b.BuildingKey)
GROUP BY b.BuildingKey
HAVING COUNT(*) = 1;

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
    NULL,   /* No BuildingName is supplied by the incoming tables. */
    b.YearBuilt,
    N'ACTIVE'
FROM #BuildingMap bm
INNER JOIN #BuildingSrc b ON b.BuildingKey = bm.BuildingKey
WHERE NOT EXISTS (SELECT 1 FROM dbo.BUILDING x WHERE x.UPRID = bm.BuildingUPRID);

/* Clear the exact names generated by the previous loader for these groups. */
UPDATE target SET BuildingName = NULL
FROM dbo.BUILDING target
INNER JOIN #BuildingMap bm ON bm.BuildingUPRID = target.UPRID
INNER JOIN #BuildingSrc src ON src.BuildingKey = bm.BuildingKey
WHERE target.BuildingName = CASE WHEN src.BuildingSeq <= 26
    THEN N'Building ' + CHAR(64 + CONVERT(INT, src.BuildingSeq))
    ELSE N'Building ' + CONVERT(NVARCHAR(20), src.BuildingSeq) END;

UPDATE target SET CommunityName = NULL
FROM dbo.COMPLEX target
INNER JOIN #ParentMap pm ON pm.UPRID = target.UPRID
WHERE target.CommunityName IN (N'BUILDING COMPLEX', pm.AccountNumber + N' BUILDING COMPLEX')
   OR (EXISTS (SELECT 1 FROM #Stage s WHERE s.GroupKey = pm.GroupKey
                 AND target.CommunityName = s.City + N' BUILDING COMPLEX'));

CREATE INDEX IX_BuildingMap_Lookup ON #BuildingMap (GroupKey, NormalizedFullAddress);

/* Correct the old MAX(X)/MAX(Y) combination only when it is not a real
   source pair, still equals the legacy result, and has source-linked ancestry.
   Leave other existing coordinate values intact. A shared Address must have
   a single agreed replacement pair; otherwise no automatic repair is made. */
IF OBJECT_ID('tempdb..#CoordinateRepair') IS NOT NULL DROP TABLE #CoordinateRepair;
SELECT DISTINCT a.AddressID, src.XCoordinate, src.YCoordinate
INTO #CoordinateRepair
FROM #BuildingSrc src
INNER JOIN #BuildingMap bm ON bm.BuildingKey = src.BuildingKey
INNER JOIN dbo.UPR_ADDRESS ua ON ua.UPRID = bm.BuildingUPRID AND ua.IsPrimary = 1
INNER JOIN dbo.ADDRESS a ON a.AddressID = ua.AddressID
    AND a.NormalizedAddress = src.NormalizedFullAddress
WHERE NOT EXISTS (SELECT a.XCoordinate, a.YCoordinate EXCEPT SELECT src.LegacyMaxX, src.LegacyMaxY)
  AND EXISTS (SELECT a.XCoordinate, a.YCoordinate EXCEPT SELECT src.XCoordinate, src.YCoordinate)
  AND NOT EXISTS (
      SELECT 1 FROM #Stage s WHERE s.IsValid = 1 AND s.NormalizedFullAddress = src.NormalizedFullAddress
        AND NOT EXISTS (SELECT a.XCoordinate, a.YCoordinate EXCEPT SELECT s.XCoordinate, s.YCoordinate))
  AND EXISTS (
      SELECT 1 FROM #Stage s
      INNER JOIN dbo.EXTERNAL_IDENTIFIER_XREF x ON x.SourceSystem = s.SourceSystem
          AND x.IdentifierType = N'SOURCE_RECORD_ID' AND x.IdentifierValue = s.SourceRecordID
      INNER JOIN dbo.UPR_CLOSURE cl ON cl.DescendantUPRID = x.UPRID AND cl.AncestorUPRID = src.ParentUPRID
      WHERE s.GroupKey = src.GroupKey AND s.NormalizedFullAddress = src.NormalizedFullAddress AND s.IsValid = 1);

UPDATE a SET XCoordinate = r.XCoordinate, YCoordinate = r.YCoordinate
FROM dbo.ADDRESS a INNER JOIN #CoordinateRepair r ON r.AddressID = a.AddressID
WHERE (SELECT COUNT(*) FROM #CoordinateRepair other WHERE other.AddressID = r.AddressID) = 1;

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

/* Remove the former MD fallback on a matched source address when no valid
   state was supplied. The incoming tables do not provide a state for MA. */
UPDATE a SET State = NULL
FROM dbo.ADDRESS a
INNER JOIN dbo.UPR_ADDRESS ua ON ua.AddressID = a.AddressID AND ua.IsPrimary = 1
INNER JOIN #BuildingMap bm ON bm.BuildingUPRID = ua.UPRID
INNER JOIN #BuildingSrc src ON src.BuildingKey = bm.BuildingKey
WHERE a.State = N'MD' AND src.State IS NULL;

IF OBJECT_ID('tempdb..#AddressMap') IS NOT NULL DROP TABLE #AddressMap;
CREATE TABLE #AddressMap (
    AddressKey BIGINT NOT NULL PRIMARY KEY,
    AddressID BIGINT NOT NULL
);

/* Reuse a source-identical Address already present (for example, when only
   the Building-to-Address association was missing from a previous run). */
INSERT INTO #AddressMap (AddressKey, AddressID)
SELECT src.AddressKey, MIN(a.AddressID)
FROM #AddressSrc src
INNER JOIN dbo.ADDRESS a ON a.NormalizedAddress = src.NormalizedAddress
WHERE NOT EXISTS (
    SELECT a.StreetNumber, a.StreetName, a.StreetType, a.City, a.State, a.ZipCode, a.XCoordinate, a.YCoordinate
    EXCEPT
    SELECT src.StreetNumber, src.StreetName, src.StreetType, src.City, src.State, src.ZipCode, src.XCoordinate, src.YCoordinate
)
GROUP BY src.AddressKey;

MERGE dbo.ADDRESS AS t
USING (
    SELECT src.* FROM #AddressSrc src
    WHERE NOT EXISTS (SELECT 1 FROM #AddressMap m WHERE m.AddressKey = src.AddressKey)
) AS s
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
        RealUnitNumber = COALESCE(
            NULLIF(LTRIM(RTRIM(s.CondoUnit)), N''),
            NULLIF(LTRIM(RTRIM(s.UnitNumber)), N'')
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
        /* Every record that needs a unit gets one - never silently dropped.
           Real source value when given. A KDAT/Condo record with none keeps
           NULL (the column exists, source just left it blank). An MA record
           counted as a unit in a building/Complex address has no UnitNumber
           column at all, so it gets literal N'N/A' - never an invented label. */
        UnitNumber = COALESCE(ub.RealUnitNumber,
            CASE WHEN ub.SourceSystem = N'KDAT' THEN NULL ELSE N'N/A' END),
        ParentUPRID = CASE
            WHEN ub.PathType = N'CONDO' THEN pm.UPRID
            ELSE bm.BuildingUPRID
        END,
        BuildingUPRID = bm.BuildingUPRID,
        BuildingTableID = CAST(NULL AS BIGINT),
        /* Only rows sharing a REAL source unit value are the same physical
           unit and may collapse into one Unit row. A row with no real value
           always keeps its own slot (keyed by StageKey) - it must never
           silently merge with an unrelated blank/N'A' row at the same address. */
        Rn = ROW_NUMBER() OVER (
            PARTITION BY ub.GroupKey, ub.NormalizedFullAddress,
                COALESCE(ub.RealUnitNumber, N'#' + CONVERT(NVARCHAR(20), ub.StageKey))
            ORDER BY
                CASE ub.SourceSystem WHEN N'KDAT' THEN 0 ELSE 1 END,
                ub.StageKey
        ),
        /* Every stage row in the dedup group - including the ones collapsed
           away below - needs to resolve to the SAME surviving Unit for XREF
           linking. Carry that surviving row's own StageKey onto every row. */
        WinnerStageKey = FIRST_VALUE(ub.StageKey) OVER (
            PARTITION BY ub.GroupKey, ub.NormalizedFullAddress,
                COALESCE(ub.RealUnitNumber, N'#' + CONVERT(NVARCHAR(20), ub.StageKey))
            ORDER BY
                CASE ub.SourceSystem WHEN N'KDAT' THEN 0 ELSE 1 END,
                ub.StageKey
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        )
    FROM UnitBase ub
    INNER JOIN #ParentMap pm ON pm.GroupKey = ub.GroupKey
    INNER JOIN #BuildingMap bm
        ON bm.GroupKey = ub.GroupKey
       AND bm.NormalizedFullAddress = ub.NormalizedFullAddress
    WHERE ub.NeedsUnit = 1
)
/* A CTE is visible to only the one statement after it - materialize it once
   so both #UnitStageMap and #UnitSrc below can be built from the same rows. */
SELECT
    StageKey, GroupKey, PathType, NormalizedFullAddress, UnitNumber,
    ParentUPRID, BuildingUPRID, BuildingTableID, Rn, WinnerStageKey
INTO #UnitJoinedAll
FROM UnitJoined;

SELECT StageKey, WinnerStageKey INTO #UnitStageMap FROM #UnitJoinedAll;
CREATE UNIQUE INDEX UX_UnitStageMap_StageKey ON #UnitStageMap (StageKey);

SELECT
    StageKey, GroupKey, PathType, NormalizedFullAddress, UnitNumber,
    ParentUPRID, BuildingUPRID, BuildingTableID
INTO #UnitSrc
FROM #UnitJoinedAll
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

/* A newly arrived source row can describe an already loaded numbered Unit.
   Reuse that same structural Unit and attach its new source XREF to it.
   Never reuse on a placeholder UnitNumber (NULL or N'N/A') - those do not
   identify a physical unit, so each such row keeps its own separate Unit. */
/* Reuse the exact source-linked Unit first, including NULL/N/A values and
   Units reparented by a Condo-to-Complex repair above. */
INSERT INTO #UnitMap (StageKey, UnitUPRID, GroupKey)
SELECT src.StageKey, MIN(u.UPRID), MIN(src.GroupKey)
FROM #UnitSrc src
INNER JOIN #Stage st ON st.StageKey = src.StageKey
INNER JOIN dbo.EXTERNAL_IDENTIFIER_XREF x ON x.SourceSystem = st.SourceSystem
    AND x.IdentifierType = N'SOURCE_RECORD_ID' AND x.IdentifierValue = st.SourceRecordID
INNER JOIN dbo.UPR u ON u.UPRID = x.UPRID AND u.ParentUPRID = src.ParentUPRID
    AND u.EntityTypeID = @EtUnit
INNER JOIN dbo.UNIT un ON un.UPRID = u.UPRID AND un.BuildingID = src.BuildingTableID
GROUP BY src.StageKey;

INSERT INTO #UnitMap (StageKey, UnitUPRID, GroupKey)
SELECT src.StageKey, MIN(u.UPRID), MIN(src.GroupKey)
FROM #UnitSrc src
INNER JOIN dbo.UNIT un ON un.BuildingID = src.BuildingTableID AND un.UnitNumber = src.UnitNumber
INNER JOIN dbo.UPR u ON u.UPRID = un.UPRID
    AND u.ParentUPRID = src.ParentUPRID AND u.EntityTypeID = @EtUnit
WHERE src.UnitNumber IS NOT NULL AND src.UnitNumber <> N'N/A'
  AND NOT EXISTS (SELECT 1 FROM #UnitMap m WHERE m.StageKey = src.StageKey)
GROUP BY src.StageKey;

MERGE dbo.UPR AS t
USING (
    SELECT u.*
    FROM #UnitSrc u
    WHERE NOT EXISTS (SELECT 1 FROM #UnitMap m WHERE m.StageKey = u.StageKey)
      AND NOT EXISTS (
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
    /* Contact row is required; unavailable owner details remain NULL. */
    OrgName = CONVERT(VARCHAR(200), NULLIF(LTRIM(RTRIM(pm.OwnerName)), N''))
INTO #ContactSrc
FROM #ParentMap pm
WHERE EXISTS (
    SELECT 1 FROM #Stage s
    WHERE s.GroupKey = pm.GroupKey AND s.IsValid = 1 AND s.HasRequiredAddress = 1
);

/* Remove the previous account-as-owner fallback, without changing real names. */
UPDATE c SET OrganizationName = src.OrgName
FROM dbo.CONTACT c
INNER JOIN dbo.UPR_CONTACT uc ON uc.ContactID = c.ContactID AND uc.RoleTypeID = @RoleOwner
INNER JOIN #ContactSrc src ON src.ParentUPRID = uc.UPRID
INNER JOIN #ParentMap pm ON pm.UPRID = src.ParentUPRID
WHERE c.OrganizationName = pm.AccountNumber
  AND (src.OrgName IS NULL OR src.OrgName <> c.OrganizationName);

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
            NULLIF(LTRIM(RTRIM(s.UnitNumber)), N'')
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
/* Route through #UnitStageMap.WinnerStageKey, not a value match on
   UnitNumber: #UnitSrc.UnitNumber may be the materialized NULL/N'A'
   placeholder (never equal-matches su's raw value), and a stage row whose
   real value was collapsed onto another row's Unit is not itself present in
   #UnitSrc at all. Both cases must still resolve to the shared Unit. */
LEFT JOIN #UnitStageMap usm ON usm.StageKey = su.StageKey
LEFT JOIN #UnitSrc us ON us.StageKey = usm.WinnerStageKey
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

/* Level is the descendant's depth from the root (report LevelNo), not the
   distance from each ancestor. Derive it from ParentUPRID, not entity type:
   a Unit directly under a Condo is level 1; under its Building it is level 2.
   Walking only rooted trees also detects cycles without an infinite loop. */
IF OBJECT_ID('tempdb..#UPRLevels') IS NOT NULL DROP TABLE #UPRLevels;
CREATE TABLE #UPRLevels (UPRID BIGINT NOT NULL PRIMARY KEY, [Level] INT NOT NULL);
INSERT INTO #UPRLevels (UPRID, [Level])
SELECT UPRID, 0 FROM dbo.UPR WHERE ParentUPRID IS NULL;
DECLARE @LevelsAdded INT = 1;
WHILE @LevelsAdded > 0
BEGIN
    INSERT INTO #UPRLevels (UPRID, [Level])
    SELECT child.UPRID, parent.[Level] + 1
    FROM dbo.UPR child
    INNER JOIN #UPRLevels parent ON parent.UPRID = child.ParentUPRID
    WHERE NOT EXISTS (SELECT 1 FROM #UPRLevels seen WHERE seen.UPRID = child.UPRID);
    SET @LevelsAdded = @@ROWCOUNT;
END;
IF EXISTS (SELECT 1 FROM dbo.UPR u
           WHERE NOT EXISTS (SELECT 1 FROM #UPRLevels l WHERE l.UPRID = u.UPRID))
    THROW 50005, 'UPR hierarchy contains a cycle or an unreachable parent; cannot calculate closure levels.', 1;

/* Build the expected paths separately, then apply only real differences.
   Unchanged loads must not produce thousands of delete/reinsert audit events. */
IF OBJECT_ID('tempdb..#ExpectedClosure') IS NOT NULL DROP TABLE #ExpectedClosure;
CREATE TABLE #ExpectedClosure (
    AncestorUPRID BIGINT NOT NULL,
    DescendantUPRID BIGINT NOT NULL,
    [Level] INT NOT NULL,
    PRIMARY KEY (AncestorUPRID, DescendantUPRID)
);
INSERT INTO #ExpectedClosure (AncestorUPRID, DescendantUPRID, [Level])
SELECT UPRID, UPRID, [Level] FROM #UPRLevels;
DECLARE @ClosureAdded INT = 1;
WHILE @ClosureAdded > 0
BEGIN
    INSERT INTO #ExpectedClosure (AncestorUPRID, DescendantUPRID, [Level])
    SELECT c.AncestorUPRID, child.UPRID, l.[Level]
    FROM #ExpectedClosure c
    INNER JOIN dbo.UPR child ON child.ParentUPRID = c.DescendantUPRID
    INNER JOIN #UPRLevels l ON l.UPRID = child.UPRID
    WHERE NOT EXISTS (SELECT 1 FROM #ExpectedClosure x
        WHERE x.AncestorUPRID = c.AncestorUPRID AND x.DescendantUPRID = child.UPRID);
    SET @ClosureAdded = @@ROWCOUNT;
END;
DELETE c FROM dbo.UPR_CLOSURE c
WHERE NOT EXISTS (SELECT 1 FROM #ExpectedClosure e
    WHERE e.AncestorUPRID = c.AncestorUPRID AND e.DescendantUPRID = c.DescendantUPRID);
UPDATE c SET [Level] = e.[Level]
FROM dbo.UPR_CLOSURE c
INNER JOIN #ExpectedClosure e
    ON e.AncestorUPRID = c.AncestorUPRID AND e.DescendantUPRID = c.DescendantUPRID
WHERE c.[Level] IS NULL OR c.[Level] <> e.[Level];
INSERT INTO dbo.UPR_CLOSURE (AncestorUPRID, DescendantUPRID, [Level])
SELECT e.AncestorUPRID, e.DescendantUPRID, e.[Level] FROM #ExpectedClosure e
WHERE NOT EXISTS (SELECT 1 FROM dbo.UPR_CLOSURE c
    WHERE c.AncestorUPRID = e.AncestorUPRID AND c.DescendantUPRID = e.DescendantUPRID);

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.UPR_CLOSURE')
           AND name = N'Level' AND is_nullable = 1)
    ALTER TABLE dbo.UPR_CLOSURE ALTER COLUMN [Level] INT NOT NULL;
IF OBJECT_ID(N'dbo.CK_UPR_CLOSURE_Level', N'C') IS NULL
    ALTER TABLE dbo.UPR_CLOSURE WITH CHECK ADD CONSTRAINT CK_UPR_CLOSURE_Level CHECK ([Level] >= 0);

/* Link the same source address records to their parent and Units as well.
   This creates associations, not extra addresses or guessed address values. */
IF OBJECT_ID('tempdb..#HierarchyAddressLinks') IS NOT NULL DROP TABLE #HierarchyAddressLinks;
;WITH AddressLinks AS (
    SELECT pm.UPRID, ua.AddressID
    FROM #ParentMap pm
    INNER JOIN #BuildingMap bm ON bm.GroupKey = pm.GroupKey
    INNER JOIN dbo.UPR_ADDRESS ua ON ua.UPRID = bm.BuildingUPRID AND ua.IsPrimary = 1
    UNION
    SELECT un.UPRID, ua.AddressID
    FROM dbo.UNIT un
    INNER JOIN dbo.BUILDING b ON b.BuildingID = un.BuildingID
    INNER JOIN #BuildingMap bm ON bm.BuildingUPRID = b.UPRID
    INNER JOIN dbo.UPR_ADDRESS ua ON ua.UPRID = b.UPRID AND ua.IsPrimary = 1
)
SELECT UPRID, AddressID INTO #HierarchyAddressLinks FROM AddressLinks;

;WITH NumberedLinks AS (
    SELECT UPRID, AddressID, Rn = ROW_NUMBER() OVER (PARTITION BY UPRID ORDER BY AddressID)
    FROM #HierarchyAddressLinks
)
INSERT INTO dbo.UPR_ADDRESS (UPRID, AddressID, AddressRoleID, IsPrimary, EffectiveDate)
SELECT l.UPRID, l.AddressID, @AddrPhysical,
    CASE WHEN l.Rn = 1 AND NOT EXISTS (
        SELECT 1 FROM dbo.UPR_ADDRESS p WHERE p.UPRID = l.UPRID AND p.IsPrimary = 1
    ) THEN 1 ELSE 0 END,
    CONVERT(DATE, @Now)
FROM NumberedLinks l
WHERE NOT EXISTS (SELECT 1 FROM dbo.UPR_ADDRESS ua
    WHERE ua.UPRID = l.UPRID AND ua.AddressID = l.AddressID);

/* Restore a missing primary flag even when the parent/Unit association
   already existed and therefore did not need another INSERT above. */
;WITH PrimaryHierarchyAddress AS (
    SELECT ua.UPRID, UPRAddressID = MIN(ua.UPRAddressID)
    FROM #HierarchyAddressLinks l
    INNER JOIN dbo.UPR_ADDRESS ua ON ua.UPRID = l.UPRID AND ua.AddressID = l.AddressID
    WHERE NOT EXISTS (SELECT 1 FROM dbo.UPR_ADDRESS p WHERE p.UPRID = ua.UPRID AND p.IsPrimary = 1)
    GROUP BY ua.UPRID
)
UPDATE ua SET IsPrimary = 1
FROM dbo.UPR_ADDRESS ua
INNER JOIN PrimaryHierarchyAddress p ON p.UPRAddressID = ua.UPRAddressID;

/* Share each parent's source contact with its Building/Unit/ADU descendants. */
INSERT INTO dbo.UPR_CONTACT (UPRID, ContactID, RoleTypeID, EffectiveDate)
SELECT DISTINCT cl.DescendantUPRID, uc.ContactID, uc.RoleTypeID, CONVERT(DATE, @Now)
FROM #ParentMap pm
INNER JOIN dbo.UPR_CONTACT uc ON uc.UPRID = pm.UPRID AND uc.RoleTypeID = @RoleOwner
INNER JOIN dbo.UPR_CLOSURE cl ON cl.AncestorUPRID = pm.UPRID
WHERE cl.DescendantUPRID <> pm.UPRID
  AND NOT EXISTS (SELECT 1 FROM dbo.UPR_CONTACT existing
      WHERE existing.UPRID = cl.DescendantUPRID AND existing.ContactID = uc.ContactID
        AND existing.RoleTypeID = uc.RoleTypeID);

SET @UPRContactInserted = @UPRContactInserted + @@ROWCOUNT;
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

INSERT INTO dbo.AuditLog (EntityName, EntityKey, OperationType, ChangedBy, ChangedDate, ChangeSummary, RunID, SessionID)
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
     + N'; Closure=' + CONVERT(NVARCHAR(20), @ClosureRows)
     + N'; Classification=MA-FIRST-2026-09-15; Parcel=OPTIONAL-PARCEL-2026-09-16'
     + N'; Coordinates=SOURCE-PAIR-2026-09-16', @AuditRunID, @@SPID);
SET @AuditInserted = @@ROWCOUNT;

UPDATE dbo.UPR_LOAD_RUN
SET RunStatus = 'COMPLETED', FinishedAt = SYSDATETIME(),
    SourceRowsRead = @MARead + @SDATRead, RejectedRows = @InvalidRows
WHERE RunID = @AuditRunID;
COMMIT TRANSACTION;
EXEC sys.sp_set_session_context @key = N'UPR_AuditRunID', @value = @PreviousAuditRun;

PRINT N'================================================================';
PRINT N'UPR hierarchical load COMPLETE';
PRINT N'Audit RunID: ' + CONVERT(NVARCHAR(36), @AuditRunID);
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
PRINT N'Audit batch summaries        : ' + CONVERT(NVARCHAR(20), @AuditInserted);
PRINT N'Elapsed seconds              : '
    + CONVERT(NVARCHAR(20), DATEDIFF(SECOND, @BatchStart, SYSDATETIME()));
PRINT N'NOTE: Safe to re-run - existing UPRs are reused, not duplicated.';
PRINT N'================================================================';

/* Show actual committed row events for this run, including their full values.
   list_upr_audit.sql also offers a field-by-field view and edits outside loads. */
PRINT N'Staging classification - MA account decisions and source-row routing';
SELECT RunID = @AuditRunID, s.SourceSystem, s.SourceRecordID, s.AccountNumber,
    s.RawPropertyType, s.PropertyType AS EffectivePropertyType,
    s.NormalizedFullAddress, s.UnitNumber, s.CondoUnit,
    a.MARowCount, a.ValidMARowCount, s.DistinctAddrOnAccount AS MAStreetAddressCount,
    s.PathType, s.GroupKey, s.IsValid, s.ReviewReason, s.ClassificationReason
FROM #Stage s LEFT JOIN #AcctAddrCnt a ON a.AccountNumber = s.AccountNumber
ORDER BY s.AccountNumber, s.SourceSystem, s.SourceRecordID;

SELECT RunID = @AuditRunID, RunStatus = 'COMPLETED',
    RowsInserted = COALESCE(SUM(CASE WHEN OperationType = 'INSERT' THEN 1 ELSE 0 END), 0),
    RowsUpdated = COALESCE(SUM(CASE WHEN OperationType = 'UPDATE' THEN 1 ELSE 0 END), 0),
    RowsDeleted = COALESCE(SUM(CASE WHEN OperationType = 'DELETE' THEN 1 ELSE 0 END), 0)
FROM dbo.AuditLog WHERE RunID = @AuditRunID AND EntityName <> N'UPR_HIER_LOAD';
SELECT AuditID, RunID, EntityName AS TableName, EntityKey AS RecordKey,
    OperationType AS Action, ChangedDate, ChangedBy, OldValues, NewValues
FROM dbo.AuditLog WHERE RunID = @AuditRunID AND EntityName <> N'UPR_HIER_LOAD'
ORDER BY AuditID;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    DECLARE @ErrNum INT = ERROR_NUMBER();
    DECLARE @ErrLine INT = ERROR_LINE();
    DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
    IF @RunRecorded = 1
        EXEC sys.sp_executesql N'
            UPDATE dbo.UPR_LOAD_RUN SET RunStatus = ''FAILED'', FinishedAt = SYSDATETIME(),
                ErrorMessage = @err WHERE RunID = @id AND RunStatus = ''RUNNING'';',
            N'@id UNIQUEIDENTIFIER, @err NVARCHAR(4000)', @AuditRunID, @ErrMsg;
    EXEC sys.sp_set_session_context @key = N'UPR_AuditRunID', @value = @PreviousAuditRun;
    PRINT N'*** UPR hierarchical load FAILED ***';
    PRINT N'Error ' + CONVERT(NVARCHAR(20), @ErrNum)
        + N' at line ' + CONVERT(NVARCHAR(20), @ErrLine)
        + N': ' + @ErrMsg;
    THROW;
END CATCH;
GO
