/* September 29 client test: keep the original API table unchanged.
   Select the intended database in SSMS. Edit @UPRID, then run the entire file.
   Reads dbo.UPR / dbo.UPR_CLOSURE only; all working tables are temporary.
   Expected: PASS and the root-to-selected path, starting at Level 0.
   Level in this report describes each ancestor, not the stored descendant.
*/
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
DECLARE @UPRID BIGINT = 207075;

IF OBJECT_ID(N'dbo.UPR_CLOSURE', N'U') IS NULL
   OR COL_LENGTH(N'dbo.UPR_CLOSURE', N'AncestorUPRID') IS NULL
   OR COL_LENGTH(N'dbo.UPR_CLOSURE', N'DescendantUPRID') IS NULL
   OR COL_LENGTH(N'dbo.UPR_CLOSURE', N'Level') IS NULL
   OR COL_LENGTH(N'dbo.UPR_CLOSURE', N'UPRAncestry') IS NOT NULL
    THROW 51000, 'Expected the original API table: AncestorUPRID, DescendantUPRID and Level. This test does not alter the schema.', 1;
IF @UPRID IS NULL OR NOT EXISTS(SELECT 1 FROM dbo.UPR WHERE UPRID=@UPRID)
    THROW 51000, 'The selected UPRID is not in this database. Set @UPRID to the record to test.', 1;

-- Dynamic batch allows the schema guard to run before column binding.
EXEC sys.sp_executesql N'
CREATE TABLE #Expected (AncestorUPRID BIGINT NOT NULL PRIMARY KEY, StepsFromSelected INT NOT NULL);
DECLARE @Node BIGINT=@SelectedUPRID, @Parent BIGINT, @Steps INT=0;
WHILE @Node IS NOT NULL
BEGIN
    IF EXISTS(SELECT 1 FROM #Expected WHERE AncestorUPRID=@Node)
        THROW 51001, ''The parent hierarchy contains a cycle.'', 1;
    IF NOT EXISTS(SELECT 1 FROM dbo.UPR WHERE UPRID=@Node)
        THROW 51001, ''The parent hierarchy contains a missing parent.'', 1;
    INSERT #Expected VALUES(@Node,@Steps);
    SELECT @Parent=ParentUPRID FROM dbo.UPR WHERE UPRID=@Node;
    SELECT @Node=@Parent, @Steps=@Steps+1;
END;

SELECT node.[Level], path.AncestorUPRID, path.DescendantUPRID
INTO #Actual
FROM dbo.UPR_CLOSURE path
JOIN dbo.UPR_CLOSURE node ON node.AncestorUPRID=path.AncestorUPRID
    AND node.DescendantUPRID=path.AncestorUPRID
WHERE path.DescendantUPRID=@SelectedUPRID;

-- Independent expectation comes from ParentUPRID, not stored closure levels.
IF EXISTS (
    SELECT @Steps-1-StepsFromSelected, AncestorUPRID, @SelectedUPRID FROM #Expected
    EXCEPT SELECT [Level], AncestorUPRID, DescendantUPRID FROM #Actual
) OR EXISTS (
    SELECT [Level], AncestorUPRID, DescendantUPRID FROM #Actual
    EXCEPT SELECT @Steps-1-StepsFromSelected, AncestorUPRID, @SelectedUPRID FROM #Expected
) OR (SELECT COUNT(*) FROM #Actual)<>(SELECT COUNT(*) FROM #Expected)
    THROW 51002, ''FAIL: closure ancestor levels/paths do not match ParentUPRID. Review hierarchy freshness; no data was changed.'', 1;

SELECT Result=N''PASS'', SelectedUPRID=@SelectedUPRID,
    CheckName=N''Original API columns retained; complete ancestor path includes root Level 0'',
    RootUPRID=(SELECT AncestorUPRID FROM #Actual WHERE [Level]=0),
    AncestorRows=(SELECT COUNT(*) FROM #Actual);
SELECT [Level], AncestorUPRID, DescendantUPRID FROM #Actual ORDER BY [Level], AncestorUPRID;
', N'@SelectedUPRID BIGINT', @SelectedUPRID=@UPRID;
