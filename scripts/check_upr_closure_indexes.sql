/* READ ONLY - October 14, 2026: inspect closure index definitions before/after R10.
   Select the intended test database in SSMS (the reported run used UPR7XDB_TEST).
   No USE, schema changes, index changes, or permanent data writes.
   Return these grids if the loader still reports an index-related error.
*/
SET NOCOUNT ON;
SELECT @@SERVERNAME AS ServerName,DB_NAME() AS DatabaseName;
DECLARE @ClosureObjectID INT=OBJECT_ID(N'dbo.UPR_CLOSURE',N'U');
IF @ClosureObjectID IS NULL
    THROW 52200,'dbo.UPR_CLOSURE is missing or not visible in the selected database.',1;

SELECT i.name AS IndexName,i.type_desc AS IndexType,i.is_unique,i.is_primary_key,
    i.is_unique_constraint,i.is_disabled,i.is_hypothetical,i.ignore_dup_key,
    i.has_filter,i.filter_definition,
    c.name AS ColumnName,ic.key_ordinal,ic.is_included_column,ic.is_descending_key,
    ic.partition_ordinal
FROM sys.indexes i
LEFT JOIN sys.index_columns ic ON ic.object_id=i.object_id AND ic.index_id=i.index_id
LEFT JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id
WHERE i.object_id=@ClosureObjectID AND i.index_id>0
ORDER BY i.index_id,ic.is_included_column,ic.key_ordinal,ic.index_column_id;

SELECT N'Unique ancestor/descendant pair' AS Requirement,
    CASE WHEN EXISTS (
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
) THEN N'PASS' ELSE N'MISSING: R10 will add a compatible index using an unused name' END AS Result;

SELECT N'Descendant-first traversal' AS Requirement,
    CASE WHEN EXISTS (
SELECT 1 FROM sys.indexes i
    JOIN sys.index_columns d ON d.object_id=i.object_id AND d.index_id=i.index_id AND d.key_ordinal=1
    JOIN sys.columns dc ON dc.object_id=d.object_id AND dc.column_id=d.column_id
    JOIN sys.index_columns a ON a.object_id=i.object_id AND a.index_id=i.index_id
        AND (a.key_ordinal>1 OR a.is_included_column=1)
    JOIN sys.columns ac ON ac.object_id=a.object_id AND ac.column_id=a.column_id
    WHERE i.object_id=@ClosureObjectID AND i.[type] IN (1,2)
      AND i.is_disabled=0 AND i.has_filter=0 AND i.is_hypothetical=0
      AND dc.name=N'DescendantUPRID' AND ac.name=N'AncestorUPRID'
) THEN N'PASS' ELSE N'MISSING: R10 will add a compatible index using an unused name' END AS Result;

/* Metadata verdict only: not a closure data, capacity or throughput check.
   Existing unique/filtered/disabled indexes are displayed, never removed.
   R10 preserves them; any independent restriction imposed by them still applies. */
