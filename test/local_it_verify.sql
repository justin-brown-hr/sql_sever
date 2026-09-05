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
INSERT #R VALUES (CASE WHEN @n = 3 THEN 'PASS' ELSE 'FAIL' END,
                  'Complex 00272531 has 3 buildings', CONVERT(VARCHAR(20), @n) + ' (expected 3)');

SELECT @n = COUNT(*)
FROM dbo.BUILDING b
INNER JOIN dbo.UPR u ON u.UPRID = b.UPRID
INNER JOIN dbo.UPR p ON p.UPRID = u.ParentUPRID AND p.AccountNumber = '00272531'
WHERE b.BuildingName IN ('Building A', 'Building B', 'Building C');
INSERT #R VALUES (CASE WHEN @n = 3 THEN 'PASS' ELSE 'FAIL' END,
                  'Buildings labelled Building A/B/C', CONVERT(VARCHAR(20), @n) + ' (expected 3)');

SELECT @n = COUNT(*) FROM dbo.COMPLEX WHERE CommunityName LIKE '%BUILDING COMPLEX';
INSERT #R VALUES (CASE WHEN @n = 2 THEN 'PASS' ELSE 'FAIL' END,
                  'CommunityName is a business label', CONVERT(VARCHAR(20), @n) + ' (expected 2)');

/* ---- 7. MULTI with one address stays a Property -------------------------- */
SELECT @n = COUNT(*)
FROM dbo.PROPERTY p
INNER JOIN dbo.UPR u ON u.UPRID = p.UPRID
WHERE u.AccountNumber = '00100001';
INSERT #R VALUES (CASE WHEN @n = 1 THEN 'PASS' ELSE 'FAIL' END,
                  'Single-address MULTI is a Property', CONVERT(VARCHAR(20), @n) + ' (expected 1)');

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
SELECT @n = COUNT(*) FROM dbo.ADDRESS WHERE State = 'MD' AND StreetName LIKE 'VERYLONG%';
INSERT #R VALUES (CASE WHEN @n = 1 THEN 'PASS' ELSE 'FAIL' END,
                  'Garbage PremisesState fell back to MD', CONVERT(VARCHAR(20), @n) + ' (expected 1)');

/* ---- 16. rejects are in Review_Q and NOT in UPR -------------------------- */
SELECT @n = COUNT(*) FROM dbo.UPR WHERE AccountNumber IN ('00000131', '00000141', '00000151', '00088990', '00099001');
INSERT #R VALUES (CASE WHEN @n = 0 THEN 'PASS' ELSE 'FAIL' END,
                  'Bad-address rows not loaded', CONVERT(VARCHAR(20), @n) + ' (expected 0)');
SELECT @n = COUNT(*) FROM dbo.UPRMATCHREVIEW_Q WHERE ReasonForNoMatch = 'NO_ADDRESS_MATCH';
INSERT #R VALUES (CASE WHEN @n >= 5 THEN 'PASS' ELSE 'FAIL' END,
                  'Bad-address rows in Review_Q', CONVERT(VARCHAR(20), @n) + ' (expected >=5)');
SELECT @n = COUNT(*) FROM dbo.UPRMATCHREVIEW_Q WHERE ReasonForNoMatch = 'INSUFFICIENT_DATA';
INSERT #R VALUES (CASE WHEN @n = 1 THEN 'PASS' ELSE 'FAIL' END,
                  'No-account row -> INSUFFICIENT_DATA', CONVERT(VARCHAR(20), @n) + ' (expected 1)');

/* ---- 17. missing parcel: loaded AND flagged ------------------------------ */
SELECT @n = COUNT(*) FROM dbo.UPR WHERE AccountNumber IN ('00000161', '00000171');
INSERT #R VALUES (CASE WHEN @n = 2 THEN 'PASS' ELSE 'FAIL' END,
                  'Missing-parcel rows still loaded', CONVERT(VARCHAR(20), @n) + ' (expected 2)');
SELECT @n = COUNT(*) FROM dbo.UPRMATCHREVIEW_Q WHERE ReasonForNoMatch = 'MISSING PARCELID';
INSERT #R VALUES (CASE WHEN @n >= 2 THEN 'PASS' ELSE 'FAIL' END,
                  'Missing-parcel rows flagged', CONVERT(VARCHAR(20), @n) + ' (expected >=2)');

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

/* ---- 19. contact / status history counts match parents ------------------- */
SELECT @n = COUNT(*) FROM dbo.UPR u
INNER JOIN dbo.REF_ENTITYTYPE e ON e.EntityTypeID = u.EntityTypeID
WHERE e.Description IN ('Complex', 'Property', 'Condo');
SELECT @m = COUNT(*) FROM dbo.UPRSTATUSHISTORY;
INSERT #R VALUES (CASE WHEN @n = @m THEN 'PASS' ELSE 'FAIL' END,
                  'Status history row per parent', CONVERT(VARCHAR(20), @n) + ' parents / '
                  + CONVERT(VARCHAR(20), @m) + ' history');

SELECT * FROM #R ORDER BY Seq;

SELECT Failures = SUM(CASE WHEN Result = 'FAIL' THEN 1 ELSE 0 END),
       Passes   = SUM(CASE WHEN Result = 'PASS' THEN 1 ELSE 0 END)
FROM #R;
GO
