/*
================================================================================
  UPR Full Records / Hierarchy Listing - 2026-10-13
  Read existing loaded UPR data; no loader rerun or audit installation required.

  Lists every UPR record as Parent followed by its children, so you can confirm
  complete records were written (Complex/Property/Condo -> Building -> Unit).

  Columns include: LevelNo, UPRID, ParentUPRID, AccountNumber, EntityType,
  names, address, owner/contact, property type, parcel, unit number.
  LevelNo is the depth from the root (0). UPR_CLOSURE.Level is distance
  within an ancestor/descendant pair; they match only for a root ancestor. ParentUPRID is the immediate parent; UPRID is the child.

  EDIT:
    - Select the intended database in SSMS; this file does not switch databases
    - @FilterAccount  = NULL for ALL records, or set one Account# to drill down
    - @MaxRows        = NULL for all root trees, or a positive root-tree cap
================================================================================
*/

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

DECLARE @FilterAccount NVARCHAR(50) = NULL;   -- e.g. N'00272531'  |  NULL = all
DECLARE @MaxRows       INT          = NULL;  -- optional cap on roots, not children
DECLARE @AsOfDate DATE=CONVERT(DATE,GETDATE());
DECLARE @ShowAllAssociations BIT=1;          -- all direct address/contact links
/* BuildingID is the model key, not a street number or invented building number.
   Display a separate BuildingNumber only if that column actually exists. */
IF OBJECT_ID('tempdb..#ReportBuildingNumber') IS NOT NULL DROP TABLE #ReportBuildingNumber;
CREATE TABLE #ReportBuildingNumber(BuildingID BIGINT PRIMARY KEY,BuildingNumber NVARCHAR(200) NULL);
IF COL_LENGTH(N'dbo.BUILDING',N'BuildingNumber') IS NOT NULL
    EXEC sys.sp_executesql N'INSERT #ReportBuildingNumber(BuildingID,BuildingNumber)
        SELECT BuildingID,CONVERT(NVARCHAR(200),BuildingNumber) FROM dbo.BUILDING;';
IF OBJECT_ID('tempdb..#ReportADU') IS NOT NULL DROP TABLE #ReportADU;
CREATE TABLE #ReportADU(UPRID BIGINT,UnitNumber NVARCHAR(50));
IF COL_LENGTH(N'dbo.ADU',N'UPRID') IS NOT NULL AND COL_LENGTH(N'dbo.ADU',N'UnitNumber') IS NOT NULL
    EXEC sys.sp_executesql N'INSERT #ReportADU(UPRID,UnitNumber) SELECT UPRID,UnitNumber FROM dbo.ADU;';


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
        INNER JOIN dbo.UPR root ON root.UPRID = cl.AncestorUPRID
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

IF OBJECT_ID('tempdb..#ReportTree') IS NOT NULL DROP TABLE #ReportTree;
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
            RIGHT(REPLICATE('0', 20) + CONVERT(VARCHAR(20), u.UPRID), 20))
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
            + RIGHT(REPLICATE('0', 20) + CONVERT(VARCHAR(20), c.UPRID), 20))
    FROM Tree t
    INNER JOIN dbo.UPR c ON c.ParentUPRID = t.UPRID
)
SELECT * INTO #ReportTree FROM Tree OPTION(MAXRECURSION 100);
CREATE UNIQUE CLUSTERED INDEX IX_ReportTree ON #ReportTree(UPRID);
/* Default all-records mode also includes rows with no reachable property root.
   Their level/root are unknown; do not silently omit or invent their hierarchy. */
IF @NormAccount IS NULL AND @MaxRows IS NULL
    INSERT #ReportTree(RootUPRID,RootAccount,UPRID,ParentUPRID,EntityTypeID,AccountNumber,StatusCode,LevelNo,SortPath)
    SELECT u.UPRID,u.AccountNumber,u.UPRID,u.ParentUPRID,u.EntityTypeID,u.AccountNumber,u.StatusCode,-1,
        CONVERT(VARCHAR(8000),N'~'+CONVERT(VARCHAR(20),u.UPRID))
    FROM dbo.UPR u WHERE NOT EXISTS(SELECT 1 FROM #ReportTree t WHERE t.UPRID=u.UPRID);

SELECT
    LevelNo=CASE WHEN t.LevelNo>=0 THEN t.LevelNo END,
    Hierarchy = CASE WHEN t.LevelNo<0 THEN N'[UNRESOLVED HIERARCHY] ' ELSE REPLICATE(N'  ',t.LevelNo) END
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
    RootUPRID     = CASE WHEN t.LevelNo>=0 THEN t.RootUPRID END,
    RootAccount   = t.RootAccount,
    AccountNumber = COALESCE(t.AccountNumber,t.RootAccount),
    EntityType    = e.Description,
    StatusCode    = t.StatusCode,
    CommunityName = cx.CommunityName,
    PropertyName  = p.PropertyName,
    BuildingName  = COALESCE(b.BuildingName,linkedBuilding.BuildingName),
    UnitNumber    = COALESCE(un.UnitNumber, ad.UnitNumber),
    PropertyType  = COALESCE(pt.PropertyTypeCode, cxt.PropertyTypeCode),
    Parcel        = COALESCE(p.Parcel,condoHistory.ParcelID),
    ParcelSource  = CASE WHEN p.Parcel IS NOT NULL THEN N'PROPERTY'
                        WHEN condoHistory.ParcelID IS NOT NULL THEN N'Condo load status history' END,
    YearBuilt     = COALESCE(b.YearBuilt,linkedBuilding.YearBuilt),
    Address       = CASE WHEN a.AddressID IS NOT NULL THEN COALESCE(NULLIF(a.NormalizedAddress,N''),LTRIM(RTRIM(CONCAT(a.StreetNumber,N' ',a.StreetDirection,N' ',a.StreetName,N' ',a.StreetType,N' ',a.StreetSuffix)))) END,
    StreetNumber  = a.StreetNumber,
    StreetName    = a.StreetName,
    City          = a.City,
    ZipCode       = a.ZipCode,
    OwnerName     = owner.OwnerName,
    ContactName   = ct.ContactName,
    RecordAccountNumber = t.AccountNumber,
    AccountSourceUPRID = CASE WHEN t.AccountNumber IS NOT NULL THEN t.UPRID
                             WHEN t.RootAccount IS NOT NULL THEN t.RootUPRID END,
    OwnerSourceUPRID = owner.OwnerUPRID,
    OwnerSource = owner.OwnerSource,
    OwnerIsInherited = CONVERT(BIT,CASE WHEN owner.OwnerUPRID<>t.UPRID THEN 1 ELSE 0 END),
    OwnerContactID = owner.ContactID,
    ContactRole = ct.ContactRole,
    AddressSourceUPRID = a.AddressUPRID,
    AddressIsInherited = CONVERT(BIT,CASE WHEN a.AddressUPRID<>t.UPRID THEN 1 ELSE 0 END),
    AddressRole = a.AddressRole,
    StreetDirection=a.StreetDirection,StreetType=a.StreetType,StreetSuffix=a.StreetSuffix,State=a.State,
    FullAddress = CASE WHEN a.AddressID IS NOT NULL THEN LTRIM(RTRIM(CONCAT(a.StreetNumber,N' ',a.StreetDirection,N' ',a.StreetName,N' ',a.StreetType,N' ',a.StreetSuffix,N', ',a.City,N', ',a.State,N' ',a.ZipCode))) END,
    BuildingUPRID = COALESCE(b.UPRID,linkedBuilding.UPRID),
    BuildingNumber = bn.BuildingNumber,
    BuildingNumberAvailability = CASE WHEN COL_LENGTH(N'dbo.BUILDING',N'BuildingNumber') IS NULL
        THEN N'No separate BuildingNumber column; BuildingID is shown separately'
        WHEN bn.BuildingNumber IS NULL THEN N'Not recorded' ELSE N'Recorded value' END,
    BuildingID    = COALESCE(b.BuildingID, un.BuildingID),
    UnitID        = un.UnitID
FROM #ReportTree t
INNER JOIN dbo.REF_ENTITYTYPE e ON e.EntityTypeID = t.EntityTypeID
LEFT JOIN dbo.COMPLEX  cx ON cx.UPRID = t.UPRID
LEFT JOIN dbo.PROPERTY p  ON p.UPRID  = t.UPRID
LEFT JOIN dbo.CONDO    d  ON d.UPRID  = t.UPRID
OUTER APPLY (
    SELECT TOP (1) h.ParcelID
    FROM dbo.UPRSTATUSHISTORY h
    WHERE d.CondoID IS NOT NULL AND h.UPRID = t.UPRID AND h.ChangeSource = N'HIER_LOAD'
    ORDER BY h.ChangedDate DESC, h.UPRStatusHistoryID DESC
) condoHistory
LEFT JOIN dbo.BUILDING b  ON b.UPRID  = t.UPRID
LEFT JOIN dbo.UNIT     un ON un.UPRID = t.UPRID
LEFT JOIN #ReportADU ad ON ad.UPRID=t.UPRID
LEFT JOIN dbo.BUILDING linkedBuilding ON linkedBuilding.BuildingID=un.BuildingID
LEFT JOIN #ReportBuildingNumber bn ON bn.BuildingID=COALESCE(b.BuildingID,un.BuildingID)
LEFT JOIN dbo.REF_PROPERTYTYPE pt  ON pt.PropertyTypeID  = p.PropertyTypeID
LEFT JOIN dbo.REF_PROPERTYTYPE cxt ON cxt.PropertyTypeID = cx.PropertyTypeID
OUTER APPLY (
    /* Prefer own current address; otherwise a related Building/ancestor address.
       Keep its source UPRID visible so a fallback is never presented as direct. */
    SELECT TOP(1) addr.AddressID,addr.NormalizedAddress,addr.StreetNumber,addr.StreetName,
        addr.StreetDirection,addr.StreetType,addr.StreetSuffix,addr.City,addr.State,addr.ZipCode,
        rel.AddressUPRID,ar.AddressRoleCode AS AddressRole
    FROM (
        SELECT ua.UPRID AS AddressUPRID,ua.AddressID,ua.AddressRoleID,ua.IsPrimary,ua.UPRAddressID,
            ua.EffectiveDate,ua.EndDate,Pri=0,Distance=0
        FROM dbo.UPR_ADDRESS ua WHERE ua.UPRID=t.UPRID
        UNION ALL
        SELECT ua.UPRID,ua.AddressID,ua.AddressRoleID,ua.IsPrimary,ua.UPRAddressID,
            ua.EffectiveDate,ua.EndDate,1,cl.[Level]
        FROM dbo.UPR_CLOSURE cl JOIN dbo.BUILDING childBuilding ON childBuilding.UPRID=cl.DescendantUPRID
        JOIN dbo.UPR_ADDRESS ua ON ua.UPRID=childBuilding.UPRID
        WHERE cl.AncestorUPRID=t.UPRID AND cl.DescendantUPRID<>t.UPRID
        UNION ALL
        SELECT ua.UPRID,ua.AddressID,ua.AddressRoleID,ua.IsPrimary,ua.UPRAddressID,
            ua.EffectiveDate,ua.EndDate,2,cl.[Level]
        FROM dbo.UPR_CLOSURE cl JOIN dbo.UPR_ADDRESS ua ON ua.UPRID=cl.AncestorUPRID
        WHERE cl.DescendantUPRID=t.UPRID AND cl.AncestorUPRID<>t.UPRID
    ) rel JOIN dbo.ADDRESS addr ON addr.AddressID=rel.AddressID
    JOIN dbo.REF_ADDRESSROLE ar ON ar.AddressRoleID=rel.AddressRoleID
    WHERE (rel.EffectiveDate IS NULL OR rel.EffectiveDate<=@AsOfDate)
      AND (rel.EndDate IS NULL OR rel.EndDate>=@AsOfDate)
    ORDER BY rel.Pri,CASE WHEN ar.AddressRoleCode=N'PHYSICAL' THEN 0 ELSE 1 END,
        rel.Distance,rel.IsPrimary DESC,rel.UPRAddressID
) a
OUTER APPLY (
    SELECT TOP(1) oc.OwnerUPRID,oc.OwnerName,oc.OwnerSource,oc.ContactID
    FROM (
        /* OWNER_CANDIDATES_BEGIN */
        SELECT p.UPRID AS OwnerUPRID,NULLIF(LTRIM(RTRIM(p.OwnerName)),N'') AS OwnerName,
            N'PROPERTY.OwnerName' AS OwnerSource,CAST(NULL AS BIGINT) AS ContactID,0 AS SourcePriority
        FROM dbo.PROPERTY p
        UNION ALL
        SELECT d.UPRID,NULLIF(LTRIM(RTRIM(d.OwnerName)),N''),N'CONDO.OwnerName',NULL,0 FROM dbo.CONDO d
        UNION ALL
        SELECT uc.UPRID,COALESCE(NULLIF(LTRIM(RTRIM(c.OrganizationName)),N''),
            NULLIF(LTRIM(RTRIM(CONCAT(c.FirstName,N' ',c.LastName))),N'')),N'OWNER contact',c.ContactID,1
        FROM dbo.UPR_CONTACT uc JOIN dbo.CONTACT c ON c.ContactID=uc.ContactID
        JOIN dbo.REF_ROLETYPE r ON r.RoleTypeID=uc.RoleTypeID
        WHERE r.RoleTypeCode=N'OWNER' AND c.StatusCode=N'ACTIVE'
          AND (uc.EffectiveDate IS NULL OR uc.EffectiveDate<=@AsOfDate)
          AND (uc.EndDate IS NULL OR uc.EndDate>=@AsOfDate)
        /* OWNER_CANDIDATES_END */
    ) oc
    WHERE oc.OwnerName IS NOT NULL AND (oc.OwnerUPRID=t.UPRID OR EXISTS(
        SELECT 1 FROM dbo.UPR_CLOSURE cl WHERE cl.DescendantUPRID=t.UPRID AND cl.AncestorUPRID=oc.OwnerUPRID))
    ORDER BY CASE WHEN oc.OwnerUPRID=t.UPRID THEN 0 ELSE 1 END,
        (SELECT MIN(cl.[Level]) FROM dbo.UPR_CLOSURE cl WHERE cl.DescendantUPRID=t.UPRID AND cl.AncestorUPRID=oc.OwnerUPRID),
        oc.SourcePriority,oc.OwnerUPRID,oc.ContactID,oc.OwnerName
) owner
OUTER APPLY (
    /* General contact is separate from ownership; never label an agent as owner. */
    SELECT TOP(1) ContactName=COALESCE(NULLIF(c.OrganizationName,N''),NULLIF(LTRIM(RTRIM(CONCAT(c.FirstName,N' ',c.LastName))),N'')),
        r.RoleTypeCode AS ContactRole
    FROM dbo.UPR_CONTACT uc JOIN dbo.CONTACT c ON c.ContactID=uc.ContactID
    JOIN dbo.REF_ROLETYPE r ON r.RoleTypeID=uc.RoleTypeID
    WHERE uc.UPRID=t.UPRID AND c.StatusCode=N'ACTIVE'
      AND (uc.EffectiveDate IS NULL OR uc.EffectiveDate<=@AsOfDate) AND (uc.EndDate IS NULL OR uc.EndDate>=@AsOfDate)
    ORDER BY CASE WHEN r.RoleTypeCode=N'OWNER' THEN 0 ELSE 1 END,uc.UPRContactID
) ct
ORDER BY t.SortPath;

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
                INNER JOIN dbo.UPR root ON root.UPRID = cl.AncestorUPRID
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

    /* R9: a Unit parent must be the Building referenced by UNIT.BuildingID. */
    SELECT
        Issue  = N'Unit has invalid Building link',
        un.UPRID,
        Detail = N'Unit ' + COALESCE(un.UnitNumber, N'(no unit number)')
               + N': BuildingID must identify the immediate Building parent'
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
              AND pe.Description=N'Building' AND parent.UPRID=linked.UPRID
          )
      AND (@NormAccount IS NULL
           OR u.AccountNumber = @NormAccount
           OR EXISTS (
                SELECT 1 FROM dbo.UPR_CLOSURE cl
                INNER JOIN dbo.UPR root ON root.UPRID = cl.AncestorUPRID
                WHERE cl.DescendantUPRID = u.UPRID
                  AND root.ParentUPRID IS NULL
                  AND root.AccountNumber = @NormAccount
              ))
) x
INNER JOIN dbo.UPR u ON u.UPRID = x.UPRID
INNER JOIN dbo.REF_ENTITYTYPE e ON e.EntityTypeID = u.EntityTypeID
ORDER BY Issue, u.AccountNumber, u.UPRID;

PRINT N'';
IF @ShowAllAssociations=1
BEGIN
    SELECT N'All address links' AS RecordSection,ua.UPRID,ua.AddressID,ar.AddressRoleCode,ua.IsPrimary,
        a.StreetNumber,a.StreetDirection,a.StreetName,a.StreetType,a.StreetSuffix,a.City,a.State,a.ZipCode,
        ua.EffectiveDate,ua.EndDate,
        CASE WHEN ua.EffectiveDate>@AsOfDate THEN N'Future' WHEN ua.EndDate<@AsOfDate THEN N'Ended' ELSE N'Current' END AS AssociationStatus
    FROM #ReportTree t JOIN dbo.UPR_ADDRESS ua ON ua.UPRID=t.UPRID
    JOIN dbo.ADDRESS a ON a.AddressID=ua.AddressID JOIN dbo.REF_ADDRESSROLE ar ON ar.AddressRoleID=ua.AddressRoleID
    ORDER BY ua.UPRID,ua.AddressID,ua.UPRAddressID;
    SELECT N'All contact links' AS RecordSection,uc.UPRID,c.ContactID,r.RoleTypeCode,
        c.FirstName,c.MiddleName,c.LastName,c.OrganizationName,c.Phone,c.Email,c.StatusCode,
        uc.EffectiveDate,uc.EndDate,
        CASE WHEN uc.EffectiveDate>@AsOfDate THEN N'Future' WHEN uc.EndDate<@AsOfDate THEN N'Ended' ELSE N'Current' END AS AssociationStatus
    FROM #ReportTree t JOIN dbo.UPR_CONTACT uc ON uc.UPRID=t.UPRID
    JOIN dbo.CONTACT c ON c.ContactID=uc.ContactID JOIN dbo.REF_ROLETYPE r ON r.RoleTypeID=uc.RoleTypeID
    ORDER BY uc.UPRID,c.ContactID,r.RoleTypeCode;
END;
IF EXISTS(SELECT 1 FROM #ReportTree WHERE LevelNo<0)
    SELECT N'Unresolved hierarchy: records included with unknown LevelNo/RootUPRID' AS Issue,UPRID,ParentUPRID
    FROM #ReportTree WHERE LevelNo<0;

PRINT N'HIERARCHY LISTING COMPLETE';
PRINT N'  Section 2 = parent/child trees within the selected root limit (Results grid).';
PRINT N'  Section 3 empty = no issues found by these checks; not a full integrity audit.';
GO
