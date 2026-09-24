/* Behavioral UPR-SEARCH-002 tests. Run after loader + search installation in a
   DISPOSABLE test DB. Fixtures and their audit events are rolled back. */
USE UPRXDB_TEST;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET ARITHABORT ON;
SET NUMERIC_ROUNDABORT OFF;
SET XACT_ABORT OFF;
GO
BEGIN TRANSACTION;
BEGIN TRY
    DECLARE @P INT=(SELECT EntityTypeID FROM dbo.REF_ENTITYTYPE WHERE Description='Property'),
        @C INT=(SELECT EntityTypeID FROM dbo.REF_ENTITYTYPE WHERE Description='Condo'),
        @B INT=(SELECT EntityTypeID FROM dbo.REF_ENTITYTYPE WHERE Description='Building'),
        @U INT=(SELECT EntityTypeID FROM dbo.REF_ENTITYTYPE WHERE Description='Unit'),
        @PT INT=(SELECT TOP(1) PropertyTypeID FROM dbo.REF_PROPERTYTYPE ORDER BY PropertyTypeID),
        @AR INT=(SELECT TOP(1) AddressRoleID FROM dbo.REF_ADDRESSROLE ORDER BY AddressRoleID),
        @CT INT=(SELECT TOP(1) ContactTypeID FROM dbo.REF_CONTACTTYPE ORDER BY ContactTypeID),
        @Owner INT=(SELECT RoleTypeID FROM dbo.REF_ROLETYPE WHERE RoleTypeCode='OWNER'),
        @Other INT,@R1 BIGINT,@R2 BIGINT,@B1 BIGINT,@B2 BIGINT,@BT1 BIGINT,@BT2 BIGINT,
        @U1 BIGINT,@U2 BIGINT,@A1 BIGINT,@A2 BIGINT,@Contact BIGINT,
        @Allowed NVARCHAR(MAX),@Json NVARCHAR(MAX),@Caught BIT;
    INSERT dbo.REF_ROLETYPE(RoleTypeCode,Description) VALUES('SEARCH_TEST_NON_OWNER','Search test non-owner');
    SET @Other=SCOPE_IDENTITY();
    INSERT dbo.UPR(EntityTypeID,AccountNumber) VALUES(@P,'123456789'); SET @R1=SCOPE_IDENTITY();
    INSERT dbo.PROPERTY(UPRID,PropertyTypeID,Parcel) VALUES(@R1,@PT,'P-123');
    INSERT dbo.UPR(EntityTypeID,AccountNumber) VALUES(@C,'23456789'); SET @R2=SCOPE_IDENTITY();
    INSERT dbo.CONDO(UPRID) VALUES(@R2);
    INSERT dbo.UPR(EntityTypeID,ParentUPRID) VALUES(@B,@R1); SET @B1=SCOPE_IDENTITY();
    INSERT dbo.BUILDING(UPRID) VALUES(@B1); SET @BT1=SCOPE_IDENTITY();
    INSERT dbo.UPR(EntityTypeID,ParentUPRID) VALUES(@B,@R2); SET @B2=SCOPE_IDENTITY();
    INSERT dbo.BUILDING(UPRID) VALUES(@B2); SET @BT2=SCOPE_IDENTITY();
    INSERT dbo.UPR(EntityTypeID,ParentUPRID) VALUES(@U,@B1); SET @U1=SCOPE_IDENTITY();
    INSERT dbo.UNIT(UPRID,BuildingID,UnitNumber) VALUES(@U1,@BT1,'101');
    /* Condo Unit's immediate parent differs from its linked Building. */
    INSERT dbo.UPR(EntityTypeID,ParentUPRID) VALUES(@U,@R2); SET @U2=SCOPE_IDENTITY();
    INSERT dbo.UNIT(UPRID,BuildingID,UnitNumber) VALUES(@U2,@BT2,'101');
    DECLARE @Nodes TABLE(UPRID BIGINT PRIMARY KEY,ParentUPRID BIGINT,[Level] INT);
    INSERT @Nodes VALUES(@R1,NULL,0),(@R2,NULL,0),(@B1,@R1,1),(@B2,@R2,1),(@U1,@B1,2),(@U2,@R2,1);
    ;WITH Paths AS (
        SELECT UPRAncestry=UPRID,DescendantUPRID=UPRID,[Level] FROM @Nodes
        UNION ALL
        SELECT p.UPRAncestry,n.UPRID,n.[Level] FROM Paths p JOIN @Nodes n ON n.ParentUPRID=p.DescendantUPRID
    )
    INSERT dbo.UPR_CLOSURE(UPRAncestry,DescendantUPRID,[Level]) SELECT * FROM Paths;
    SELECT @Allowed=N'['+STUFF((SELECT N','+CONVERT(NVARCHAR(20),UPRID) FROM @Nodes ORDER BY UPRID FOR XML PATH('')),1,1,N'')+N']';
    INSERT dbo.ADDRESS(StreetNumber,StreetName,StreetType,City,ZipCode,NormalizedAddress)
        VALUES('123','MAIN','ST','ROCKVILLE','20850','123 MAIN ST ROCKVILLE 20850'); SET @A1=SCOPE_IDENTITY();
    INSERT dbo.ADDRESS(StreetNumber,StreetName,StreetType,City,ZipCode,NormalizedAddress)
        VALUES('456','OAK','RD','ROCKVILLE','20850','456 OAK RD ROCKVILLE 20850'); SET @A2=SCOPE_IDENTITY();
    INSERT dbo.UPR_ADDRESS(UPRID,AddressID,AddressRoleID,IsPrimary)
        VALUES(@R1,@A1,@AR,1),(@R1,@A2,@AR,0),(@B1,@A1,@AR,1),(@U1,@A1,@AR,1),(@R2,@A1,@AR,1);
    INSERT dbo.CONTACT(ContactTypeID,FirstName,LastName) VALUES(@CT,'John','Smith'); SET @Contact=SCOPE_IDENTITY();
    INSERT dbo.UPR_CONTACT(UPRID,ContactID,RoleTypeID) VALUES(@R1,@Contact,@Owner),(@U1,@Contact,@Owner),(@R2,@Contact,@Other);
    INSERT dbo.EXTERNAL_IDENTIFIER_XREF(UPRID,SourceSystem,IdentifierType,IdentifierValue) VALUES
        (@R1,'KDAT','ACCOUNT_NUMBER','123456789'),(@R2,'KDAT','ACCOUNT_NUMBER','23456789'),
        (@R1,'KDAT','PARCEL_ID','P-123'),(@R2,'GIS','PARCEL_ID','P-123'),
        (@R1,'KDAT','SOURCE_RECORD_ID','SEARCH-SHARED'),(@R2,'GIS','SOURCE_RECORD_ID','SEARCH-SHARED');

    IF dbo.fn_UPR_NormalizeSDATAccount('123-456-789')<>'123456789'
       OR dbo.fn_UPR_NormalizeSDATAccount('255115')<>'00255115'
       OR dbo.fn_UPR_NormalizeSDATAccount('123456789012')<>'123456789012'
        THROW 51000,'Account normalization lost digits or failed formatting normalization.',1;
    EXEC dbo.usp_UPR_Search @UPRID=@R1,@ResultMode='JSON',@AuthorizedUPRIDs=@Allowed,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF JSON_VALUE(@Json,'$.totalResults')<>'1' OR JSON_VALUE(@Json,'$.results[0].matchType')<>'EXACT'
        THROW 51000,'UPRID lookup must be exact.',1;
    EXEC dbo.usp_UPR_Search @UPRID=-98765,@ResultMode='JSON',@AuthorizedUPRIDs=@Allowed,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF JSON_VALUE(@Json,'$.totalResults')<>'0' OR JSON_QUERY(@Json,'$.results')<>N'[]'
        THROW 51000,'Unknown UPRID must return an empty result.',1;
    EXEC dbo.usp_UPR_Search @AccountNumber=N'123-456-789',@ResultMode='JSON',@AuthorizedUPRIDs=@Allowed,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF JSON_VALUE(@Json,'$.totalResults')<>'1' OR TRY_CONVERT(BIGINT,JSON_VALUE(@Json,'$.results[0].uprId'))<>@R1
        THROW 51000,'Long account resolved to the truncated account.',1;
    EXEC dbo.usp_UPR_Search @IdentifierValue=N'SEARCH-SHARED',@IncludeIdentifiers=1,@ResultMode='JSON',@AuthorizedUPRIDs=@Allowed,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF JSON_VALUE(@Json,'$.totalResults')<>'2' OR JSON_VALUE(@Json,'$.results[0].matchedIdentifiers[0].sourceSystem') IS NULL
        THROW 51000,'Cross-source identifier ambiguity/provenance was lost.',1;
    EXEC dbo.usp_UPR_Search @IdentifierValue=N'SEARCH-SHARED',@SourceSystem=N'SDAT',@IncludeIdentifiers=1,@ResultMode='JSON',@AuthorizedUPRIDs=@Allowed,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF JSON_VALUE(@Json,'$.totalResults')<>'1' OR TRY_CONVERT(BIGINT,JSON_VALUE(@Json,'$.results[0].uprId'))<>@R1
        THROW 51000,'Source-scoped external lookup failed.',1;
    DECLARE @UPRText NVARCHAR(150)=CONVERT(NVARCHAR(150),@R1);
    EXEC dbo.usp_UPR_Search @IdentifierValue=@UPRText,@IncludeIdentifiers=1,@ResultMode='JSON',@AuthorizedUPRIDs=@Allowed,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF JSON_VALUE(@Json,'$.totalResults')<>'0' THROW 51000,'External ID was interpreted as UPRID.',1;
    EXEC dbo.usp_UPR_Search @ParcelID=N'P123',@NormalizeParcel=1,@SourceSystem=N'SDAT',@IncludeIdentifiers=1,@ResultMode='JSON',@AuthorizedUPRIDs=@Allowed,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF JSON_VALUE(@Json,'$.totalResults')<>'1' THROW 51000,'Source-normalized parcel lookup failed.',1;
    EXEC dbo.usp_UPR_Search @AccountNumber=N'123456789',@ParcelID=N'WRONG',@IncludeIdentifiers=1,@ResultMode='JSON',@AuthorizedUPRIDs=@Allowed,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF JSON_VALUE(@Json,'$.totalResults')<>'0' THROW 51000,'Negative parcel search returned an account-only match.',1;
    EXEC dbo.usp_UPR_Search @Address=N'456 Oak Road.',@MatchMode='EXACT',@ResultMode='JSON',@AuthorizedUPRIDs=@Allowed,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF JSON_VALUE(@Json,'$.totalResults')<>'1' OR TRY_CONVERT(BIGINT,JSON_VALUE(@Json,'$.results[0].uprId'))<>@R1
       OR JSON_VALUE(@Json,'$.results[0].address.formatted')<>'456 OAK RD ROCKVILLE 20850'
        THROW 51000,'Secondary address or normalized suffix did not match.',1;
    EXEC dbo.usp_UPR_Search @Address=N'123 Mian St',@ResultMode='JSON',@AuthorizedUPRIDs=@Allowed,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF JSON_VALUE(@Json,'$.totalResults')<>'4' OR JSON_VALUE(@Json,'$.results[0].matchType')<>'FUZZY'
        THROW 51000,'Fuzzy transposition failed or results were not deduplicated.',1;
    EXEC dbo.usp_UPR_Search @Address=N'123 Main Strret',@ResultMode='JSON',@AuthorizedUPRIDs=@Allowed,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF JSON_VALUE(@Json,'$.totalResults')<>'4' OR JSON_VALUE(@Json,'$.results[0].matchType')<>'FUZZY'
        THROW 51000,'Fuzzy street-suffix typo failed.',1;
    EXEC dbo.usp_UPR_Search @Address=N'124 Mian St',@ResultMode='JSON',@AuthorizedUPRIDs=@Allowed,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF JSON_VALUE(@Json,'$.totalResults')<>'0' THROW 51000,'Fuzzy search changed the house number.',1;
    EXEC dbo.usp_UPR_Search @OwnerName=N'John Smith',@IncludeContacts=1,@ResultMode='JSON',@AuthorizedUPRIDs=@Allowed,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF JSON_VALUE(@Json,'$.totalResults')<>'2' OR JSON_VALUE(@Json,'$.results[0].matchedContacts[0].role')<>'OWNER'
        THROW 51000,'Personal-name owner search included a non-owner or lost contact evidence.',1;
    EXEC dbo.usp_UPR_Search @UnitNumber=N'101',@BuildingUPRID=@B2,@ResultMode='JSON',@AuthorizedUPRIDs=@Allowed,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF JSON_VALUE(@Json,'$.totalResults')<>'1' OR TRY_CONVERT(BIGINT,JSON_VALUE(@Json,'$.results[0].uprId'))<>@U2
       OR TRY_CONVERT(BIGINT,JSON_VALUE(@Json,'$.results[0].buildingUprId'))<>@B2
       OR TRY_CONVERT(BIGINT,JSON_VALUE(@Json,'$.results[0].parentUprId'))<>@R2
        THROW 51000,'Condo unit building context changed the authoritative parent.',1;
    EXEC dbo.usp_UPR_Search @UnitNumber=N'101',@AccountNumber=N'123456789',@SourceSystem=N'SDAT',@ResultMode='JSON',@AuthorizedUPRIDs=@Allowed,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF JSON_VALUE(@Json,'$.totalResults')<>'1' OR TRY_CONVERT(BIGINT,JSON_VALUE(@Json,'$.results[0].uprId'))<>@U1
        THROW 51000,'Account + unit did not resolve through the authorized ancestor.',1;
    EXEC dbo.usp_UPR_Search @Address=N'123 Main',@PageSize=1,@PageNumber=2,@ResultMode='JSON',@AuthorizedUPRIDs=@Allowed,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF JSON_VALUE(@Json,'$.totalResults')<>'4' OR (SELECT COUNT(*) FROM OPENJSON(@Json,'$.results'))<>1
        THROW 51000,'Pagination lost total count or page size.',1;
    EXEC dbo.usp_UPR_Search @Address=N'123 Main',@PageSize=1,@PageNumber=100,@ResultMode='JSON',@AuthorizedUPRIDs=@Allowed,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF JSON_VALUE(@Json,'$.totalResults')<>'4' OR JSON_QUERY(@Json,'$.results')<>N'[]'
        THROW 51000,'Out-of-range page lost total count.',1;
    EXEC dbo.usp_UPR_Search @UPRID=@R1,@ResultMode='JSON',@AuthorizedUPRIDs=N'[]',@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF JSON_VALUE(@Json,'$.totalResults')<>'0' THROW 51000,'Unauthorized UPR leaked into results/counts.',1;
    SET @Caught=0;
    BEGIN TRY
        EXEC dbo.usp_UPR_Search @UnitNumber=N'101',@ResultMode='JSON',@AuthorizedUPRIDs=@Allowed,@EmitResult=0;
    END TRY BEGIN CATCH
        IF ERROR_NUMBER()=50001 SET @Caught=1; ELSE THROW;
    END CATCH;
    IF @Caught=0 THROW 51000,'Unscoped unit number was accepted.',1;
    SET @Caught=0;
    BEGIN TRY
        EXEC dbo.usp_UPR_Search @UPRID=@R1,@ResultMode='JSON',@EmitResult=0;
    END TRY BEGIN CATCH
        IF ERROR_NUMBER()=50001 SET @Caught=1; ELSE THROW;
    END CATCH;
    IF @Caught=0 THROW 51000,'Portal call without authorization scope was accepted.',1;

    EXEC dbo.usp_UPR_Property360 @UPRID=@U1,@Expand=N'none',@AuthorizedUPRIDs=@Allowed,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF TRY_CONVERT(BIGINT,JSON_VALUE(@Json,'$.upr.uprId'))<>@U1 OR JSON_QUERY(@Json,'$.hierarchy') IS NOT NULL
        THROW 51000,'none expansion is not selected UPR only.',1;
    EXEC dbo.usp_UPR_Property360 @UPRID=@U1,@Expand=N'parent',@AuthorizedUPRIDs=@Allowed,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF (SELECT COUNT(*) FROM OPENJSON(@Json,'$.hierarchy.parents'))<>1
        THROW 51000,'parent expansion returned more than immediate parent.',1;
    EXEC dbo.usp_UPR_Property360 @UPRID=@U1,@Expand=N'parents',@AuthorizedUPRIDs=@Allowed,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF (SELECT COUNT(*) FROM OPENJSON(@Json,'$.hierarchy.parents'))<>2
        THROW 51000,'parents expansion lost ancestors or included self.',1;
    EXEC dbo.usp_UPR_Property360 @UPRID=@R1,@Expand=N'children',@AuthorizedUPRIDs=@Allowed,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF (SELECT COUNT(*) FROM OPENJSON(@Json,'$.hierarchy.children'))<>1
        THROW 51000,'children expansion included grandchildren.',1;
    EXEC dbo.usp_UPR_Property360 @UPRID=@R1,@Expand=N'descendants',@AuthorizedUPRIDs=@Allowed,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF (SELECT COUNT(*) FROM OPENJSON(@Json,'$.hierarchy.children'))<>2
        THROW 51000,'descendants expansion lost subtree or included self.',1;
    EXEC dbo.usp_UPR_Property360 @UPRID=@R1,@Expand=N'parents,children',@AuthorizedUPRIDs=@Allowed,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF (SELECT COUNT(*) FROM OPENJSON(@Json,'$.hierarchy.children'))<>1 OR JSON_QUERY(@Json,'$.hierarchy.parents')<>N'[]'
        THROW 51000,'Combined expansion failed.',1;
    EXEC dbo.usp_UPR_Property360 @UPRID=@R1,@Expand=N'360',@AuthorizedUPRIDs=@Allowed,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF JSON_QUERY(@Json,'$.contacts') IS NOT NULL OR JSON_QUERY(@Json,'$.externalIdentifiers') IS NOT NULL
       OR (SELECT COUNT(*) FROM OPENJSON(@Json,'$.units'))<>1
        THROW 51000,'360 omitted entity data or exposed a disabled section.',1;
    EXEC dbo.usp_UPR_Property360 @UPRID=@R1,@Expand=N'360',@AuthorizedUPRIDs=@Allowed,@IncludeContacts=1,@IncludeIdentifiers=1,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF (SELECT COUNT(*) FROM OPENJSON(@Json,'$.contacts'))<>2 OR JSON_QUERY(@Json,'$.externalIdentifiers')=N'[]'
        THROW 51000,'360 lost authorized contacts/identifiers.',1;
    EXEC dbo.usp_UPR_Property360 @UPRID=@U2,@Expand=N'360',@AuthorizedUPRIDs=@Allowed,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF (SELECT COUNT(*) FROM OPENJSON(@Json,'$.buildings'))<>1
       OR TRY_CONVERT(BIGINT,JSON_VALUE(@Json,'$.buildings[0].uprId'))<>@B2
       OR (SELECT COUNT(*) FROM OPENJSON(@Json,'$.hierarchy.parents'))<>1
       OR JSON_QUERY(@Json,'$.hierarchy.children')<>N'[]'
        THROW 51000,'Condo Unit 360 lost its related Building or invented a hierarchy edge.',1;
    DECLARE @UnitOnly NVARCHAR(MAX)=N'['+CONVERT(NVARCHAR(20),@U1)+N']';
    EXEC dbo.usp_UPR_Property360 @UPRID=@U1,@Expand=N'360',@AuthorizedUPRIDs=@UnitOnly,@ResponseJson=@Json OUTPUT,@EmitResult=0;
    IF JSON_VALUE(@Json,'$.upr.parentUprId') IS NOT NULL OR JSON_QUERY(@Json,'$.hierarchy.parents')<>N'[]'
       OR JSON_VALUE(@Json,'$.units[0].buildingUprId') IS NOT NULL
        THROW 51000,'Restricted expansion exposed an unauthorized parent/building.',1;
    SET @Caught=0;
    BEGIN TRY
        EXEC dbo.usp_UPR_Property360 @UPRID=@R1,@AuthorizedUPRIDs=N'[]',@EmitResult=0;
    END TRY BEGIN CATCH
        IF ERROR_NUMBER()=50004 SET @Caught=1; ELSE THROW;
    END CATCH;
    IF @Caught=0 THROW 51000,'Unauthorized detail was returned.',1;
    SET @Caught=0;
    BEGIN TRY
        EXEC dbo.usp_UPR_Property360 @UPRID=@R1,@AuthorizedUPRIDs=@Allowed,@MaxNodes=1,@EmitResult=0;
    END TRY BEGIN CATCH
        IF ERROR_NUMBER()=50001 SET @Caught=1; ELSE THROW;
    END CATCH;
    IF @Caught=0 THROW 51000,'Oversized expansion was silently truncated.',1;
    PRINT 'PASS: UPR-SEARCH-002 matching, ambiguity, pagination, authorization and expansion assertions.';
    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
