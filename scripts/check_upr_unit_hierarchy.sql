/* READ ONLY - October 8 R9 verification.
   Select the SAME database used by the loader. RootUPRID=24 is the screenshot
   example, not a cross-database property identity. Compare account/type too.
   Checks ALL units; root-filtered details follow. No data or schema changes. */
SET NOCOUNT ON;
DECLARE @RootUPRID BIGINT=24;
IF OBJECT_ID('tempdb..#UnitHierarchyCheck') IS NOT NULL DROP TABLE #UnitHierarchyCheck;
SELECT un.UnitID,un.UPRID AS UnitUPRID,u.ParentUPRID AS ActualParentUPRID,
    un.BuildingID,b.UPRID AS ExpectedBuildingUPRID,bu.ParentUPRID AS RootUPRID,
    root.AccountNumber AS RootAccountNumber,re.Description AS RootEntityType,
    Verdict=CASE
      WHEN u.UPRID IS NULL OR ue.Description<>N'Unit' OR ue.Description IS NULL THEN N'FAIL: missing/wrong Unit UPR'
      WHEN b.UPRID IS NULL OR bu.UPRID IS NULL OR be.Description<>N'Building' OR be.Description IS NULL
        THEN N'FAIL: missing/wrong Building UPR'
      WHEN u.ParentUPRID IS NULL OR u.ParentUPRID<>b.UPRID THEN N'FAIL: Unit parent differs from UNIT.BuildingID mapping'
      WHEN root.UPRID IS NULL OR root.ParentUPRID IS NOT NULL
        OR re.Description NOT IN(N'Condo',N'Complex',N'Property') OR re.Description IS NULL
        THEN N'FAIL: Building has no valid property root'
      WHEN (SELECT COUNT(*) FROM dbo.UPR_CLOSURE c WHERE c.AncestorUPRID=un.UPRID AND c.DescendantUPRID=un.UPRID)<>1
        OR NOT EXISTS(SELECT 1 FROM dbo.UPR_CLOSURE c WHERE c.AncestorUPRID=un.UPRID AND c.DescendantUPRID=un.UPRID AND c.[Level]=0)
        THEN N'FAIL: Unit self distance must be 0'
      WHEN (SELECT COUNT(*) FROM dbo.UPR_CLOSURE c WHERE c.AncestorUPRID=b.UPRID AND c.DescendantUPRID=un.UPRID)<>1
        OR NOT EXISTS(SELECT 1 FROM dbo.UPR_CLOSURE c WHERE c.AncestorUPRID=b.UPRID AND c.DescendantUPRID=un.UPRID AND c.[Level]=1)
        THEN N'FAIL: Building-to-Unit distance must be 1'
      WHEN (SELECT COUNT(*) FROM dbo.UPR_CLOSURE c WHERE c.AncestorUPRID=root.UPRID AND c.DescendantUPRID=un.UPRID)<>1
        OR NOT EXISTS(SELECT 1 FROM dbo.UPR_CLOSURE c WHERE c.AncestorUPRID=root.UPRID AND c.DescendantUPRID=un.UPRID AND c.[Level]=2)
        THEN N'FAIL: root-to-Unit distance must be 2'
      ELSE N'PASS' END
INTO #UnitHierarchyCheck
FROM dbo.UNIT un
LEFT JOIN dbo.UPR u ON u.UPRID=un.UPRID
LEFT JOIN dbo.REF_ENTITYTYPE ue ON ue.EntityTypeID=u.EntityTypeID
LEFT JOIN dbo.BUILDING b ON b.BuildingID=un.BuildingID
LEFT JOIN dbo.UPR bu ON bu.UPRID=b.UPRID
LEFT JOIN dbo.REF_ENTITYTYPE be ON be.EntityTypeID=bu.EntityTypeID
LEFT JOIN dbo.UPR root ON root.UPRID=bu.ParentUPRID
LEFT JOIN dbo.REF_ENTITYTYPE re ON re.EntityTypeID=root.EntityTypeID;
SELECT DB_NAME() AS DatabaseName,COUNT_BIG(*) AS UnitsChecked,
    COALESCE(SUM(CONVERT(BIGINT,CASE WHEN Verdict<>N'PASS' THEN 1 ELSE 0 END)),0) AS UnitsFailing,
    CASE WHEN COUNT_BIG(*)=0 THEN N'NO UNITS TO CHECK'
         WHEN MAX(CASE WHEN Verdict<>N'PASS' THEN 1 ELSE 0 END)=0 THEN N'PASS' ELSE N'FAIL' END AS OverallResult
FROM #UnitHierarchyCheck;
SELECT TOP(200) * FROM #UnitHierarchyCheck WHERE Verdict<>N'PASS' ORDER BY UnitUPRID;
SELECT DB_NAME() AS DatabaseName,u.UPRID,u.AccountNumber,et.Description AS RootEntityType,u.ParentUPRID
FROM dbo.UPR u JOIN dbo.REF_ENTITYTYPE et ON et.EntityTypeID=u.EntityTypeID WHERE u.UPRID=@RootUPRID;
SELECT c.[Level],d.UPRID,d.ParentUPRID,et.Description AS EntityType,d.AccountNumber,d.StatusCode
FROM dbo.UPR_CLOSURE c JOIN dbo.UPR d ON d.UPRID=c.DescendantUPRID
JOIN dbo.REF_ENTITYTYPE et ON et.EntityTypeID=d.EntityTypeID
WHERE c.AncestorUPRID=@RootUPRID ORDER BY c.[Level],d.UPRID;
SELECT * FROM #UnitHierarchyCheck WHERE RootUPRID=@RootUPRID OR ActualParentUPRID=@RootUPRID ORDER BY UnitUPRID;
/* Also run check_upr_closure_distance.sql from the prior delivery for ALL pair
   integrity checks (including unexpected extra pairs), and the audit checker
   with this R9 run's printed RunID. */
