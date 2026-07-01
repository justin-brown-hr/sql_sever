/*
  Review_Q preflight — run ONCE on target database before load (optional).
  The load script uses ONLY columns that exist on dbo.UPRMATCHREVIEW_Q.
  Do NOT add MA_Account / SDAT_Address columns here — use client Review_Q DDL as-is.
*/
SET NOCOUNT ON;

IF OBJECT_ID(N'dbo.UPRMATCHREVIEW_Q', N'U') IS NULL
BEGIN
    RAISERROR(N'dbo.UPRMATCHREVIEW_Q not found.', 16, 1);
    RETURN;
END;

IF COL_LENGTH('dbo.UPRMATCHREVIEW_Q', 'IncomingSourceSystem') IS NULL
   OR COL_LENGTH('dbo.UPRMATCHREVIEW_Q', 'NormalizedIncomingAddress') IS NULL
   OR COL_LENGTH('dbo.UPRMATCHREVIEW_Q', 'SDATAccountNumber') IS NULL
   OR COL_LENGTH('dbo.UPRMATCHREVIEW_Q', 'ReasonForNoMatch') IS NULL
   OR COL_LENGTH('dbo.UPRMATCHREVIEW_Q', 'ReviewStatus') IS NULL
BEGIN
    RAISERROR(N'UPRMATCHREVIEW_Q missing core columns. Recreate from client DDL.', 16, 1);
    RETURN;
END;

PRINT N'Review_Q core columns verified (IncomingSourceSystem, NormalizedIncomingAddress, SDATAccountNumber, ReasonForNoMatch, ReviewStatus).';
