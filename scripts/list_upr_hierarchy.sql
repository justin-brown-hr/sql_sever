/*
================================================================================
  UPR Hierarchy Listing
  Run AFTER scripts/load_upr_master.sql

  Lists every UPR record as Parent followed by its children, so you can confirm
  complete records were written (Complex/Property/Condo -> Building -> Unit).

  Columns include: LevelNo, UPRID, ParentUPRID, AccountNumber, EntityType,
  names, address, owner/contact, property type, parcel, unit number.
  LevelNo is the depth from the root (0), matching UPR_CLOSURE.Level for
  this descendant. ParentUPRID is the immediate parent; UPRID is the child.

  EDIT:
    - USE database name if yours differs
    - @FilterAccount  = NULL for ALL records, or set one Account# to drill down
    - @MaxRows        = NULL for all root trees, or a positive root-tree cap
================================================================================
*/
USE UPRXDB_TEST;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

DECLARE @FilterAccount NVARCHAR(50) = NULL;   -- e.g. N'00272531'  |  NULL = all
DECLARE @MaxRows       INT          = NULL;  -- optional cap on roots, not children

IF @MaxRows IS NOT NULL AND @MaxRows <= 0
    THROW 50001, '@MaxRows must be NULL (all roots) or a positive integer.', 1;

/* Normalize filter locally - do not call load-script functions.
   (SSMS / SQL Server still bind those names at compile time even
   inside OBJECT_ID checks, which causes "Cannot find object".)
   Match the loader: remove spaces/hyphens from numeric accounts, pad
   short values to eight digits and preserve every digit of longer values. */
DECLARE @NormAccount NVARCHAR(50) = NULLIF(LTRIM(RTRIM(@FilterAccount)), N'');
DECLARE @AccountDigits NVARCHAR(50) = REPLACE(REPLACE(@NormAccount, N'-', N''), N' ', N'');
IF @AccountDigits <> N'' AND @AccountDigits NOT LIKE N'%[^0-9]%'
    SET @NormAccount = CASE WHEN LEN(@AccountDigits) < 8
        THEN REPLICATE(N'0', 8 - LEN(@AccountDigits)) + @AccountDigits ELSE @AccountDigits END;

PRINT N'============================================================';
PRINT N'  UPR HIERARCHY LISTING';
PRINT N'  Database: ' + DB_NAME()
    + N'   Run: ' + CONVERT(NVARCHAR(30), SYSDATETIME(), 120);
IF @NormAccount IS NOT NULL
    PRINT N'  Filter Account#: ' + @NormAccount;
ELSE
    PRINT N'  Filter Account#: (all records)';
PRINT N'============================================================';

/* ------------------------------------------------------------
   SECTION 1 - Summary counts (quick completeness glance)
   ------------------------------------------------------------ */
PRINT N'';
PRINT N'--- Section 1: Summary counts ---';

SELECT
    EntityType = e.Description,
    Records    = COUNT(*)
FROM dbo.UPR u
INNER JOIN dbo.REF_ENTITYTYPE e ON e.EntityTypeID = u.EntityTypeID
WHERE @NormAccount IS NULL
   OR u.AccountNumber = @NormAccount
   OR EXISTS (
        SELECT 1
        FROM dbo.UPR_CLOSURE cl
        INNER JOIN dbo.UPR root ON root.UPRID = cl.UPRAncestry
        WHERE cl.DescendantUPRID = u.UPRID
          AND root.ParentUPRID IS NULL
          AND root.AccountNumber = @NormAccount
      )
GROUP BY e.Description
ORDER BY
    CASE e.Description
        WHEN N'Complex'  THEN 1
        WHEN N'Property' THEN 2
        WHEN N'Condo'    THEN 3
        WHEN N'Building' THEN 4
        WHEN N'Unit'     THEN 5
        WHEN N'ADU'      THEN 6
        ELSE 9
    END;

/* ------------------------------------------------------------
   SECTION 2 - Full hierarchy: Parent then children
   One row per UPR. Level 0 = root parent (Complex / Property / Condo).
   Indent shows depth. Sort keeps each tree together.
   ------------------------------------------------------------ */
PRINT N'';
PRINT N'--- Section 2: Parent -> child hierarchy (complete records) ---';

DECLARE @MatchingRoots BIGINT;
SELECT @MatchingRoots = COUNT_BIG(*)
FROM dbo.UPR u
INNER JOIN dbo.REF_ENTITYTYPE e ON e.EntityTypeID = u.EntityTypeID
WHERE u.ParentUPRID IS NULL
  AND e.Description IN (N'Complex', N'Property', N'Condo')
  AND (@NormAccount IS NULL OR u.AccountNumber = @NormAccount);

DECLARE @RootLimit BIGINT = COALESCE(CONVERT(BIGINT, @MaxRows), @MatchingRoots);
IF @RootLimit < @MatchingRoots
BEGIN
    PRINT N'WARNING: Section 2 is capped. Set @MaxRows = NULL to list all root trees.';
    /* Also show the warning in Results, where the client reviews the tree. */
    SELECT
        Warning = N'Section 2 is capped; Sections 1 and 3 still cover all matching records.',
        MatchingRoots = @MatchingRoots,
        ListedRoots = @RootLimit,
        OmittedRoots = @MatchingRoots - @RootLimit;
END;

;WITH Roots AS
(
    SELECT TOP (@RootLimit)
        u.UPRID AS RootUPRID,
        u.AccountNumber AS RootAccount
    FROM dbo.UPR u
    INNER JOIN dbo.REF_ENTITYTYPE e ON e.EntityTypeID = u.EntityTypeID
    WHERE u.ParentUPRID IS NULL
      AND e.Description IN (N'Complex', N'Property', N'Condo')
      AND (@NormAccount IS NULL OR u.AccountNumber = @NormAccount)
    ORDER BY u.AccountNumber, u.UPRID
),
Tree AS
(
    /* Level 0 - root parents */
    SELECT
        r.RootUPRID,
        r.RootAccount,
        u.UPRID,
        u.ParentUPRID,
        u.EntityTypeID,
        u.AccountNumber,
        u.StatusCode,
        LevelNo = 0,
        SortPath = CONVERT(VARCHAR(8000),
            RIGHT(REPLICATE('0', 12) + CONVERT(VARCHAR(12), u.UPRID), 12))
    FROM Roots r
    INNER JOIN dbo.UPR u ON u.UPRID = r.RootUPRID

    UNION ALL

    /* Children under each parent */
    SELECT
        t.RootUPRID,
        t.RootAccount,
        c.UPRID,
        c.ParentUPRID,
        c.EntityTypeID,
        c.AccountNumber,
        c.StatusCode,
        LevelNo = t.LevelNo + 1,
        SortPath = CONVERT(VARCHAR(8000),
            t.SortPath + N'.'
            + RIGHT(REPLICATE('0', 12) + CONVERT(VARCHAR(12), c.UPRID), 12))
    FROM Tree t
    INNER JOIN dbo.UPR c ON c.ParentUPRID = t.UPRID
)
SELECT
    LevelNo,
    Hierarchy = REPLICATE(N'  ', LevelNo)
                + CASE e.Description
                      WHEN N'Complex'  THEN N'[COMPLEX]  '
                      WHEN N'Property' THEN N'[PROPERTY] '
                      WHEN N'Condo'    THEN N'[CONDO]    '
                      WHEN N'Building' THEN N'[BUILDING] '
                      WHEN N'Unit'     THEN N'[UNIT]     '
                      WHEN N'ADU'      THEN N'[ADU]      '
                      ELSE N'[' + e.Description + N'] '
                  END
                + COALESCE(
                      cx.CommunityName,
                      p.PropertyName,
                      b.BuildingName,
                      un.UnitNumber,
                      ad.UnitNumber,
                      N'(no name)')
                + CASE
                      WHEN a.NormalizedAddress IS NOT NULL
                          THEN N'  |  ' + a.NormalizedAddress
                      ELSE N''
                  END,
    t.UPRID,
    t.ParentUPRID,
    RootUPRID     = t.RootUPRID,
    RootAccount   = t.RootAccount,
    AccountNumber = t.AccountNumber,
    EntityType    = e.Description,
    StatusCode    = t.StatusCode,
    CommunityName = cx.CommunityName,
    PropertyName  = p.PropertyName,
    BuildingName  = b.BuildingName,
    UnitNumber    = COALESCE(un.UnitNumber, ad.UnitNumber),
    PropertyType  = COALESCE(pt.PropertyTypeCode, cxt.PropertyTypeCode),
    Parcel        = COALESCE(p.Parcel, condoParcel.Parcel),
    ParcelSource  = CASE WHEN p.Parcel IS NOT NULL THEN N'PROPERTY'
                        WHEN condoLegacy.Parcel IS NOT NULL THEN N'Archived CONDO value'
                        WHEN condoLegacy.CondoID IS NULL AND condoHistory.ParcelID IS NOT NULL THEN N'Load history' END,
    YearBuilt     = b.YearBuilt,
    Address       = a.NormalizedAddress,
    StreetNumber  = a.StreetNumber,
    StreetName    = a.StreetName,
    City          = a.City,
    ZipCode       = a.ZipCode,
    OwnerName     = COALESCE(p.OwnerName, d.OwnerName, ct.OrganizationName),
    ContactName   = ct.OrganizationName,
    BuildingID    = COALESCE(b.BuildingID, un.BuildingID),
    UnitID        = un.UnitID
FROM Tree t
INNER JOIN dbo.REF_ENTITYTYPE e ON e.EntityTypeID = t.EntityTypeID
LEFT JOIN dbo.COMPLEX  cx ON cx.UPRID = t.UPRID
LEFT JOIN dbo.PROPERTY p  ON p.UPRID  = t.UPRID
LEFT JOIN dbo.CONDO    d  ON d.UPRID  = t.UPRID
LEFT JOIN dbo.UPR_CONDO_LEGACY condoLegacy ON condoLegacy.CondoID = d.CondoID AND condoLegacy.UPRID = t.UPRID
OUTER APPLY (
    SELECT TOP (1) h.ParcelID
    FROM dbo.UPRSTATUSHISTORY h
    WHERE d.CondoID IS NOT NULL AND h.UPRID = t.UPRID AND h.ChangeSource = N'HIER_LOAD'
    ORDER BY h.ChangedDate DESC, h.UPRStatusHistoryID DESC
) condoHistory
CROSS APPLY (SELECT Parcel = CASE WHEN condoLegacy.CondoID IS NOT NULL
    THEN CONVERT(NVARCHAR(50), condoLegacy.Parcel) ELSE condoHistory.ParcelID END) condoParcel
LEFT JOIN dbo.BUILDING b  ON b.UPRID  = t.UPRID
LEFT JOIN dbo.UNIT     un ON un.UPRID = t.UPRID
LEFT JOIN dbo.ADU      ad ON ad.UPRID = t.UPRID
LEFT JOIN dbo.REF_PROPERTYTYPE pt  ON pt.PropertyTypeID  = p.PropertyTypeID
LEFT JOIN dbo.REF_PROPERTYTYPE cxt ON cxt.PropertyTypeID = cx.PropertyTypeID
OUTER APPLY (
    /* Own address, else first building descendant address, else ancestor address */
    SELECT TOP 1 addr.NormalizedAddress, addr.StreetNumber, addr.StreetName,
                 addr.City, addr.ZipCode
    FROM (
        SELECT ua.AddressID, ua.IsPrimary, ua.UPRAddressID, Pri = 0
        FROM dbo.UPR_ADDRESS ua
        WHERE ua.UPRID = t.UPRID
        UNION ALL
        SELECT ua.AddressID, ua.IsPrimary, ua.UPRAddressID, Pri = 1
        FROM dbo.UPR_CLOSURE cl
        INNER JOIN dbo.UPR_ADDRESS ua ON ua.UPRID = cl.DescendantUPRID
        WHERE cl.UPRAncestry = t.UPRID
          AND cl.DescendantUPRID <> t.UPRID
        UNION ALL
        SELECT ua.AddressID, ua.IsPrimary, ua.UPRAddressID, Pri = 2
        FROM dbo.UPR_CLOSURE cl
        INNER JOIN dbo.UPR_ADDRESS ua ON ua.UPRID = cl.UPRAncestry
        WHERE cl.DescendantUPRID = t.UPRID
          AND cl.UPRAncestry <> t.UPRID
    ) rel
    INNER JOIN dbo.ADDRESS addr ON addr.AddressID = rel.AddressID
    ORDER BY rel.Pri, rel.IsPrimary DESC, rel.UPRAddressID
) a
OUTER APPLY (
    SELECT TOP 1 c.OrganizationName
    FROM dbo.UPR_CONTACT uc
    INNER JOIN dbo.CONTACT c ON c.ContactID = uc.ContactID
    WHERE uc.UPRID = t.UPRID
    ORDER BY uc.UPRContactID
) ct
ORDER BY t.SortPath
OPTION (MAXRECURSION 100);

/* ------------------------------------------------------------
   SECTION 3 - Completeness flags (parents missing expected children)
   Empty result = no issues found by these checks. Any row needs attention.
   ------------------------------------------------------------ */
PRINT N'';
PRINT N'--- Section 3: Completeness flags (empty = good) ---';

SELECT
    Issue,
    u.UPRID,
    u.ParentUPRID,
    EntityType = e.Description,
    u.AccountNumber,
    Detail
FROM (
    /* Parent with no Building child */
    SELECT
        Issue  = N'Parent has no Building child',
        u.UPRID,
        Detail = N'Expected at least one Building under this parent'
    FROM dbo.UPR u
    INNER JOIN dbo.REF_ENTITYTYPE e ON e.EntityTypeID = u.EntityTypeID
    WHERE u.ParentUPRID IS NULL
      AND e.Description IN (N'Complex', N'Property', N'Condo')
      AND (@NormAccount IS NULL OR u.AccountNumber = @NormAccount)
      AND NOT EXISTS (
            SELECT 1
            FROM dbo.UPR c
            INNER JOIN dbo.REF_ENTITYTYPE ce ON ce.EntityTypeID = c.EntityTypeID
            WHERE c.ParentUPRID = u.UPRID
              AND ce.Description = N'Building'
          )

    UNION ALL

    /* Building with no primary Address */
    SELECT
        Issue  = N'Building has no primary Address',
        b.UPRID,
        Detail = COALESCE(b.BuildingName, N'(unnamed building)')
    FROM dbo.BUILDING b
    INNER JOIN dbo.UPR u ON u.UPRID = b.UPRID
    WHERE (@NormAccount IS NULL
           OR u.AccountNumber = @NormAccount
           OR EXISTS (
                SELECT 1 FROM dbo.UPR_CLOSURE cl
                INNER JOIN dbo.UPR root ON root.UPRID = cl.UPRAncestry
                WHERE cl.DescendantUPRID = u.UPRID
                  AND root.ParentUPRID IS NULL
                  AND root.AccountNumber = @NormAccount
              ))
      AND NOT EXISTS (
            SELECT 1 FROM dbo.UPR_ADDRESS ua
            WHERE ua.UPRID = b.UPRID AND ua.IsPrimary = 1
          )

    UNION ALL

    /* Parent with no Contact */
    SELECT
        Issue  = N'Parent has no Contact',
        u.UPRID,
        Detail = N'Owner/organization contact missing'
    FROM dbo.UPR u
    INNER JOIN dbo.REF_ENTITYTYPE e ON e.EntityTypeID = u.EntityTypeID
    WHERE u.ParentUPRID IS NULL
      AND e.Description IN (N'Complex', N'Property', N'Condo')
      AND (@NormAccount IS NULL OR u.AccountNumber = @NormAccount)
      AND NOT EXISTS (
            SELECT 1 FROM dbo.UPR_CONTACT uc WHERE uc.UPRID = u.UPRID
          )

    UNION ALL

    /* A Unit may be under its Building, or directly under a Condo with
       its linked Building under that same Condo (the loader's condo model). */
    SELECT
        Issue  = N'Unit has invalid Building link',
        un.UPRID,
        Detail = N'Unit ' + COALESCE(un.UnitNumber, N'(no unit number)')
               + N': BuildingID must match its Building parent or a Building under its Condo parent'
    FROM dbo.UNIT un
    INNER JOIN dbo.UPR u ON u.UPRID = un.UPRID
    WHERE NOT EXISTS (
            SELECT 1
            FROM dbo.BUILDING linked
            INNER JOIN dbo.UPR bu ON bu.UPRID = linked.UPRID
            INNER JOIN dbo.REF_ENTITYTYPE be ON be.EntityTypeID = bu.EntityTypeID
            INNER JOIN dbo.UPR parent ON parent.UPRID = u.ParentUPRID
            INNER JOIN dbo.REF_ENTITYTYPE pe ON pe.EntityTypeID = parent.EntityTypeID
            WHERE linked.BuildingID = un.BuildingID
              AND be.Description = N'Building'
              AND (
                    (pe.Description = N'Building' AND parent.UPRID = linked.UPRID)
                 OR (pe.Description = N'Condo' AND bu.ParentUPRID = parent.UPRID)
                  )
          )
      AND (@NormAccount IS NULL
           OR u.AccountNumber = @NormAccount
           OR EXISTS (
                SELECT 1 FROM dbo.UPR_CLOSURE cl
                INNER JOIN dbo.UPR root ON root.UPRID = cl.UPRAncestry
                WHERE cl.DescendantUPRID = u.UPRID
                  AND root.ParentUPRID IS NULL
                  AND root.AccountNumber = @NormAccount
              ))
) x
INNER JOIN dbo.UPR u ON u.UPRID = x.UPRID
INNER JOIN dbo.REF_ENTITYTYPE e ON e.EntityTypeID = u.EntityTypeID
ORDER BY Issue, u.AccountNumber, u.UPRID;

PRINT N'';
PRINT N'HIERARCHY LISTING COMPLETE';
PRINT N'  Section 2 = parent/child trees within the selected root limit (Results grid).';
PRINT N'  Section 3 empty = no issues found by these checks; not a full integrity audit.';
GO
