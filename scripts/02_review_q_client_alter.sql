/*
  Review_Q preflight — run ONCE on target database before load (optional).
  Verifies client UPRMATCHREVIEW_Q column names used by load_upr_master.sql.
  Also allows NULL UPropertyRecords_XrefID so rejected rows need no UPR parent.
*/
SET NOCOUNT ON;

IF OBJECT_ID(N'dbo.UPRMATCHREVIEW_Q', N'U') IS NULL
BEGIN
    RAISERROR(N'dbo.UPRMATCHREVIEW_Q not found.', 16, 1);
    RETURN;
END;

IF COL_LENGTH('dbo.UPRMATCHREVIEW_Q', 'IncomingSourceSystem') IS NULL
   OR COL_LENGTH('dbo.UPRMATCHREVIEW_Q', 'MA_Account') IS NULL
   OR COL_LENGTH('dbo.UPRMATCHREVIEW_Q', 'MA_NormalizedIncomingAddress') IS NULL
   OR COL_LENGTH('dbo.UPRMATCHREVIEW_Q', 'MA_ParcelID') IS NULL
   OR COL_LENGTH('dbo.UPRMATCHREVIEW_Q', 'SDAT_AccountNumber') IS NULL
   OR COL_LENGTH('dbo.UPRMATCHREVIEW_Q', 'SDAT_NormalizedIncomingAddress') IS NULL
   OR COL_LENGTH('dbo.UPRMATCHREVIEW_Q', 'SDAT_ParcelID') IS NULL
   OR COL_LENGTH('dbo.UPRMATCHREVIEW_Q', 'ReasonForNoMatch') IS NULL
   OR COL_LENGTH('dbo.UPRMATCHREVIEW_Q', 'ReviewStatus') IS NULL
BEGIN
    RAISERROR(N'UPRMATCHREVIEW_Q missing required MA/SDAT Review_Q columns.', 16, 1);
    RETURN;
END;

IF EXISTS (
    SELECT 1
    FROM sys.foreign_keys fk
    WHERE fk.parent_object_id = OBJECT_ID(N'dbo.UPRMATCHREVIEW_Q')
      AND fk.name = N'FK_UPRMATCHREVIEW_Q_XREF'
)
    ALTER TABLE dbo.UPRMATCHREVIEW_Q DROP CONSTRAINT FK_UPRMATCHREVIEW_Q_XREF;

IF EXISTS (
    SELECT 1
    FROM sys.columns c
    WHERE c.object_id = OBJECT_ID(N'dbo.UPRMATCHREVIEW_Q')
      AND c.name = N'UPropertyRecords_XrefID'
      AND c.is_nullable = 0
)
    ALTER TABLE dbo.UPRMATCHREVIEW_Q ALTER COLUMN UPropertyRecords_XrefID INT NULL;

IF NOT EXISTS (
    SELECT 1
    FROM sys.foreign_keys fk
    WHERE fk.parent_object_id = OBJECT_ID(N'dbo.UPRMATCHREVIEW_Q')
      AND fk.name = N'FK_UPRMATCHREVIEW_Q_XREF'
)
    ALTER TABLE dbo.UPRMATCHREVIEW_Q ADD CONSTRAINT FK_UPRMATCHREVIEW_Q_XREF
        FOREIGN KEY (UPropertyRecords_XrefID)
        REFERENCES dbo.UPropertyRecords_XREF (UPropertyRecords_XrefID);

PRINT N'Review_Q verified: MA/SDAT columns present; UPropertyRecords_XrefID nullable.';
