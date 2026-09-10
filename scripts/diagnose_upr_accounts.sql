/* Read-only source/destination evidence for the two client-reported accounts.
   Run on the client's database; no normalization functions are required.
   These queries do not insert, update, or manufacture source data. */
USE UPRXDB_TEST;
GO
SET NOCOUNT ON;

PRINT N'Original MasterAddress source rows';
SELECT ma.*
FROM dbo.MAIncomingTableX1 ma
WHERE RIGHT(N'00000000' + LTRIM(RTRIM(CONVERT(NVARCHAR(50), ma.Account))), 8)
    IN (N'00089876', N'01297731');

PRINT N'Original SDAT source rows (includes CondoUnit if the column exists)';
SELECT s.*
FROM dbo.SDATIncomingTableX1 s
WHERE RIGHT(N'00000000' + LTRIM(RTRIM(CONVERT(NVARCHAR(50), s.AccountNumber))), 8)
    IN (N'00089876', N'01297731');

PRINT N'Written UPR entities with direct Address and Contact links';
;WITH Tree AS (
    SELECT u.UPRID, u.ParentUPRID, RootAccount = u.AccountNumber
    FROM dbo.UPR u
    WHERE u.ParentUPRID IS NULL AND u.AccountNumber IN ('00089876', '01297731')
    UNION ALL
    SELECT u.UPRID, u.ParentUPRID, t.RootAccount
    FROM dbo.UPR u INNER JOIN Tree t ON u.ParentUPRID = t.UPRID
)
SELECT t.RootAccount, u.UPRID, u.ParentUPRID, e.Description AS EntityType,
    un.UnitNumber, BuildingID = COALESCE(b.BuildingID, un.BuildingID),
    ua.IsPrimary, a.AddressID, a.StreetNumber, a.StreetName, a.StreetType,
    a.City, a.State, a.ZipCode, a.NormalizedAddress,
    ct.ContactID, ct.OrganizationName
FROM Tree t
INNER JOIN dbo.UPR u ON u.UPRID = t.UPRID
INNER JOIN dbo.REF_ENTITYTYPE e ON e.EntityTypeID = u.EntityTypeID
LEFT JOIN dbo.UNIT un ON un.UPRID = u.UPRID
LEFT JOIN dbo.BUILDING b ON b.UPRID = u.UPRID
LEFT JOIN dbo.UPR_ADDRESS ua ON ua.UPRID = u.UPRID
LEFT JOIN dbo.ADDRESS a ON a.AddressID = ua.AddressID
LEFT JOIN dbo.UPR_CONTACT uc ON uc.UPRID = u.UPRID
LEFT JOIN dbo.CONTACT ct ON ct.ContactID = uc.ContactID
ORDER BY t.RootAccount, u.UPRID, a.AddressID, ct.ContactID
OPTION (MAXRECURSION 100);

PRINT N'Review queue entries for these source accounts';
SELECT * FROM dbo.UPRMATCHREVIEW_Q
WHERE MA_Account IN ('00089876', '01297731') OR SDAT_AccountNumber IN ('00089876', '01297731');

PRINT N'Installed audit triggers';
SELECT TableName = OBJECT_NAME(parent_id), name, is_disabled
FROM sys.triggers WHERE name LIKE N'tr_UPR_Audit[_]%'
ORDER BY TableName;
GO
