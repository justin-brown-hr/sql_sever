/* READ ONLY: select the SAME test database as the loader.
   Paste the completed loader's Audit RunID below. History is never rewritten.
   Optional AuditID bounds reduce scanning; leave them NULL if not recorded. */
SET NOCOUNT ON;
DECLARE @RunID UNIQUEIDENTIFIER=NULL;
DECLARE @FirstAuditID INT=NULL,@LastAuditID INT=NULL;
IF @RunID IS NULL
BEGIN
    PRINT N'Paste the completed loader Audit RunID into @RunID before running this check.';
    RETURN;
END;
DECLARE @Payload SYSNAME=CASE WHEN COL_LENGTH(N'dbo.AuditLog',N'NewValue') IS NOT NULL THEN N'NewValue'
    WHEN COL_LENGTH(N'dbo.AuditLog',N'NewValues') IS NOT NULL THEN N'NewValues' END;
IF @Payload IS NULL OR (COL_LENGTH(N'dbo.AuditLog',N'NewValue') IS NOT NULL AND COL_LENGTH(N'dbo.AuditLog',N'NewValues') IS NOT NULL)
    THROW 50004,'Audit payload column is missing or ambiguous. Run the schema diagnostic.',1;
DECLARE @Prefix NVARCHAR(100)=N'RunID = '+CONVERT(NVARCHAR(36),@RunID)+NCHAR(10);
IF OBJECT_ID('tempdb..#RunAuditCheck') IS NOT NULL DROP TABLE #RunAuditCheck;
CREATE TABLE #RunAuditCheck(AuditID INT,UPRID BIGINT,EntityNameID INT,EntityRecordID BIGINT,
    OperationType VARCHAR(20),ChangedBy NVARCHAR(100),ChangedDate DATETIME2(7),OldValues NVARCHAR(MAX),NewValue NVARCHAR(MAX));
DECLARE @Sql NVARCHAR(MAX)=N'INSERT #RunAuditCheck
    SELECT AuditID,UPRID,EntityNameID,EntityRecordID,OperationType,ChangedBy,ChangedDate,OldValues,'+QUOTENAME(@Payload)+N'
    FROM dbo.AuditLog WHERE (@first IS NULL OR AuditID>=@first) AND (@last IS NULL OR AuditID<=@last)
      AND (LEFT('+QUOTENAME(@Payload)+N',LEN(@prefix))=@prefix OR LEFT(OldValues,LEN(@prefix))=@prefix);';
EXEC sys.sp_executesql @Sql,N'@first INT,@last INT,@prefix NVARCHAR(100)',@FirstAuditID,@LastAuditID,@Prefix;
DECLARE @SummaryEntityID INT,@SummaryCount INT,@ExpectedRows BIGINT,@ActualRows BIGINT;
IF (SELECT COUNT(*) FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityName=N'UPR_HIER_LOAD')<>1
    THROW 50004,'Summary entity mapping missing or ambiguous.',1;
SELECT @SummaryEntityID=EntityID FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityName=N'UPR_HIER_LOAD';
SELECT @SummaryCount=COUNT(*) FROM #RunAuditCheck WHERE EntityNameID=@SummaryEntityID;
SELECT @ActualRows=COUNT_BIG(*) FROM #RunAuditCheck WHERE EntityNameID<>@SummaryEntityID;
SELECT @ExpectedRows=TRY_CONVERT(BIGINT,SUBSTRING(lines.value,LEN(N'Row audit entries written = ')+1,40))
FROM #RunAuditCheck a CROSS APPLY STRING_SPLIT(a.NewValue,NCHAR(10)) lines
WHERE a.EntityNameID=@SummaryEntityID AND lines.value LIKE N'Row audit entries written = %';
SELECT @RunID AS RunID,@SummaryCount AS BatchSummaries,@ExpectedRows AS ExpectedRowAuditEntries,
    @ActualRows AS ActualRowAuditEntries,
    CASE WHEN @SummaryCount=1 AND @ExpectedRows=@ActualRows THEN N'PASS' ELSE N'FAIL: summary/count mismatch' END AS AuditCountCheck;
SELECT e.EntityName AS TableName,a.OperationType,COUNT_BIG(*) AS AuditEntries
FROM #RunAuditCheck a LEFT JOIN dbo.REF_ENTITY_IDENTIFICATION e ON e.EntityID=a.EntityNameID
GROUP BY e.EntityName,a.OperationType ORDER BY e.EntityName,a.OperationType;
SELECT COUNT_BIG(*) AS InvalidEntityMappings FROM #RunAuditCheck a WHERE
    (SELECT COUNT(*) FROM dbo.REF_ENTITY_IDENTIFICATION e WHERE e.EntityID=a.EntityNameID)<>1;
SELECT COUNT_BIG(*) AS UnexpectedJsonRows FROM #RunAuditCheck WHERE ISJSON(OldValues)=1 OR ISJSON(NewValue)=1;
SELECT TOP(50) a.AuditID,a.UPRID,e.EntityName AS TableName,a.EntityRecordID,a.OperationType,a.ChangedBy,a.ChangedDate,
    CASE WHEN ISJSON(a.OldValues)=1 THEN N'Unexpected JSON value: not displayed' ELSE a.OldValues END AS OldValues,
    CASE WHEN ISJSON(a.NewValue)=1 THEN N'Unexpected JSON value: not displayed' ELSE a.NewValue END AS NewValue
FROM #RunAuditCheck a LEFT JOIN dbo.REF_ENTITY_IDENTIFICATION e ON e.EntityID=a.EntityNameID ORDER BY a.AuditID;
