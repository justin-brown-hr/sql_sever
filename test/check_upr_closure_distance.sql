/* READ-ONLY verification after repair_upr_closure_distance.sql.
   Select the same database used by the API. Run the entire file.
   Checks ALL UPR parent chains, closure pairs and distances; working tables
   are temporary. Traverses upward independently of the repair's downward walk.
   Set @UPRID for the detail output (client example: 207075).
   PASS validates closure against ParentUPRID, not external source correctness.
   The UNIT detail result helps distinguish UnitID from UPRID for API testing.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @UPRID BIGINT = 207075;
IF @@TRANCOUNT<>0 THROW 52100,'Run verification outside an existing transaction.',1;
IF COL_LENGTH(N'dbo.UPR',N'ParentUPRID') IS NULL
 OR COL_LENGTH(N'dbo.UPR_CLOSURE',N'AncestorUPRID') IS NULL
 OR COL_LENGTH(N'dbo.UPR_CLOSURE',N'DescendantUPRID') IS NULL
 OR COL_LENGTH(N'dbo.UPR_CLOSURE',N'Level') IS NULL
    THROW 52100,'Expected UPR and the original AncestorUPRID/DescendantUPRID/Level closure layout.',1;

BEGIN TRY
BEGIN TRANSACTION;
IF OBJECT_ID('tempdb..#Parents') IS NOT NULL DROP TABLE #Parents;
IF OBJECT_ID('tempdb..#ActualPaths') IS NOT NULL DROP TABLE #ActualPaths;
IF OBJECT_ID('tempdb..#ExpectedPaths') IS NOT NULL DROP TABLE #ExpectedPaths;
SELECT UPRID,ParentUPRID INTO #Parents FROM dbo.UPR WITH(HOLDLOCK);
CREATE UNIQUE CLUSTERED INDEX IX_Parents ON #Parents(UPRID);
SELECT AncestorUPRID,DescendantUPRID,[Level] INTO #ActualPaths
FROM dbo.UPR_CLOSURE WITH(HOLDLOCK);
IF NOT EXISTS(SELECT 1 FROM #Parents WHERE UPRID=@UPRID)
    THROW 52100,'Selected UPRID does not exist. Select the API database and set @UPRID.',1;
IF EXISTS(SELECT 1 FROM #Parents p LEFT JOIN #Parents a ON a.UPRID=p.ParentUPRID
          WHERE p.ParentUPRID IS NOT NULL AND a.UPRID IS NULL)
BEGIN
    SELECT p.UPRID,p.ParentUPRID AS MissingParentUPRID FROM #Parents p
    LEFT JOIN #Parents a ON a.UPRID=p.ParentUPRID
    WHERE p.ParentUPRID IS NOT NULL AND a.UPRID IS NULL;
    THROW 52101,'UPR has a missing parent. No data changed.',1;
END;

CREATE TABLE #ExpectedPaths(AncestorUPRID BIGINT NOT NULL,
    DescendantUPRID BIGINT NOT NULL,[Level] INT NOT NULL,
    PRIMARY KEY(AncestorUPRID,DescendantUPRID));
INSERT #ExpectedPaths SELECT UPRID,UPRID,0 FROM #Parents;
DECLARE @Distance INT=0,@Added INT=1;
WHILE @Added>0
BEGIN
    IF EXISTS(SELECT 1 FROM #ExpectedPaths e
        JOIN #Parents p ON p.UPRID=e.AncestorUPRID
        JOIN #ExpectedPaths seen ON seen.AncestorUPRID=p.ParentUPRID
            AND seen.DescendantUPRID=e.DescendantUPRID
        WHERE e.[Level]=@Distance)
        THROW 52101,'UPR parent chain contains a cycle. No data changed.',1;
    INSERT #ExpectedPaths(AncestorUPRID,DescendantUPRID,[Level])
    SELECT p.ParentUPRID,e.DescendantUPRID,e.[Level]+1
    FROM #ExpectedPaths e JOIN #Parents p ON p.UPRID=e.AncestorUPRID
    WHERE e.[Level]=@Distance AND p.ParentUPRID IS NOT NULL;
    SET @Added=@@ROWCOUNT;
    SET @Distance+=1;
END;

IF EXISTS(SELECT AncestorUPRID,DescendantUPRID,[Level] FROM #ExpectedPaths
          EXCEPT SELECT AncestorUPRID,DescendantUPRID,[Level] FROM #ActualPaths)
 OR EXISTS(SELECT AncestorUPRID,DescendantUPRID,[Level] FROM #ActualPaths
           EXCEPT SELECT AncestorUPRID,DescendantUPRID,[Level] FROM #ExpectedPaths)
 OR (SELECT COUNT_BIG(*) FROM #ActualPaths)<>(SELECT COUNT_BIG(*) FROM #ExpectedPaths)
BEGIN
    SELECT TOP(100) COALESCE(e.AncestorUPRID,a.AncestorUPRID) AS AncestorUPRID,
        COALESCE(e.DescendantUPRID,a.DescendantUPRID) AS DescendantUPRID,
        a.[Level] AS ActualLevel,e.[Level] AS ExpectedLevel,
        CASE WHEN e.AncestorUPRID IS NULL THEN 'EXTRA_PATH'
             WHEN a.AncestorUPRID IS NULL THEN 'MISSING_PATH' ELSE 'WRONG_LEVEL' END AS Issue
    FROM #ExpectedPaths e FULL JOIN #ActualPaths a
        ON a.AncestorUPRID=e.AncestorUPRID AND a.DescendantUPRID=e.DescendantUPRID
    WHERE e.AncestorUPRID IS NULL OR a.AncestorUPRID IS NULL
        OR a.[Level] IS NULL OR a.[Level]<>e.[Level]
    ORDER BY DescendantUPRID,AncestorUPRID;
    THROW 52102,'Closure differs from ParentUPRID paths/distances (up to 100 differences shown). No data changed.',1;
END;
COMMIT TRANSACTION;

SELECT Result=N'PASS',CheckedUPRs=(SELECT COUNT_BIG(*) FROM #Parents),
    CheckedClosureRows=(SELECT COUNT_BIG(*) FROM #ActualPaths),
    Meaning=N'All closure paths and pair distances match ParentUPRID; all self rows are zero.';
-- Raw values, not adjusted for display. Order root to selected for comparison.
SELECT [Level],AncestorUPRID,DescendantUPRID FROM #ActualPaths
WHERE DescendantUPRID=@UPRID ORDER BY [Level] DESC,AncestorUPRID;
-- Explicitly separate absolute position from distance to the selected record.
SELECT path.AncestorUPRID AS UPRID,depth.[Level] AS TreeLevel,
    path.[Level] AS HierarchyDistance
FROM #ActualPaths path
JOIN #ActualPaths depth ON depth.DescendantUPRID=path.AncestorUPRID
JOIN #Parents root ON root.UPRID=depth.AncestorUPRID AND root.ParentUPRID IS NULL
WHERE path.DescendantUPRID=@UPRID ORDER BY path.[Level];

-- Supporting detail, read after the consistent hierarchy snapshot above.
-- A Unit can be parented directly to a Condo; BuildingUPRID is an association,
-- so a difference from ParentUPRID is not alone proof of a bad parent link.
IF OBJECT_ID(N'dbo.UNIT',N'U') IS NOT NULL AND OBJECT_ID(N'dbo.BUILDING',N'U') IS NOT NULL
    SELECT u.UPRID,u.EntityTypeID,u.ParentUPRID,un.UnitID,un.BuildingID,b.UPRID AS BuildingUPRID
    FROM dbo.UPR u LEFT JOIN dbo.UNIT un ON un.UPRID=u.UPRID
    LEFT JOIN dbo.BUILDING b ON b.BuildingID=un.BuildingID
    WHERE u.UPRID=@UPRID;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
