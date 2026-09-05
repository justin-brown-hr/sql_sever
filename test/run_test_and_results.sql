/*
================================================================================
  UPR HIERARCHICAL LOAD - VALIDATION REPORT
  Run AFTER scripts/load_upr_master.sql

  Works with REAL DATA or test data (no expectations tied to sample accounts).
  Run in SSMS: File -> Open -> this file -> Execute (F5)

  Steps for a real-data test:
    1. Load YOUR data into dbo.MAIncomingTableX1 and dbo.SDATIncomingTableX1
    2. Run ddl/03_new_upr_schema.sql (first time only)
    3. Run scripts/load_upr_master.sql
    4. Run THIS script to review results

  EDIT the USE line if your database name differs.
================================================================================
*/
USE UPRXDB_TEST;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

/* Optional: set an account number to see the full hierarchy for one property */
DECLARE @SampleAccount NVARCHAR(50) = NULL;   -- e.g. N'00272531'

PRINT N'============================================================';
PRINT N'  UPR HIERARCHICAL LOAD - VALIDATION REPORT';
PRINT N'  Database: ' + DB_NAME() + N'   Run: ' + CONVERT(NVARCHAR(30), SYSDATETIME(), 120);
PRINT N'============================================================';

/* ============================================================
   SECTION 1 - RECORD COUNTS
   ============================================================ */
PRINT N'';
PRINT N'--- Section 1: Record counts ---';

SELECT
    MA_Incoming    = (SELECT COUNT(*) FROM dbo.MAIncomingTableX1),
    SDAT_Incoming  = (SELECT COUNT(*) FROM dbo.SDATIncomingTableX1),
    UPR_Total      = (SELECT COUNT(*) FROM dbo.UPR),
    Complexes      = (SELECT COUNT(*) FROM dbo.COMPLEX),
    Properties     = (SELECT COUNT(*) FROM dbo.PROPERTY),
    Condos         = (SELECT COUNT(*) FROM dbo.CONDO),
    Buildings      = (SELECT COUNT(*) FROM dbo.BUILDING),
    Units          = (SELECT COUNT(*) FROM dbo.UNIT),
    Addresses      = (SELECT COUNT(*) FROM dbo.ADDRESS),
    Contacts       = (SELECT COUNT(*) FROM dbo.CONTACT),
    XREF_Links     = (SELECT COUNT(*) FROM dbo.EXTERNAL_IDENTIFIER_XREF),
    Review_Queue   = (SELECT COUNT(*) FROM dbo.UPRMATCHREVIEW_Q),
    StatusHistory  = (SELECT COUNT(*) FROM dbo.UPRSTATUSHISTORY),
    AuditLog_Rows  = (SELECT COUNT(*) FROM dbo.AuditLog);

/* ============================================================
   SECTION 2 - RECORDS BY ENTITY AND PROPERTY TYPE
   ============================================================ */
PRINT N'';
PRINT N'--- Section 2: UPR records by entity type ---';

SELECT e.Description AS EntityType, COUNT(*) AS Records
FROM dbo.UPR u
INNER JOIN dbo.REF_ENTITYTYPE e ON e.EntityTypeID = u.EntityTypeID
GROUP BY e.Description
ORDER BY COUNT(*) DESC;

PRINT N'';
PRINT N'--- Section 2b: Properties by property type ---';

SELECT t.PropertyTypeCode, t.PropertyTypeName, COUNT(*) AS Properties
FROM dbo.PROPERTY p
INNER JOIN dbo.REF_PROPERTYTYPE t ON t.PropertyTypeID = p.PropertyTypeID
GROUP BY t.PropertyTypeCode, t.PropertyTypeName
ORDER BY COUNT(*) DESC;

/* ============================================================
   SECTION 3 - REVIEW QUEUE BY REASON
   ============================================================ */
PRINT N'';
PRINT N'--- Section 3: Review queue by reason ---';

SELECT ReasonForNoMatch, IncomingSourceSystem, COUNT(*) AS Records
FROM dbo.UPRMATCHREVIEW_Q
GROUP BY ReasonForNoMatch, IncomingSourceSystem
ORDER BY COUNT(*) DESC;

/* ============================================================
   SECTION 4 - VALIDATION CHECKS (PASS / FAIL / N/A)
   ============================================================ */
PRINT N'';
PRINT N'--- Section 4: Validation checks ---';

IF OBJECT_ID('tempdb..#V') IS NOT NULL DROP TABLE #V;
CREATE TABLE #V (Seq INT IDENTITY(1,1), Result VARCHAR(4), CheckName VARCHAR(120), Detail VARCHAR(200));

DECLARE @n INT, @m INT;

/* incoming data present */
SELECT @n = COUNT(*) FROM dbo.MAIncomingTableX1;
INSERT #V VALUES (CASE WHEN @n > 0 THEN 'PASS' ELSE 'N/A' END,
    'Incoming MasterAddress data loaded', CONVERT(VARCHAR(20), @n) + ' rows');
SELECT @n = COUNT(*) FROM dbo.SDATIncomingTableX1;
INSERT #V VALUES (CASE WHEN @n > 0 THEN 'PASS' ELSE 'N/A' END,
    'Incoming SDAT data loaded', CONVERT(VARCHAR(20), @n) + ' rows');

/* UPR records created */
SELECT @n = COUNT(*) FROM dbo.UPR;
INSERT #V VALUES (CASE WHEN @n > 0 THEN 'PASS' ELSE 'FAIL' END,
    'UPR records created', CONVERT(VARCHAR(20), @n) + ' rows');

/* every UPR resolves to exactly one entity row */
SELECT @n = COUNT(*)
FROM dbo.UPR u
LEFT JOIN dbo.COMPLEX  c ON c.UPRID = u.UPRID
LEFT JOIN dbo.PROPERTY p ON p.UPRID = u.UPRID
LEFT JOIN dbo.CONDO    d ON d.UPRID = u.UPRID
LEFT JOIN dbo.BUILDING b ON b.UPRID = u.UPRID
LEFT JOIN dbo.UNIT     n ON n.UPRID = u.UPRID
WHERE COALESCE(c.ComplexID, p.PropertyID, d.CondoID, b.BuildingID, n.UnitID) IS NULL;
INSERT #V VALUES (CASE WHEN @n = 0 THEN 'PASS' ELSE 'FAIL' END,
    'Every UPR has its entity record', CONVERT(VARCHAR(20), @n) + ' orphan UPR rows');

/* entity type consistent with entity table */
SELECT @n = COUNT(*)
FROM dbo.UPR u
INNER JOIN dbo.REF_ENTITYTYPE e ON e.EntityTypeID = u.EntityTypeID
WHERE (e.Description = 'Complex'  AND NOT EXISTS (SELECT 1 FROM dbo.COMPLEX  x WHERE x.UPRID = u.UPRID))
   OR (e.Description = 'Property' AND NOT EXISTS (SELECT 1 FROM dbo.PROPERTY x WHERE x.UPRID = u.UPRID))
   OR (e.Description = 'Condo'    AND NOT EXISTS (SELECT 1 FROM dbo.CONDO    x WHERE x.UPRID = u.UPRID))
   OR (e.Description = 'Building' AND NOT EXISTS (SELECT 1 FROM dbo.BUILDING x WHERE x.UPRID = u.UPRID))
   OR (e.Description = 'Unit'     AND NOT EXISTS (SELECT 1 FROM dbo.UNIT     x WHERE x.UPRID = u.UPRID));
INSERT #V VALUES (CASE WHEN @n = 0 THEN 'PASS' ELSE 'FAIL' END,
    'Entity type matches entity table', CONVERT(VARCHAR(20), @n) + ' mismatches');

/* every building has one primary address */
SELECT @n = COUNT(*) FROM dbo.BUILDING b
WHERE NOT EXISTS (SELECT 1 FROM dbo.UPR_ADDRESS ua WHERE ua.UPRID = b.UPRID AND ua.IsPrimary = 1);
INSERT #V VALUES (CASE WHEN @n = 0 THEN 'PASS' ELSE 'FAIL' END,
    'Every Building has a primary Address', CONVERT(VARCHAR(20), @n) + ' without address');

/* every parent (Complex/Property/Condo) has a contact */
SELECT @n = COUNT(*)
FROM dbo.UPR u
INNER JOIN dbo.REF_ENTITYTYPE e ON e.EntityTypeID = u.EntityTypeID
WHERE e.Description IN ('Complex', 'Property', 'Condo')
  AND NOT EXISTS (SELECT 1 FROM dbo.UPR_CONTACT uc WHERE uc.UPRID = u.UPRID);
INSERT #V VALUES (CASE WHEN @n = 0 THEN 'PASS' ELSE 'FAIL' END,
    'Every parent record has a Contact', CONVERT(VARCHAR(20), @n) + ' without contact');

/* every unit belongs to a building */
SELECT @n = COUNT(*) FROM dbo.UNIT WHERE BuildingID IS NULL;
INSERT #V VALUES (CASE WHEN @n = 0 THEN 'PASS' ELSE 'FAIL' END,
    'Every Unit has a Building', CONVERT(VARCHAR(20), @n) + ' units without building');

/* unit parent must be Building or Condo */
SELECT @n = COUNT(*)
FROM dbo.UNIT n
INNER JOIN dbo.UPR u ON u.UPRID = n.UPRID
LEFT JOIN dbo.UPR pu ON pu.UPRID = u.ParentUPRID
LEFT JOIN dbo.REF_ENTITYTYPE pe ON pe.EntityTypeID = pu.EntityTypeID
WHERE pe.Description NOT IN ('Building', 'Condo') OR pe.Description IS NULL;
INSERT #V VALUES (CASE WHEN @n = 0 THEN 'PASS' ELSE 'FAIL' END,
    'Unit parents are Building or Condo', CONVERT(VARCHAR(20), @n) + ' bad parents');

/* no duplicate building address under the same parent */
SELECT @n = COUNT(*)
FROM (
    SELECT u.ParentUPRID, a.NormalizedAddress
    FROM dbo.BUILDING b
    INNER JOIN dbo.UPR u ON u.UPRID = b.UPRID
    INNER JOIN dbo.UPR_ADDRESS ua ON ua.UPRID = b.UPRID AND ua.IsPrimary = 1
    INNER JOIN dbo.ADDRESS a ON a.AddressID = ua.AddressID
    GROUP BY u.ParentUPRID, a.NormalizedAddress
    HAVING COUNT(*) > 1
) d;
INSERT #V VALUES (CASE WHEN @n = 0 THEN 'PASS' ELSE 'FAIL' END,
    'No duplicate building per parent+address', CONVERT(VARCHAR(20), @n) + ' duplicates');

/* each source record linked to exactly one UPR */
SELECT @n = COUNT(*), @m = COUNT(DISTINCT CONCAT(SourceSystem, '|', IdentifierValue))
FROM dbo.EXTERNAL_IDENTIFIER_XREF
WHERE IdentifierType = 'SOURCE_RECORD_ID';
INSERT #V VALUES (CASE WHEN @n = @m THEN 'PASS' ELSE 'FAIL' END,
    'Source records map to one UPR each', CONVERT(VARCHAR(20), @n) + ' links / '
    + CONVERT(VARCHAR(20), @m) + ' distinct');

/* closure table complete */
SELECT @n = COUNT(*) FROM dbo.UPR u
WHERE NOT EXISTS (SELECT 1 FROM dbo.UPR_CLOSURE c
                  WHERE c.AncestorUPRID = u.UPRID AND c.DescendantUPRID = u.UPRID);
SELECT @m = COUNT(*) FROM dbo.UPR u
WHERE u.ParentUPRID IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM dbo.UPR_CLOSURE c
                  WHERE c.AncestorUPRID = u.ParentUPRID AND c.DescendantUPRID = u.UPRID);
INSERT #V VALUES (CASE WHEN @n + @m = 0 THEN 'PASS' ELSE 'FAIL' END,
    'Hierarchy closure table complete', CONVERT(VARCHAR(20), @n + @m) + ' missing rows');

/* status history written per parent */
SELECT @n = COUNT(*) FROM dbo.UPR u
INNER JOIN dbo.REF_ENTITYTYPE e ON e.EntityTypeID = u.EntityTypeID
WHERE e.Description IN ('Complex', 'Property', 'Condo');
SELECT @m = COUNT(DISTINCT UPRID) FROM dbo.UPRSTATUSHISTORY;
INSERT #V VALUES (CASE WHEN @m >= @n THEN 'PASS' ELSE 'FAIL' END,
    'Status history written for parents', CONVERT(VARCHAR(20), @m) + ' of '
    + CONVERT(VARCHAR(20), @n) + ' parents');

/* review queue */
SELECT @n = COUNT(*) FROM dbo.UPRMATCHREVIEW_Q;
INSERT #V VALUES (CASE WHEN @n > 0 THEN 'PASS' ELSE 'N/A' END,
    'Review queue populated', CONVERT(VARCHAR(20), @n)
    + ' rows (N/A = nothing needed review)');

/* audit log */
SELECT @n = COUNT(*) FROM dbo.AuditLog WHERE EntityName = 'UPR_HIER_LOAD';
INSERT #V VALUES (CASE WHEN @n > 0 THEN 'PASS' ELSE 'FAIL' END,
    'Audit log written', CONVERT(VARCHAR(20), @n) + ' batch rows');

SELECT Result, CheckName, Detail FROM #V ORDER BY Seq;

SELECT Failures = SUM(CASE WHEN Result = 'FAIL' THEN 1 ELSE 0 END),
       Passes   = SUM(CASE WHEN Result = 'PASS' THEN 1 ELSE 0 END),
       NotApplicable = SUM(CASE WHEN Result = 'N/A' THEN 1 ELSE 0 END)
FROM #V;

/* ============================================================
   SECTION 5 - OPTIONAL SINGLE-ACCOUNT DRILL-DOWN
   ============================================================ */
IF @SampleAccount IS NOT NULL
BEGIN
    PRINT N'';
    PRINT N'--- Section 5: Full hierarchy for account ' + @SampleAccount + N' ---';

    SELECT
        u.UPRID,
        u.ParentUPRID,
        EntityType   = e.Description,
        u.AccountNumber,
        u.StatusCode,
        CommunityName = cx.CommunityName,
        BuildingName  = b.BuildingName,
        UnitNumber    = n.UnitNumber,
        Address       = a.NormalizedAddress,
        OwnerContact  = ct.OrganizationName
    FROM dbo.UPR root
    INNER JOIN dbo.UPR_CLOSURE cl ON cl.AncestorUPRID = root.UPRID
    INNER JOIN dbo.UPR u ON u.UPRID = cl.DescendantUPRID
    INNER JOIN dbo.REF_ENTITYTYPE e ON e.EntityTypeID = u.EntityTypeID
    LEFT JOIN dbo.COMPLEX cx ON cx.UPRID = u.UPRID
    LEFT JOIN dbo.BUILDING b ON b.UPRID = u.UPRID
    LEFT JOIN dbo.UNIT n ON n.UPRID = u.UPRID
    LEFT JOIN dbo.UPR_ADDRESS ua ON ua.UPRID = u.UPRID AND ua.IsPrimary = 1
    LEFT JOIN dbo.ADDRESS a ON a.AddressID = ua.AddressID
    LEFT JOIN dbo.UPR_CONTACT uc ON uc.UPRID = u.UPRID
    LEFT JOIN dbo.CONTACT ct ON ct.ContactID = uc.ContactID
    WHERE root.AccountNumber = @SampleAccount
      AND root.ParentUPRID IS NULL
    ORDER BY cl.AncestorUPRID, u.ParentUPRID, u.UPRID;
END;

PRINT N'';
PRINT N'VALIDATION REPORT COMPLETE';
GO
