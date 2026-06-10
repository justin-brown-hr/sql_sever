/*
================================================================================
  UPR Master Search Script
  SQL Server 2016+

  Search UPROPERTYRECORD by multiple criteria.
  Set one or more parameters below (NULL = ignore that filter).
================================================================================
*/
USE UPR_Master;
GO

DECLARE @SDATAccountNumber NVARCHAR(50)  = NULL;   -- e.g. N'10001001'
DECLARE @ParcelID          NVARCHAR(50)  = NULL;   -- e.g. N'P101'
DECLARE @StreetNumber      NVARCHAR(20)  = NULL;
DECLARE @StreetName        NVARCHAR(150) = NULL;   -- partial match supported
DECLARE @City              NVARCHAR(100) = NULL;
DECLARE @ZipCode           NVARCHAR(10)  = NULL;
DECLARE @Owner             NVARCHAR(200) = NULL;   -- partial match
DECLARE @PropertyType      NVARCHAR(30)  = NULL;   -- e.g. N'CONDO'
DECLARE @NormalizedAddress NVARCHAR(200) = NULL;   -- partial match
DECLARE @SourceSystem      VARCHAR(30)   = NULL;   -- e.g. N'eProperty'
DECLARE @StatusCode        NVARCHAR(30)  = NULL;

/* ---- Example: uncomment one block to run a preset search ---- */
-- SET @SDATAccountNumber = N'10001001';
-- SET @ParcelID = N'P101';
-- SET @StreetName = N'MAIN';
-- SET @City = N'ROCKVILLE';
-- SET @SourceSystem = N'MPDU';

SET NOCOUNT ON;

PRINT N'';
PRINT N'============================================================';
PRINT N'  UPR MASTER SEARCH RESULTS';
PRINT N'============================================================';

SELECT
    upr.UPropertyRecordID,
    upr.SDATAccountNumber,
    upr.ParcelID,
    upr.Owner,
    upr.StreetNumber,
    upr.StreetName,
    upr.StreetType,
    upr.UnitNumber,
    upr.City,
    upr.[State],
    upr.ZipCode,
    upr.NormalizedAddress,
    upr.NormalizedFullAddress,
    upr.PropertyType,
    upr.StatusCode,
    upr.IsActive,
    upr.Latitude,
    upr.Longitude,
    upr.CreatedDate,
    upr.UpdatedDate
FROM dbo.UPROPERTYRECORD upr
WHERE (@SDATAccountNumber IS NULL OR upr.SDATAccountNumber = @SDATAccountNumber)
  AND (@ParcelID          IS NULL OR upr.ParcelID = @ParcelID)
  AND (@StreetNumber      IS NULL OR upr.StreetNumber = @StreetNumber)
  AND (@StreetName        IS NULL OR upr.StreetName LIKE N'%' + @StreetName + N'%')
  AND (@City              IS NULL OR upr.City = @City)
  AND (@ZipCode           IS NULL OR upr.ZipCode LIKE @ZipCode + N'%')
  AND (@Owner             IS NULL OR upr.Owner LIKE N'%' + @Owner + N'%')
  AND (@PropertyType      IS NULL OR upr.PropertyType = @PropertyType)
  AND (@NormalizedAddress IS NULL OR upr.NormalizedAddress LIKE N'%' + @NormalizedAddress + N'%')
  AND (@StatusCode        IS NULL OR upr.StatusCode = @StatusCode)
  AND (@SourceSystem IS NULL OR EXISTS (
        SELECT 1 FROM dbo.UPROPERTYRECORD_XREF x
        WHERE x.UPropertyRecordID = upr.UPropertyRecordID
          AND x.SourceSystem = @SourceSystem
          AND x.IsActive = 1
      ))
ORDER BY upr.UPropertyRecordID;

PRINT N'';
PRINT N'--- Cross-References for matched records ---';

SELECT
    upr.UPropertyRecordID,
    x.SourceSystem,
    x.SourceRecordID,
    x.SourceEntityType,
    x.MatchMethodCode,
    x.MatchResult,
    x.MatchConfidence,
    x.ProcessingStatus,
    x.EffectiveStartDate,
    x.Notes
FROM dbo.UPROPERTYRECORD upr
INNER JOIN dbo.UPROPERTYRECORD_XREF x ON x.UPropertyRecordID = upr.UPropertyRecordID
WHERE (@SDATAccountNumber IS NULL OR upr.SDATAccountNumber = @SDATAccountNumber)
  AND (@ParcelID          IS NULL OR upr.ParcelID = @ParcelID)
  AND (@StreetName        IS NULL OR upr.StreetName LIKE N'%' + @StreetName + N'%')
  AND (@City              IS NULL OR upr.City = @City)
  AND (@SourceSystem IS NULL OR x.SourceSystem = @SourceSystem)
ORDER BY upr.UPropertyRecordID, x.SourceSystem;

PRINT N'';
PRINT N'--- Review Queue (if any) ---';

SELECT
    q.UPRMatchReviewID,
    q.UPropertyRecordID,
    q.IncomingSourceSystem,
    q.NormalizedIncomingAddress,
    q.SDATAccountNumber,
    q.ParcelID,
    q.ReasonForNoMatch,
    q.ReviewStatus,
    q.ProcessingTimestamp
FROM dbo.UPROPERTYMATCHREVIEW_Q q
WHERE (@SDATAccountNumber IS NULL OR q.SDATAccountNumber = @SDATAccountNumber)
  AND (@ParcelID          IS NULL OR q.ParcelID = @ParcelID)
ORDER BY q.UPRMatchReviewID;

GO
