/*
    Reference data seed - from Incoming_Test_Data.docx
    Run after ddl/01_create_schema.sql
*/
USE UPR_Master;
GO

SET NOCOUNT ON;

/* REF_PROPERTYTYPE */
IF NOT EXISTS (SELECT 1 FROM dbo.REF_PROPERTYTYPE)
INSERT INTO dbo.REF_PROPERTYTYPE (PropertyTypeCode, PropertyTypeName, AllowsBuildings, AllowsUnits, DeletedInd, CreationUSERID, LastUpdatedUserID)
VALUES
(N'APT',   N'Apartment Complex',     1, 1, 0, N'SYSTEM', N'SYSTEM'),
(N'CONDO', N'Condominium Property',  1, 1, 0, N'SYSTEM', N'SYSTEM'),
(N'TH',    N'Townhouse Community',   1, 1, 0, N'SYSTEM', N'SYSTEM'),
(N'MULTI', N'Multi-Family Property', 1, 1, 0, N'SYSTEM', N'SYSTEM'),
(N'SF',    N'Single Family Property',1, 0, 0, N'SYSTEM', N'SYSTEM'),
(N'LAND',  N'Vacant Land',           0, 0, 0, N'SYSTEM', N'SYSTEM'),
(N'MIXED', N'Mixed Use Property',    1, 1, 0, N'SYSTEM', N'SYSTEM');

/* REF_STATUSCODE_Property */
IF NOT EXISTS (SELECT 1 FROM dbo.REF_STATUSCODE_Property)
INSERT INTO dbo.REF_STATUSCODE_Property (StatusCode, [Description])
VALUES
(N'ACTIVE',       N'Active'),
(N'INACTIVE',     N'Inactive'),
(N'PENDING',       N'Pending'),
(N'RETIRED',       N'Retired'),
(N'UNDER_REVIEW',  N'Under review'),
(N'MERGED',        N'Merged'),
(N'SPLIT',         N'Split'),
(N'REJECTED',      N'Rejected');

/* REF_SOURCESYSTEM */
IF NOT EXISTS (SELECT 1 FROM dbo.REF_SOURCESYSTEM)
INSERT INTO dbo.REF_SOURCESYSTEM (SourceSystemCode, SourceSystemName, [Description])
VALUES
(N'ADDRESS_MASTER', N'Address Master',      N'Incoming AddressMaster'),
(N'KDAT',           N'KDAT',                N'Incoming SDAT/KDAT'),
(N'eProperty',      N'eProperty',            N'Licensing property'),
(N'CASE',           N'CASE',                N'Enforcement case'),
(N'MPDU',           N'MPDU',                N'MPDU development'),
(N'MULTIFAMILY',    N'Multifamily loans',   N'Multifamily loan address');

/* REF_MATCHMETHOD */
IF NOT EXISTS (SELECT 1 FROM dbo.REF_MATCHMETHOD)
INSERT INTO dbo.REF_MATCHMETHOD (MatchMethodCode, MatchMethodName, [Description])
VALUES
(N'ParcelID',          N'Parcel match',        N'Exact parcel'),
(N'SDATAccount',       N'Tax/Account match',   N'Exact account / tax id'),
(N'AddressExact',      N'Exact address',       N'Exact normalized match'),
(N'AddressNormalized', N'Normalized address',  N'Normalized composite'),
(N'GISProximity',      N'GIS proximity',       N'Coordinate proximity'),
(N'Manual',            N'Manual',              N'Steward confirmed');

/* REF_MATCHCONFIDENCE */
IF NOT EXISTS (SELECT 1 FROM dbo.REF_MATCHCONFIDENCE)
INSERT INTO dbo.REF_MATCHCONFIDENCE (MatchConfidenceCode, MatchConfidenceName, ConfidenceRank, [Description], CreatedDate, UpdatedDate)
VALUES
(N'HIGH',     N'High',     100, N'Very reliable', SYSDATETIME(), SYSDATETIME()),
(N'MEDIUM',   N'Medium',    75, N'Likely',         SYSDATETIME(), SYSDATETIME()),
(N'LOW',      N'Low',       55, N'Uncertain',      SYSDATETIME(), SYSDATETIME()),
(N'VERIFIED', N'Verified', 110, N'Human verified', SYSDATETIME(), SYSDATETIME()),
(N'NONE',     N'None',       0, N'No confidence assigned', SYSDATETIME(), SYSDATETIME());

/* REF_BUILDINGTYPE */
IF NOT EXISTS (SELECT 1 FROM dbo.REF_BUILDINGTYPE)
INSERT INTO dbo.REF_BUILDINGTYPE (BuildingTypeCode, BuildingTypeName, [Description], IsResidential, IsActive)
VALUES (N'MAIN', N'Main building', N'Default main structure', 1, 1);

/* REF_UNITTYPECODE */
IF NOT EXISTS (SELECT 1 FROM dbo.REF_UNITTYPECODE)
INSERT INTO dbo.REF_UNITTYPECODE (UnitTypeCode, UnitTypeName, [Description])
VALUES
(N'APT',  N'Apartment unit', N'Apartment'),
(N'COND', N'Condo unit',     N'Condominium unit');

/* REF_STATUSCODE_Unit */
IF NOT EXISTS (SELECT 1 FROM dbo.REF_STATUSCODE_Unit)
INSERT INTO dbo.REF_STATUSCODE_Unit (StatusCode, EntityType, StatusName, [Description])
VALUES (N'ACTIVE', N'UNIT', N'Active', N'Active unit');

GO
PRINT 'Reference data seeded.';
GO
