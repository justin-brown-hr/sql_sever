/* Smoke test for dbo.usp_UPR_Search against the hierarchical model. */
USE UPRXDB_TEST;
GO
SET NOCOUNT ON;
GO
PRINT '--- 1. by account number';
EXEC dbo.usp_UPR_Search @AccountNumber = '00272531';
PRINT '--- 2. by entity type Complex';
EXEC dbo.usp_UPR_Search @EntityType = 'Complex';
PRINT '--- 3. city + entity type';
EXEC dbo.usp_UPR_Search @City = 'ROCKVILLE', @EntityType = 'Unit', @MaxRows = 5;
PRINT '--- 4. no parameters at all';
EXEC dbo.usp_UPR_Search @MaxRows = 3;
PRINT '--- 5. review queue only';
EXEC dbo.usp_UPR_Search @IncludeReviewQOnly = 1, @MaxRows = 3;
PRINT '--- 6. owner name';
EXEC dbo.usp_UPR_Search @OwnerName = 'BETHESDA';
PRINT '--- 7. street + zip';
EXEC dbo.usp_UPR_Search @StreetName = 'GLENMONT', @ZipCode = '20902', @MaxRows = 10;
GO
