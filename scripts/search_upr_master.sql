/*
================================================================================
  UPR Hierarchical Search - dbo.usp_UPR_Search
  SQL Server 2016+

  Searches the new hierarchical model (NewUPRTABLEUSED + COMPLEX).
  NULL / omitted parameters are ignored.

  Prerequisites: ddl/03_new_upr_schema.sql + load_upr_master.sql
  Change USE database name to match your environment.
================================================================================
*/
USE UPRXDB_TEST;
GO

/* Required for filtered indexes. SSMS sets these ON, sqlcmd does not:
   without them CREATE INDEX and later INSERTs fail with error 1934. */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET ARITHABORT ON;
SET NUMERIC_ROUNDABORT OFF;
GO

CREATE OR ALTER PROCEDURE dbo.usp_UPR_Search
    @AccountNumber         NVARCHAR(50)  = NULL,
    @ParcelID              NVARCHAR(50)  = NULL,
    @StreetNumber          NVARCHAR(20)  = NULL,
    @StreetName            NVARCHAR(100) = NULL,
    @City                  NVARCHAR(100) = NULL,
    @ZipCode               NVARCHAR(10)  = NULL,
    @OwnerName             NVARCHAR(100) = NULL,
    @EntityType            NVARCHAR(50)  = NULL,   -- Complex | Property | Building | Unit | Condo | ADU
    @PropertyTypeCode      NVARCHAR(128) = NULL,
    @StatusCode            NVARCHAR(20)  = NULL,   -- ACTIVE | INACTIVE | RETIRED
    @NormalizedAddress     NVARCHAR(300) = NULL,
    @SourceSystem          NVARCHAR(50)  = NULL,   -- ADDRESS_MASTER | KDAT | eProperty | ...
    @ReasonForNoMatch      NVARCHAR(255) = NULL,
    @IncludeReviewQOnly    BIT           = 0,
    @MaxRows               INT           = 5000
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @NormAccount NVARCHAR(50) = CASE
        WHEN @AccountNumber IS NULL THEN NULL
        WHEN OBJECT_ID(N'dbo.fn_UPR_NormalizeSDATAccount', N'FN') IS NOT NULL
            THEN dbo.fn_UPR_NormalizeSDATAccount(NULLIF(LTRIM(RTRIM(@AccountNumber)), N''))
        ELSE NULLIF(LTRIM(RTRIM(@AccountNumber)), N'')
    END;

    DECLARE @Top INT = CASE
        WHEN @MaxRows IS NULL OR @MaxRows < 1 THEN 2147483647
        ELSE @MaxRows
    END;

    PRINT N'';
    PRINT N'============================================================';
    PRINT N'  UPR HIERARCHICAL SEARCH (usp_UPR_Search)';
    PRINT N'  Database: ' + DB_NAME();
    PRINT N'============================================================';

    IF @IncludeReviewQOnly = 0
    BEGIN
        PRINT N'';
        PRINT N'--- UPR hub ---';

        SELECT TOP (@Top)
            u.UPRID,
            u.ParentUPRID,
            et.Description AS EntityType,
            u.AccountNumber,
            u.StatusCode,
            p.PropertyName,
            pt.PropertyTypeCode,
            p.OwnerName AS PropertyOwner,
            c.CondoName,
            cx.CommunityName,
            b.BuildingName,
            b.YearBuilt,
            un.UnitNumber,
            a.NormalizedAddress,
            a.StreetNumber,
            a.StreetName,
            a.City,
            a.ZipCode,
            u.CreatedDate
        FROM dbo.UPR u
        INNER JOIN dbo.REF_ENTITYTYPE et ON et.EntityTypeID = u.EntityTypeID
        LEFT JOIN dbo.PROPERTY p ON p.UPRID = u.UPRID
        LEFT JOIN dbo.REF_PROPERTYTYPE pt ON pt.PropertyTypeID = p.PropertyTypeID
        LEFT JOIN dbo.CONDO c ON c.UPRID = u.UPRID
        LEFT JOIN dbo.COMPLEX cx ON cx.UPRID = u.UPRID
        LEFT JOIN dbo.BUILDING b ON b.UPRID = u.UPRID
        LEFT JOIN dbo.UNIT un ON un.UPRID = u.UPRID
        /* Addresses live on Building UPRs. Fall back through the hierarchy so
           parents (Complex/Property/Condo) show and match their first
           building's address, and units show their building's address. */
        OUTER APPLY (
            SELECT TOP 1 ad.NormalizedAddress, ad.StreetNumber, ad.StreetName,
                         ad.City, ad.ZipCode
            FROM (
                /* own address, then a descendant building's address */
                SELECT ua.AddressID, ua.IsPrimary, ua.UPRAddressID,
                       Pri = CASE WHEN ua.UPRID = u.UPRID THEN 0 ELSE 1 END
                FROM dbo.UPR_CLOSURE cl
                INNER JOIN dbo.UPR_ADDRESS ua ON ua.UPRID = cl.DescendantUPRID
                WHERE cl.AncestorUPRID = u.UPRID
                UNION ALL
                /* ancestor's address (units inherit from their building) */
                SELECT ua.AddressID, ua.IsPrimary, ua.UPRAddressID, Pri = 2
                FROM dbo.UPR_CLOSURE cl
                INNER JOIN dbo.UPR_ADDRESS ua ON ua.UPRID = cl.AncestorUPRID
                WHERE cl.DescendantUPRID = u.UPRID
                  AND cl.AncestorUPRID <> u.UPRID
            ) rel
            INNER JOIN dbo.ADDRESS ad ON ad.AddressID = rel.AddressID
            ORDER BY rel.Pri, rel.IsPrimary DESC, rel.UPRAddressID
        ) a
        WHERE (@NormAccount IS NULL OR u.AccountNumber = @NormAccount)
          AND (@StatusCode IS NULL OR u.StatusCode = @StatusCode)
          AND (@EntityType IS NULL OR et.Description = @EntityType)
          AND (@PropertyTypeCode IS NULL OR pt.PropertyTypeCode = @PropertyTypeCode
               OR EXISTS (
                    SELECT 1 FROM dbo.COMPLEX cx2
                    INNER JOIN dbo.REF_PROPERTYTYPE pt2 ON pt2.PropertyTypeID = cx2.PropertyTypeID
                    WHERE cx2.UPRID = u.UPRID AND pt2.PropertyTypeCode = @PropertyTypeCode
               ))
          AND (@ParcelID IS NULL OR p.Parcel = @ParcelID OR c.Parcel = @ParcelID)
          AND (@OwnerName IS NULL
               OR p.OwnerName LIKE N'%' + @OwnerName + N'%'
               OR c.OwnerName LIKE N'%' + @OwnerName + N'%'
               OR EXISTS (
                    SELECT 1 FROM dbo.UPR_CONTACT uc
                    INNER JOIN dbo.CONTACT ct ON ct.ContactID = uc.ContactID
                    WHERE uc.UPRID = u.UPRID
                      AND ct.OrganizationName LIKE N'%' + @OwnerName + N'%'
               ))
          AND (@StreetNumber IS NULL OR a.StreetNumber = @StreetNumber)
          AND (@StreetName IS NULL OR a.StreetName LIKE N'%' + @StreetName + N'%')
          AND (@City IS NULL OR a.City = @City)
          AND (@ZipCode IS NULL OR a.ZipCode LIKE @ZipCode + N'%')
          AND (
                @NormalizedAddress IS NULL
                OR a.NormalizedAddress LIKE N'%' + @NormalizedAddress + N'%'
              )
          AND (@SourceSystem IS NULL OR EXISTS (
                SELECT 1 FROM dbo.EXTERNAL_IDENTIFIER_XREF x
                WHERE x.UPRID = u.UPRID AND x.SourceSystem = @SourceSystem
              ))
        ORDER BY u.UPRID;

        PRINT N'';
        PRINT N'--- EXTERNAL_IDENTIFIER_XREF ---';

        SELECT TOP (@Top)
            x.ExternalIdentifierID,
            x.UPRID,
            u.AccountNumber,
            et.Description AS EntityType,
            x.SourceSystem,
            x.IdentifierType,
            x.IdentifierValue,
            x.CreatedDate
        FROM dbo.EXTERNAL_IDENTIFIER_XREF x
        INNER JOIN dbo.UPR u ON u.UPRID = x.UPRID
        INNER JOIN dbo.REF_ENTITYTYPE et ON et.EntityTypeID = u.EntityTypeID
        WHERE (@NormAccount IS NULL OR u.AccountNumber = @NormAccount)
          AND (@SourceSystem IS NULL OR x.SourceSystem = @SourceSystem)
          AND (@EntityType IS NULL OR et.Description = @EntityType)
        ORDER BY x.UPRID, x.SourceSystem;

        PRINT N'';
        PRINT N'--- Hierarchy (UPR_CLOSURE descendants for matching parents) ---';

        SELECT TOP (@Top)
            c.AncestorUPRID,
            aet.Description AS AncestorEntityType,
            c.DescendantUPRID,
            det.Description AS DescendantEntityType,
            d.AccountNumber AS DescendantAccount
        FROM dbo.UPR_CLOSURE c
        INNER JOIN dbo.UPR a ON a.UPRID = c.AncestorUPRID
        INNER JOIN dbo.UPR d ON d.UPRID = c.DescendantUPRID
        INNER JOIN dbo.REF_ENTITYTYPE aet ON aet.EntityTypeID = a.EntityTypeID
        INNER JOIN dbo.REF_ENTITYTYPE det ON det.EntityTypeID = d.EntityTypeID
        WHERE c.AncestorUPRID <> c.DescendantUPRID
          AND (@NormAccount IS NULL OR a.AccountNumber = @NormAccount OR d.AccountNumber = @NormAccount)
          AND (@EntityType IS NULL OR aet.Description = @EntityType)
        ORDER BY c.AncestorUPRID, c.DescendantUPRID;
    END;

    PRINT N'';
    PRINT N'--- Review Queue (UPRMATCHREVIEW_Q) ---';

    SELECT TOP (@Top)
        q.UPRMatchReviewID,
        q.UPRID,
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
    WHERE (@NormAccount IS NULL
           OR q.SDAT_AccountNumber = @NormAccount
           OR q.MA_Account = @NormAccount)
      AND (@ParcelID IS NULL OR q.MA_ParcelID = @ParcelID OR q.SDAT_ParcelID = @ParcelID)
      AND (@ReasonForNoMatch IS NULL OR q.ReasonForNoMatch = @ReasonForNoMatch)
      AND (
            @NormalizedAddress IS NULL
            OR q.MA_NormalizedIncomingAddress LIKE N'%' + @NormalizedAddress + N'%'
            OR q.SDAT_NormalizedIncomingAddress LIKE N'%' + @NormalizedAddress + N'%'
          )
    ORDER BY q.UPRMatchReviewID;

    PRINT N'';
    PRINT N'UPR SEARCH COMPLETE';
END;
GO

/*
Examples:

EXEC dbo.usp_UPR_Search @AccountNumber = N'00272531';
EXEC dbo.usp_UPR_Search @EntityType = N'Complex', @StreetName = N'OAK RIDGE';
EXEC dbo.usp_UPR_Search @EntityType = N'Condo', @AccountNumber = N'00048535';
EXEC dbo.usp_UPR_Search @OwnerName = N'LLC';
EXEC dbo.usp_UPR_Search @ReasonForNoMatch = N'INSUFFICIENT_DATA', @IncludeReviewQOnly = 1;

*/
GO
