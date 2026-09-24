/* September 17 review migration and persistent row auditing.
   Existing data: run this file BEFORE the new loader/reports, with writers stopped.
   Atomic and repeatable. Old audit table retained as AuditLog_PreSept17;
   AuditLog becomes a compatibility view for reads over normalized AUDIT_LOG.
   Removed Condo values are archived in UPR_CONDO_LEGACY.
   Requires compatibility level 130+ (JSON). No schema reset or source deletion.
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
IF OBJECT_ID(N'dbo.UPR', N'U') IS NULL
    THROW 50001, 'Create the UPR schema before installing audit triggers.', 1;
IF (SELECT compatibility_level FROM sys.databases WHERE database_id = DB_ID()) < 130
    THROW 50002, 'Audit migration requires database compatibility level 130 or later.', 1;
BEGIN TRY
BEGIN TRANSACTION;
DECLARE @Migrating BIT = 0;
IF OBJECT_ID(N'dbo.AuditLog', N'U') IS NOT NULL
BEGIN
    IF OBJECT_ID(N'dbo.AuditLog_PreSept17', N'U') IS NOT NULL
        THROW 50003, 'Both legacy audit tables exist; resolve the migration state before continuing.', 1;
    EXEC sys.sp_rename N'dbo.AuditLog', N'AuditLog_PreSept17';
    SET @Migrating = 1;
END;
IF OBJECT_ID(N'dbo.UPR_CONDO_LEGACY', N'U') IS NULL
    EXEC(N'CREATE TABLE dbo.UPR_CONDO_LEGACY
(
    CondoID BIGINT NOT NULL CONSTRAINT PK_UPR_CONDO_LEGACY PRIMARY KEY,
    UPRID BIGINT NOT NULL,
    CondoName VARCHAR(200) NULL,
    Parcel VARCHAR(20) NULL,
    ArchivedDate DATETIME2 NOT NULL DEFAULT (SYSUTCDATETIME())
);');
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
IF OBJECT_ID(N'dbo.AUDIT_LOG', N'U') IS NULL
    EXEC(N'CREATE TABLE dbo.AUDIT_LOG
(
    AuditLogID BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_AUDIT_LOG PRIMARY KEY,
    UPRID BIGINT NULL,
    OriginalUPRID BIGINT NULL,
    EntityID INT NOT NULL REFERENCES dbo.REF_ENTITY_IDENTIFICATION (EntityID),
    EntityRecordID BIGINT NOT NULL,
    EntityKey NVARCHAR(200) NOT NULL,
    ActionType VARCHAR(20) NOT NULL,
    ChangedDate DATETIME2(3) NOT NULL DEFAULT (SYSDATETIME()),
    ChangedBy NVARCHAR(100) NOT NULL,
    OldValues NVARCHAR(MAX) NULL,
    NewValues NVARCHAR(MAX) NULL,
    RunID UNIQUEIDENTIFIER NULL,
    SessionID INT NULL,
    ChangeSummary NVARCHAR(2000) NULL,
    /* Live FK clears on removal; OriginalUPRID and JSON retain event identity. */
    CONSTRAINT FK_AUDIT_LOG_UPR FOREIGN KEY (UPRID) REFERENCES dbo.UPR (UPRID) ON DELETE SET NULL,
    CONSTRAINT CK_AUDIT_LOG_Action CHECK (ActionType IN (''INSERT'',''UPDATE'',''DELETE'',''MERGE'',''STATUS_CHANGE''))
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
IF @Migrating = 1
BEGIN
    /* Earlier installations may not yet have the optional audit columns. */
    IF COL_LENGTH(N'dbo.AuditLog_PreSept17', N'OldValues') IS NULL
        EXEC(N'ALTER TABLE dbo.AuditLog_PreSept17 ADD OldValues NVARCHAR(MAX) NULL;');
    IF COL_LENGTH(N'dbo.AuditLog_PreSept17', N'NewValues') IS NULL
        EXEC(N'ALTER TABLE dbo.AuditLog_PreSept17 ADD NewValues NVARCHAR(MAX) NULL;');
    IF COL_LENGTH(N'dbo.AuditLog_PreSept17', N'RunID') IS NULL
        EXEC(N'ALTER TABLE dbo.AuditLog_PreSept17 ADD RunID UNIQUEIDENTIFIER NULL;');
    IF COL_LENGTH(N'dbo.AuditLog_PreSept17', N'SessionID') IS NULL
        EXEC(N'ALTER TABLE dbo.AuditLog_PreSept17 ADD SessionID INT NULL;');
    EXEC(N'INSERT dbo.REF_ENTITY_IDENTIFICATION (EntityName, EntityDescription)
SELECT DISTINCT CONVERT(VARCHAR(100), l.EntityName), ''Migrated audit entity''
FROM dbo.AuditLog_PreSept17 l
WHERE NOT EXISTS (SELECT 1 FROM dbo.REF_ENTITY_IDENTIFICATION e WHERE e.EntityName = l.EntityName);
SELECT l.AuditID, e.EntityID, l.EntityKey,
    RegistryKey = CASE WHEN e.EntityName = ''UPR_CLOSURE''
        AND ck.UPRAncestry IS NOT NULL AND ck.DescendantUPRID IS NOT NULL
        THEN (SELECT ck.UPRAncestry, ck.DescendantUPRID FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
        ELSE l.EntityKey END,
    NativeID = CASE WHEN k.KeyCount = 1 THEN k.NativeID END,
    OriginalUPRID = COALESCE(
        TRY_CONVERT(BIGINT, JSON_VALUE(CASE WHEN ISJSON(l.NewValues) = 1 THEN l.NewValues ELSE N''{}'' END, ''$.UPRID'')),
        TRY_CONVERT(BIGINT, JSON_VALUE(CASE WHEN ISJSON(l.OldValues) = 1 THEN l.OldValues ELSE N''{}'' END, ''$.UPRID'')),
        CASE WHEN e.EntityName = ''UPR'' THEN k.NativeID
             WHEN e.EntityName = ''UPR_CLOSURE'' THEN TRY_CONVERT(BIGINT, JSON_VALUE(CASE WHEN ISJSON(l.EntityKey) = 1 THEN l.EntityKey ELSE N''{}'' END, ''$.DescendantUPRID'')) END)
INTO #LegacyAuditKeys
FROM dbo.AuditLog_PreSept17 l
JOIN dbo.REF_ENTITY_IDENTIFICATION e ON e.EntityName = l.EntityName
OUTER APPLY (SELECT COUNT(*) KeyCount, MAX(TRY_CONVERT(BIGINT, value)) NativeID
    FROM OPENJSON(CASE WHEN ISJSON(l.EntityKey) = 1 THEN l.EntityKey ELSE N''{}'' END)) k
OUTER APPLY (SELECT
    UPRAncestry = COALESCE(
        TRY_CONVERT(BIGINT, JSON_VALUE(CASE WHEN ISJSON(l.EntityKey) = 1 THEN l.EntityKey ELSE N''{}'' END, ''$.UPRAncestry'')),
        TRY_CONVERT(BIGINT, JSON_VALUE(CASE WHEN ISJSON(l.EntityKey) = 1 THEN l.EntityKey ELSE N''{}'' END, ''$.AncestorUPRID''))),
    DescendantUPRID = TRY_CONVERT(BIGINT, JSON_VALUE(CASE WHEN ISJSON(l.EntityKey) = 1 THEN l.EntityKey ELSE N''{}'' END, ''$.DescendantUPRID''))) ck;
INSERT dbo.AUDIT_ENTITY_RECORD (EntityID, EntityKey)
SELECT DISTINCT k.EntityID, k.RegistryKey FROM #LegacyAuditKeys k
WHERE k.NativeID IS NULL AND NOT EXISTS (SELECT 1 FROM dbo.AUDIT_ENTITY_RECORD r
    WHERE r.EntityID = k.EntityID AND r.EntityKey = k.RegistryKey);
SET IDENTITY_INSERT dbo.AUDIT_LOG ON;
INSERT dbo.AUDIT_LOG (AuditLogID, UPRID, OriginalUPRID, EntityID, EntityRecordID, EntityKey,
    ActionType, ChangedDate, ChangedBy, OldValues, NewValues, RunID, SessionID, ChangeSummary)
SELECT l.AuditID, u.UPRID, k.OriginalUPRID, k.EntityID, COALESCE(k.NativeID, -r.RecordID), l.EntityKey,
    l.OperationType, l.ChangedDate, l.ChangedBy, l.OldValues, l.NewValues, l.RunID, l.SessionID, l.ChangeSummary
FROM dbo.AuditLog_PreSept17 l JOIN #LegacyAuditKeys k ON k.AuditID = l.AuditID
LEFT JOIN dbo.UPR u ON u.UPRID = k.OriginalUPRID
LEFT JOIN dbo.AUDIT_ENTITY_RECORD r ON r.EntityID = k.EntityID AND r.EntityKey = k.RegistryKey;
SET IDENTITY_INSERT dbo.AUDIT_LOG OFF;');
END;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.AUDIT_LOG') AND name = N'IX_AUDIT_LOG_RunID')
    EXEC(N'CREATE INDEX IX_AUDIT_LOG_RunID ON dbo.AUDIT_LOG (RunID, AuditLogID) INCLUDE (EntityID, ActionType);');
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.AUDIT_LOG') AND name = N'IX_AUDIT_LOG_Entity')
    EXEC(N'CREATE INDEX IX_AUDIT_LOG_Entity ON dbo.AUDIT_LOG (EntityID, EntityRecordID, AuditLogID);');
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.AUDIT_LOG') AND name = N'IX_AUDIT_LOG_UPRID')
    EXEC(N'CREATE INDEX IX_AUDIT_LOG_UPRID ON dbo.AUDIT_LOG (UPRID, AuditLogID);');
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.AUDIT_LOG') AND name = N'IX_AUDIT_LOG_OriginalUPRID')
    EXEC(N'CREATE INDEX IX_AUDIT_LOG_OriginalUPRID ON dbo.AUDIT_LOG (OriginalUPRID, AuditLogID);');
IF OBJECT_ID(N'dbo.UPRSTATUSHISTORY', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.UPRSTATUSHISTORY') AND name = N'IX_UPRSTATUSHISTORY_ParcelLookup')
    EXEC(N'CREATE INDEX IX_UPRSTATUSHISTORY_ParcelLookup ON dbo.UPRSTATUSHISTORY (UPRID, ChangeSource, ChangedDate DESC, UPRStatusHistoryID DESC) INCLUDE (ParcelID);');
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
FROM dbo.AUDIT_LOG ev JOIN #ClosureAuditAliases old ON old.EntityID=ev.EntityID AND ev.EntityRecordID=-old.RecordID
JOIN dbo.AUDIT_ENTITY_RECORD canonical ON canonical.EntityID=old.EntityID AND canonical.EntityKey=old.CanonicalKey
WHERE ev.EntityRecordID <> -canonical.RecordID;');
EXEC(N'CREATE OR ALTER VIEW dbo.AuditLog AS
SELECT a.AuditLogID AS AuditID, e.EntityName, a.EntityKey,
    a.ActionType AS OperationType, a.ChangedBy, a.ChangedDate, a.ChangeSummary,
    a.OldValues, a.NewValues, a.RunID, a.SessionID,
    a.UPRID, a.OriginalUPRID, a.EntityID, a.EntityRecordID
FROM dbo.AUDIT_LOG a
JOIN dbo.REF_ENTITY_IDENTIFICATION e ON e.EntityID = a.EntityID;');
/* Carry existing audit-reader SELECT permissions to the compatibility view.
   Writers must use the new contract; legacy INSERT permissions are not copied. */
IF @Migrating = 1
BEGIN
    DECLARE @GrantSQL NVARCHAR(MAX) = N'';
    SELECT @GrantSQL += CASE p.state WHEN 'D' THEN N'DENY ' ELSE N'GRANT ' END
        + N'SELECT ON OBJECT::dbo.AuditLog'
        + CASE WHEN p.minor_id = 0 THEN N'' ELSE N' (' + QUOTENAME(c.name) + N')' END
        + N' TO ' + QUOTENAME(dp.name)
        + CASE WHEN p.state = 'W' THEN N' WITH GRANT OPTION' ELSE N'' END + N';'
    FROM sys.database_permissions p
    JOIN sys.database_principals dp ON dp.principal_id = p.grantee_principal_id
    LEFT JOIN sys.columns c ON c.object_id = p.major_id AND c.column_id = p.minor_id
    WHERE p.class = 1 AND p.major_id = OBJECT_ID(N'dbo.AuditLog_PreSept17')
      AND p.permission_name = N'SELECT' AND p.state IN ('D','G','W')
      AND (p.minor_id = 0 OR EXISTS (SELECT 1 FROM sys.columns v
           WHERE v.object_id = OBJECT_ID(N'dbo.AuditLog') AND v.name = c.name));
    IF @GrantSQL <> N'' EXEC sys.sp_executesql @GrantSQL;
END;
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
    INSERT dbo.AUDIT_LOG (UPRID, OriginalUPRID, EntityID, EntityRecordID, EntityKey,
        ActionType, ChangedBy, OldValues, NewValues, RunID, SessionID)
    SELECT u.UPRID, ev.OriginalUPRID, '' + CONVERT(NVARCHAR(12), @EntityID) + N'',
        COALESCE(ev.NativeID, -r.RecordID), ev.EntityKey, ev.ActionType, LEFT(ORIGINAL_LOGIN(),100),
        ev.OldValues, ev.NewValues, @RunID, @@SPID
    FROM #Events ev LEFT JOIN dbo.UPR u ON u.UPRID = ev.OriginalUPRID
    LEFT JOIN dbo.AUDIT_ENTITY_RECORD r ON r.EntityID = '' + CONVERT(NVARCHAR(12), @EntityID) + N'' AND r.EntityKey = ev.EntityKey;
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
PRINT N'September 17 schema migration and auditing installed (23 model/reference tables).';
PRINT N'Reinstall hierarchy, search and audit reports before resuming use.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
