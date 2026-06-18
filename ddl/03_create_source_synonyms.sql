/*
    Source synonyms for UPR load script
    Run ONCE per environment in UPRDB_Test (edit database names if yours differ).

    After running:
      - load_upr_master.sql uses dbo.src_* instead of 3-part names
      - SSMS IntelliSense "could not be bound" red lines go away (Edit > IntelliSense > Refresh Local Cache)

    Required: login must have SELECT on source tables in each database.
*/
USE UPRDB_Test;
GO

IF OBJECT_ID(N'dbo.src_MasterAddress', N'SN') IS NOT NULL DROP SYNONYM dbo.src_MasterAddress;
IF OBJECT_ID(N'dbo.src_RealPropertyTaxInformation', N'SN') IS NOT NULL DROP SYNONYM dbo.src_RealPropertyTaxInformation;
IF OBJECT_ID(N'dbo.src_eProperty', N'SN') IS NOT NULL DROP SYNONYM dbo.src_eProperty;
IF OBJECT_ID(N'dbo.src_Case', N'SN') IS NOT NULL DROP SYNONYM dbo.src_Case;
IF OBJECT_ID(N'dbo.src_MPDU_Development', N'SN') IS NOT NULL DROP SYNONYM dbo.src_MPDU_Development;
IF OBJECT_ID(N'dbo.src_MultifamilyAddress', N'SN') IS NOT NULL DROP SYNONYM dbo.src_MultifamilyAddress;
GO

CREATE SYNONYM dbo.src_MasterAddress
    FOR DHCA_Internal.dbo.MasterAddress;

CREATE SYNONYM dbo.src_RealPropertyTaxInformation
    FOR DHCA_Internal.dbo.RealPropertyTaxInformation;

CREATE SYNONYM dbo.src_eProperty
    FOR DHCA_LicensingAndRegistration.dbo.Property;

CREATE SYNONYM dbo.src_Case
    FOR DHCA_OLTA.dbo.[Case];

CREATE SYNONYM dbo.src_MPDU_Development
    FOR DHCA_MPDU.dbo.Development;

CREATE SYNONYM dbo.src_MultifamilyAddress
    FOR DHCA_MultifamilyLoans.dbo.Address;
GO

PRINT N'Source synonyms created in UPRDB_Test. Refresh SSMS IntelliSense (Ctrl+Shift+R) if red underlines remain.';
