/*
  Install persistent auditing on the 22 UPR model/reference tables.
  Run after the schema and BEFORE the loader; safe on an existing database.
  Does not rebuild tables or manufacture historical audit records.

  Each committed INSERT/UPDATE/DELETE writes the row key, login, timestamp,
  and full JSON before/after values to AuditLog, including writes from outside
  the loader. Audit writes share the business transaction and roll back with it.
  Load changes share a RunID; UPR_LOAD_RUN records completed/failed/empty runs.
  Incoming staging tables and AuditLog itself are outside this model audit.
  SELECT, DDL, TRUNCATE, and failed/rolled-back attempts need SQL Server Audit
  if those operations also need to be retained.
*/
USE UPRXDB_TEST;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID(N'dbo.AuditLog', N'U') IS NULL
    THROW 50001, 'Create the UPR schema before installing audit triggers.', 1;

BEGIN TRY
BEGIN TRANSACTION;
IF COL_LENGTH(N'dbo.AuditLog', N'OldValues') IS NULL
    ALTER TABLE dbo.AuditLog ADD OldValues NVARCHAR(MAX) NULL;
IF COL_LENGTH(N'dbo.AuditLog', N'NewValues') IS NULL
    ALTER TABLE dbo.AuditLog ADD NewValues NVARCHAR(MAX) NULL;
IF COL_LENGTH(N'dbo.AuditLog', N'RunID') IS NULL
    ALTER TABLE dbo.AuditLog ADD RunID UNIQUEIDENTIFIER NULL;
IF COL_LENGTH(N'dbo.AuditLog', N'SessionID') IS NULL
    ALTER TABLE dbo.AuditLog ADD SessionID INT NULL;

IF OBJECT_ID(N'dbo.UPR_LOAD_RUN', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.UPR_LOAD_RUN
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
        CONSTRAINT CK_UPR_LOAD_RUN_Status CHECK (RunStatus IN ('RUNNING', 'COMPLETED', 'FAILED'))
    );
END;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.AuditLog')
               AND name = N'IX_AuditLog_RunID')
    EXEC(N'CREATE INDEX IX_AuditLog_RunID ON dbo.AuditLog (RunID, AuditID) INCLUDE (EntityName, OperationType);');

DECLARE @Tables TABLE (TableName SYSNAME PRIMARY KEY);
INSERT @Tables VALUES
    (N'UPR'), (N'ADDRESS'), (N'COMPLEX'), (N'PROPERTY'), (N'CONDO'),
    (N'BUILDING'), (N'UNIT'), (N'ADU'), (N'CONTACT'), (N'UPR_ADDRESS'),
    (N'UPR_CONTACT'), (N'EXTERNAL_IDENTIFIER_XREF'), (N'UPR_CLOSURE'),
    (N'UPRMATCHREVIEW_Q'), (N'UPRSTATUSHISTORY'), (N'REF_ENTITYTYPE'),
    (N'REF_PROPERTYTYPE'), (N'REF_PROPERTY_STATUSCODE'), (N'REF_CONTACTTYPE'),
    (N'REF_ROLETYPE'), (N'REF_ADDRESSROLE'), (N'REF_UNITTYPECODE');

IF EXISTS (SELECT 1 FROM @Tables WHERE OBJECT_ID(N'dbo.' + TableName, N'U') IS NULL)
    THROW 50002, 'A required UPR table is missing; audit installation was rolled back.', 1;

DECLARE @Table SYSNAME, @ObjectID INT, @Join NVARCHAR(MAX), @Key NVARCHAR(MAX),
        @FirstKey SYSNAME, @DDL NVARCHAR(MAX);
DECLARE AuditTables CURSOR LOCAL FAST_FORWARD FOR SELECT TableName FROM @Tables;
OPEN AuditTables;
FETCH NEXT FROM AuditTables INTO @Table;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ObjectID = OBJECT_ID(N'dbo.' + @Table);
    SET @Join = N'';
    SET @Key = N'';
    SET @FirstKey = NULL;
    /* Composite keys (UPR_CLOSURE) are preserved in EntityKey JSON. */
    SELECT @Join = @Join + CASE WHEN @Join = N'' THEN N'' ELSE N' AND ' END
               + N'i.' + QUOTENAME(c.name) + N' = d.' + QUOTENAME(c.name),
           @Key = @Key + CASE WHEN @Key = N'' THEN N'' ELSE N', ' END
               + N'COALESCE(i.' + QUOTENAME(c.name) + N', d.' + QUOTENAME(c.name)
               + N') AS ' + QUOTENAME(c.name),
           @FirstKey = COALESCE(@FirstKey, c.name)
    FROM sys.indexes ix
    INNER JOIN sys.index_columns ic ON ic.object_id = ix.object_id AND ic.index_id = ix.index_id
    INNER JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    WHERE ix.object_id = @ObjectID AND ix.is_primary_key = 1
      AND ic.key_ordinal > 0;
    IF @FirstKey IS NULL THROW 50003, 'An audited UPR table has no primary key.', 1;

    SET @DDL = N'CREATE OR ALTER TRIGGER dbo.' + QUOTENAME(N'tr_UPR_Audit_' + @Table)
      + N' ON dbo.' + QUOTENAME(@Table) + N' AFTER INSERT, UPDATE, DELETE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;
    DECLARE @RunID UNIQUEIDENTIFIER = TRY_CONVERT(UNIQUEIDENTIFIER,
        CONVERT(NVARCHAR(128), SESSION_CONTEXT(N''UPR_AuditRunID'')));
    /* A stale context from a completed load must not claim later manual edits. */
    IF NOT EXISTS (SELECT 1 FROM dbo.UPR_LOAD_RUN
                   WHERE RunID = @RunID AND SessionID = @@SPID AND RunStatus = ''RUNNING'')
        SET @RunID = NULL;
    INSERT dbo.AuditLog
        (EntityName, EntityKey, OperationType, ChangedBy, ChangedDate, ChangeSummary, OldValues, NewValues, RunID, SessionID)
    SELECT N''' + @Table + N''',
        (SELECT ' + @Key + N' FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
        op.OperationType, LEFT(ORIGINAL_LOGIN(), 100), SYSDATETIME(),
        N''Row '' + op.OperationType,
        CASE WHEN d.' + QUOTENAME(@FirstKey) + N' IS NOT NULL
            THEN (SELECT d.* FOR JSON PATH, INCLUDE_NULL_VALUES, WITHOUT_ARRAY_WRAPPER) END,
        CASE WHEN i.' + QUOTENAME(@FirstKey) + N' IS NOT NULL
            THEN (SELECT i.* FOR JSON PATH, INCLUDE_NULL_VALUES, WITHOUT_ARRAY_WRAPPER) END,
        @RunID, @@SPID
    FROM inserted i FULL OUTER JOIN deleted d ON ' + @Join + N'
    CROSS APPLY (SELECT OperationType = CASE
        WHEN d.' + QUOTENAME(@FirstKey) + N' IS NULL THEN N''INSERT''
        WHEN i.' + QUOTENAME(@FirstKey) + N' IS NULL THEN N''DELETE''
        ELSE N''UPDATE'' END) op;
END;';
    EXEC sys.sp_executesql @DDL;
    SET @DDL = N'ENABLE TRIGGER dbo.' + QUOTENAME(N'tr_UPR_Audit_' + @Table)
        + N' ON dbo.' + QUOTENAME(@Table) + N';';
    EXEC sys.sp_executesql @DDL;
    FETCH NEXT FROM AuditTables INTO @Table;
END;
CLOSE AuditTables;
DEALLOCATE AuditTables;
COMMIT TRANSACTION;
PRINT N'Auditing installed: 22 UPR model/reference tables, row changes with before/after values and load RunID.';
PRINT N'View records with scripts/list_upr_audit.sql.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
