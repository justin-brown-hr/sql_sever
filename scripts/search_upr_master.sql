/*
================================================================================
  UPR Master Search Script
  SQL Server 2016+

  Search UPROPERTYRECORDS, XREF, and UPRMATCHREVIEW_Q by multiple criteria.
  Set parameters below (NULL = ignore that filter). Combine filters as needed.

  Aligns with docs/ddl.md and scripts/load_upr_master.sql schema.
  Change USE database name to match your environment.
================================================================================
*/
USE UPRXDB_TEST;
GO

DECLARE @SDATAccountNumber     NVARCHAR(50)  = NULL;   -- e.g. N'10001001' (normalized on search)
DECLARE @MA_Account            NVARCHAR(30)  = NULL;   -- Review_Q MA account filter
DECLARE @ParcelID              NVARCHAR(50)  = NULL;
DECLARE @StreetNumber          NVARCHAR(20)  = NULL;
DECLARE @StreetName            NVARCHAR(100) = NULL;   -- partial match
DECLARE @City                  NVARCHAR(100) = NULL;
DECLARE @ZipCode               NVARCHAR(10)  = NULL;
DECLARE @Owner                 NVARCHAR(100) = NULL;   -- partial match
DECLARE @PropertyTypeCode      NVARCHAR(100) = NULL;   -- e.g. N'CONDO'
DECLARE @PropertyStatusCode    NVARCHAR(30)  = NULL;   -- ACTIVE | INACTIVE | PENDING | RETIRED
DECLARE @NormalizedAddress     NVARCHAR(100) = NULL;   -- partial match on street or full normalized address
DECLARE @SourceSystemCode      NVARCHAR(30)  = NULL;   -- ADDRESS_MASTER | KDAT | eProperty | CASE | MPDU | MULTIFAMILY
DECLARE @ReasonForNoMatch      NVARCHAR(255) = NULL;   -- Review_Q only — e.g. N'Missing ParcelID'
DECLARE @IncomingSourceSystem  NVARCHAR(100) = NULL;   -- Review_Q — ADDRESS_MASTER | KDAT | BOTH
DECLARE @IncludeReviewQOnly    BIT           = 0;      -- 1 = skip UPR/XREF, search Review_Q only

/* ---- Examples: uncomment to run a preset search ---- */
-- SET @SDATAccountNumber = N'10001001';
-- SET @ParcelID = N'P101';
-- SET @StreetName = N'MAIN';
-- SET @City = N'ROCKVILLE';
-- SET @SourceSystemCode = N'MPDU';
-- SET @ReasonForNoMatch = N'DUPLICATE';
-- SET @IncludeReviewQOnly = 1;

SET NOCOUNT ON;

DECLARE @NormAccount NVARCHAR(50) = CASE
    WHEN @SDATAccountNumber IS NULL THEN NULL
    WHEN OBJECT_ID(N'dbo.fn_UPR_NormalizeSDATAccount', N'FN') IS NOT NULL
        THEN dbo.fn_UPR_NormalizeSDATAccount(NULLIF(LTRIM(RTRIM(@SDATAccountNumber)), N''))
    ELSE NULLIF(LTRIM(RTRIM(@SDATAccountNumber)), N'')
END;

PRINT N'';
PRINT N'============================================================';
PRINT N'  UPR MASTER SEARCH';
PRINT N'  Database: ' + DB_NAME();
PRINT N'============================================================';

IF @IncludeReviewQOnly = 0
BEGIN
    PRINT N'';
    PRINT N'--- UPR Properties (UPROPERTYRECORDS) ---';

    SELECT
        upr.UPropertyRecordsID,
        upr.SDATAccountNumber,
        upr.ParcelID,
        upr.PropertyName,
        upr.Owner,
        upr.StreetNumber,
        upr.StreetName,
        upr.StreetType,
        upr.City,
        upr.[State],
        upr.ZipCode,
        upr.NormalizedStreetAddress,
        upr.NormalizedFullAddress,
        upr.PropertyTypeCode,
        upr.PropertyStatusCode,
        upr.IsActive,
        upr.Latitude,
        upr.Longitude,
        u.UnitNumber,
        upr.CreatedDate,
        upr.UpdatedDate
    FROM dbo.UPROPERTYRECORDS upr
    OUTER APPLY (
        SELECT TOP 1 un.UnitNumber
        FROM dbo.Unit un
        WHERE un.UPropertyRecordsID = upr.UPropertyRecordsID
          AND un.IsActive = 1
        ORDER BY un.UnitNumber
    ) u
    WHERE (@NormAccount IS NULL OR upr.SDATAccountNumber = @NormAccount)
      AND (@ParcelID IS NULL OR upr.ParcelID = @ParcelID)
      AND (@StreetNumber IS NULL OR upr.StreetNumber = @StreetNumber)
      AND (@StreetName IS NULL OR upr.StreetName LIKE N'%' + @StreetName + N'%')
      AND (@City IS NULL OR upr.City = @City)
      AND (@ZipCode IS NULL OR upr.ZipCode LIKE @ZipCode + N'%')
      AND (@Owner IS NULL OR upr.Owner LIKE N'%' + @Owner + N'%')
      AND (@PropertyTypeCode IS NULL OR upr.PropertyTypeCode = @PropertyTypeCode)
      AND (@PropertyStatusCode IS NULL OR upr.PropertyStatusCode = @PropertyStatusCode)
      AND (
            @NormalizedAddress IS NULL
            OR upr.NormalizedStreetAddress LIKE N'%' + @NormalizedAddress + N'%'
            OR upr.NormalizedFullAddress LIKE N'%' + @NormalizedAddress + N'%'
          )
      AND (@SourceSystemCode IS NULL OR EXISTS (
            SELECT 1
            FROM dbo.UPROPERTYRECORDS_XREF x
            WHERE x.UPropertyRecordsID = upr.UPropertyRecordsID
              AND x.SourceSystemCode = @SourceSystemCode
              AND x.IsActive = 1
          ))
    ORDER BY upr.UPropertyRecordsID;

    PRINT N'';
    PRINT N'--- Cross-References (UPROPERTYRECORDS_XREF) ---';

    SELECT
        upr.UPropertyRecordsID,
        upr.SDATAccountNumber,
        x.UPropertyRecords_XrefID,
        x.SourceSystemCode,
        x.SourceRecordID,
        x.SourceEntityType,
        x.MatchMethodCode,
        x.MatchResult,
        x.MatchConfidence,
        x.ProcessingStatus,
        x.EffectiveStartDate,
        x.Notes
    FROM dbo.UPROPERTYRECORDS upr
    INNER JOIN dbo.UPROPERTYRECORDS_XREF x
        ON x.UPropertyRecordsID = upr.UPropertyRecordsID
       AND x.IsActive = 1
    WHERE (@NormAccount IS NULL OR upr.SDATAccountNumber = @NormAccount)
      AND (@ParcelID IS NULL OR upr.ParcelID = @ParcelID)
      AND (@StreetName IS NULL OR upr.StreetName LIKE N'%' + @StreetName + N'%')
      AND (@City IS NULL OR upr.City = @City)
      AND (@SourceSystemCode IS NULL OR x.SourceSystemCode = @SourceSystemCode)
    ORDER BY upr.UPropertyRecordsID, x.SourceSystemCode, x.SourceRecordID;
END;

PRINT N'';
PRINT N'--- Review Queue (UPRMATCHREVIEW_Q) ---';

SELECT
    q.UPRMatchReviewID,
    q.UPropertyRecords_XrefID,
    q.IncomingSourceSystem,
    q.MA_Account,
    q.MA_NormalizedIncomingAddress,
    q.MA_ParcelID,
    q.SDAT_AccountNumber,
    q.SDAT_NormalizedIncomingAddress,
    q.SDAT_ParcelID,
    q.ReasonForNoMatch,
    q.ReviewStatus,
    q.ProcessingTimestamp
FROM dbo.UPRMATCHREVIEW_Q q
WHERE (@MA_Account IS NULL OR q.MA_Account = @MA_Account)
  AND (@NormAccount IS NULL OR q.SDAT_AccountNumber = @NormAccount)
  AND (@ParcelID IS NULL OR q.MA_ParcelID = @ParcelID OR q.SDAT_ParcelID = @ParcelID)
  AND (@ReasonForNoMatch IS NULL OR q.ReasonForNoMatch = @ReasonForNoMatch)
  AND (@IncomingSourceSystem IS NULL OR q.IncomingSourceSystem = @IncomingSourceSystem)
  AND (
        @NormalizedAddress IS NULL
        OR q.MA_NormalizedIncomingAddress LIKE N'%' + @NormalizedAddress + N'%'
        OR q.SDAT_NormalizedIncomingAddress LIKE N'%' + @NormalizedAddress + N'%'
      )
ORDER BY q.UPRMatchReviewID;

PRINT N'';
PRINT N'UPR SEARCH COMPLETE';

GO
