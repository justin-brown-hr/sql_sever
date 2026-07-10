/*
================================================================================
  Diagnose DUPLICATE Review_Q rows that should be in UPR

  Run AFTER load_upr_master.sql on the client database.
  Finds duplicate groups where:
    - 2+ Review_Q rows share account + normalized address with reason DUPLICATE
    - No ACTIVE UPR row exists for that account+address (mis-routed valid winner)

  Use results to confirm the duplicate-winner fix before/after re-run.
================================================================================
*/
USE UPRXDB_TEST;   /* change to your UPR database */
GO

SET NOCOUNT ON;

DECLARE @MinDupInGroup INT = 2;   /* client reported 2 — lower to 1 to list all DUPLICATE */

PRINT N'';
PRINT N'============================================================';
PRINT N'  DUPLICATE Review_Q diagnostic';
PRINT N'  Database: ' + DB_NAME();
PRINT N'  Run: ' + CONVERT(NVARCHAR(30), SYSDATETIME(), 120);
PRINT N'============================================================';

IF OBJECT_ID(N'dbo.UPRMATCHREVIEW_Q', N'U') IS NULL
BEGIN
    RAISERROR(N'Table dbo.UPRMATCHREVIEW_Q not found.', 16, 1);
    RETURN;
END;

/* --------------------------------------------------------------------------
   1. Summary — DUPLICATE groups with no UPR (likely mis-routed)
   -------------------------------------------------------------------------- */
PRINT N'';
PRINT N'--- 1. DUPLICATE groups with NO matching ACTIVE UPR ---';

;WITH ReviewNorm AS (
    SELECT
        q.UPRMatchReviewID,
        q.IncomingSourceSystem,
        q.MA_Account,
        q.MA_NormalizedIncomingAddress,
        q.MA_ParcelID,
        q.SDAT_AccountNumber,
        q.SDAT_NormalizedIncomingAddress,
        q.SDAT_ParcelID,
        q.ReasonForNoMatch,
        q.ReviewStatus,
        q.ProcessingTimestamp,
        EffectiveAccount = CASE
            WHEN OBJECT_ID(N'dbo.fn_UPR_NormalizeSDATAccount', N'FN') IS NOT NULL
                THEN dbo.fn_UPR_NormalizeSDATAccount(
                    NULLIF(LTRIM(RTRIM(COALESCE(q.SDAT_AccountNumber, q.MA_Account))), N''))
            ELSE NULLIF(LTRIM(RTRIM(COALESCE(q.SDAT_AccountNumber, q.MA_Account))), N'')
        END,
        EffectiveAddress = LEFT(NULLIF(LTRIM(RTRIM(COALESCE(
            NULLIF(q.SDAT_NormalizedIncomingAddress, N''),
            q.MA_NormalizedIncomingAddress
        ))), N''), 300),
        EffectiveParcel = NULLIF(LTRIM(RTRIM(COALESCE(q.SDAT_ParcelID, q.MA_ParcelID))), N''),
        HasValidParcel = CASE
            WHEN NULLIF(LTRIM(RTRIM(COALESCE(q.SDAT_ParcelID, q.MA_ParcelID))), N'') IS NOT NULL THEN 1
            ELSE 0
        END,
        HasValidAccount = CASE
            WHEN NULLIF(LTRIM(RTRIM(COALESCE(q.SDAT_AccountNumber, q.MA_Account))), N'') IS NOT NULL THEN 1
            ELSE 0
        END,
        HasValidAddress = CASE
            WHEN NULLIF(LTRIM(RTRIM(COALESCE(
                NULLIF(q.SDAT_NormalizedIncomingAddress, N''),
                q.MA_NormalizedIncomingAddress
            ))), N'') IS NOT NULL THEN 1
            ELSE 0
        END
    FROM dbo.UPRMATCHREVIEW_Q q
    WHERE q.ReasonForNoMatch = N'DUPLICATE'
),
DupGroups AS (
    SELECT
        r.EffectiveAccount,
        r.EffectiveAddress,
        COUNT(*) AS DupRowCount,
        SUM(r.HasValidParcel) AS RowsWithParcel,
        SUM(CASE WHEN r.HasValidParcel = 1 AND r.HasValidAccount = 1 AND r.HasValidAddress = 1 THEN 1 ELSE 0 END) AS FullyValidRows
    FROM ReviewNorm r
    WHERE r.EffectiveAccount IS NOT NULL
      AND r.EffectiveAddress IS NOT NULL
    GROUP BY r.EffectiveAccount, r.EffectiveAddress
    HAVING COUNT(*) >= @MinDupInGroup
)
SELECT
    g.EffectiveAccount,
    g.EffectiveAddress,
    g.DupRowCount,
    g.FullyValidRows,
    g.RowsWithParcel,
    UprExists = CASE WHEN upr.UPropertyRecordsID IS NOT NULL THEN N'YES' ELSE N'NO' END,
    upr.UPropertyRecordsID,
    upr.ParcelID AS UprParcelID,
    IssueFlag = CASE
        WHEN upr.UPropertyRecordsID IS NOT NULL
            THEN N'OK — UPR exists for this account (one row per property key)'
        WHEN g.DupRowCount > 1 AND g.FullyValidRows >= 1
            THEN N'CHECK — duplicate group has no UPR; only ONE row should win UPR, rest Review_Q'
        WHEN upr.UPropertyRecordsID IS NULL
            THEN N'NO UPR — review duplicates'
        ELSE N'OK'
    END
FROM DupGroups g
LEFT JOIN dbo.UPROPERTYRECORDS upr
    ON upr.SDATAccountNumber = g.EffectiveAccount
   AND upr.PropertyStatusCode = N'ACTIVE'
ORDER BY
    CASE WHEN upr.UPropertyRecordsID IS NULL AND g.FullyValidRows >= 1 THEN 0 ELSE 1 END,
    g.EffectiveAccount,
    g.EffectiveAddress;

/* --------------------------------------------------------------------------
   2. Row-level detail for duplicate groups with no UPR on account
   -------------------------------------------------------------------------- */
PRINT N'';
PRINT N'--- 2. Row detail — DUPLICATE groups with valid row(s) but no UPR ---';

;WITH ReviewNorm AS (
    SELECT
        q.UPRMatchReviewID,
        q.IncomingSourceSystem,
        q.MA_Account,
        q.MA_NormalizedIncomingAddress,
        q.MA_ParcelID,
        q.SDAT_AccountNumber,
        q.SDAT_NormalizedIncomingAddress,
        q.SDAT_ParcelID,
        q.ReasonForNoMatch,
        q.ReviewStatus,
        q.ProcessingTimestamp,
        EffectiveAccount = CASE
            WHEN OBJECT_ID(N'dbo.fn_UPR_NormalizeSDATAccount', N'FN') IS NOT NULL
                THEN dbo.fn_UPR_NormalizeSDATAccount(
                    NULLIF(LTRIM(RTRIM(COALESCE(q.SDAT_AccountNumber, q.MA_Account))), N''))
            ELSE NULLIF(LTRIM(RTRIM(COALESCE(q.SDAT_AccountNumber, q.MA_Account))), N'')
        END,
        EffectiveAddress = LEFT(NULLIF(LTRIM(RTRIM(COALESCE(
            NULLIF(q.SDAT_NormalizedIncomingAddress, N''),
            q.MA_NormalizedIncomingAddress
        ))), N''), 300),
        EffectiveParcel = NULLIF(LTRIM(RTRIM(COALESCE(q.SDAT_ParcelID, q.MA_ParcelID))), N''),
        IsFullyValid = CASE
            WHEN NULLIF(LTRIM(RTRIM(COALESCE(q.SDAT_ParcelID, q.MA_ParcelID))), N'') IS NOT NULL
             AND NULLIF(LTRIM(RTRIM(COALESCE(q.SDAT_AccountNumber, q.MA_Account))), N'') IS NOT NULL
             AND NULLIF(LTRIM(RTRIM(COALESCE(
                    NULLIF(q.SDAT_NormalizedIncomingAddress, N''),
                    q.MA_NormalizedIncomingAddress
                ))), N'') IS NOT NULL
            THEN 1 ELSE 0
        END,
        GroupWinRn = ROW_NUMBER() OVER (
            PARTITION BY
                CASE
                    WHEN OBJECT_ID(N'dbo.fn_UPR_NormalizeSDATAccount', N'FN') IS NOT NULL
                        THEN dbo.fn_UPR_NormalizeSDATAccount(
                            NULLIF(LTRIM(RTRIM(COALESCE(q.SDAT_AccountNumber, q.MA_Account))), N''))
                    ELSE NULLIF(LTRIM(RTRIM(COALESCE(q.SDAT_AccountNumber, q.MA_Account))), N'')
                END,
                LEFT(NULLIF(LTRIM(RTRIM(COALESCE(
                    NULLIF(q.SDAT_NormalizedIncomingAddress, N''),
                    q.MA_NormalizedIncomingAddress
                ))), N''), 300)
            ORDER BY
                CASE q.IncomingSourceSystem WHEN N'BOTH' THEN 1 WHEN N'KDAT' THEN 2 ELSE 3 END,
                q.UPRMatchReviewID
        )
    FROM dbo.UPRMATCHREVIEW_Q q
    WHERE q.ReasonForNoMatch = N'DUPLICATE'
),
MisGroups AS (
    SELECT r.EffectiveAccount, r.EffectiveAddress
    FROM ReviewNorm r
    WHERE r.EffectiveAccount IS NOT NULL
      AND r.EffectiveAddress IS NOT NULL
    GROUP BY r.EffectiveAccount, r.EffectiveAddress
    HAVING COUNT(*) >= @MinDupInGroup
       AND SUM(r.IsFullyValid) >= 1
       AND NOT EXISTS (
            SELECT 1
            FROM dbo.UPROPERTYRECORDS upr
            WHERE upr.SDATAccountNumber = r.EffectiveAccount
              AND upr.PropertyStatusCode = N'ACTIVE'
       )
)
SELECT
    r.UPRMatchReviewID,
    r.IncomingSourceSystem,
    r.MA_Account,
    r.MA_ParcelID,
    LEFT(r.MA_NormalizedIncomingAddress, 80) AS MA_Address,
    r.SDAT_AccountNumber,
    r.SDAT_ParcelID,
    LEFT(r.SDAT_NormalizedIncomingAddress, 80) AS SDAT_Address,
    r.EffectiveAccount,
    r.EffectiveParcel,
    r.IsFullyValid,
    RecommendedAction = CASE
        WHEN r.IsFullyValid = 1 AND r.GroupWinRn = 1
            THEN N'Expected UPR WINNER for this account+address (verify in UPROPERTYRECORDS)'
        WHEN r.IsFullyValid = 1
            THEN N'Expected Review_Q DUPLICATE loser (same account+address as winner)'
        ELSE N'Stays Review_Q DUPLICATE (loser or invalid)'
    END,
    r.ReviewStatus,
    r.ProcessingTimestamp
FROM ReviewNorm r
INNER JOIN MisGroups m
    ON m.EffectiveAccount = r.EffectiveAccount
   AND m.EffectiveAddress = r.EffectiveAddress
ORDER BY r.EffectiveAccount, r.EffectiveAddress, r.IsFullyValid DESC, r.UPRMatchReviewID;

/* --------------------------------------------------------------------------
   3. Quick counts
   -------------------------------------------------------------------------- */
PRINT N'';
PRINT N'--- 3. Counts ---';

DECLARE @DupTotal INT = (
    SELECT COUNT(*) FROM dbo.UPRMATCHREVIEW_Q WHERE ReasonForNoMatch = N'DUPLICATE'
);

DECLARE @MisRoutedGroups INT = (
    SELECT COUNT(*)
    FROM (
        SELECT
            EffectiveAccount = CASE
                WHEN OBJECT_ID(N'dbo.fn_UPR_NormalizeSDATAccount', N'FN') IS NOT NULL
                    THEN dbo.fn_UPR_NormalizeSDATAccount(
                        NULLIF(LTRIM(RTRIM(COALESCE(q.SDAT_AccountNumber, q.MA_Account))), N''))
                ELSE NULLIF(LTRIM(RTRIM(COALESCE(q.SDAT_AccountNumber, q.MA_Account))), N'')
            END,
            EffectiveAddress = LEFT(NULLIF(LTRIM(RTRIM(COALESCE(
                NULLIF(q.SDAT_NormalizedIncomingAddress, N''),
                q.MA_NormalizedIncomingAddress
            ))), N''), 300)
        FROM dbo.UPRMATCHREVIEW_Q q
        WHERE q.ReasonForNoMatch = N'DUPLICATE'
        GROUP BY
            CASE
                WHEN OBJECT_ID(N'dbo.fn_UPR_NormalizeSDATAccount', N'FN') IS NOT NULL
                    THEN dbo.fn_UPR_NormalizeSDATAccount(
                        NULLIF(LTRIM(RTRIM(COALESCE(q.SDAT_AccountNumber, q.MA_Account))), N''))
                ELSE NULLIF(LTRIM(RTRIM(COALESCE(q.SDAT_AccountNumber, q.MA_Account))), N'')
            END,
            LEFT(NULLIF(LTRIM(RTRIM(COALESCE(
                NULLIF(q.SDAT_NormalizedIncomingAddress, N''),
                q.MA_NormalizedIncomingAddress
            ))), N''), 300)
        HAVING COUNT(*) >= @MinDupInGroup
           AND SUM(CASE
                WHEN NULLIF(LTRIM(RTRIM(COALESCE(q.SDAT_ParcelID, q.MA_ParcelID))), N'') IS NOT NULL
                 AND NULLIF(LTRIM(RTRIM(COALESCE(q.SDAT_AccountNumber, q.MA_Account))), N'') IS NOT NULL
                 AND NULLIF(LTRIM(RTRIM(COALESCE(
                        NULLIF(q.SDAT_NormalizedIncomingAddress, N''),
                        q.MA_NormalizedIncomingAddress
                    ))), N'') IS NOT NULL
                THEN 1 ELSE 0 END) >= 1
           AND NOT EXISTS (
                SELECT 1
                FROM dbo.UPROPERTYRECORDS upr
                WHERE upr.SDATAccountNumber = CASE
                    WHEN OBJECT_ID(N'dbo.fn_UPR_NormalizeSDATAccount', N'FN') IS NOT NULL
                        THEN dbo.fn_UPR_NormalizeSDATAccount(
                            NULLIF(LTRIM(RTRIM(COALESCE(q.SDAT_AccountNumber, q.MA_Account))), N''))
                    ELSE NULLIF(LTRIM(RTRIM(COALESCE(q.SDAT_AccountNumber, q.MA_Account))), N'')
                END
                AND upr.PropertyStatusCode = N'ACTIVE'
           )
ELSE
    PRINT N'';
    PRINT N'No mis-routed duplicate groups detected (or UPR already exists for those keys).';

GO
