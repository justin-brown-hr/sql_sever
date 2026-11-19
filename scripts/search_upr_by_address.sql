/*
================================================================================
  UPR search by address - 2026-11-11
  Read-only. Corrected version of the client's UPR_BYAddress_Listing_GB script
  for the 11/6/2026 record layout (UNIT has no BuildingID).

  Why the original returned empty grids:
    - ADDRESS.NormalizedAddress holds the FULL line written by the loader,
      e.g. '1200 EAST WEST HWY SILVER SPRING 20910', so comparing it with the
      street alone ('1200 East West Hwy') never matched.
    - The fallback CONCAT kept one space per NULL part (StreetSuffix and
      StreetDirection are usually NULL), giving '1200  EAST WEST HWY' with
      double spaces, which never matched either.

  This version:
    - accepts the street alone, street + city, or the full stored line;
      case, commas, periods and extra spaces do not matter;
    - matches through IX_ADDRESS_NormalizedAddress (equality or prefix), and
      only falls back to the address parts when that finds nothing;
    - shows a Unit's Building through UPR.ParentUPRID (a Unit's parent UPR is
      its Building in the new layout).

  EDIT: the USE line, then @SearchAddress (and optionally City / ZipCode).
  Street types must be written as stored by the loader: HWY, DR, ST, AVE, ...
================================================================================
*/
USE UPR2XXDB_TEST;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;

------------------------------------------------------------
-- 1. INPUT: Enter the address you want to search
------------------------------------------------------------
DECLARE @SearchAddress VARCHAR(300) = '1200 East West Hwy';
DECLARE @SearchCity    VARCHAR(100) = NULL;
DECLARE @SearchZipCode VARCHAR(10)  = NULL;
DECLARE @AsOfDate      DATE         = CONVERT(DATE, GETDATE());

/* Normalize the input the same way the loader writes NormalizedAddress:
   upper case, no commas/periods, single spaces. */
DECLARE @s VARCHAR(300) = UPPER(LTRIM(RTRIM(
    REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@SearchAddress, ',', ' '), '.', ' '),
        CHAR(9), ' '), CHAR(13), ' '), CHAR(10), ' '))));
WHILE CHARINDEX('  ', @s) > 0 SET @s = REPLACE(@s, '  ', ' ');
DECLARE @City VARCHAR(100) = NULLIF(UPPER(LTRIM(RTRIM(@SearchCity))), '');
DECLARE @Zip5 VARCHAR(5)   = NULLIF(LEFT(LTRIM(RTRIM(@SearchZipCode)), 5), '');

IF @s IS NULL OR @s = ''
    THROW 50001, 'Set @SearchAddress, for example ''1200 East West Hwy''.', 1;

------------------------------------------------------------
-- 2. Find the matching ADDRESS records
------------------------------------------------------------
DROP TABLE IF EXISTS #MatchedAddresses;
DROP TABLE IF EXISTS #MatchedUPRs;
DROP TABLE IF EXISTS #RootUPRs;

CREATE TABLE #MatchedAddresses
(
    AddressID         BIGINT PRIMARY KEY,
    MatchedBy         VARCHAR(30),
    StreetNumber      VARCHAR(20),
    StreetDirection   VARCHAR(20),
    StreetName        VARCHAR(200),
    StreetType        VARCHAR(30),
    StreetSuffix      VARCHAR(3),
    NormalizedAddress VARCHAR(300),
    City              VARCHAR(100),
    State             CHAR(2),
    ZipCode           VARCHAR(10)
);

/* 2a. Index match: the full stored line, or the line starting with the search
       text ('1200 EAST WEST HWY' finds '1200 EAST WEST HWY SILVER SPRING 20910'). */
INSERT #MatchedAddresses
SELECT A.AddressID, 'NormalizedAddress', A.StreetNumber, A.StreetDirection, A.StreetName,
       A.StreetType, A.StreetSuffix, A.NormalizedAddress, A.City, A.State, A.ZipCode
FROM dbo.ADDRESS A
WHERE (A.NormalizedAddress = @s OR A.NormalizedAddress LIKE @s + ' %')
  AND (@City IS NULL OR UPPER(LTRIM(RTRIM(A.City))) = @City)
  AND (@Zip5 IS NULL OR LEFT(LTRIM(RTRIM(A.ZipCode)), 5) = @Zip5);

/* 2b. Fallback on the address parts (NULL parts skipped, single spaces),
       only when the index match found nothing. */
IF NOT EXISTS (SELECT 1 FROM #MatchedAddresses)
    INSERT #MatchedAddresses
    SELECT A.AddressID, 'Street parts', A.StreetNumber, A.StreetDirection, A.StreetName,
           A.StreetType, A.StreetSuffix, A.NormalizedAddress, A.City, A.State, A.ZipCode
    FROM dbo.ADDRESS A
    CROSS APPLY (SELECT Street = UPPER(LTRIM(RTRIM(
              ISNULL(NULLIF(LTRIM(RTRIM(A.StreetNumber)), '') + ' ', '')
            + ISNULL(NULLIF(LTRIM(RTRIM(A.StreetDirection)), '') + ' ', '')
            + ISNULL(NULLIF(LTRIM(RTRIM(A.StreetName)), '') + ' ', '')
            + ISNULL(NULLIF(LTRIM(RTRIM(A.StreetType)), '') + ' ', '')
            + ISNULL(NULLIF(LTRIM(RTRIM(A.StreetSuffix)), ''), ''))))) p
    WHERE p.Street = @s
      AND (@City IS NULL OR UPPER(LTRIM(RTRIM(A.City))) = @City)
      AND (@Zip5 IS NULL OR LEFT(LTRIM(RTRIM(A.ZipCode)), 5) = @Zip5);

IF NOT EXISTS (SELECT 1 FROM #MatchedAddresses)
    PRINT 'No ADDRESS matches ''' + @s + '''. Check the street type abbreviation (HWY, DR, ST, ...) and the City/ZIP filters.';

------------------------------------------------------------
-- 3. UPR entities linked to the address (current links)
------------------------------------------------------------
SELECT DISTINCT UA.UPRID, UA.AddressID, UA.AddressRoleID, UA.PrimaryInd
INTO #MatchedUPRs
FROM dbo.UPR_ADDRESS UA
INNER JOIN #MatchedAddresses A ON A.AddressID = UA.AddressID
WHERE (UA.EffectiveDate IS NULL OR UA.EffectiveDate <= @AsOfDate)
  AND (UA.EndDate IS NULL OR UA.EndDate >= @AsOfDate);

------------------------------------------------------------
-- 4. Root UPR (Complex / Property / Condo) of each matched entity
------------------------------------------------------------
SELECT DISTINCT C.AncestorUPRID AS RootUPRID
INTO #RootUPRs
FROM #MatchedUPRs M
INNER JOIN dbo.UPR_CLOSURE C ON C.DescendantUPRID = M.UPRID
INNER JOIN dbo.UPR R ON R.UPRID = C.AncestorUPRID AND R.ParentUPRID IS NULL;

------------------------------------------------------------
-- 5. Entire hierarchy under each root
------------------------------------------------------------
SELECT
    R.RootUPRID,
    C.DescendantUPRID AS UPRID,
    C.Level,
    U.ParentUPRID,
    ET.Description AS EntityType,
    U.AccountNumber,
    U.StatusCode AS UPRStatus,
    PrimaryAddress = addr.NormalizedAddress,
    /* Building rows: their own BUILDING row. Unit rows: the parent Building. */
    BuildingID     = COALESCE(B.BuildingID, PB.BuildingID),
    BuildingUPRID  = COALESCE(B.UPRID, PB.UPRID),
    BuildingName   = COALESCE(B.BuildingName, PB.BuildingName),
    YearBuilt      = COALESCE(B.YearBuilt, PB.YearBuilt),
    B.StatusCode AS BuildingStatus,
    UN.UnitID,
    UN.UnitNumber,
    UN.UnitTypeCode,
    UN.FloorNumber,
    UN.BedroomCount,
    UN.BathroomCount,
    UN.HasLegalIdentity,
    UN.StatusCode AS UnitStatus,
    HierarchyLevel = CASE WHEN C.Level = 0 THEN 'ROOT'
                          WHEN C.Level = 1 THEN 'DIRECT CHILD'
                          ELSE 'DESCENDANT' END
FROM #RootUPRs R
INNER JOIN dbo.UPR_CLOSURE C ON C.AncestorUPRID = R.RootUPRID
INNER JOIN dbo.UPR U ON U.UPRID = C.DescendantUPRID
INNER JOIN dbo.REF_ENTITYTYPE ET ON ET.EntityTypeID = U.EntityTypeID
LEFT JOIN dbo.BUILDING B ON B.UPRID = U.UPRID
LEFT JOIN dbo.UNIT UN ON UN.UPRID = U.UPRID
LEFT JOIN dbo.BUILDING PB ON UN.UnitID IS NOT NULL AND PB.UPRID = U.ParentUPRID
OUTER APPLY (
    SELECT TOP (1) a.NormalizedAddress
    FROM dbo.UPR_ADDRESS ua
    INNER JOIN dbo.ADDRESS a ON a.AddressID = ua.AddressID
    WHERE ua.UPRID = U.UPRID
      AND (ua.EffectiveDate IS NULL OR ua.EffectiveDate <= @AsOfDate)
      AND (ua.EndDate IS NULL OR ua.EndDate >= @AsOfDate)
    ORDER BY ua.PrimaryInd DESC, ua.UPRAddressID
) addr
ORDER BY R.RootUPRID, C.Level, U.ParentUPRID, U.UPRID;

------------------------------------------------------------
-- 6. The matched address records
------------------------------------------------------------
SELECT * FROM #MatchedAddresses ORDER BY AddressID;

------------------------------------------------------------
-- 7. UPR entities directly linked to the address
------------------------------------------------------------
SELECT
    M.UPRID,
    U.ParentUPRID,
    ET.Description AS EntityType,
    U.AccountNumber,
    M.AddressID,
    M.AddressRoleID,
    M.PrimaryInd,
    U.StatusCode
FROM #MatchedUPRs M
INNER JOIN dbo.UPR U ON U.UPRID = M.UPRID
INNER JOIN dbo.REF_ENTITYTYPE ET ON ET.EntityTypeID = U.EntityTypeID
ORDER BY M.UPRID;
GO
