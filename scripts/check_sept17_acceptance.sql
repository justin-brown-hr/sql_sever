/* Read-only acceptance evidence for Reviewsin Sept17_Run.docx.
   Run after migration and loading, then again after an unchanged rerun.
   Screenshot counts are a comparison target, not proof that the current source
   file has the same inventory. Inspect differences before judging acceptance. */
USE UPRXDB_TEST;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

IF OBJECT_ID('tempdb..#ReviewAccounts') IS NOT NULL DROP TABLE #ReviewAccounts;
CREATE TABLE #ReviewAccounts (AccountNumber VARCHAR(8) PRIMARY KEY, ExpectedBuildings INT, ExpectedUnits INT, ExpectedMA INT);
INSERT #ReviewAccounts VALUES ('00050037',3,3,3), ('00261025',3,3,3), ('00050048',7,7,6), ('00272520',4,4,3);

PRINT N'Screenshot comparison: differences require checking the current source inventory';
SELECT w.AccountNumber, w.ExpectedBuildings, w.ExpectedUnits,
    ActualRoots = roots.Roots, ActualComplexes = roots.Complexes,
    ActualBuildings = buildings.Buildings, ActualUnits = units.Units,
    ActualMARows = ma.RowsRead, ActualSDATRows = sd.RowsRead,
    ScreenshotComparison = CASE
        WHEN roots.Roots = 1 AND roots.Complexes = 1 AND buildings.Buildings = w.ExpectedBuildings
          AND units.Units = w.ExpectedUnits THEN N'MATCHES SCREENSHOT COUNTS' ELSE N'REVIEW DIFFERENCE' END,
    SourceRowCounts = CASE WHEN ma.RowsRead = w.ExpectedMA AND sd.RowsRead = 1
        THEN N'MATCH SHOWN ROW COUNTS; CHECK ADDRESSES TOO' ELSE N'DIFFERENT FROM SCREENSHOT SUBSET' END
FROM #ReviewAccounts w
OUTER APPLY (SELECT Roots = COUNT(*), Complexes = COALESCE(SUM(CASE WHEN e.Description = N'Complex' THEN 1 ELSE 0 END),0)
    FROM dbo.UPR u JOIN dbo.REF_ENTITYTYPE e ON e.EntityTypeID = u.EntityTypeID
    WHERE u.ParentUPRID IS NULL AND u.AccountNumber = w.AccountNumber) roots
OUTER APPLY (SELECT Buildings = COUNT(*) FROM dbo.BUILDING b JOIN dbo.UPR u ON u.UPRID = b.UPRID
    JOIN dbo.UPR root ON root.UPRID = u.ParentUPRID WHERE root.ParentUPRID IS NULL AND root.AccountNumber = w.AccountNumber) buildings
OUTER APPLY (SELECT Units = COUNT(*) FROM dbo.UNIT un JOIN dbo.BUILDING b ON b.BuildingID = un.BuildingID
    JOIN dbo.UPR bu ON bu.UPRID = b.UPRID JOIN dbo.UPR root ON root.UPRID = bu.ParentUPRID
    WHERE root.ParentUPRID IS NULL AND root.AccountNumber = w.AccountNumber) units
OUTER APPLY (SELECT RowsRead = COUNT(*) FROM dbo.MAIncomingTableX1 m
    WHERE dbo.fn_UPR_NormalizeSDATAccount(CONVERT(NVARCHAR(50),m.Account)) = w.AccountNumber) ma
OUTER APPLY (SELECT RowsRead = COUNT(*) FROM dbo.SDATIncomingTableX1 s
    WHERE dbo.fn_UPR_NormalizeSDATAccount(CONVERT(NVARCHAR(50),s.AccountNumber)) = w.AccountNumber) sd
ORDER BY w.AccountNumber;

/* Mirror only the documented pairing eligibility, then inspect real XREFs;
   no staging-table internals or presumed source IDs are needed. */
IF OBJECT_ID('tempdb..#ReviewSources') IS NOT NULL DROP TABLE #ReviewSources;
SELECT w.AccountNumber, SourceSystem = CONVERT(VARCHAR(50),'ADDRESS_MASTER'),
    SourceRecordID = CONVERT(NVARCHAR(150),m.MasterAddressID),
    FullAddress = dbo.fn_UPR_NormalizeFullAddressLine(
        dbo.fn_UPR_NormalizeStreetNumber(m.StreetNumber) + N' ' + m.StreetName + N' ' + ISNULL(m.StreetType,N''), m.City, m.ZipCode),
    UnitNumber = NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50),m.Unit))),N'')
INTO #ReviewSources
FROM dbo.MAIncomingTableX1 m JOIN #ReviewAccounts w
    ON dbo.fn_UPR_NormalizeSDATAccount(CONVERT(NVARCHAR(50),m.Account)) = w.AccountNumber
UNION ALL
SELECT w.AccountNumber, 'KDAT', CONVERT(NVARCHAR(150),s.RealPropertyTaxInformationID),
    dbo.fn_UPR_NormalizeFullAddressLine(
        dbo.fn_UPR_NormalizeStreetNumber(CONVERT(NVARCHAR(20),s.PremisesNumber)) + N' '
        + CONVERT(NVARCHAR(200),s.PremisesStreetName) + N' ' + ISNULL(CONVERT(NVARCHAR(30),s.PremisesStreetType),N''),
        CONVERT(NVARCHAR(100),s.PremisesCity), CONVERT(NVARCHAR(10),s.PremisesZipCode)),
    NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50),s.CondoUnit))),N'')
FROM dbo.SDATIncomingTableX1 s JOIN #ReviewAccounts w
    ON dbo.fn_UPR_NormalizeSDATAccount(CONVERT(NVARCHAR(50),s.AccountNumber)) = w.AccountNumber;

PRINT N'Blank MA/SDAT pairs: both source IDs must resolve to the same Unit, or need review';
;WITH Pairs AS (
    SELECT AccountNumber, FullAddress,
        MAID = MAX(CASE WHEN SourceSystem = 'ADDRESS_MASTER' THEN SourceRecordID END),
        SDATID = MAX(CASE WHEN SourceSystem = 'KDAT' THEN SourceRecordID END)
    FROM #ReviewSources GROUP BY AccountNumber, FullAddress
    HAVING COUNT(*) = 2 AND MAX(UnitNumber) IS NULL
       AND COUNT(DISTINCT SourceSystem) = 2
)
SELECT p.*, MAUnitUPRID = ma.UPRID, SDATUnitUPRID = sd.UPRID,
    PairResult = CASE WHEN ma.UPRID IS NULL OR sd.UPRID IS NULL THEN N'REVIEW: SOURCE LINK MISSING'
        WHEN ma.UPRID <> sd.UPRID THEN N'REVIEW: SEPARATE RECORDS'
        WHEN un.UPRID IS NULL THEN N'REVIEW: LINK IS NOT A UNIT' ELSE N'SHARED UNIT' END
FROM Pairs p
LEFT JOIN dbo.EXTERNAL_IDENTIFIER_XREF ma ON ma.SourceSystem = 'ADDRESS_MASTER' AND ma.IdentifierType = 'SOURCE_RECORD_ID' AND ma.IdentifierValue = p.MAID
LEFT JOIN dbo.EXTERNAL_IDENTIFIER_XREF sd ON sd.SourceSystem = 'KDAT' AND sd.IdentifierType = 'SOURCE_RECORD_ID' AND sd.IdentifierValue = p.SDATID
LEFT JOIN dbo.UNIT un ON un.UPRID = ma.UPRID
ORDER BY p.AccountNumber, p.FullAddress;

PRINT N'All source records for these accounts and their current destination IDs';
SELECT s.*, x.UPRID, un.UnitID, un.BuildingID, StoredUnitNumber = un.UnitNumber
FROM #ReviewSources s LEFT JOIN dbo.EXTERNAL_IDENTIFIER_XREF x
    ON x.SourceSystem = s.SourceSystem AND x.IdentifierType = 'SOURCE_RECORD_ID' AND x.IdentifierValue = s.SourceRecordID
LEFT JOIN dbo.UNIT un ON un.UPRID = x.UPRID
ORDER BY s.AccountNumber, s.FullAddress, s.SourceSystem, s.SourceRecordID;

PRINT N'Review queue for these accounts (includes historical entries; inspect status/date)';
SELECT q.* FROM dbo.UPRMATCHREVIEW_Q q
WHERE EXISTS (SELECT 1 FROM #ReviewAccounts w WHERE w.AccountNumber IN (q.MA_Account,q.SDAT_AccountNumber))
ORDER BY q.ProcessingTimestamp, q.UPRMatchReviewID;

PRINT N'Latest run: an unchanged rerun should show zero business-row changes';
SELECT TOP (1) r.*, BusinessRowChanges = (SELECT COUNT_BIG(*) FROM dbo.AUDIT_LOG a
    JOIN dbo.REF_ENTITY_IDENTIFICATION e ON e.EntityID = a.EntityID
    WHERE a.RunID = r.RunID AND e.EntityName <> 'UPR_HIER_LOAD')
FROM dbo.UPR_LOAD_RUN r ORDER BY r.StartedAt DESC, r.RunID;
GO
