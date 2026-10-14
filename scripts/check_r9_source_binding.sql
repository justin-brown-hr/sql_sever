/* READ ONLY: R9 source binding check - 2026-10-09.
   Select the intended CLIENT TEST DATABASE in SSMS before running this file.
   No USE statement: does not switch to the project's default UPRXDB_TEST.
   Run in UPR6XDB_TEST if that is the intended database shown in the screenshots.
   Returns metadata and zero-row compilation checks only. No table/data changes.
   Send all result grids, including the first ServerName/DatabaseName result.
*/
SET NOCOUNT ON;
SELECT @@SERVERNAME AS ServerName,DB_NAME() AS DatabaseName,
    SUSER_SNAME() AS LoginName,N'R9 default USE is UPRXDB_TEST; verify it matches the intended target before loading' AS ContextCheck;
DECLARE @Expected TABLE(TableName SYSNAME,ColumnName SYSNAME);
INSERT @Expected VALUES
(N'MAIncomingTableX1',N'Account'),(N'MAIncomingTableX1',N'City'),(N'MAIncomingTableX1',N'LUCategory'),(N'MAIncomingTableX1',N'MasterAddressID'),(N'MAIncomingTableX1',N'ParcelNumber'),(N'MAIncomingTableX1',N'StreetName'),(N'MAIncomingTableX1',N'StreetNumber'),(N'MAIncomingTableX1',N'StreetType'),(N'MAIncomingTableX1',N'Unit'),(N'MAIncomingTableX1',N'XCoordinate'),(N'MAIncomingTableX1',N'YCoordinate'),(N'MAIncomingTableX1',N'ZipCode'),
(N'SDATIncomingTableX1',N'AccountNumber'),(N'SDATIncomingTableX1',N'CondoUnit'),(N'SDATIncomingTableX1',N'DwellingUnits'),(N'SDATIncomingTableX1',N'Owner'),(N'SDATIncomingTableX1',N'Parcel'),(N'SDATIncomingTableX1',N'PremisesCity'),(N'SDATIncomingTableX1',N'PremisesNumber'),(N'SDATIncomingTableX1',N'PremisesState'),(N'SDATIncomingTableX1',N'PremisesStreetName'),(N'SDATIncomingTableX1',N'PremisesStreetType'),(N'SDATIncomingTableX1',N'PremisesZipCode'),(N'SDATIncomingTableX1',N'RealPropertyTaxInformationID'),(N'SDATIncomingTableX1',N'YearBuilt');
SELECT e.TableName,e.ColumnName,
    CASE WHEN OBJECT_ID(N'dbo.'+QUOTENAME(e.TableName)) IS NULL THEN N'OBJECT MISSING OR NOT VISIBLE'
         WHEN COL_LENGTH(N'dbo.'+QUOTENAME(e.TableName),e.ColumnName) IS NULL THEN N'COLUMN MISSING OR NOT VISIBLE'
         ELSE N'VISIBLE' END AS MetadataStatus
FROM @Expected e ORDER BY e.TableName,e.ColumnName;
/* Show matching names and ID columns in this database, including views/synonyms.
   These are possible mappings for review, not automatic source substitutions. */
SELECT SCHEMA_NAME(o.schema_id) AS SchemaName,o.name AS ObjectName,o.type_desc AS ObjectType,
    sy.base_object_name AS SynonymTarget,c.name AS ColumnName,TYPE_NAME(c.user_type_id) AS ColumnType
FROM sys.objects o LEFT JOIN sys.columns c ON c.object_id=o.object_id
LEFT JOIN sys.synonyms sy ON sy.object_id=o.object_id
WHERE o.is_ms_shipped=0 AND o.type IN('U','V','SN')
  AND (o.name IN(N'MAIncomingTableX1',N'SDATIncomingTableX1')
       OR o.name LIKE N'%Incoming%' OR c.name IN(N'MasterAddressID',N'RealPropertyTaxInformationID'))
ORDER BY SchemaName,ObjectName,c.column_id;
DECLARE @Probe TABLE(SourceTable SYSNAME,BindingResult NVARCHAR(30),ErrorNumber INT NULL,ErrorMessage NVARCHAR(4000) NULL);
BEGIN TRY
    EXEC sys.sp_executesql N'SELECT TOP(0) ma.[Account],ma.[City],ma.[LUCategory],ma.[MasterAddressID],ma.[ParcelNumber],ma.[StreetName],ma.[StreetNumber],ma.[StreetType],ma.[Unit],ma.[XCoordinate],ma.[YCoordinate],ma.[ZipCode] FROM dbo.[MAIncomingTableX1] AS ma;';
    INSERT @Probe VALUES(N'MAIncomingTableX1',N'ENGINE BINDING PASSED',NULL,NULL);
END TRY
BEGIN CATCH
    INSERT @Probe VALUES(N'MAIncomingTableX1',N'ENGINE BINDING FAILED',ERROR_NUMBER(),ERROR_MESSAGE());
END CATCH;
BEGIN TRY
    EXEC sys.sp_executesql N'SELECT TOP(0) s.[AccountNumber],s.[CondoUnit],s.[DwellingUnits],s.[Owner],s.[Parcel],s.[PremisesCity],s.[PremisesNumber],s.[PremisesState],s.[PremisesStreetName],s.[PremisesStreetType],s.[PremisesZipCode],s.[RealPropertyTaxInformationID],s.[YearBuilt] FROM dbo.[SDATIncomingTableX1] AS s;';
    INSERT @Probe VALUES(N'SDATIncomingTableX1',N'ENGINE BINDING PASSED',NULL,NULL);
END TRY
BEGIN CATCH
    INSERT @Probe VALUES(N'SDATIncomingTableX1',N'ENGINE BINDING FAILED',ERROR_NUMBER(),ERROR_MESSAGE());
END CATCH;
SELECT * FROM @Probe ORDER BY SourceTable;
SELECT CASE WHEN EXISTS(SELECT 1 FROM @Probe WHERE ErrorNumber IS NOT NULL)
    THEN N'Source binding is unresolved. Confirm the actual database/schema/table/column names and permissions before running the loader.'
    ELSE N'Both source projections bind in this database. This does not verify loader execution; editor warnings may be stale or use a different context.' END AS NextStep;
/* CondoUnit is included because the main source query reads it. R9 can add that
   column earlier when absent; this diagnostic intentionally makes no changes. */
