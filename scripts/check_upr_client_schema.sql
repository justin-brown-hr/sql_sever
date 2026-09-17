/* Read-only diagnostic: select the client's intended database in SSMS first.
   No USE statement: report the actual selected database without redirecting it.
   Send both result sets along with the loader's Messages output. */
SET NOCOUNT ON;

SELECT @@SERVERNAME AS ServerName, DB_NAME() AS DatabaseName;

WITH RequiredColumns AS (
    SELECT TableName, ColumnName
    FROM (VALUES
        (N'UPR_CLOSURE', N'AncestorUPRID'),
        (N'UPR_CLOSURE', N'DescendantUPRID'),
        (N'UPR_CLOSURE', N'Level'),
        (N'AuditLog', N'RunID'),
        (N'AuditLog', N'SessionID'),
        (N'AuditLog', N'OldValues'),
        (N'AuditLog', N'NewValues'),
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
