/*
  Install persistent auditing on the 22 UPR model/reference tables.
  Run after the schema and BEFORE the loader; safe on an existing database.
  Does not rebuild tables or manufacture historical audit records.

  Each committed INSERT/UPDATE/DELETE writes the row key, login, timestamp,
  and full JSON before/after values to AuditLog, including writes from outside
  the loader. Audit writes share the business transaction and roll back with it.
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
    DECLARE @Operation NVARCHAR(20) = CASE
        WHEN EXISTS (SELECT 1 FROM inserted) AND EXISTS (SELECT 1 FROM deleted) THEN N''UPDATE''
        WHEN EXISTS (SELECT 1 FROM inserted) THEN N''INSERT'' ELSE N''DELETE'' END;
    INSERT dbo.AuditLog
        (EntityName, EntityKey, OperationType, ChangedBy, ChangedDate, ChangeSummary, OldValues, NewValues)
    SELECT N''' + @Table + N''',
        (SELECT ' + @Key + N' FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
        @Operation, LEFT(ORIGINAL_LOGIN(), 100), SYSDATETIME(),
        N''Row '' + @Operation,
        CASE WHEN d.' + QUOTENAME(@FirstKey) + N' IS NOT NULL
            THEN (SELECT d.* FOR JSON PATH, INCLUDE_NULL_VALUES, WITHOUT_ARRAY_WRAPPER) END,
        CASE WHEN i.' + QUOTENAME(@FirstKey) + N' IS NOT NULL
            THEN (SELECT i.* FOR JSON PATH, INCLUDE_NULL_VALUES, WITHOUT_ARRAY_WRAPPER) END
    FROM inserted i FULL OUTER JOIN deleted d ON ' + @Join + N';
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
PRINT N'Auditing installed: 22 UPR model/reference tables, INSERT/UPDATE/DELETE, full before/after values.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
