/* UPR SEARCH / PROPERTY 360 DEMO - 2026-10-08
   Read-only business data: SELECTs and session temporary tables only.
   No installation, loader run, AuditLog change or closure/schema change.
   Run in SSMS under an authorized staff database account. This is not an API
   endpoint and does not replace the existing API authorization contract.
   Select the intended database in SSMS; this file deliberately has no USE.

   SEARCH -> read ALL matches -> select the desired UPRID -> 360.
   Examples (edit controls below, then run the ENTIRE file):
     SEARCH / ADDRESS / 123 Main Street
     SEARCH / ACCOUNT / your account number
     SEARCH / PARCEL / your parcel identifier
     SEARCH / OWNER / owner name
     SEARCH / UNIT / unit number (optionally restrict @BuildingUPRID)
     SEARCH / UPRID / 24
     SOURCES -> inspect recorded SourceSystem + IdentifierType pairs.
     SEARCH / MPDU, MULTIFAMILY_LOANS, CASE, LICENSE or EXTERNAL:
       set the exact @SourceSystem and @IdentifierType from SOURCES.
       These are identifier lookups only, not source-system case/program details.
       MPDU / MULTIFAMILY_LOANS may leave SearchValue NULL to list loaded links.
     360 / @SelectedUPRID = 207075 -> whole root property context, selected unit
       remains explicitly identified; no automatic first search-result selection.
*/
SET NOCOUNT ON;
DECLARE @Mode VARCHAR(12)='SEARCH';             -- SEARCH | 360 | SOURCES
DECLARE @SearchBy VARCHAR(24)='UPRID';          -- see examples above
DECLARE @SearchValue NVARCHAR(300)=N'24';       -- replace with a real demo value
DECLARE @SelectedUPRID BIGINT=NULL;            -- required only for mode 360
DECLARE @EntityType NVARCHAR(50)=NULL;         -- optional search filter, e.g. Unit
DECLARE @AddressRole NVARCHAR(30)=NULL;        -- optional code from REF_ADDRESSROLE
DECLARE @BuildingUPRID BIGINT=NULL;            -- optional UNIT search restriction
DECLARE @SourceSystem NVARCHAR(50)=NULL;       -- EXACT recorded external source
DECLARE @IdentifierType NVARCHAR(50)=NULL;     -- EXACT recorded identifier type
DECLARE @MaxMatches INT=200,@MaxContextNodes INT=5000,@MaxHistoryRows INT=500;
DECLARE @AsOfDate DATE=CONVERT(DATE,GETDATE()); -- database server's business date

SET @Mode=UPPER(LTRIM(RTRIM(@Mode)));
SET @SearchBy=UPPER(LTRIM(RTRIM(@SearchBy)));
SET @SearchValue=NULLIF(LTRIM(RTRIM(@SearchValue)),N'');
SET @EntityType=NULLIF(LTRIM(RTRIM(@EntityType)),N'');
SET @AddressRole=NULLIF(LTRIM(RTRIM(@AddressRole)),N'');
SET @SourceSystem=NULLIF(LTRIM(RTRIM(@SourceSystem)),N'');
SET @IdentifierType=NULLIF(LTRIM(RTRIM(@IdentifierType)),N'');
IF @Mode IS NULL OR @Mode NOT IN ('SEARCH','360','SOURCES')
    THROW 50001,'Choose SEARCH, 360 or SOURCES.',1;
IF @MaxMatches IS NULL OR @MaxMatches NOT BETWEEN 1 AND 5000
 OR @MaxContextNodes IS NULL OR @MaxContextNodes NOT BETWEEN 1 AND 20000
 OR @MaxHistoryRows IS NULL OR @MaxHistoryRows NOT BETWEEN 1 AND 10000
    THROW 50001,'Invalid demo result limits.',1;

/* Validate metadata before compiling the dependent query batch.
   Dynamic execution is fixed SQL; search values are passed as parameters. */
DECLARE @Required TABLE(TableName SYSNAME,ColumnName SYSNAME);
INSERT @Required VALUES
    (N'UPR',N'UPRID'),(N'UPR',N'ParentUPRID'),(N'UPR',N'EntityTypeID'),(N'UPR',N'AccountNumber'),(N'UPR',N'StatusCode'),(N'UPR',N'CreatedDate'),(N'UPR',N'UpdatedDate'),
    (N'REF_ENTITYTYPE',N'EntityTypeID'),(N'REF_ENTITYTYPE',N'Description'),
    (N'PROPERTY',N'UPRID'),(N'PROPERTY',N'PropertyName'),(N'PROPERTY',N'OwnerName'),(N'PROPERTY',N'Parcel'),(N'PROPERTY',N'PropertyTypeID'),(N'PROPERTY',N'StatusCode'),
    (N'COMPLEX',N'UPRID'),(N'COMPLEX',N'CommunityName'),(N'COMPLEX',N'PropertyTypeID'),(N'COMPLEX',N'StatusCode'),
    (N'CONDO',N'UPRID'),(N'CONDO',N'OwnerName'),(N'CONDO',N'StatusCode'),
    (N'BUILDING',N'BuildingID'),(N'BUILDING',N'UPRID'),(N'BUILDING',N'BuildingName'),(N'BUILDING',N'YearBuilt'),(N'BUILDING',N'StatusCode'),
    (N'UNIT',N'UnitID'),(N'UNIT',N'UPRID'),(N'UNIT',N'BuildingID'),(N'UNIT',N'UnitNumber'),(N'UNIT',N'StatusCode'),
    (N'REF_PROPERTYTYPE',N'PropertyTypeID'),(N'REF_PROPERTYTYPE',N'PropertyTypeName'),
    (N'UPR_ADDRESS',N'UPRID'),(N'UPR_ADDRESS',N'AddressID'),(N'UPR_ADDRESS',N'AddressRoleID'),(N'UPR_ADDRESS',N'IsPrimary'),(N'UPR_ADDRESS',N'EffectiveDate'),(N'UPR_ADDRESS',N'EndDate'),
    (N'ADDRESS',N'AddressID'),(N'ADDRESS',N'StreetNumber'),(N'ADDRESS',N'StreetDirection'),(N'ADDRESS',N'StreetName'),(N'ADDRESS',N'StreetType'),(N'ADDRESS',N'StreetSuffix'),(N'ADDRESS',N'City'),(N'ADDRESS',N'State'),(N'ADDRESS',N'ZipCode'),(N'ADDRESS',N'XCoordinate'),(N'ADDRESS',N'YCoordinate'),
    (N'REF_ADDRESSROLE',N'AddressRoleID'),(N'REF_ADDRESSROLE',N'AddressRoleCode'),(N'REF_ADDRESSROLE',N'Description'),
    (N'UPR_CONTACT',N'UPRID'),(N'UPR_CONTACT',N'ContactID'),(N'UPR_CONTACT',N'RoleTypeID'),(N'UPR_CONTACT',N'EffectiveDate'),(N'UPR_CONTACT',N'EndDate'),
    (N'CONTACT',N'ContactID'),(N'CONTACT',N'FirstName'),(N'CONTACT',N'MiddleName'),(N'CONTACT',N'LastName'),(N'CONTACT',N'OrganizationName'),(N'CONTACT',N'Phone'),(N'CONTACT',N'Email'),(N'CONTACT',N'StatusCode'),
    (N'REF_ROLETYPE',N'RoleTypeID'),(N'REF_ROLETYPE',N'RoleTypeCode'),(N'REF_ROLETYPE',N'Description'),
    (N'EXTERNAL_IDENTIFIER_XREF',N'UPRID'),(N'EXTERNAL_IDENTIFIER_XREF',N'SourceSystem'),(N'EXTERNAL_IDENTIFIER_XREF',N'IdentifierType'),(N'EXTERNAL_IDENTIFIER_XREF',N'IdentifierValue'),(N'EXTERNAL_IDENTIFIER_XREF',N'CreatedDate'),
    (N'UPRSTATUSHISTORY',N'UPRID'),(N'UPRSTATUSHISTORY',N'UPRStatusHistoryID'),(N'UPRSTATUSHISTORY',N'OldStatusCode'),(N'UPRSTATUSHISTORY',N'NewStatusCode'),(N'UPRSTATUSHISTORY',N'ChangeReason'),(N'UPRSTATUSHISTORY',N'ChangeSource'),(N'UPRSTATUSHISTORY',N'ChangedBy'),(N'UPRSTATUSHISTORY',N'ChangedDate');
IF EXISTS(SELECT 1 FROM @Required r WHERE COL_LENGTH(N'dbo.'+QUOTENAME(r.TableName),r.ColumnName) IS NULL)
BEGIN
    SELECT N'Missing required demo column' AS Finding,r.TableName,r.ColumnName
    FROM @Required r WHERE COL_LENGTH(N'dbo.'+QUOTENAME(r.TableName),r.ColumnName) IS NULL;
    THROW 50001,'Demo schema differs from the supplied UPR model. Send the missing-column results; no business data was changed.',1;
END;

DECLARE @DemoSql NVARCHAR(MAX)=N'
/* Mode SOURCES does not label an unknown source as a program or infer statuses. */
IF @Mode=''SOURCES''
BEGIN
    SELECT N''Available identifier mappings'' AS Section,SourceSystem,IdentifierType,
        COUNT_BIG(*) AS IdentifierLinks,COUNT_BIG(DISTINCT UPRID) AS LinkedUPRs
    FROM dbo.EXTERNAL_IDENTIFIER_XREF
    GROUP BY SourceSystem,IdentifierType ORDER BY SourceSystem,IdentifierType;
    SELECT AddressRoleCode,Description FROM dbo.REF_ADDRESSROLE ORDER BY AddressRoleCode;
    SELECT Description AS EntityType FROM dbo.REF_ENTITYTYPE ORDER BY Description;
    SELECT N''Choose the source/type pair confirmed for your search category. An identifier link does not establish license, case or program status.'' AS Guidance;
    RETURN;
END;

IF @Mode=''SEARCH''
BEGIN
    IF @SearchBy IS NULL OR @SearchBy NOT IN
       (''ADDRESS'',''ACCOUNT'',''PARCEL'',''OWNER'',''UNIT'',''UPRID'',''MPDU'',''MULTIFAMILY_LOANS'',''CASE'',''LICENSE'',''EXTERNAL'')
        THROW 50001,''Choose a supported search criterion from the demo controls.'',1;
    IF @SearchValue IS NULL AND @SearchBy NOT IN (''MPDU'',''MULTIFAMILY_LOANS'')
        THROW 50001,''Enter a search value. Only program searches may omit the value to list loaded links for the chosen source/type.'',1;
    IF @SearchBy=''UPRID'' AND TRY_CONVERT(BIGINT,@SearchValue) IS NULL
        THROW 50001,''UPRID must be an integer.'',1;
    IF @SearchBy IN (''MPDU'',''MULTIFAMILY_LOANS'',''CASE'',''LICENSE'',''EXTERNAL'')
       AND (@SourceSystem IS NULL OR @IdentifierType IS NULL)
    BEGIN
        SELECT N''Source mapping required'' AS Section,@SearchBy AS SearchCategory,
            N''Run SOURCES and set both SourceSystem and IdentifierType to the confirmed pair. No source names are guessed.'' AS Guidance;
        RETURN;
    END;
    IF @AddressRole IS NOT NULL AND NOT EXISTS
        (SELECT 1 FROM dbo.REF_ADDRESSROLE WHERE AddressRoleCode=@AddressRole)
        THROW 50001,''Address role not found. Run SOURCES to see available codes.'',1;
    IF @EntityType IS NOT NULL AND NOT EXISTS
        (SELECT 1 FROM dbo.REF_ENTITYTYPE WHERE Description=@EntityType)
        THROW 50001,''Entity type not found. Run SOURCES to see available values.'',1;
    IF @SearchBy IN (''MPDU'',''MULTIFAMILY_LOANS'',''CASE'',''LICENSE'',''EXTERNAL'') AND NOT EXISTS
        (SELECT 1 FROM dbo.EXTERNAL_IDENTIFIER_XREF WHERE SourceSystem=@SourceSystem AND IdentifierType=@IdentifierType)
    BEGIN
        SELECT N''Source mapping unavailable'' AS Section,@SourceSystem AS SourceSystem,@IdentifierType AS IdentifierType,
            N''No links for this source/type are loaded. This does not mean that the source system has no records.'' AS Guidance;
        RETURN;
    END;
    /* The same limited street-token normalization used by the existing search.
       No fuzzy or inferred identity match is used in the demo. */
    DECLARE @Needle NVARCHAR(600)=UPPER(@SearchValue),@Account NVARCHAR(300)=@SearchValue;
    IF @SearchBy=''ACCOUNT'' AND LEN(@Account)<8 AND @Account NOT LIKE N''%[^0-9]%''
        SET @Account=RIGHT(N''00000000''+@Account,8);
    CREATE TABLE #SearchAddress(UPRID BIGINT,AddressID BIGINT,DisplayAddress NVARCHAR(600),
        SearchAddress NVARCHAR(600),AddressRole NVARCHAR(30),IsPrimary BIT);
    INSERT #SearchAddress
    SELECT ua.UPRID,a.AddressID,
        LTRIM(RTRIM(CONCAT(a.StreetNumber,N'' '',a.StreetDirection,N'' '',a.StreetName,N'' '',a.StreetType,N'' '',a.StreetSuffix,
            N'' '',a.City,N'' '',a.State,N'' '',a.ZipCode))),NULL,ar.AddressRoleCode,ua.IsPrimary
    FROM dbo.UPR_ADDRESS ua JOIN dbo.ADDRESS a ON a.AddressID=ua.AddressID
    JOIN dbo.REF_ADDRESSROLE ar ON ar.AddressRoleID=ua.AddressRoleID
    WHERE (ua.EffectiveDate IS NULL OR ua.EffectiveDate<=@AsOfDate)
      AND (ua.EndDate IS NULL OR ua.EndDate>=@AsOfDate)
      AND (@AddressRole IS NULL OR ar.AddressRoleCode=@AddressRole);
    UPDATE #SearchAddress SET SearchAddress=UPPER(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(DisplayAddress,
        N''.'',N''''),N'','',N'' ''),NCHAR(9),N'' ''),NCHAR(13),N'' ''),NCHAR(10),N'' ''));
    SET @Needle=REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@Needle,N''.'',N''''),N'','',N'' ''),NCHAR(9),N'' ''),NCHAR(13),N'' ''),NCHAR(10),N'' '');
    WHILE EXISTS(SELECT 1 FROM #SearchAddress WHERE CHARINDEX(N''  '',SearchAddress)>0)
        UPDATE #SearchAddress SET SearchAddress=REPLACE(SearchAddress,N''  '',N'' '') WHERE CHARINDEX(N''  '',SearchAddress)>0;
    WHILE CHARINDEX(N''  '',@Needle)>0 SET @Needle=REPLACE(@Needle,N''  '',N'' '');
    UPDATE #SearchAddress SET SearchAddress=N'' ''+LTRIM(RTRIM(SearchAddress))+N'' '';
    SET @Needle=N'' ''+LTRIM(RTRIM(@Needle))+N'' '';
    UPDATE #SearchAddress SET SearchAddress=REPLACE(SearchAddress,N'' STREET '',N'' ST '');
    SET @Needle=REPLACE(@Needle,N'' STREET '',N'' ST '');
    UPDATE #SearchAddress SET SearchAddress=REPLACE(SearchAddress,N'' AVENUE '',N'' AVE '');
    SET @Needle=REPLACE(@Needle,N'' AVENUE '',N'' AVE '');
    UPDATE #SearchAddress SET SearchAddress=REPLACE(SearchAddress,N'' ROAD '',N'' RD '');
    SET @Needle=REPLACE(@Needle,N'' ROAD '',N'' RD '');
    UPDATE #SearchAddress SET SearchAddress=REPLACE(SearchAddress,N'' LANE '',N'' LN '');
    SET @Needle=REPLACE(@Needle,N'' LANE '',N'' LN '');
    UPDATE #SearchAddress SET SearchAddress=REPLACE(SearchAddress,N'' COURT '',N'' CT '');
    SET @Needle=REPLACE(@Needle,N'' COURT '',N'' CT '');
    UPDATE #SearchAddress SET SearchAddress=REPLACE(SearchAddress,N'' DRIVE '',N'' DR '');
    SET @Needle=REPLACE(@Needle,N'' DRIVE '',N'' DR '');
    UPDATE #SearchAddress SET SearchAddress=REPLACE(SearchAddress,N'' BOULEVARD '',N'' BLVD '');
    SET @Needle=REPLACE(@Needle,N'' BOULEVARD '',N'' BLVD '');
    UPDATE #SearchAddress SET SearchAddress=REPLACE(SearchAddress,N'' BLV '',N'' BLVD '');
    SET @Needle=REPLACE(@Needle,N'' BLV '',N'' BLVD '');
    UPDATE #SearchAddress SET SearchAddress=REPLACE(SearchAddress,N'' PLACE '',N'' PL '');
    SET @Needle=REPLACE(@Needle,N'' PLACE '',N'' PL '');
    UPDATE #SearchAddress SET SearchAddress=REPLACE(SearchAddress,N'' CIRCLE '',N'' CIR '');
    SET @Needle=REPLACE(@Needle,N'' CIRCLE '',N'' CIR '');
    UPDATE #SearchAddress SET SearchAddress=REPLACE(SearchAddress,N'' TERRACE '',N'' TER '');
    SET @Needle=REPLACE(@Needle,N'' TERRACE '',N'' TER '');
    UPDATE #SearchAddress SET SearchAddress=REPLACE(SearchAddress,N'' PARKWAY '',N'' PKWY '');
    SET @Needle=REPLACE(@Needle,N'' PARKWAY '',N'' PKWY '');
    UPDATE #SearchAddress SET SearchAddress=REPLACE(SearchAddress,N'' HIGHWAY '',N'' HWY '');
    SET @Needle=REPLACE(@Needle,N'' HIGHWAY '',N'' HWY '');
    UPDATE #SearchAddress SET SearchAddress=REPLACE(SearchAddress,N'' TRAIL '',N'' TRL '');
    SET @Needle=REPLACE(@Needle,N'' TRAIL '',N'' TRL '');
    UPDATE #SearchAddress SET SearchAddress=REPLACE(SearchAddress,N'' SQUARE '',N'' SQ '');
    SET @Needle=REPLACE(@Needle,N'' SQUARE '',N'' SQ '');
    UPDATE #SearchAddress SET SearchAddress=LTRIM(RTRIM(SearchAddress));
    SET @Needle=LTRIM(RTRIM(@Needle));
    IF @SearchBy=''ADDRESS'' AND NULLIF(@Needle,N'''') IS NULL
        THROW 50001,''Address search must contain address text.'',1;
    CREATE INDEX IX_DemoSearchAddress ON #SearchAddress(UPRID);
    /* MATCH_QUERY_BEGIN */
    SELECT u.UPRID INTO #Matches
    FROM dbo.UPR u JOIN dbo.REF_ENTITYTYPE et ON et.EntityTypeID=u.EntityTypeID
    WHERE (@EntityType IS NULL OR et.Description=@EntityType)
      AND (@AddressRole IS NULL OR EXISTS(SELECT 1 FROM #SearchAddress a WHERE a.UPRID=u.UPRID))
      AND (
        (@SearchBy=''UPRID'' AND u.UPRID=TRY_CONVERT(BIGINT,@SearchValue))
        OR (@SearchBy=''ACCOUNT'' AND (u.AccountNumber=@SearchValue OR u.AccountNumber=@Account
            OR EXISTS(SELECT 1 FROM dbo.EXTERNAL_IDENTIFIER_XREF x WHERE x.UPRID=u.UPRID
                AND x.IdentifierType=''ACCOUNT_NUMBER'' AND x.IdentifierValue IN (@SearchValue,@Account))))
        OR (@SearchBy=''ADDRESS'' AND EXISTS(SELECT 1 FROM #SearchAddress a WHERE a.UPRID=u.UPRID AND CHARINDEX(@Needle,a.SearchAddress)>0))
        OR (@SearchBy=''PARCEL'' AND (
            EXISTS(SELECT 1 FROM dbo.PROPERTY p WHERE p.UPRID=u.UPRID AND p.Parcel=@SearchValue)
            OR EXISTS(SELECT 1 FROM dbo.EXTERNAL_IDENTIFIER_XREF x WHERE x.UPRID=u.UPRID
                AND x.IdentifierType IN (''PARCEL'',''PARCEL_ID'') AND x.IdentifierValue=@SearchValue)))
        OR (@SearchBy=''OWNER'' AND (
            EXISTS(SELECT 1 FROM dbo.PROPERTY p WHERE p.UPRID=u.UPRID AND CHARINDEX(@SearchValue,p.OwnerName)>0)
            OR EXISTS(SELECT 1 FROM dbo.CONDO c WHERE c.UPRID=u.UPRID AND CHARINDEX(@SearchValue,c.OwnerName)>0)
            OR EXISTS(SELECT 1 FROM dbo.UPR_CONTACT uc JOIN dbo.CONTACT c ON c.ContactID=uc.ContactID
                JOIN dbo.REF_ROLETYPE r ON r.RoleTypeID=uc.RoleTypeID
                WHERE uc.UPRID=u.UPRID AND r.RoleTypeCode=''OWNER'' AND c.StatusCode=''ACTIVE''
                  AND (uc.EffectiveDate IS NULL OR uc.EffectiveDate<=@AsOfDate) AND (uc.EndDate IS NULL OR uc.EndDate>=@AsOfDate)
                  AND (CHARINDEX(@SearchValue,c.OrganizationName)>0
                    OR CHARINDEX(@SearchValue,LTRIM(RTRIM(CONCAT(c.FirstName,N'' '',c.LastName))))>0))))
        OR (@SearchBy=''UNIT'' AND EXISTS(SELECT 1 FROM dbo.UNIT un JOIN dbo.BUILDING b ON b.BuildingID=un.BuildingID
            WHERE un.UPRID=u.UPRID AND un.UnitNumber=@SearchValue AND (@BuildingUPRID IS NULL OR b.UPRID=@BuildingUPRID)))
        OR (@SearchBy IN (''MPDU'',''MULTIFAMILY_LOANS'',''CASE'',''LICENSE'',''EXTERNAL'') AND EXISTS(
            SELECT 1 FROM dbo.EXTERNAL_IDENTIFIER_XREF x WHERE x.UPRID=u.UPRID
              AND x.SourceSystem=@SourceSystem AND x.IdentifierType=@IdentifierType
              AND (@SearchValue IS NULL OR x.IdentifierValue=@SearchValue)))
      );
    /* MATCH_QUERY_END */
    CREATE UNIQUE CLUSTERED INDEX IX_DemoMatches ON #Matches(UPRID);
    DECLARE @TotalMatches BIGINT=(SELECT COUNT_BIG(*) FROM #Matches);
    SELECT N''Search summary'' AS Section,@SearchBy AS SearchCriterion,@SearchValue AS SearchValue,
        @SourceSystem AS SourceSystem,@IdentifierType AS IdentifierType,@TotalMatches AS TotalMatchingUPRs,
        @MaxMatches AS DisplayLimit,CASE WHEN @TotalMatches>@MaxMatches THEN N''Refine search: results exceed display limit''
        WHEN @TotalMatches=0 THEN N''No matching loaded UPR records'' ELSE N''Select the required UPRID and run mode 360'' END AS Guidance;
    SELECT TOP(@MaxMatches) N''Search results'' AS Section,u.UPRID,et.Description AS EntityType,
        COALESCE(p.PropertyName,cx.CommunityName,b.BuildingName,
            CASE WHEN un.UnitID IS NOT NULL THEN CONCAT(N''Unit '',COALESCE(un.UnitNumber,N''(number not recorded)'')) END,
            CONCAT(et.Description,N'' '',u.UPRID)) AS PropertyOrEntity,
        ad.DisplayAddress AS Address,ad.AddressRole,u.AccountNumber,u.ParentUPRID,u.StatusCode,
        @SearchBy AS MatchedBy,@SearchValue AS SearchedValue
    FROM #Matches m JOIN dbo.UPR u ON u.UPRID=m.UPRID JOIN dbo.REF_ENTITYTYPE et ON et.EntityTypeID=u.EntityTypeID
    LEFT JOIN dbo.PROPERTY p ON p.UPRID=u.UPRID LEFT JOIN dbo.COMPLEX cx ON cx.UPRID=u.UPRID
    LEFT JOIN dbo.BUILDING b ON b.UPRID=u.UPRID LEFT JOIN dbo.UNIT un ON un.UPRID=u.UPRID
    OUTER APPLY(SELECT TOP(1) a.DisplayAddress,a.AddressRole FROM #SearchAddress a WHERE a.UPRID=u.UPRID
        AND (@SearchBy<>''ADDRESS'' OR CHARINDEX(@Needle,a.SearchAddress)>0)
        ORDER BY CASE WHEN a.AddressRole=N''PHYSICAL'' THEN 0 ELSE 1 END,a.IsPrimary DESC,a.AddressID) ad
    ORDER BY u.UPRID;
    RETURN;
END;

IF @SelectedUPRID IS NULL OR NOT EXISTS(SELECT 1 FROM dbo.UPR WHERE UPRID=@SelectedUPRID)
    THROW 50001,''Set SelectedUPRID to a UPRID returned by search.'',1;
/* Follow real parent links. No reinterpretation or updates of UPR_CLOSURE.Level.
   Cycles and missing parents stop the demo instead of displaying a partial tree. */
CREATE TABLE #Ancestors(UPRID BIGINT NOT NULL PRIMARY KEY,DistanceFromSelected INT NOT NULL);
DECLARE @Walk BIGINT=@SelectedUPRID,@Parent BIGINT,@Distance INT=0,@RootUPRID BIGINT;
WHILE @Walk IS NOT NULL
BEGIN
    IF EXISTS(SELECT 1 FROM #Ancestors WHERE UPRID=@Walk)
        THROW 50001,''A parent cycle was found. Property context cannot be displayed reliably.'',1;
    IF @Distance>1000 THROW 50001,''Parent chain exceeds the demo depth limit.'',1;
    IF NOT EXISTS(SELECT 1 FROM dbo.UPR WHERE UPRID=@Walk)
        THROW 50001,''A parent UPR is missing. Property context cannot be displayed reliably.'',1;
    INSERT #Ancestors VALUES(@Walk,@Distance);
    SELECT @Parent=ParentUPRID FROM dbo.UPR WHERE UPRID=@Walk;
    SET @RootUPRID=@Walk;
    SET @Walk=@Parent;
    SET @Distance+=1;
END;
CREATE TABLE #Context(UPRID BIGINT NOT NULL PRIMARY KEY,ParentUPRID BIGINT NULL,RootLevel INT NOT NULL);
INSERT #Context VALUES(@RootUPRID,NULL,0);
DECLARE @Depth INT=0,@Added INT=1;
WHILE @Added>0
BEGIN
    IF @Depth>=1000 AND EXISTS(SELECT 1 FROM dbo.UPR u JOIN #Context p ON u.ParentUPRID=p.UPRID WHERE p.RootLevel=@Depth)
        THROW 50001,''Property tree exceeds the demo depth limit.'',1;
    /* CONTEXT_EXPANSION_BEGIN */
    INSERT #Context(UPRID,ParentUPRID,RootLevel)
    SELECT TOP(@MaxContextNodes+1) u.UPRID,u.ParentUPRID,p.RootLevel+1
    FROM dbo.UPR u JOIN #Context p ON u.ParentUPRID=p.UPRID
    WHERE p.RootLevel=@Depth AND NOT EXISTS(SELECT 1 FROM #Context seen WHERE seen.UPRID=u.UPRID);
    /* CONTEXT_EXPANSION_END */
    SET @Added=@@ROWCOUNT;
    IF (SELECT COUNT_BIG(*) FROM #Context)>@MaxContextNodes
        THROW 50001,''Property context exceeds MaxContextNodes; increase the explicit limit. No partial tree was returned.'',1;
    SET @Depth+=1;
END;
IF NOT EXISTS(SELECT 1 FROM #Context WHERE UPRID=@SelectedUPRID)
    THROW 50001,''The hierarchy changed during the demo. Run again against stable test data.'',1;

SELECT N''1. Property identity'' AS Section,@SelectedUPRID AS SelectedUPRID,@RootUPRID AS PropertyContextUPRID,
    et.Description AS SelectedEntityType,u.AccountNumber,u.StatusCode AS UPRStatus,
    COALESCE(p.PropertyName,cx.CommunityName,b.BuildingName,CONCAT(et.Description,N'' '',u.UPRID)) AS SelectedName,
    un.UnitNumber,pt.PropertyTypeName AS SelectedPropertyType,p.Parcel AS SelectedParcel,
    (SELECT COUNT_BIG(*) FROM #Context) AS ContextRecords,
    N''Context includes the root property and all of its buildings/units. Selection remains the requested UPRID.'' AS ContextMeaning
FROM dbo.UPR u JOIN dbo.REF_ENTITYTYPE et ON et.EntityTypeID=u.EntityTypeID
LEFT JOIN dbo.PROPERTY p ON p.UPRID=u.UPRID LEFT JOIN dbo.COMPLEX cx ON cx.UPRID=u.UPRID
LEFT JOIN dbo.BUILDING b ON b.UPRID=u.UPRID LEFT JOIN dbo.UNIT un ON un.UPRID=u.UPRID
LEFT JOIN dbo.REF_PROPERTYTYPE pt ON pt.PropertyTypeID=COALESCE(p.PropertyTypeID,cx.PropertyTypeID)
WHERE u.UPRID=@SelectedUPRID;

SELECT N''2. Hierarchy and property details'' AS Section,c.RootLevel,c.UPRID,c.ParentUPRID,
    CASE WHEN c.UPRID=@SelectedUPRID THEN N''Selected record'' WHEN c.UPRID=@RootUPRID THEN N''Property root''
         WHEN an.UPRID IS NOT NULL THEN N''Ancestor of selection'' ELSE N''Related record in property tree'' END AS Relationship,
    an.DistanceFromSelected AS AncestorDistanceFromSelected,et.Description AS EntityType,
    COALESCE(p.PropertyName,cx.CommunityName,b.BuildingName,
        CASE WHEN un.UnitID IS NOT NULL THEN CONCAT(N''Unit '',COALESCE(un.UnitNumber,N''(number not recorded)'')) END,
        CONCAT(et.Description,N'' '',c.UPRID)) AS PropertyOrEntity,
    u.AccountNumber,pt.PropertyTypeName,p.Parcel,un.UnitNumber,b.YearBuilt,
    u.StatusCode AS UPRStatus,COALESCE(p.StatusCode,cx.StatusCode,b.StatusCode,un.StatusCode,co.StatusCode) AS EntityStatus,
    u.CreatedDate,u.UpdatedDate
FROM #Context c JOIN dbo.UPR u ON u.UPRID=c.UPRID JOIN dbo.REF_ENTITYTYPE et ON et.EntityTypeID=u.EntityTypeID
LEFT JOIN #Ancestors an ON an.UPRID=c.UPRID
LEFT JOIN dbo.PROPERTY p ON p.UPRID=c.UPRID LEFT JOIN dbo.COMPLEX cx ON cx.UPRID=c.UPRID
LEFT JOIN dbo.BUILDING b ON b.UPRID=c.UPRID LEFT JOIN dbo.UNIT un ON un.UPRID=c.UPRID
LEFT JOIN dbo.CONDO co ON co.UPRID=c.UPRID
LEFT JOIN dbo.REF_PROPERTYTYPE pt ON pt.PropertyTypeID=COALESCE(p.PropertyTypeID,cx.PropertyTypeID)
ORDER BY c.RootLevel,c.ParentUPRID,c.UPRID;

SELECT N''3. Location'' AS Section,ua.UPRID,a.AddressID,ar.AddressRoleCode AS AddressRole,ua.IsPrimary,
    a.StreetNumber,a.StreetDirection,a.StreetName,a.StreetType,a.StreetSuffix,a.City,a.State,a.ZipCode,
    a.XCoordinate,a.YCoordinate,ua.EffectiveDate,ua.EndDate,
    CASE WHEN ua.EffectiveDate>@AsOfDate THEN N''Future association''
         WHEN ua.EndDate<@AsOfDate THEN N''Ended association'' ELSE N''Current association'' END AS AssociationStatus
FROM #Context c JOIN dbo.UPR_ADDRESS ua ON ua.UPRID=c.UPRID JOIN dbo.ADDRESS a ON a.AddressID=ua.AddressID
JOIN dbo.REF_ADDRESSROLE ar ON ar.AddressRoleID=ua.AddressRoleID
ORDER BY c.RootLevel,ua.UPRID,CASE WHEN ar.AddressRoleCode=N''PHYSICAL'' THEN 0 ELSE 1 END,ua.IsPrimary DESC,a.AddressID;

SELECT N''4a. Recorded owners'' AS Section,p.UPRID,N''PROPERTY'' AS OwnerSource,p.OwnerName
FROM dbo.PROPERTY p JOIN #Context c ON c.UPRID=p.UPRID WHERE p.OwnerName IS NOT NULL
UNION ALL
SELECT N''4a. Recorded owners'',co.UPRID,N''CONDO'',co.OwnerName
FROM dbo.CONDO co JOIN #Context c ON c.UPRID=co.UPRID WHERE co.OwnerName IS NOT NULL;
SELECT N''4b. Contacts and roles'' AS Section,uc.UPRID,c.ContactID,r.Description AS ContactRole,
    c.FirstName,c.MiddleName,c.LastName,c.OrganizationName,c.Phone,c.Email,c.StatusCode AS ContactStatus,
    uc.EffectiveDate,uc.EndDate,
    CASE WHEN uc.EffectiveDate>@AsOfDate THEN N''Future association''
         WHEN uc.EndDate<@AsOfDate THEN N''Ended association'' ELSE N''Current association'' END AS AssociationStatus
FROM #Context scope JOIN dbo.UPR_CONTACT uc ON uc.UPRID=scope.UPRID JOIN dbo.CONTACT c ON c.ContactID=uc.ContactID
JOIN dbo.REF_ROLETYPE r ON r.RoleTypeID=uc.RoleTypeID ORDER BY uc.UPRID,r.RoleTypeCode,c.ContactID;

SELECT N''5. External system identifiers'' AS Section,x.UPRID,x.SourceSystem,x.IdentifierType,x.IdentifierValue,x.CreatedDate,
    N''Identifier link only; source record detail and status are not supplied by this UPR table'' AS DetailAvailability
FROM #Context c JOIN dbo.EXTERNAL_IDENTIFIER_XREF x ON x.UPRID=c.UPRID
ORDER BY x.UPRID,x.SourceSystem,x.IdentifierType,x.IdentifierValue;

SELECT N''6. Regulatory information'' AS Section,N''Licenses, inspections and cases'' AS Perspective,
    N''Details unavailable: regulatory source tables are not connected to this demo. Recorded links, if loaded, appear in External system identifiers.'' AS Availability;
SELECT N''7. DHCA programs'' AS Section,N''MPDU and Multifamily Loans'' AS Perspective,
    N''Details unavailable: program source tables are not connected to this demo. An identifier link alone does not prove enrollment, eligibility or current status.'' AS Availability;

DECLARE @HistoryCount BIGINT=(SELECT COUNT_BIG(*) FROM dbo.UPRSTATUSHISTORY h JOIN #Context c ON c.UPRID=h.UPRID);
SELECT N''8. History and status'' AS Section,@HistoryCount AS AvailableStatusEvents,@MaxHistoryRows AS DisplayLimit,
    CASE WHEN @HistoryCount>@MaxHistoryRows THEN N''Most recent events shown; history exceeds display limit''
         ELSE N''All loaded status events shown; created/updated dates and current UPR statuses are in the hierarchy grid'' END AS Coverage;
SELECT TOP(@MaxHistoryRows) N''8. Status history'' AS Section,h.UPRID,h.UPRStatusHistoryID,
    h.OldStatusCode,h.NewStatusCode,h.ChangeReason,h.ChangeSource,h.ChangedBy,h.ChangedDate
FROM dbo.UPRSTATUSHISTORY h JOIN #Context c ON c.UPRID=h.UPRID
ORDER BY h.ChangedDate DESC,h.UPRStatusHistoryID DESC;
';
EXEC sys.sp_executesql @DemoSql,
 N'@Mode VARCHAR(12),@SearchBy VARCHAR(24),@SearchValue NVARCHAR(300),@SelectedUPRID BIGINT,
   @EntityType NVARCHAR(50),@AddressRole NVARCHAR(30),@BuildingUPRID BIGINT,
   @SourceSystem NVARCHAR(50),@IdentifierType NVARCHAR(50),@MaxMatches INT,
   @MaxContextNodes INT,@MaxHistoryRows INT,@AsOfDate DATE',
 @Mode,@SearchBy,@SearchValue,@SelectedUPRID,@EntityType,@AddressRole,@BuildingUPRID,
 @SourceSystem,@IdentifierType,@MaxMatches,@MaxContextNodes,@MaxHistoryRows,@AsOfDate;
