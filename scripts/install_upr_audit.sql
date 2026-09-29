/* Client AuditLog layout update - September 24, 2026.
   Physical dbo.AuditLog has only the nine client columns. AUDIT_LOG_CONTEXT
   retains technical keys/run metadata; dbo.AUDIT_LOG is a read compatibility
   view. Previous physical audit tables are archived, never silently discarded.
   Apply to a restored test database first, with writers stopped. Atomic and
   repeatable; requires compatibility 130+. See CLIENT_AUDIT_LAYOUT_2026-09-24.md.
*/
USE UPRXDB_TEST;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO
IF @@TRANCOUNT <> 0
BEGIN
    RAISERROR ('Run audit installation outside an existing transaction.', 16, 1);
    RETURN;
END;
IF OBJECT_ID(N'dbo.UPR',N'U') IS NULL
    THROW 50001,'Create the UPR schema before installing audit triggers.',1;
IF (SELECT compatibility_level FROM sys.databases WHERE database_id=DB_ID())<130
    THROW 50002,'Audit migration requires compatibility level 130 or later.',1;
BEGIN TRY
BEGIN TRANSACTION;
/* Old generated triggers must not write through objects while those objects
   are being migrated. Transaction rollback restores their previous state. */
DECLARE @DisableSQL NVARCHAR(MAX)=N'';
SELECT @DisableSQL+=N'DISABLE TRIGGER '+QUOTENAME(OBJECT_SCHEMA_NAME(t.object_id))+N'.'+QUOTENAME(t.name)
    +N' ON '+QUOTENAME(OBJECT_SCHEMA_NAME(t.parent_id))+N'.'+QUOTENAME(OBJECT_NAME(t.parent_id))+N';'
FROM sys.triggers t WHERE t.parent_class=1 AND t.is_disabled=0
  AND OBJECT_SCHEMA_NAME(t.object_id)=N'dbo' AND t.name LIKE N'tr[_]UPR[_]Audit[_]%';
IF @DisableSQL<>N'' EXEC sys.sp_executesql @DisableSQL;
SELECT o.name AS ObjectName,c.name AS ColumnName,dp.name AS PrincipalName,p.state AS PermissionState
INTO #AuditReaderPermissions
FROM sys.database_permissions p JOIN sys.objects o ON o.object_id=p.major_id
JOIN sys.database_principals dp ON dp.principal_id=p.grantee_principal_id
LEFT JOIN sys.columns c ON c.object_id=p.major_id AND c.column_id=p.minor_id
WHERE p.class=1 AND o.schema_id=SCHEMA_ID(N'dbo') AND o.name IN(N'AuditLog',N'AUDIT_LOG')
    AND p.permission_name=N'SELECT' AND p.state IN('D','G','W');
IF OBJECT_ID(N'dbo.REF_ENTITY_IDENTIFICATION', N'U') IS NULL
    EXEC(N'CREATE TABLE dbo.REF_ENTITY_IDENTIFICATION
(
    EntityID INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_REF_ENTITY_IDENTIFICATION PRIMARY KEY,
    EntityName VARCHAR(100) NOT NULL CONSTRAINT UQ_REF_ENTITY_IDENTIFICATION_Name UNIQUE,
    EntityDescription VARCHAR(250) NULL,
    IsActive BIT NOT NULL DEFAULT (1),
    CreatedDate DATETIME2 NOT NULL DEFAULT (SYSUTCDATETIME()),
    CreatedBy VARCHAR(100) NOT NULL DEFAULT (ORIGINAL_LOGIN())
);');
IF OBJECT_ID(N'dbo.AUDIT_ENTITY_RECORD', N'U') IS NULL
    EXEC(N'/* Negative IDs identify composite/text keys; nonnegative IDs are native row IDs.
   The original key is always retained, including every closure-key component. */
CREATE TABLE dbo.AUDIT_ENTITY_RECORD
(
    RecordID BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_AUDIT_ENTITY_RECORD PRIMARY KEY,
    EntityID INT NOT NULL REFERENCES dbo.REF_ENTITY_IDENTIFICATION (EntityID),
    EntityKey NVARCHAR(200) NOT NULL,
    CONSTRAINT UQ_AUDIT_ENTITY_RECORD UNIQUE (EntityID, EntityKey)
);');
/* Recognize all supported starting layouts. Never treat the client layout as
   the old EntityName/EntityKey table or recopy archives on repeated installs. */
DECLARE @Source SYSNAME=NULL,@Legacy BIT=0;
IF OBJECT_ID(N'dbo.AUDIT_LOG',N'U') IS NOT NULL
BEGIN
    IF OBJECT_ID(N'dbo.AuditLog',N'U') IS NOT NULL
        THROW 50003,'Two physical audit tables exist. Reconcile their histories before migration.',1;
    IF OBJECT_ID(N'dbo.AUDIT_LOG_PreClientLayout',N'U') IS NOT NULL
        THROW 50003,'The normalized audit archive already exists. Resolve the migration state first.',1;
    IF EXISTS(SELECT 1 FROM sys.foreign_keys WHERE referenced_object_id=OBJECT_ID(N'dbo.AUDIT_LOG'))
       OR EXISTS(SELECT 1 FROM sys.sql_expression_dependencies WHERE referenced_id=OBJECT_ID(N'dbo.AUDIT_LOG') AND is_schema_bound_reference=1)
        THROW 50003,'External audit dependencies require an explicit migration before changing the layout.',1;
    IF OBJECT_ID(N'dbo.AuditLog',N'V') IS NOT NULL EXEC(N'DROP VIEW dbo.AuditLog;');
    EXEC sys.sp_rename N'dbo.AUDIT_LOG',N'AUDIT_LOG_PreClientLayout';
    SET @Source=N'AUDIT_LOG_PreClientLayout';
END;
ELSE IF OBJECT_ID(N'dbo.AuditLog',N'U') IS NOT NULL AND COL_LENGTH(N'dbo.AuditLog',N'EntityNameID') IS NULL
BEGIN
    IF COL_LENGTH(N'dbo.AuditLog',N'EntityName') IS NULL OR COL_LENGTH(N'dbo.AuditLog',N'EntityKey') IS NULL
        THROW 50003,'Unrecognized AuditLog layout. Run the schema diagnostic before migration.',1;
    IF OBJECT_ID(N'dbo.AuditLog_PreSept17',N'U') IS NOT NULL
        THROW 50003,'Both legacy audit tables exist. Resolve the migration state first.',1;
    IF EXISTS(SELECT 1 FROM sys.foreign_keys WHERE referenced_object_id=OBJECT_ID(N'dbo.AuditLog'))
       OR EXISTS(SELECT 1 FROM sys.sql_expression_dependencies WHERE referenced_id=OBJECT_ID(N'dbo.AuditLog') AND is_schema_bound_reference=1)
        THROW 50003,'External audit dependencies require an explicit migration before changing the layout.',1;
    EXEC sys.sp_rename N'dbo.AuditLog',N'AuditLog_PreSept17';
    SELECT @Source=N'AuditLog_PreSept17',@Legacy=1;
END;
IF OBJECT_ID(N'dbo.AuditLog',N'V') IS NOT NULL
    THROW 50003,'AuditLog is a view without a recognized source audit table. Resolve the migration state first.',1;
IF OBJECT_ID(N'dbo.AuditLog',N'U') IS NULL AND @Source IS NULL
   AND (OBJECT_ID(N'dbo.AuditLog_PreSept17',N'U') IS NOT NULL OR OBJECT_ID(N'dbo.AUDIT_LOG_PreClientLayout',N'U') IS NOT NULL)
    THROW 50003,'Only an archived audit table exists. Recover the intended current history explicitly.',1;
IF OBJECT_ID(N'dbo.AuditLog',N'U') IS NULL
    EXEC(N'CREATE TABLE dbo.AuditLog
(
    AuditID INT IDENTITY(1,1) NOT NULL,
    UPRID BIGINT NULL,
    EntityNameID INT NOT NULL,
    EntityRecordID BIGINT NOT NULL,
    OperationType NVARCHAR(20) NOT NULL,
    ChangedBy NVARCHAR(100) NOT NULL,
    ChangedDate DATETIME2(3) NOT NULL CONSTRAINT DF_AuditLog_Client_ChangedDate DEFAULT (SYSDATETIME()),
    OldValues NVARCHAR(MAX) NULL,
    NewValues NVARCHAR(MAX) NULL,
    CONSTRAINT PK_AuditLog_Client PRIMARY KEY CLUSTERED (AuditID),
    CONSTRAINT CK_AuditLog_Client_OperationType CHECK (OperationType IN
        (''INSERT'',''UPDATE'',''DELETE'',''MERGE'',''STATUS_CHANGE'')),
    CONSTRAINT CK_AuditLog_Client_ChangedDate CHECK (ChangedDate <= DATEADD(MINUTE,1,SYSDATETIME()))
);
');
/* Refuse unfamiliar extensions/types instead of dropping client columns. */
IF (SELECT COUNT(*) FROM sys.columns WHERE object_id=OBJECT_ID(N'dbo.AuditLog'))<>9
   OR EXISTS (
    SELECT 1 FROM (VALUES
      (N'AuditID',N'int',4,0),(N'UPRID',N'bigint',8,1),(N'EntityNameID',N'int',4,0),
      (N'EntityRecordID',N'bigint',8,0),(N'OperationType',N'nvarchar',40,0),
      (N'ChangedBy',N'nvarchar',200,0),(N'ChangedDate',N'datetime2',NULL,0),
      (N'OldValues',N'nvarchar',-1,1),(N'NewValues',N'nvarchar',-1,1)
    ) wanted(ColumnName,TypeName,MaxLength,Nullable)
    LEFT JOIN sys.columns c ON c.object_id=OBJECT_ID(N'dbo.AuditLog') AND c.name=wanted.ColumnName
    WHERE c.column_id IS NULL OR TYPE_NAME(c.system_type_id)<>wanted.TypeName
       OR (wanted.MaxLength IS NOT NULL AND c.max_length<>wanted.MaxLength) OR c.is_nullable<>wanted.Nullable
   ) OR COLUMNPROPERTY(OBJECT_ID(N'dbo.AuditLog'),N'AuditID','IsIdentity')<>1
    THROW 50006,'Existing AuditLog differs from the supplied nine-column layout. Run the schema diagnostic; no columns were removed.',1;
IF NOT EXISTS(SELECT 1 FROM sys.indexes ix
    JOIN sys.index_columns ic ON ic.object_id=ix.object_id AND ic.index_id=ix.index_id AND ic.key_ordinal=1
    JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id
    WHERE ix.object_id=OBJECT_ID(N'dbo.AuditLog') AND ix.is_primary_key=1 AND ix.type=1 AND c.name=N'AuditID'
      AND NOT EXISTS(SELECT 1 FROM sys.index_columns more WHERE more.object_id=ix.object_id
          AND more.index_id=ix.index_id AND more.key_ordinal>1))
    THROW 50006,'AuditLog must have the supplied clustered primary key on AuditID.',1;
IF NOT EXISTS(SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID(N'dbo.AuditLog')
    AND name=N'ChangedDate' AND default_object_id<>0)
    THROW 50006,'AuditLog.ChangedDate must have the supplied timestamp default.',1;
IF OBJECT_ID(N'dbo.AUDIT_LOG_CONTEXT',N'U') IS NULL
    EXEC(N'/* Technical event context stays outside the client''s nine-column AuditLog.
   EntityKey is nullable: historical client-layout rows did not record it. */
CREATE TABLE dbo.AUDIT_LOG_CONTEXT
(
    AuditID INT NOT NULL CONSTRAINT PK_AUDIT_LOG_CONTEXT PRIMARY KEY,
    OriginalUPRID BIGINT NULL,
    EntityKey NVARCHAR(200) NULL,
    RunID UNIQUEIDENTIFIER NULL,
    SessionID INT NULL,
    ChangeSummary NVARCHAR(2000) NULL,
    CONSTRAINT FK_AUDIT_LOG_CONTEXT_Event FOREIGN KEY (AuditID) REFERENCES dbo.AuditLog(AuditID) ON DELETE CASCADE
);
');
IF OBJECT_ID(N'dbo.UPR_CONDO_LEGACY', N'U') IS NULL
    EXEC(N'CREATE TABLE dbo.UPR_CONDO_LEGACY
(
    CondoID BIGINT NOT NULL CONSTRAINT PK_UPR_CONDO_LEGACY PRIMARY KEY,
    UPRID BIGINT NOT NULL,
    CondoName VARCHAR(200) NULL,
    Parcel VARCHAR(20) NULL,
    ArchivedDate DATETIME2 NOT NULL DEFAULT (SYSUTCDATETIME())
);');
/* Preserve legacy Condo values before removing the requested columns.
   Repeated installs do not re-archive or erase the original values. */
IF COL_LENGTH(N'dbo.CONDO', N'CondoName') IS NOT NULL OR COL_LENGTH(N'dbo.CONDO', N'Parcel') IS NOT NULL
BEGIN
    DECLARE @ArchiveSQL NVARCHAR(MAX) = N'INSERT dbo.UPR_CONDO_LEGACY (CondoID, UPRID, CondoName, Parcel)
        SELECT c.CondoID, c.UPRID, '
        + CASE WHEN COL_LENGTH(N'dbo.CONDO', N'CondoName') IS NOT NULL THEN N'c.CondoName' ELSE N'NULL' END
        + N', ' + CASE WHEN COL_LENGTH(N'dbo.CONDO', N'Parcel') IS NOT NULL THEN N'c.Parcel' ELSE N'NULL' END
        + N' FROM dbo.CONDO c WHERE NOT EXISTS (SELECT 1 FROM dbo.UPR_CONDO_LEGACY h WHERE h.CondoID = c.CondoID);';
    EXEC sys.sp_executesql @ArchiveSQL;
    IF COL_LENGTH(N'dbo.CONDO', N'CondoName') IS NOT NULL
        EXEC(N'ALTER TABLE dbo.CONDO DROP COLUMN CondoName;');
    IF COL_LENGTH(N'dbo.CONDO', N'Parcel') IS NOT NULL
        EXEC(N'ALTER TABLE dbo.CONDO DROP COLUMN Parcel;');
END;
IF COL_LENGTH(N'dbo.UPR_CLOSURE', N'AncestorUPRID') IS NOT NULL
BEGIN
    IF COL_LENGTH(N'dbo.UPR_CLOSURE', N'UPRAncestry') IS NOT NULL
        THROW 50004, 'Both closure ancestry columns exist; resolve before migration.', 1;
    EXEC sys.sp_rename N'dbo.UPR_CLOSURE.AncestorUPRID', N'UPRAncestry', N'COLUMN';
END;
IF OBJECT_ID(N'dbo.UPR_LOAD_RUN', N'U') IS NULL
    EXEC(N'CREATE TABLE dbo.UPR_LOAD_RUN
    (
        RunID UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_UPR_LOAD_RUN PRIMARY KEY,
        StartedAt DATETIME2(3) NOT NULL,
        FinishedAt DATETIME2(3) NULL,
        RunStatus VARCHAR(12) NOT NULL,
        StartedBy NVARCHAR(100) NOT NULL,
        SessionID INT NOT NULL,
        SourceRowsRead INT NULL,
        RejectedRows INT NULL,
        ErrorMessage NVARCHAR(4000) NULL,
        CONSTRAINT CK_UPR_LOAD_RUN_Status CHECK (RunStatus IN (''RUNNING'', ''COMPLETED'', ''FAILED''))
    );');
CREATE TABLE #History
(
    AuditID BIGINT NOT NULL PRIMARY KEY, UPRID BIGINT NULL, OriginalUPRID BIGINT NULL,
    EntityNameID INT NOT NULL, EntityRecordID BIGINT NOT NULL, EntityKey NVARCHAR(200) NULL,
    OperationType NVARCHAR(20) NOT NULL, ChangedBy NVARCHAR(100) NOT NULL,
    ChangedDate DATETIME2(3) NOT NULL, OldValues NVARCHAR(MAX) NULL, NewValues NVARCHAR(MAX) NULL,
    RunID UNIQUEIDENTIFIER NULL, SessionID INT NULL, ChangeSummary NVARCHAR(2000) NULL
);
IF @Source=N'AUDIT_LOG_PreClientLayout'
    EXEC(N'INSERT #History
        SELECT AuditLogID,COALESCE(OriginalUPRID,UPRID),OriginalUPRID,EntityID,EntityRecordID,EntityKey,
            ActionType,ChangedBy,ChangedDate,OldValues,NewValues,RunID,SessionID,ChangeSummary
        FROM dbo.AUDIT_LOG_PreClientLayout;');
IF @Legacy=1
BEGIN
    IF COL_LENGTH(N'dbo.AuditLog_PreSept17',N'OldValues') IS NULL
        EXEC(N'ALTER TABLE dbo.AuditLog_PreSept17 ADD OldValues NVARCHAR(MAX) NULL;');
    IF COL_LENGTH(N'dbo.AuditLog_PreSept17',N'NewValues') IS NULL
        EXEC(N'ALTER TABLE dbo.AuditLog_PreSept17 ADD NewValues NVARCHAR(MAX) NULL;');
    IF COL_LENGTH(N'dbo.AuditLog_PreSept17',N'RunID') IS NULL
        EXEC(N'ALTER TABLE dbo.AuditLog_PreSept17 ADD RunID UNIQUEIDENTIFIER NULL;');
    IF COL_LENGTH(N'dbo.AuditLog_PreSept17',N'SessionID') IS NULL
        EXEC(N'ALTER TABLE dbo.AuditLog_PreSept17 ADD SessionID INT NULL;');
    IF COL_LENGTH(N'dbo.AuditLog_PreSept17',N'ChangeSummary') IS NULL
        EXEC(N'ALTER TABLE dbo.AuditLog_PreSept17 ADD ChangeSummary NVARCHAR(2000) NULL;');
    EXEC(N'INSERT dbo.REF_ENTITY_IDENTIFICATION(EntityName,EntityDescription)
        SELECT DISTINCT CONVERT(VARCHAR(100),a.EntityName),''Retained audit entity''
        FROM dbo.AuditLog_PreSept17 a
        WHERE NOT EXISTS(SELECT 1 FROM dbo.REF_ENTITY_IDENTIFICATION e WHERE e.EntityName=a.EntityName);
    SELECT a.AuditID,e.EntityID,a.EntityKey,
        RegistryKey=CASE WHEN e.EntityName=''UPR_CLOSURE'' AND ck.UPRAncestry IS NOT NULL AND ck.DescendantUPRID IS NOT NULL
            THEN (SELECT ck.UPRAncestry,ck.DescendantUPRID FOR JSON PATH,WITHOUT_ARRAY_WRAPPER) ELSE a.EntityKey END,
        NativeID=CASE WHEN k.KeyCount=1 THEN k.NativeID END,
        OriginalUPRID=COALESCE(
            TRY_CONVERT(BIGINT,JSON_VALUE(CASE WHEN ISJSON(a.NewValues)=1 THEN a.NewValues ELSE N''{}'' END,''$.UPRID'')),
            TRY_CONVERT(BIGINT,JSON_VALUE(CASE WHEN ISJSON(a.OldValues)=1 THEN a.OldValues ELSE N''{}'' END,''$.UPRID'')),
            CASE WHEN e.EntityName=''UPR'' THEN k.NativeID
                 WHEN e.EntityName=''UPR_CLOSURE'' THEN ck.DescendantUPRID END)
    INTO #LegacyKeys FROM dbo.AuditLog_PreSept17 a
    JOIN dbo.REF_ENTITY_IDENTIFICATION e ON e.EntityName=a.EntityName
    OUTER APPLY(SELECT COUNT(*) KeyCount,MAX(TRY_CONVERT(BIGINT,value)) NativeID
        FROM OPENJSON(CASE WHEN ISJSON(a.EntityKey)=1 THEN a.EntityKey ELSE N''{}'' END)) k
    OUTER APPLY(SELECT
        UPRAncestry=COALESCE(
            TRY_CONVERT(BIGINT,JSON_VALUE(CASE WHEN ISJSON(a.EntityKey)=1 THEN a.EntityKey ELSE N''{}'' END,''$.UPRAncestry'')),
            TRY_CONVERT(BIGINT,JSON_VALUE(CASE WHEN ISJSON(a.EntityKey)=1 THEN a.EntityKey ELSE N''{}'' END,''$.AncestorUPRID''))),
        DescendantUPRID=TRY_CONVERT(BIGINT,JSON_VALUE(CASE WHEN ISJSON(a.EntityKey)=1 THEN a.EntityKey ELSE N''{}'' END,''$.DescendantUPRID''))) ck;
    INSERT dbo.AUDIT_ENTITY_RECORD(EntityID,EntityKey)
        SELECT DISTINCT k.EntityID,k.RegistryKey FROM #LegacyKeys k WHERE k.NativeID IS NULL
        AND NOT EXISTS(SELECT 1 FROM dbo.AUDIT_ENTITY_RECORD r WHERE r.EntityID=k.EntityID AND r.EntityKey=k.RegistryKey);
    INSERT #History
        SELECT a.AuditID,k.OriginalUPRID,k.OriginalUPRID,k.EntityID,COALESCE(k.NativeID,-r.RecordID),a.EntityKey,
            a.OperationType,a.ChangedBy,a.ChangedDate,a.OldValues,a.NewValues,a.RunID,a.SessionID,a.ChangeSummary
        FROM dbo.AuditLog_PreSept17 a JOIN #LegacyKeys k ON k.AuditID=a.AuditID
        LEFT JOIN dbo.AUDIT_ENTITY_RECORD r ON r.EntityID=k.EntityID AND r.EntityKey=k.RegistryKey;');
END;
IF EXISTS(SELECT 1 FROM #History WHERE AuditID NOT BETWEEN -2147483648 AND 2147483647)
    THROW 50005,'Existing AuditIDs do not fit the client INT layout. No IDs were truncated; migration rolled back.',1;
IF EXISTS(SELECT 1 FROM #History WHERE ChangedDate>DATEADD(MINUTE,1,SYSDATETIME()))
    THROW 50005,'Historical audit dates fail the supplied future-date constraint. Resolve before migration.',1;
IF EXISTS(SELECT 1 FROM #History h WHERE NOT EXISTS(SELECT 1 FROM dbo.REF_ENTITY_IDENTIFICATION e WHERE e.EntityID=h.EntityNameID))
    THROW 50005,'Historical entity IDs have no name mapping. Supply the entity reference mapping before migration.',1;
EXEC(N'
    IF EXISTS(SELECT 1 FROM dbo.AuditLog a WHERE NOT EXISTS(
        SELECT 1 FROM dbo.REF_ENTITY_IDENTIFICATION e WHERE e.EntityID=a.EntityNameID))
        THROW 50005,''Existing EntityNameID values have no mapping in REF_ENTITY_IDENTIFICATION. Supply the mapping; IDs will not be guessed.'',1;
    IF EXISTS(SELECT 1 FROM #History h JOIN dbo.AuditLog a ON a.AuditID=h.AuditID)
        THROW 50005,''Overlapping audit IDs require explicit reconciliation.'',1;
    SET IDENTITY_INSERT dbo.AuditLog ON;
    INSERT dbo.AuditLog(AuditID,UPRID,EntityNameID,EntityRecordID,OperationType,ChangedBy,ChangedDate,OldValues,NewValues)
        SELECT CONVERT(INT,AuditID),UPRID,EntityNameID,EntityRecordID,OperationType,ChangedBy,ChangedDate,OldValues,NewValues
        FROM #History;
    SET IDENTITY_INSERT dbo.AuditLog OFF;
    INSERT dbo.AUDIT_LOG_CONTEXT(AuditID,OriginalUPRID,EntityKey,RunID,SessionID,ChangeSummary)
        SELECT CONVERT(INT,AuditID),OriginalUPRID,EntityKey,RunID,SessionID,ChangeSummary FROM #History;
    /* Do not invent missing original keys, runs, sessions or summaries for the
       client nine-column history. UPRID is the supplied event association. */
    INSERT dbo.AUDIT_LOG_CONTEXT(AuditID,OriginalUPRID)
        SELECT a.AuditID,a.UPRID FROM dbo.AuditLog a
        WHERE NOT EXISTS(SELECT 1 FROM dbo.AUDIT_LOG_CONTEXT c WHERE c.AuditID=a.AuditID);
');
EXEC(N'/* Earlier September 23 candidates registered old closure JSON under its old
   column spelling. Reconcile those IDs without changing original event JSON. */
SELECT r.RecordID, r.EntityID,
    CanonicalKey = (SELECT k.UPRAncestry, k.DescendantUPRID FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
INTO #ClosureAuditAliases
FROM dbo.AUDIT_ENTITY_RECORD r JOIN dbo.REF_ENTITY_IDENTIFICATION e ON e.EntityID = r.EntityID
CROSS APPLY (SELECT
    UPRAncestry = TRY_CONVERT(BIGINT,JSON_VALUE(CASE WHEN ISJSON(r.EntityKey)=1 THEN r.EntityKey ELSE N''{}'' END,''$.AncestorUPRID'')),
    DescendantUPRID = TRY_CONVERT(BIGINT,JSON_VALUE(CASE WHEN ISJSON(r.EntityKey)=1 THEN r.EntityKey ELSE N''{}'' END,''$.DescendantUPRID''))) k
WHERE e.EntityName = ''UPR_CLOSURE'' AND k.UPRAncestry IS NOT NULL AND k.DescendantUPRID IS NOT NULL;
INSERT dbo.AUDIT_ENTITY_RECORD (EntityID,EntityKey)
SELECT DISTINCT a.EntityID,a.CanonicalKey FROM #ClosureAuditAliases a
WHERE NOT EXISTS (SELECT 1 FROM dbo.AUDIT_ENTITY_RECORD r WHERE r.EntityID=a.EntityID AND r.EntityKey=a.CanonicalKey);
UPDATE ev SET EntityRecordID = -canonical.RecordID
FROM dbo.AuditLog ev JOIN #ClosureAuditAliases old ON old.EntityID=ev.EntityNameID AND ev.EntityRecordID=-old.RecordID
JOIN dbo.AUDIT_ENTITY_RECORD canonical ON canonical.EntityID=old.EntityID AND canonical.EntityKey=old.CanonicalKey
WHERE ev.EntityRecordID <> -canonical.RecordID;');
EXEC(N'CREATE OR ALTER VIEW dbo.AUDIT_LOG AS
SELECT a.AuditID AS AuditLogID,
    /* Compatibility UPRID remains a live link. The main table retains the
       event''s original association even after deletion of that UPR. */
    live.UPRID, COALESCE(c.OriginalUPRID,a.UPRID) AS OriginalUPRID,
    a.EntityNameID AS EntityID, a.EntityRecordID, c.EntityKey,
    a.OperationType AS ActionType, a.ChangedDate, a.ChangedBy, a.OldValues, a.NewValues,
    c.RunID, c.SessionID, c.ChangeSummary,
    a.AuditID, e.EntityName, a.OperationType
FROM dbo.AuditLog a
LEFT JOIN dbo.AUDIT_LOG_CONTEXT c ON c.AuditID=a.AuditID
LEFT JOIN dbo.UPR live ON live.UPRID=a.UPRID
LEFT JOIN dbo.REF_ENTITY_IDENTIFICATION e ON e.EntityID=a.EntityNameID;
');
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'dbo.AuditLog') AND name=N'IX_AuditLog_Entity')
    EXEC(N'CREATE INDEX IX_AuditLog_Entity ON dbo.AuditLog(EntityNameID,EntityRecordID,AuditID);');
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'dbo.AuditLog') AND name=N'IX_AuditLog_UPRID')
    EXEC(N'CREATE INDEX IX_AuditLog_UPRID ON dbo.AuditLog(UPRID,AuditID);');
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'dbo.AUDIT_LOG_CONTEXT') AND name=N'IX_AUDIT_LOG_CONTEXT_Run')
    EXEC(N'CREATE INDEX IX_AUDIT_LOG_CONTEXT_Run ON dbo.AUDIT_LOG_CONTEXT(RunID,AuditID);');
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'dbo.AUDIT_LOG_CONTEXT') AND name=N'IX_AUDIT_LOG_CONTEXT_OriginalUPRID')
    EXEC(N'CREATE INDEX IX_AUDIT_LOG_CONTEXT_OriginalUPRID ON dbo.AUDIT_LOG_CONTEXT(OriginalUPRID,AuditID);');
IF OBJECT_ID(N'dbo.UPRSTATUSHISTORY',N'U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'dbo.UPRSTATUSHISTORY') AND name=N'IX_UPRSTATUSHISTORY_ParcelLookup')
    EXEC(N'CREATE INDEX IX_UPRSTATUSHISTORY_ParcelLookup ON dbo.UPRSTATUSHISTORY(UPRID,ChangeSource,ChangedDate DESC,UPRStatusHistoryID DESC) INCLUDE(ParcelID);');
/* Restore SELECT permissions that still map to columns in each public object.
   Obsolete columns are not granted elsewhere implicitly; legacy writers must
   adopt the documented core/context contract. Existing client-table grants stay. */
DECLARE @GrantSQL NVARCHAR(MAX)=N'';
SELECT @GrantSQL+=CASE p.PermissionState WHEN 'D' THEN N'DENY ' ELSE N'GRANT ' END
    +N'SELECT ON OBJECT::dbo.'+QUOTENAME(p.ObjectName)
    +CASE WHEN p.ColumnName IS NULL THEN N'' ELSE N' ('+QUOTENAME(p.ColumnName)+N')' END
    +N' TO '+QUOTENAME(p.PrincipalName)
    +CASE WHEN p.PermissionState='W' THEN N' WITH GRANT OPTION' ELSE N'' END+N';'
FROM #AuditReaderPermissions p
WHERE p.ColumnName IS NULL OR EXISTS(SELECT 1 FROM sys.columns c
    WHERE c.object_id=OBJECT_ID(N'dbo.'+p.ObjectName) AND c.name=p.ColumnName);
IF @GrantSQL<>N'' EXEC sys.sp_executesql @GrantSQL;
EXEC(N'DECLARE @Tables TABLE (TableName SYSNAME PRIMARY KEY);
INSERT @Tables VALUES
    (N''UPR''), (N''ADDRESS''), (N''COMPLEX''), (N''PROPERTY''), (N''CONDO''),
    (N''BUILDING''), (N''UNIT''), (N''ADU''), (N''CONTACT''), (N''UPR_ADDRESS''),
    (N''UPR_CONTACT''), (N''EXTERNAL_IDENTIFIER_XREF''), (N''UPR_CLOSURE''),
    (N''UPRMATCHREVIEW_Q''), (N''UPRSTATUSHISTORY''), (N''REF_ENTITYTYPE''),
    (N''REF_PROPERTYTYPE''), (N''REF_PROPERTY_STATUSCODE''), (N''REF_CONTACTTYPE''),
    (N''REF_ROLETYPE''), (N''REF_ADDRESSROLE''), (N''REF_UNITTYPECODE'');

IF EXISTS (SELECT 1 FROM @Tables WHERE OBJECT_ID(N''dbo.'' + TableName, N''U'') IS NULL)
    THROW 50002, ''A required UPR table is missing; audit installation was rolled back.'', 1;

INSERT @Tables VALUES (N''REF_ENTITY_IDENTIFICATION'');
INSERT dbo.REF_ENTITY_IDENTIFICATION (EntityName, EntityDescription)
SELECT TableName, ''UPR model row changes'' FROM @Tables t
WHERE NOT EXISTS (SELECT 1 FROM dbo.REF_ENTITY_IDENTIFICATION e WHERE e.EntityName = t.TableName);
IF NOT EXISTS (SELECT 1 FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityName = ''UPR_HIER_LOAD'')
    INSERT dbo.REF_ENTITY_IDENTIFICATION (EntityName, EntityDescription) VALUES (''UPR_HIER_LOAD'', ''Load summary (EntityRecordID 0; RunID identifies the run)'');

DECLARE @Table SYSNAME, @ObjectID INT, @Join NVARCHAR(MAX), @Key NVARCHAR(MAX),
    @FirstKey SYSNAME, @DDL NVARCHAR(MAX), @EntityID INT, @Native NVARCHAR(MAX),
    @UPR NVARCHAR(MAX), @KeyCount INT, @FirstType SYSNAME;
DECLARE AuditTables CURSOR LOCAL FAST_FORWARD FOR SELECT TableName FROM @Tables;
OPEN AuditTables;
FETCH NEXT FROM AuditTables INTO @Table;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @EntityID = EntityID FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityName = @Table;
    SET @ObjectID = OBJECT_ID(N''dbo.'' + @Table);
    SET @Join = N'''';
    SET @Key = N'''';
    SET @FirstKey = NULL;
    SET @KeyCount = 0;
    DECLARE @Column SYSNAME, @Type SYSNAME;
    DECLARE KeyColumns CURSOR LOCAL FAST_FORWARD FOR
        SELECT c.name, TYPE_NAME(c.system_type_id)
        FROM sys.indexes ix
        JOIN sys.index_columns ic ON ic.object_id = ix.object_id AND ic.index_id = ix.index_id
        JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        WHERE ix.object_id = @ObjectID AND ix.is_primary_key = 1 AND ic.key_ordinal > 0
        ORDER BY ic.key_ordinal;
    OPEN KeyColumns;
    FETCH NEXT FROM KeyColumns INTO @Column, @Type;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Join += CASE WHEN @Join = N'''' THEN N'''' ELSE N'' AND '' END
            + N''i.'' + QUOTENAME(@Column) + N'' = d.'' + QUOTENAME(@Column);
        SET @Key += CASE WHEN @Key = N'''' THEN N'''' ELSE N'', '' END
            + N''COALESCE(i.'' + QUOTENAME(@Column) + N'', d.'' + QUOTENAME(@Column) + N'') AS '' + QUOTENAME(@Column);
        IF @FirstKey IS NULL SELECT @FirstKey = @Column, @FirstType = @Type;
        SET @KeyCount += 1;
        FETCH NEXT FROM KeyColumns INTO @Column, @Type;
    END;
    CLOSE KeyColumns;
    DEALLOCATE KeyColumns;
    IF @FirstKey IS NULL THROW 50005, ''An audited UPR table has no primary key.'', 1;
    SET @Native = CASE WHEN @KeyCount = 1 AND @FirstType IN (''int'',''bigint'',''smallint'',''tinyint'')
        THEN N''CONVERT(BIGINT, COALESCE(i.'' + QUOTENAME(@FirstKey) + N'', d.'' + QUOTENAME(@FirstKey) + N''))''
        ELSE N''CAST(NULL AS BIGINT)'' END;
    SET @UPR = CASE
        WHEN COL_LENGTH(N''dbo.'' + @Table, N''UPRID'') IS NOT NULL THEN N''COALESCE(i.UPRID, d.UPRID)''
        WHEN @Table = N''UPR_CLOSURE'' THEN N''COALESCE(i.DescendantUPRID, d.DescendantUPRID)''
        WHEN @Table = N''ADDRESS'' THEN N''(SELECT CASE WHEN COUNT(DISTINCT UPRID) = 1 THEN MIN(UPRID) END FROM dbo.UPR_ADDRESS WHERE AddressID = COALESCE(i.AddressID,d.AddressID))''
        WHEN @Table = N''CONTACT'' THEN N''(SELECT CASE WHEN COUNT(DISTINCT UPRID) = 1 THEN MIN(UPRID) END FROM dbo.UPR_CONTACT WHERE ContactID = COALESCE(i.ContactID,d.ContactID))''
        ELSE N''CAST(NULL AS BIGINT)'' END;
    SET @DDL = N''CREATE OR ALTER TRIGGER dbo.'' + QUOTENAME(N''tr_UPR_Audit_'' + @Table)
        + N'' ON dbo.'' + QUOTENAME(@Table) + N'' AFTER INSERT, UPDATE, DELETE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;
    DECLARE @RunID UNIQUEIDENTIFIER = TRY_CONVERT(UNIQUEIDENTIFIER, CONVERT(NVARCHAR(128), SESSION_CONTEXT(N''''UPR_AuditRunID'''')));
    IF NOT EXISTS (SELECT 1 FROM dbo.UPR_LOAD_RUN WHERE RunID = @RunID AND SessionID = @@SPID AND RunStatus = ''''RUNNING'''')
        SET @RunID = NULL;
    SELECT EntityKey = (SELECT '' + @Key + N'' FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
        NativeID = '' + @Native + N'', OriginalUPRID = '' + @UPR + N'',
        ActionType = CASE WHEN d.'' + QUOTENAME(@FirstKey) + N'' IS NULL THEN ''''INSERT''''
                          WHEN i.'' + QUOTENAME(@FirstKey) + N'' IS NULL THEN ''''DELETE'''' ELSE ''''UPDATE'''' END,
        OldValues = CASE WHEN d.'' + QUOTENAME(@FirstKey) + N'' IS NOT NULL
            THEN (SELECT d.* FOR JSON PATH, INCLUDE_NULL_VALUES, WITHOUT_ARRAY_WRAPPER) END,
        NewValues = CASE WHEN i.'' + QUOTENAME(@FirstKey) + N'' IS NOT NULL
            THEN (SELECT i.* FOR JSON PATH, INCLUDE_NULL_VALUES, WITHOUT_ARRAY_WRAPPER) END
    INTO #Events FROM inserted i FULL OUTER JOIN deleted d ON '' + @Join + N'';
    INSERT dbo.AUDIT_ENTITY_RECORD (EntityID, EntityKey)
    SELECT DISTINCT '' + CONVERT(NVARCHAR(12), @EntityID) + N'', ev.EntityKey FROM #Events ev
    WHERE ev.NativeID IS NULL AND NOT EXISTS (SELECT 1 FROM dbo.AUDIT_ENTITY_RECORD r WITH (UPDLOCK, HOLDLOCK)
        WHERE r.EntityID = '' + CONVERT(NVARCHAR(12), @EntityID) + N'' AND r.EntityKey = ev.EntityKey);
    DECLARE @Written TABLE (AuditID INT NOT NULL, OriginalUPRID BIGINT NULL, EntityKey NVARCHAR(200) NOT NULL);
    MERGE dbo.AuditLog AS target
    USING (SELECT ev.*, COALESCE(ev.NativeID, -r.RecordID) AS RecordID
        FROM #Events ev LEFT JOIN dbo.AUDIT_ENTITY_RECORD r
          ON r.EntityID = '' + CONVERT(NVARCHAR(12), @EntityID) + N'' AND r.EntityKey = ev.EntityKey) AS src
    ON 1 = 0
    WHEN NOT MATCHED THEN INSERT (UPRID, EntityNameID, EntityRecordID, OperationType, ChangedBy, OldValues, NewValues)
        VALUES (src.OriginalUPRID, '' + CONVERT(NVARCHAR(12), @EntityID) + N'', src.RecordID,
            src.ActionType, LEFT(ORIGINAL_LOGIN(),100), src.OldValues, src.NewValues)
    OUTPUT inserted.AuditID, src.OriginalUPRID, src.EntityKey INTO @Written;
    INSERT dbo.AUDIT_LOG_CONTEXT (AuditID, OriginalUPRID, EntityKey, RunID, SessionID)
    SELECT AuditID, OriginalUPRID, EntityKey, @RunID, @@SPID FROM @Written;
END;'';
    EXEC sys.sp_executesql @DDL;
    SET @DDL = N''ENABLE TRIGGER dbo.'' + QUOTENAME(N''tr_UPR_Audit_'' + @Table) + N'' ON dbo.'' + QUOTENAME(@Table) + N'';'';
    EXEC sys.sp_executesql @DDL;
    FETCH NEXT FROM AuditTables INTO @Table;
END;
CLOSE AuditTables;
DEALLOCATE AuditTables;
');
COMMIT TRANSACTION;
PRINT N'Client AuditLog layout installed; technical context retained separately; 23 model/reference tables audited.';
PRINT N'Reinstall the updated loader, search, hierarchy and audit reports before resuming writes.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
