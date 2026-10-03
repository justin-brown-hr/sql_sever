/* Read-only diagnostic: select the intended client test database in SSMS first.
   This checks the loader's table/column names and returns the physical layout.
   It does not execute the load or certify data, permissions, types or triggers.
   Save all result sets; resolve CORE_MISSING before running the loader. */
SET NOCOUNT ON;
SELECT @@SERVERNAME AS ServerName,DB_NAME() AS DatabaseName,
    SERVERPROPERTY('ProductVersion') AS ProductVersion,
    d.compatibility_level AS CompatibilityLevel
FROM sys.databases d WHERE d.database_id=DB_ID();

DECLARE @Expected TABLE(TableName SYSNAME,ColumnName SYSNAME,Requirement VARCHAR(30));
INSERT @Expected(TableName,ColumnName,Requirement) VALUES
    (N'REF_ENTITYTYPE',N'EntityTypeID',N'CORE'),
    (N'REF_ENTITYTYPE',N'Description',N'CORE'),
    (N'REF_PROPERTYTYPE',N'PropertyTypeID',N'CORE'),
    (N'REF_PROPERTYTYPE',N'PropertyTypeCode',N'CORE'),
    (N'REF_PROPERTYTYPE',N'PropertyTypeName',N'CORE'),
    (N'REF_PROPERTYTYPE',N'AllowsBuildings',N'CORE'),
    (N'REF_PROPERTYTYPE',N'AllowsUnits',N'CORE'),
    (N'REF_PROPERTYTYPE',N'DeletedInd',N'CORE'),
    (N'REF_PROPERTYTYPE',N'CreationUserID',N'CORE'),
    (N'REF_PROPERTYTYPE',N'CreationDate',N'CORE'),
    (N'REF_PROPERTYTYPE',N'LastUpdatedUserID',N'CORE'),
    (N'REF_PROPERTYTYPE',N'LastUpdatedDate',N'CORE'),
    (N'REF_CONTACTTYPE',N'ContactTypeID',N'CORE'),
    (N'REF_CONTACTTYPE',N'ContactTypeCode',N'CORE'),
    (N'REF_CONTACTTYPE',N'Description',N'CORE'),
    (N'REF_ROLETYPE',N'RoleTypeID',N'CORE'),
    (N'REF_ROLETYPE',N'RoleTypeCode',N'CORE'),
    (N'REF_ROLETYPE',N'Description',N'CORE'),
    (N'REF_ADDRESSROLE',N'AddressRoleID',N'CORE'),
    (N'REF_ADDRESSROLE',N'AddressRoleCode',N'CORE'),
    (N'REF_ADDRESSROLE',N'Description',N'CORE'),
    (N'UPR',N'UPRID',N'CORE'),
    (N'UPR',N'ParentUPRID',N'CORE'),
    (N'UPR',N'EntityTypeID',N'CORE'),
    (N'UPR',N'AccountNumber',N'CORE'),
    (N'UPR',N'StatusCode',N'CORE'),
    (N'UPR',N'CreatedBy',N'CORE'),
    (N'UPR',N'UpdatedDate',N'CORE'),
    (N'UPR',N'UpdatedBy',N'CORE'),
    (N'ADDRESS',N'AddressID',N'CORE'),
    (N'ADDRESS',N'StreetNumber',N'CORE'),
    (N'ADDRESS',N'StreetName',N'CORE'),
    (N'ADDRESS',N'StreetType',N'CORE'),
    (N'ADDRESS',N'City',N'CORE'),
    (N'ADDRESS',N'State',N'CORE'),
    (N'ADDRESS',N'ZipCode',N'CORE'),
    (N'ADDRESS',N'NormalizedAddress',N'CORE'),
    (N'ADDRESS',N'YCoordinate',N'CORE'),
    (N'ADDRESS',N'XCoordinate',N'CORE'),
    (N'COMPLEX',N'UPRID',N'CORE'),
    (N'COMPLEX',N'CommunityName',N'CORE'),
    (N'COMPLEX',N'PropertyTypeID',N'CORE'),
    (N'COMPLEX',N'StatusCode',N'CORE'),
    (N'COMPLEX',N'CreatedBy',N'CORE'),
    (N'PROPERTY',N'UPRID',N'CORE'),
    (N'PROPERTY',N'PropertyTypeID',N'CORE'),
    (N'PROPERTY',N'PropertyName',N'CORE'),
    (N'PROPERTY',N'OwnerName',N'CORE'),
    (N'PROPERTY',N'Parcel',N'CORE'),
    (N'PROPERTY',N'StatusCode',N'CORE'),
    (N'CONDO',N'UPRID',N'CORE'),
    (N'CONDO',N'OwnerName',N'CORE'),
    (N'CONDO',N'StatusCode',N'CORE'),
    (N'BUILDING',N'BuildingID',N'CORE'),
    (N'BUILDING',N'UPRID',N'CORE'),
    (N'BUILDING',N'BuildingName',N'CORE'),
    (N'BUILDING',N'YearBuilt',N'CORE'),
    (N'BUILDING',N'StatusCode',N'CORE'),
    (N'BUILDING',N'UpdatedDate',N'CORE'),
    (N'UNIT',N'UPRID',N'CORE'),
    (N'UNIT',N'BuildingID',N'CORE'),
    (N'UNIT',N'UnitNumber',N'CORE'),
    (N'UNIT',N'UnitTypeCode',N'CORE'),
    (N'UNIT',N'FloorNumber',N'CORE'),
    (N'UNIT',N'BedroomCount',N'CORE'),
    (N'UNIT',N'BathroomCount',N'CORE'),
    (N'UNIT',N'HasLegalIdentity',N'CORE'),
    (N'UNIT',N'StatusCode',N'CORE'),
    (N'UNIT',N'UpdatedDate',N'CORE'),
    (N'UPR_ADDRESS',N'UPRAddressID',N'CORE'),
    (N'UPR_ADDRESS',N'UPRID',N'CORE'),
    (N'UPR_ADDRESS',N'AddressID',N'CORE'),
    (N'UPR_ADDRESS',N'AddressRoleID',N'CORE'),
    (N'UPR_ADDRESS',N'IsPrimary',N'CORE'),
    (N'UPR_ADDRESS',N'EffectiveDate',N'CORE'),
    (N'UPR_ADDRESS',N'EndDate',N'CORE'),
    (N'EXTERNAL_IDENTIFIER_XREF',N'ExternalIdentifierID',N'CORE'),
    (N'EXTERNAL_IDENTIFIER_XREF',N'UPRID',N'CORE'),
    (N'EXTERNAL_IDENTIFIER_XREF',N'SourceSystem',N'CORE'),
    (N'EXTERNAL_IDENTIFIER_XREF',N'IdentifierType',N'CORE'),
    (N'EXTERNAL_IDENTIFIER_XREF',N'IdentifierValue',N'CORE'),
    (N'CONTACT',N'ContactID',N'CORE'),
    (N'CONTACT',N'ContactTypeID',N'CORE'),
    (N'CONTACT',N'OrganizationName',N'CORE'),
    (N'CONTACT',N'StatusCode',N'CORE'),
    (N'UPR_CONTACT',N'UPRID',N'CORE'),
    (N'UPR_CONTACT',N'ContactID',N'CORE'),
    (N'UPR_CONTACT',N'RoleTypeID',N'CORE'),
    (N'UPR_CONTACT',N'EffectiveDate',N'CORE'),
    (N'UPR_CONTACT',N'EndDate',N'CORE'),
    (N'UPRMATCHREVIEW_Q',N'UPRID',N'CORE'),
    (N'UPRMATCHREVIEW_Q',N'IncomingSourceSystem',N'CORE'),
    (N'UPRMATCHREVIEW_Q',N'SDAT_NormalizedIncomingAddress',N'CORE'),
    (N'UPRMATCHREVIEW_Q',N'MA_NormalizedIncomingAddress',N'CORE'),
    (N'UPRMATCHREVIEW_Q',N'SDAT_ParcelID',N'CORE'),
    (N'UPRMATCHREVIEW_Q',N'MA_ParcelID',N'CORE'),
    (N'UPRMATCHREVIEW_Q',N'SDAT_AccountNumber',N'CORE'),
    (N'UPRMATCHREVIEW_Q',N'MA_Account',N'CORE'),
    (N'UPRMATCHREVIEW_Q',N'ReasonForNoMatch',N'CORE'),
    (N'UPRMATCHREVIEW_Q',N'ProcessingTimestamp',N'CORE'),
    (N'UPRMATCHREVIEW_Q',N'ReviewStatus',N'CORE'),
    (N'UPRMATCHREVIEW_Q',N'Decision',N'CORE'),
    (N'UPRSTATUSHISTORY',N'UPRID',N'CORE'),
    (N'UPRSTATUSHISTORY',N'SDATAccountNumber',N'CORE'),
    (N'UPRSTATUSHISTORY',N'OldStatusCode',N'CORE'),
    (N'UPRSTATUSHISTORY',N'NewStatusCode',N'CORE'),
    (N'UPRSTATUSHISTORY',N'ChangeReason',N'CORE'),
    (N'UPRSTATUSHISTORY',N'ParcelID',N'CORE'),
    (N'UPRSTATUSHISTORY',N'Owner',N'CORE'),
    (N'UPRSTATUSHISTORY',N'PropertyTypeCode',N'CORE'),
    (N'UPRSTATUSHISTORY',N'ChangeSource',N'CORE'),
    (N'UPRSTATUSHISTORY',N'ChangedBy',N'CORE'),
    (N'UPRSTATUSHISTORY',N'ChangedDate',N'CORE'),
    (N'UPRSTATUSHISTORY',N'Notes',N'CORE'),
    (N'UPRSTATUSHISTORY',N'BuildingID',N'CORE'),
    (N'MAIncomingTableX1',N'MasterAddressID',N'CORE'),
    (N'MAIncomingTableX1',N'Account',N'CORE'),
    (N'MAIncomingTableX1',N'ParcelNumber',N'CORE'),
    (N'MAIncomingTableX1',N'StreetNumber',N'CORE'),
    (N'MAIncomingTableX1',N'StreetName',N'CORE'),
    (N'MAIncomingTableX1',N'StreetType',N'CORE'),
    (N'MAIncomingTableX1',N'Unit',N'CORE'),
    (N'MAIncomingTableX1',N'City',N'CORE'),
    (N'MAIncomingTableX1',N'ZipCode',N'CORE'),
    (N'MAIncomingTableX1',N'LUCategory',N'CORE'),
    (N'MAIncomingTableX1',N'XCoordinate',N'CORE'),
    (N'MAIncomingTableX1',N'YCoordinate',N'CORE'),
    (N'SDATIncomingTableX1',N'RealPropertyTaxInformationID',N'CORE'),
    (N'SDATIncomingTableX1',N'AccountNumber',N'CORE'),
    (N'SDATIncomingTableX1',N'Parcel',N'CORE'),
    (N'SDATIncomingTableX1',N'Owner',N'CORE'),
    (N'SDATIncomingTableX1',N'YearBuilt',N'CORE'),
    (N'SDATIncomingTableX1',N'DwellingUnits',N'CORE'),
    (N'SDATIncomingTableX1',N'PremisesNumber',N'CORE'),
    (N'SDATIncomingTableX1',N'PremisesStreetName',N'CORE'),
    (N'SDATIncomingTableX1',N'PremisesStreetType',N'CORE'),
    (N'SDATIncomingTableX1',N'PremisesCity',N'CORE'),
    (N'SDATIncomingTableX1',N'PremisesState',N'CORE'),
    (N'SDATIncomingTableX1',N'PremisesZipCode',N'CORE'),
    (N'SDATIncomingTableX1',N'CondoUnit',N'LOADER_ADDS_IF_ABSENT'),
    (N'UPR_CLOSURE',N'AncestorUPRID',N'CORE'),
    (N'UPR_CLOSURE',N'DescendantUPRID',N'CORE'),
    (N'UPR_CLOSURE',N'Level',N'LOADER_ADDS_IF_ABSENT'),
    (N'AuditLog',N'AuditID',N'CORE'),
    (N'AuditLog',N'UPRID',N'CORE'),
    (N'AuditLog',N'EntityNameID',N'CORE'),
    (N'AuditLog',N'EntityRecordID',N'CORE'),
    (N'AuditLog',N'OperationType',N'CORE'),
    (N'AuditLog',N'ChangedBy',N'CORE'),
    (N'AuditLog',N'ChangedDate',N'CORE'),
    (N'AuditLog',N'OldValues',N'CORE'),
    (N'AuditLog',N'NewValues',N'CORE'),
    (N'REF_ENTITY_IDENTIFICATION',N'EntityID',N'CORE'),
    (N'REF_ENTITY_IDENTIFICATION',N'EntityName',N'CORE'),
    (N'AUDIT_LOG_CONTEXT',N'AuditID',N'OPTIONAL_EXTENSION'),
    (N'AUDIT_LOG_CONTEXT',N'EntityKey',N'OPTIONAL_EXTENSION'),
    (N'AUDIT_LOG_CONTEXT',N'RunID',N'OPTIONAL_EXTENSION'),
    (N'AUDIT_LOG_CONTEXT',N'SessionID',N'OPTIONAL_EXTENSION'),
    (N'AUDIT_LOG_CONTEXT',N'ChangeSummary',N'OPTIONAL_EXTENSION'),
    (N'UPR_CONDO_LEGACY',N'UPRID',N'OPTIONAL_EXTENSION'),
    (N'UPR_CONDO_LEGACY',N'CondoName',N'OPTIONAL_EXTENSION'),
    (N'UPR_LOAD_RUN',N'RunID',N'OPTIONAL_EXTENSION'),
    (N'UPR_LOAD_RUN',N'RunStatus',N'OPTIONAL_EXTENSION'),
    (N'UPR_LOAD_RUN',N'StartedAt',N'OPTIONAL_EXTENSION'),
    (N'UPR_LOAD_RUN',N'FinishedAt',N'OPTIONAL_EXTENSION'),
    (N'UPR_LOAD_RUN',N'StartedBy',N'OPTIONAL_EXTENSION'),
    (N'UPR_LOAD_RUN',N'SessionID',N'OPTIONAL_EXTENSION'),
    (N'UPR_LOAD_RUN',N'SourceRowsRead',N'OPTIONAL_EXTENSION'),
    (N'UPR_LOAD_RUN',N'RejectedRows',N'OPTIONAL_EXTENSION'),
    (N'UPR_LOAD_RUN',N'ErrorMessage',N'OPTIONAL_EXTENSION');

SELECT e.TableName,e.ColumnName,e.Requirement,
    CASE WHEN c.column_id IS NOT NULL THEN N'PRESENT'
         WHEN e.Requirement='LOADER_ADDS_IF_ABSENT' AND t.object_id IS NOT NULL
              THEN N'ADDED BY COMPLETE LOADER'
         WHEN e.Requirement='OPTIONAL_EXTENSION' AND t.object_id IS NULL
              THEN N'OPTIONAL: ABSENCE SUPPORTED'
         WHEN e.Requirement='OPTIONAL_EXTENSION' THEN N'REVIEW INCOMPLETE EXTENSION'
         ELSE N'CORE_MISSING OR NOT VISIBLE' END AS MetadataStatus,
    TYPE_NAME(c.user_type_id) AS DataType,c.is_nullable AS IsNullable
FROM @Expected e
LEFT JOIN sys.tables t ON t.schema_id=SCHEMA_ID(N'dbo') AND t.name=e.TableName
LEFT JOIN sys.columns c ON c.object_id=t.object_id AND c.name=e.ColumnName
ORDER BY e.Requirement,e.TableName,e.ColumnName;

SELECT SchemaNameCheck=CASE WHEN COUNT(*)=0 THEN N'PASS: required names visible'
    ELSE N'STOP: resolve missing core objects/columns before loading' END,
    MissingCoreColumns=COUNT(*)
FROM @Expected e
LEFT JOIN sys.tables t ON t.schema_id=SCHEMA_ID(N'dbo') AND t.name=e.TableName
LEFT JOIN sys.columns c ON c.object_id=t.object_id AND c.name=e.ColumnName
WHERE (e.Requirement='CORE' AND c.column_id IS NULL)
   OR (e.Requirement='LOADER_ADDS_IF_ABSENT' AND t.object_id IS NULL);

-- Return all actual columns, including additional required columns/defaults.
SELECT t.name AS TableName,c.column_id,c.name AS ColumnName,TYPE_NAME(c.system_type_id) AS DataType,
    c.max_length,c.[precision],c.scale,c.is_nullable,c.is_identity,c.is_computed,
    d.[definition] AS DefaultDefinition
FROM sys.tables t JOIN sys.columns c ON c.object_id=t.object_id
LEFT JOIN sys.default_constraints d ON d.object_id=c.default_object_id
WHERE t.schema_id=SCHEMA_ID(N'dbo') AND EXISTS(SELECT 1 FROM @Expected e WHERE e.TableName=t.name)
ORDER BY t.name,c.column_id;

-- Optional compatibility view is not required by the main loader.
SELECT o.name,o.type_desc FROM sys.objects o WHERE o.schema_id=SCHEMA_ID(N'dbo')
    AND o.name IN(N'AuditLog',N'AUDIT_LOG',N'AUDIT_LOG_CONTEXT',N'AuditLog_PreSept17',N'AUDIT_LOG_PreClientLayout');

SELECT t.name AS TriggerName,OBJECT_NAME(t.parent_id) AS TableName,t.is_disabled,
    OBJECT_DEFINITION(t.object_id) AS TriggerDefinition
FROM sys.triggers t WHERE t.parent_class=1 AND OBJECT_SCHEMA_NAME(t.parent_id)=N'dbo'
ORDER BY TableName,TriggerName;

SELECT OBJECT_NAME(parent_object_id) AS TableName,name,[definition],is_disabled,is_not_trusted
FROM sys.check_constraints
WHERE EXISTS(SELECT 1 FROM @Expected e WHERE OBJECT_ID(N'dbo.'+e.TableName)=parent_object_id);
