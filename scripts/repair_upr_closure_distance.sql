/* October 1 delivery: repair stored closure Level to ancestor/descendant edge distance.
   CLIENT RUN ORDER: 1) this file, 2) check_upr_closure_distance.sql.
   DATA UPDATE, not a read-only report. Run on a restored test database first.
   Select the database in SSMS. No schema changes or incoming-data load.
   Keeps every existing ancestor/descendant pair. Missing/extra paths or invalid
   parent trees stop and roll back; existing audit triggers record real updates.

   Expected for the supplied chain: (24,207075,2), (88788,207075,1),
   (207075,207075,0). Derived from ParentUPRID, never hard-coded.

   PREVENT RECURRENCE: update the closure-building step in the active loader.
   Seed each self path with Level=0, then extend with previous path Level+1.
   The project load_upr_master.sql includes this correction. Do not rerun an
   old loader after repair: it would restore the wrong root-depth values.
   In the existing Step 12:
     Self-path SELECT: SELECT UPRID, UPRID, 0 FROM #UPRLevels;
     Extension SELECT: SELECT c.AncestorUPRID, child.UPRID, c.[Level] + 1
     Keep the child.ParentUPRID=c.DescendantUPRID join and NOT EXISTS guard.
     Remove the now-unused join to #UPRLevels l from that extension SELECT.
   These are edits to the active loader, not statements to run by themselves.
   A root-depth report must use a root-to-node path, not a node's self-row.
   Existing API table name, columns, parent links and identifiers are retained.
*/
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET ARITHABORT ON;
SET NUMERIC_ROUNDABORT OFF;
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF @@TRANCOUNT<>0 THROW 52000,'Run the closure repair outside an existing transaction.',1;
IF OBJECT_ID(N'dbo.UPR',N'U') IS NULL
    OR COL_LENGTH(N'dbo.UPR',N'ParentUPRID') IS NULL
    OR COL_LENGTH(N'dbo.UPR_CLOSURE',N'AncestorUPRID') IS NULL
    OR COL_LENGTH(N'dbo.UPR_CLOSURE',N'DescendantUPRID') IS NULL
    OR COL_LENGTH(N'dbo.UPR_CLOSURE',N'Level') IS NULL
    THROW 52000,'Original AncestorUPRID/DescendantUPRID/Level layout required.',1;
BEGIN TRY
BEGIN TRANSACTION;
IF OBJECT_ID('tempdb..#HierarchyInput') IS NOT NULL DROP TABLE #HierarchyInput;
IF OBJECT_ID('tempdb..#ClosureSnapshot') IS NOT NULL DROP TABLE #ClosureSnapshot;
SELECT UPRID,ParentUPRID INTO #HierarchyInput FROM dbo.UPR WITH(UPDLOCK,HOLDLOCK);
CREATE UNIQUE CLUSTERED INDEX IX_HierarchyInput ON #HierarchyInput(UPRID);
SELECT AncestorUPRID,DescendantUPRID,[Level] INTO #ClosureSnapshot
FROM dbo.UPR_CLOSURE WITH(UPDLOCK,HOLDLOCK);
IF OBJECT_ID('tempdb..#UPRLevels') IS NOT NULL DROP TABLE #UPRLevels;
CREATE TABLE #UPRLevels (UPRID BIGINT NOT NULL PRIMARY KEY, [Level] INT NOT NULL);
INSERT INTO #UPRLevels (UPRID, [Level])
SELECT UPRID, 0 FROM  #HierarchyInput WHERE ParentUPRID IS NULL;
DECLARE @LevelsAdded INT = 1;
WHILE @LevelsAdded > 0
BEGIN
    INSERT INTO #UPRLevels (UPRID, [Level])
    SELECT child.UPRID, parent.[Level] + 1
    FROM  #HierarchyInput child
    INNER JOIN #UPRLevels parent ON parent.UPRID = child.ParentUPRID
    WHERE NOT EXISTS (SELECT 1 FROM #UPRLevels seen WHERE seen.UPRID = child.UPRID);
    SET @LevelsAdded = @@ROWCOUNT;
END;
IF EXISTS (SELECT 1 FROM  #HierarchyInput u
           WHERE NOT EXISTS (SELECT 1 FROM #UPRLevels l WHERE l.UPRID = u.UPRID))
    THROW 50005, 'UPR hierarchy contains a cycle or an unreachable parent; cannot calculate closure levels.', 1;

/* Build the expected paths separately, then apply only real differences.
   Unchanged loads must not produce thousands of delete/reinsert audit events. */
IF OBJECT_ID('tempdb..#ExpectedClosure') IS NOT NULL DROP TABLE #ExpectedClosure;
CREATE TABLE #ExpectedClosure (
    AncestorUPRID BIGINT NOT NULL,
    DescendantUPRID BIGINT NOT NULL,
    [Level] INT NOT NULL,
    PRIMARY KEY (AncestorUPRID, DescendantUPRID)
);
INSERT INTO #ExpectedClosure (AncestorUPRID, DescendantUPRID, [Level])
SELECT UPRID, UPRID, 0 FROM #UPRLevels;
DECLARE @ClosureAdded INT = 1;
WHILE @ClosureAdded > 0
BEGIN
    INSERT INTO #ExpectedClosure (AncestorUPRID, DescendantUPRID, [Level])
    SELECT c.AncestorUPRID, child.UPRID, c.[Level] + 1
    FROM #ExpectedClosure c
    INNER JOIN  #HierarchyInput child ON child.ParentUPRID = c.DescendantUPRID
    WHERE NOT EXISTS (SELECT 1 FROM #ExpectedClosure x
        WHERE x.AncestorUPRID = c.AncestorUPRID AND x.DescendantUPRID = child.UPRID);
    SET @ClosureAdded = @@ROWCOUNT;
END;
IF EXISTS(SELECT AncestorUPRID,DescendantUPRID FROM #ExpectedClosure
    EXCEPT SELECT AncestorUPRID,DescendantUPRID FROM #ClosureSnapshot)
 OR EXISTS(SELECT AncestorUPRID,DescendantUPRID FROM #ClosureSnapshot
    EXCEPT SELECT AncestorUPRID,DescendantUPRID FROM #ExpectedClosure)
 OR (SELECT COUNT_BIG(*) FROM #ClosureSnapshot)<>(SELECT COUNT_BIG(*) FROM #ExpectedClosure)
    THROW 52001,'Closure paths differ from ParentUPRID. No levels changed; reconcile paths before repair.',1;
UPDATE c SET [Level]=e.[Level]
FROM dbo.UPR_CLOSURE c JOIN #ExpectedClosure e
    ON e.AncestorUPRID=c.AncestorUPRID AND e.DescendantUPRID=c.DescendantUPRID
WHERE c.[Level] IS NULL OR c.[Level]<>e.[Level];
DECLARE @Changed INT=@@ROWCOUNT;
IF EXISTS(SELECT AncestorUPRID,DescendantUPRID,[Level] FROM #ExpectedClosure
    EXCEPT SELECT AncestorUPRID,DescendantUPRID,[Level] FROM dbo.UPR_CLOSURE)
 OR EXISTS(SELECT AncestorUPRID,DescendantUPRID,[Level] FROM dbo.UPR_CLOSURE
    EXCEPT SELECT AncestorUPRID,DescendantUPRID,[Level] FROM #ExpectedClosure)
 OR (SELECT COUNT_BIG(*) FROM dbo.UPR_CLOSURE)<>(SELECT COUNT_BIG(*) FROM #ExpectedClosure)
    THROW 52002,'Post-update verification failed. Repair rolled back.',1;
COMMIT TRANSACTION;
SELECT Result=N'PASS',UpdatedRows=@Changed,
    Meaning=N'Level is edge distance: self 0, direct parent-child 1. Table columns and relationship pairs unchanged.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
