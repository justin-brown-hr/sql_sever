/* Read-only source/destination evidence for the client-reported accounts.
   Run on the client's database; no normalization functions are required.
   These queries do not insert, update, or manufacture source data. */
USE UPRXDB_TEST;
GO
SET NOCOUNT ON;

/* Add every reported account to this list - it drives every query below. */
IF OBJECT_ID('tempdb..#WatchAccount') IS NOT NULL DROP TABLE #WatchAccount;
CREATE TABLE #WatchAccount (AccountNumber NVARCHAR(50) PRIMARY KEY);
INSERT #WatchAccount VALUES
    ('00089876'), ('01297731'), ('00272531'), ('00086862'), ('00255115'),
    ('00050037'), ('00261025'), ('00050048'), ('00272520');

PRINT N'Latest loader audit summaries (duplicate marker: MA-SDAT-OVERLAP-2026-09-23)';
SELECT TOP (5) AuditID, ChangedDate, ChangeSummary
FROM dbo.AuditLog WHERE EntityName = N'UPR_HIER_LOAD' ORDER BY AuditID DESC;

PRINT N'Original MasterAddress source rows';
SELECT ma.*
FROM dbo.MAIncomingTableX1 ma
WHERE EXISTS (SELECT 1 FROM #WatchAccount w
    WHERE w.AccountNumber = RIGHT(N'00000000' + LTRIM(RTRIM(CONVERT(NVARCHAR(50), ma.Account))), 8));

PRINT N'Original SDAT source rows (includes CondoUnit if the column exists)';
SELECT s.*
FROM dbo.SDATIncomingTableX1 s
WHERE EXISTS (SELECT 1 FROM #WatchAccount w
    WHERE w.AccountNumber = RIGHT(N'00000000' + LTRIM(RTRIM(CONVERT(NVARCHAR(50), s.AccountNumber))), 8));

PRINT N'Written UPR entities with direct Address and Contact links';
;WITH Tree AS (
    SELECT u.UPRID, u.ParentUPRID, RootAccount = u.AccountNumber
    FROM dbo.UPR u
    WHERE u.ParentUPRID IS NULL
      AND EXISTS (SELECT 1 FROM #WatchAccount w WHERE w.AccountNumber = u.AccountNumber)
    UNION ALL
    SELECT u.UPRID, u.ParentUPRID, t.RootAccount
    FROM dbo.UPR u INNER JOIN Tree t ON u.ParentUPRID = t.UPRID
)
SELECT t.RootAccount, u.UPRID, u.ParentUPRID, e.Description AS EntityType,
    un.UnitNumber, BuildingID = COALESCE(b.BuildingID, un.BuildingID),
    ua.IsPrimary, a.AddressID, a.StreetNumber, a.StreetName, a.StreetType,
    a.City, a.State, a.ZipCode, a.NormalizedAddress,
    ct.ContactID, ct.OrganizationName
FROM Tree t
INNER JOIN dbo.UPR u ON u.UPRID = t.UPRID
INNER JOIN dbo.REF_ENTITYTYPE e ON e.EntityTypeID = u.EntityTypeID
LEFT JOIN dbo.UNIT un ON un.UPRID = u.UPRID
LEFT JOIN dbo.BUILDING b ON b.UPRID = u.UPRID
LEFT JOIN dbo.UPR_ADDRESS ua ON ua.UPRID = u.UPRID
LEFT JOIN dbo.ADDRESS a ON a.AddressID = ua.AddressID
LEFT JOIN dbo.UPR_CONTACT uc ON uc.UPRID = u.UPRID
LEFT JOIN dbo.CONTACT ct ON ct.ContactID = uc.ContactID
ORDER BY t.RootAccount, u.UPRID, a.AddressID, ct.ContactID
OPTION (MAXRECURSION 100);

PRINT N'Existing top-level parents by account - check for competing Condo/Complex roots';
SELECT w.AccountNumber, u.UPRID, e.Description AS EntityType, u.StatusCode,
    DirectChildren = (SELECT COUNT(*) FROM dbo.UPR child WHERE child.ParentUPRID = u.UPRID),
    RootsOnAccount = (SELECT COUNT(*) FROM dbo.UPR r
                     WHERE r.AccountNumber = w.AccountNumber AND r.ParentUPRID IS NULL)
FROM #WatchAccount w
LEFT JOIN dbo.UPR u ON u.AccountNumber = w.AccountNumber AND u.ParentUPRID IS NULL
LEFT JOIN dbo.REF_ENTITYTYPE e ON e.EntityTypeID = u.EntityTypeID
LEFT JOIN dbo.CONDO d ON d.UPRID = u.UPRID
ORDER BY w.AccountNumber, u.UPRID;

PRINT N'SDAT source record links and their current root classification';
SELECT root.AccountNumber, RootUPRID = root.UPRID, e.Description AS RootEntityType,
    x.IdentifierValue AS SDATSourceRecordID, x.UPRID AS LinkedUPRID,
    linked.ParentUPRID, un.BuildingID, un.UnitNumber
FROM dbo.EXTERNAL_IDENTIFIER_XREF x
INNER JOIN dbo.UPR linked ON linked.UPRID = x.UPRID
INNER JOIN dbo.UPR_CLOSURE cl ON cl.DescendantUPRID = x.UPRID
INNER JOIN dbo.UPR root ON root.UPRID = cl.UPRAncestry AND root.ParentUPRID IS NULL
INNER JOIN dbo.REF_ENTITYTYPE e ON e.EntityTypeID = root.EntityTypeID
LEFT JOIN dbo.UNIT un ON un.UPRID = x.UPRID
WHERE x.SourceSystem = N'KDAT' AND x.IdentifierType = N'SOURCE_RECORD_ID'
  AND EXISTS (SELECT 1 FROM #WatchAccount w WHERE w.AccountNumber = root.AccountNumber)
ORDER BY root.AccountNumber, x.IdentifierValue;

PRINT N'Review queue entries for these source accounts';
SELECT * FROM dbo.UPRMATCHREVIEW_Q
WHERE EXISTS (SELECT 1 FROM #WatchAccount w WHERE w.AccountNumber = UPRMATCHREVIEW_Q.MA_Account)
   OR EXISTS (SELECT 1 FROM #WatchAccount w WHERE w.AccountNumber = UPRMATCHREVIEW_Q.SDAT_AccountNumber);

PRINT N'Installed audit triggers (expect 23, all enabled)';
SELECT TableName = OBJECT_NAME(parent_id), name, is_disabled
FROM sys.triggers WHERE name LIKE N'tr_UPR_Audit[_]%'
ORDER BY TableName;

/* Audit coverage health check - explains a thin/empty AuditLog without
   guessing. A trigger-driven row can only exist for a change made AFTER
   scripts/install_upr_audit.sql was run; nothing is fabricated retroactively.
   An unchanged rerun of the loader is expected to add only the one
   UPR_HIER_LOAD batch-summary row - that is correct, not a bug. */
PRINT N'Audit coverage summary';
SELECT
    TotalAuditRows       = (SELECT COUNT(*) FROM dbo.AuditLog),
    RowLevelAuditRows     = (SELECT COUNT(*) FROM dbo.AuditLog WHERE EntityName <> 'UPR_HIER_LOAD'),
    BatchSummaryRows      = (SELECT COUNT(*) FROM dbo.AuditLog WHERE EntityName = 'UPR_HIER_LOAD'),
    DistinctTablesAudited = (SELECT COUNT(DISTINCT EntityName) FROM dbo.AuditLog WHERE EntityName <> 'UPR_HIER_LOAD'),
    EnabledTriggerCount   = (SELECT COUNT(*) FROM sys.triggers WHERE name LIKE N'tr_UPR_Audit[_]%' AND is_disabled = 0),
    EarliestAuditEvent    = (SELECT MIN(ChangedDate) FROM dbo.AuditLog WHERE EntityName <> 'UPR_HIER_LOAD'),
    LatestAuditEvent      = (SELECT MAX(ChangedDate) FROM dbo.AuditLog),
    EarliestUPRCreated    = (SELECT MIN(CreatedDate) FROM dbo.UPR);
PRINT N'If EnabledTriggerCount < 23, run scripts/install_upr_audit.sql.';
PRINT N'If EarliestUPRCreated is well before EarliestAuditEvent, some UPR rows';
PRINT N'were loaded before auditing was installed - their creation cannot be';
PRINT N'audited retroactively, only their future changes will be captured.';

IF OBJECT_ID(N'dbo.UPR_LOAD_RUN', N'U') IS NOT NULL
BEGIN
    PRINT N'Recent load runs and their recorded row changes';
    EXEC sys.sp_executesql N'
        SELECT TOP (10) r.RunID, r.StartedAt, r.FinishedAt, r.RunStatus,
            r.SourceRowsRead, r.RejectedRows,
            RowsInserted = COALESCE(a.RowsInserted, 0),
            RowsUpdated = COALESCE(a.RowsUpdated, 0),
            RowsDeleted = COALESCE(a.RowsDeleted, 0), r.ErrorMessage
        FROM dbo.UPR_LOAD_RUN r
        OUTER APPLY (
            SELECT RowsInserted = SUM(CASE WHEN OperationType = ''INSERT'' THEN 1 ELSE 0 END),
                RowsUpdated = SUM(CASE WHEN OperationType = ''UPDATE'' THEN 1 ELSE 0 END),
                RowsDeleted = SUM(CASE WHEN OperationType = ''DELETE'' THEN 1 ELSE 0 END)
            FROM dbo.AuditLog WHERE RunID = r.RunID AND EntityName <> N''UPR_HIER_LOAD''
        ) a
        ORDER BY r.StartedAt DESC, r.RunID;';
    PRINT N'Run scripts/list_upr_audit.sql to see every row and changed field.';
END;

/* Client rule: never an invented MA-<id> / SD-<id> UnitNumber anywhere. */
PRINT N'Any remaining invented MA-/SD- UnitNumber (expect 0 rows)';
SELECT un.UnitID, un.UnitNumber, u.AccountNumber
FROM dbo.UNIT un
INNER JOIN dbo.UPR u ON u.UPRID = un.UPRID
WHERE (un.UnitNumber LIKE 'MA-%' AND SUBSTRING(un.UnitNumber, 4, 50) NOT LIKE '%[^0-9]%')
   OR (un.UnitNumber LIKE 'SD-%' AND SUBSTRING(un.UnitNumber, 4, 50) NOT LIKE '%[^0-9]%');
GO
