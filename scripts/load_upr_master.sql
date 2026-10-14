/* RELEASE: UPR MAIN LOADER 2026-10-08 R9
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
    4) SDAT-only account: Condo -> Building -> Unit; account on Condo UPR.
       Shared accounts follow MA's Complex or uniquely matched MA group;
       unmatched/ambiguous shared SDAT rows go to Review_Q, never default Condo.
    5) SF / Warehouse / Office / Park / etc -> Property -> Building only, no Unit
       (not a dwelling-unit record type)
    6) Address via ADDRESS + UPR_ADDRESS only; Contact required when address valid
    7) Staging in temp tables after validate/normalize; print statistics
    8) AccountNumber required on every incoming record; no account -> reject to
       Review_Q (INSUFFICIENT_DATA), never written to UPR. Not unique on UPR
       (one account can span several UPR rows). CommunityName on COMPLEX only.
    9) MULTI/APT/CONDO rows resolve to Units. Real source Unit numbers are
       retained. An unambiguous blank MA/SDAT pair shares one Unit; other blank
       rows retain independent Units (MA N/A, SDAT NULL on new inserts).
       Never invent MA-<id>/SD-<id> unit labels.
   10) Missing/placeholder Parcel numbers stay NULL and do not cause Review_Q.

  Prerequisites: existing UPR/source schema and the client's nine-column AuditLog
  with REF_ENTITY_IDENTIFICATION. No audit-extension installation is required.
  Loader INSERT/UPDATE/DELETE changes are captured and written to AuditLog with
  readable text values. No audit support tables or trigger installer is required.
  Existing audit-writing triggers require review to avoid duplicate/JSON events.
  Historical audit rows are preserved; row auditing covers loader statements.
  Re-runnable: unchanged incoming data inserts no business rows (batch audit remains).

  October 2 closure correction is included in this MAIN script:
    - Level counts parent links within each ancestor/descendant pair (self = 0).
    - Ensures composite uniqueness and indexes for both traversal directions.
    - Reuses equivalent existing indexes, including the composite primary key.
    - Existing duplicate pairs stop the load with a diagnostic; no silent deletion.
  Run test/check_upr_closure_distance.sql after the load. No separate Level repair
  or manual edits to Step 12 are needed with this version.
  October 2 R2: supports the client schema without UPR_CONDO_LEGACY,
  AUDIT_LOG_CONTEXT, UPR_LOAD_RUN or the AUDIT_LOG compatibility view.

  October 5 R3: detects NewValue (client) or NewValues (prior project layout),
  preserves existing VARCHAR/NVARCHAR types, and never renames the audit column.

  October 5 R4: seeds required standard dictionary metadata; supports identity,
  default-generated and serialized manual INT entity IDs without renumbering.

  October 5 R5: preserves existing Level type/nullability and dependent indexes;
  no ALTER COLUMN or new closure CHECK constraint during loading.

  October 6 R6: supplies nullable manual audit IDs and validates the mapping
  before business loading and immediately before the audit INSERT.
  October 6 R7: checks audit INSERT metadata before business loading and verifies
  that the summary row was persisted before commit.

  October 6 R8: loader-owned row audit, readable before/after values, explicit UPR
  write statistics, and batched audit INSERTs. Existing history is not rewritten.

  October 8 R9: Condo Units now use their linked Building as ParentUPRID.
  Existing direct Condo -> Unit links are repaired only when UNIT.BuildingID
  identifies a Building under that same root Condo. IDs are preserved, repair
  is audited, and Step 12 recalculates pair distances. Inconsistent links stop
  with a diagnostic; no building is guessed from an address or example ID.

  EDIT USE database name to match your environment.
================================================================================
*/
USE UPRXDB_TEST;
GO
PRINT N'UPR MAIN LOADER 2026-10-08 R9';
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
/* Use a dedicated connection without a caller-owned transaction.
   Never roll back a caller's work. Failure details remain in Messages. */
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
        WHEN N'BOULEVARD' THEN N'BLVD' WHEN N'BLVD' THEN N'BLVD' WHEN N'BLV' THEN N'BLVD'
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

/* Preserve long identifiers; pad short numeric MA/SDAT accounts to eight digits. */
CREATE OR ALTER FUNCTION dbo.fn_UPR_NormalizeSDATAccount (@acct NVARCHAR(50))
RETURNS NVARCHAR(50)
AS
BEGIN
    DECLARE @s NVARCHAR(50) = NULLIF(LTRIM(RTRIM(ISNULL(@acct, N''))), N'');
    IF @s IS NULL RETURN NULL;
    DECLARE @digits NVARCHAR(50) = REPLACE(REPLACE(@s, N'-', N''), N' ', N'');
    IF @digits <> N'' AND @digits NOT LIKE N'%[^0-9]%'
    BEGIN
        IF LEN(@digits) < 8 RETURN REPLICATE(N'0', 8 - LEN(@digits)) + @digits;
        RETURN @digits;
    END;
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
   actual pair distances without changing the column definition afterward. */
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

/* Results tab shows the statistical report. Set to 1 to also list every
   staged source row and every audited row change (very large on full loads). */
DECLARE @ShowDetailResults BIT = 0;

DECLARE @RunUser     NVARCHAR(100) = SUSER_SNAME();
DECLARE @AuditUser   NVARCHAR(100) = LEFT(COALESCE(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(128), SUSER_SNAME()))), N''), N'SYSTEM'),100);
/* Truncated to the second: assigning SYSDATETIME() to DATETIME2(0) ROUNDS,
   which can produce a timestamp in the future and trip <= SYSDATETIME() checks */
DECLARE @Now         DATETIME2(0)  = CONVERT(DATETIME2(0), CONVERT(VARCHAR(19), SYSDATETIME(), 126));
DECLARE @BatchStart  DATETIME2(0)  = SYSDATETIME();
DECLARE @AuditRunID UNIQUEIDENTIFIER = NEWID();
DECLARE @PreviousAuditRun SQL_VARIANT = SESSION_CONTEXT(N'UPR_AuditRunID');
DECLARE @SummaryEntityID INT;
/* Use only these two known column names. No schema migration is performed. */
DECLARE @AuditNewColumn SYSNAME = CASE
    WHEN COL_LENGTH(N'dbo.AuditLog',N'NewValue') IS NOT NULL THEN N'NewValue'
    WHEN COL_LENGTH(N'dbo.AuditLog',N'NewValues') IS NOT NULL THEN N'NewValues' END;
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

/* Core client schema: optional support objects are never bound statically.
   If an optional object is present but incomplete, report that condition rather
   than treating corrupted installation metadata as an absent extension. */
IF OBJECT_ID(N'dbo.AuditLog',N'U') IS NULL
 OR EXISTS(SELECT 1 FROM (VALUES(N'AuditID'),(N'UPRID'),(N'EntityNameID'),(N'EntityRecordID'),
    (N'OperationType'),(N'ChangedBy'),(N'ChangedDate'),(N'OldValues')) v(ColumnName)
    WHERE COL_LENGTH(N'dbo.AuditLog',v.ColumnName) IS NULL)
 OR @AuditNewColumn IS NULL
 OR COL_LENGTH(N'dbo.REF_ENTITY_IDENTIFICATION',N'EntityID') IS NULL
 OR COL_LENGTH(N'dbo.REF_ENTITY_IDENTIFICATION',N'EntityName') IS NULL
 OR COL_LENGTH(N'dbo.UPR_CLOSURE',N'AncestorUPRID') IS NULL
    THROW 50004,'Expected the client AuditLog columns, entity dictionary and original closure column names. Run check_upr_client_schema.sql for details.',1;
IF COL_LENGTH(N'dbo.AuditLog',N'NewValue') IS NOT NULL
 AND COL_LENGTH(N'dbo.AuditLog',N'NewValues') IS NOT NULL
    THROW 50004,'AuditLog contains both NewValue and NewValues. Confirm the intended payload column before loading; no column was changed.',1;
PRINT N'Audit payload column: dbo.AuditLog.' + QUOTENAME(@AuditNewColumn);
/* AUDIT_INSERT_PREFLIGHT_BEGIN
   An omitted NOT NULL column without a default would fail only at Step14.
   Check the real table, including client-added columns, before loading rows. */
IF EXISTS(SELECT 1 FROM sys.columns c
    WHERE c.object_id=OBJECT_ID(N'dbo.AuditLog') AND c.is_nullable=0
      AND c.is_identity=0 AND c.is_computed=0 AND c.default_object_id=0
      AND c.system_type_id<>189 AND c.generated_always_type=0
      AND c.name NOT IN(N'EntityNameID',N'EntityRecordID',N'OperationType',N'ChangedBy',N'ChangedDate',@AuditNewColumn))
BEGIN
    SELECT c.name AS UnsuppliedRequiredAuditColumn,TYPE_NAME(c.system_type_id) AS DataType
    FROM sys.columns c
    WHERE c.object_id=OBJECT_ID(N'dbo.AuditLog') AND c.is_nullable=0
      AND c.is_identity=0 AND c.is_computed=0 AND c.default_object_id=0
      AND c.system_type_id<>189 AND c.generated_always_type=0
      AND c.name NOT IN(N'EntityNameID',N'EntityRecordID',N'OperationType',N'ChangedBy',N'ChangedDate',@AuditNewColumn);
    THROW 50004,'AuditLog has a required column the summary INSERT cannot supply. See UnsuppliedRequiredAuditColumn; business loading has not started.',1;
END;
IF NOT EXISTS(SELECT 1 FROM sys.columns c
    WHERE c.object_id=OBJECT_ID(N'dbo.AuditLog') AND c.name=N'AuditID'
      AND c.is_identity=1 AND c.system_type_id=56)
    THROW 50004,'AuditLog.AuditID must use the supplied INT IDENTITY layout. Business loading has not started.',1;
IF EXISTS(SELECT 1 FROM sys.columns c
    WHERE c.object_id=OBJECT_ID(N'dbo.AuditLog')
      AND c.name IN(N'UPRID',N'OldValues',N'EntityNameID',N'EntityRecordID',N'OperationType',N'ChangedBy',N'ChangedDate',@AuditNewColumn)
      AND (c.is_identity=1 OR c.is_computed=1 OR c.system_type_id=189 OR c.generated_always_type<>0))
    THROW 50004,'AuditLog summary target includes a generated or computed column; business loading has not started.',1;
/* AUDIT_INSERT_PREFLIGHT_END */

/* Loader-owned auditing must not duplicate an existing audit writer or allow
   an older JSON-producing trigger to add unreadable events. Retain every trigger;
   report conflicts before any business writes instead of disabling client code. */
IF EXISTS(SELECT 1 FROM sys.triggers tr
    WHERE tr.is_disabled=0 AND tr.parent_class=1 AND OBJECT_SCHEMA_NAME(tr.parent_id)=N'dbo'
      AND OBJECT_NAME(tr.parent_id) IN (N'REF_ENTITYTYPE',N'REF_PROPERTYTYPE',N'REF_ROLETYPE',N'REF_ADDRESSROLE',N'REF_CONTACTTYPE',N'UPR',N'ADDRESS',N'COMPLEX',N'PROPERTY',N'CONDO',N'BUILDING',N'UNIT',N'CONTACT',N'UPR_ADDRESS',N'UPR_CONTACT',N'EXTERNAL_IDENTIFIER_XREF',N'UPR_CLOSURE',N'UPRMATCHREVIEW_Q',N'UPRSTATUSHISTORY',N'AuditLog',N'REF_ENTITY_IDENTIFICATION')
      AND (OBJECT_DEFINITION(tr.object_id) IS NULL OR OBJECT_DEFINITION(tr.object_id) LIKE N'%FOR JSON%'
        OR OBJECT_DEFINITION(tr.object_id) LIKE N'%AuditLog%' OR OBJECT_DEFINITION(tr.object_id) LIKE N'%AUDIT_LOG%'))
BEGIN
    SELECT tr.name AS AuditTriggerToReview,OBJECT_NAME(tr.parent_id) AS TableName,
        OBJECT_DEFINITION(tr.object_id) AS TriggerDefinition
    FROM sys.triggers tr
    WHERE tr.is_disabled=0 AND tr.parent_class=1 AND OBJECT_SCHEMA_NAME(tr.parent_id)=N'dbo'
      AND OBJECT_NAME(tr.parent_id) IN (N'REF_ENTITYTYPE',N'REF_PROPERTYTYPE',N'REF_ROLETYPE',N'REF_ADDRESSROLE',N'REF_CONTACTTYPE',N'UPR',N'ADDRESS',N'COMPLEX',N'PROPERTY',N'CONDO',N'BUILDING',N'UNIT',N'CONTACT',N'UPR_ADDRESS',N'UPR_CONTACT',N'EXTERNAL_IDENTIFIER_XREF',N'UPR_CLOSURE',N'UPRMATCHREVIEW_Q',N'UPRSTATUSHISTORY',N'AuditLog',N'REF_ENTITY_IDENTIFICATION')
      AND (OBJECT_DEFINITION(tr.object_id) IS NULL OR OBJECT_DEFINITION(tr.object_id) LIKE N'%FOR JSON%'
        OR OBJECT_DEFINITION(tr.object_id) LIKE N'%AuditLog%' OR OBJECT_DEFINITION(tr.object_id) LIKE N'%AUDIT_LOG%');
    THROW 50004,'Existing audit-writing or unreadable triggers require review before loader-owned auditing. No trigger was changed.',1;
END;
EXEC sys.sp_set_session_context @key = N'UPR_AuditRunID', @value = @AuditRunID;

PRINT N'================================================================';
PRINT N'UPR hierarchical load starting: ' + CONVERT(NVARCHAR(30), @BatchStart, 121);
PRINT N'Staging rules: MA-FIRST-2026-09-15';
PRINT N'Parcel rules: OPTIONAL-PARCEL-2026-09-16';
PRINT N'Coordinate rules: SOURCE-PAIR-2026-09-16';
PRINT N'Duplicate rules: MA-SDAT-OVERLAP-2026-09-23';
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

BEGIN TRANSACTION;
/* Create the batch-summary dictionary entry using the client's actual defaults.
   Hold the small dictionary exclusively through this transaction so manual INT
   key allocation and the name check cannot race with another writer. Never
   renumber existing entities or change dictionary columns/defaults. */
IF OBJECT_ID('tempdb..#AuditEntityMap') IS NOT NULL DROP TABLE #AuditEntityMap;
CREATE TABLE #AuditEntityMap(EntityName SYSNAME NOT NULL PRIMARY KEY,EntityID INT NULL);
INSERT #AuditEntityMap(EntityName) VALUES
    (N'UPR_HIER_LOAD'),
    (N'REF_ENTITYTYPE'),
    (N'REF_PROPERTYTYPE'),
    (N'REF_ROLETYPE'),
    (N'REF_ADDRESSROLE'),
    (N'REF_CONTACTTYPE'),
    (N'UPR'),
    (N'ADDRESS'),
    (N'COMPLEX'),
    (N'PROPERTY'),
    (N'CONDO'),
    (N'BUILDING'),
    (N'UNIT'),
    (N'CONTACT'),
    (N'UPR_ADDRESS'),
    (N'UPR_CONTACT'),
    (N'EXTERNAL_IDENTIFIER_XREF'),
    (N'UPR_CLOSURE'),
    (N'UPRMATCHREVIEW_Q'),
    (N'UPRSTATUSHISTORY');
DECLARE @DictionaryRequired TABLE(ColumnName SYSNAME PRIMARY KEY,TypeID INT);
DECLARE @AuditEntityName SYSNAME,@AuditEntityDescription VARCHAR(250),@ResolvedAuditEntityID INT;
DECLARE AuditEntityNames CURSOR LOCAL FAST_FORWARD FOR SELECT EntityName FROM #AuditEntityMap ORDER BY EntityName;
OPEN AuditEntityNames;
FETCH NEXT FROM AuditEntityNames INTO @AuditEntityName;
WHILE @@FETCH_STATUS=0
BEGIN
    PRINT N'Resolving audit entity: '+@AuditEntityName;
    SET @ResolvedAuditEntityID=NULL;
    SET @AuditEntityDescription=CASE WHEN @AuditEntityName=N'UPR_HIER_LOAD'
        THEN 'Load batch summary; EntityRecordID 0' ELSE 'Loader row changes; readable before and after values' END;
DECLARE @SummaryMappingRows INT;
SELECT @SummaryMappingRows=COUNT(*)
FROM dbo.REF_ENTITY_IDENTIFICATION WITH(TABLOCKX,HOLDLOCK)
WHERE EntityName=@AuditEntityName;
IF @SummaryMappingRows>1
    THROW 50004,'Audit entity has duplicate entity dictionary names. Resolve the mapping before loading.',1;
IF NOT EXISTS(SELECT 1 FROM sys.columns
    WHERE object_id=OBJECT_ID(N'dbo.REF_ENTITY_IDENTIFICATION') AND name=N'EntityID' AND system_type_id=56)
    THROW 50004,'Audit entity dictionary EntityID must be INT. Return its actual layout before loading.',1;
DECLARE @ManualDictionaryID BIT=CASE WHEN EXISTS(SELECT 1 FROM sys.columns
    WHERE object_id=OBJECT_ID(N'dbo.REF_ENTITY_IDENTIFICATION') AND name=N'EntityID'
      AND is_identity=0 AND is_computed=0 AND default_object_id=0) THEN 1 ELSE 0 END;
DECLARE @NextEntityID INT=NULL;
DECLARE @LargestEntityID BIGINT;
/* A nullable manual key still needs a value: AuditLog.EntityNameID is NOT NULL.
   Repair only this loader's single NULL mapping; never renumber a non-NULL ID. */
IF @ManualDictionaryID=1 AND (@SummaryMappingRows=0 OR EXISTS(
    SELECT 1 FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityName=@AuditEntityName AND EntityID IS NULL))
BEGIN
    SELECT @LargestEntityID=MAX(CONVERT(BIGINT,EntityID))
    FROM dbo.REF_ENTITY_IDENTIFICATION WITH(TABLOCKX,HOLDLOCK);
    IF @LargestEntityID>=2147483647
        THROW 50004,'Entity dictionary has no higher available INT ID. Existing IDs were preserved.',1;
    SET @NextEntityID=CONVERT(INT,CASE WHEN ISNULL(@LargestEntityID,0)<1 THEN 1 ELSE @LargestEntityID+1 END);
    IF @SummaryMappingRows=1
    BEGIN
        UPDATE dbo.REF_ENTITY_IDENTIFICATION SET EntityID=@NextEntityID
        WHERE EntityName=@AuditEntityName AND EntityID IS NULL;
        PRINT N'Repaired NULL EntityID on the single Audit entity mapping; existing non-NULL IDs were preserved.';
    END;
END;
IF @SummaryMappingRows=0
BEGIN
    DELETE FROM @DictionaryRequired;
    INSERT @DictionaryRequired(ColumnName,TypeID)
    SELECT name,system_type_id FROM sys.columns
    WHERE object_id=OBJECT_ID(N'dbo.REF_ENTITY_IDENTIFICATION')
      AND name<>N'EntityName' AND (is_nullable=0 OR name=N'EntityID') AND is_identity=0 AND is_computed=0
      AND default_object_id=0 AND system_type_id<>189;
    IF EXISTS(SELECT 1 FROM @DictionaryRequired
        WHERE ColumnName NOT IN(N'EntityID',N'EntityDescription',N'IsActive',N'CreatedDate',N'CreatedBy'))
    BEGIN
        SELECT ColumnName AS UnmappedRequiredDictionaryColumn,TYPE_NAME(TypeID) AS DataType
        FROM @DictionaryRequired
        WHERE ColumnName NOT IN(N'EntityID',N'EntityDescription',N'IsActive',N'CreatedDate',N'CreatedBy');
        THROW 50004,'Entity dictionary has unfamiliar required fields. See UnmappedRequiredDictionaryColumn results; no dictionary row was inserted.',1;
    END;
    DECLARE @DictionaryInsertColumns NVARCHAR(MAX)=N'[EntityName]';
    DECLARE @DictionaryInsertValues NVARCHAR(MAX)=N'@name';
    IF @ManualDictionaryID=1
    BEGIN
        SET @DictionaryInsertColumns+=N',[EntityID]';
        SET @DictionaryInsertValues+=N',@id';
    END;
    IF EXISTS(SELECT 1 FROM @DictionaryRequired WHERE ColumnName=N'EntityDescription')
    BEGIN
        SET @DictionaryInsertColumns+=N',[EntityDescription]';
        SET @DictionaryInsertValues+=N',@description';
    END;
    IF EXISTS(SELECT 1 FROM @DictionaryRequired WHERE ColumnName=N'IsActive')
    BEGIN
        SET @DictionaryInsertColumns+=N',[IsActive]';
        SET @DictionaryInsertValues+=N',@active';
    END;
    IF EXISTS(SELECT 1 FROM @DictionaryRequired WHERE ColumnName=N'CreatedDate')
    BEGIN
        SET @DictionaryInsertColumns+=N',[CreatedDate]';
        SET @DictionaryInsertValues+=N',@created';
    END;
    IF EXISTS(SELECT 1 FROM @DictionaryRequired WHERE ColumnName=N'CreatedBy')
    BEGIN
        SET @DictionaryInsertColumns+=N',[CreatedBy]';
        SET @DictionaryInsertValues+=N',@creator';
    END;
    DECLARE @DictionaryInsertSql NVARCHAR(MAX)=N'INSERT INTO dbo.REF_ENTITY_IDENTIFICATION ('
        +@DictionaryInsertColumns+N') VALUES ('+@DictionaryInsertValues+N');';
    EXEC sys.sp_executesql @DictionaryInsertSql,
        N'@name VARCHAR(100),@id INT,@description VARCHAR(250),@active BIT,@created DATETIME2(0),@creator NVARCHAR(100)',
        @name=@AuditEntityName,@id=@NextEntityID,@description=@AuditEntityDescription,
        @active=1,@created=@Now,@creator=@AuditUser;
    PRINT N'Created the Audit entity dictionary entry; existing entity IDs were preserved.';
END;
IF (SELECT COUNT(*) FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityName=@AuditEntityName)<>1
    THROW 50004,'Audit entity must have one unambiguous entity dictionary mapping.',1;
SELECT @ResolvedAuditEntityID=EntityID FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityName=@AuditEntityName;
IF @ResolvedAuditEntityID IS NULL
    THROW 50004,'Audit entity EntityID is NULL after dictionary resolution. Check its default/computed definition and triggers; business loading has not started.',1;
IF (SELECT COUNT(*) FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityID=@ResolvedAuditEntityID)<>1
    THROW 50004,'Audit entity EntityID is shared by multiple dictionary rows. Resolve the mapping before loading.',1;
PRINT N'Audit mapping verified: ' + @AuditEntityName + N' EntityID=' + CONVERT(NVARCHAR(20),@ResolvedAuditEntityID);

    UPDATE #AuditEntityMap SET EntityID=@ResolvedAuditEntityID WHERE EntityName=@AuditEntityName;
    FETCH NEXT FROM AuditEntityNames INTO @AuditEntityName;
END;
CLOSE AuditEntityNames;
DEALLOCATE AuditEntityNames;
SELECT @SummaryEntityID=EntityID FROM #AuditEntityMap WHERE EntityName=N'UPR_HIER_LOAD';
PRINT N'Loader audit mode: row changes and batch summary are written directly to the existing AuditLog as readable text.';
/* Reject existing duplicate pairs before loading business rows. Hold these locks
   through Step 12, which ensures pair uniqueness and both index directions after
   any legacy Level backfill. Individual ancestor/descendant IDs are not unique.
   A later load failure rolls back the transaction, including newly added indexes. */
DECLARE @ClosureObjectID INT=OBJECT_ID(N'dbo.UPR_CLOSURE');
IF EXISTS(SELECT 1 FROM dbo.UPR_CLOSURE WITH(UPDLOCK,HOLDLOCK)
          GROUP BY AncestorUPRID,DescendantUPRID HAVING COUNT_BIG(*)>1)
BEGIN
    SELECT TOP(20) AncestorUPRID,DescendantUPRID,COUNT_BIG(*) AS DuplicateRows
    FROM dbo.UPR_CLOSURE GROUP BY AncestorUPRID,DescendantUPRID
    HAVING COUNT_BIG(*)>1 ORDER BY AncestorUPRID,DescendantUPRID;
    THROW 50006,'UPR_CLOSURE contains duplicate ancestor/descendant pairs. Load stopped; review the reported duplicates before rerunning.',1;
END;

PRINT N'Step 0 complete - required tables/functions present.';

/* ============================================================================
   1. SEED / ENSURE REF codes used by load
   ============================================================================ */
/* Statement OUTPUT captures changes without assuming audit triggers exist.
   Values are readable labeled text; the closure pair is retained in both images. */
IF OBJECT_ID('tempdb..#AuditEvents') IS NOT NULL DROP TABLE #AuditEvents;
CREATE TABLE #AuditEvents(
    EventID BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    EntityName SYSNAME NOT NULL,UPRID BIGINT NULL,EntityRecordID BIGINT NOT NULL,
    OperationType VARCHAR(20) NOT NULL,OldValues NVARCHAR(MAX) NULL,NewValue NVARCHAR(MAX) NULL
);
DECLARE @AuditDmlRows INT=0;
PRINT N'Step 1: Ensure REF entity / role / address / contact / property types...';

IF NOT EXISTS (SELECT 1 FROM dbo.REF_ENTITYTYPE WHERE Description = N'Complex')
    INSERT INTO dbo.REF_ENTITYTYPE (Description)
OUTPUT N'REF_ENTITYTYPE',CAST(NULL AS BIGINT),inserted.[EntityTypeID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'EntityTypeID = ' + CASE WHEN inserted.[EntityTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EntityTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Description = ' + CASE WHEN inserted.[Description] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[Description],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
VALUES (N'Complex');
IF NOT EXISTS (SELECT 1 FROM dbo.REF_ENTITYTYPE WHERE Description = N'Property')
    INSERT INTO dbo.REF_ENTITYTYPE (Description)
OUTPUT N'REF_ENTITYTYPE',CAST(NULL AS BIGINT),inserted.[EntityTypeID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'EntityTypeID = ' + CASE WHEN inserted.[EntityTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EntityTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Description = ' + CASE WHEN inserted.[Description] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[Description],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
VALUES (N'Property');
IF NOT EXISTS (SELECT 1 FROM dbo.REF_ENTITYTYPE WHERE Description = N'Building')
    INSERT INTO dbo.REF_ENTITYTYPE (Description)
OUTPUT N'REF_ENTITYTYPE',CAST(NULL AS BIGINT),inserted.[EntityTypeID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'EntityTypeID = ' + CASE WHEN inserted.[EntityTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EntityTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Description = ' + CASE WHEN inserted.[Description] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[Description],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
VALUES (N'Building');
IF NOT EXISTS (SELECT 1 FROM dbo.REF_ENTITYTYPE WHERE Description = N'Unit')
    INSERT INTO dbo.REF_ENTITYTYPE (Description)
OUTPUT N'REF_ENTITYTYPE',CAST(NULL AS BIGINT),inserted.[EntityTypeID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'EntityTypeID = ' + CASE WHEN inserted.[EntityTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EntityTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Description = ' + CASE WHEN inserted.[Description] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[Description],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
VALUES (N'Unit');
IF NOT EXISTS (SELECT 1 FROM dbo.REF_ENTITYTYPE WHERE Description = N'Condo')
    INSERT INTO dbo.REF_ENTITYTYPE (Description)
OUTPUT N'REF_ENTITYTYPE',CAST(NULL AS BIGINT),inserted.[EntityTypeID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'EntityTypeID = ' + CASE WHEN inserted.[EntityTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EntityTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Description = ' + CASE WHEN inserted.[Description] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[Description],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
VALUES (N'Condo');
IF NOT EXISTS (SELECT 1 FROM dbo.REF_ENTITYTYPE WHERE Description = N'ADU')
    INSERT INTO dbo.REF_ENTITYTYPE (Description)
OUTPUT N'REF_ENTITYTYPE',CAST(NULL AS BIGINT),inserted.[EntityTypeID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'EntityTypeID = ' + CASE WHEN inserted.[EntityTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EntityTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Description = ' + CASE WHEN inserted.[Description] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[Description],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
VALUES (N'ADU');

IF NOT EXISTS (SELECT 1 FROM dbo.REF_ROLETYPE WHERE RoleTypeCode = N'OWNER')
    INSERT INTO dbo.REF_ROLETYPE (RoleTypeCode, Description)
OUTPUT N'REF_ROLETYPE',CAST(NULL AS BIGINT),inserted.[RoleTypeID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'RoleTypeID = ' + CASE WHEN inserted.[RoleTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[RoleTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'RoleTypeCode = ' + CASE WHEN inserted.[RoleTypeCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[RoleTypeCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Description = ' + CASE WHEN inserted.[Description] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[Description],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
VALUES (N'OWNER', N'Owner');

IF NOT EXISTS (SELECT 1 FROM dbo.REF_ADDRESSROLE WHERE AddressRoleCode = N'PHYSICAL')
    INSERT INTO dbo.REF_ADDRESSROLE (AddressRoleCode, Description)
OUTPUT N'REF_ADDRESSROLE',CAST(NULL AS BIGINT),inserted.[AddressRoleID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'AddressRoleID = ' + CASE WHEN inserted.[AddressRoleID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AddressRoleID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AddressRoleCode = ' + CASE WHEN inserted.[AddressRoleCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AddressRoleCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Description = ' + CASE WHEN inserted.[Description] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[Description],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
VALUES (N'PHYSICAL', N'Physical Address');

IF NOT EXISTS (SELECT 1 FROM dbo.REF_CONTACTTYPE WHERE ContactTypeCode = N'ORGANIZATION')
    INSERT INTO dbo.REF_CONTACTTYPE (ContactTypeCode, Description)
OUTPUT N'REF_CONTACTTYPE',CAST(NULL AS BIGINT),inserted.[ContactTypeID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'ContactTypeID = ' + CASE WHEN inserted.[ContactTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ContactTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ContactTypeCode = ' + CASE WHEN inserted.[ContactTypeCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ContactTypeCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Description = ' + CASE WHEN inserted.[Description] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[Description],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
VALUES (N'ORGANIZATION', N'Organization');

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

OUTPUT N'REF_PROPERTYTYPE',CAST(NULL AS BIGINT),inserted.[PropertyTypeID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'PropertyTypeID = ' + CASE WHEN inserted.[PropertyTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[PropertyTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'PropertyTypeCode = ' + CASE WHEN inserted.[PropertyTypeCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[PropertyTypeCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'PropertyTypeName = ' + CASE WHEN inserted.[PropertyTypeName] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[PropertyTypeName],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AllowsBuildings = ' + CASE WHEN inserted.[AllowsBuildings] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AllowsBuildings],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AllowsUnits = ' + CASE WHEN inserted.[AllowsUnits] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AllowsUnits],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'DeletedInd = ' + CASE WHEN inserted.[DeletedInd] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[DeletedInd],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'CreationUserID = ' + CASE WHEN inserted.[CreationUserID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[CreationUserID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'CreationDate = ' + CASE WHEN inserted.[CreationDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[CreationDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'LastUpdatedUserID = ' + CASE WHEN inserted.[LastUpdatedUserID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[LastUpdatedUserID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'LastUpdatedDate = ' + CASE WHEN inserted.[LastUpdatedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[LastUpdatedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
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

/* CONDO_UNIT_REPAIR_BEGIN
   October 8: normalize existing direct Condo -> Unit links BEFORE source reuse
   and duplicate matching. UNIT.BuildingID is the only mapping authority here.
   This runs inside the main load/audit transaction; errors roll it back. */
IF OBJECT_ID('tempdb..#CondoUnitParentRepair') IS NOT NULL DROP TABLE #CondoUnitParentRepair;
/* CONDO_UNIT_CANDIDATES_BEGIN */
SELECT u.UPRID AS UnitUPRID,u.ParentUPRID AS OldParentUPRID,un.BuildingID,
    b.UPRID AS BuildingUPRID,bu.ParentUPRID AS BuildingParentUPRID,
    Issue=CASE
        WHEN (SELECT COUNT(*) FROM dbo.UNIT n WHERE n.UPRID=u.UPRID)<>1
            THEN N'Unit must have exactly one UNIT record'
        WHEN b.UPRID IS NULL OR bu.UPRID IS NULL THEN N'UNIT.BuildingID has no linked Building UPR'
        WHEN bu.EntityTypeID<>@EtBuilding THEN N'Linked Building UPR has the wrong entity type'
        WHEN co.ParentUPRID IS NOT NULL THEN N'Condo is not a root; review hierarchy before repair'
        WHEN bu.ParentUPRID IS NULL OR bu.ParentUPRID<>co.UPRID THEN N'Linked Building is not under the same Condo'
        WHEN EXISTS(SELECT 1 FROM dbo.UPR child WHERE child.ParentUPRID=u.UPRID)
            THEN N'Unit has children; review before reparenting'
        ELSE NULL END
INTO #CondoUnitParentRepair
FROM dbo.UPR u JOIN dbo.UPR co ON co.UPRID=u.ParentUPRID AND co.EntityTypeID=@EtCondo
LEFT JOIN dbo.UNIT un ON un.UPRID=u.UPRID
LEFT JOIN dbo.BUILDING b ON b.BuildingID=un.BuildingID
LEFT JOIN dbo.UPR bu ON bu.UPRID=b.UPRID
WHERE u.EntityTypeID=@EtUnit;
/* CONDO_UNIT_CANDIDATES_END */
IF EXISTS(SELECT 1 FROM #CondoUnitParentRepair WHERE Issue IS NOT NULL)
BEGIN
    SELECT UnitUPRID,OldParentUPRID,BuildingID,BuildingUPRID,BuildingParentUPRID,Issue
    FROM #CondoUnitParentRepair WHERE Issue IS NOT NULL ORDER BY UnitUPRID;
    THROW 50008,'Cannot safely repair a direct Condo-to-Unit parent. Review the Unit/Building diagnostic; the transaction is rolled back.',1;
END;
CREATE UNIQUE CLUSTERED INDEX IX_CondoUnitParentRepair ON #CondoUnitParentRepair(UnitUPRID);
UPDATE u SET ParentUPRID=r.BuildingUPRID,UpdatedBy=@RunUser,UpdatedDate=@Now
OUTPUT N'UPR',inserted.[UPRID],inserted.[UPRID],'UPDATE',
    CONVERT(NVARCHAR(MAX),N'') + N'UPRID = ' + CASE WHEN deleted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ParentUPRID = ' + CASE WHEN deleted.[ParentUPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ParentUPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EntityTypeID = ' + CASE WHEN deleted.[EntityTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[EntityTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AccountNumber = ' + CASE WHEN deleted.[AccountNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[AccountNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN deleted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'CreatedBy = ' + CASE WHEN deleted.[CreatedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[CreatedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedDate = ' + CASE WHEN deleted.[UpdatedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UpdatedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedBy = ' + CASE WHEN deleted.[UpdatedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UpdatedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CONVERT(NVARCHAR(MAX),N'') + N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ParentUPRID = ' + CASE WHEN inserted.[ParentUPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ParentUPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EntityTypeID = ' + CASE WHEN inserted.[EntityTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EntityTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AccountNumber = ' + CASE WHEN inserted.[AccountNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AccountNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN inserted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'CreatedBy = ' + CASE WHEN inserted.[CreatedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[CreatedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedDate = ' + CASE WHEN inserted.[UpdatedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UpdatedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedBy = ' + CASE WHEN inserted.[UpdatedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UpdatedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
FROM dbo.UPR u JOIN #CondoUnitParentRepair r ON r.UnitUPRID=u.UPRID
WHERE u.ParentUPRID=r.OldParentUPRID;
DECLARE @CondoUnitsReparented INT=@@ROWCOUNT;
PRINT N'Existing Condo units moved under their linked Building: '+CONVERT(NVARCHAR(20),@CondoUnitsReparented);
/* CONDO_UNIT_REPAIR_END */

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
            WHEN N'BOULEVARD' THEN N'BLVD' WHEN N'BLVD' THEN N'BLVD' WHEN N'BLV' THEN N'BLVD'
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

OUTPUT N'REF_PROPERTYTYPE',CAST(NULL AS BIGINT),inserted.[PropertyTypeID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'PropertyTypeID = ' + CASE WHEN inserted.[PropertyTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[PropertyTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'PropertyTypeCode = ' + CASE WHEN inserted.[PropertyTypeCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[PropertyTypeCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'PropertyTypeName = ' + CASE WHEN inserted.[PropertyTypeName] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[PropertyTypeName],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AllowsBuildings = ' + CASE WHEN inserted.[AllowsBuildings] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AllowsBuildings],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AllowsUnits = ' + CASE WHEN inserted.[AllowsUnits] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AllowsUnits],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'DeletedInd = ' + CASE WHEN inserted.[DeletedInd] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[DeletedInd],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'CreationUserID = ' + CASE WHEN inserted.[CreationUserID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[CreationUserID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'CreationDate = ' + CASE WHEN inserted.[CreationDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[CreationDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'LastUpdatedUserID = ' + CASE WHEN inserted.[LastUpdatedUserID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[LastUpdatedUserID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'LastUpdatedDate = ' + CASE WHEN inserted.[LastUpdatedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[LastUpdatedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
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
            WHEN N'BOULEVARD' THEN N'BLVD' WHEN N'BLVD' THEN N'BLVD' WHEN N'BLV' THEN N'BLVD'
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

/* SEARCH-002: do not silently split an existing hierarchy whose old normalizer
   discarded account digits. Reconcile affected source links/accounts first. */
IF EXISTS (
    SELECT 1 FROM #Stage s
    JOIN dbo.EXTERNAL_IDENTIFIER_XREF x ON x.SourceSystem = s.SourceSystem
        AND x.IdentifierType = N'SOURCE_RECORD_ID' AND x.IdentifierValue = s.SourceRecordID
    JOIN dbo.UPR_CLOSURE cl ON cl.DescendantUPRID = x.UPRID
    JOIN dbo.UPR u ON u.UPRID = cl.AncestorUPRID
    WHERE (LEN(s.AccountNumber) BETWEEN 9 AND 12
      AND s.AccountNumber NOT LIKE N'%[^0-9]%'
      AND u.AccountNumber = RIGHT(s.AccountNumber, 8))
       OR (u.AccountNumber <> s.AccountNumber
           AND dbo.fn_UPR_NormalizeSDATAccount(u.AccountNumber) = s.AccountNumber)
)
    THROW 50002, 'Existing source links use a truncated account or newly normalized formatted account. Reconcile UPR accounts and source mappings before loading.', 1;

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
OUTPUT N'UNIT',inserted.[UPRID],inserted.[UnitID],'UPDATE',
    CONVERT(NVARCHAR(MAX),N'') + N'UnitID = ' + CASE WHEN deleted.[UnitID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UnitID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN deleted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'BuildingID = ' + CASE WHEN deleted.[BuildingID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[BuildingID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UnitNumber = ' + CASE WHEN deleted.[UnitNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UnitNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UnitTypeCode = ' + CASE WHEN deleted.[UnitTypeCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UnitTypeCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'FloorNumber = ' + CASE WHEN deleted.[FloorNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[FloorNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'BedroomCount = ' + CASE WHEN deleted.[BedroomCount] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[BedroomCount],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'BathroomCount = ' + CASE WHEN deleted.[BathroomCount] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[BathroomCount],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'HasLegalIdentity = ' + CASE WHEN deleted.[HasLegalIdentity] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[HasLegalIdentity],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN deleted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedDate = ' + CASE WHEN deleted.[UpdatedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UpdatedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CONVERT(NVARCHAR(MAX),N'') + N'UnitID = ' + CASE WHEN inserted.[UnitID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UnitID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'BuildingID = ' + CASE WHEN inserted.[BuildingID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[BuildingID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UnitNumber = ' + CASE WHEN inserted.[UnitNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UnitNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UnitTypeCode = ' + CASE WHEN inserted.[UnitTypeCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UnitTypeCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'FloorNumber = ' + CASE WHEN inserted.[FloorNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[FloorNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'BedroomCount = ' + CASE WHEN inserted.[BedroomCount] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[BedroomCount],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'BathroomCount = ' + CASE WHEN inserted.[BathroomCount] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[BathroomCount],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'HasLegalIdentity = ' + CASE WHEN inserted.[HasLegalIdentity] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[HasLegalIdentity],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN inserted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedDate = ' + CASE WHEN inserted.[UpdatedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UpdatedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)

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

OUTPUT N'UPRMATCHREVIEW_Q',inserted.[UPRID],inserted.[UPRMatchReviewID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'UPRMatchReviewID = ' + CASE WHEN inserted.[UPRMatchReviewID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRMatchReviewID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IncomingSourceSystem = ' + CASE WHEN inserted.[IncomingSourceSystem] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[IncomingSourceSystem],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'SDAT_NormalizedIncomingAddress = ' + CASE WHEN inserted.[SDAT_NormalizedIncomingAddress] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[SDAT_NormalizedIncomingAddress],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'MA_NormalizedIncomingAddress = ' + CASE WHEN inserted.[MA_NormalizedIncomingAddress] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[MA_NormalizedIncomingAddress],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'SDAT_ParcelID = ' + CASE WHEN inserted.[SDAT_ParcelID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[SDAT_ParcelID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'MA_ParcelID = ' + CASE WHEN inserted.[MA_ParcelID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[MA_ParcelID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'SDAT_AccountNumber = ' + CASE WHEN inserted.[SDAT_AccountNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[SDAT_AccountNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'MA_Account = ' + CASE WHEN inserted.[MA_Account] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[MA_Account],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ReasonForNoMatch = ' + CASE WHEN inserted.[ReasonForNoMatch] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ReasonForNoMatch],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ProcessingTimestamp = ' + CASE WHEN inserted.[ProcessingTimestamp] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ProcessingTimestamp],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ReviewStatus = ' + CASE WHEN inserted.[ReviewStatus] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ReviewStatus],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Decision = ' + CASE WHEN inserted.[Decision] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[Decision],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
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
IF OBJECT_ID('tempdb..#ProtectedCondoUPR') IS NOT NULL DROP TABLE #ProtectedCondoUPR;
CREATE TABLE #ProtectedCondoUPR(UPRID BIGINT NOT NULL PRIMARY KEY);
IF OBJECT_ID(N'dbo.UPR_CONDO_LEGACY',N'U') IS NOT NULL
BEGIN
    IF COL_LENGTH(N'dbo.UPR_CONDO_LEGACY',N'UPRID') IS NULL
       OR COL_LENGTH(N'dbo.UPR_CONDO_LEGACY',N'CondoName') IS NULL
        THROW 50004,'Existing Condo archive has an unfamiliar layout; review it before converting Condo roots.',1;
    EXEC sys.sp_executesql N'INSERT #ProtectedCondoUPR(UPRID)
        SELECT DISTINCT UPRID FROM dbo.UPR_CONDO_LEGACY WHERE CondoName IS NOT NULL AND UPRID IS NOT NULL;';
END;
IF COL_LENGTH(N'dbo.CONDO',N'CondoName') IS NOT NULL
    EXEC sys.sp_executesql N'INSERT #ProtectedCondoUPR(UPRID)
        SELECT DISTINCT c.UPRID FROM dbo.CONDO c WHERE c.CondoName IS NOT NULL
        AND NOT EXISTS(SELECT 1 FROM #ProtectedCondoUPR n WHERE n.UPRID=c.UPRID);';
/* Without a prior migration, a live Parcel value also needs preservation.
   Do not delete that subtype row as part of automatic reclassification. */
IF COL_LENGTH(N'dbo.CONDO',N'Parcel') IS NOT NULL
    EXEC sys.sp_executesql N'INSERT #ProtectedCondoUPR(UPRID)
        SELECT DISTINCT c.UPRID FROM dbo.CONDO c WHERE c.Parcel IS NOT NULL
        AND NOT EXISTS(SELECT 1 FROM #ProtectedCondoUPR n WHERE n.UPRID=c.UPRID);';
IF OBJECT_ID('tempdb..#CondoToComplex') IS NOT NULL DROP TABLE #CondoToComplex;
SELECT g.GroupKey, u.UPRID
INTO #CondoToComplex
FROM #ParentGroup g
INNER JOIN dbo.UPR u ON u.AccountNumber = g.AccountNumber
    AND u.ParentUPRID IS NULL AND u.EntityTypeID = @EtCondo
INNER JOIN dbo.CONDO d ON d.UPRID = u.UPRID
WHERE g.PathType = N'COMPLEX'
  AND NOT EXISTS (SELECT 1 FROM #ProtectedCondoUPR old WHERE old.UPRID = u.UPRID)
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
OUTPUT N'UPR',inserted.[UPRID],inserted.[UPRID],'UPDATE',
    CONVERT(NVARCHAR(MAX),N'') + N'UPRID = ' + CASE WHEN deleted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ParentUPRID = ' + CASE WHEN deleted.[ParentUPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ParentUPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EntityTypeID = ' + CASE WHEN deleted.[EntityTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[EntityTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AccountNumber = ' + CASE WHEN deleted.[AccountNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[AccountNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN deleted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'CreatedBy = ' + CASE WHEN deleted.[CreatedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[CreatedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedDate = ' + CASE WHEN deleted.[UpdatedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UpdatedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedBy = ' + CASE WHEN deleted.[UpdatedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UpdatedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CONVERT(NVARCHAR(MAX),N'') + N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ParentUPRID = ' + CASE WHEN inserted.[ParentUPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ParentUPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EntityTypeID = ' + CASE WHEN inserted.[EntityTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EntityTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AccountNumber = ' + CASE WHEN inserted.[AccountNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AccountNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN inserted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'CreatedBy = ' + CASE WHEN inserted.[CreatedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[CreatedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedDate = ' + CASE WHEN inserted.[UpdatedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UpdatedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedBy = ' + CASE WHEN inserted.[UpdatedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UpdatedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)

FROM dbo.UPR u INNER JOIN #CondoToComplex r ON r.UPRID = u.UPRID;
DELETE d
OUTPUT N'CONDO',deleted.[UPRID],deleted.[CondoID],'DELETE',
    CONVERT(NVARCHAR(MAX),N'') + N'CondoID = ' + CASE WHEN deleted.[CondoID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[CondoID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN deleted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'OwnerName = ' + CASE WHEN deleted.[OwnerName] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[OwnerName],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN deleted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CAST(NULL AS NVARCHAR(MAX))
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
 FROM dbo.CONDO d INNER JOIN #CondoToComplex r ON r.UPRID = d.UPRID;
UPDATE child SET ParentUPRID = b.UPRID, UpdatedBy = @RunUser, UpdatedDate = @Now
OUTPUT N'UPR',inserted.[UPRID],inserted.[UPRID],'UPDATE',
    CONVERT(NVARCHAR(MAX),N'') + N'UPRID = ' + CASE WHEN deleted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ParentUPRID = ' + CASE WHEN deleted.[ParentUPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ParentUPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EntityTypeID = ' + CASE WHEN deleted.[EntityTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[EntityTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AccountNumber = ' + CASE WHEN deleted.[AccountNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[AccountNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN deleted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'CreatedBy = ' + CASE WHEN deleted.[CreatedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[CreatedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedDate = ' + CASE WHEN deleted.[UpdatedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UpdatedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedBy = ' + CASE WHEN deleted.[UpdatedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UpdatedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CONVERT(NVARCHAR(MAX),N'') + N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ParentUPRID = ' + CASE WHEN inserted.[ParentUPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ParentUPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EntityTypeID = ' + CASE WHEN inserted.[EntityTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EntityTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AccountNumber = ' + CASE WHEN inserted.[AccountNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AccountNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN inserted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'CreatedBy = ' + CASE WHEN inserted.[CreatedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[CreatedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedDate = ' + CASE WHEN inserted.[UpdatedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UpdatedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedBy = ' + CASE WHEN inserted.[UpdatedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UpdatedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)

FROM dbo.UPR child INNER JOIN #CondoToComplex r ON r.UPRID = child.ParentUPRID
INNER JOIN dbo.UNIT un ON un.UPRID = child.UPRID
INNER JOIN dbo.BUILDING b ON b.BuildingID = un.BuildingID;
/* Step 7 fills COMPLEX for this reused UPR; Step 12 rebuilds closure/Level.
   Statement OUTPUT retains these changes for the audit write in Step 14. */

INSERT INTO dbo.UPRMATCHREVIEW_Q
    (UPRID, IncomingSourceSystem, SDAT_NormalizedIncomingAddress, MA_NormalizedIncomingAddress,
     SDAT_AccountNumber, MA_Account, ReasonForNoMatch, ProcessingTimestamp, ReviewStatus, Decision)

OUTPUT N'UPRMATCHREVIEW_Q',inserted.[UPRID],inserted.[UPRMatchReviewID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'UPRMatchReviewID = ' + CASE WHEN inserted.[UPRMatchReviewID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRMatchReviewID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IncomingSourceSystem = ' + CASE WHEN inserted.[IncomingSourceSystem] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[IncomingSourceSystem],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'SDAT_NormalizedIncomingAddress = ' + CASE WHEN inserted.[SDAT_NormalizedIncomingAddress] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[SDAT_NormalizedIncomingAddress],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'MA_NormalizedIncomingAddress = ' + CASE WHEN inserted.[MA_NormalizedIncomingAddress] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[MA_NormalizedIncomingAddress],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'SDAT_ParcelID = ' + CASE WHEN inserted.[SDAT_ParcelID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[SDAT_ParcelID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'MA_ParcelID = ' + CASE WHEN inserted.[MA_ParcelID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[MA_ParcelID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'SDAT_AccountNumber = ' + CASE WHEN inserted.[SDAT_AccountNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[SDAT_AccountNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'MA_Account = ' + CASE WHEN inserted.[MA_Account] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[MA_Account],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ReasonForNoMatch = ' + CASE WHEN inserted.[ReasonForNoMatch] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ReasonForNoMatch],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ProcessingTimestamp = ' + CASE WHEN inserted.[ProcessingTimestamp] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ProcessingTimestamp],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ReviewStatus = ' + CASE WHEN inserted.[ReviewStatus] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ReviewStatus],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Decision = ' + CASE WHEN inserted.[Decision] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[Decision],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
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
    AuditNewValue NVARCHAR(MAX) NULL,
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
    s.ParcelID,
    CONVERT(NVARCHAR(MAX),N'') + N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ParentUPRID = ' + CASE WHEN inserted.[ParentUPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ParentUPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EntityTypeID = ' + CASE WHEN inserted.[EntityTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EntityTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AccountNumber = ' + CASE WHEN inserted.[AccountNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AccountNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN inserted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'CreatedBy = ' + CASE WHEN inserted.[CreatedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[CreatedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedDate = ' + CASE WHEN inserted.[UpdatedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UpdatedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedBy = ' + CASE WHEN inserted.[UpdatedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UpdatedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #ParentMap (GroupKey, UPRID, PathType, AccountNumber, PropertyType, OwnerName, CommunityName, ParcelID, AuditNewValue);
SET @AuditDmlRows=@@ROWCOUNT;
INSERT #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
SELECT N'UPR',m.UPRID,m.UPRID,'INSERT',NULL,m.AuditNewValue
FROM #ParentMap m WHERE m.AuditNewValue IS NOT NULL;


SET @ParentInserted = (
    SELECT COUNT(*) FROM #ParentMap pm
    WHERE NOT EXISTS (SELECT 1 FROM #ParentSkip ps WHERE ps.GroupKey = pm.GroupKey)
);

INSERT INTO dbo.COMPLEX (UPRID, CommunityName, PropertyTypeID, StatusCode, CreatedBy)

OUTPUT N'COMPLEX',inserted.[UPRID],inserted.[ComplexID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'ComplexID = ' + CASE WHEN inserted.[ComplexID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ComplexID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'CommunityName = ' + CASE WHEN inserted.[CommunityName] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[CommunityName],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'PropertyTypeID = ' + CASE WHEN inserted.[PropertyTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[PropertyTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN inserted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'CreatedBy = ' + CASE WHEN inserted.[CreatedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[CreatedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
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

OUTPUT N'PROPERTY',inserted.[UPRID],inserted.[PropertyID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'PropertyID = ' + CASE WHEN inserted.[PropertyID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[PropertyID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'PropertyTypeID = ' + CASE WHEN inserted.[PropertyTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[PropertyTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'PropertyName = ' + CASE WHEN inserted.[PropertyName] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[PropertyName],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'OwnerName = ' + CASE WHEN inserted.[OwnerName] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[OwnerName],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Parcel = ' + CASE WHEN inserted.[Parcel] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[Parcel],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN inserted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
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

INSERT INTO dbo.CONDO (UPRID, OwnerName, StatusCode)

OUTPUT N'CONDO',inserted.[UPRID],inserted.[CondoID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'CondoID = ' + CASE WHEN inserted.[CondoID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[CondoID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'OwnerName = ' + CASE WHEN inserted.[OwnerName] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[OwnerName],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN inserted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
SELECT
    pm.UPRID,
    pm.OwnerName,
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

/* September 17 existing-data repair: only one blank MA + one blank SDAT
   record at the same account/address, each source-linked to an otherwise
   unmodified blank Unit. Preserve the MA Unit/Building and both source links.
   Anything ambiguous or manually enriched remains untouched for review. */
IF OBJECT_ID('tempdb..#OverlapPairs') IS NOT NULL DROP TABLE #OverlapPairs;
SELECT GroupKey, NormalizedFullAddress,
    MAStageKey = MAX(CASE WHEN SourceSystem = N'ADDRESS_MASTER' THEN StageKey END),
    SDStageKey = MAX(CASE WHEN SourceSystem = N'KDAT' THEN StageKey END)
INTO #OverlapPairs FROM #Stage
WHERE IsValid = 1
GROUP BY GroupKey, NormalizedFullAddress
HAVING COUNT(*) = 2
   AND SUM(CASE WHEN SourceSystem = N'ADDRESS_MASTER' THEN 1 ELSE 0 END) = 1
   AND SUM(CASE WHEN SourceSystem = N'KDAT' THEN 1 ELSE 0 END) = 1
   AND MAX(COALESCE(UnitNumber, CondoUnit)) IS NULL;

IF OBJECT_ID('tempdb..#OverlapRepair') IS NOT NULL DROP TABLE #OverlapRepair;
SELECT p.MAStageKey, p.SDStageKey, KeepUnit = mu.UPRID, DropUnit = su.UPRID,
    KeepBuilding = mb.UPRID, DropBuilding = sb.UPRID,
    KeepBuildingID = mb.BuildingID, DropBuildingID = sb.BuildingID
INTO #OverlapRepair
FROM #OverlapPairs p
JOIN #Stage ma ON ma.StageKey = p.MAStageKey
JOIN #Stage sd ON sd.StageKey = p.SDStageKey
JOIN #ParentMap pm ON pm.GroupKey = p.GroupKey
JOIN dbo.EXTERNAL_IDENTIFIER_XREF mx ON mx.SourceSystem = ma.SourceSystem
    AND mx.IdentifierType = N'SOURCE_RECORD_ID' AND mx.IdentifierValue = ma.SourceRecordID
JOIN dbo.EXTERNAL_IDENTIFIER_XREF sx ON sx.SourceSystem = sd.SourceSystem
    AND sx.IdentifierType = N'SOURCE_RECORD_ID' AND sx.IdentifierValue = sd.SourceRecordID
JOIN dbo.UNIT mu ON mu.UPRID = mx.UPRID
JOIN dbo.UNIT su ON su.UPRID = sx.UPRID AND su.UPRID <> mu.UPRID
JOIN dbo.UPR mup ON mup.UPRID = mu.UPRID
JOIN dbo.UPR sup ON sup.UPRID = su.UPRID
JOIN dbo.BUILDING mb ON mb.BuildingID = mu.BuildingID
JOIN dbo.BUILDING sb ON sb.BuildingID = su.BuildingID
JOIN dbo.UPR mbp ON mbp.UPRID = mb.UPRID AND mbp.ParentUPRID = pm.UPRID
JOIN dbo.UPR sbp ON sbp.UPRID = sb.UPRID AND sbp.ParentUPRID = pm.UPRID
WHERE (mu.UnitNumber IS NULL OR mu.UnitNumber = N'N/A')
  AND (su.UnitNumber IS NULL OR su.UnitNumber = N'N/A')
  AND sup.ParentUPRID = sb.UPRID
  AND mup.ParentUPRID = mb.UPRID
  AND sup.AccountNumber IS NULL AND sup.StatusCode = N'ACTIVE'
  AND sup.EntityTypeID = @EtUnit AND mup.EntityTypeID = @EtUnit
  AND sbp.EntityTypeID = @EtBuilding AND mbp.EntityTypeID = @EtBuilding
  AND su.StatusCode = N'ACTIVE' AND su.UpdatedDate IS NULL
  AND su.UnitTypeCode IS NULL AND su.FloorNumber IS NULL AND su.BedroomCount IS NULL
  AND su.BathroomCount IS NULL AND su.HasLegalIdentity IS NULL
  AND NOT EXISTS (SELECT 1 FROM dbo.UPR child WHERE child.ParentUPRID = su.UPRID)
  AND NOT EXISTS (SELECT 1 FROM dbo.EXTERNAL_IDENTIFIER_XREF x WHERE x.UPRID = su.UPRID AND x.ExternalIdentifierID <> sx.ExternalIdentifierID)
  AND NOT EXISTS (SELECT 1 FROM dbo.UPR_CONTACT d JOIN dbo.UPR_CONTACT k
      ON k.UPRID = mu.UPRID AND k.ContactID = d.ContactID AND k.RoleTypeID = d.RoleTypeID
      WHERE d.UPRID = su.UPRID AND EXISTS (SELECT d.EffectiveDate, d.EndDate EXCEPT SELECT k.EffectiveDate, k.EndDate))
  AND EXISTS (SELECT 1 FROM dbo.UPR_ADDRESS ua JOIN dbo.ADDRESS a ON a.AddressID = ua.AddressID
      WHERE ua.UPRID = mb.UPRID AND ua.IsPrimary = 1 AND a.NormalizedAddress = p.NormalizedFullAddress)
  AND EXISTS (SELECT 1 FROM dbo.UPR_ADDRESS ua JOIN dbo.ADDRESS a ON a.AddressID = ua.AddressID
      WHERE ua.UPRID = sb.UPRID AND ua.IsPrimary = 1
        AND dbo.fn_UPR_NormalizeFullAddressLine(a.StreetNumber + N' ' + a.StreetName + N' ' + ISNULL(a.StreetType,N''), a.City, a.ZipCode) = p.NormalizedFullAddress)
  AND (mb.UPRID = sb.UPRID OR (
      sb.BuildingName IS NULL AND sb.UpdatedDate IS NULL AND sb.StatusCode = N'ACTIVE'
      AND sbp.AccountNumber IS NULL AND sbp.StatusCode = N'ACTIVE'
      AND (sb.YearBuilt IS NULL OR mb.YearBuilt IS NULL OR sb.YearBuilt = mb.YearBuilt)
      AND NOT EXISTS (SELECT 1 FROM dbo.UNIT other WHERE other.BuildingID = sb.BuildingID AND other.UPRID <> su.UPRID)
      AND NOT EXISTS (SELECT 1 FROM dbo.UPR child WHERE child.ParentUPRID = sb.UPRID AND child.UPRID <> su.UPRID)
      AND NOT EXISTS (SELECT 1 FROM dbo.EXTERNAL_IDENTIFIER_XREF x WHERE x.UPRID = sb.UPRID)
      AND NOT EXISTS (SELECT 1 FROM dbo.UPR_CONTACT d JOIN dbo.UPR_CONTACT k
          ON k.UPRID = mb.UPRID AND k.ContactID = d.ContactID AND k.RoleTypeID = d.RoleTypeID
          WHERE d.UPRID = sb.UPRID AND EXISTS (SELECT d.EffectiveDate, d.EndDate EXCEPT SELECT k.EffectiveDate, k.EndDate))
  ));
/* A source Unit shared with another candidate makes the entire match unsafe. */
DELETE r FROM #OverlapRepair r WHERE EXISTS (SELECT 1 FROM #OverlapRepair other
    WHERE other.MAStageKey <> r.MAStageKey
      AND (other.DropUnit IN (r.DropUnit,r.KeepUnit) OR other.KeepUnit IN (r.DropUnit,r.KeepUnit)));

IF OBJECT_ID('tempdb..#MergeUPR') IS NOT NULL DROP TABLE #MergeUPR;
CREATE TABLE #MergeUPR (OldUPRID BIGINT NOT NULL PRIMARY KEY, NewUPRID BIGINT NOT NULL);
INSERT INTO #MergeUPR (OldUPRID, NewUPRID) SELECT DropUnit, KeepUnit FROM #OverlapRepair;
INSERT INTO #MergeUPR (OldUPRID, NewUPRID)
SELECT DISTINCT DropBuilding, KeepBuilding FROM #OverlapRepair WHERE DropBuilding <> KeepBuilding;

/* Move links before removing the redundant nodes. Readable old/new audit events
   retain every removed row, including the donor Unit and Building IDs. */
UPDATE x SET UPRID = m.NewUPRID
OUTPUT N'EXTERNAL_IDENTIFIER_XREF',inserted.[UPRID],inserted.[ExternalIdentifierID],'UPDATE',
    CONVERT(NVARCHAR(MAX),N'') + N'ExternalIdentifierID = ' + CASE WHEN deleted.[ExternalIdentifierID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ExternalIdentifierID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN deleted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'SourceSystem = ' + CASE WHEN deleted.[SourceSystem] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[SourceSystem],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IdentifierType = ' + CASE WHEN deleted.[IdentifierType] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[IdentifierType],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IdentifierValue = ' + CASE WHEN deleted.[IdentifierValue] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[IdentifierValue],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CONVERT(NVARCHAR(MAX),N'') + N'ExternalIdentifierID = ' + CASE WHEN inserted.[ExternalIdentifierID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ExternalIdentifierID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'SourceSystem = ' + CASE WHEN inserted.[SourceSystem] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[SourceSystem],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IdentifierType = ' + CASE WHEN inserted.[IdentifierType] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[IdentifierType],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IdentifierValue = ' + CASE WHEN inserted.[IdentifierValue] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[IdentifierValue],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
 FROM dbo.EXTERNAL_IDENTIFIER_XREF x JOIN #MergeUPR m ON m.OldUPRID = x.UPRID;
DELETE d
OUTPUT N'UPR_CONTACT',deleted.[UPRID],deleted.[UPRContactID],'DELETE',
    CONVERT(NVARCHAR(MAX),N'') + N'UPRContactID = ' + CASE WHEN deleted.[UPRContactID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRContactID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN deleted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ContactID = ' + CASE WHEN deleted.[ContactID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ContactID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'RoleTypeID = ' + CASE WHEN deleted.[RoleTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[RoleTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EffectiveDate = ' + CASE WHEN deleted.[EffectiveDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[EffectiveDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EndDate = ' + CASE WHEN deleted.[EndDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[EndDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CAST(NULL AS NVARCHAR(MAX))
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
 FROM dbo.UPR_CONTACT d JOIN #MergeUPR m ON m.OldUPRID = d.UPRID
WHERE EXISTS (SELECT 1 FROM dbo.UPR_CONTACT k WHERE k.UPRID = m.NewUPRID AND k.ContactID = d.ContactID AND k.RoleTypeID = d.RoleTypeID);
UPDATE d SET UPRID = m.NewUPRID
OUTPUT N'UPR_CONTACT',inserted.[UPRID],inserted.[UPRContactID],'UPDATE',
    CONVERT(NVARCHAR(MAX),N'') + N'UPRContactID = ' + CASE WHEN deleted.[UPRContactID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRContactID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN deleted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ContactID = ' + CASE WHEN deleted.[ContactID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ContactID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'RoleTypeID = ' + CASE WHEN deleted.[RoleTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[RoleTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EffectiveDate = ' + CASE WHEN deleted.[EffectiveDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[EffectiveDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EndDate = ' + CASE WHEN deleted.[EndDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[EndDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CONVERT(NVARCHAR(MAX),N'') + N'UPRContactID = ' + CASE WHEN inserted.[UPRContactID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRContactID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ContactID = ' + CASE WHEN inserted.[ContactID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ContactID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'RoleTypeID = ' + CASE WHEN inserted.[RoleTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[RoleTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EffectiveDate = ' + CASE WHEN inserted.[EffectiveDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EffectiveDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EndDate = ' + CASE WHEN inserted.[EndDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EndDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
 FROM dbo.UPR_CONTACT d JOIN #MergeUPR m ON m.OldUPRID = d.UPRID;
/* Keep alternate source address links, but retain the survivor's primary. */
UPDATE d SET IsPrimary = 0
OUTPUT N'UPR_ADDRESS',inserted.[UPRID],inserted.[UPRAddressID],'UPDATE',
    CONVERT(NVARCHAR(MAX),N'') + N'UPRAddressID = ' + CASE WHEN deleted.[UPRAddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRAddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN deleted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AddressID = ' + CASE WHEN deleted.[AddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[AddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AddressRoleID = ' + CASE WHEN deleted.[AddressRoleID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[AddressRoleID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IsPrimary = ' + CASE WHEN deleted.[IsPrimary] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[IsPrimary],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EffectiveDate = ' + CASE WHEN deleted.[EffectiveDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[EffectiveDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EndDate = ' + CASE WHEN deleted.[EndDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[EndDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CONVERT(NVARCHAR(MAX),N'') + N'UPRAddressID = ' + CASE WHEN inserted.[UPRAddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRAddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AddressID = ' + CASE WHEN inserted.[AddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AddressRoleID = ' + CASE WHEN inserted.[AddressRoleID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AddressRoleID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IsPrimary = ' + CASE WHEN inserted.[IsPrimary] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[IsPrimary],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EffectiveDate = ' + CASE WHEN inserted.[EffectiveDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EffectiveDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EndDate = ' + CASE WHEN inserted.[EndDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EndDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
 FROM dbo.UPR_ADDRESS d JOIN #MergeUPR m ON m.OldUPRID = d.UPRID
WHERE d.IsPrimary = 1 AND EXISTS (SELECT 1 FROM dbo.UPR_ADDRESS k WHERE k.UPRID = m.NewUPRID AND k.IsPrimary = 1);
DELETE d
OUTPUT N'UPR_ADDRESS',deleted.[UPRID],deleted.[UPRAddressID],'DELETE',
    CONVERT(NVARCHAR(MAX),N'') + N'UPRAddressID = ' + CASE WHEN deleted.[UPRAddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRAddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN deleted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AddressID = ' + CASE WHEN deleted.[AddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[AddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AddressRoleID = ' + CASE WHEN deleted.[AddressRoleID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[AddressRoleID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IsPrimary = ' + CASE WHEN deleted.[IsPrimary] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[IsPrimary],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EffectiveDate = ' + CASE WHEN deleted.[EffectiveDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[EffectiveDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EndDate = ' + CASE WHEN deleted.[EndDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[EndDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CAST(NULL AS NVARCHAR(MAX))
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
 FROM dbo.UPR_ADDRESS d JOIN #MergeUPR m ON m.OldUPRID = d.UPRID
WHERE EXISTS (SELECT 1 FROM dbo.UPR_ADDRESS k WHERE k.UPRID = m.NewUPRID
    AND k.AddressID = d.AddressID AND k.AddressRoleID = d.AddressRoleID
    AND NOT EXISTS (SELECT d.EffectiveDate, d.EndDate EXCEPT SELECT k.EffectiveDate, k.EndDate));
UPDATE d SET UPRID = m.NewUPRID
OUTPUT N'UPR_ADDRESS',inserted.[UPRID],inserted.[UPRAddressID],'UPDATE',
    CONVERT(NVARCHAR(MAX),N'') + N'UPRAddressID = ' + CASE WHEN deleted.[UPRAddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRAddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN deleted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AddressID = ' + CASE WHEN deleted.[AddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[AddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AddressRoleID = ' + CASE WHEN deleted.[AddressRoleID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[AddressRoleID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IsPrimary = ' + CASE WHEN deleted.[IsPrimary] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[IsPrimary],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EffectiveDate = ' + CASE WHEN deleted.[EffectiveDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[EffectiveDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EndDate = ' + CASE WHEN deleted.[EndDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[EndDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CONVERT(NVARCHAR(MAX),N'') + N'UPRAddressID = ' + CASE WHEN inserted.[UPRAddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRAddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AddressID = ' + CASE WHEN inserted.[AddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AddressRoleID = ' + CASE WHEN inserted.[AddressRoleID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AddressRoleID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IsPrimary = ' + CASE WHEN inserted.[IsPrimary] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[IsPrimary],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EffectiveDate = ' + CASE WHEN inserted.[EffectiveDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EffectiveDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EndDate = ' + CASE WHEN inserted.[EndDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EndDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
 FROM dbo.UPR_ADDRESS d JOIN #MergeUPR m ON m.OldUPRID = d.UPRID;
UPDATE h SET UPRID = m.NewUPRID
OUTPUT N'UPRSTATUSHISTORY',inserted.[UPRID],inserted.[UPRStatusHistoryID],'UPDATE',
    CONVERT(NVARCHAR(MAX),N'') + N'UPRStatusHistoryID = ' + CASE WHEN deleted.[UPRStatusHistoryID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRStatusHistoryID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN deleted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'SDATAccountNumber = ' + CASE WHEN deleted.[SDATAccountNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[SDATAccountNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'OldStatusCode = ' + CASE WHEN deleted.[OldStatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[OldStatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'NewStatusCode = ' + CASE WHEN deleted.[NewStatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[NewStatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ChangeReason = ' + CASE WHEN deleted.[ChangeReason] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ChangeReason],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ParcelID = ' + CASE WHEN deleted.[ParcelID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ParcelID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Owner = ' + CASE WHEN deleted.[Owner] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[Owner],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'PropertyTypeCode = ' + CASE WHEN deleted.[PropertyTypeCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[PropertyTypeCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ChangeSource = ' + CASE WHEN deleted.[ChangeSource] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ChangeSource],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ChangedBy = ' + CASE WHEN deleted.[ChangedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ChangedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ChangedDate = ' + CASE WHEN deleted.[ChangedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ChangedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Notes = ' + CASE WHEN deleted.[Notes] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[Notes],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'BuildingID = ' + CASE WHEN deleted.[BuildingID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[BuildingID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CONVERT(NVARCHAR(MAX),N'') + N'UPRStatusHistoryID = ' + CASE WHEN inserted.[UPRStatusHistoryID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRStatusHistoryID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'SDATAccountNumber = ' + CASE WHEN inserted.[SDATAccountNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[SDATAccountNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'OldStatusCode = ' + CASE WHEN inserted.[OldStatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[OldStatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'NewStatusCode = ' + CASE WHEN inserted.[NewStatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[NewStatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ChangeReason = ' + CASE WHEN inserted.[ChangeReason] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ChangeReason],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ParcelID = ' + CASE WHEN inserted.[ParcelID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ParcelID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Owner = ' + CASE WHEN inserted.[Owner] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[Owner],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'PropertyTypeCode = ' + CASE WHEN inserted.[PropertyTypeCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[PropertyTypeCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ChangeSource = ' + CASE WHEN inserted.[ChangeSource] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ChangeSource],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ChangedBy = ' + CASE WHEN inserted.[ChangedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ChangedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ChangedDate = ' + CASE WHEN inserted.[ChangedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ChangedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Notes = ' + CASE WHEN inserted.[Notes] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[Notes],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'BuildingID = ' + CASE WHEN inserted.[BuildingID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[BuildingID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
 FROM dbo.UPRSTATUSHISTORY h JOIN #MergeUPR m ON m.OldUPRID = h.UPRID;
UPDATE h SET BuildingID = r.KeepBuildingID
OUTPUT N'UPRSTATUSHISTORY',inserted.[UPRID],inserted.[UPRStatusHistoryID],'UPDATE',
    CONVERT(NVARCHAR(MAX),N'') + N'UPRStatusHistoryID = ' + CASE WHEN deleted.[UPRStatusHistoryID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRStatusHistoryID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN deleted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'SDATAccountNumber = ' + CASE WHEN deleted.[SDATAccountNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[SDATAccountNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'OldStatusCode = ' + CASE WHEN deleted.[OldStatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[OldStatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'NewStatusCode = ' + CASE WHEN deleted.[NewStatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[NewStatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ChangeReason = ' + CASE WHEN deleted.[ChangeReason] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ChangeReason],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ParcelID = ' + CASE WHEN deleted.[ParcelID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ParcelID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Owner = ' + CASE WHEN deleted.[Owner] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[Owner],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'PropertyTypeCode = ' + CASE WHEN deleted.[PropertyTypeCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[PropertyTypeCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ChangeSource = ' + CASE WHEN deleted.[ChangeSource] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ChangeSource],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ChangedBy = ' + CASE WHEN deleted.[ChangedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ChangedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ChangedDate = ' + CASE WHEN deleted.[ChangedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ChangedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Notes = ' + CASE WHEN deleted.[Notes] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[Notes],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'BuildingID = ' + CASE WHEN deleted.[BuildingID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[BuildingID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CONVERT(NVARCHAR(MAX),N'') + N'UPRStatusHistoryID = ' + CASE WHEN inserted.[UPRStatusHistoryID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRStatusHistoryID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'SDATAccountNumber = ' + CASE WHEN inserted.[SDATAccountNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[SDATAccountNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'OldStatusCode = ' + CASE WHEN inserted.[OldStatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[OldStatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'NewStatusCode = ' + CASE WHEN inserted.[NewStatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[NewStatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ChangeReason = ' + CASE WHEN inserted.[ChangeReason] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ChangeReason],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ParcelID = ' + CASE WHEN inserted.[ParcelID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ParcelID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Owner = ' + CASE WHEN inserted.[Owner] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[Owner],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'PropertyTypeCode = ' + CASE WHEN inserted.[PropertyTypeCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[PropertyTypeCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ChangeSource = ' + CASE WHEN inserted.[ChangeSource] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ChangeSource],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ChangedBy = ' + CASE WHEN inserted.[ChangedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ChangedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ChangedDate = ' + CASE WHEN inserted.[ChangedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ChangedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Notes = ' + CASE WHEN inserted.[Notes] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[Notes],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'BuildingID = ' + CASE WHEN inserted.[BuildingID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[BuildingID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
 FROM dbo.UPRSTATUSHISTORY h
JOIN #OverlapRepair r ON r.DropBuildingID = h.BuildingID WHERE r.DropBuildingID <> r.KeepBuildingID;
UPDATE q SET UPRID = m.NewUPRID
OUTPUT N'UPRMATCHREVIEW_Q',inserted.[UPRID],inserted.[UPRMatchReviewID],'UPDATE',
    CONVERT(NVARCHAR(MAX),N'') + N'UPRMatchReviewID = ' + CASE WHEN deleted.[UPRMatchReviewID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRMatchReviewID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN deleted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IncomingSourceSystem = ' + CASE WHEN deleted.[IncomingSourceSystem] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[IncomingSourceSystem],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'SDAT_NormalizedIncomingAddress = ' + CASE WHEN deleted.[SDAT_NormalizedIncomingAddress] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[SDAT_NormalizedIncomingAddress],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'MA_NormalizedIncomingAddress = ' + CASE WHEN deleted.[MA_NormalizedIncomingAddress] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[MA_NormalizedIncomingAddress],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'SDAT_ParcelID = ' + CASE WHEN deleted.[SDAT_ParcelID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[SDAT_ParcelID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'MA_ParcelID = ' + CASE WHEN deleted.[MA_ParcelID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[MA_ParcelID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'SDAT_AccountNumber = ' + CASE WHEN deleted.[SDAT_AccountNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[SDAT_AccountNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'MA_Account = ' + CASE WHEN deleted.[MA_Account] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[MA_Account],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ReasonForNoMatch = ' + CASE WHEN deleted.[ReasonForNoMatch] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ReasonForNoMatch],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ProcessingTimestamp = ' + CASE WHEN deleted.[ProcessingTimestamp] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ProcessingTimestamp],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ReviewStatus = ' + CASE WHEN deleted.[ReviewStatus] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ReviewStatus],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Decision = ' + CASE WHEN deleted.[Decision] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[Decision],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CONVERT(NVARCHAR(MAX),N'') + N'UPRMatchReviewID = ' + CASE WHEN inserted.[UPRMatchReviewID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRMatchReviewID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IncomingSourceSystem = ' + CASE WHEN inserted.[IncomingSourceSystem] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[IncomingSourceSystem],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'SDAT_NormalizedIncomingAddress = ' + CASE WHEN inserted.[SDAT_NormalizedIncomingAddress] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[SDAT_NormalizedIncomingAddress],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'MA_NormalizedIncomingAddress = ' + CASE WHEN inserted.[MA_NormalizedIncomingAddress] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[MA_NormalizedIncomingAddress],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'SDAT_ParcelID = ' + CASE WHEN inserted.[SDAT_ParcelID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[SDAT_ParcelID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'MA_ParcelID = ' + CASE WHEN inserted.[MA_ParcelID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[MA_ParcelID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'SDAT_AccountNumber = ' + CASE WHEN inserted.[SDAT_AccountNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[SDAT_AccountNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'MA_Account = ' + CASE WHEN inserted.[MA_Account] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[MA_Account],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ReasonForNoMatch = ' + CASE WHEN inserted.[ReasonForNoMatch] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ReasonForNoMatch],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ProcessingTimestamp = ' + CASE WHEN inserted.[ProcessingTimestamp] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ProcessingTimestamp],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ReviewStatus = ' + CASE WHEN inserted.[ReviewStatus] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ReviewStatus],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Decision = ' + CASE WHEN inserted.[Decision] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[Decision],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
 FROM dbo.UPRMATCHREVIEW_Q q JOIN #MergeUPR m ON m.OldUPRID = q.UPRID;
UPDATE b SET YearBuilt = donor.YearBuilt
OUTPUT N'BUILDING',inserted.[UPRID],inserted.[BuildingID],'UPDATE',
    CONVERT(NVARCHAR(MAX),N'') + N'BuildingID = ' + CASE WHEN deleted.[BuildingID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[BuildingID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN deleted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'BuildingName = ' + CASE WHEN deleted.[BuildingName] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[BuildingName],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'YearBuilt = ' + CASE WHEN deleted.[YearBuilt] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[YearBuilt],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN deleted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedDate = ' + CASE WHEN deleted.[UpdatedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UpdatedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CONVERT(NVARCHAR(MAX),N'') + N'BuildingID = ' + CASE WHEN inserted.[BuildingID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[BuildingID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'BuildingName = ' + CASE WHEN inserted.[BuildingName] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[BuildingName],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'YearBuilt = ' + CASE WHEN inserted.[YearBuilt] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[YearBuilt],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN inserted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedDate = ' + CASE WHEN inserted.[UpdatedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UpdatedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
 FROM dbo.BUILDING b
JOIN #OverlapRepair r ON r.KeepBuildingID = b.BuildingID
JOIN dbo.BUILDING donor ON donor.BuildingID = r.DropBuildingID
WHERE b.YearBuilt IS NULL AND donor.YearBuilt IS NOT NULL;
DELETE c
OUTPUT N'UPR_CLOSURE',deleted.[DescendantUPRID],deleted.[DescendantUPRID],'DELETE',
    CONVERT(NVARCHAR(MAX),N'') + N'AncestorUPRID = ' + CASE WHEN deleted.[AncestorUPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[AncestorUPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'DescendantUPRID = ' + CASE WHEN deleted.[DescendantUPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[DescendantUPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Level = ' + CASE WHEN deleted.[Level] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[Level],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CAST(NULL AS NVARCHAR(MAX))
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
 FROM dbo.UPR_CLOSURE c WHERE EXISTS (SELECT 1 FROM #MergeUPR m WHERE m.OldUPRID IN (c.AncestorUPRID,c.DescendantUPRID));
DELETE u
OUTPUT N'UNIT',deleted.[UPRID],deleted.[UnitID],'DELETE',
    CONVERT(NVARCHAR(MAX),N'') + N'UnitID = ' + CASE WHEN deleted.[UnitID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UnitID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN deleted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'BuildingID = ' + CASE WHEN deleted.[BuildingID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[BuildingID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UnitNumber = ' + CASE WHEN deleted.[UnitNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UnitNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UnitTypeCode = ' + CASE WHEN deleted.[UnitTypeCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UnitTypeCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'FloorNumber = ' + CASE WHEN deleted.[FloorNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[FloorNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'BedroomCount = ' + CASE WHEN deleted.[BedroomCount] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[BedroomCount],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'BathroomCount = ' + CASE WHEN deleted.[BathroomCount] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[BathroomCount],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'HasLegalIdentity = ' + CASE WHEN deleted.[HasLegalIdentity] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[HasLegalIdentity],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN deleted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedDate = ' + CASE WHEN deleted.[UpdatedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UpdatedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CAST(NULL AS NVARCHAR(MAX))
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
 FROM dbo.UNIT u JOIN #OverlapRepair r ON r.DropUnit = u.UPRID;
DELETE u
OUTPUT N'UPR',deleted.[UPRID],deleted.[UPRID],'DELETE',
    CONVERT(NVARCHAR(MAX),N'') + N'UPRID = ' + CASE WHEN deleted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ParentUPRID = ' + CASE WHEN deleted.[ParentUPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ParentUPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EntityTypeID = ' + CASE WHEN deleted.[EntityTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[EntityTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AccountNumber = ' + CASE WHEN deleted.[AccountNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[AccountNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN deleted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'CreatedBy = ' + CASE WHEN deleted.[CreatedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[CreatedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedDate = ' + CASE WHEN deleted.[UpdatedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UpdatedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedBy = ' + CASE WHEN deleted.[UpdatedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UpdatedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CAST(NULL AS NVARCHAR(MAX))
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
 FROM dbo.UPR u JOIN #OverlapRepair r ON r.DropUnit = u.UPRID;
DELETE b
OUTPUT N'BUILDING',deleted.[UPRID],deleted.[BuildingID],'DELETE',
    CONVERT(NVARCHAR(MAX),N'') + N'BuildingID = ' + CASE WHEN deleted.[BuildingID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[BuildingID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN deleted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'BuildingName = ' + CASE WHEN deleted.[BuildingName] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[BuildingName],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'YearBuilt = ' + CASE WHEN deleted.[YearBuilt] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[YearBuilt],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN deleted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedDate = ' + CASE WHEN deleted.[UpdatedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UpdatedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CAST(NULL AS NVARCHAR(MAX))
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
 FROM dbo.BUILDING b JOIN #OverlapRepair r ON r.DropBuilding = b.UPRID WHERE r.DropBuilding <> r.KeepBuilding;
DELETE u
OUTPUT N'UPR',deleted.[UPRID],deleted.[UPRID],'DELETE',
    CONVERT(NVARCHAR(MAX),N'') + N'UPRID = ' + CASE WHEN deleted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ParentUPRID = ' + CASE WHEN deleted.[ParentUPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ParentUPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EntityTypeID = ' + CASE WHEN deleted.[EntityTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[EntityTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AccountNumber = ' + CASE WHEN deleted.[AccountNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[AccountNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN deleted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'CreatedBy = ' + CASE WHEN deleted.[CreatedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[CreatedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedDate = ' + CASE WHEN deleted.[UpdatedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UpdatedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedBy = ' + CASE WHEN deleted.[UpdatedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UpdatedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CAST(NULL AS NVARCHAR(MAX))
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
 FROM dbo.UPR u JOIN #MergeUPR m ON m.OldUPRID = u.UPRID;

/* When a potential old pair cannot be repaired safely, do not silently remap
   its source identifier. Retain both records and show a repeatable review. */
INSERT INTO dbo.UPRMATCHREVIEW_Q
    (UPRID, IncomingSourceSystem, SDAT_NormalizedIncomingAddress, MA_NormalizedIncomingAddress,
     SDAT_AccountNumber, MA_Account, ReasonForNoMatch, ProcessingTimestamp, ReviewStatus, Decision)

OUTPUT N'UPRMATCHREVIEW_Q',inserted.[UPRID],inserted.[UPRMatchReviewID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'UPRMatchReviewID = ' + CASE WHEN inserted.[UPRMatchReviewID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRMatchReviewID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IncomingSourceSystem = ' + CASE WHEN inserted.[IncomingSourceSystem] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[IncomingSourceSystem],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'SDAT_NormalizedIncomingAddress = ' + CASE WHEN inserted.[SDAT_NormalizedIncomingAddress] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[SDAT_NormalizedIncomingAddress],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'MA_NormalizedIncomingAddress = ' + CASE WHEN inserted.[MA_NormalizedIncomingAddress] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[MA_NormalizedIncomingAddress],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'SDAT_ParcelID = ' + CASE WHEN inserted.[SDAT_ParcelID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[SDAT_ParcelID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'MA_ParcelID = ' + CASE WHEN inserted.[MA_ParcelID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[MA_ParcelID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'SDAT_AccountNumber = ' + CASE WHEN inserted.[SDAT_AccountNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[SDAT_AccountNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'MA_Account = ' + CASE WHEN inserted.[MA_Account] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[MA_Account],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ReasonForNoMatch = ' + CASE WHEN inserted.[ReasonForNoMatch] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ReasonForNoMatch],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ProcessingTimestamp = ' + CASE WHEN inserted.[ProcessingTimestamp] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ProcessingTimestamp],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ReviewStatus = ' + CASE WHEN inserted.[ReviewStatus] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ReviewStatus],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Decision = ' + CASE WHEN inserted.[Decision] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[Decision],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
SELECT sx.UPRID, N'KDAT', sd.NormalizedFullAddress, ma.NormalizedFullAddress,
    sd.AccountNumber, ma.AccountNumber, N'AMBIGUOUS_CANDIDATES', @Now, N'PENDING_REVIEW',
    N'MA/SDAT blank-unit overlap has existing records that cannot be safely merged; inspect source links and manually maintained values.'
FROM #OverlapPairs p JOIN #Stage ma ON ma.StageKey = p.MAStageKey JOIN #Stage sd ON sd.StageKey = p.SDStageKey
JOIN dbo.EXTERNAL_IDENTIFIER_XREF mx ON mx.SourceSystem = ma.SourceSystem AND mx.IdentifierType = N'SOURCE_RECORD_ID' AND mx.IdentifierValue = ma.SourceRecordID
JOIN dbo.EXTERNAL_IDENTIFIER_XREF sx ON sx.SourceSystem = sd.SourceSystem AND sx.IdentifierType = N'SOURCE_RECORD_ID' AND sx.IdentifierValue = sd.SourceRecordID
WHERE mx.UPRID <> sx.UPRID AND NOT EXISTS (SELECT 1 FROM dbo.UPRMATCHREVIEW_Q q WHERE q.UPRID = sx.UPRID AND q.Decision LIKE N'MA/SDAT blank-unit overlap%');
SET @ReviewInserted += @@ROWCOUNT;

/* Normalize the known BLV alias on source-linked existing addresses too,
   including an SDAT-only earlier load that is now joined by MA. */
UPDATE a SET StreetType = N'BLVD', NormalizedAddress = n.FullAddress
OUTPUT N'ADDRESS',CAST(NULL AS BIGINT),inserted.[AddressID],'UPDATE',
    CONVERT(NVARCHAR(MAX),N'') + N'AddressID = ' + CASE WHEN deleted.[AddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[AddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StreetNumber = ' + CASE WHEN deleted.[StreetNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[StreetNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StreetName = ' + CASE WHEN deleted.[StreetName] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[StreetName],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StreetType = ' + CASE WHEN deleted.[StreetType] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[StreetType],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'City = ' + CASE WHEN deleted.[City] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[City],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'State = ' + CASE WHEN deleted.[State] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[State],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ZipCode = ' + CASE WHEN deleted.[ZipCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ZipCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'NormalizedAddress = ' + CASE WHEN deleted.[NormalizedAddress] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[NormalizedAddress],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'YCoordinate = ' + CASE WHEN deleted.[YCoordinate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[YCoordinate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'XCoordinate = ' + CASE WHEN deleted.[XCoordinate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[XCoordinate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CONVERT(NVARCHAR(MAX),N'') + N'AddressID = ' + CASE WHEN inserted.[AddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StreetNumber = ' + CASE WHEN inserted.[StreetNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StreetNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StreetName = ' + CASE WHEN inserted.[StreetName] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StreetName],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StreetType = ' + CASE WHEN inserted.[StreetType] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StreetType],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'City = ' + CASE WHEN inserted.[City] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[City],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'State = ' + CASE WHEN inserted.[State] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[State],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ZipCode = ' + CASE WHEN inserted.[ZipCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ZipCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'NormalizedAddress = ' + CASE WHEN inserted.[NormalizedAddress] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[NormalizedAddress],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'YCoordinate = ' + CASE WHEN inserted.[YCoordinate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[YCoordinate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'XCoordinate = ' + CASE WHEN inserted.[XCoordinate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[XCoordinate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)

FROM dbo.ADDRESS a
CROSS APPLY (SELECT FullAddress = dbo.fn_UPR_NormalizeFullAddressLine(
    a.StreetNumber + N' ' + a.StreetName + N' BLVD', a.City, a.ZipCode)) n
WHERE a.StreetType = N'BLV'
  AND EXISTS (SELECT 1 FROM dbo.UPR_ADDRESS ua
      JOIN dbo.EXTERNAL_IDENTIFIER_XREF x ON x.UPRID = ua.UPRID AND x.IdentifierType = N'SOURCE_RECORD_ID'
      JOIN #Stage s ON s.SourceSystem = x.SourceSystem AND s.SourceRecordID = x.IdentifierValue
      WHERE ua.AddressID = a.AddressID AND s.IsValid = 1 AND s.NormalizedFullAddress = n.FullAddress);

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
    AuditNewValue NVARCHAR(MAX) NULL,
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
OUTPUT N'UPR_ADDRESS',inserted.[UPRID],inserted.[UPRAddressID],'UPDATE',
    CONVERT(NVARCHAR(MAX),N'') + N'UPRAddressID = ' + CASE WHEN deleted.[UPRAddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRAddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN deleted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AddressID = ' + CASE WHEN deleted.[AddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[AddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AddressRoleID = ' + CASE WHEN deleted.[AddressRoleID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[AddressRoleID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IsPrimary = ' + CASE WHEN deleted.[IsPrimary] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[IsPrimary],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EffectiveDate = ' + CASE WHEN deleted.[EffectiveDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[EffectiveDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EndDate = ' + CASE WHEN deleted.[EndDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[EndDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CONVERT(NVARCHAR(MAX),N'') + N'UPRAddressID = ' + CASE WHEN inserted.[UPRAddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRAddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AddressID = ' + CASE WHEN inserted.[AddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AddressRoleID = ' + CASE WHEN inserted.[AddressRoleID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AddressRoleID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IsPrimary = ' + CASE WHEN inserted.[IsPrimary] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[IsPrimary],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EffectiveDate = ' + CASE WHEN inserted.[EffectiveDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EffectiveDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EndDate = ' + CASE WHEN inserted.[EndDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EndDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)

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
OUTPUT s.BuildingKey, s.GroupKey, inserted.UPRID, s.NormalizedFullAddress, s.PathType,
    CONVERT(NVARCHAR(MAX),N'') + N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ParentUPRID = ' + CASE WHEN inserted.[ParentUPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ParentUPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EntityTypeID = ' + CASE WHEN inserted.[EntityTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EntityTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AccountNumber = ' + CASE WHEN inserted.[AccountNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AccountNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN inserted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'CreatedBy = ' + CASE WHEN inserted.[CreatedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[CreatedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedDate = ' + CASE WHEN inserted.[UpdatedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UpdatedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedBy = ' + CASE WHEN inserted.[UpdatedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UpdatedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #BuildingMap (BuildingKey, GroupKey, BuildingUPRID, NormalizedFullAddress, PathType, AuditNewValue);
SET @AuditDmlRows=@@ROWCOUNT;
INSERT #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
SELECT N'UPR',m.BuildingUPRID,m.BuildingUPRID,'INSERT',NULL,m.AuditNewValue
FROM #BuildingMap m WHERE m.AuditNewValue IS NOT NULL;


SET @BuildingInserted = @AuditDmlRows;

INSERT INTO dbo.BUILDING (UPRID, BuildingName, YearBuilt, StatusCode)

OUTPUT N'BUILDING',inserted.[UPRID],inserted.[BuildingID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'BuildingID = ' + CASE WHEN inserted.[BuildingID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[BuildingID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'BuildingName = ' + CASE WHEN inserted.[BuildingName] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[BuildingName],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'YearBuilt = ' + CASE WHEN inserted.[YearBuilt] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[YearBuilt],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN inserted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedDate = ' + CASE WHEN inserted.[UpdatedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UpdatedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
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
OUTPUT N'BUILDING',inserted.[UPRID],inserted.[BuildingID],'UPDATE',
    CONVERT(NVARCHAR(MAX),N'') + N'BuildingID = ' + CASE WHEN deleted.[BuildingID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[BuildingID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN deleted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'BuildingName = ' + CASE WHEN deleted.[BuildingName] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[BuildingName],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'YearBuilt = ' + CASE WHEN deleted.[YearBuilt] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[YearBuilt],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN deleted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedDate = ' + CASE WHEN deleted.[UpdatedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UpdatedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CONVERT(NVARCHAR(MAX),N'') + N'BuildingID = ' + CASE WHEN inserted.[BuildingID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[BuildingID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'BuildingName = ' + CASE WHEN inserted.[BuildingName] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[BuildingName],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'YearBuilt = ' + CASE WHEN inserted.[YearBuilt] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[YearBuilt],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN inserted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedDate = ' + CASE WHEN inserted.[UpdatedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UpdatedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)

FROM dbo.BUILDING target
INNER JOIN #BuildingMap bm ON bm.BuildingUPRID = target.UPRID
INNER JOIN #BuildingSrc src ON src.BuildingKey = bm.BuildingKey
WHERE target.BuildingName = CASE WHEN src.BuildingSeq <= 26
    THEN N'Building ' + CHAR(64 + CONVERT(INT, src.BuildingSeq))
    ELSE N'Building ' + CONVERT(NVARCHAR(20), src.BuildingSeq) END;

UPDATE target SET CommunityName = NULL
OUTPUT N'COMPLEX',inserted.[UPRID],inserted.[ComplexID],'UPDATE',
    CONVERT(NVARCHAR(MAX),N'') + N'ComplexID = ' + CASE WHEN deleted.[ComplexID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ComplexID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN deleted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'CommunityName = ' + CASE WHEN deleted.[CommunityName] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[CommunityName],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'PropertyTypeID = ' + CASE WHEN deleted.[PropertyTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[PropertyTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN deleted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'CreatedBy = ' + CASE WHEN deleted.[CreatedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[CreatedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CONVERT(NVARCHAR(MAX),N'') + N'ComplexID = ' + CASE WHEN inserted.[ComplexID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ComplexID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'CommunityName = ' + CASE WHEN inserted.[CommunityName] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[CommunityName],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'PropertyTypeID = ' + CASE WHEN inserted.[PropertyTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[PropertyTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN inserted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'CreatedBy = ' + CASE WHEN inserted.[CreatedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[CreatedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)

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
OUTPUT N'ADDRESS',CAST(NULL AS BIGINT),inserted.[AddressID],'UPDATE',
    CONVERT(NVARCHAR(MAX),N'') + N'AddressID = ' + CASE WHEN deleted.[AddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[AddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StreetNumber = ' + CASE WHEN deleted.[StreetNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[StreetNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StreetName = ' + CASE WHEN deleted.[StreetName] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[StreetName],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StreetType = ' + CASE WHEN deleted.[StreetType] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[StreetType],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'City = ' + CASE WHEN deleted.[City] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[City],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'State = ' + CASE WHEN deleted.[State] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[State],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ZipCode = ' + CASE WHEN deleted.[ZipCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ZipCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'NormalizedAddress = ' + CASE WHEN deleted.[NormalizedAddress] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[NormalizedAddress],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'YCoordinate = ' + CASE WHEN deleted.[YCoordinate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[YCoordinate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'XCoordinate = ' + CASE WHEN deleted.[XCoordinate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[XCoordinate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CONVERT(NVARCHAR(MAX),N'') + N'AddressID = ' + CASE WHEN inserted.[AddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StreetNumber = ' + CASE WHEN inserted.[StreetNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StreetNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StreetName = ' + CASE WHEN inserted.[StreetName] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StreetName],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StreetType = ' + CASE WHEN inserted.[StreetType] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StreetType],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'City = ' + CASE WHEN inserted.[City] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[City],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'State = ' + CASE WHEN inserted.[State] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[State],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ZipCode = ' + CASE WHEN inserted.[ZipCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ZipCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'NormalizedAddress = ' + CASE WHEN inserted.[NormalizedAddress] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[NormalizedAddress],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'YCoordinate = ' + CASE WHEN inserted.[YCoordinate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[YCoordinate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'XCoordinate = ' + CASE WHEN inserted.[XCoordinate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[XCoordinate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)

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
OUTPUT N'ADDRESS',CAST(NULL AS BIGINT),inserted.[AddressID],'UPDATE',
    CONVERT(NVARCHAR(MAX),N'') + N'AddressID = ' + CASE WHEN deleted.[AddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[AddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StreetNumber = ' + CASE WHEN deleted.[StreetNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[StreetNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StreetName = ' + CASE WHEN deleted.[StreetName] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[StreetName],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StreetType = ' + CASE WHEN deleted.[StreetType] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[StreetType],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'City = ' + CASE WHEN deleted.[City] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[City],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'State = ' + CASE WHEN deleted.[State] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[State],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ZipCode = ' + CASE WHEN deleted.[ZipCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ZipCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'NormalizedAddress = ' + CASE WHEN deleted.[NormalizedAddress] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[NormalizedAddress],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'YCoordinate = ' + CASE WHEN deleted.[YCoordinate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[YCoordinate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'XCoordinate = ' + CASE WHEN deleted.[XCoordinate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[XCoordinate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CONVERT(NVARCHAR(MAX),N'') + N'AddressID = ' + CASE WHEN inserted.[AddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StreetNumber = ' + CASE WHEN inserted.[StreetNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StreetNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StreetName = ' + CASE WHEN inserted.[StreetName] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StreetName],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StreetType = ' + CASE WHEN inserted.[StreetType] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StreetType],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'City = ' + CASE WHEN inserted.[City] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[City],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'State = ' + CASE WHEN inserted.[State] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[State],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ZipCode = ' + CASE WHEN inserted.[ZipCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ZipCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'NormalizedAddress = ' + CASE WHEN inserted.[NormalizedAddress] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[NormalizedAddress],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'YCoordinate = ' + CASE WHEN inserted.[YCoordinate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[YCoordinate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'XCoordinate = ' + CASE WHEN inserted.[XCoordinate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[XCoordinate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)

FROM dbo.ADDRESS a
INNER JOIN dbo.UPR_ADDRESS ua ON ua.AddressID = a.AddressID AND ua.IsPrimary = 1
INNER JOIN #BuildingMap bm ON bm.BuildingUPRID = ua.UPRID
INNER JOIN #BuildingSrc src ON src.BuildingKey = bm.BuildingKey
WHERE a.State = N'MD' AND src.State IS NULL;

IF OBJECT_ID('tempdb..#AddressMap') IS NOT NULL DROP TABLE #AddressMap;
CREATE TABLE #AddressMap (
    AuditNewValue NVARCHAR(MAX) NULL,
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
OUTPUT s.AddressKey, inserted.AddressID,
    CONVERT(NVARCHAR(MAX),N'') + N'AddressID = ' + CASE WHEN inserted.[AddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StreetNumber = ' + CASE WHEN inserted.[StreetNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StreetNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StreetName = ' + CASE WHEN inserted.[StreetName] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StreetName],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StreetType = ' + CASE WHEN inserted.[StreetType] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StreetType],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'City = ' + CASE WHEN inserted.[City] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[City],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'State = ' + CASE WHEN inserted.[State] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[State],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ZipCode = ' + CASE WHEN inserted.[ZipCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ZipCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'NormalizedAddress = ' + CASE WHEN inserted.[NormalizedAddress] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[NormalizedAddress],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'YCoordinate = ' + CASE WHEN inserted.[YCoordinate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[YCoordinate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'XCoordinate = ' + CASE WHEN inserted.[XCoordinate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[XCoordinate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END INTO #AddressMap (AddressKey, AddressID, AuditNewValue);
SET @AuditDmlRows=@@ROWCOUNT;
INSERT #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
SELECT N'ADDRESS',CAST(NULL AS BIGINT),m.AddressID,'INSERT',NULL,m.AuditNewValue
FROM #AddressMap m WHERE m.AuditNewValue IS NOT NULL;


SET @AddressInserted = @@ROWCOUNT;

INSERT INTO dbo.UPR_ADDRESS (UPRID, AddressID, AddressRoleID, IsPrimary, EffectiveDate)

OUTPUT N'UPR_ADDRESS',inserted.[UPRID],inserted.[UPRAddressID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'UPRAddressID = ' + CASE WHEN inserted.[UPRAddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRAddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AddressID = ' + CASE WHEN inserted.[AddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AddressRoleID = ' + CASE WHEN inserted.[AddressRoleID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AddressRoleID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IsPrimary = ' + CASE WHEN inserted.[IsPrimary] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[IsPrimary],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EffectiveDate = ' + CASE WHEN inserted.[EffectiveDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EffectiveDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EndDate = ' + CASE WHEN inserted.[EndDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EndDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
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
      PROPERTY/COMPLEX/CONDO: Unit child of its Building (ParentUPRID=Building)
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
UnitCandidates AS (
    SELECT ub.*,
        BlankMA = SUM(CASE WHEN RealUnitNumber IS NULL AND SourceSystem = N'ADDRESS_MASTER' THEN 1 ELSE 0 END)
            OVER (PARTITION BY GroupKey, NormalizedFullAddress),
        BlankSDAT = SUM(CASE WHEN RealUnitNumber IS NULL AND SourceSystem = N'KDAT' THEN 1 ELSE 0 END)
            OVER (PARTITION BY GroupKey, NormalizedFullAddress),
        NumberedUnits = SUM(CASE WHEN RealUnitNumber IS NOT NULL THEN 1 ELSE 0 END)
            OVER (PARTITION BY GroupKey, NormalizedFullAddress)
    FROM UnitBase ub WHERE NeedsUnit = 1
),
UnitJoined AS (
    SELECT
        ub.StageKey,
        ub.GroupKey,
        ub.PathType,
        ub.NormalizedFullAddress,
        /* MA wins confirmed overlaps. Blank MA stays N/A; blank SDAT stays
           NULL when independent. Both source identifiers remain linked. */
        UnitNumber = COALESCE(ub.RealUnitNumber,
            CASE WHEN ub.SourceSystem = N'KDAT' THEN NULL ELSE N'N/A' END),
        ParentUPRID = bm.BuildingUPRID,
        BuildingUPRID = bm.BuildingUPRID,
        BuildingTableID = CAST(NULL AS BIGINT),
        /* Named units match by real number. An unambiguous blank MA/SDAT
           pair with no numbered units shares one slot (September 17 review).
           Other blank rows retain their own slots; no arbitrary matching. */
        Rn = ROW_NUMBER() OVER (
            PARTITION BY ub.GroupKey, ub.NormalizedFullAddress,
                CASE WHEN ub.RealUnitNumber IS NULL THEN 0 ELSE 1 END,
                COALESCE(ub.RealUnitNumber, CASE WHEN ub.BlankMA = 1 AND ub.BlankSDAT = 1
                    AND ub.NumberedUnits = 0 THEN N'#MA-SDAT-PAIR'
                    ELSE N'#' + CONVERT(NVARCHAR(20), ub.StageKey) END)
            ORDER BY
                CASE ub.SourceSystem WHEN N'ADDRESS_MASTER' THEN 0 ELSE 1 END,
                ub.StageKey
        ),
        /* Every stage row in the dedup group - including the ones collapsed
           away below - needs to resolve to the SAME surviving Unit for XREF
           linking. Carry that surviving row's own StageKey onto every row. */
        WinnerStageKey = FIRST_VALUE(ub.StageKey) OVER (
            PARTITION BY ub.GroupKey, ub.NormalizedFullAddress,
                CASE WHEN ub.RealUnitNumber IS NULL THEN 0 ELSE 1 END,
                COALESCE(ub.RealUnitNumber, CASE WHEN ub.BlankMA = 1 AND ub.BlankSDAT = 1
                    AND ub.NumberedUnits = 0 THEN N'#MA-SDAT-PAIR'
                    ELSE N'#' + CONVERT(NVARCHAR(20), ub.StageKey) END)
            ORDER BY
                CASE ub.SourceSystem WHEN N'ADDRESS_MASTER' THEN 0 ELSE 1 END,
                ub.StageKey
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        )
    FROM UnitCandidates ub
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
    AuditNewValue NVARCHAR(MAX) NULL,
    StageKey INT NOT NULL PRIMARY KEY,
    UnitUPRID BIGINT NOT NULL,
    GroupKey NVARCHAR(450) NOT NULL
);

/* A newly arrived source row can describe an already loaded numbered Unit.
   Reuse that same structural Unit and attach its new source XREF to it.
   Placeholder numbers alone do not identify a Unit. Only the confirmed
   cross-source pairs in #UnitStageMap may reuse either member's existing Unit. */
/* Reuse the exact source-linked Unit first, including NULL/N/A values and
   Units reparented by a Condo-to-Complex repair above. */
INSERT INTO #UnitMap (StageKey, UnitUPRID, GroupKey)
SELECT src.StageKey, MIN(u.UPRID), MIN(src.GroupKey)
FROM #UnitSrc src
INNER JOIN #UnitStageMap sm ON sm.WinnerStageKey = src.StageKey
INNER JOIN #Stage st ON st.StageKey = sm.StageKey
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
OUTPUT s.StageKey, inserted.UPRID, s.GroupKey,
    CONVERT(NVARCHAR(MAX),N'') + N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ParentUPRID = ' + CASE WHEN inserted.[ParentUPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ParentUPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EntityTypeID = ' + CASE WHEN inserted.[EntityTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EntityTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AccountNumber = ' + CASE WHEN inserted.[AccountNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AccountNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN inserted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'CreatedBy = ' + CASE WHEN inserted.[CreatedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[CreatedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedDate = ' + CASE WHEN inserted.[UpdatedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UpdatedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedBy = ' + CASE WHEN inserted.[UpdatedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UpdatedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #UnitMap (StageKey, UnitUPRID, GroupKey, AuditNewValue);
SET @AuditDmlRows=@@ROWCOUNT;
INSERT #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
SELECT N'UPR',m.UnitUPRID,m.UnitUPRID,'INSERT',NULL,m.AuditNewValue
FROM #UnitMap m WHERE m.AuditNewValue IS NOT NULL;


INSERT INTO dbo.UNIT (UPRID, BuildingID, UnitNumber, StatusCode)

OUTPUT N'UNIT',inserted.[UPRID],inserted.[UnitID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'UnitID = ' + CASE WHEN inserted.[UnitID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UnitID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'BuildingID = ' + CASE WHEN inserted.[BuildingID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[BuildingID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UnitNumber = ' + CASE WHEN inserted.[UnitNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UnitNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UnitTypeCode = ' + CASE WHEN inserted.[UnitTypeCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UnitTypeCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'FloorNumber = ' + CASE WHEN inserted.[FloorNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[FloorNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'BedroomCount = ' + CASE WHEN inserted.[BedroomCount] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[BedroomCount],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'BathroomCount = ' + CASE WHEN inserted.[BathroomCount] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[BathroomCount],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'HasLegalIdentity = ' + CASE WHEN inserted.[HasLegalIdentity] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[HasLegalIdentity],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN inserted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UpdatedDate = ' + CASE WHEN inserted.[UpdatedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UpdatedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
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
OUTPUT N'CONTACT',CAST(NULL AS BIGINT),inserted.[ContactID],'UPDATE',
    CONVERT(NVARCHAR(MAX),N'') + N'ContactID = ' + CASE WHEN deleted.[ContactID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ContactID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ContactTypeID = ' + CASE WHEN deleted.[ContactTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[ContactTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'OrganizationName = ' + CASE WHEN deleted.[OrganizationName] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[OrganizationName],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN deleted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CONVERT(NVARCHAR(MAX),N'') + N'ContactID = ' + CASE WHEN inserted.[ContactID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ContactID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ContactTypeID = ' + CASE WHEN inserted.[ContactTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ContactTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'OrganizationName = ' + CASE WHEN inserted.[OrganizationName] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[OrganizationName],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN inserted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)

FROM dbo.CONTACT c
INNER JOIN dbo.UPR_CONTACT uc ON uc.ContactID = c.ContactID AND uc.RoleTypeID = @RoleOwner
INNER JOIN #ContactSrc src ON src.ParentUPRID = uc.UPRID
INNER JOIN #ParentMap pm ON pm.UPRID = src.ParentUPRID
WHERE c.OrganizationName = pm.AccountNumber
  AND (src.OrgName IS NULL OR src.OrgName <> c.OrganizationName);

IF OBJECT_ID('tempdb..#ContactMap') IS NOT NULL DROP TABLE #ContactMap;
CREATE TABLE #ContactMap (
    AuditNewValue NVARCHAR(MAX) NULL,
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
OUTPUT s.GroupKey, inserted.ContactID, s.ParentUPRID,
    CONVERT(NVARCHAR(MAX),N'') + N'ContactID = ' + CASE WHEN inserted.[ContactID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ContactID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ContactTypeID = ' + CASE WHEN inserted.[ContactTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ContactTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'OrganizationName = ' + CASE WHEN inserted.[OrganizationName] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[OrganizationName],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'StatusCode = ' + CASE WHEN inserted.[StatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[StatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #ContactMap (GroupKey, ContactID, ParentUPRID, AuditNewValue);
SET @AuditDmlRows=@@ROWCOUNT;
INSERT #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
SELECT N'CONTACT',m.ParentUPRID,m.ContactID,'INSERT',NULL,m.AuditNewValue
FROM #ContactMap m WHERE m.AuditNewValue IS NOT NULL;


SET @ContactInserted = @AuditDmlRows;

INSERT INTO dbo.UPR_CONTACT (UPRID, ContactID, RoleTypeID, EffectiveDate)

OUTPUT N'UPR_CONTACT',inserted.[UPRID],inserted.[UPRContactID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'UPRContactID = ' + CASE WHEN inserted.[UPRContactID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRContactID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ContactID = ' + CASE WHEN inserted.[ContactID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ContactID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'RoleTypeID = ' + CASE WHEN inserted.[RoleTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[RoleTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EffectiveDate = ' + CASE WHEN inserted.[EffectiveDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EffectiveDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EndDate = ' + CASE WHEN inserted.[EndDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EndDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
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

OUTPUT N'EXTERNAL_IDENTIFIER_XREF',inserted.[UPRID],inserted.[ExternalIdentifierID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'ExternalIdentifierID = ' + CASE WHEN inserted.[ExternalIdentifierID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ExternalIdentifierID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'SourceSystem = ' + CASE WHEN inserted.[SourceSystem] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[SourceSystem],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IdentifierType = ' + CASE WHEN inserted.[IdentifierType] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[IdentifierType],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IdentifierValue = ' + CASE WHEN inserted.[IdentifierValue] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[IdentifierValue],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
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

OUTPUT N'EXTERNAL_IDENTIFIER_XREF',inserted.[UPRID],inserted.[ExternalIdentifierID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'ExternalIdentifierID = ' + CASE WHEN inserted.[ExternalIdentifierID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ExternalIdentifierID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'SourceSystem = ' + CASE WHEN inserted.[SourceSystem] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[SourceSystem],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IdentifierType = ' + CASE WHEN inserted.[IdentifierType] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[IdentifierType],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IdentifierValue = ' + CASE WHEN inserted.[IdentifierValue] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[IdentifierValue],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
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

/* SEARCH-002: retain source-qualified parcels on the source target and root.
   Do not infer global uniqueness or reject an otherwise valid missing parcel.
   Existing identifiers are retained as provenance; source-change retirement is
   a separate policy, as with the existing account identifiers. */
;WITH ParcelLinks AS (
    SELECT x.TargetUPRID AS UPRID, s.SourceSystem, s.ParcelID
    FROM #XrefSrc x JOIN #Stage s ON s.StageKey = x.StageKey
    WHERE s.IsValid = 1 AND s.ParcelID IS NOT NULL
    UNION
    SELECT pm.UPRID, s.SourceSystem, s.ParcelID
    FROM #Stage s JOIN #ParentMap pm ON pm.GroupKey = s.GroupKey
    WHERE s.IsValid = 1 AND s.ParcelID IS NOT NULL
)
INSERT INTO dbo.EXTERNAL_IDENTIFIER_XREF (UPRID, SourceSystem, IdentifierType, IdentifierValue)

OUTPUT N'EXTERNAL_IDENTIFIER_XREF',inserted.[UPRID],inserted.[ExternalIdentifierID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'ExternalIdentifierID = ' + CASE WHEN inserted.[ExternalIdentifierID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ExternalIdentifierID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'SourceSystem = ' + CASE WHEN inserted.[SourceSystem] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[SourceSystem],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IdentifierType = ' + CASE WHEN inserted.[IdentifierType] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[IdentifierType],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IdentifierValue = ' + CASE WHEN inserted.[IdentifierValue] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[IdentifierValue],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
SELECT p.UPRID, p.SourceSystem, N'PARCEL_ID', p.ParcelID
FROM ParcelLinks p
WHERE NOT EXISTS (SELECT 1 FROM dbo.EXTERNAL_IDENTIFIER_XREF x
    WHERE x.UPRID = p.UPRID AND x.SourceSystem = p.SourceSystem
      AND x.IdentifierType = N'PARCEL_ID' AND x.IdentifierValue = p.ParcelID);
SET @XrefInserted = @XrefInserted + @@ROWCOUNT;

PRINT N'Step 11 complete - XREF inserted: ' + CONVERT(NVARCHAR(20), @XrefInserted);

/* ============================================================================
   12. Rebuild UPR_CLOSURE from ParentUPRID
   ============================================================================ */
PRINT N'Step 12: Rebuild UPR_CLOSURE...';

/* September 30 contract: Level is the number of parent edges from this
   row's AncestorUPRID to DescendantUPRID. Every self row is 0; direct links
   are 1. Root depth remains a separate report value. Root traversal below
   validates that ParentUPRID forms rooted trees before creating any paths. */
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
SELECT UPRID, UPRID, 0 FROM #UPRLevels;
DECLARE @ClosureAdded INT = 1;
WHILE @ClosureAdded > 0
BEGIN
    INSERT INTO #ExpectedClosure (AncestorUPRID, DescendantUPRID, [Level])
    SELECT c.AncestorUPRID, child.UPRID, c.[Level] + 1
    FROM #ExpectedClosure c
    INNER JOIN dbo.UPR child ON child.ParentUPRID = c.DescendantUPRID
    WHERE NOT EXISTS (SELECT 1 FROM #ExpectedClosure x
        WHERE x.AncestorUPRID = c.AncestorUPRID AND x.DescendantUPRID = child.UPRID);
    SET @ClosureAdded = @@ROWCOUNT;
END;
DELETE c
OUTPUT N'UPR_CLOSURE',deleted.[DescendantUPRID],deleted.[DescendantUPRID],'DELETE',
    CONVERT(NVARCHAR(MAX),N'') + N'AncestorUPRID = ' + CASE WHEN deleted.[AncestorUPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[AncestorUPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'DescendantUPRID = ' + CASE WHEN deleted.[DescendantUPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[DescendantUPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Level = ' + CASE WHEN deleted.[Level] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[Level],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CAST(NULL AS NVARCHAR(MAX))
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
 FROM dbo.UPR_CLOSURE c
WHERE NOT EXISTS (SELECT 1 FROM #ExpectedClosure e
    WHERE e.AncestorUPRID = c.AncestorUPRID AND e.DescendantUPRID = c.DescendantUPRID);
UPDATE c SET [Level] = e.[Level]
OUTPUT N'UPR_CLOSURE',inserted.[DescendantUPRID],inserted.[DescendantUPRID],'UPDATE',
    CONVERT(NVARCHAR(MAX),N'') + N'AncestorUPRID = ' + CASE WHEN deleted.[AncestorUPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[AncestorUPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'DescendantUPRID = ' + CASE WHEN deleted.[DescendantUPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[DescendantUPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Level = ' + CASE WHEN deleted.[Level] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[Level],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CONVERT(NVARCHAR(MAX),N'') + N'AncestorUPRID = ' + CASE WHEN inserted.[AncestorUPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AncestorUPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'DescendantUPRID = ' + CASE WHEN inserted.[DescendantUPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[DescendantUPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Level = ' + CASE WHEN inserted.[Level] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[Level],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)

FROM dbo.UPR_CLOSURE c
INNER JOIN #ExpectedClosure e
    ON e.AncestorUPRID = c.AncestorUPRID AND e.DescendantUPRID = c.DescendantUPRID
WHERE c.[Level] IS NULL OR c.[Level] <> e.[Level];
INSERT INTO dbo.UPR_CLOSURE (AncestorUPRID, DescendantUPRID, [Level])

OUTPUT N'UPR_CLOSURE',inserted.[DescendantUPRID],inserted.[DescendantUPRID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'AncestorUPRID = ' + CASE WHEN inserted.[AncestorUPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AncestorUPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'DescendantUPRID = ' + CASE WHEN inserted.[DescendantUPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[DescendantUPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Level = ' + CASE WHEN inserted.[Level] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[Level],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
SELECT e.AncestorUPRID, e.DescendantUPRID, e.[Level] FROM #ExpectedClosure e
WHERE NOT EXISTS (SELECT 1 FROM dbo.UPR_CLOSURE c
    WHERE c.AncestorUPRID = e.AncestorUPRID AND c.DescendantUPRID = e.DescendantUPRID);

/* Preserve the client's existing Level type/nullability and dependent indexes.
   The synchronization above fills NULL/incorrect values with calculated distances.
   Do not ALTER COLUMN or add a new CHECK constraint during the data load. */
IF EXISTS(SELECT 1 FROM dbo.UPR_CLOSURE WHERE [Level] IS NULL OR [Level]<0)
    THROW 50005,'Closure synchronization left a NULL or negative distance. The load was rolled back.',1;

/* Ensure the requested pair and traversal indexes after distance synchronization. */
/* CLOSURE_FORWARD_INDEX_CHECK */
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes i
    JOIN sys.index_columns a ON a.object_id=i.object_id AND a.index_id=i.index_id AND a.key_ordinal=1
    JOIN sys.columns ac ON ac.object_id=a.object_id AND ac.column_id=a.column_id
    JOIN sys.index_columns d ON d.object_id=i.object_id AND d.index_id=i.index_id AND d.key_ordinal=2
    JOIN sys.columns dc ON dc.object_id=d.object_id AND dc.column_id=d.column_id
    WHERE i.object_id=@ClosureObjectID AND i.[type] IN (1,2)
      AND i.is_unique=1 AND i.ignore_dup_key=0 AND i.is_disabled=0
      AND i.has_filter=0 AND i.is_hypothetical=0
      AND ac.name=N'AncestorUPRID' AND dc.name=N'DescendantUPRID'
      AND (SELECT COUNT(*) FROM sys.index_columns k
           WHERE k.object_id=i.object_id AND k.index_id=i.index_id AND k.key_ordinal>0)=2
)
BEGIN
    IF EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=@ClosureObjectID AND name=N'UX_UPR_CLOSURE_AncestorDescendant')
        THROW 50007,'UX_UPR_CLOSURE_AncestorDescendant exists with an incompatible definition. Review it before rerunning.',1;
    CREATE UNIQUE NONCLUSTERED INDEX UX_UPR_CLOSURE_AncestorDescendant
        ON dbo.UPR_CLOSURE(AncestorUPRID,DescendantUPRID) INCLUDE([Level]);
END;

/* CLOSURE_REVERSE_INDEX_CHECK */
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes i
    JOIN sys.index_columns d ON d.object_id=i.object_id AND d.index_id=i.index_id AND d.key_ordinal=1
    JOIN sys.columns dc ON dc.object_id=d.object_id AND dc.column_id=d.column_id
    JOIN sys.index_columns a ON a.object_id=i.object_id AND a.index_id=i.index_id AND a.key_ordinal=2
    JOIN sys.columns ac ON ac.object_id=a.object_id AND ac.column_id=a.column_id
    WHERE i.object_id=@ClosureObjectID AND i.[type] IN (1,2)
      AND i.is_disabled=0 AND i.has_filter=0 AND i.is_hypothetical=0
      AND dc.name=N'DescendantUPRID' AND ac.name=N'AncestorUPRID'
)
BEGIN
    IF EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=@ClosureObjectID AND name=N'IX_UPR_CLOSURE_Descendant')
        THROW 50007,'IX_UPR_CLOSURE_Descendant exists with an incompatible definition. Review it before rerunning.',1;
    CREATE NONCLUSTERED INDEX IX_UPR_CLOSURE_Descendant
        ON dbo.UPR_CLOSURE(DescendantUPRID,AncestorUPRID) INCLUDE([Level]);
END;
PRINT N'Closure indexes verified: unique ancestor/descendant pair and descendant-first traversal.';

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

OUTPUT N'UPR_ADDRESS',inserted.[UPRID],inserted.[UPRAddressID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'UPRAddressID = ' + CASE WHEN inserted.[UPRAddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRAddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AddressID = ' + CASE WHEN inserted.[AddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AddressRoleID = ' + CASE WHEN inserted.[AddressRoleID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AddressRoleID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IsPrimary = ' + CASE WHEN inserted.[IsPrimary] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[IsPrimary],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EffectiveDate = ' + CASE WHEN inserted.[EffectiveDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EffectiveDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EndDate = ' + CASE WHEN inserted.[EndDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EndDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
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
OUTPUT N'UPR_ADDRESS',inserted.[UPRID],inserted.[UPRAddressID],'UPDATE',
    CONVERT(NVARCHAR(MAX),N'') + N'UPRAddressID = ' + CASE WHEN deleted.[UPRAddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRAddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN deleted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AddressID = ' + CASE WHEN deleted.[AddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[AddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AddressRoleID = ' + CASE WHEN deleted.[AddressRoleID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[AddressRoleID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IsPrimary = ' + CASE WHEN deleted.[IsPrimary] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[IsPrimary],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EffectiveDate = ' + CASE WHEN deleted.[EffectiveDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[EffectiveDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EndDate = ' + CASE WHEN deleted.[EndDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),deleted.[EndDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END,
    CONVERT(NVARCHAR(MAX),N'') + N'UPRAddressID = ' + CASE WHEN inserted.[UPRAddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRAddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AddressID = ' + CASE WHEN inserted.[AddressID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AddressID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'AddressRoleID = ' + CASE WHEN inserted.[AddressRoleID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[AddressRoleID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'IsPrimary = ' + CASE WHEN inserted.[IsPrimary] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[IsPrimary],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EffectiveDate = ' + CASE WHEN inserted.[EffectiveDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EffectiveDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EndDate = ' + CASE WHEN inserted.[EndDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EndDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)

FROM dbo.UPR_ADDRESS ua
INNER JOIN PrimaryHierarchyAddress p ON p.UPRAddressID = ua.UPRAddressID;

/* Share each parent's source contact with its Building/Unit/ADU descendants. */
INSERT INTO dbo.UPR_CONTACT (UPRID, ContactID, RoleTypeID, EffectiveDate)

OUTPUT N'UPR_CONTACT',inserted.[UPRID],inserted.[UPRContactID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'UPRContactID = ' + CASE WHEN inserted.[UPRContactID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRContactID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ContactID = ' + CASE WHEN inserted.[ContactID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ContactID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'RoleTypeID = ' + CASE WHEN inserted.[RoleTypeID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[RoleTypeID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EffectiveDate = ' + CASE WHEN inserted.[EffectiveDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EffectiveDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'EndDate = ' + CASE WHEN inserted.[EndDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[EndDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
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

OUTPUT N'UPRSTATUSHISTORY',inserted.[UPRID],inserted.[UPRStatusHistoryID],'INSERT',
    CAST(NULL AS NVARCHAR(MAX)),
    CONVERT(NVARCHAR(MAX),N'') + N'UPRStatusHistoryID = ' + CASE WHEN inserted.[UPRStatusHistoryID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRStatusHistoryID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'UPRID = ' + CASE WHEN inserted.[UPRID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[UPRID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'SDATAccountNumber = ' + CASE WHEN inserted.[SDATAccountNumber] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[SDATAccountNumber],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'OldStatusCode = ' + CASE WHEN inserted.[OldStatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[OldStatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'NewStatusCode = ' + CASE WHEN inserted.[NewStatusCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[NewStatusCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ChangeReason = ' + CASE WHEN inserted.[ChangeReason] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ChangeReason],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ParcelID = ' + CASE WHEN inserted.[ParcelID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ParcelID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Owner = ' + CASE WHEN inserted.[Owner] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[Owner],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'PropertyTypeCode = ' + CASE WHEN inserted.[PropertyTypeCode] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[PropertyTypeCode],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ChangeSource = ' + CASE WHEN inserted.[ChangeSource] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ChangeSource],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ChangedBy = ' + CASE WHEN inserted.[ChangedBy] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ChangedBy],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'ChangedDate = ' + CASE WHEN inserted.[ChangedDate] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[ChangedDate],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'Notes = ' + CASE WHEN inserted.[Notes] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[Notes],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END + NCHAR(10) +
        N'BuildingID = ' + CASE WHEN inserted.[BuildingID] IS NULL THEN N'<NULL>' ELSE N'"' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),inserted.[BuildingID],126),N'\',N'\\'),N'"',N'""'),NCHAR(13),N'\r'),NCHAR(10),N'\n') + N'"' END
INTO #AuditEvents(EntityName,UPRID,EntityRecordID,OperationType,OldValues,NewValue)
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
   14. Persist row audit events and batch summary
   ============================================================================ */
PRINT N'Step 14: AuditLog...';

/* Omit no-op UPDATE events. Binary comparison preserves case/trailing-space changes. */
DELETE FROM #AuditEvents WHERE OperationType='UPDATE'
    AND CONVERT(VARBINARY(MAX),OldValues)=CONVERT(VARBINARY(MAX),NewValue);
IF EXISTS(SELECT 1 FROM #AuditEntityMap m WHERE m.EntityID IS NULL
    OR (SELECT COUNT(*) FROM dbo.REF_ENTITY_IDENTIFICATION e WHERE e.EntityName=m.EntityName)<>1
    OR (SELECT COUNT(*) FROM dbo.REF_ENTITY_IDENTIFICATION e WHERE e.EntityID=m.EntityID)<>1
    OR NOT EXISTS(SELECT 1 FROM dbo.REF_ENTITY_IDENTIFICATION e WHERE e.EntityID=m.EntityID AND e.EntityName=m.EntityName))
    THROW 50004,'An audit entity mapping changed during loading; no audit insert was attempted.',1;
IF OBJECT_ID('tempdb..#AuditCounts') IS NOT NULL DROP TABLE #AuditCounts;
SELECT EntityName AS TableName,
    RowsInserted=SUM(CONVERT(BIGINT,CASE WHEN OperationType='INSERT' THEN 1 ELSE 0 END)),
    RowsUpdated=SUM(CONVERT(BIGINT,CASE WHEN OperationType='UPDATE' THEN 1 ELSE 0 END)),
    RowsDeleted=SUM(CONVERT(BIGINT,CASE WHEN OperationType='DELETE' THEN 1 ELSE 0 END))
INTO #AuditCounts FROM #AuditEvents GROUP BY EntityName;
DECLARE @UPRRowsInserted BIGINT=0,@UPRRowsUpdated BIGINT=0,@UPRRowsDeleted BIGINT=0,@UPRDistinctWritten BIGINT=0;
DECLARE @UPRTotalAfterLoad BIGINT=(SELECT COUNT_BIG(*) FROM dbo.UPR);
SELECT @UPRRowsInserted=RowsInserted,@UPRRowsUpdated=RowsUpdated,@UPRRowsDeleted=RowsDeleted
FROM #AuditCounts WHERE TableName=N'UPR';
SELECT @UPRDistinctWritten=COUNT_BIG(DISTINCT UPRID) FROM #AuditEvents
WHERE EntityName=N'UPR' AND OperationType IN('INSERT','UPDATE');
DECLARE @AuditRowsWritten BIGINT=0,@AuditBatchEnd BIGINT,@AuditExpected BIGINT,@AuditWritten INT;
DECLARE @AuditPrefix NVARCHAR(100)=N'RunID = '+CONVERT(NVARCHAR(36),@AuditRunID)+NCHAR(10);
IF OBJECT_ID('tempdb..#PersistedAuditIDs') IS NOT NULL DROP TABLE #PersistedAuditIDs;
CREATE TABLE #PersistedAuditIDs(AuditID INT NOT NULL PRIMARY KEY);
/* Bound each audit INSERT to 10,000 events. Capture is set-based; no per-record
   cursor, permanent helper table or trigger installation is required. */
DECLARE @RowAuditSql NVARCHAR(MAX)=N'INSERT dbo.AuditLog
    (UPRID,EntityNameID,EntityRecordID,OperationType,ChangedBy,ChangedDate,OldValues,'+QUOTENAME(@AuditNewColumn)+N')
    OUTPUT inserted.AuditID INTO #PersistedAuditIDs(AuditID)
    SELECT e.UPRID,m.EntityID,e.EntityRecordID,e.OperationType,@who,@at,
        CASE WHEN e.OldValues IS NULL THEN NULL ELSE @prefix+e.OldValues END,
        CASE WHEN e.NewValue IS NULL THEN NULL ELSE @prefix+e.NewValue END
    FROM #AuditEvents e JOIN #AuditEntityMap m ON m.EntityName=e.EntityName
    WHERE e.EventID<=@last;
    SET @written=@@ROWCOUNT;';
WHILE EXISTS(SELECT 1 FROM #AuditEvents)
BEGIN
    SELECT @AuditBatchEnd=MAX(EventID) FROM (SELECT TOP(10000) EventID FROM #AuditEvents ORDER BY EventID) batch;
    SELECT @AuditExpected=COUNT_BIG(*) FROM #AuditEvents WHERE EventID<=@AuditBatchEnd;
    SET @AuditWritten=0;
    EXEC sys.sp_executesql @RowAuditSql,
        N'@who NVARCHAR(100),@at DATETIME2(0),@prefix NVARCHAR(100),@last BIGINT,@written INT OUTPUT',
        @who=@AuditUser,@at=@Now,@prefix=@AuditPrefix,@last=@AuditBatchEnd,@written=@AuditWritten OUTPUT;
    IF @AuditWritten<>@AuditExpected
        THROW 50004,'Audit row count did not match captured changes; transaction will be rolled back.',1;
    SET @AuditRowsWritten+=@AuditWritten;
    DELETE FROM #AuditEvents WHERE EventID<=@AuditBatchEnd;
END;
IF EXISTS(SELECT 1 FROM #PersistedAuditIDs p LEFT JOIN dbo.AuditLog a ON a.AuditID=p.AuditID WHERE a.AuditID IS NULL)
    THROW 50004,'A captured audit row was not retained; transaction will be rolled back.',1;
DECLARE @LoadSummary NVARCHAR(MAX)=@AuditPrefix
    +N'Event = UPR_HIER_LOAD'+NCHAR(10)
    +N'Source rows read = '+CONVERT(NVARCHAR(30),CONVERT(BIGINT,@MARead)+@SDATRead)+NCHAR(10)
    +N'UPR rows inserted = '+CONVERT(NVARCHAR(30),@UPRRowsInserted)+NCHAR(10)
    +N'UPR rows updated = '+CONVERT(NVARCHAR(30),@UPRRowsUpdated)+NCHAR(10)
    +N'UPR rows deleted = '+CONVERT(NVARCHAR(30),@UPRRowsDeleted)+NCHAR(10)
    +N'Distinct UPR records inserted or updated = '+CONVERT(NVARCHAR(30),@UPRDistinctWritten)+NCHAR(10)
    +N'Condo units reparented = '+CONVERT(NVARCHAR(30),@CondoUnitsReparented)+NCHAR(10)
    +N'UPR records in database = '+CONVERT(NVARCHAR(30),@UPRTotalAfterLoad)+NCHAR(10)
    +N'Row audit entries written = '+CONVERT(NVARCHAR(30),@AuditRowsWritten)+NCHAR(10)
    +N'Closure rows = '+CONVERT(NVARCHAR(30),@ClosureRows);
/* The client column is NewValue VARCHAR(MAX); prior project databases used
   NewValues NVARCHAR(MAX). Bind the selected name only inside dynamic SQL, so
   neither absent alternative can cause an invalid-column compilation error.
   Capture identity inside that same scope and pass values as parameters. */
/* Recheck after business triggers have run; never send a NULL or remapped ID. */
IF @SummaryEntityID IS NULL
    THROW 50004,'Summary audit EntityNameID is NULL; audit INSERT was not attempted.',1;
IF (SELECT COUNT(*) FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityName=N'UPR_HIER_LOAD')<>1
 OR (SELECT COUNT(*) FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityID=@SummaryEntityID)<>1
 OR NOT EXISTS(SELECT 1 FROM dbo.REF_ENTITY_IDENTIFICATION
               WHERE EntityName=N'UPR_HIER_LOAD' AND EntityID=@SummaryEntityID)
    THROW 50004,'Summary audit dictionary mapping changed during loading; transaction will be rolled back.',1;
DECLARE @SummaryAuditID INT;
DECLARE @AuditInsertSql NVARCHAR(MAX) = N'INSERT INTO dbo.AuditLog
    (EntityNameID,EntityRecordID,OperationType,ChangedBy,ChangedDate,' + QUOTENAME(@AuditNewColumn) + N')
    VALUES(@entity,0,N''INSERT'',@who,@at,@payload);
    SET @audit=CONVERT(INT,SCOPE_IDENTITY());';
EXEC sys.sp_executesql @AuditInsertSql,
    N'@entity INT,@who NVARCHAR(100),@at DATETIME2(0),@payload NVARCHAR(MAX),@audit INT OUTPUT',
    @entity=@SummaryEntityID,@who=@AuditUser,@at=@Now,@payload=@LoadSummary,@audit=@SummaryAuditID OUTPUT;
IF @SummaryAuditID IS NULL OR NOT EXISTS(
    SELECT 1 FROM dbo.AuditLog WHERE AuditID=@SummaryAuditID AND EntityNameID=@SummaryEntityID
      AND EntityRecordID=0 AND OperationType=N'INSERT')
    THROW 50004,'Summary audit INSERT did not retain the expected row. Check AuditLog triggers; the load will be rolled back.',1;
SET @AuditInserted = 1;
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
PRINT N'UPR rows inserted            : ' + CONVERT(NVARCHAR(30),@UPRRowsInserted);
PRINT N'UPR rows updated             : ' + CONVERT(NVARCHAR(30),@UPRRowsUpdated);
PRINT N'UPR rows deleted             : ' + CONVERT(NVARCHAR(30),@UPRRowsDeleted);
PRINT N'Distinct UPR records written : ' + CONVERT(NVARCHAR(30),@UPRDistinctWritten);
PRINT N'Condo units reparented       : ' + CONVERT(NVARCHAR(20),@CondoUnitsReparented);
PRINT N'UPR records in database      : ' + CONVERT(NVARCHAR(30),@UPRTotalAfterLoad);
PRINT N'Row audit entries written    : ' + CONVERT(NVARCHAR(30),@AuditRowsWritten);
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

/* Results tab: statistical report first. Row-level detail grids can reach
   millions of rows on a full load, so they appear only when requested. */
SELECT [Order], Section, Metric, [Value]
FROM (VALUES
    ( 1, N'Run',     N'Audit RunID',                     CONVERT(NVARCHAR(36), @AuditRunID)),
    ( 2, N'Run',     N'Status',                          N'COMPLETED'),
    ( 3, N'Run',     N'Started',                         CONVERT(NVARCHAR(30), @BatchStart, 120)),
    ( 4, N'Run',     N'Elapsed seconds',                 CONVERT(NVARCHAR(20), DATEDIFF(SECOND, @BatchStart, SYSDATETIME()))),
    ( 5, N'Source',  N'MA rows read',                    CONVERT(NVARCHAR(20), @MARead)),
    ( 6, N'Source',  N'SDAT rows read',                  CONVERT(NVARCHAR(20), @SDATRead)),
    ( 7, N'Source',  N'Stage rows',                      CONVERT(NVARCHAR(20), @StageRows)),
    ( 8, N'Source',  N'Valid loadable rows',             CONVERT(NVARCHAR(20), @ValidRows)),
    ( 9, N'Source',  N'Invalid rows',                    CONVERT(NVARCHAR(20), @InvalidRows)),
    (10, N'Source',  N'Review_Q inserted',               CONVERT(NVARCHAR(20), @ReviewInserted)),
    (11, N'Groups',  N'COMPLEX groups',                  CONVERT(NVARCHAR(20), @ComplexGroups)),
    (12, N'Groups',  N'PROPERTY groups',                 CONVERT(NVARCHAR(20), @PropertyGroups)),
    (13, N'Groups',  N'CONDO groups',                    CONVERT(NVARCHAR(20), @CondoGroups)),
    (14, N'Written', N'New parent UPRs',                 CONVERT(NVARCHAR(20), @ParentInserted)),
    (15, N'Written', N'COMPLEX inserted',                CONVERT(NVARCHAR(20), @ComplexInserted)),
    (16, N'Written', N'PROPERTY inserted',               CONVERT(NVARCHAR(20), @PropertyInserted)),
    (17, N'Written', N'CONDO inserted',                  CONVERT(NVARCHAR(20), @CondoInserted)),
    (18, N'Written', N'Building UPRs (new this run)',    CONVERT(NVARCHAR(20), @BuildingInserted)),
    (19, N'Written', N'UNIT rows inserted',              CONVERT(NVARCHAR(20), @UnitInserted)),
    (20, N'Written', N'ADDRESS rows inserted',           CONVERT(NVARCHAR(20), @AddressInserted)),
    (21, N'Written', N'CONTACT rows inserted',           CONVERT(NVARCHAR(20), @ContactInserted)),
    (22, N'Written', N'UPR_CONTACT rows inserted',       CONVERT(NVARCHAR(20), @UPRContactInserted)),
    (23, N'Written', N'XREF inserted',                   CONVERT(NVARCHAR(20), @XrefInserted)),
    (24, N'Written', N'UPR_CLOSURE rows (total)',        CONVERT(NVARCHAR(20), @ClosureRows)),
    (25, N'Written', N'StatusHistory inserted',          CONVERT(NVARCHAR(20), @StatusHistInserted)),
    (26, N'Written', N'UPR rows inserted', CONVERT(NVARCHAR(30),@UPRRowsInserted)),
    (27, N'Written', N'UPR rows updated', CONVERT(NVARCHAR(30),@UPRRowsUpdated)),
    (28, N'Written', N'UPR rows deleted', CONVERT(NVARCHAR(30),@UPRRowsDeleted)),
    (29, N'Written', N'Distinct UPR records inserted or updated', CONVERT(NVARCHAR(30),@UPRDistinctWritten)),
    (30, N'Audit', N'Row audit entries written', CONVERT(NVARCHAR(30),@AuditRowsWritten)),
    (31, N'Audit', N'Batch audit entries written', CONVERT(NVARCHAR(30),@AuditInserted)),
    (32, N'Database', N'UPR records after load', CONVERT(NVARCHAR(30),@UPRTotalAfterLoad)),
    (33, N'Written', N'Existing Condo units reparented', CONVERT(NVARCHAR(20),@CondoUnitsReparented))
) v([Order], Section, Metric, [Value])
ORDER BY [Order];

/* Where the incoming rows went, and why rows were sent to review. */
SELECT s.SourceSystem, s.PathType,
    CASE WHEN s.IsValid = 1 THEN N'Loaded' ELSE N'Review' END AS Outcome,
    COALESCE(s.ReviewReason, N'') AS ReviewReason, COUNT(*) AS SourceRows
FROM #Stage s
GROUP BY s.SourceSystem, s.PathType, s.IsValid, s.ReviewReason
ORDER BY s.SourceSystem, Outcome, s.PathType, ReviewReason;

/* Counts belong to this session's captured changes, never a global ID range. */
SELECT TableName,RowsInserted,RowsUpdated,RowsDeleted FROM #AuditCounts ORDER BY TableName;
SELECT @SummaryAuditID AS BatchAuditID,@AuditRowsWritten AS RowAuditEntriesWritten,
       @AuditInserted AS BatchAuditEntriesWritten,@AuditRunID AS RunID,
       COALESCE((SELECT MIN(AuditID) FROM #PersistedAuditIDs),@SummaryAuditID) AS FirstAuditID,
       @SummaryAuditID AS LastAuditID;

IF @ShowDetailResults = 1
BEGIN
    PRINT N'Staging classification - MA account decisions and source-row routing';
    SELECT RunID = @AuditRunID, s.SourceSystem, s.SourceRecordID, s.AccountNumber,
        s.RawPropertyType, s.PropertyType AS EffectivePropertyType,
        s.NormalizedFullAddress, s.UnitNumber, s.CondoUnit,
        a.MARowCount, a.ValidMARowCount, s.DistinctAddrOnAccount AS MAStreetAddressCount,
        s.PathType, s.GroupKey, s.IsValid, s.ReviewReason, s.ClassificationReason
    FROM #Stage s LEFT JOIN #AcctAddrCnt a ON a.AccountNumber = s.AccountNumber
    ORDER BY s.AccountNumber, s.SourceSystem, s.SourceRecordID;

    DECLARE @AuditDetailSql NVARCHAR(MAX)=N'SELECT a.AuditID,a.UPRID,e.EntityName AS TableName,
        a.EntityRecordID,a.OperationType,a.ChangedBy,a.ChangedDate,a.OldValues,a.'+QUOTENAME(@AuditNewColumn)+N' AS NewValue
        FROM #PersistedAuditIDs p JOIN dbo.AuditLog a ON a.AuditID=p.AuditID
        JOIN #AuditEntityMap e ON e.EntityID=a.EntityNameID ORDER BY a.AuditID;';
    EXEC sys.sp_executesql @AuditDetailSql;

END;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    DECLARE @ErrNum INT = ERROR_NUMBER();
    DECLARE @ErrLine INT = ERROR_LINE();
    DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
    DECLARE @ErrProcedure NVARCHAR(128) = ERROR_PROCEDURE();
    SELECT @ErrNum AS ErrorNumber,@ErrProcedure AS ErrorProcedure,@ErrLine AS ErrorLine,
        @SummaryEntityID AS SummaryEntityID,@ErrMsg AS ErrorMessage;
    EXEC sys.sp_set_session_context @key = N'UPR_AuditRunID', @value = @PreviousAuditRun;
    PRINT N'*** UPR hierarchical load FAILED ***';
    PRINT N'Error ' + CONVERT(NVARCHAR(20), @ErrNum)
        + N' at line ' + CONVERT(NVARCHAR(20), @ErrLine)
        + N': ' + @ErrMsg;
    THROW;
END CATCH;
GO
