/* Read-only diagnostic: select the client's intended database in SSMS first.
   No USE statement: report the actual selected database without redirecting it.
   Send all result sets along with the loader's Messages output. */
SET NOCOUNT ON;

SELECT @@SERVERNAME AS ServerName, DB_NAME() AS DatabaseName;

WITH RequiredColumns AS (
    SELECT TableName, ColumnName
    FROM (VALUES
        (N'UPR_CLOSURE', N'UPRAncestry'),
        (N'UPR_CLOSURE', N'DescendantUPRID'),
        (N'UPR_CLOSURE', N'Level'),
        (N'AuditLog', N'AuditID'),
        (N'AuditLog', N'UPRID'),
        (N'AuditLog', N'EntityNameID'),
        (N'AuditLog', N'EntityRecordID'),
        (N'AuditLog', N'OperationType'),
        (N'AuditLog', N'ChangedBy'),
        (N'AuditLog', N'ChangedDate'),
        (N'AuditLog', N'OldValues'),
        (N'AuditLog', N'NewValues'),
        (N'AUDIT_LOG_CONTEXT', N'AuditID'),
        (N'AUDIT_LOG_CONTEXT', N'OriginalUPRID'),
        (N'AUDIT_LOG_CONTEXT', N'EntityKey'),
        (N'AUDIT_LOG_CONTEXT', N'RunID'),
        (N'AUDIT_LOG_CONTEXT', N'SessionID'),
        (N'AUDIT_LOG_CONTEXT', N'ChangeSummary'),
        (N'REF_ENTITY_IDENTIFICATION', N'EntityID'),
        (N'UPR_LOAD_RUN', N'RunID'),
        (N'UPR_LOAD_RUN', N'RunStatus'),
        (N'UPR_LOAD_RUN', N'StartedAt'),
        (N'UPR_LOAD_RUN', N'FinishedAt'),
        (N'UPR_LOAD_RUN', N'StartedBy'),
        (N'UPR_LOAD_RUN', N'SessionID'),
        (N'UPR_LOAD_RUN', N'SourceRowsRead'),
        (N'UPR_LOAD_RUN', N'RejectedRows'),
        (N'UPR_LOAD_RUN', N'ErrorMessage')
    ) v(TableName, ColumnName)
)
SELECT r.TableName, r.ColumnName,
    CASE WHEN t.object_id IS NULL THEN N'TABLE MISSING OR NOT VISIBLE'
         WHEN c.column_id IS NULL THEN N'COLUMN MISSING OR NOT VISIBLE'
         ELSE N'PRESENT' END AS MetadataStatus,
    TYPE_NAME(c.user_type_id) AS DataType, c.is_nullable AS IsNullable
FROM RequiredColumns r
LEFT JOIN sys.tables t ON t.schema_id = SCHEMA_ID(N'dbo') AND t.name = r.TableName
LEFT JOIN sys.columns c ON c.object_id = t.object_id AND c.name = r.ColumnName
ORDER BY r.TableName, r.ColumnName;

-- Full physical layout, including precision/defaults: compare with the client SQL.
SELECT t.name AS TableName,c.column_id,c.name AS ColumnName,TYPE_NAME(c.system_type_id) AS DataType,
    c.max_length,c.[precision],c.scale,c.is_nullable,c.is_identity,d.[definition] AS DefaultDefinition
FROM sys.tables t JOIN sys.columns c ON c.object_id=t.object_id
LEFT JOIN sys.default_constraints d ON d.object_id=c.default_object_id
WHERE t.schema_id=SCHEMA_ID(N'dbo') AND t.name IN(N'AuditLog',N'AUDIT_LOG_CONTEXT',N'REF_ENTITY_IDENTIFICATION')
ORDER BY t.name,c.column_id;
SELECT o.name,o.type_desc FROM sys.objects o WHERE o.schema_id=SCHEMA_ID(N'dbo')
    AND o.name IN(N'AuditLog',N'AUDIT_LOG',N'AUDIT_LOG_CONTEXT',N'AuditLog_PreSept17',N'AUDIT_LOG_PreClientLayout');

SELECT name,[definition],is_disabled,is_not_trusted FROM sys.check_constraints
WHERE parent_object_id=OBJECT_ID(N'dbo.AuditLog');
