/*
================================================================================
  UPR Load Validation Report
  Run AFTER scripts/load_upr_master.sql

  Works with REAL DATA or test data.
  Run in SSMS: File -> Open -> this file -> Execute (F5)

  Steps for real-data test:
    1. Load YOUR data into dbo.AddressMaster and dbo.SDAT
    2. Run scripts/load_upr_master.sql
    3. Run THIS script to review results
================================================================================
*/
USE UPR_Master;
GO

SET NOCOUNT ON;

/* Optional: set an account number to see full detail for one property at the end */
DECLARE @SampleAccount NVARCHAR(50) = NULL;   -- e.g. N'10001001'

PRINT N'';
PRINT N'============================================================';
PRINT N'  UPR LOAD VALIDATION REPORT';
PRINT N'  Run date: ' + CONVERT(NVARCHAR(30), SYSDATETIME(), 120);
PRINT N'============================================================';

/* --------------------------------------------------------------------------
   SECTION 1: Record counts after load
   -------------------------------------------------------------------------- */
PRINT N'';
PRINT N'--- 1. RECORD COUNTS (tables populated by load) ---';

SELECT
    TableName,
    RecordCount,
    CASE TableName
        WHEN N'AddressMaster (incoming)'     THEN N'Your source data - AddressMaster staging'
        WHEN N'SDAT (incoming)'              THEN N'Your source data - SDAT staging'
        WHEN N'UPROPERTYRECORD (master)'   THEN N'Master property records created/updated'
        WHEN N'UPROPERTYRECORD_XREF'       THEN N'Links from UPR to source systems'
        WHEN N'UPROPERTYMATCHREVIEW_Q'     THEN N'Records needing manual review'
        WHEN N'UPR_STATUSHISTORY'          THEN N'Status change history'
        WHEN N'CONTACT'                      THEN N'Owner/contact records from SDAT'
        WHEN N'PROPERTYCONTACT'              THEN N'Property-to-contact links'
        WHEN N'Building'                     THEN N'Buildings (CONDO/APT properties)'
        WHEN N'Unit'                         THEN N'Units (CONDO/APT properties)'
        WHEN N'AuditLog'                     THEN N'Processing audit trail'
        ELSE N''
    END AS Description
FROM (
    SELECT N'AddressMaster (incoming)'     AS TableName, COUNT(*) AS RecordCount FROM dbo.AddressMaster
    UNION ALL SELECT N'SDAT (incoming)',              COUNT(*) FROM dbo.SDAT
    UNION ALL SELECT N'UPROPERTYRECORD (master)',    COUNT(*) FROM dbo.UPROPERTYRECORD
    UNION ALL SELECT N'UPROPERTYRECORD_XREF',        COUNT(*) FROM dbo.UPROPERTYRECORD_XREF
    UNION ALL SELECT N'UPROPERTYMATCHREVIEW_Q',      COUNT(*) FROM dbo.UPROPERTYMATCHREVIEW_Q
    UNION ALL SELECT N'UPR_STATUSHISTORY',           COUNT(*) FROM dbo.UPR_STATUSHISTORY
    UNION ALL SELECT N'CONTACT',                       COUNT(*) FROM dbo.CONTACT
    UNION ALL SELECT N'PROPERTYCONTACT',               COUNT(*) FROM dbo.PROPERTYCONTACT
    UNION ALL SELECT N'Building',                      COUNT(*) FROM dbo.Building
    UNION ALL SELECT N'Unit',                          COUNT(*) FROM dbo.Unit
    UNION ALL SELECT N'AuditLog',                      COUNT(*) FROM dbo.AuditLog
) c
ORDER BY TableName;

/* --------------------------------------------------------------------------
   SECTION 2: Cross-reference summary by source system
   -------------------------------------------------------------------------- */
PRINT N'';
PRINT N'--- 2. CROSS-REFERENCES BY SOURCE SYSTEM ---';
PRINT N'    (Shows how many records matched each external system)';

SELECT
    SourceSystem,
    MatchResult,
    MatchConfidence,
    COUNT(*) AS RecordCount
FROM dbo.UPROPERTYRECORD_XREF
GROUP BY SourceSystem, MatchResult, MatchConfidence
ORDER BY SourceSystem, MatchResult;

/* --------------------------------------------------------------------------
   SECTION 3: Review queue summary
   -------------------------------------------------------------------------- */
PRINT N'';
PRINT N'--- 3. REVIEW QUEUE (records that could not be auto-matched) ---';

SELECT
    ReasonForNoMatch AS Reason,
    ReviewStatus,
    COUNT(*) AS RecordCount
FROM dbo.UPROPERTYMATCHREVIEW_Q
GROUP BY ReasonForNoMatch, ReviewStatus
ORDER BY RecordCount DESC;

IF NOT EXISTS (SELECT 1 FROM dbo.UPROPERTYMATCHREVIEW_Q)
    PRINT N'    (No records in review queue - all records matched or processed)';

/* --------------------------------------------------------------------------
   SECTION 4: Validation checks (meaningful descriptions for real data)
   -------------------------------------------------------------------------- */
PRINT N'';
PRINT N'--- 4. VALIDATION CHECKS ---';

DECLARE @checks TABLE (
    CheckNumber     INT           NOT NULL,
    TestDescription NVARCHAR(200) NOT NULL,
    WhatWeChecked   NVARCHAR(300) NOT NULL,
    ExpectedResult  NVARCHAR(50)  NOT NULL,
    ActualResult    NVARCHAR(50)  NOT NULL,
    Pass            BIT           NOT NULL
);

DECLARE @maCnt   INT = (SELECT COUNT(*) FROM dbo.AddressMaster);
DECLARE @sdatCnt INT = (SELECT COUNT(*) FROM dbo.SDAT);
DECLARE @uprCnt  INT = (SELECT COUNT(*) FROM dbo.UPROPERTYRECORD);
DECLARE @xrefMa  INT = (SELECT COUNT(*) FROM dbo.UPROPERTYRECORD_XREF WHERE SourceSystem = N'ADDRESS_MASTER');
DECLARE @xrefKd  INT = (SELECT COUNT(*) FROM dbo.UPROPERTYRECORD_XREF WHERE SourceSystem = N'KDAT');
DECLARE @xrefEp  INT = (SELECT COUNT(*) FROM dbo.UPROPERTYRECORD_XREF WHERE SourceSystem = N'eProperty' AND MatchResult = N'MATCH');
DECLARE @xrefCs  INT = (SELECT COUNT(*) FROM dbo.UPROPERTYRECORD_XREF WHERE SourceSystem = N'CASE' AND MatchResult = N'MATCH');
DECLARE @xrefMp  INT = (SELECT COUNT(*) FROM dbo.UPROPERTYRECORD_XREF WHERE SourceSystem = N'MPDU' AND MatchResult = N'MATCH');
DECLARE @xrefMf  INT = (SELECT COUNT(*) FROM dbo.UPROPERTYRECORD_XREF WHERE SourceSystem = N'MULTIFAMILY' AND MatchResult = N'MATCH');
DECLARE @reviewQ INT = (SELECT COUNT(*) FROM dbo.UPROPERTYMATCHREVIEW_Q);
DECLARE @auditCnt INT = (SELECT COUNT(*) FROM dbo.AuditLog);
DECLARE @dupCnt  INT = (SELECT COUNT(*) FROM (
    SELECT SDATAccountNumber FROM dbo.UPROPERTYRECORD
    WHERE SDATAccountNumber IS NOT NULL
    GROUP BY SDATAccountNumber HAVING COUNT(*) > 1) d);
DECLARE @condoCnt INT = (SELECT COUNT(*) FROM dbo.UPROPERTYRECORD WHERE PropertyType = N'CONDO');
DECLARE @bldgCnt  INT = (SELECT COUNT(*) FROM dbo.Building);
DECLARE @epExists INT = (SELECT COUNT(*) FROM dbo.eProperty);
DECLARE @csExists INT = (SELECT COUNT(*) FROM dbo.[Case]);
DECLARE @mpExists INT = (SELECT COUNT(*) FROM dbo.MPDU);

/* Check 1 */
INSERT INTO @checks VALUES (1,
    N'Incoming AddressMaster data loaded',
    N'AddressMaster staging table has rows ready for processing',
    N'> 0', CAST(@maCnt AS NVARCHAR(20)), CASE WHEN @maCnt > 0 THEN 1 ELSE 0 END);

/* Check 2 */
INSERT INTO @checks VALUES (2,
    N'Incoming SDAT data loaded',
    N'SDAT staging table has rows ready for processing',
    N'> 0', CAST(@sdatCnt AS NVARCHAR(20)), CASE WHEN @sdatCnt > 0 THEN 1 ELSE 0 END);

/* Check 3 */
INSERT INTO @checks VALUES (3,
    N'UPR master records created',
    N'UPROPERTYRECORD table populated from incoming data',
    N'> 0', CAST(@uprCnt AS NVARCHAR(20)), CASE WHEN @uprCnt > 0 THEN 1 ELSE 0 END);

/* Check 4 */
INSERT INTO @checks VALUES (4,
    N'AddressMaster linked to UPR (XREF)',
    N'Each AddressMaster record written to UPROPERTYRECORD_XREF',
    N'> 0', CAST(@xrefMa AS NVARCHAR(20)), CASE WHEN @xrefMa > 0 THEN 1 ELSE 0 END);

/* Check 5 */
INSERT INTO @checks VALUES (5,
    N'SDAT linked to UPR (XREF)',
    N'Each SDAT record written to UPROPERTYRECORD_XREF as KDAT source',
    N'> 0', CAST(@xrefKd AS NVARCHAR(20)), CASE WHEN @sdatCnt = 0 OR @xrefKd > 0 THEN 1 ELSE 0 END);

/* Check 6 - eProperty (only if eProperty table has data) */
INSERT INTO @checks VALUES (6,
    N'Matched to eProperty system',
    N'UPR address/account matched records in eProperty table',
    CASE WHEN @epExists = 0 THEN N'N/A' ELSE N'> 0' END,
    CASE WHEN @epExists = 0 THEN N'N/A (no eProperty data)' ELSE CAST(@xrefEp AS NVARCHAR(20)) END,
    CASE WHEN @epExists = 0 THEN 1 WHEN @xrefEp > 0 THEN 1 ELSE 0 END);

/* Check 7 - CASE */
INSERT INTO @checks VALUES (7,
    N'Matched to CASE system',
    N'UPR normalized address matched records in Case table',
    CASE WHEN @csExists = 0 THEN N'N/A' ELSE N'> 0' END,
    CASE WHEN @csExists = 0 THEN N'N/A (no Case data)' ELSE CAST(@xrefCs AS NVARCHAR(20)) END,
    CASE WHEN @csExists = 0 THEN 1 WHEN @xrefCs > 0 THEN 1 ELSE 0 END);

/* Check 8 - MPDU */
INSERT INTO @checks VALUES (8,
    N'Matched to MPDU system',
    N'UPR normalized address matched records in MPDU table',
    CASE WHEN @mpExists = 0 THEN N'N/A' ELSE N'> 0' END,
    CASE WHEN @mpExists = 0 THEN N'N/A (no MPDU data)' ELSE CAST(@xrefMp AS NVARCHAR(20)) END,
    CASE WHEN @mpExists = 0 THEN 1 WHEN @xrefMp > 0 THEN 1 ELSE 0 END);

/* Check 9 - Multifamily */
INSERT INTO @checks VALUES (9,
    N'Matched to Multifamily Loan addresses',
    N'UPR address matched MultifamilyLoanAddress table',
    N'>= 0', CAST(@xrefMf AS NVARCHAR(20)), 1);

/* Check 10 - Review queue (informational - always pass, show count) */
INSERT INTO @checks VALUES (10,
    N'Review queue populated for unmatched records',
    N'Records sent to UPROPERTYMATCHREVIEW_Q for manual review (0 is OK if all matched)',
    N'>= 0', CAST(@reviewQ AS NVARCHAR(20)), 1);

/* Check 11 - No duplicates */
INSERT INTO @checks VALUES (11,
    N'No duplicate UPR records by account number',
    N'Same SDATAccountNumber must not appear twice in UPROPERTYRECORD',
    N'0', CAST(@dupCnt AS NVARCHAR(20)), CASE WHEN @dupCnt = 0 THEN 1 ELSE 0 END);

/* Check 12 - Audit log */
INSERT INTO @checks VALUES (12,
    N'Audit log written',
    N'All processing steps recorded in AuditLog table',
    N'> 0', CAST(@auditCnt AS NVARCHAR(20)), CASE WHEN @auditCnt > 0 THEN 1 ELSE 0 END);

/* Check 13 - CONDO buildings (only if CONDO properties exist) */
INSERT INTO @checks VALUES (13,
    N'CONDO properties have Building records',
    N'When PropertyType = CONDO, Building table should have rows',
    CASE WHEN @condoCnt = 0 THEN N'N/A' ELSE N'> 0' END,
    CASE WHEN @condoCnt = 0 THEN N'N/A (no CONDO properties)' ELSE CAST(@bldgCnt AS NVARCHAR(20)) END,
    CASE WHEN @condoCnt = 0 THEN 1 WHEN @bldgCnt > 0 THEN 1 ELSE 0 END);

SELECT
    CheckNumber,
    TestDescription,
    WhatWeChecked,
    ExpectedResult,
    ActualResult,
    CASE WHEN Pass = 1 THEN N'PASS' ELSE N'FAIL' END AS Result
FROM @checks
ORDER BY CheckNumber;

DECLARE @fail   INT = (SELECT COUNT(*) FROM @checks WHERE Pass = 0);
DECLARE @passed INT = (SELECT COUNT(*) FROM @checks WHERE Pass = 1);
DECLARE @total  INT = (SELECT COUNT(*) FROM @checks);

PRINT N'';
PRINT N'Validation summary: ' + CAST(@passed AS NVARCHAR(10)) + N' passed / ' + CAST(@total AS NVARCHAR(10)) + N' checks';

IF @fail > 0
    PRINT N'*** ' + CAST(@fail AS NVARCHAR(10)) + N' check(s) FAILED - review rows marked FAIL above ***';
ELSE
    PRINT N'All validation checks PASSED.';

/* --------------------------------------------------------------------------
   SECTION 5: Sample UPR records with cross-references (first 20)
   -------------------------------------------------------------------------- */
PRINT N'';
PRINT N'--- 5. SAMPLE UPR RECORDS WITH CROSS-REFERENCES (first 20) ---';

SELECT TOP 20
    upr.UPropertyRecordID,
    upr.SDATAccountNumber   AS AccountNumber,
    upr.ParcelID,
    upr.NormalizedAddress,
    upr.NormalizedFullAddress,
    upr.City,
    upr.ZipCode,
    upr.PropertyType,
    upr.Owner,
    upr.StatusCode,
    STUFF((
        SELECT N', ' + x2.SourceSystem + N'(' + x2.MatchResult + N')'
        FROM dbo.UPROPERTYRECORD_XREF x2
        WHERE x2.UPropertyRecordID = upr.UPropertyRecordID
          AND x2.IsActive = 1
        FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(500)'), 1, 2, N'') AS LinkedSourceSystems
FROM dbo.UPROPERTYRECORD upr
ORDER BY upr.UPropertyRecordID;

/* --------------------------------------------------------------------------
   SECTION 6: Review queue detail (if any)
   -------------------------------------------------------------------------- */
IF @reviewQ > 0
BEGIN
    PRINT N'';
    PRINT N'--- 6. REVIEW QUEUE DETAIL (records needing manual review) ---';

    SELECT TOP 50
        q.UPRMatchReviewID,
        q.SDATAccountNumber   AS AccountNumber,
        q.ParcelID,
        q.NormalizedIncomingAddress,
        q.ReasonForNoMatch    AS Reason,
        q.ReviewStatus,
        q.IncomingSourceSystem AS Source
    FROM dbo.UPROPERTYMATCHREVIEW_Q q
    ORDER BY q.ProcessingTimestamp DESC;
END

/* --------------------------------------------------------------------------
   SECTION 7: Optional single-account detail
   -------------------------------------------------------------------------- */
IF @SampleAccount IS NOT NULL
BEGIN
    PRINT N'';
    PRINT N'--- 7. DETAIL FOR ACCOUNT: ' + @SampleAccount + N' ---';

    SELECT
        upr.UPropertyRecordID,
        upr.SDATAccountNumber,
        upr.ParcelID,
        upr.NormalizedAddress,
        upr.NormalizedFullAddress,
        upr.PropertyType,
        upr.Owner,
        upr.StatusCode
    FROM dbo.UPROPERTYRECORD upr
    WHERE upr.SDATAccountNumber = @SampleAccount;

    SELECT
        x.SourceSystem,
        x.SourceRecordID,
        x.MatchMethodCode,
        x.MatchResult,
        x.MatchConfidence,
        x.ProcessingStatus
    FROM dbo.UPROPERTYRECORD upr
    JOIN dbo.UPROPERTYRECORD_XREF x ON x.UPropertyRecordID = upr.UPropertyRecordID
    WHERE upr.SDATAccountNumber = @SampleAccount
    ORDER BY x.SourceSystem;
END

GO
