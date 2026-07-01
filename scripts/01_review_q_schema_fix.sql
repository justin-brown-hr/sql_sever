/*
  Run ONCE before load (or let load_upr_master.sql apply CHECK repair automatically).
  Client Review_Q DDL must include core columns; load uses table as-is (no MA_Account etc.).
  Rebuilds UPRMATCHREVIEW_Q ReasonForNoMatch CHECK to include load reasons.
  Must run OUTSIDE a transaction that will roll back.
*/
USE UPRXDB_TEST;
GO

IF OBJECT_ID(N'dbo.UPRMATCHREVIEW_Q', N'U') IS NULL
BEGIN
    RAISERROR(N'dbo.UPRMATCHREVIEW_Q not found.', 16, 1);
    RETURN;
END

IF COL_LENGTH('dbo.UPRMATCHREVIEW_Q', 'IncomingSourceSystem') IS NULL
   OR COL_LENGTH('dbo.UPRMATCHREVIEW_Q', 'NormalizedIncomingAddress') IS NULL
   OR COL_LENGTH('dbo.UPRMATCHREVIEW_Q', 'ReasonForNoMatch') IS NULL
BEGIN
    RAISERROR(N'UPRMATCHREVIEW_Q missing core columns. Recreate from client DDL.', 16, 1);
    RETURN;
END

DECLARE @DropSql NVARCHAR(MAX) = N'';
SELECT @DropSql = @DropSql
    + N'ALTER TABLE dbo.UPRMATCHREVIEW_Q DROP CONSTRAINT '
    + QUOTENAME(cc.name) + N';' + CHAR(13)
FROM sys.check_constraints cc
WHERE cc.parent_object_id = OBJECT_ID(N'dbo.UPRMATCHREVIEW_Q')
  AND cc.definition LIKE N'%ReasonForNoMatch%';

IF @DropSql <> N''
    EXEC sys.sp_executesql @DropSql;

IF EXISTS (
    SELECT 1
    FROM sys.check_constraints cc
    WHERE cc.parent_object_id = OBJECT_ID(N'dbo.UPRMATCHREVIEW_Q')
      AND cc.name = N'CK_UPRMATCHREVIEW_Q_ReasonForNoMatch'
)
    ALTER TABLE dbo.UPRMATCHREVIEW_Q DROP CONSTRAINT CK_UPRMATCHREVIEW_Q_ReasonForNoMatch;

ALTER TABLE dbo.UPRMATCHREVIEW_Q ADD CONSTRAINT CK_UPRMATCHREVIEW_Q_ReasonForNoMatch
    CHECK (ReasonForNoMatch IN (
        N'Missing ParcelID',
        N'Address or Account Not Match',
        N'NO_PARCEL_MATCH',
        N'NO_SDAT_MATCH',
        N'NO_ADDRESS_MATCH',
        N'INSUFFICIENT_DATA',
        N'AMBIGUOUS_CANDIDATES',
        N'DUPLICATE',
        N'LOW_CONFIDENCE_ONLY',
        N'SOURCE_RECORD_ERROR',
        N'OTHER'
    ));

SELECT cc.name, cc.definition
FROM sys.check_constraints cc
WHERE cc.parent_object_id = OBJECT_ID(N'dbo.UPRMATCHREVIEW_Q')
  AND cc.name = N'CK_UPRMATCHREVIEW_Q_ReasonForNoMatch';

PRINT N'Review_Q ReasonForNoMatch CHECK rebuilt (includes DUPLICATE and load reasons).';
