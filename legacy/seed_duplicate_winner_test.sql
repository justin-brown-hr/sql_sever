/*
  Regression seed: duplicate account+address where rank-1 loses parcel UQ guard
  and rank-2 (fully valid) should win UPR after load_upr_master.sql fix.

  Scenario:
    - Two SDAT rows, same account + normalized address, different parcels
    - Parcel P-DUP-A is shared with a third row (forces BatchParcelRn > 1 on rank-1)
    - Parcel P-DUP-B is unique — promoted winner after UQ guard

  Expected after load:
    - 1 UPR row for account 88888001 / 888 MAIN STREET
    - 1 Review_Q DUPLICATE for the loser SDAT row
    - NOT both rows in Review_Q
*/
USE DHCA_Internal;
GO
SET NOCOUNT ON;

DELETE FROM dbo.RealPropertyTaxInformation
WHERE AccountNumber IN (N'88888001', N'88888002', N'88888003');
GO

INSERT INTO dbo.RealPropertyTaxInformation (
    RealPropertyTaxInformationID, AccountNumber, Parcel,
    PremisesNumber, PremisesStreetName, PremisesStreetType,
    PremisesCity, PremisesState, PremisesZipCode,
    Owner, YearBuilt, DwellingUnits
)
VALUES
/* Unique account — holds parcel P-DUP-A so duplicate rank-1 collides on parcel key */
(99001, N'88888002', N'P-DUP-A', N'777', N'OTHER', N'ST', N'ROCKVILLE', N'MD', N'20850', N'Parcel Holder', 1990, 1),
/* Duplicate pair — same account+address */
(99002, N'88888001', N'P-DUP-A', N'888', N'MAIN', N'ST', N'ROCKVILLE', N'MD', N'20850', N'Dup Owner A', 1991, 2),
(99003, N'88888001', N'P-DUP-B', N'888', N'MAIN', N'ST', N'ROCKVILLE', N'MD', N'20850', N'Dup Owner B', 1992, 3);
GO

PRINT N'seed_duplicate_winner_test: inserted 3 SDAT rows (88888001 duplicate pair + parcel collision).';
GO
