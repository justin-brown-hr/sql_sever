/*
================================================================================
  UPR Test Results - run AFTER load_upr_master.sql
  Validates key scenarios from Incoming_Test_Data.docx
================================================================================
*/
USE UPR_Master;
GO

SET NOCOUNT ON;

PRINT N'';
PRINT N'============================================================';
PRINT N'  TEST RESULTS SUMMARY';
PRINT N'============================================================';

SELECT N'AddressMaster' AS [Table], COUNT(*) AS [RowCount] FROM dbo.AddressMaster
UNION ALL SELECT N'SDAT', COUNT(*) FROM dbo.SDAT
UNION ALL SELECT N'UPROPERTYRECORD', COUNT(*) FROM dbo.UPROPERTYRECORD
UNION ALL SELECT N'UPROPERTYRECORD_XREF', COUNT(*) FROM dbo.UPROPERTYRECORD_XREF
UNION ALL SELECT N'UPROPERTYMATCHREVIEW_Q', COUNT(*) FROM dbo.UPROPERTYMATCHREVIEW_Q
UNION ALL SELECT N'UPR_STATUSHISTORY', COUNT(*) FROM dbo.UPR_STATUSHISTORY
UNION ALL SELECT N'CONTACT', COUNT(*) FROM dbo.CONTACT
UNION ALL SELECT N'PROPERTYCONTACT', COUNT(*) FROM dbo.PROPERTYCONTACT
UNION ALL SELECT N'Building', COUNT(*) FROM dbo.Building
UNION ALL SELECT N'Unit', COUNT(*) FROM dbo.Unit
UNION ALL SELECT N'AuditLog', COUNT(*) FROM dbo.AuditLog;

PRINT N'';
PRINT N'--- XREF by Source System ---';
SELECT SourceSystem, MatchResult, MatchConfidence, COUNT(*) AS Cnt
FROM dbo.UPROPERTYRECORD_XREF
GROUP BY SourceSystem, MatchResult, MatchConfidence
ORDER BY SourceSystem;

PRINT N'';
PRINT N'--- Review Queue Reasons ---';
SELECT ReasonForNoMatch, ReviewStatus, COUNT(*) AS Cnt
FROM dbo.UPROPERTYMATCHREVIEW_Q
GROUP BY ReasonForNoMatch, ReviewStatus;

PRINT N'';
PRINT N'--- Scenario Checks ---';

DECLARE @checks TABLE (Scenario NVARCHAR(100), Expected NVARCHAR(200), Actual NVARCHAR(200), Pass BIT);

/* 1. Client sample 10001001 - MA+SDAT+eProperty match */
INSERT INTO @checks
SELECT N'10001001 UPR created',
       N'>=1', CAST(COUNT(*) AS NVARCHAR(20)),
       CASE WHEN COUNT(*) >= 1 THEN 1 ELSE 0 END
FROM dbo.UPROPERTYRECORD WHERE SDATAccountNumber = N'10001001';

INSERT INTO @checks
SELECT N'10001001 eProperty XREF',
       N'>=1', CAST(COUNT(*) AS NVARCHAR(20)),
       CASE WHEN COUNT(*) >= 1 THEN 1 ELSE 0 END
FROM dbo.UPROPERTYRECORD upr
JOIN dbo.UPROPERTYRECORD_XREF x ON x.UPropertyRecordID = upr.UPropertyRecordID
WHERE upr.SDATAccountNumber = N'10001001' AND x.SourceSystem = N'eProperty' AND x.MatchResult = N'MATCH';

/* 2. Client sample 20002002 - MA only, CASE match (500 OAK LANE -> 500 OAK LN) */
INSERT INTO @checks
SELECT N'20002002 CASE XREF',
       N'>=1', CAST(COUNT(*) AS NVARCHAR(20)),
       CASE WHEN COUNT(*) >= 1 THEN 1 ELSE 0 END
FROM dbo.UPROPERTYRECORD upr
JOIN dbo.UPROPERTYRECORD_XREF x ON x.UPropertyRecordID = upr.UPropertyRecordID
WHERE upr.SDATAccountNumber = N'20002002' AND x.SourceSystem = N'CASE' AND x.MatchResult = N'MATCH';

/* 3. Client sample 30003003 - MPDU match */
INSERT INTO @checks
SELECT N'30003003 MPDU XREF',
       N'>=1', CAST(COUNT(*) AS NVARCHAR(20)),
       CASE WHEN COUNT(*) >= 1 THEN 1 ELSE 0 END
FROM dbo.UPROPERTYRECORD upr
JOIN dbo.UPROPERTYRECORD_XREF x ON x.UPropertyRecordID = upr.UPropertyRecordID
WHERE upr.SDATAccountNumber = N'30003003' AND x.SourceSystem = N'MPDU' AND x.MatchResult = N'MATCH';

/* 4. Client sample 40004004 - no external match -> Review_Q */
INSERT INTO @checks
SELECT N'40004004 Review Queue',
       N'>=1', CAST(COUNT(*) AS NVARCHAR(20)),
       CASE WHEN COUNT(*) >= 1 THEN 1 ELSE 0 END
FROM dbo.UPROPERTYMATCHREVIEW_Q q
WHERE q.SDATAccountNumber = N'40004004';

/* 5. CONDO property type creates Building */
INSERT INTO @checks
SELECT N'CONDO Building created',
       N'>=1', CAST(COUNT(*) AS NVARCHAR(20)),
       CASE WHEN COUNT(*) >= 1 THEN 1 ELSE 0 END
FROM dbo.UPROPERTYRECORD upr
JOIN dbo.Building b ON b.UPropertyRecordID = upr.UPropertyRecordID
WHERE upr.PropertyType = N'CONDO';

/* 6. No duplicate UPR by account */
INSERT INTO @checks
SELECT N'No duplicate accounts',
       N'0', CAST(COUNT(*) AS NVARCHAR(20)),
       CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END
FROM (
    SELECT SDATAccountNumber FROM dbo.UPROPERTYRECORD
    WHERE SDATAccountNumber IS NOT NULL
    GROUP BY SDATAccountNumber HAVING COUNT(*) > 1
) d;

/* 7. Audit log written */
INSERT INTO @checks
SELECT N'AuditLog entries',
       N'>=1', CAST(COUNT(*) AS NVARCHAR(20)),
       CASE WHEN COUNT(*) >= 1 THEN 1 ELSE 0 END
FROM dbo.AuditLog;

SELECT Scenario, Expected, Actual,
       CASE WHEN Pass = 1 THEN N'PASS' ELSE N'FAIL' END AS Result
FROM @checks
ORDER BY Scenario;

DECLARE @fail    INT = (SELECT COUNT(*) FROM @checks WHERE Pass = 0);
DECLARE @passed  INT = (SELECT COUNT(*) FROM @checks WHERE Pass = 1);
DECLARE @total   INT = (SELECT COUNT(*) FROM @checks);
PRINT N'';
PRINT N'Tests passed: ' + CAST(@passed AS NVARCHAR(10)) + N' / ' + CAST(@total AS NVARCHAR(10));

IF @fail > 0
    PRINT N'*** ' + CAST(@fail AS NVARCHAR(10)) + N' scenario check(s) FAILED ***';
ELSE
    PRINT N'All scenario checks PASSED.';

PRINT N'';
PRINT N'--- Sample: account 10001001 detail ---';
SELECT upr.UPropertyRecordID, upr.SDATAccountNumber, upr.NormalizedAddress, upr.PropertyType,
       x.SourceSystem, x.MatchMethodCode, x.MatchResult, x.MatchConfidence
FROM dbo.UPROPERTYRECORD upr
LEFT JOIN dbo.UPROPERTYRECORD_XREF x ON x.UPropertyRecordID = upr.UPropertyRecordID
WHERE upr.SDATAccountNumber = N'10001001'
ORDER BY x.SourceSystem;

GO
