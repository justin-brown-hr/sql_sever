/*
================================================================================
  UPR Hierarchical Schema (NewUPRTABLEUSED + client Response.docx COMPLEX)
  SQL Server 2016+

  Source of truth: docs/NewUPRTABLEUSED.docx
  COMPLEX table:   docs/Response.docx (was omitted from NewUPRTABLEUSED)

  Replaces the flat UPROPERTYRECORDS model completely.
  Change USE database name to match your environment.
================================================================================
*/
USE UPRXDB_TEST;
GO

/* Required for filtered indexes. SSMS sets these ON, sqlcmd does not:
   without them CREATE INDEX and later INSERTs fail with error 1934. */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET ARITHABORT ON;
SET NUMERIC_ROUNDABORT OFF;
GO

SET NOCOUNT ON;
GO

/* ============================================================================
   DROP ORDER (children first) - safe re-run on empty/test DB
   ============================================================================ */
IF OBJECT_ID(N'dbo.UPRSTATUSHISTORY', N'U') IS NOT NULL DROP TABLE dbo.UPRSTATUSHISTORY;
IF OBJECT_ID(N'dbo.UPRMATCHREVIEW_Q', N'U') IS NOT NULL DROP TABLE dbo.UPRMATCHREVIEW_Q;
IF OBJECT_ID(N'dbo.AuditLog', N'U') IS NOT NULL DROP TABLE dbo.AuditLog;
IF OBJECT_ID(N'dbo.UPR_CLOSURE', N'U') IS NOT NULL DROP TABLE dbo.UPR_CLOSURE;
IF OBJECT_ID(N'dbo.UPR_CONTACT', N'U') IS NOT NULL DROP TABLE dbo.UPR_CONTACT;
IF OBJECT_ID(N'dbo.EXTERNAL_IDENTIFIER_XREF', N'U') IS NOT NULL DROP TABLE dbo.EXTERNAL_IDENTIFIER_XREF;
IF OBJECT_ID(N'dbo.UPR_ADDRESS', N'U') IS NOT NULL DROP TABLE dbo.UPR_ADDRESS;
IF OBJECT_ID(N'dbo.ADU', N'U') IS NOT NULL DROP TABLE dbo.ADU;
IF OBJECT_ID(N'dbo.UNIT', N'U') IS NOT NULL DROP TABLE dbo.UNIT;
IF OBJECT_ID(N'dbo.BUILDING', N'U') IS NOT NULL DROP TABLE dbo.BUILDING;
IF OBJECT_ID(N'dbo.CONDO', N'U') IS NOT NULL DROP TABLE dbo.CONDO;
IF OBJECT_ID(N'dbo.PROPERTY', N'U') IS NOT NULL DROP TABLE dbo.PROPERTY;
IF OBJECT_ID(N'dbo.COMPLEX', N'U') IS NOT NULL DROP TABLE dbo.COMPLEX;
IF OBJECT_ID(N'dbo.ADDRESS', N'U') IS NOT NULL DROP TABLE dbo.ADDRESS;
IF OBJECT_ID(N'dbo.CONTACT', N'U') IS NOT NULL DROP TABLE dbo.CONTACT;
IF OBJECT_ID(N'dbo.UPR', N'U') IS NOT NULL DROP TABLE dbo.UPR;
IF OBJECT_ID(N'dbo.REF_UNITTYPECODE', N'U') IS NOT NULL DROP TABLE dbo.REF_UNITTYPECODE;
IF OBJECT_ID(N'dbo.REF_ADDRESSROLE', N'U') IS NOT NULL DROP TABLE dbo.REF_ADDRESSROLE;
IF OBJECT_ID(N'dbo.REF_ROLETYPE', N'U') IS NOT NULL DROP TABLE dbo.REF_ROLETYPE;
IF OBJECT_ID(N'dbo.REF_CONTACTTYPE', N'U') IS NOT NULL DROP TABLE dbo.REF_CONTACTTYPE;
IF OBJECT_ID(N'dbo.REF_PROPERTY_STATUSCODE', N'U') IS NOT NULL DROP TABLE dbo.REF_PROPERTY_STATUSCODE;
IF OBJECT_ID(N'dbo.REF_PROPERTYTYPE', N'U') IS NOT NULL DROP TABLE dbo.REF_PROPERTYTYPE;
IF OBJECT_ID(N'dbo.REF_ENTITYTYPE', N'U') IS NOT NULL DROP TABLE dbo.REF_ENTITYTYPE;
GO

/* ============================================================================
   1. REF_ENTITYTYPE
   ============================================================================ */
CREATE TABLE dbo.REF_ENTITYTYPE
(
    EntityTypeID INT IDENTITY(1,1) NOT NULL,
    Description  VARCHAR(50) NOT NULL,
    IsActive     BIT NOT NULL CONSTRAINT DF_REF_ENTITYTYPE_IsActive DEFAULT (1),
    CreatedDate  DATETIME2(0) NOT NULL CONSTRAINT DF_REF_ENTITYTYPE_CreatedDate DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_REF_ENTITYTYPE PRIMARY KEY CLUSTERED (EntityTypeID),
    CONSTRAINT UQ_REF_ENTITYTYPE_Description UNIQUE (Description)
);
GO

/* ============================================================================
   2. REF_PROPERTYTYPE
   ============================================================================ */
CREATE TABLE dbo.REF_PROPERTYTYPE
(
    PropertyTypeID    INT IDENTITY(1,1) NOT NULL,
    PropertyTypeCode  NVARCHAR(128) NOT NULL,
    PropertyTypeName  NVARCHAR(128) NOT NULL,
    AllowsBuildings   BIT NOT NULL CONSTRAINT DF_REF_PROPERTYTYPE_AllowsBuildings DEFAULT (0),
    AllowsUnits       BIT NOT NULL CONSTRAINT DF_REF_PROPERTYTYPE_AllowsUnits DEFAULT (0),
    DeletedInd        BIT NOT NULL CONSTRAINT DF_REF_PROPERTYTYPE_DeletedInd DEFAULT (0),
    CreationUserID    NVARCHAR(128) NOT NULL,
    CreationDate      DATETIME2(0) NOT NULL CONSTRAINT DF_REF_PROPERTYTYPE_CreationDate DEFAULT (SYSDATETIME()),
    LastUpdatedUserID NVARCHAR(128) NOT NULL,
    LastUpdatedDate   DATETIME2(0) NOT NULL CONSTRAINT DF_REF_PROPERTYTYPE_LastUpdatedDate DEFAULT (SYSDATETIME()),
    CONSTRAINT PK_REF_PROPERTYTYPE PRIMARY KEY CLUSTERED (PropertyTypeID),
    CONSTRAINT UQ_REF_PROPERTYTYPE_Code UNIQUE (PropertyTypeCode),
    CONSTRAINT CK_REF_PROPERTYTYPE_AllowsBuildings CHECK (AllowsBuildings IN (0,1)),
    CONSTRAINT CK_REF_PROPERTYTYPE_AllowsUnits CHECK (AllowsUnits IN (0,1)),
    CONSTRAINT CK_REF_PROPERTYTYPE_DeletedInd CHECK (DeletedInd IN (0,1)),
    CONSTRAINT CK_REF_PROPERTYTYPE_Dates CHECK (LastUpdatedDate >= CreationDate)
);
GO

/* ============================================================================
   3. REF_PROPERTY_STATUSCODE
   ============================================================================ */
CREATE TABLE dbo.REF_PROPERTY_STATUSCODE
(
    PropertyStatusCodeID INT IDENTITY(1,1) NOT NULL,
    StatusCode           NVARCHAR(30) NOT NULL,
    Description          NVARCHAR(128) NOT NULL,
    DeletedInd           BIT NOT NULL CONSTRAINT DF_REF_Property_STATUSCODE_DeletedInd DEFAULT (0),
    CreationUserID       NVARCHAR(128) NOT NULL,
    CreationDate         DATETIME2(0) NOT NULL CONSTRAINT DF_REF_Property_STATUSCODE_CreationDate DEFAULT (SYSDATETIME()),
    LastUpdatedUserID    NVARCHAR(128) NOT NULL,
    LastUpdatedDate      DATETIME2(0) NOT NULL CONSTRAINT DF_REF_Property_STATUSCODE_LastUpdatedDate DEFAULT (SYSDATETIME()),
    CONSTRAINT PK_REF_PROPERTY_STATUSCODE PRIMARY KEY CLUSTERED (PropertyStatusCodeID),
    CONSTRAINT UQ_REF_Property_STATUSCODE_StatusCode UNIQUE (StatusCode),
    CONSTRAINT CK_REF_Property_STATUSCODE_DeletedInd CHECK (DeletedInd IN (0,1)),
    CONSTRAINT CK_REF_Property_STATUSCODE_Dates CHECK (LastUpdatedDate >= CreationDate)
);
GO

/* ============================================================================
   4. REF_CONTACTTYPE
   ============================================================================ */
CREATE TABLE dbo.REF_CONTACTTYPE
(
    ContactTypeID   INT IDENTITY(1,1) NOT NULL,
    ContactTypeCode VARCHAR(30) NOT NULL,
    Description     VARCHAR(100) NOT NULL,
    IsActive        BIT NOT NULL CONSTRAINT DF_REF_CONTACTTYPE_IsActive DEFAULT (1),
    CONSTRAINT PK_REF_CONTACTTYPE PRIMARY KEY CLUSTERED (ContactTypeID),
    CONSTRAINT UQ_REF_CONTACTTYPE_Code UNIQUE (ContactTypeCode)
);
GO

/* ============================================================================
   5. REF_ROLETYPE
   ============================================================================ */
CREATE TABLE dbo.REF_ROLETYPE
(
    RoleTypeID   INT IDENTITY(1,1) NOT NULL,
    RoleTypeCode VARCHAR(50) NOT NULL,
    Description  VARCHAR(100) NOT NULL,
    IsActive     BIT NOT NULL CONSTRAINT DF_REF_ROLETYPE_IsActive DEFAULT (1),
    CONSTRAINT PK_REF_ROLETYPE PRIMARY KEY CLUSTERED (RoleTypeID),
    CONSTRAINT UQ_REF_ROLETYPE_Code UNIQUE (RoleTypeCode)
);
GO

/* ============================================================================
   6. REF_ADDRESSROLE
   ============================================================================ */
CREATE TABLE dbo.REF_ADDRESSROLE
(
    AddressRoleID   INT IDENTITY(1,1) NOT NULL,
    AddressRoleCode VARCHAR(30) NOT NULL,
    Description     VARCHAR(100) NOT NULL,
    IsActive        BIT NOT NULL CONSTRAINT DF_REF_ADDRESSROLE_IsActive DEFAULT (1),
    CONSTRAINT PK_REF_ADDRESSROLE PRIMARY KEY CLUSTERED (AddressRoleID),
    CONSTRAINT UQ_REF_ADDRESSROLE_Code UNIQUE (AddressRoleCode)
);
GO

/* ============================================================================
   7. REF_UNITTYPECODE
   ============================================================================ */
CREATE TABLE dbo.REF_UNITTYPECODE
(
    UnitTypeCodeID    INT IDENTITY(1,1) NOT NULL,
    UnitTypeCode      NVARCHAR(30) NOT NULL,
    UnitTypeName      NVARCHAR(100) NOT NULL,
    Description       NVARCHAR(128) NULL,
    IsActive          BIT NOT NULL CONSTRAINT DF_REF_UNITTYPECODE_IsActive DEFAULT (1),
    DeletedInd        BIT NOT NULL CONSTRAINT DF_REF_UNITTYPECODE_DeletedInd DEFAULT (0),
    CreationUserID    NVARCHAR(128) NOT NULL,
    CreationDate      DATETIME2(0) NOT NULL CONSTRAINT DF_REF_UNITTYPECODE_CreationDate DEFAULT (SYSDATETIME()),
    LastUpdatedUserID NVARCHAR(128) NOT NULL,
    LastUpdatedDate   DATETIME2(0) NOT NULL CONSTRAINT DF_REF_UNITTYPECODE_LastUpdatedDate DEFAULT (SYSDATETIME()),
    CONSTRAINT PK_REF_UNITTYPECODE PRIMARY KEY CLUSTERED (UnitTypeCodeID),
    CONSTRAINT UQ_REF_UNITTYPECODE_Code UNIQUE (UnitTypeCode),
    CONSTRAINT UQ_REF_UNITTYPECODE_Name UNIQUE (UnitTypeName),
    CONSTRAINT CK_REF_UNITTYPECODE_DeletedInd CHECK (DeletedInd IN (0,1)),
    CONSTRAINT CK_REF_UNITTYPECODE_Dates CHECK (LastUpdatedDate >= CreationDate)
);
GO

/* ============================================================================
   8. UPR (hub)
   ============================================================================ */
CREATE TABLE dbo.UPR
(
    UPRID         BIGINT IDENTITY(1,1) NOT NULL,
    ParentUPRID   BIGINT NULL,
    EntityTypeID  INT NOT NULL,
    AccountNumber VARCHAR(50) NULL,
    StatusCode    VARCHAR(20) NOT NULL CONSTRAINT DF_UPR_StatusCode DEFAULT ('ACTIVE'),
    CreatedDate   DATETIME2(0) NOT NULL CONSTRAINT DF_UPR_CreatedDate DEFAULT (SYSUTCDATETIME()),
    CreatedBy     VARCHAR(100) NOT NULL CONSTRAINT DF_UPR_CreatedBy DEFAULT (SUSER_SNAME()),
    UpdatedDate   DATETIME2(0) NULL,
    UpdatedBy     VARCHAR(100) NULL,
    CONSTRAINT PK_UPR PRIMARY KEY CLUSTERED (UPRID),
    CONSTRAINT FK_UPR_Parent FOREIGN KEY (ParentUPRID) REFERENCES dbo.UPR (UPRID),
    CONSTRAINT FK_UPR_Ref_EntityType FOREIGN KEY (EntityTypeID) REFERENCES dbo.REF_ENTITYTYPE (EntityTypeID),
    CONSTRAINT CK_UPR_StatusCode CHECK (StatusCode IN ('ACTIVE', 'INACTIVE')),
    CONSTRAINT CK_UPR_NotSelfParent CHECK (ParentUPRID IS NULL OR ParentUPRID <> UPRID)
);
GO

CREATE INDEX IX_UPR_ParentUPRID ON dbo.UPR (ParentUPRID);
CREATE INDEX IX_UPR_EntityTypeID ON dbo.UPR (EntityTypeID);
CREATE INDEX IX_UPR_AccountNumber ON dbo.UPR (AccountNumber) WHERE AccountNumber IS NOT NULL;
CREATE INDEX IX_UPR_Parent_EntityType ON dbo.UPR (ParentUPRID, EntityTypeID)
    INCLUDE (UPRID, AccountNumber, StatusCode);
GO

/* ============================================================================
   9. ADDRESS
   ============================================================================ */
CREATE TABLE dbo.ADDRESS
(
    AddressID         BIGINT IDENTITY(1,1) NOT NULL,
    StreetNumber      VARCHAR(20) NULL,
    StreetName        VARCHAR(200) NULL,
    StreetType        VARCHAR(30) NULL,
    StreetSuffix      VARCHAR(3) NULL,
    City              VARCHAR(100) NULL,
    State             CHAR(2) NULL,
    ZipCode           VARCHAR(10) NULL,
    StreetDirection   VARCHAR(20) NULL,
    NormalizedAddress VARCHAR(300) NULL,
    YCoordinate       INT NULL,
    XCoordinate       INT NULL,
    CreatedDate       DATETIME2(0) NOT NULL CONSTRAINT DF_ADDRESS_CreatedDate DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_ADDRESS PRIMARY KEY CLUSTERED (AddressID),
    CONSTRAINT CK_ADDRESS_State CHECK (State IS NULL OR State LIKE '[A-Z][A-Z]'),
    CONSTRAINT CK_ADDRESS_ZipCode CHECK (
        ZipCode IS NULL
        OR ZipCode LIKE '[0-9][0-9][0-9][0-9][0-9]'
        OR ZipCode LIKE '[0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]'
    )
);
GO

CREATE INDEX IX_ADDRESS_NormalizedAddress ON dbo.ADDRESS (NormalizedAddress);
CREATE INDEX IX_ADDRESS_Location ON dbo.ADDRESS (StreetNumber, StreetName, City, State, ZipCode);
GO

/* ============================================================================
   10. COMPLEX  (client Response.docx - omitted from NewUPRTABLEUSED)
       Hierarchy fields live on dbo.UPR; this table holds Complex-specific attrs.
   ============================================================================ */
CREATE TABLE dbo.COMPLEX
(
    ComplexID       BIGINT IDENTITY(1,1) NOT NULL,
    UPRID           BIGINT NOT NULL,
    CommunityName   VARCHAR(200) NULL,
    PropertyTypeID  INT NULL,
    StatusCode      VARCHAR(20) NOT NULL CONSTRAINT DF_COMPLEX_StatusCode DEFAULT ('ACTIVE'),
    CreatedDate     DATETIME2(0) NOT NULL CONSTRAINT DF_COMPLEX_CreatedDate DEFAULT (SYSUTCDATETIME()),
    CreatedBy       VARCHAR(100) NOT NULL CONSTRAINT DF_COMPLEX_CreatedBy DEFAULT (SUSER_SNAME()),
    UpdatedDate     DATETIME2(0) NULL,
    CONSTRAINT PK_COMPLEX PRIMARY KEY CLUSTERED (ComplexID),
    CONSTRAINT UQ_COMPLEX_UPRID UNIQUE (UPRID),
    CONSTRAINT FK_COMPLEX_UPR FOREIGN KEY (UPRID) REFERENCES dbo.UPR (UPRID),
    CONSTRAINT FK_COMPLEX_PropertyType FOREIGN KEY (PropertyTypeID) REFERENCES dbo.REF_PROPERTYTYPE (PropertyTypeID),
    CONSTRAINT CK_COMPLEX_StatusCode CHECK (StatusCode IN ('ACTIVE', 'INACTIVE', 'RETIRED'))
);
GO

/* ============================================================================
   11. PROPERTY
   ============================================================================ */
CREATE TABLE dbo.PROPERTY
(
    PropertyID     BIGINT IDENTITY(1,1) NOT NULL,
    UPRID          BIGINT NOT NULL,
    PropertyTypeID INT NOT NULL,
    PropertyName   VARCHAR(200) NULL,
    OwnerName      VARCHAR(200) NULL,
    Parcel         VARCHAR(20) NULL,
    StatusCode     VARCHAR(20) NOT NULL CONSTRAINT DF_PROPERTY_StatusCode DEFAULT ('ACTIVE'),
    CreatedDate    DATETIME2(0) NOT NULL CONSTRAINT DF_PROPERTY_CreatedDate DEFAULT (SYSUTCDATETIME()),
    UpdatedDate    DATETIME2(0) NULL,
    CONSTRAINT PK_PROPERTY PRIMARY KEY CLUSTERED (PropertyID),
    CONSTRAINT UQ_PROPERTY_UPRID UNIQUE (UPRID),
    CONSTRAINT FK_PROPERTY_UPR FOREIGN KEY (UPRID) REFERENCES dbo.UPR (UPRID),
    CONSTRAINT FK_PROPERTY_PropertyType FOREIGN KEY (PropertyTypeID) REFERENCES dbo.REF_PROPERTYTYPE (PropertyTypeID),
    CONSTRAINT CK_PROPERTY_StatusCode CHECK (StatusCode IN ('ACTIVE', 'INACTIVE', 'RETIRED'))
);
GO

CREATE INDEX IX_PROPERTY_PropertyTypeID ON dbo.PROPERTY (PropertyTypeID);
GO

/* ============================================================================
   12. CONDO
   ============================================================================ */
CREATE TABLE dbo.CONDO
(
    CondoID     BIGINT IDENTITY(1,1) NOT NULL,
    UPRID       BIGINT NOT NULL,
    CondoName   VARCHAR(200) NULL,
    OwnerName   VARCHAR(200) NULL,
    Parcel      VARCHAR(20) NULL,
    StatusCode  VARCHAR(20) NOT NULL CONSTRAINT DF_CONDO_StatusCode DEFAULT ('ACTIVE'),
    CreatedDate DATETIME2(0) NOT NULL CONSTRAINT DF_CONDO_CreatedDate DEFAULT (SYSUTCDATETIME()),
    UpdatedDate DATETIME2(0) NULL,
    CONSTRAINT PK_CONDO PRIMARY KEY CLUSTERED (CondoID),
    CONSTRAINT UQ_CONDO_UPRID UNIQUE (UPRID),
    CONSTRAINT FK_CONDO_UPR FOREIGN KEY (UPRID) REFERENCES dbo.UPR (UPRID),
    CONSTRAINT CK_CONDO_StatusCode CHECK (StatusCode IN ('ACTIVE', 'INACTIVE', 'RETIRED'))
);
GO

/* ============================================================================
   13. BUILDING
   ============================================================================ */
CREATE TABLE dbo.BUILDING
(
    BuildingID   BIGINT IDENTITY(1,1) NOT NULL,
    UPRID        BIGINT NOT NULL,
    BuildingName VARCHAR(200) NULL,
    YearBuilt    SMALLINT NULL,
    StatusCode   VARCHAR(20) NOT NULL CONSTRAINT DF_BUILDING_StatusCode DEFAULT ('ACTIVE'),
    CreatedDate  DATETIME2(0) NOT NULL CONSTRAINT DF_BUILDING_CreatedDate DEFAULT (SYSUTCDATETIME()),
    UpdatedDate  DATETIME2(0) NULL,
    CONSTRAINT PK_BUILDING PRIMARY KEY CLUSTERED (BuildingID),
    CONSTRAINT UQ_BUILDING_UPRID UNIQUE (UPRID),
    CONSTRAINT FK_BUILDING_UPR FOREIGN KEY (UPRID) REFERENCES dbo.UPR (UPRID),
    CONSTRAINT CK_BUILDING_YearBuilt CHECK (
        YearBuilt IS NULL OR YearBuilt BETWEEN 1600 AND YEAR(DATEADD(YEAR, 1, GETDATE()))
    ),
    CONSTRAINT CK_BUILDING_StatusCode CHECK (StatusCode IN ('ACTIVE', 'INACTIVE', 'RETIRED'))
);
GO

/* ============================================================================
   14. UNIT
   ============================================================================ */
CREATE TABLE dbo.UNIT
(
    UnitID           BIGINT IDENTITY(1,1) NOT NULL,
    UPRID            BIGINT NOT NULL,
    BuildingID       BIGINT NOT NULL,
    UnitNumber       VARCHAR(50) NULL,
    UnitTypeCode     VARCHAR(20) NULL,
    FloorNumber      VARCHAR(20) NULL,
    BedroomCount     INT NULL,
    BathroomCount    DECIMAL(4,1) NULL,
    HasLegalIdentity BIT NULL,
    StatusCode       VARCHAR(20) NOT NULL CONSTRAINT DF_UNIT_StatusCode DEFAULT ('ACTIVE'),
    CreatedDate      DATETIME2(0) NOT NULL CONSTRAINT DF_UNIT_CreatedDate DEFAULT (SYSUTCDATETIME()),
    UpdatedDate      DATETIME2(0) NULL,
    CONSTRAINT PK_UNIT PRIMARY KEY CLUSTERED (UnitID),
    CONSTRAINT UQ_UNIT_UPRID UNIQUE (UPRID),
    CONSTRAINT FK_UNIT_UPR FOREIGN KEY (UPRID) REFERENCES dbo.UPR (UPRID),
    CONSTRAINT FK_UNIT_BUILDING FOREIGN KEY (BuildingID) REFERENCES dbo.BUILDING (BuildingID),
    CONSTRAINT CK_UNIT_BedroomCount CHECK (BedroomCount IS NULL OR BedroomCount >= 0),
    CONSTRAINT CK_UNIT_BathroomCount CHECK (BathroomCount IS NULL OR BathroomCount >= 0),
    CONSTRAINT CK_UNIT_StatusCode CHECK (StatusCode IN ('ACTIVE', 'INACTIVE', 'RETIRED'))
);
GO

CREATE INDEX IX_UNIT_BuildingID ON dbo.UNIT (BuildingID);
CREATE INDEX IX_UNIT_Building_UnitNumber ON dbo.UNIT (BuildingID, UnitNumber);
GO

/* ============================================================================
   15. ADU
   ============================================================================ */
CREATE TABLE dbo.ADU
(
    ADUID       BIGINT IDENTITY(1,1) NOT NULL,
    UPRID       BIGINT NOT NULL,
    UnitNumber  VARCHAR(50) NULL,
    StatusCode  VARCHAR(20) NOT NULL CONSTRAINT DF_ADU_StatusCode DEFAULT ('ACTIVE'),
    CreatedDate DATETIME2(0) NOT NULL CONSTRAINT DF_ADU_CreatedDate DEFAULT (SYSUTCDATETIME()),
    UpdatedDate DATETIME2(0) NULL,
    CONSTRAINT PK_ADU PRIMARY KEY CLUSTERED (ADUID),
    CONSTRAINT UQ_ADU_UPRID UNIQUE (UPRID),
    CONSTRAINT FK_ADU_UPR FOREIGN KEY (UPRID) REFERENCES dbo.UPR (UPRID),
    CONSTRAINT CK_ADU_StatusCode CHECK (StatusCode IN ('ACTIVE', 'INACTIVE', 'RETIRED'))
);
GO

/* ============================================================================
   16. UPR_ADDRESS
   ============================================================================ */
CREATE TABLE dbo.UPR_ADDRESS
(
    UPRAddressID  BIGINT IDENTITY(1,1) NOT NULL,
    UPRID         BIGINT NOT NULL,
    AddressID     BIGINT NOT NULL,
    AddressRoleID INT NOT NULL,
    IsPrimary     BIT NOT NULL CONSTRAINT DF_UPR_ADDRESS_IsPrimary DEFAULT (0),
    EffectiveDate DATE NULL,
    EndDate       DATE NULL,
    CONSTRAINT PK_UPR_ADDRESS PRIMARY KEY CLUSTERED (UPRAddressID),
    CONSTRAINT FK_UPR_ADDRESS_UPR FOREIGN KEY (UPRID) REFERENCES dbo.UPR (UPRID),
    CONSTRAINT FK_UPR_ADDRESS_ADDRESS FOREIGN KEY (AddressID) REFERENCES dbo.ADDRESS (AddressID),
    CONSTRAINT FK_UPR_ADDRESS_ROLE FOREIGN KEY (AddressRoleID) REFERENCES dbo.REF_ADDRESSROLE (AddressRoleID),
    CONSTRAINT CK_UPR_ADDRESS_Dates CHECK (
        EndDate IS NULL OR EffectiveDate IS NULL OR EndDate >= EffectiveDate
    )
);
GO

CREATE INDEX IX_UPR_ADDRESS_UPRID ON dbo.UPR_ADDRESS (UPRID);
CREATE INDEX IX_UPR_ADDRESS_AddressID ON dbo.UPR_ADDRESS (AddressID);
CREATE UNIQUE INDEX UX_UPR_ADDRESS_Primary ON dbo.UPR_ADDRESS (UPRID) WHERE IsPrimary = 1;
GO

/* ============================================================================
   17. EXTERNAL_IDENTIFIER_XREF
   ============================================================================ */
CREATE TABLE dbo.EXTERNAL_IDENTIFIER_XREF
(
    ExternalIdentifierID BIGINT IDENTITY(1,1) NOT NULL,
    UPRID                BIGINT NOT NULL,
    SourceSystem         VARCHAR(50) NOT NULL,
    IdentifierType       VARCHAR(50) NOT NULL,
    IdentifierValue      VARCHAR(150) NOT NULL,
    CreatedDate          DATETIME2(0) NOT NULL CONSTRAINT DF_EXTERNAL_IDENTIFIER_CreatedDate DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_EXTERNAL_IDENTIFIER PRIMARY KEY CLUSTERED (ExternalIdentifierID),
    CONSTRAINT FK_EXTERNAL_IDENTIFIER_UPR FOREIGN KEY (UPRID) REFERENCES dbo.UPR (UPRID)
);
GO

/* One source record maps to exactly one UPR. AccountNumber is NOT unique
   (client rule), so it is only protected against exact duplicate rows. */
CREATE UNIQUE INDEX UX_EXTERNAL_IDENTIFIER_SourceRecord
    ON dbo.EXTERNAL_IDENTIFIER_XREF (SourceSystem, IdentifierValue)
    WHERE IdentifierType = 'SOURCE_RECORD_ID';
CREATE UNIQUE INDEX UX_EXTERNAL_IDENTIFIER_Source_Type_Value_UPR
    ON dbo.EXTERNAL_IDENTIFIER_XREF (SourceSystem, IdentifierType, IdentifierValue, UPRID);
CREATE INDEX IX_EXTERNAL_IDENTIFIER_UPRID ON dbo.EXTERNAL_IDENTIFIER_XREF (UPRID);
CREATE INDEX IX_EXTERNAL_IDENTIFIER_Source
    ON dbo.EXTERNAL_IDENTIFIER_XREF (SourceSystem, IdentifierType)
    INCLUDE (UPRID, IdentifierValue);
GO

/* ============================================================================
   18. CONTACT
   ============================================================================ */
CREATE TABLE dbo.CONTACT
(
    ContactID        BIGINT IDENTITY(1,1) NOT NULL,
    ContactTypeID    INT NOT NULL,
    FirstName        VARCHAR(100) NULL,
    MiddleName       VARCHAR(100) NULL,
    LastName         VARCHAR(100) NULL,
    OrganizationName VARCHAR(200) NULL,
    Phone            VARCHAR(30) NULL,
    Email            VARCHAR(254) NULL,
    AddressLine1     VARCHAR(200) NULL,
    AddressLine2     VARCHAR(200) NULL,
    City             VARCHAR(100) NULL,
    State            CHAR(2) NULL,
    ZipCode          VARCHAR(10) NULL,
    StatusCode       VARCHAR(20) NOT NULL CONSTRAINT DF_CONTACT_StatusCode DEFAULT ('ACTIVE'),
    CreatedDate      DATETIME2(0) NOT NULL CONSTRAINT DF_CONTACT_CreatedDate DEFAULT (SYSUTCDATETIME()),
    UpdatedDate      DATETIME2(0) NULL,
    CONSTRAINT PK_CONTACT PRIMARY KEY CLUSTERED (ContactID),
    CONSTRAINT FK_CONTACT_ContactType FOREIGN KEY (ContactTypeID) REFERENCES dbo.REF_CONTACTTYPE (ContactTypeID),
    CONSTRAINT CK_CONTACT_State CHECK (State IS NULL OR State LIKE '[A-Z][A-Z]'),
    CONSTRAINT CK_CONTACT_ZipCode CHECK (
        ZipCode IS NULL
        OR ZipCode LIKE '[0-9][0-9][0-9][0-9][0-9]'
        OR ZipCode LIKE '[0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]'
    ),
    CONSTRAINT CK_CONTACT_StatusCode CHECK (StatusCode IN ('ACTIVE', 'INACTIVE', 'RETIRED'))
);
GO

CREATE INDEX IX_CONTACT_LastName ON dbo.CONTACT (LastName, FirstName);
CREATE INDEX IX_CONTACT_Email ON dbo.CONTACT (Email) WHERE Email IS NOT NULL;
CREATE INDEX IX_CONTACT_OrganizationName ON dbo.CONTACT (OrganizationName) WHERE OrganizationName IS NOT NULL;
GO

/* ============================================================================
   19. UPR_CONTACT
   ============================================================================ */
CREATE TABLE dbo.UPR_CONTACT
(
    UPRContactID  BIGINT IDENTITY(1,1) NOT NULL,
    UPRID         BIGINT NOT NULL,
    ContactID     BIGINT NOT NULL,
    RoleTypeID    INT NOT NULL,
    EffectiveDate DATE NULL,
    EndDate       DATE NULL,
    CONSTRAINT PK_UPR_CONTACT PRIMARY KEY CLUSTERED (UPRContactID),
    CONSTRAINT FK_UPR_CONTACT_UPR FOREIGN KEY (UPRID) REFERENCES dbo.UPR (UPRID),
    CONSTRAINT FK_UPR_CONTACT_CONTACT FOREIGN KEY (ContactID) REFERENCES dbo.CONTACT (ContactID),
    CONSTRAINT FK_UPR_CONTACT_ROLE FOREIGN KEY (RoleTypeID) REFERENCES dbo.REF_ROLETYPE (RoleTypeID),
    CONSTRAINT CK_UPR_CONTACT_Dates CHECK (
        EndDate IS NULL OR EffectiveDate IS NULL OR EndDate >= EffectiveDate
    )
);
GO

CREATE INDEX IX_UPR_CONTACT_UPRID ON dbo.UPR_CONTACT (UPRID);
CREATE INDEX IX_UPR_CONTACT_ContactID ON dbo.UPR_CONTACT (ContactID);
CREATE INDEX IX_UPR_CONTACT_Role ON dbo.UPR_CONTACT (RoleTypeID, UPRID);
CREATE UNIQUE INDEX UX_UPR_CONTACT_Relationship ON dbo.UPR_CONTACT (UPRID, ContactID, RoleTypeID);
GO

/* ============================================================================
   20. UPR_CLOSURE (derived from ParentUPRID)
   ============================================================================ */
CREATE TABLE dbo.UPR_CLOSURE
(
    AncestorUPRID   BIGINT NOT NULL,
    DescendantUPRID BIGINT NOT NULL,
    CONSTRAINT PK_UPR_CLOSURE PRIMARY KEY CLUSTERED (AncestorUPRID, DescendantUPRID),
    CONSTRAINT FK_UPR_CLOSURE_Ancestor FOREIGN KEY (AncestorUPRID) REFERENCES dbo.UPR (UPRID),
    CONSTRAINT FK_UPR_CLOSURE_Descendant FOREIGN KEY (DescendantUPRID) REFERENCES dbo.UPR (UPRID)
);
GO

CREATE INDEX IX_UPR_CLOSURE_Descendant ON dbo.UPR_CLOSURE (DescendantUPRID, AncestorUPRID);
CREATE INDEX IX_UPR_CLOSURE_Ancestor ON dbo.UPR_CLOSURE (AncestorUPRID) INCLUDE (DescendantUPRID);
GO

/* ============================================================================
   21. AuditLog
   ============================================================================ */
CREATE TABLE dbo.AuditLog
(
    AuditID       INT IDENTITY(1,1) NOT NULL,
    EntityName    NVARCHAR(100) NOT NULL,
    EntityKey     NVARCHAR(200) NOT NULL,
    OperationType NVARCHAR(20) NOT NULL,
    ChangedBy     NVARCHAR(100) NOT NULL,
    ChangedDate   DATETIME2(3) NOT NULL CONSTRAINT DF_AuditLog_ChangedDate DEFAULT (SYSDATETIME()),
    ChangeSummary NVARCHAR(2000) NULL,
    CONSTRAINT PK_AuditLog PRIMARY KEY CLUSTERED (AuditID),
    CONSTRAINT CK_AuditLog_OperationType CHECK (OperationType IN (
        'INSERT', 'UPDATE', 'DELETE', 'MERGE', 'STATUS_CHANGE'
    )),
    /* 1-minute tolerance: DATETIME2(0) rounds up, so a value written as
       SYSDATETIME() can land just after 'now' and fail a strict check */
    CONSTRAINT CK_AuditLog_ChangedDate CHECK (ChangedDate <= DATEADD(MINUTE, 1, SYSDATETIME()))
);
GO

/* ============================================================================
   22. UPRMATCHREVIEW_Q
       UPRID nullable so rejected incoming rows (no UPR yet) can still queue.
   ============================================================================ */
CREATE TABLE dbo.UPRMATCHREVIEW_Q
(
    UPRMatchReviewID               INT IDENTITY(1,1) NOT NULL,
    UPRID                          BIGINT NULL,
    IncomingSourceSystem           NVARCHAR(100) NOT NULL,
    SDAT_NormalizedIncomingAddress NVARCHAR(300) NOT NULL,
    MA_NormalizedIncomingAddress   NVARCHAR(300) NOT NULL,
    SDAT_ParcelID                  NVARCHAR(50) NULL,
    MA_ParcelID                    NVARCHAR(50) NULL,
    SDAT_AccountNumber             NVARCHAR(50) NULL,
    MA_Account                     NVARCHAR(50) NULL,
    ReasonForNoMatch               NVARCHAR(255) NOT NULL,
    ProcessingTimestamp            DATETIME2(0) NOT NULL CONSTRAINT DF_UPRMATCHREVIEW_Q_ProcessingTimestamp DEFAULT (SYSDATETIME()),
    Reviewer                       NVARCHAR(100) NULL,
    ReviewStatus                   NVARCHAR(128) NOT NULL CONSTRAINT DF_UPRMATCHREVIEW_Q_ReviewStatus DEFAULT ('PENDING_REVIEW'),
    Decision                       NVARCHAR(200) NULL,
    CONSTRAINT PK_UPRMATCHREVIEW_Q PRIMARY KEY CLUSTERED (UPRMatchReviewID),
    CONSTRAINT CK_UPRMATCHREVIEW_Q_ReviewStatus CHECK (ReviewStatus IN (
        'PENDING_REVIEW', 'IN_REVIEW', 'MATCHED_TO_EXISTING', 'APPROVED_AS_NEW',
        'REJECTED', 'NEEDS_MORE_INFO', 'CLOSED'
    )),
    CONSTRAINT CK_UPRMATCHREVIEW_Q_ReasonForNoMatch CHECK (ReasonForNoMatch IN (
        'MISSING PARCELID', 'NO_SDAT_MATCH', 'NO_ADDRESS_MATCH', 'INSUFFICIENT_DATA',
        'AMBIGUOUS_CANDIDATES', 'LOW_CONFIDENCE_ONLY', 'SOURCE_RECORD_ERROR', 'OTHER'
    ))
);
GO

/* ============================================================================
   23. UPRSTATUSHISTORY
       BuildingID / UnitNumber / Ownership dates nullable so Complex/Property
       rows without units can still record status history.
   ============================================================================ */
CREATE TABLE dbo.UPRSTATUSHISTORY
(
    UPRStatusHistoryID INT IDENTITY(1,1) NOT NULL,
    UPRID              BIGINT NOT NULL,
    SDATAccountNumber  NVARCHAR(50) NULL,
    CNumber            NVARCHAR(50) NULL,
    OldStatusCode      NVARCHAR(30) NULL,
    NewStatusCode      NVARCHAR(30) NOT NULL,
    ChangeReason       NVARCHAR(255) NULL,
    ParcelID           NVARCHAR(50) NULL,
    PropertyName       NVARCHAR(100) NULL,
    Owner              NVARCHAR(100) NULL,
    StreetNumber       NVARCHAR(20) NULL,
    StreetName         NVARCHAR(100) NULL,
    StreetType         NVARCHAR(4) NULL,
    City               NVARCHAR(100) NULL,
    State              NVARCHAR(2) NULL,
    ZipCode            NVARCHAR(10) NULL,
    PropertyTypeCode   NVARCHAR(30) NULL,
    ChangeSource       NVARCHAR(50) NULL,
    ChangedBy          NVARCHAR(100) NULL,
    ChangedDate        DATETIME2(0) NOT NULL CONSTRAINT DF_UPRStatusHistory_ChangedDate DEFAULT (SYSDATETIME()),
    Notes              NVARCHAR(1000) NULL,
    LevelInd           BIT NOT NULL CONSTRAINT DF_UPRStatusHistory_LevelInd DEFAULT (0),
    BuildingID         INT NULL,
    UnitNumber         NVARCHAR(50) NULL,
    UnitType           NVARCHAR(30) NULL,
    OwnershipStartDate DATETIME2(0) NULL,
    OwnershipEndDate   DATETIME2(0) NULL,
    Email              NVARCHAR(150) NULL,
    Phone              NVARCHAR(30) NULL,
    MaillingAddress1   NVARCHAR(200) NULL,
    MaillingAddress2   NVARCHAR(200) NULL,
    CONSTRAINT PK_UPRSTATUSHISTORY PRIMARY KEY CLUSTERED (UPRStatusHistoryID),
    CONSTRAINT FK_UPRStatusHistory_UPR FOREIGN KEY (UPRID) REFERENCES dbo.UPR (UPRID),
    CONSTRAINT CK_UPRStatusHistory_NewStatus CHECK (NewStatusCode IN (
        'PENDING', 'ACTIVE', 'INACTIVE', 'UNDER_REVIEW', 'MERGED', 'SPLIT', 'RETIRED', 'REJECTED'
    )),
    CONSTRAINT CK_UPRStatusHistory_OldStatus CHECK (
        OldStatusCode IS NULL OR OldStatusCode IN (
            'PENDING', 'ACTIVE', 'INACTIVE', 'UNDER_REVIEW', 'MERGED', 'SPLIT', 'RETIRED', 'REJECTED'
        )
    ),
    CONSTRAINT CK_UPRStatusHistory_ChangedDate CHECK (ChangedDate <= DATEADD(MINUTE, 1, SYSDATETIME()))
);
GO

/* ============================================================================
   SEED REFERENCE DATA
   ============================================================================ */
INSERT INTO dbo.REF_ENTITYTYPE (Description) VALUES
    ('Complex'), ('Property'), ('Building'), ('Unit'), ('Condo'), ('ADU');
GO

DECLARE @User NVARCHAR(128) = SUSER_SNAME();
DECLARE @Now  DATETIME2(0) = SYSDATETIME();

INSERT INTO dbo.REF_PROPERTYTYPE
    (PropertyTypeCode, PropertyTypeName, AllowsBuildings, AllowsUnits, DeletedInd,
     CreationUserID, CreationDate, LastUpdatedUserID, LastUpdatedDate)
VALUES
    (N'SF',       N'Single Family',      1, 1, 0, @User, @Now, @User, @Now),
    (N'MULTI',    N'Multi-Family',       1, 1, 0, @User, @Now, @User, @Now),
    (N'TH',       N'Townhouse',          1, 1, 0, @User, @Now, @User, @Now),
    (N'CONDO',    N'Condominium',        1, 1, 0, @User, @Now, @User, @Now),
    (N'MIXED',    N'Mixed Use',          1, 1, 0, @User, @Now, @User, @Now),
    (N'LAND',     N'Vacant Land',        1, 0, 0, @User, @Now, @User, @Now),
    (N'WAREHS',   N'Warehouse',          1, 0, 0, @User, @Now, @User, @Now),
    (N'OFFICE',   N'Office',             1, 0, 0, @User, @Now, @User, @Now),
    (N'PARK',     N'Park',               1, 0, 0, @User, @Now, @User, @Now),
    (N'APT',      N'Apartment Complex',  1, 1, 0, @User, @Now, @User, @Now);
GO

INSERT INTO dbo.REF_PROPERTY_STATUSCODE
    (StatusCode, Description, DeletedInd, CreationUserID, CreationDate, LastUpdatedUserID, LastUpdatedDate)
VALUES
    (N'ACTIVE',   N'Active',   0, SUSER_SNAME(), SYSDATETIME(), SUSER_SNAME(), SYSDATETIME()),
    (N'INACTIVE', N'Inactive', 0, SUSER_SNAME(), SYSDATETIME(), SUSER_SNAME(), SYSDATETIME()),
    (N'RETIRED',  N'Retired',  0, SUSER_SNAME(), SYSDATETIME(), SUSER_SNAME(), SYSDATETIME());
GO

INSERT INTO dbo.REF_CONTACTTYPE (ContactTypeCode, Description) VALUES
    ('PERSON', 'Individual Person'),
    ('ORGANIZATION', 'Organization'),
    ('UNKNOWN', 'Unknown / placeholder');
GO

INSERT INTO dbo.REF_ROLETYPE (RoleTypeCode, Description) VALUES
    ('OWNER', 'Owner'),
    ('PROPERTY_MANAGER', 'Property Manager'),
    ('LEGAL_AGENT', 'Legal Agent'),
    ('APPLICANT', 'Applicant'),
    ('LANDLORD', 'Landlord'),
    ('AUTHORIZED_REP', 'Authorized Representative');
GO

INSERT INTO dbo.REF_ADDRESSROLE (AddressRoleCode, Description) VALUES
    ('SITE', 'Site Address'),
    ('MAILING', 'Mailing Address'),
    ('PHYSICAL', 'Physical Address'),
    ('OTHER', 'Other Address');
GO

PRINT N'New hierarchical UPR schema created (NewUPRTABLEUSED + COMPLEX).';
GO
