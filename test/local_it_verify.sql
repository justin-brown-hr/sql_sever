/*
================================================================================
  LOCAL INTEGRATION VERIFY - hierarchy invariants + client rules
  Every check prints PASS or FAIL with the observed value.
================================================================================
*/
USE UPRXDB_TEST;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

IF OBJECT_ID('tempdb..#R') IS NOT NULL DROP TABLE #R;
CREATE TABLE #R (Seq INT IDENTITY(1,1), Result VARCHAR(4), Chk VARCHAR(120), Detail VARCHAR(200));

DECLARE @n INT, @m INT;

/* ---- 1. every UPR resolves to exactly one entity row --------------------- */
SELECT @n = COUNT(*)
FROM dbo.UPR u
LEFT JOIN dbo.COMPLEX  c ON c.UPRID = u.UPRID
LEFT JOIN dbo.PROPERTY p ON p.UPRID = u.UPRID
LEFT JOIN dbo.CONDO    d ON d.UPRID = u.UPRID
LEFT JOIN dbo.BUILDING b ON b.UPRID = u.UPRID
LEFT JOIN dbo.UNIT     n ON n.UPRID = u.UPRID
WHERE COALESCE(c.ComplexID, p.PropertyID, d.CondoID, b.BuildingID, n.UnitID) IS NULL;
INSERT #R VALUES (CASE WHEN @n = 0 THEN 'PASS' ELSE 'FAIL' END,
                  'Every UPR has an entity row', CONVERT(VARCHAR(20), @n) + ' orphan UPR rows');

/* ---- 2. EntityType matches the entity table ------------------------------ */
SELECT @n = COUNT(*)
FROM dbo.UPR u
INNER JOIN dbo.REF_ENTITYTYPE e ON e.EntityTypeID = u.EntityTypeID
WHERE (e.Description = 'Complex'  AND NOT EXISTS (SELECT 1 FROM dbo.COMPLEX  x WHERE x.UPRID = u.UPRID))
   OR (e.Description = 'Property' AND NOT EXISTS (SELECT 1 FROM dbo.PROPERTY x WHERE x.UPRID = u.UPRID))
   OR (e.Description = 'Condo'    AND NOT EXISTS (SELECT 1 FROM dbo.CONDO    x WHERE x.UPRID = u.UPRID))
   OR (e.Description = 'Building' AND NOT EXISTS (SELECT 1 FROM dbo.BUILDING x WHERE x.UPRID = u.UPRID))
   OR (e.Description = 'Unit'     AND NOT EXISTS (SELECT 1 FROM dbo.UNIT     x WHERE x.UPRID = u.UPRID));
INSERT #R VALUES (CASE WHEN @n = 0 THEN 'PASS' ELSE 'FAIL' END,
                  'EntityType matches entity table', CONVERT(VARCHAR(20), @n) + ' mismatches');

/* ---- 3. every Building UPR has exactly one primary address --------------- */
SELECT @n = COUNT(*)
FROM dbo.BUILDING b
WHERE NOT EXISTS (SELECT 1 FROM dbo.UPR_ADDRESS ua WHERE ua.UPRID = b.UPRID AND ua.IsPrimary = 1);
INSERT #R VALUES (CASE WHEN @n = 0 THEN 'PASS' ELSE 'FAIL' END,
                  'Every BUILDING has a primary ADDRESS', CONVERT(VARCHAR(20), @n) + ' without address');

/* ---- 4. every parent UPR has a contact ----------------------------------- */
SELECT @n = COUNT(*)
FROM dbo.UPR u
INNER JOIN dbo.REF_ENTITYTYPE e ON e.EntityTypeID = u.EntityTypeID
WHERE e.Description IN ('Complex', 'Property', 'Condo')
  AND NOT EXISTS (SELECT 1 FROM dbo.UPR_CONTACT uc WHERE uc.UPRID = u.UPRID);
INSERT #R VALUES (CASE WHEN @n = 0 THEN 'PASS' ELSE 'FAIL' END,
                  'Every parent UPR has a CONTACT', CONVERT(VARCHAR(20), @n) + ' without contact');

/* ---- 5. every Unit is under a Building or Condo, with a BuildingID ------- */
SELECT @n = COUNT(*) FROM dbo.UNIT WHERE BuildingID IS NULL;
INSERT #R VALUES (CASE WHEN @n = 0 THEN 'PASS' ELSE 'FAIL' END,
                  'Every UNIT has a BuildingID', CONVERT(VARCHAR(20), @n) + ' null');

SELECT @n = COUNT(*)
FROM dbo.UNIT n
INNER JOIN dbo.UPR u ON u.UPRID = n.UPRID
LEFT JOIN dbo.UPR pu ON pu.UPRID = u.ParentUPRID
LEFT JOIN dbo.REF_ENTITYTYPE pe ON pe.EntityTypeID = pu.EntityTypeID
WHERE pe.Description NOT IN ('Building', 'Condo') OR pe.Description IS NULL;
INSERT #R VALUES (CASE WHEN @n = 0 THEN 'PASS' ELSE 'FAIL' END,
                  'Unit parent is Building or Condo', CONVERT(VARCHAR(20), @n) + ' bad parents');

/* ---- 6. Complex rule: MULTI/APT + account + 2+ addresses ----------------- */
SELECT @n = COUNT(*) FROM dbo.COMPLEX;
INSERT #R VALUES (CASE WHEN @n = 2 THEN 'PASS' ELSE 'FAIL' END,
                  'Two COMPLEX parents created', CONVERT(VARCHAR(20), @n) + ' (expected 2)');

SELECT @n = COUNT(*)
FROM dbo.COMPLEX c
INNER JOIN dbo.UPR u ON u.UPRID = c.UPRID
INNER JOIN dbo.UPR b ON b.ParentUPRID = u.UPRID
WHERE u.AccountNumber = '00272531';
INSERT #R VALUES (CASE WHEN @n = 4 THEN 'PASS' ELSE 'FAIL' END,
                  'Complex 00272531 has 4 buildings', CONVERT(VARCHAR(20), @n) + ' (expected 4)');

SELECT @n = COUNT(*)
FROM dbo.BUILDING b
INNER JOIN dbo.UPR u ON u.UPRID = b.UPRID
INNER JOIN dbo.UPR p ON p.UPRID = u.ParentUPRID AND p.AccountNumber = '00272531'
WHERE b.BuildingName IS NULL;
INSERT #R VALUES (CASE WHEN @n = 4 THEN 'PASS' ELSE 'FAIL' END,
                  'Missing building names remain NULL', CONVERT(VARCHAR(20), @n) + ' (expected 4)');

/* Complex account (rule 2) must NOT also produce a Condo, even though it has
   SDAT condo-unit rows. Regression for the client 00272531 report. */
SELECT @n = COUNT(*)
FROM dbo.CONDO d
INNER JOIN dbo.UPR u ON u.UPRID = d.UPRID
WHERE EXISTS (SELECT 1 FROM dbo.UPR cx
              INNER JOIN dbo.COMPLEX c ON c.UPRID = cx.UPRID
              WHERE cx.AccountNumber = u.AccountNumber);
INSERT #R VALUES (CASE WHEN @n = 0 THEN 'PASS' ELSE 'FAIL' END,
                  'No Complex account also has a Condo', CONVERT(VARCHAR(20), @n) + ' (expected 0)');

SELECT @n = COUNT(*) FROM dbo.CONDO d
INNER JOIN dbo.UPR u ON u.UPRID = d.UPRID
WHERE u.AccountNumber = '00272531';
INSERT #R VALUES (CASE WHEN @n = 0 THEN 'PASS' ELSE 'FAIL' END,
                  'Account 00272531 has no Condo', CONVERT(VARCHAR(20), @n) + ' (expected 0)');

/* 5 units in the Complex tree: 101/102/201 from MA, N'A' for the MA row at
   104 GLENMONT with no Unit value (every MA row counted as a unit in its
   building gets a Unit record), and 301 from the SDAT CondoUnit row. */
SELECT @n = COUNT(*)
FROM dbo.UNIT n
INNER JOIN dbo.UPR u ON u.UPRID = n.UPRID
INNER JOIN dbo.UPR_CLOSURE cl ON cl.DescendantUPRID = u.UPRID
INNER JOIN dbo.UPR anc ON anc.UPRID = cl.AncestorUPRID
INNER JOIN dbo.COMPLEX c ON c.UPRID = anc.UPRID AND anc.AccountNumber = '00272531';
INSERT #R VALUES (CASE WHEN @n = 5 THEN 'PASS' ELSE 'FAIL' END,
                  'Complex 00272531 has 5 units', CONVERT(VARCHAR(20), @n) + ' (expected 5)');

SELECT @n = COUNT(*)
FROM dbo.UNIT n
INNER JOIN dbo.UPR u ON u.UPRID = n.UPRID
INNER JOIN dbo.UPR_CLOSURE cl ON cl.DescendantUPRID = u.UPRID
INNER JOIN dbo.UPR anc ON anc.UPRID = cl.AncestorUPRID
INNER JOIN dbo.COMPLEX c ON c.UPRID = anc.UPRID AND anc.AccountNumber = '00272531'
WHERE n.UnitNumber = N'N/A';
INSERT #R VALUES (CASE WHEN @n = 1 THEN 'PASS' ELSE 'FAIL' END,
                  'MA row with no Unit value recorded as N/A, not skipped', CONVERT(VARCHAR(20), @n) + ' (expected 1)');

/* The SDAT condo-unit row (KDAT 1012) resolves into the Complex, not a Condo */
SELECT @n = COUNT(*)
FROM dbo.EXTERNAL_IDENTIFIER_XREF x
INNER JOIN dbo.UPR_CLOSURE cl ON cl.DescendantUPRID = x.UPRID
INNER JOIN dbo.UPR anc ON anc.UPRID = cl.AncestorUPRID
INNER JOIN dbo.COMPLEX c ON c.UPRID = anc.UPRID AND anc.AccountNumber = '00272531'
WHERE x.IdentifierType = 'SOURCE_RECORD_ID' AND x.SourceSystem = 'KDAT' AND x.IdentifierValue = '1012';
INSERT #R VALUES (CASE WHEN @n >= 1 THEN 'PASS' ELSE 'FAIL' END,
                  'SDAT row on Complex account is in the Complex', CONVERT(VARCHAR(20), @n) + ' (expected >=1)');

SELECT @n = COUNT(*) FROM dbo.COMPLEX WHERE CommunityName IS NULL;
INSERT #R VALUES (CASE WHEN @n = 2 THEN 'PASS' ELSE 'FAIL' END,
                  'Missing community names remain NULL', CONVERT(VARCHAR(20), @n) + ' (expected 2)');

/* ---- 7. MULTI with one address stays a Property -------------------------- */
SELECT @n = COUNT(*)
FROM dbo.PROPERTY p
INNER JOIN dbo.UPR u ON u.UPRID = p.UPRID
WHERE u.AccountNumber = '00100001';
INSERT #R VALUES (CASE WHEN @n = 1 THEN 'PASS' ELSE 'FAIL' END,
                  'Single-address MULTI is a Property', CONVERT(VARCHAR(20), @n) + ' (expected 1)');

/* Property -> Building -> Unit per client rule 3, even with no source Unit value */
SELECT @n = COUNT(*)
FROM dbo.UNIT n
INNER JOIN dbo.UPR u ON u.UPRID = n.UPRID
INNER JOIN dbo.UPR_CLOSURE cl ON cl.DescendantUPRID = u.UPRID
INNER JOIN dbo.UPR anc ON anc.UPRID = cl.AncestorUPRID AND anc.AccountNumber = '00100001'
WHERE n.UnitNumber = N'N/A';
INSERT #R VALUES (CASE WHEN @n = 1 THEN 'PASS' ELSE 'FAIL' END,
                  'Single-address MULTI still gets a Unit (N/A, no source value)', CONVERT(VARCHAR(20), @n) + ' (expected 1)');

/* ---- 8. Condo: SDAT account merges with the MA condo row ----------------- */
SELECT @n = COUNT(*) FROM dbo.CONDO c INNER JOIN dbo.UPR u ON u.UPRID = c.UPRID
WHERE u.AccountNumber = '00031023';
INSERT #R VALUES (CASE WHEN @n = 1 THEN 'PASS' ELSE 'FAIL' END,
                  'MA + SDAT condo merged into ONE Condo', CONVERT(VARCHAR(20), @n) + ' (expected 1)');

SELECT @n = COUNT(*)
FROM dbo.UNIT n
INNER JOIN dbo.UPR u ON u.UPRID = n.UPRID
INNER JOIN dbo.UPR_CLOSURE cl ON cl.DescendantUPRID = u.UPRID
INNER JOIN dbo.UPR anc ON anc.UPRID = cl.AncestorUPRID AND anc.AccountNumber = '00031023'
WHERE n.UnitNumber IN ('101', '102');
INSERT #R VALUES (CASE WHEN @n = 2 THEN 'PASS' ELSE 'FAIL' END,
                  'Condo units 101/102 from CondoUnit', CONVERT(VARCHAR(20), @n) + ' (expected 2)');

/* Condo with an AccountNumber but no CondoUnit value: still gets a Unit row
   (client rule) - record NULL, the source column exists but was left blank. */
SELECT @n = COUNT(*)
FROM dbo.UNIT n
INNER JOIN dbo.UPR u ON u.UPRID = n.UPRID
INNER JOIN dbo.UPR_CLOSURE cl ON cl.DescendantUPRID = u.UPRID
INNER JOIN dbo.UPR anc ON anc.UPRID = cl.AncestorUPRID AND anc.AccountNumber = '00044556'
WHERE n.UnitNumber IS NULL;
INSERT #R VALUES (CASE WHEN @n = 1 THEN 'PASS' ELSE 'FAIL' END,
                  'Condo with no CondoUnit value still gets a Unit (NULL, not skipped)', CONVERT(VARCHAR(20), @n) + ' (expected 1)');

/* zero-padded account 31024 / 00031024 must be one condo */
SELECT @n = COUNT(*) FROM dbo.UPR WHERE AccountNumber = '00031024';
INSERT #R VALUES (CASE WHEN @n = 1 THEN 'PASS' ELSE 'FAIL' END,
                  'Zero-padded account deduped', CONVERT(VARCHAR(20), @n) + ' (expected 1)');

/* ---- 9. Warehouse / Office / Park / Vacant get a building, no unit ------- */
SELECT @n = COUNT(*)
FROM dbo.UPR u
INNER JOIN dbo.PROPERTY p ON p.UPRID = u.UPRID
INNER JOIN dbo.REF_PROPERTYTYPE t ON t.PropertyTypeID = p.PropertyTypeID
WHERE u.AccountNumber IN ('00000011', '00000022', '00000033', '00000044', '00000055')
  AND EXISTS (SELECT 1 FROM dbo.UPR b WHERE b.ParentUPRID = u.UPRID);
INSERT #R VALUES (CASE WHEN @n = 5 THEN 'PASS' ELSE 'FAIL' END,
                  'Warehouse/Office/Vacant/Park have buildings', CONVERT(VARCHAR(20), @n) + ' (expected 5)');

SELECT @n = COUNT(*)
FROM dbo.UNIT n
INNER JOIN dbo.UPR u ON u.UPRID = n.UPRID
INNER JOIN dbo.UPR b ON b.UPRID = u.ParentUPRID
INNER JOIN dbo.UPR p ON p.UPRID = b.ParentUPRID
WHERE p.AccountNumber IN ('00000011', '00000022', '00000044', '00000055');
INSERT #R VALUES (CASE WHEN @n = 0 THEN 'PASS' ELSE 'FAIL' END,
                  'No units for warehouse/vacant/park', CONVERT(VARCHAR(20), @n) + ' (expected 0)');

/* ---- 10. long LUCategory maps to a short code ---------------------------- */
SELECT @n = COUNT(*) FROM dbo.REF_PROPERTYTYPE WHERE PropertyTypeCode = 'INSTCF';
INSERT #R VALUES (CASE WHEN @n = 1 THEN 'PASS' ELSE 'FAIL' END,
                  'Institutional/Community -> INSTCF', CONVERT(VARCHAR(20), @n));

/* ---- 11. blank record type must not become SF ---------------------------- */
SELECT @n = COUNT(*)
FROM dbo.PROPERTY p
INNER JOIN dbo.UPR u ON u.UPRID = p.UPRID
INNER JOIN dbo.REF_PROPERTYTYPE t ON t.PropertyTypeID = p.PropertyTypeID
WHERE u.AccountNumber IN ('00000077', '00000088') AND t.PropertyTypeCode = 'UNKNWN';
INSERT #R VALUES (CASE WHEN @n = 2 THEN 'PASS' ELSE 'FAIL' END,
                  'Blank record type -> UNKNWN not SF', CONVERT(VARCHAR(20), @n) + ' (expected 2)');

/* ---- 12. one account on three non-multifamily addresses ------------------ */
SELECT @n = COUNT(*) FROM dbo.UPR u
INNER JOIN dbo.PROPERTY p ON p.UPRID = u.UPRID
WHERE u.AccountNumber = '00000099';
INSERT #R VALUES (CASE WHEN @n = 3 THEN 'PASS' ELSE 'FAIL' END,
                  'One account -> 3 separate Properties', CONVERT(VARCHAR(20), @n) + ' (expected 3)');

SELECT @n = COUNT(*) FROM dbo.EXTERNAL_IDENTIFIER_XREF
WHERE IdentifierType = 'ACCOUNT_NUMBER' AND IdentifierValue = '00000099';
INSERT #R VALUES (CASE WHEN @n = 3 THEN 'PASS' ELSE 'FAIL' END,
                  'All 3 account XREF links kept', CONVERT(VARCHAR(20), @n) + ' (expected 3)');

/* ---- 13. source records map 1:1 to a UPR --------------------------------- */
SELECT @n = COUNT(*), @m = COUNT(DISTINCT IdentifierValue)
FROM dbo.EXTERNAL_IDENTIFIER_XREF WHERE IdentifierType = 'SOURCE_RECORD_ID';
INSERT #R VALUES (CASE WHEN @n = @m THEN 'PASS' ELSE 'FAIL' END,
                  'Source record IDs unique in XREF', CONVERT(VARCHAR(20), @n) + ' rows / '
                  + CONVERT(VARCHAR(20), @m) + ' distinct');

/* ---- 14. YearBuilt 0 / 9999 stored as NULL, not rejected ----------------- */
SELECT @n = COUNT(*) FROM dbo.BUILDING WHERE YearBuilt IS NOT NULL AND (YearBuilt < 1600 OR YearBuilt > 2100);
INSERT #R VALUES (CASE WHEN @n = 0 THEN 'PASS' ELSE 'FAIL' END,
                  'No out-of-range YearBuilt stored', CONVERT(VARCHAR(20), @n));
SELECT @n = COUNT(*) FROM dbo.UPR WHERE AccountNumber IN ('00055667', '00055668');
INSERT #R VALUES (CASE WHEN @n = 2 THEN 'PASS' ELSE 'FAIL' END,
                  'Bad-YearBuilt rows still loaded', CONVERT(VARCHAR(20), @n) + ' (expected 2)');

/* ---- 15. 300-char street name survived without truncation error ---------- */
SELECT @n = COUNT(*) FROM dbo.UPR WHERE AccountNumber = '00066778';
INSERT #R VALUES (CASE WHEN @n = 1 THEN 'PASS' ELSE 'FAIL' END,
                  'Very long street name loaded', CONVERT(VARCHAR(20), @n) + ' (expected 1)');
SELECT @n = COUNT(*) FROM dbo.ADDRESS WHERE State IS NULL AND StreetName LIKE 'VERYLONG%';
INSERT #R VALUES (CASE WHEN @n = 1 THEN 'PASS' ELSE 'FAIL' END,
                  'Unsupported source State remains NULL', CONVERT(VARCHAR(20), @n) + ' (expected 1)');

/* ---- 16. rejects are in Review_Q and NOT in UPR -------------------------- */
SELECT @n = COUNT(*) FROM dbo.UPR WHERE AccountNumber IN ('00000131', '00088990');
INSERT #R VALUES (CASE WHEN @n = 0 THEN 'PASS' ELSE 'FAIL' END,
                  'Bad-address rows not loaded', CONVERT(VARCHAR(20), @n) + ' (expected 0)');
SELECT @n = COUNT(*) FROM dbo.UPRMATCHREVIEW_Q WHERE ReasonForNoMatch = 'NO_ADDRESS_MATCH';
INSERT #R VALUES (CASE WHEN @n >= 2 THEN 'PASS' ELSE 'FAIL' END,
                  'Bad-address rows in Review_Q', CONVERT(VARCHAR(20), @n) + ' (expected >=2)');

/* Client rule: any source record without an AccountNumber is rejected to
   Review_Q and must NEVER appear in UPR (no exceptions for a valid address). */
SELECT @n = COUNT(*) FROM dbo.UPRMATCHREVIEW_Q WHERE ReasonForNoMatch = 'INSUFFICIENT_DATA';
INSERT #R VALUES (CASE WHEN @n = 1 THEN 'PASS' ELSE 'FAIL' END,
                  'No-account row flagged in Review_Q', CONVERT(VARCHAR(20), @n) + ' (expected 1)');
SELECT @n = COUNT(*) FROM dbo.ADDRESS a
INNER JOIN dbo.UPR_ADDRESS ua ON ua.AddressID = a.AddressID
WHERE a.StreetName = 'NOACCOUNT';
INSERT #R VALUES (CASE WHEN @n = 0 THEN 'PASS' ELSE 'FAIL' END,
                  'No-account row rejected, NOT loaded into UPR', CONVERT(VARCHAR(20), @n) + ' (expected 0)');

/* ---- 17. missing parcel: loaded WITHOUT a parcel-only review ------------- */
SELECT @n = COUNT(*) FROM dbo.UPR WHERE AccountNumber IN ('00000161', '00000171');
INSERT #R VALUES (CASE WHEN @n = 2 THEN 'PASS' ELSE 'FAIL' END,
                  'Missing-parcel rows still loaded', CONVERT(VARCHAR(20), @n) + ' (expected 2)');
SELECT @n = COUNT(*) FROM dbo.UPRMATCHREVIEW_Q WHERE ReasonForNoMatch = 'MISSING PARCELID';
INSERT #R VALUES (CASE WHEN @n = 0 THEN 'PASS' ELSE 'FAIL' END,
                  'No missing-parcel review entries', CONVERT(VARCHAR(20), @n) + ' (expected 0)');

/* ---- 18. closure covers every ancestor path ------------------------------ */
SELECT @n = COUNT(*) FROM dbo.UPR u
WHERE NOT EXISTS (SELECT 1 FROM dbo.UPR_CLOSURE c WHERE c.AncestorUPRID = u.UPRID AND c.DescendantUPRID = u.UPRID);
INSERT #R VALUES (CASE WHEN @n = 0 THEN 'PASS' ELSE 'FAIL' END,
                  'Closure has a self row per UPR', CONVERT(VARCHAR(20), @n));
SELECT @n = COUNT(*) FROM dbo.UPR u
WHERE u.ParentUPRID IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM dbo.UPR_CLOSURE c WHERE c.AncestorUPRID = u.ParentUPRID AND c.DescendantUPRID = u.UPRID);
INSERT #R VALUES (CASE WHEN @n = 0 THEN 'PASS' ELSE 'FAIL' END,
                  'Closure has parent-child rows', CONVERT(VARCHAR(20), @n));

/* Level matches the descendant's root depth, including self rows. */
;WITH Tree AS (
    SELECT UPRID, LevelNo = 0 FROM dbo.UPR WHERE ParentUPRID IS NULL
    UNION ALL
    SELECT u.UPRID, t.LevelNo + 1 FROM dbo.UPR u
    INNER JOIN Tree t ON t.UPRID = u.ParentUPRID
)
SELECT @n = COUNT(*) FROM dbo.UPR_CLOSURE c
LEFT JOIN Tree t ON t.UPRID = c.DescendantUPRID
WHERE t.UPRID IS NULL OR c.[Level] IS NULL OR c.[Level] <> t.LevelNo
OPTION (MAXRECURSION 0);
INSERT #R VALUES (CASE WHEN @n = 0 THEN 'PASS' ELSE 'FAIL' END,
                  'Closure Level matches report root depth', CONVERT(VARCHAR(20), @n));

/* ---- 19. contact / status history counts match parents ------------------- */
SELECT @n = COUNT(*) FROM dbo.UPR u
INNER JOIN dbo.REF_ENTITYTYPE e ON e.EntityTypeID = u.EntityTypeID
WHERE e.Description IN ('Complex', 'Property', 'Condo');
SELECT @m = COUNT(*) FROM dbo.UPRSTATUSHISTORY;
INSERT #R VALUES (CASE WHEN @n = @m THEN 'PASS' ELSE 'FAIL' END,
                  'Status history row per parent', CONVERT(VARCHAR(20), @n) + ' parents / '
                  + CONVERT(VARCHAR(20), @m) + ' history');

/* ---- 20. never an invented MA-<id> / SD-<id> UnitNumber (client rule) ---- */
SELECT @n = COUNT(*) FROM dbo.UNIT
WHERE (UnitNumber LIKE 'MA-%' AND SUBSTRING(UnitNumber, 4, 50) NOT LIKE '%[^0-9]%')
   OR (UnitNumber LIKE 'SD-%' AND SUBSTRING(UnitNumber, 4, 50) NOT LIKE '%[^0-9]%');
INSERT #R VALUES (CASE WHEN @n = 0 THEN 'PASS' ELSE 'FAIL' END,
                  'No invented MA-/SD- UnitNumber anywhere', CONVERT(VARCHAR(20), @n) + ' (expected 0)');

SELECT * FROM #R ORDER BY Seq;

SELECT Failures = SUM(CASE WHEN Result = 'FAIL' THEN 1 ELSE 0 END),
       Passes   = SUM(CASE WHEN Result = 'PASS' THEN 1 ELSE 0 END)
FROM #R;
IF EXISTS (SELECT 1 FROM #R WHERE Result = 'FAIL')
    THROW 51000, 'Local integration verification failed.', 1;
GO
