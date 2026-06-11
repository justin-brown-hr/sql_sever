/*
    Unified Property Record (UPR) - Database Schema
    SQL Server 2016+
    Consolidated from client specs: ALL_UPRDB.docx, Program_Specification_UPropertyMaster.docx
*/

USE master;
GO

IF DB_ID(N'UPR_Master') IS NULL
    CREATE DATABASE UPR_Master;
GO

USE UPR_Master;
GO

/* ============================================================================
   DROP ORDER (child tables first)
   ============================================================================ */
IF OBJECT_ID(N'dbo.UPROPERTYMATCHREVIEW_Q', N'U') IS NOT NULL DROP TABLE dbo.UPROPERTYMATCHREVIEW_Q;
IF OBJECT_ID(N'dbo.UPR_STATUSHISTORY', N'U') IS NOT NULL DROP TABLE dbo.UPR_STATUSHISTORY;
IF OBJECT_ID(N'dbo.UNITCONTACT', N'U') IS NOT NULL DROP TABLE dbo.UNITCONTACT;
IF OBJECT_ID(N'dbo.UNITOWNER', N'U') IS NOT NULL DROP TABLE dbo.UNITOWNER;
IF OBJECT_ID(N'dbo.Unit', N'U') IS NOT NULL DROP TABLE dbo.Unit;
IF OBJECT_ID(N'dbo.Building', N'U') IS NOT NULL DROP TABLE dbo.Building;
IF OBJECT_ID(N'dbo.PROPERTYCONTACT', N'U') IS NOT NULL DROP TABLE dbo.PROPERTYCONTACT;
IF OBJECT_ID(N'dbo.CONTACT', N'U') IS NOT NULL DROP TABLE dbo.CONTACT;
IF OBJECT_ID(N'dbo.UPROPERTYRECORD_XREF', N'U') IS NOT NULL DROP TABLE dbo.UPROPERTYRECORD_XREF;
IF OBJECT_ID(N'dbo.UPROPERTYRECORD', N'U') IS NOT NULL DROP TABLE dbo.UPROPERTYRECORD;
IF OBJECT_ID(N'dbo.AuditLog', N'U') IS NOT NULL DROP TABLE dbo.AuditLog;
IF OBJECT_ID(N'dbo.MultifamilyLoanAddress', N'U') IS NOT NULL DROP TABLE dbo.MultifamilyLoanAddress;
IF OBJECT_ID(N'dbo.MPDU', N'U') IS NOT NULL DROP TABLE dbo.MPDU;
IF OBJECT_ID(N'dbo.[Case]', N'U') IS NOT NULL DROP TABLE dbo.[Case];
IF OBJECT_ID(N'dbo.eProperty', N'U') IS NOT NULL DROP TABLE dbo.eProperty;
IF OBJECT_ID(N'dbo.SDAT', N'U') IS NOT NULL DROP TABLE dbo.SDAT;
IF OBJECT_ID(N'dbo.AddressMaster', N'U') IS NOT NULL DROP TABLE dbo.AddressMaster;
IF OBJECT_ID(N'dbo.REF_MATCHCONFIDENCE', N'U') IS NOT NULL DROP TABLE dbo.REF_MATCHCONFIDENCE;
IF OBJECT_ID(N'dbo.REF_MATCHMETHOD', N'U') IS NOT NULL DROP TABLE dbo.REF_MATCHMETHOD;
IF OBJECT_ID(N'dbo.REF_SOURCESYSTEM', N'U') IS NOT NULL DROP TABLE dbo.REF_SOURCESYSTEM;
IF OBJECT_ID(N'dbo.REF_UNITTYPECODE', N'U') IS NOT NULL DROP TABLE dbo.REF_UNITTYPECODE;
IF OBJECT_ID(N'dbo.REF_BUILDINGTYPE', N'U') IS NOT NULL DROP TABLE dbo.REF_BUILDINGTYPE;
IF OBJECT_ID(N'dbo.REF_STATUSCODE_Unit', N'U') IS NOT NULL DROP TABLE dbo.REF_STATUSCODE_Unit;
IF OBJECT_ID(N'dbo.REF_STATUSCODE_Property', N'U') IS NOT NULL DROP TABLE dbo.REF_STATUSCODE_Property;
IF OBJECT_ID(N'dbo.REF_PROPERTYTYPE', N'U') IS NOT NULL DROP TABLE dbo.REF_PROPERTYTYPE;
GO

/* ============================================================================
   INCOMING / STAGING TABLES
   ============================================================================ */
CREATE TABLE dbo.AddressMaster  /* client: MASTERADDRESS */
(
    MasterAddressID       INT           NOT NULL PRIMARY KEY,
    AddressStatus         INT           NULL,
    AddressType           INT           NULL,
    AddressDate           DATETIME      NULL,
    StreetNumber          INT           NULL,
    StreetSuffix          NVARCHAR(3)   NULL,
    StreetName            NVARCHAR(22)  NULL,
    StreetType            NCHAR(4)      NULL,
    StreetSuffixDirection NCHAR(2)      NULL,
    Unit                  NCHAR(6)      NULL,
    XCoordinate           INT           NULL,
    YCoordinate           INT           NULL,
    FullAddress           NVARCHAR(50)  NULL,
    City                  NVARCHAR(22)  NULL,
    ZipCode               NCHAR(10)     NULL,
    Comments              NVARCHAR(MAX) NULL,
    Account               NCHAR(8)      NULL,
    ParcelNumber          NCHAR(3)      NULL,
    PropertyType          NCHAR(35)     NULL
);

CREATE TABLE dbo.SDAT  /* client real table — no PK, no KdatRecordID, no CondoUnit */
(
    AccountNumber        NVARCHAR(MAX) NULL,
    Lot                  NVARCHAR(MAX) NULL,
    Block                NVARCHAR(MAX) NULL,
    Parcel               NVARCHAR(MAX) NULL,
    TownCode             NVARCHAR(MAX) NULL,
    GeneralZone          NVARCHAR(MAX) NULL,
    PropertyParcelCode   NVARCHAR(MAX) NULL,
    OwnerOccupancyCode   NVARCHAR(MAX) NULL,
    DwellingUnits        INT           NULL,
    Owner                NVARCHAR(MAX) NULL,
    TransferDate         DATETIME      NULL,
    YearBuilt            INT           NULL,
    PremisesNumber       NVARCHAR(MAX) NULL,
    PremisesDirection    NVARCHAR(MAX) NULL,
    PremisesStreetName   NVARCHAR(MAX) NULL,
    PremisesStreetType   NVARCHAR(MAX) NULL,
    PremisesCity         NVARCHAR(MAX) NULL,
    PremisesState        NVARCHAR(MAX) NULL,
    PremisesZipCode      NVARCHAR(MAX) NULL
);

/* ============================================================================
   EXTERNAL MATCH TABLES
   ============================================================================ */
CREATE TABLE dbo.eProperty
(
    PropertyID     INT           NOT NULL PRIMARY KEY,
    StreetAddress  NVARCHAR(200) NULL,
    AddressLine2   NVARCHAR(200) NULL,
    City           NVARCHAR(100) NULL,
    ZipCode        NVARCHAR(10)  NULL,
    TaxID          NVARCHAR(50)  NULL,
    YearBuilt      INT           NULL,
    Latitude       DECIMAL(10,6) NULL,
    Longitude      DECIMAL(10,6) NULL
);

CREATE TABLE dbo.[Case]
(
    CaseID         INT           NOT NULL PRIMARY KEY,
    CaseNumber     NVARCHAR(50)  NULL,
    CaseName       NVARCHAR(200) NULL,
    StreetAddress  NVARCHAR(200) NULL,
    AddressLine2   NVARCHAR(200) NULL,
    City           NVARCHAR(100) NULL,
    ZipCode        NVARCHAR(10)  NULL
);

CREATE TABLE dbo.MPDU
(
    DevelopmentID  INT           NOT NULL PRIMARY KEY,
    ProjectName    NVARCHAR(200) NULL,
    StreetAddress  NVARCHAR(200) NULL,
    City           NVARCHAR(100) NULL,
    ZipCode        NVARCHAR(10)  NULL
);

CREATE TABLE dbo.MultifamilyLoanAddress
(
    AddressID        INT           NOT NULL PRIMARY KEY,
    ProjectID        INT           NULL,
    StreetNumber     NVARCHAR(20)  NULL,
    StreetDirection  NVARCHAR(10)  NULL,
    StreetName       NVARCHAR(100) NULL,
    StreetType       NVARCHAR(20)  NULL,
    AddressLine2     NVARCHAR(200) NULL,
    City             NVARCHAR(100) NULL,
    ZipCode          NVARCHAR(10)  NULL,
    DeletedInd       BIT           NOT NULL DEFAULT 0
);

/* ============================================================================
   REFERENCE TABLES
   ============================================================================ */
CREATE TABLE dbo.REF_PROPERTYTYPE
(
    PropertyTypeID    INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    PropertyTypeCode  NVARCHAR(6)   NOT NULL UNIQUE,
    PropertyTypeName  NVARCHAR(128) NOT NULL,
    AllowsBuildings   BIT NOT NULL DEFAULT 0,
    AllowsUnits       BIT NOT NULL DEFAULT 0,
    DeletedInd        BIT NOT NULL DEFAULT 0,
    CreationUSERID    NVARCHAR(128) NOT NULL DEFAULT N'SYSTEM',
    CreationDate      DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME(),
    LastUpdatedUserID NVARCHAR(128) NOT NULL DEFAULT N'SYSTEM',
    LastUpdatedDate   DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE dbo.REF_STATUSCODE_Property
(
    PropertyStatusCodeID INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    StatusCode           NVARCHAR(30) NOT NULL UNIQUE,
    [Description]        NVARCHAR(128) NOT NULL
);

CREATE TABLE dbo.REF_SOURCESYSTEM
(
    SourceSystemCodeID INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    SourceSystemCode   NVARCHAR(30)  NOT NULL UNIQUE,
    SourceSystemName   NVARCHAR(100) NOT NULL,
    [Description]      NVARCHAR(255) NULL,
    IsActive           BIT NOT NULL DEFAULT 1,
    CreatedDate        DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    UpdatedDate        DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE dbo.REF_MATCHMETHOD
(
    MatchMethodCodeID INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    MatchMethodCode   NVARCHAR(30)  NOT NULL UNIQUE,
    MatchMethodName   NVARCHAR(100) NOT NULL,
    [Description]     NVARCHAR(255) NULL,
    IsActive          BIT NOT NULL DEFAULT 1,
    CreatedDate       DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    UpdatedDate       DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE dbo.REF_MATCHCONFIDENCE
(
    MatchConfidenceCodeID INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    MatchConfidenceCode   NVARCHAR(20) NOT NULL UNIQUE,
    MatchConfidenceName   NVARCHAR(50) NOT NULL,
    ConfidenceRank        INT NOT NULL,
    [Description]         NVARCHAR(128) NOT NULL,
    IsActive              BIT NOT NULL DEFAULT 1,
    CreatedDate           DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    UpdatedDate           DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE dbo.REF_BUILDINGTYPE
(
    BuildingTypeID      INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    BuildingTypeCode    NVARCHAR(30)  NOT NULL UNIQUE,
    BuildingTypeName    NVARCHAR(100) NOT NULL,
    [Description]       NVARCHAR(255) NULL,
    IsResidential       BIT NOT NULL DEFAULT 1,
    IsActive            BIT NOT NULL DEFAULT 1,
    DeletedInd          BIT NOT NULL DEFAULT 0,
    CreationUSERID      NVARCHAR(128) NOT NULL DEFAULT N'SYSTEM',
    CreationDate        DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    LastUpdatedUserID   NVARCHAR(128) NOT NULL DEFAULT N'SYSTEM',
    LastUpdatedDate     DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE dbo.REF_UNITTYPECODE
(
    UnitTypeCodeID   INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    UnitTypeCode     NVARCHAR(30)  NOT NULL UNIQUE,
    UnitTypeName     NVARCHAR(100) NOT NULL,
    [Description]    NVARCHAR(128) NULL,
    IsActive         BIT NOT NULL DEFAULT 1,
    DeletedInd       BIT NOT NULL DEFAULT 0,
    CreationUSERID   NVARCHAR(128) NOT NULL DEFAULT N'SYSTEM',
    CreationDate     DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    LastUpdatedUserID NVARCHAR(128) NOT NULL DEFAULT N'SYSTEM',
    LastUpdatedDate  DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE dbo.REF_STATUSCODE_Unit
(
    UnitStatusCodeID INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    StatusCode       NVARCHAR(30) NOT NULL,
    EntityType       NVARCHAR(50) NOT NULL,
    StatusName       NVARCHAR(50) NOT NULL,
    [Description]    NVARCHAR(128) NOT NULL
);

/* ============================================================================
   UPR CORE TABLES
   ============================================================================ */
CREATE TABLE dbo.UPROPERTYRECORD
(
    UPropertyRecordID     INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    SDATAccountNumber     NVARCHAR(50)  NULL,
    ParcelID              NVARCHAR(50)  NULL,
    PropertyName          NVARCHAR(200) NULL,
    Owner                 NVARCHAR(200) NULL,
    StreetNumber          NVARCHAR(20)  NOT NULL,
    StreetName            NVARCHAR(150) NOT NULL,
    StreetSuffix          NVARCHAR(20)  NULL,
    StreetType            NVARCHAR(10)  NULL,
    UnitNumber            NVARCHAR(20)  NULL,
    City                  NVARCHAR(100) NOT NULL,
    [State]               VARCHAR(2)    NULL,
    ZipCode               VARCHAR(10)   NOT NULL,
    NormalizedAddress     NVARCHAR(200) NOT NULL,
    NormalizedFullAddress NVARCHAR(300) NOT NULL,
    Latitude              DECIMAL(10,6) NULL,
    Longitude             DECIMAL(10,6) NULL,
    PropertyType          NVARCHAR(30)  NULL,
    StatusCode            NVARCHAR(30)  NOT NULL DEFAULT N'ACTIVE',
    IsActive              BIT NOT NULL DEFAULT 1,
    CreatedDate           DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    CreatedBy             NVARCHAR(100) NULL DEFAULT SUSER_SNAME(),
    UpdatedDate           DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    UpdatedBy             NVARCHAR(100) NULL DEFAULT SUSER_SNAME(),
    CONSTRAINT UQ_UPROPERTYRECORD_Account UNIQUE (SDATAccountNumber),
    CONSTRAINT UQ_UPROPERTYRECORD_Parcel  UNIQUE (ParcelID),
    CONSTRAINT UQ_UPROPERTYRECORD_Address UNIQUE (StreetNumber, StreetName, StreetType, ZipCode)
);

CREATE TABLE dbo.UPROPERTYRECORD_XREF
(
    UPropertyRecord_XrefID INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    UPropertyRecordID      INT NOT NULL,
    SourceSystem           VARCHAR(30)  NOT NULL,
    SourceRecordID         VARCHAR(100) NOT NULL,
    SourceEntityType       VARCHAR(50)  NOT NULL,
    MatchMethodCode        VARCHAR(30)  NOT NULL,
    MatchResult            NVARCHAR(30) NOT NULL,
    MatchConfidence        NVARCHAR(30) NOT NULL,
    ProcessingStatus       NVARCHAR(50) NULL,
    IsActive               BIT NOT NULL DEFAULT 1,
    EffectiveStartDate     DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    EffectiveEndDate       DATETIME2(0) NULL,
    Notes                  VARCHAR(1000) NULL,
    CreatedDate            DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    UpdatedDate            DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    CreatedBy              VARCHAR(100) NULL DEFAULT SUSER_SNAME(),
    CONSTRAINT FK_XREF_UPROPERTYRECORD FOREIGN KEY (UPropertyRecordID)
        REFERENCES dbo.UPROPERTYRECORD (UPropertyRecordID),
    CONSTRAINT CK_XREF_MatchResult CHECK (MatchResult IN (N'MATCH', N'NO_MATCH', N'POSSIBLE_MATCH', N'DUPLICATE', N'REJECTED')),
    CONSTRAINT CK_XREF_MatchConfidence CHECK (MatchConfidence IN (N'HIGH', N'MEDIUM', N'LOW', N'VERIFIED', N'NONE'))
);

CREATE TABLE dbo.UPROPERTYMATCHREVIEW_Q
(
    UPRMatchReviewID          INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    UPropertyRecord_XrefID    INT NULL,
    UPropertyRecordID         INT NULL,
    IncomingSourceSystem      NVARCHAR(100) NOT NULL,
    NormalizedIncomingAddress NVARCHAR(300) NOT NULL,
    ParcelID                  NVARCHAR(50)  NULL,
    SDATAccountNumber         NVARCHAR(50)  NULL,
    ReasonForNoMatch          NVARCHAR(255) NOT NULL,
    ProcessingTimestamp       DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    Reviewer                  NVARCHAR(100) NULL,
    ReviewStatus              NVARCHAR(128) NOT NULL DEFAULT N'PENDING_REVIEW',
    Decision                  NVARCHAR(200) NULL,
    CONSTRAINT FK_REVIEW_XREF FOREIGN KEY (UPropertyRecord_XrefID)
        REFERENCES dbo.UPROPERTYRECORD_XREF (UPropertyRecord_XrefID),
    CONSTRAINT FK_REVIEW_UPR FOREIGN KEY (UPropertyRecordID)
        REFERENCES dbo.UPROPERTYRECORD (UPropertyRecordID)
);

CREATE TABLE dbo.UPR_STATUSHISTORY
(
    UPRStatusHistoryID INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    UPropertyRecordID  INT NOT NULL,
    SDATAccountNumber  NVARCHAR(50) NULL,
    OldStatusCode      NVARCHAR(30) NULL,
    NewStatusCode      NVARCHAR(30) NOT NULL,
    ChangeReason       NVARCHAR(255) NULL,
    ParcelID           NVARCHAR(50) NULL,
    PropertyName       NVARCHAR(200) NULL,
    Owner              NVARCHAR(200) NULL,
    StreetNumber       NVARCHAR(20) NULL,
    StreetName         NVARCHAR(150) NULL,
    StreetType         NVARCHAR(10) NULL,
    City               NVARCHAR(100) NULL,
    [State]            VARCHAR(2) NULL,
    ZipCode            VARCHAR(10) NULL,
    PropertyType       NVARCHAR(30) NULL,
    ChangeSource       NVARCHAR(50) NULL,
    ChangedBy          NVARCHAR(100) NULL DEFAULT SUSER_SNAME(),
    ChangedDate        DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    Notes              NVARCHAR(1000) NULL,
    CONSTRAINT FK_STATUSHISTORY_UPR FOREIGN KEY (UPropertyRecordID)
        REFERENCES dbo.UPROPERTYRECORD (UPropertyRecordID)
);

CREATE TABLE dbo.CONTACT
(
    ContactID          INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    ContactTypeCode    NVARCHAR(30) NOT NULL,
    FirstName          NVARCHAR(100) NULL,
    LastName           NVARCHAR(100) NULL,
    OrganizationName   NVARCHAR(200) NULL,
    Email              NVARCHAR(150) NULL,
    Phone              NVARCHAR(30) NULL,
    MailingAddress1    NVARCHAR(200) NULL,
    MailingAddress2    NVARCHAR(200) NULL,
    City               NVARCHAR(100) NULL,
    [State]            CHAR(2) NULL,
    ZipCode            NVARCHAR(10) NULL,
    IsActive           BIT NOT NULL DEFAULT 1,
    CreatedDate        DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    UpdatedDate        DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE dbo.PROPERTYCONTACT
(
    PropertyContactID   INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    UPropertyRecordID   INT NOT NULL,
    ContactID           INT NOT NULL,
    ContactRoleCode     NVARCHAR(30) NOT NULL,
    EffectiveStartDate  DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    EffectiveEndDate    DATETIME2(0) NULL,
    IsActive            BIT NOT NULL DEFAULT 1,
    CONSTRAINT FK_PROPERTYCONTACT_UPR FOREIGN KEY (UPropertyRecordID)
        REFERENCES dbo.UPROPERTYRECORD (UPropertyRecordID),
    CONSTRAINT FK_PROPERTYCONTACT_CONTACT FOREIGN KEY (ContactID)
        REFERENCES dbo.CONTACT (ContactID)
);

CREATE TABLE dbo.Building
(
    BuildingID          INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    UPropertyRecordID   INT NOT NULL,
    BuildingCode        NVARCHAR(50) NOT NULL,
    BuildingName        NVARCHAR(100) NULL,
    BuildingTypeCode    NVARCHAR(50) NULL,
    BuildingAddress     NVARCHAR(255) NULL,
    StatusCode          NVARCHAR(30) NOT NULL DEFAULT N'ACTIVE',
    IsActive            BIT NOT NULL DEFAULT 1,
    CreatedDate         DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    UpdatedDate         DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    CreatedBy           NVARCHAR(128) NULL DEFAULT SUSER_SNAME(),
    UpdatedBy           NVARCHAR(128) NULL DEFAULT SUSER_SNAME(),
    CONSTRAINT FK_BUILDING_UPR FOREIGN KEY (UPropertyRecordID)
        REFERENCES dbo.UPROPERTYRECORD (UPropertyRecordID),
    CONSTRAINT UQ_BUILDING_Code UNIQUE (UPropertyRecordID, BuildingCode)
);

CREATE TABLE dbo.Unit
(
    UnitID              INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    UPropertyRecordID   INT NOT NULL,
    BuildingID          INT NOT NULL,
    UnitNumber          VARCHAR(50) NOT NULL,
    SDATAccountNumber   VARCHAR(50) NULL,
    UnitTypeCode        VARCHAR(30) NOT NULL,
    BedroomCount        INT NULL,
    BathroomCount       DECIMAL(3,1) NULL,
    FloorNumber         VARCHAR(20) NULL,
    UnitStatusCode      VARCHAR(30) NULL DEFAULT N'ACTIVE',
    IsMPDU              BIT NOT NULL DEFAULT 0,
    IsActive            BIT NOT NULL DEFAULT 1,
    CreatedDate         DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    UpdatedDate         DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    CreatedBy           VARCHAR(100) NULL DEFAULT SUSER_SNAME(),
    UpdatedBy           VARCHAR(100) NULL DEFAULT SUSER_SNAME(),
    CONSTRAINT FK_UNIT_UPR FOREIGN KEY (UPropertyRecordID)
        REFERENCES dbo.UPROPERTYRECORD (UPropertyRecordID),
    CONSTRAINT FK_UNIT_BUILDING FOREIGN KEY (BuildingID)
        REFERENCES dbo.Building (BuildingID),
    CONSTRAINT UQ_UNIT_Number UNIQUE (UPropertyRecordID, UnitNumber)
);

CREATE TABLE dbo.UNITOWNER
(
    UnitOwnerID         INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    UnitID              INT NOT NULL,
    ContactID           INT NOT NULL,
    OwnershipStartDate  DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    OwnershipEndDate    DATETIME2(0) NULL,
    IsPrimaryOwner      BIT NOT NULL DEFAULT 1,
    IsActive            BIT NOT NULL DEFAULT 1,
    CreationUserID      NVARCHAR(128) NOT NULL DEFAULT SUSER_SNAME(),
    CreationDate        DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    LastUpdatedUserID   NVARCHAR(128) NOT NULL DEFAULT SUSER_SNAME(),
    LastUpdatedDate     DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT FK_UNITOWNER_UNIT FOREIGN KEY (UnitID) REFERENCES dbo.Unit (UnitID),
    CONSTRAINT FK_UNITOWNER_CONTACT FOREIGN KEY (ContactID) REFERENCES dbo.CONTACT (ContactID)
);

CREATE TABLE dbo.UNITCONTACT
(
    UnitContactID       INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    UnitID              INT NOT NULL,
    ContactID           INT NOT NULL,
    ContactTypeCode     NVARCHAR(30) NOT NULL,
    FirstName           NVARCHAR(100) NULL,
    LastName            NVARCHAR(100) NULL,
    OrganizationName    NVARCHAR(200) NULL,
    Email               NVARCHAR(150) NULL,
    Phone               NVARCHAR(30) NULL,
    MailingAddress1     NVARCHAR(200) NULL,
    MailingAddress2     NVARCHAR(200) NULL,
    City                NVARCHAR(100) NULL,
    [State]             CHAR(2) NULL,
    ZipCode             NVARCHAR(10) NULL,
    IsActive            BIT NOT NULL DEFAULT 1,
    CreatedDate         DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    UpdatedDate         DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT FK_UNITCONTACT_UNIT FOREIGN KEY (UnitID) REFERENCES dbo.Unit (UnitID),
    CONSTRAINT FK_UNITCONTACT_CONTACT FOREIGN KEY (ContactID) REFERENCES dbo.CONTACT (ContactID)
);

CREATE TABLE dbo.AuditLog
(
    AuditID        INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    EntityName     NVARCHAR(100) NOT NULL,
    EntityKey      NVARCHAR(200) NOT NULL,
    OperationType  NVARCHAR(20) NOT NULL,
    ChangedBy      NVARCHAR(100) NOT NULL DEFAULT SUSER_SNAME(),
    ChangedDate    DATETIME2(3) NOT NULL DEFAULT SYSDATETIME(),
    ChangeSummary  NVARCHAR(2000) NULL,
    CONSTRAINT CK_AuditLog_OperationType CHECK (OperationType IN (N'INSERT', N'UPDATE', N'DELETE', N'MERGE', N'STATUS_CHANGE'))
);

GO
PRINT 'UPR_Master schema created successfully.';
GO
