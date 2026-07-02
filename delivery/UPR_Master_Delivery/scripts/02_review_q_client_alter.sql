/*
  Review_Q preflight — run ONCE on target database before load (optional).
  Verifies client UPRMATCHREVIEW_Q column names used by load_upr_master.sql.
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

PRINT N'Review_Q verified: MA_Account, MA_NormalizedIncomingAddress, MA_ParcelID, SDAT_AccountNumber, SDAT_NormalizedIncomingAddress, SDAT_ParcelID.';
