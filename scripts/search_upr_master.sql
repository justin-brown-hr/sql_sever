/* UPR-SEARCH-002. SQL Server 2016 SP1+, compatibility 130+.
   Install after install_upr_audit.sql and the updated load_upr_master.sql.
   REPORT preserves the administrative four-result-set interface/column order.
   GRID/JSON are bounded Portal contracts; the trusted API MUST supply an
   authorized UPR allowlist (JSON array of integer IDs). Never accept this list
   or disclosure flags directly from an untrusted HTTP caller.
   This file installs queries only; it grants no access and performs no load.
   See CLIENT_SEARCH_UPDATE_2026-09-24.md for modes and integration requirements. */
USE UPRXDB_TEST;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET ARITHABORT ON;
SET NUMERIC_ROUNDABORT OFF;
GO

/* Canonical text for comparison; original values remain available for display.
   Address suffix mapping is deliberately separate from personal-name matching. */
CREATE OR ALTER FUNCTION dbo.fn_UPR_SearchText (@value NVARCHAR(600), @address BIT)
RETURNS NVARCHAR(600)
AS
BEGIN
    DECLARE @s NVARCHAR(600) = UPPER(LTRIM(RTRIM(@value)));
    SET @s = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@s, N'.', N''), N',', N' '),
        NCHAR(9), N' '), NCHAR(13), N' '), NCHAR(10), N' ');
    WHILE CHARINDEX(N'  ', @s) > 0 SET @s = REPLACE(@s, N'  ', N' ');
    IF @address = 1
    BEGIN
        SET @s = N' ' + @s + N' ';
        SET @s = REPLACE(@s, N' STREET ', N' ST ');
        SET @s = REPLACE(@s, N' AVENUE ', N' AVE ');
        SET @s = REPLACE(@s, N' ROAD ', N' RD ');
        SET @s = REPLACE(@s, N' LANE ', N' LN ');
        SET @s = REPLACE(@s, N' COURT ', N' CT ');
        SET @s = REPLACE(@s, N' DRIVE ', N' DR ');
        SET @s = REPLACE(@s, N' BOULEVARD ', N' BLVD ');
        SET @s = REPLACE(@s, N' BLV ', N' BLVD ');
        SET @s = REPLACE(@s, N' PLACE ', N' PL ');
        SET @s = REPLACE(@s, N' CIRCLE ', N' CIR ');
        SET @s = REPLACE(@s, N' TERRACE ', N' TER ');
        SET @s = REPLACE(@s, N' PARKWAY ', N' PKWY ');
        SET @s = REPLACE(@s, N' HIGHWAY ', N' HWY ');
        SET @s = REPLACE(@s, N' TRAIL ', N' TRL ');
        SET @s = REPLACE(@s, N' SQUARE ', N' SQ ');
    END;
    RETURN NULLIF(LTRIM(RTRIM(@s)), N'');
END;
GO

/* Levenshtein similarity on bounded address strings, not identity confidence.
   Only invoked after exact/partial matching fails and the candidate limit passes. */
CREATE OR ALTER FUNCTION dbo.fn_UPR_SearchSimilarity (@a NVARCHAR(600), @b NVARCHAR(600))
RETURNS DECIMAL(6,5)
AS
BEGIN
    IF @a IS NULL OR @b IS NULL RETURN 0;
    /* Expand common suffixes only for fuzzy scoring. This lets STRRET/STRET
       compare to STREET without labelling the typo an exact match. */
    SET @a=LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(N' '+@a+N' ',N' ST ',N' STREET '),N' RD ',N' ROAD '),N' AVE ',N' AVENUE ')));
    SET @b=LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(N' '+@b+N' ',N' ST ',N' STREET '),N' RD ',N' ROAD '),N' AVE ',N' AVENUE ')));
    DECLARE @n INT = LEN(@a), @m INT = LEN(@b), @i INT = 1, @j INT,
        @prev NVARCHAR(601) = N'', @curr NVARCHAR(601), @cost INT, @v INT, @d INT;
    IF @n = 0 OR @m = 0 RETURN CASE WHEN @a = @b THEN 1 ELSE 0 END;
    SET @j = 0;
    WHILE @j <= @m
    BEGIN
        SET @prev += NCHAR(@j + 1);
        SET @j += 1;
    END;
    WHILE @i <= @n
    BEGIN
        SET @curr = NCHAR(@i + 1);
        SET @j = 1;
        WHILE @j <= @m
        BEGIN
            SET @cost = CASE WHEN SUBSTRING(@a,@i,1) = SUBSTRING(@b,@j,1) THEN 0 ELSE 1 END;
            SET @v = UNICODE(SUBSTRING(@prev,@j,1)) - 1 + @cost;
            SET @d = UNICODE(SUBSTRING(@prev,@j+1,1));
            IF @d < @v SET @v = @d;
            SET @d = UNICODE(SUBSTRING(@curr,@j,1));
            IF @d < @v SET @v = @d;
            SET @curr += NCHAR(@v + 1);
            SET @j += 1;
        END;
        SET @prev = @curr;
        SET @i += 1;
    END;
    RETURN CONVERT(DECIMAL(6,5), 1.0 - (UNICODE(RIGHT(@prev,1)) - 1) * 1.0 /
        CASE WHEN @n > @m THEN @n ELSE @m END);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_UPR_Search
    @AccountNumber NVARCHAR(50) = NULL,
    @ParcelID NVARCHAR(50) = NULL,
    @StreetNumber NVARCHAR(20) = NULL,
    @StreetName NVARCHAR(100) = NULL,
    @City NVARCHAR(100) = NULL,
    @ZipCode NVARCHAR(10) = NULL,
    @OwnerName NVARCHAR(100) = NULL,
    @EntityType NVARCHAR(50) = NULL,
    @PropertyTypeCode NVARCHAR(128) = NULL,
    @StatusCode NVARCHAR(20) = NULL,
    @NormalizedAddress NVARCHAR(300) = NULL,
    @SourceSystem NVARCHAR(50) = NULL,
    @ReasonForNoMatch NVARCHAR(255) = NULL,
    @IncludeReviewQOnly BIT = 0,
    @MaxRows INT = 5000,
    /* New parameters are appended to preserve existing positional callers. */
    @UPRID BIGINT = NULL,
    @IdentifierType NVARCHAR(50) = NULL,
    @IdentifierValue NVARCHAR(150) = NULL,
    @UnitNumber NVARCHAR(50) = NULL,
    @BuildingUPRID BIGINT = NULL,
    @Address NVARCHAR(300) = NULL,
    @State NVARCHAR(2) = NULL,
    @AddressRole NVARCHAR(30) = NULL,
    @OwnerRole NVARCHAR(50) = N'OWNER',
    @MatchMode VARCHAR(10) = 'AUTO', -- AUTO: exact/normalized, partial, then fuzzy
    @EnableFuzzy BIT = 1,
    @MinScore DECIMAL(6,5) = 0.80,
    @FuzzyCandidateLimit INT = 500,
    @NormalizeParcel BIT = 0, -- opt-in source rule: remove spaces/hyphens
    @ResultMode VARCHAR(10) = 'REPORT', -- REPORT | GRID | JSON
    @PageNumber INT = 1,
    @PageSize INT = 50,
    @AuthorizedUPRIDs NVARCHAR(MAX) = NULL, -- [10025,10026]; trusted API only
    @IncludeContacts BIT = 0,
    @IncludeIdentifiers BIT = 0,
    @ResponseJson NVARCHAR(MAX) = NULL OUTPUT,
    @EmitResult BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET @ResponseJson = NULL;
    SET @ResultMode = UPPER(@ResultMode);
    SET @MatchMode = UPPER(@MatchMode);
    IF @ResultMode IS NULL OR @ResultMode NOT IN ('REPORT','GRID','JSON')
        THROW 50001, 'ResultMode must be REPORT, GRID or JSON.', 1;
    IF @MatchMode IS NULL OR @MatchMode NOT IN ('AUTO','EXACT','PARTIAL','FUZZY')
        THROW 50001, 'MatchMode must be AUTO, EXACT, PARTIAL or FUZZY.', 1;
    IF @PageNumber IS NULL OR @PageNumber < 1 OR @PageSize IS NULL OR @PageSize NOT BETWEEN 1 AND 200
        THROW 50001, 'PageNumber must be positive; PageSize must be 1..200.', 1;
    IF @MinScore IS NULL OR @MinScore < 0.5 OR @MinScore > 1
       OR @FuzzyCandidateLimit IS NULL OR @FuzzyCandidateLimit NOT BETWEEN 1 AND 1000
        THROW 50001, 'MinScore must be 0.5..1 and FuzzyCandidateLimit 1..1000.', 1;
    IF @ResultMode <> 'REPORT' AND (@IncludeReviewQOnly = 1 OR @ReasonForNoMatch IS NOT NULL)
        THROW 50001, 'Review queue filters are available only in REPORT mode.', 1;
    IF @ResultMode <> 'REPORT' AND @AuthorizedUPRIDs IS NULL
        THROW 50001, 'Portal modes require a trusted API authorized UPR allowlist.', 1;

    /* JSON scalar arrays of integer IDs; invalid entries never widen scope. */
    CREATE TABLE #Allowed (UPRID BIGINT NOT NULL PRIMARY KEY);
    IF @AuthorizedUPRIDs IS NOT NULL
    BEGIN
        IF ISJSON(@AuthorizedUPRIDs) <> 1 OR LEFT(LTRIM(@AuthorizedUPRIDs),1) <> N'['
            THROW 50001, 'AuthorizedUPRIDs must be a JSON array of integer UPRIDs.', 1;
        IF EXISTS (SELECT 1 FROM OPENJSON(@AuthorizedUPRIDs)
            WHERE [type] <> 2 OR TRY_CONVERT(BIGINT,[value]) IS NULL)
            THROW 50001, 'AuthorizedUPRIDs contains an invalid integer UPRID.', 1;
        INSERT #Allowed SELECT DISTINCT CONVERT(BIGINT,[value]) FROM OPENJSON(@AuthorizedUPRIDs);
    END;
    ELSE INSERT #Allowed SELECT UPRID FROM dbo.UPR;

    SELECT @AccountNumber = NULLIF(LTRIM(RTRIM(@AccountNumber)),N''),
        @ParcelID = NULLIF(LTRIM(RTRIM(@ParcelID)),N''),
        @StreetNumber = NULLIF(LTRIM(RTRIM(@StreetNumber)),N''),
        @StreetName = NULLIF(LTRIM(RTRIM(@StreetName)),N''),
        @City = NULLIF(LTRIM(RTRIM(@City)),N''), @ZipCode = NULLIF(LTRIM(RTRIM(@ZipCode)),N''),
        @OwnerName = NULLIF(LTRIM(RTRIM(@OwnerName)),N''),
        @UnitNumber = NULLIF(LTRIM(RTRIM(@UnitNumber)),N''),
        @IdentifierValue = NULLIF(LTRIM(RTRIM(@IdentifierValue)),N''),
        @SourceSystem = NULLIF(LTRIM(RTRIM(@SourceSystem)),N''),
        @IdentifierType = NULLIF(LTRIM(RTRIM(@IdentifierType)),N''),
        @Address = NULLIF(LTRIM(RTRIM(@Address)),N''),
        @NormalizedAddress = NULLIF(LTRIM(RTRIM(@NormalizedAddress)),N'');
    IF @SourceSystem = N'SDAT' SET @SourceSystem = N'KDAT';
    IF @IdentifierType = N'ACCOUNT' SET @IdentifierType = N'ACCOUNT_NUMBER';
    IF @IdentifierType = N'PARCEL' SET @IdentifierType = N'PARCEL_ID';
    IF @Address IS NOT NULL AND @NormalizedAddress IS NOT NULL
        THROW 50001, 'Supply Address or NormalizedAddress, not both.', 1;
    SET @Address = COALESCE(@Address, @NormalizedAddress);
    IF @NormalizeParcel = 1 AND @SourceSystem IS NULL
        THROW 50001, 'Parcel formatting normalization requires SourceSystem.', 1;
    IF @IdentifierType IS NOT NULL AND @IdentifierValue IS NULL
        THROW 50001, 'IdentifierType requires IdentifierValue.', 1;
    IF @ResultMode <> 'REPORT' AND @OwnerName IS NOT NULL AND ISNULL(@IncludeContacts,0) = 0
        THROW 50001, 'Owner search requires contact disclosure permission from the API.', 1;
    IF @ResultMode <> 'REPORT' AND (@IdentifierValue IS NOT NULL OR @ParcelID IS NOT NULL)
       AND ISNULL(@IncludeIdentifiers,0) = 0
        THROW 50001, 'Identifier/parcel search requires identifier disclosure permission from the API.', 1;
    IF @ResultMode <> 'REPORT' AND @UPRID IS NULL AND @AccountNumber IS NULL
       AND @ParcelID IS NULL AND @IdentifierValue IS NULL AND @UnitNumber IS NULL
       AND @OwnerName IS NULL AND @Address IS NULL AND @StreetName IS NULL
        THROW 50001, 'Supply a property search input, not only filters.', 1;
    IF @UnitNumber IS NOT NULL AND @BuildingUPRID IS NULL AND @AccountNumber IS NULL
       AND @Address IS NULL AND NOT (@StreetNumber IS NOT NULL AND @StreetName IS NOT NULL)
       AND @UPRID IS NULL
        THROW 50001, 'UnitNumber requires building, account, full street address or exact UPRID context.', 1;
    IF @ResultMode <> 'REPORT' AND ((@Address IS NOT NULL AND LEN(@Address) < 3)
        OR (@StreetName IS NOT NULL AND LEN(@StreetName) < 3)
        OR (@OwnerName IS NOT NULL AND LEN(@OwnerName) < 3))
        THROW 50001, 'Address, StreetName and OwnerName searches require at least three characters.', 1;

    DECLARE @NormAccount NVARCHAR(50) = dbo.fn_UPR_NormalizeSDATAccount(@AccountNumber),
        @NormParcel NVARCHAR(50) = @ParcelID,
        @Query NVARCHAR(600) = dbo.fn_UPR_SearchText(@Address,1),
        @StreetQuery NVARCHAR(600) = dbo.fn_UPR_SearchText(@StreetName,1),
        @OwnerQuery NVARCHAR(600) = dbo.fn_UPR_SearchText(@OwnerName,0),
        @Today DATE = CONVERT(DATE,SYSUTCDATETIME()),
        @SearchID UNIQUEIDENTIFIER = NEWID(),
        @Top INT = CASE WHEN @MaxRows IS NULL OR @MaxRows < 1 THEN 2147483647 ELSE @MaxRows END;
    IF @NormalizeParcel = 1 SET @NormParcel = REPLACE(REPLACE(@ParcelID,N'-',N''),N' ',N'');
    IF @ParcelID IS NOT NULL AND @NormParcel = N''
        THROW 50001, 'ParcelID contains no searchable characters.', 1;

    /* Explicit source/type/value match evidence; all supplied search inputs AND. */
    SELECT x.* INTO #Identifiers FROM dbo.EXTERNAL_IDENTIFIER_XREF x
    JOIN #Allowed a ON a.UPRID = x.UPRID
    WHERE (@SourceSystem IS NULL OR x.SourceSystem = @SourceSystem)
      AND (@IdentifierType IS NULL OR x.IdentifierType = @IdentifierType)
      AND (@IdentifierValue IS NULL OR x.IdentifierValue = @IdentifierValue);
    CREATE INDEX IX_SearchIdentifiers ON #Identifiers(UPRID);

    SELECT u.UPRID INTO #Eligible
    FROM dbo.UPR u JOIN #Allowed permitted ON permitted.UPRID = u.UPRID
    JOIN dbo.REF_ENTITYTYPE et ON et.EntityTypeID = u.EntityTypeID
    LEFT JOIN dbo.PROPERTY p ON p.UPRID = u.UPRID
    LEFT JOIN dbo.COMPLEX cx ON cx.UPRID = u.UPRID
    LEFT JOIN dbo.UNIT un ON un.UPRID = u.UPRID
    LEFT JOIN dbo.BUILDING ub ON ub.BuildingID = un.BuildingID
    LEFT JOIN dbo.CONDO co ON co.UPRID = u.UPRID
    LEFT JOIN dbo.UPR_CONDO_LEGACY old ON old.CondoID = co.CondoID AND old.UPRID = u.UPRID
    OUTER APPLY (SELECT TOP (1) h.ParcelID FROM dbo.UPRSTATUSHISTORY h
        WHERE co.CondoID IS NOT NULL AND h.UPRID = u.UPRID AND h.ChangeSource = N'HIER_LOAD'
        ORDER BY h.ChangedDate DESC,h.UPRStatusHistoryID DESC) hist
    WHERE @IncludeReviewQOnly = 0
      AND (@UPRID IS NULL OR u.UPRID = @UPRID)
      AND (@EntityType IS NULL OR et.Description = @EntityType)
      AND (@StatusCode IS NULL OR u.StatusCode = @StatusCode)
      AND (@PropertyTypeCode IS NULL OR EXISTS (SELECT 1 FROM dbo.REF_PROPERTYTYPE pt
          WHERE pt.PropertyTypeCode = @PropertyTypeCode AND pt.PropertyTypeID IN (p.PropertyTypeID,cx.PropertyTypeID)))
      AND (@NormAccount IS NULL OR
          (@SourceSystem IS NULL AND u.AccountNumber IN (@AccountNumber,@NormAccount)) OR EXISTS (
          SELECT 1 FROM dbo.EXTERNAL_IDENTIFIER_XREF x WHERE x.UPRID = u.UPRID
          AND x.IdentifierType = N'ACCOUNT_NUMBER' AND x.IdentifierValue IN (@AccountNumber,@NormAccount)
          AND (@SourceSystem IS NULL OR x.SourceSystem = @SourceSystem))
          OR (@UnitNumber IS NOT NULL AND EXISTS (
              SELECT 1 FROM dbo.UPR_CLOSURE cl
              JOIN dbo.UPR parent ON parent.UPRID=cl.UPRAncestry
              JOIN #Allowed permittedParent ON permittedParent.UPRID=parent.UPRID
              WHERE cl.DescendantUPRID=u.UPRID AND
                ((@SourceSystem IS NULL AND parent.AccountNumber IN(@AccountNumber,@NormAccount)) OR EXISTS (
                    SELECT 1 FROM dbo.EXTERNAL_IDENTIFIER_XREF ax WHERE ax.UPRID=parent.UPRID
                    AND ax.IdentifierType=N'ACCOUNT_NUMBER' AND ax.IdentifierValue IN(@AccountNumber,@NormAccount)
                    AND (@SourceSystem IS NULL OR ax.SourceSystem=@SourceSystem))))))
      AND (@IdentifierValue IS NULL OR EXISTS (SELECT 1 FROM #Identifiers x WHERE x.UPRID = u.UPRID))
      AND (@SourceSystem IS NULL OR EXISTS (SELECT 1 FROM dbo.EXTERNAL_IDENTIFIER_XREF x
          WHERE x.UPRID = u.UPRID AND x.SourceSystem = @SourceSystem)
          OR (@UnitNumber IS NOT NULL AND @NormAccount IS NOT NULL AND EXISTS (
              SELECT 1 FROM dbo.UPR_CLOSURE cl JOIN #Allowed pa ON pa.UPRID=cl.UPRAncestry
              JOIN dbo.EXTERNAL_IDENTIFIER_XREF ax ON ax.UPRID=cl.UPRAncestry
              WHERE cl.DescendantUPRID=u.UPRID AND ax.SourceSystem=@SourceSystem
                AND ax.IdentifierType=N'ACCOUNT_NUMBER' AND ax.IdentifierValue IN(@AccountNumber,@NormAccount))))
      AND (@UnitNumber IS NULL OR un.UnitNumber = @UnitNumber)
      AND (@BuildingUPRID IS NULL OR ub.UPRID = @BuildingUPRID)
      AND (@ParcelID IS NULL OR EXISTS (
          SELECT 1 FROM dbo.EXTERNAL_IDENTIFIER_XREF x WHERE x.UPRID = u.UPRID
          AND x.IdentifierType IN (N'PARCEL_ID',N'PARCEL')
          AND (@SourceSystem IS NULL OR x.SourceSystem = @SourceSystem)
          AND CASE WHEN @NormalizeParcel = 1 THEN REPLACE(REPLACE(x.IdentifierValue,N'-',N''),N' ',N'')
              ELSE x.IdentifierValue END = @NormParcel)
          /* Old retained parcels have no reliable source qualifier. Do not guess. */
          OR (@SourceSystem IS NULL AND (p.Parcel = @ParcelID OR
              CASE WHEN old.CondoID IS NOT NULL THEN old.Parcel ELSE hist.ParcelID END = @ParcelID)));
    CREATE UNIQUE CLUSTERED INDEX IX_SearchEligible ON #Eligible(UPRID);

    /* Match all current OWNER relationships, not an arbitrary contact/display name. */
    SELECT DISTINCT e.UPRID, ct.ContactID, r.RoleTypeCode,
        ct.FirstName, ct.LastName, ct.OrganizationName,
        MatchRank = CONVERT(INT, CASE WHEN @OwnerName IN
            (ct.OrganizationName, LTRIM(RTRIM(CONCAT(ct.FirstName,N' ',ct.LastName)))) THEN 0
            WHEN @OwnerQuery IN (n.OrgName,n.PersonName) THEN 1 ELSE 2 END)
    INTO #Owners
    FROM #Eligible e JOIN dbo.UPR_CONTACT uc ON uc.UPRID = e.UPRID
    JOIN dbo.CONTACT ct ON ct.ContactID = uc.ContactID
    JOIN dbo.REF_ROLETYPE r ON r.RoleTypeID = uc.RoleTypeID
    CROSS APPLY (SELECT dbo.fn_UPR_SearchText(ct.OrganizationName,0) AS OrgName,
        dbo.fn_UPR_SearchText(CONCAT(ct.FirstName,N' ',ct.LastName),0) AS PersonName) n
    WHERE @OwnerName IS NOT NULL AND r.RoleTypeCode = @OwnerRole AND r.IsActive = 1
      AND ct.StatusCode = 'ACTIVE'
      AND (uc.EffectiveDate IS NULL OR uc.EffectiveDate <= @Today)
      AND (uc.EndDate IS NULL OR uc.EndDate >= @Today)
      AND (@OwnerQuery IN (n.OrgName,n.PersonName) OR (@MatchMode <> 'EXACT' AND
          (CHARINDEX(@OwnerQuery,n.OrgName) > 0 OR CHARINDEX(@OwnerQuery,n.PersonName) > 0)));
    IF @OwnerName IS NOT NULL
        DELETE e FROM #Eligible e WHERE NOT EXISTS (SELECT 1 FROM #Owners o WHERE o.UPRID=e.UPRID);

    /* All directly linked addresses qualify, including secondary and mailing
       links. The loader already shares building addresses with parents/units. */
    SELECT DISTINCT e.UPRID, ua.AddressID, ua.IsPrimary, ad.NormalizedAddress,
        ad.StreetNumber,ad.StreetName,ad.StreetType,ad.City,ad.State,ad.ZipCode,
        StreetText = dbo.fn_UPR_SearchText(CONCAT(ad.StreetNumber,N' ',ad.StreetName,N' ',ad.StreetType),1),
        FullText = dbo.fn_UPR_SearchText(CONCAT(ad.StreetNumber,N' ',ad.StreetName,N' ',ad.StreetType,N' ',ad.City,N' ',ad.State,N' ',ad.ZipCode),1),
        StoredText = dbo.fn_UPR_SearchText(ad.NormalizedAddress,1),
        NameText = dbo.fn_UPR_SearchText(CONCAT(ad.StreetName,N' ',ad.StreetType),1)
    INTO #Addresses
    FROM #Eligible e JOIN dbo.UPR_ADDRESS ua ON ua.UPRID = e.UPRID
    JOIN dbo.ADDRESS ad ON ad.AddressID = ua.AddressID
    JOIN dbo.REF_ADDRESSROLE ar ON ar.AddressRoleID = ua.AddressRoleID
    WHERE (@AddressRole IS NULL OR ar.AddressRoleCode = @AddressRole)
      AND (ua.EffectiveDate IS NULL OR ua.EffectiveDate <= @Today)
      AND (ua.EndDate IS NULL OR ua.EndDate >= @Today)
      AND (@StreetNumber IS NULL OR dbo.fn_UPR_NormalizeStreetNumber(ad.StreetNumber) = dbo.fn_UPR_NormalizeStreetNumber(@StreetNumber))
      AND (@City IS NULL OR dbo.fn_UPR_SearchText(ad.City,0) = dbo.fn_UPR_SearchText(@City,0))
      AND (@State IS NULL OR ad.State = @State)
      AND (@ZipCode IS NULL OR LEFT(ad.ZipCode,LEN(@ZipCode)) = @ZipCode);

    DECLARE @HasAddress BIT = CASE WHEN @Address IS NOT NULL OR @StreetName IS NOT NULL
        OR @StreetNumber IS NOT NULL OR @City IS NOT NULL OR @State IS NOT NULL
        OR @ZipCode IS NOT NULL OR @AddressRole IS NOT NULL THEN 1 ELSE 0 END;
    CREATE TABLE #AddressMatches (UPRID BIGINT NOT NULL, AddressID BIGINT NOT NULL,
        MatchRank INT NOT NULL, MatchScore DECIMAL(6,5) NOT NULL);
    INSERT #AddressMatches
    SELECT UPRID, AddressID, CASE WHEN @Address = NormalizedAddress
        AND (@StreetName IS NULL OR @StreetName = StreetName) THEN 0 ELSE 1 END, 1
    FROM #Addresses
    WHERE (@Query IS NULL OR @Query IN (StreetText,FullText,StoredText))
      AND (@StreetQuery IS NULL OR @StreetQuery IN (NameText,dbo.fn_UPR_SearchText(StreetName,1)));

    IF @MatchMode IN ('AUTO','PARTIAL','FUZZY')
    BEGIN
        INSERT #AddressMatches
        SELECT a.UPRID,a.AddressID,2,0.90 FROM #Addresses a
        WHERE (@Query IS NULL OR CHARINDEX(@Query,a.FullText)>0 OR CHARINDEX(@Query,a.StoredText)>0)
          AND (@StreetQuery IS NULL OR CHARINDEX(@StreetQuery,a.NameText)>0)
          AND NOT EXISTS (SELECT 1 FROM #AddressMatches m WHERE m.UPRID=a.UPRID AND m.AddressID=a.AddressID);
    END;

    /* Fuzzy fallback never changes house number, city, state or ZIP filters.
       A free-form numeric house token is extracted and compared exactly. */
    IF @EnableFuzzy = 1 AND @MatchMode IN ('AUTO','FUZZY')
       AND (@Query IS NOT NULL OR @StreetQuery IS NOT NULL)
       AND NOT EXISTS (SELECT 1 FROM #AddressMatches)
    BEGIN
        DECLARE @House NVARCHAR(20) = @StreetNumber,
            @FirstToken NVARCHAR(300) = LEFT(@Query,CHARINDEX(N' ',@Query+N' ')-1),
            @FuzzyQuery NVARCHAR(600) = COALESCE(@StreetQuery,@Query);
        IF @House IS NULL AND @FirstToken LIKE N'[0-9]%'
            SET @House = LEFT(@FirstToken,20);
        IF @House IS NULL AND @City IS NULL AND @ZipCode IS NULL AND @AccountNumber IS NULL AND @BuildingUPRID IS NULL
            THROW 50001, 'Fuzzy address search requires house number, city, ZIP, account or building context.', 1;
        SELECT DISTINCT a.AddressID,a.NameText,a.StreetText,a.FullText,a.StoredText
        INTO #FuzzyPool FROM #Addresses a
        WHERE (@House IS NULL OR dbo.fn_UPR_NormalizeStreetNumber(a.StreetNumber)=dbo.fn_UPR_NormalizeStreetNumber(@House))
          AND (@Query IS NULL OR @StreetQuery IS NULL OR CHARINDEX(@Query,a.FullText)>0 OR CHARINDEX(@Query,a.StoredText)>0);
        IF (SELECT COUNT(*) FROM #FuzzyPool) > @FuzzyCandidateLimit
            THROW 50001, 'Too many fuzzy address candidates. Add city, ZIP or account context.', 1;
        SELECT p.AddressID,Score=MAX(dbo.fn_UPR_SearchSimilarity(@FuzzyQuery,CONVERT(NVARCHAR(600),v.CompareText)))
        INTO #FuzzyScores FROM #FuzzyPool p
        CROSS APPLY (VALUES
            (CASE WHEN @StreetQuery IS NOT NULL THEN p.NameText ELSE p.StreetText END),
            (CASE WHEN @StreetQuery IS NULL THEN p.FullText END),
            (CASE WHEN @StreetQuery IS NULL THEN p.StoredText END)) v(CompareText)
        WHERE v.CompareText IS NOT NULL GROUP BY p.AddressID;
        INSERT #AddressMatches
        SELECT a.UPRID,a.AddressID,3,f.Score FROM #Addresses a JOIN #FuzzyScores f ON f.AddressID=a.AddressID
        WHERE f.Score>=@MinScore;
    END;

    /* One candidate per UPR; choose matched address before display address. */
    SELECT e.UPRID, u.ParentUPRID, et.Description AS EntityType, u.AccountNumber,u.StatusCode,
        p.PropertyName,pt.PropertyTypeCode,p.OwnerName AS PropertyOwner,cx.CommunityName,
        b.BuildingName,b.YearBuilt,un.UnitNumber,
        ad.NormalizedAddress,ad.StreetNumber,ad.StreetName,ad.City,ad.ZipCode,u.CreatedDate,
        AddressID=ad.AddressID,
        BuildingUPRID=CASE WHEN EXISTS(SELECT 1 FROM #Allowed al WHERE al.UPRID=ub.UPRID) THEN ub.UPRID END,
        PropertyUPRID=anc.UPRID,
        MatchRank=CASE WHEN ISNULL(own.MatchRank,0)>CASE WHEN @HasAddress=1 THEN ISNULL(am.MatchRank,0) ELSE 0 END
            THEN own.MatchRank ELSE CASE WHEN @HasAddress=1 THEN ISNULL(am.MatchRank,0) ELSE 0 END END,
        MatchScore=CONVERT(DECIMAL(6,5),CASE WHEN own.MatchRank=2 AND ISNULL(am.MatchScore,1)>0.90 THEN 0.90 ELSE ISNULL(am.MatchScore,1) END)
    INTO #Matches
    FROM #Eligible e JOIN dbo.UPR u ON u.UPRID=e.UPRID
    JOIN dbo.REF_ENTITYTYPE et ON et.EntityTypeID=u.EntityTypeID
    LEFT JOIN dbo.PROPERTY p ON p.UPRID=u.UPRID
    LEFT JOIN dbo.REF_PROPERTYTYPE pt ON pt.PropertyTypeID=p.PropertyTypeID
    LEFT JOIN dbo.COMPLEX cx ON cx.UPRID=u.UPRID
    LEFT JOIN dbo.BUILDING b ON b.UPRID=u.UPRID
    LEFT JOIN dbo.UNIT un ON un.UPRID=u.UPRID
    LEFT JOIN dbo.BUILDING ub ON ub.BuildingID=un.BuildingID
    OUTER APPLY (SELECT TOP (1) m.AddressID,m.MatchRank,m.MatchScore FROM #AddressMatches m
        WHERE m.UPRID=e.UPRID AND @HasAddress=1 ORDER BY m.MatchRank,m.MatchScore DESC,m.AddressID) am
    OUTER APPLY (SELECT TOP (1) a.* FROM #Addresses a WHERE a.UPRID=e.UPRID
        AND (@HasAddress=0 OR a.AddressID=am.AddressID)
        ORDER BY CASE WHEN a.AddressID=am.AddressID THEN 0 ELSE 1 END,a.IsPrimary DESC,a.AddressID) ad
    OUTER APPLY (SELECT MIN(o.MatchRank) AS MatchRank FROM #Owners o WHERE o.UPRID=e.UPRID) own
    OUTER APPLY (SELECT TOP (1) au.UPRID FROM dbo.UPR_CLOSURE cl
        JOIN dbo.UPR au ON au.UPRID=cl.UPRAncestry JOIN #Allowed al ON al.UPRID=au.UPRID
        JOIN dbo.REF_ENTITYTYPE ae ON ae.EntityTypeID=au.EntityTypeID
        JOIN dbo.UPR_CLOSURE self ON self.UPRAncestry=au.UPRID AND self.DescendantUPRID=au.UPRID
        WHERE cl.DescendantUPRID=e.UPRID AND ae.Description IN ('Property','Complex')
        ORDER BY self.[Level] DESC,au.UPRID) anc
    WHERE @HasAddress=0 OR am.AddressID IS NOT NULL;
    /* An account normalization is still an exact identifier match, never fuzzy. */
    UPDATE #Matches SET MatchRank=1 WHERE MatchRank=0 AND @AccountNumber IS NOT NULL AND @AccountNumber<>@NormAccount
        AND ISNULL(AccountNumber,N'')<>@AccountNumber;
    UPDATE #Matches SET MatchRank=1 WHERE MatchRank=0 AND @NormalizeParcel=1 AND @NormParcel<>@ParcelID;
    CREATE UNIQUE CLUSTERED INDEX IX_SearchMatches ON #Matches(UPRID);

    IF @ResultMode = 'REPORT'
    BEGIN
        IF @IncludeReviewQOnly=0
        BEGIN
            SELECT TOP (@Top) UPRID,ParentUPRID,EntityType,AccountNumber,StatusCode,
                PropertyName,PropertyTypeCode,PropertyOwner,CommunityName,BuildingName,YearBuilt,UnitNumber,
                NormalizedAddress,StreetNumber,StreetName,City,ZipCode,CreatedDate
            FROM #Matches ORDER BY UPRID;
            SELECT TOP (@Top) x.ExternalIdentifierID,x.UPRID,m.AccountNumber,m.EntityType,
                x.SourceSystem,x.IdentifierType,x.IdentifierValue,x.CreatedDate
            FROM #Identifiers x JOIN #Matches m ON m.UPRID=x.UPRID ORDER BY x.UPRID,x.SourceSystem,x.ExternalIdentifierID;
            SELECT TOP (@Top) cl.UPRAncestry,ae.Description AS AncestorEntityType,cl.DescendantUPRID,
                de.Description AS DescendantEntityType,d.AccountNumber AS DescendantAccount
            FROM dbo.UPR_CLOSURE cl JOIN #Matches m ON m.UPRID=cl.UPRAncestry
            JOIN dbo.UPR a ON a.UPRID=cl.UPRAncestry JOIN dbo.UPR d ON d.UPRID=cl.DescendantUPRID
            JOIN #Allowed al ON al.UPRID=d.UPRID
            JOIN dbo.REF_ENTITYTYPE ae ON ae.EntityTypeID=a.EntityTypeID
            JOIN dbo.REF_ENTITYTYPE de ON de.EntityTypeID=d.EntityTypeID
            WHERE cl.UPRAncestry<>cl.DescendantUPRID ORDER BY cl.UPRAncestry,cl.DescendantUPRID;
        END;
        SELECT TOP (@Top) q.UPRMatchReviewID,q.UPRID,q.IncomingSourceSystem,q.MA_Account,
            q.MA_NormalizedIncomingAddress,q.MA_ParcelID,q.SDAT_AccountNumber,q.SDAT_NormalizedIncomingAddress,
            q.SDAT_ParcelID,q.ReasonForNoMatch,q.ReviewStatus,q.ProcessingTimestamp
        FROM dbo.UPRMATCHREVIEW_Q q
        WHERE (@IncludeReviewQOnly=1 OR EXISTS (SELECT 1 FROM #Matches m WHERE m.UPRID=q.UPRID))
          AND (@AuthorizedUPRIDs IS NULL OR EXISTS (SELECT 1 FROM #Allowed al WHERE al.UPRID=q.UPRID))
          AND (@UPRID IS NULL OR q.UPRID=@UPRID)
          AND (@NormAccount IS NULL OR q.MA_Account=@NormAccount OR q.SDAT_AccountNumber=@NormAccount)
          AND (@ParcelID IS NULL OR q.MA_ParcelID=@ParcelID OR q.SDAT_ParcelID=@ParcelID)
          AND (@SourceSystem IS NULL OR q.IncomingSourceSystem=@SourceSystem)
          AND (@ReasonForNoMatch IS NULL OR q.ReasonForNoMatch=@ReasonForNoMatch)
          AND (@Query IS NULL OR CHARINDEX(@Query,dbo.fn_UPR_SearchText(q.MA_NormalizedIncomingAddress,1))>0
               OR CHARINDEX(@Query,dbo.fn_UPR_SearchText(q.SDAT_NormalizedIncomingAddress,1))>0)
        ORDER BY q.UPRMatchReviewID;
        RETURN;
    END;

    DECLARE @Total BIGINT=(SELECT COUNT_BIG(*) FROM #Matches),
        @Offset BIGINT=(CONVERT(BIGINT,@PageNumber)-1)*@PageSize;
    SELECT m.*, MatchType=CONVERT(VARCHAR(20),CASE m.MatchRank WHEN 0 THEN 'EXACT'
        WHEN 1 THEN 'NORMALIZED_EXACT' WHEN 2 THEN 'PARTIAL' ELSE 'FUZZY' END)
    INTO #Page FROM #Matches m ORDER BY m.MatchRank,m.MatchScore DESC,m.UPRID
    OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
    SET @ResponseJson=(SELECT @SearchID AS searchId,@Total AS totalResults,@PageNumber AS pageNumber,@PageSize AS pageSize,
        JSON_QUERY((SELECT m.UPRID AS uprId,UPPER(m.EntityType) AS entityType,m.EntityType AS entityTypeDescription,
            m.MatchType AS matchType,m.MatchScore AS matchScore,m.NormalizedAddress AS [address.formatted],
            m.AccountNumber AS accountNumber,
            CASE WHEN EXISTS(SELECT 1 FROM #Allowed al WHERE al.UPRID=m.ParentUPRID) THEN m.ParentUPRID END AS parentUprId,
            m.UnitNumber AS unitNumber,m.BuildingUPRID AS buildingUprId,m.PropertyUPRID AS propertyUprId,
            JSON_QUERY(CASE WHEN @IncludeIdentifiers=1 THEN (SELECT x.SourceSystem AS sourceSystem,
                x.IdentifierType AS identifierType,x.IdentifierValue AS identifierValue
                FROM #Identifiers x WHERE x.UPRID=m.UPRID AND
                (@IdentifierValue IS NOT NULL OR (@NormAccount IS NOT NULL AND x.IdentifierType=N'ACCOUNT_NUMBER' AND x.IdentifierValue=@NormAccount)
                    OR (@ParcelID IS NOT NULL AND x.IdentifierType IN(N'PARCEL',N'PARCEL_ID') AND
                        CASE WHEN @NormalizeParcel=1 THEN REPLACE(REPLACE(x.IdentifierValue,N'-',N''),N' ',N'') ELSE x.IdentifierValue END=@NormParcel))
                ORDER BY x.SourceSystem,x.IdentifierType,x.IdentifierValue FOR JSON PATH) END) AS matchedIdentifiers,
            JSON_QUERY(CASE WHEN @IncludeContacts=1 THEN (SELECT o.ContactID AS contactId,o.FirstName AS firstName,
                o.LastName AS lastName,o.OrganizationName AS organizationName,o.RoleTypeCode AS role,
                CASE o.MatchRank WHEN 0 THEN 'EXACT' WHEN 1 THEN 'NORMALIZED_EXACT' ELSE 'PARTIAL' END AS matchType
                FROM #Owners o WHERE o.UPRID=m.UPRID ORDER BY o.ContactID,o.RoleTypeCode FOR JSON PATH) END) AS matchedContacts
            FROM #Page m ORDER BY m.MatchRank,m.MatchScore DESC,m.UPRID FOR JSON PATH)) AS results
        FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
    IF @EmitResult=1
    BEGIN
        IF @ResultMode='JSON' SELECT @ResponseJson AS ResponseJson;
        ELSE
        BEGIN
            SELECT @SearchID AS SearchID,@Total AS TotalResults,@PageNumber AS PageNumber,@PageSize AS PageSize;
            SELECT uprId,entityType,entityTypeDescription,matchType,matchScore,address,accountNumber,
                parentUprId,unitNumber,buildingUprId,propertyUprId,matchedIdentifiers,matchedContacts
            FROM OPENJSON(@ResponseJson,'$.results') WITH (
                uprId BIGINT,entityType NVARCHAR(50),entityTypeDescription NVARCHAR(50),matchType VARCHAR(20),
                matchScore DECIMAL(6,5),address NVARCHAR(MAX) AS JSON,accountNumber NVARCHAR(50),parentUprId BIGINT,
                unitNumber NVARCHAR(50),buildingUprId BIGINT,propertyUprId BIGINT,
                matchedIdentifiers NVARCHAR(MAX) AS JSON,matchedContacts NVARCHAR(MAX) AS JSON);
        END;
    END;
END;
GO

/* Selected UPR remains the anchor. 360 means its ancestors + its descendants,
   not its ancestors' other subtrees. Node authorization is applied to every
   expanded node and association; caller permissions determine section flags.
   Closure.Level keeps its established root-depth meaning. */
CREATE OR ALTER PROCEDURE dbo.usp_UPR_Property360
    @UPRID BIGINT,
    @Expand NVARCHAR(100) = N'360',
    @AuthorizedUPRIDs NVARCHAR(MAX),
    @IncludeContacts BIT = 0,
    @IncludeIdentifiers BIT = 0,
    @MaxNodes INT = 2000,
    @ResponseJson NVARCHAR(MAX) = NULL OUTPUT,
    @EmitResult BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET @ResponseJson=NULL;
    IF @UPRID IS NULL OR @MaxNodes IS NULL OR @MaxNodes NOT BETWEEN 1 AND 10000
        THROW 50001, 'UPRID is required; MaxNodes must be 1..10000.', 1;
    IF @AuthorizedUPRIDs IS NULL OR ISJSON(@AuthorizedUPRIDs)<>1
       OR LEFT(LTRIM(@AuthorizedUPRIDs),1)<>N'['
        THROW 50001, 'Property360 requires a trusted API authorized UPR allowlist.', 1;
    IF EXISTS(SELECT 1 FROM OPENJSON(@AuthorizedUPRIDs) WHERE [type]<>2 OR TRY_CONVERT(BIGINT,[value]) IS NULL)
        THROW 50001, 'AuthorizedUPRIDs contains an invalid integer UPRID.', 1;
    CREATE TABLE #DetailAllowed(UPRID BIGINT NOT NULL PRIMARY KEY);
    INSERT #DetailAllowed SELECT DISTINCT CONVERT(BIGINT,[value]) FROM OPENJSON(@AuthorizedUPRIDs);
    IF NOT EXISTS(SELECT 1 FROM dbo.UPR u JOIN #DetailAllowed a ON a.UPRID=u.UPRID WHERE u.UPRID=@UPRID)
        THROW 50004, 'Property not found or not accessible.', 1;
    SET @Expand=LOWER(REPLACE(LTRIM(RTRIM(@Expand)),N' ',N''));
    IF @Expand IS NULL OR @Expand=N'' OR LEFT(@Expand,1)=N',' OR RIGHT(@Expand,1)=N',' OR CHARINDEX(N',,',@Expand)>0
        THROW 50001, 'Specify a nonempty expansion mode.', 1;
    IF EXISTS(SELECT 1 FROM STRING_SPLIT(@Expand,N',') WHERE value NOT IN
        (N'none',N'parent',N'parents',N'children',N'descendants',N'360'))
        THROW 50001, 'Unknown expansion mode.', 1;
    IF CHARINDEX(N',',@Expand)>0 AND EXISTS(SELECT 1 FROM STRING_SPLIT(@Expand,N',') WHERE value IN(N'none',N'360'))
        THROW 50001, 'none and 360 cannot be combined with other expansion modes.', 1;
    DECLARE @Parents BIT=0,@Parent BIT=0,@Children BIT=0,@Descendants BIT=0,
        @Full BIT=CASE WHEN @Expand=N'360' THEN 1 ELSE 0 END,
        @Today DATE=CONVERT(DATE,SYSUTCDATETIME());
    IF @Full=1 OR EXISTS(SELECT 1 FROM STRING_SPLIT(@Expand,N',') WHERE value=N'parents') SET @Parents=1;
    IF EXISTS(SELECT 1 FROM STRING_SPLIT(@Expand,N',') WHERE value=N'parent') SET @Parent=1;
    IF EXISTS(SELECT 1 FROM STRING_SPLIT(@Expand,N',') WHERE value=N'children') SET @Children=1;
    IF @Full=1 OR EXISTS(SELECT 1 FROM STRING_SPLIT(@Expand,N',') WHERE value=N'descendants') SET @Descendants=1;
    CREATE TABLE #Scope(UPRID BIGINT NOT NULL PRIMARY KEY,Relation VARCHAR(12) NOT NULL);
    INSERT #Scope VALUES(@UPRID,'SELECTED');
    INSERT #Scope
    SELECT u.UPRID,'PARENT' FROM dbo.UPR u JOIN #DetailAllowed a ON a.UPRID=u.UPRID
    WHERE u.UPRID<>@UPRID AND ((@Parent=1 AND u.UPRID=(SELECT ParentUPRID FROM dbo.UPR WHERE UPRID=@UPRID))
        OR (@Parents=1 AND EXISTS(SELECT 1 FROM dbo.UPR_CLOSURE c WHERE c.UPRAncestry=u.UPRID AND c.DescendantUPRID=@UPRID)));
    INSERT #Scope
    SELECT u.UPRID,'CHILD' FROM dbo.UPR u JOIN #DetailAllowed a ON a.UPRID=u.UPRID
    WHERE NOT EXISTS(SELECT 1 FROM #Scope s WHERE s.UPRID=u.UPRID)
      AND ((@Children=1 AND u.ParentUPRID=@UPRID) OR (@Descendants=1 AND EXISTS(
          SELECT 1 FROM dbo.UPR_CLOSURE c WHERE c.UPRAncestry=@UPRID AND c.DescendantUPRID=u.UPRID)));
    /* A Condo Unit can link to a Building that is not its ancestor. Include
       that authorized entity as related context without changing the tree. */
    IF @Full=1
        INSERT #Scope
        SELECT b.UPRID,'BUILDING' FROM dbo.UNIT un JOIN dbo.BUILDING b ON b.BuildingID=un.BuildingID
        JOIN #DetailAllowed a ON a.UPRID=b.UPRID
        WHERE un.UPRID=@UPRID AND NOT EXISTS(SELECT 1 FROM #Scope s WHERE s.UPRID=b.UPRID);
    IF (SELECT COUNT(*) FROM #Scope)>@MaxNodes
        THROW 50001, 'Expansion exceeds MaxNodes. Request a narrower expansion.', 1;

    SELECT u.UPRID,u.EntityTypeID,UPPER(et.Description) AS EntityType,u.AccountNumber,u.StatusCode,
        ParentUPRID=CASE WHEN EXISTS(SELECT 1 FROM #DetailAllowed a WHERE a.UPRID=u.ParentUPRID) THEN u.ParentUPRID END,
        s.Relation,c.[Level] AS RootLevel
    INTO #Nodes FROM #Scope s JOIN dbo.UPR u ON u.UPRID=s.UPRID
    JOIN dbo.REF_ENTITYTYPE et ON et.EntityTypeID=u.EntityTypeID
    LEFT JOIN dbo.UPR_CLOSURE c ON c.UPRAncestry=u.UPRID AND c.DescendantUPRID=u.UPRID;
    SET @ResponseJson=(SELECT
        JSON_QUERY((SELECT n.UPRID AS uprId,n.EntityTypeID AS entityTypeId,n.EntityType AS entityType,
            n.ParentUPRID AS parentUprId,n.AccountNumber AS accountNumber,n.StatusCode AS statusCode
            FROM #Nodes n WHERE n.UPRID=@UPRID FOR JSON PATH,INCLUDE_NULL_VALUES,WITHOUT_ARRAY_WRAPPER)) AS upr,
        JSON_QUERY(CASE WHEN @Expand<>N'none' THEN (SELECT
            JSON_QUERY((SELECT n.UPRID AS uprId,n.ParentUPRID AS parentUprId,n.EntityType AS entityType,n.RootLevel AS rootLevel
                FROM #Nodes n WHERE n.Relation='PARENT' ORDER BY n.RootLevel,n.UPRID FOR JSON PATH)) AS parents,
            JSON_QUERY((SELECT n.UPRID AS uprId,n.ParentUPRID AS parentUprId,n.EntityType AS entityType,n.RootLevel AS rootLevel
                FROM #Nodes n WHERE n.Relation='CHILD' ORDER BY n.RootLevel,n.UPRID FOR JSON PATH)) AS children
            FOR JSON PATH,WITHOUT_ARRAY_WRAPPER) END) AS hierarchy,
        JSON_QUERY(CASE WHEN @Full=1 THEN (SELECT ua.UPRID AS uprId,a.AddressID AS addressId,
            r.AddressRoleCode AS role,ua.IsPrimary AS isPrimary,a.NormalizedAddress AS formatted,
            a.StreetNumber AS streetNumber,a.StreetName AS streetName,a.StreetType AS streetType,
            a.City AS city,a.State AS state,a.ZipCode AS postalCode
            FROM #Scope s JOIN dbo.UPR_ADDRESS ua ON ua.UPRID=s.UPRID
            JOIN dbo.ADDRESS a ON a.AddressID=ua.AddressID JOIN dbo.REF_ADDRESSROLE r ON r.AddressRoleID=ua.AddressRoleID
            WHERE (ua.EffectiveDate IS NULL OR ua.EffectiveDate<=@Today) AND (ua.EndDate IS NULL OR ua.EndDate>=@Today)
            ORDER BY ua.UPRID,ua.IsPrimary DESC,ua.UPRAddressID FOR JSON PATH) END) AS addresses,
        JSON_QUERY(CASE WHEN @Full=1 AND @IncludeIdentifiers=1 THEN (SELECT x.UPRID AS uprId,
            x.SourceSystem AS sourceSystem,x.IdentifierType AS identifierType,x.IdentifierValue AS identifierValue
            FROM #Scope s JOIN dbo.EXTERNAL_IDENTIFIER_XREF x ON x.UPRID=s.UPRID
            ORDER BY x.UPRID,x.SourceSystem,x.IdentifierType,x.IdentifierValue FOR JSON PATH) END) AS externalIdentifiers,
        JSON_QUERY(CASE WHEN @Full=1 AND @IncludeContacts=1 THEN (SELECT uc.UPRID AS uprId,c.ContactID AS contactId,
            r.RoleTypeCode AS role,c.FirstName AS firstName,c.MiddleName AS middleName,c.LastName AS lastName,
            c.OrganizationName AS organizationName,c.Phone AS phone,c.Email AS email
            FROM #Scope s JOIN dbo.UPR_CONTACT uc ON uc.UPRID=s.UPRID
            JOIN dbo.CONTACT c ON c.ContactID=uc.ContactID JOIN dbo.REF_ROLETYPE r ON r.RoleTypeID=uc.RoleTypeID
            WHERE c.StatusCode='ACTIVE' AND (uc.EffectiveDate IS NULL OR uc.EffectiveDate<=@Today)
              AND (uc.EndDate IS NULL OR uc.EndDate>=@Today)
            ORDER BY uc.UPRID,c.ContactID,r.RoleTypeCode FOR JSON PATH) END) AS contacts,
        JSON_QUERY(CASE WHEN @Full=1 THEN (SELECT p.UPRID AS uprId,p.PropertyID AS propertyId,
            p.PropertyName AS propertyName,p.PropertyTypeID AS propertyTypeId,p.StatusCode AS statusCode
            FROM #Scope s JOIN dbo.PROPERTY p ON p.UPRID=s.UPRID ORDER BY p.UPRID FOR JSON PATH) END) AS properties,
        JSON_QUERY(CASE WHEN @Full=1 THEN (SELECT c.UPRID AS uprId,c.ComplexID AS complexId,
            c.CommunityName AS communityName,c.PropertyTypeID AS propertyTypeId,c.StatusCode AS statusCode
            FROM #Scope s JOIN dbo.COMPLEX c ON c.UPRID=s.UPRID ORDER BY c.UPRID FOR JSON PATH) END) AS complexes,
        JSON_QUERY(CASE WHEN @Full=1 THEN (SELECT b.UPRID AS uprId,b.BuildingID AS buildingId,
            b.BuildingName AS buildingName,b.YearBuilt AS yearBuilt,b.StatusCode AS statusCode
            FROM #Scope s JOIN dbo.BUILDING b ON b.UPRID=s.UPRID ORDER BY b.UPRID FOR JSON PATH) END) AS buildings,
        JSON_QUERY(CASE WHEN @Full=1 THEN (SELECT un.UPRID AS uprId,un.UnitID AS unitId,un.UnitNumber AS unitNumber,
            CASE WHEN EXISTS(SELECT 1 FROM #DetailAllowed al WHERE al.UPRID=b.UPRID) THEN b.UPRID END AS buildingUprId,
            un.UnitTypeCode AS unitTypeCode,un.FloorNumber AS floorNumber,un.BedroomCount AS bedroomCount,
            un.BathroomCount AS bathroomCount,un.HasLegalIdentity AS hasLegalIdentity,un.StatusCode AS statusCode
            FROM #Scope s JOIN dbo.UNIT un ON un.UPRID=s.UPRID JOIN dbo.BUILDING b ON b.BuildingID=un.BuildingID
            ORDER BY un.UPRID FOR JSON PATH) END) AS units,
        JSON_QUERY(CASE WHEN @Full=1 THEN (SELECT a.UPRID AS uprId,a.ADUID AS aduId,a.UnitNumber AS unitNumber,a.StatusCode AS statusCode
            FROM #Scope s JOIN dbo.ADU a ON a.UPRID=s.UPRID ORDER BY a.UPRID FOR JSON PATH) END) AS adus,
        JSON_QUERY(CASE WHEN @Full=1 THEN (SELECT c.UPRID AS uprId,c.CondoID AS condoId,c.StatusCode AS statusCode
            FROM #Scope s JOIN dbo.CONDO c ON c.UPRID=s.UPRID ORDER BY c.UPRID FOR JSON PATH) END) AS condos
        FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
    IF @EmitResult=1 SELECT @ResponseJson AS ResponseJson;
END;
GO

/* Examples (replace IDs and derive authorization server-side in the API):
EXEC dbo.usp_UPR_Search @AccountNumber=N'00272531'; -- administrative report
EXEC dbo.usp_UPR_Search @UPRID=10025,@ResultMode='JSON',@AuthorizedUPRIDs=N'[10025]';
EXEC dbo.usp_UPR_Search @IdentifierValue=N'123456789',@IdentifierType=N'ACCOUNT',
    @SourceSystem=N'SDAT',@ResultMode='JSON',@IncludeIdentifiers=1,@AuthorizedUPRIDs=N'[10025]';
EXEC dbo.usp_UPR_Search @UnitNumber=N'102',@BuildingUPRID=10025,
    @ResultMode='GRID',@AuthorizedUPRIDs=N'[10025,10026]';
EXEC dbo.usp_UPR_Property360 @UPRID=10026,@Expand=N'parents,children',
    @AuthorizedUPRIDs=N'[10025,10026]';
*/
