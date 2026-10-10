USE SalesDB;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'Pipeline')
    EXEC(N'CREATE SCHEMA Pipeline');
GO

IF OBJECT_ID(N'Pipeline.PipelineDefinitions', N'U') IS NULL
BEGIN
    CREATE TABLE Pipeline.PipelineDefinitions
    (
        PipelineDefinitionID INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PipelineDefinitions PRIMARY KEY,
        PipelineKey          VARCHAR(80)        NOT NULL CONSTRAINT UQ_PipelineDefinitions_Key UNIQUE,
        PipelineName         NVARCHAR(150)      NOT NULL,
        Description          NVARCHAR(500)      NULL,
        IsActive             BIT                NOT NULL CONSTRAINT DF_PipelineDefinitions_IsActive DEFAULT (1),
        CreatedAt            DATETIME2(3)       NOT NULL CONSTRAINT DF_PipelineDefinitions_CreatedAt DEFAULT SYSUTCDATETIME()
    );
END;
GO

IF OBJECT_ID(N'Pipeline.PipelineStepDefinitions', N'U') IS NULL
BEGIN
    CREATE TABLE Pipeline.PipelineStepDefinitions
    (
        StepDefinitionID     INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PipelineStepDefinitions PRIMARY KEY,
        PipelineDefinitionID INT                NOT NULL,
        StepKey              VARCHAR(80)        NOT NULL,
        StepOrder            TINYINT            NOT NULL,
        LayerNumber          TINYINT            NOT NULL,
        LayerName            NVARCHAR(80)       NOT NULL,
        StepName             NVARCHAR(120)      NOT NULL,
        ProcedureSchema      SYSNAME            NOT NULL,
        ProcedureName        SYSNAME            NOT NULL,
        IsActive             BIT                NOT NULL CONSTRAINT DF_PipelineStepDefinitions_IsActive DEFAULT (1),
        CONSTRAINT FK_PipelineStepDefinitions_Pipeline FOREIGN KEY (PipelineDefinitionID)
            REFERENCES Pipeline.PipelineDefinitions(PipelineDefinitionID),
        CONSTRAINT UQ_PipelineStepDefinitions_Key UNIQUE (PipelineDefinitionID, StepKey),
        CONSTRAINT UQ_PipelineStepDefinitions_Order UNIQUE (PipelineDefinitionID, StepOrder)
    );
END;
GO

IF OBJECT_ID(N'Pipeline.PipelineStepDependencies', N'U') IS NULL
BEGIN
    CREATE TABLE Pipeline.PipelineStepDependencies
    (
        StepDefinitionID          INT NOT NULL,
        DependsOnStepDefinitionID INT NOT NULL,
        CONSTRAINT PK_PipelineStepDependencies PRIMARY KEY (StepDefinitionID, DependsOnStepDefinitionID),
        CONSTRAINT FK_PipelineStepDependencies_Step FOREIGN KEY (StepDefinitionID)
            REFERENCES Pipeline.PipelineStepDefinitions(StepDefinitionID),
        CONSTRAINT FK_PipelineStepDependencies_Dependency FOREIGN KEY (DependsOnStepDefinitionID)
            REFERENCES Pipeline.PipelineStepDefinitions(StepDefinitionID),
        CONSTRAINT CK_PipelineStepDependencies_NoSelf CHECK (StepDefinitionID <> DependsOnStepDefinitionID)
    );
END;
GO

IF OBJECT_ID(N'Pipeline.PipelineRuns', N'U') IS NULL
BEGIN
    CREATE TABLE Pipeline.PipelineRuns
    (
        RunID                BIGINT         IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PipelineRuns PRIMARY KEY,
        PipelineDefinitionID INT            NULL,
        PipelineName         SYSNAME        NOT NULL,
        Status               VARCHAR(20)    NOT NULL,
        TriggeredBy          NVARCHAR(100)  NOT NULL,
        StartedAt            DATETIME2(3)   NOT NULL CONSTRAINT DF_PipelineRuns_StartedAt DEFAULT SYSUTCDATETIME(),
        CompletedAt          DATETIME2(3)   NULL,
        DurationMs           INT            NULL,
        RowsProcessed        INT            NULL,
        ErrorNumber          INT            NULL,
        ErrorMessage         NVARCHAR(2048) NULL,
        CONSTRAINT FK_PipelineRuns_Definition FOREIGN KEY (PipelineDefinitionID)
            REFERENCES Pipeline.PipelineDefinitions(PipelineDefinitionID),
        CONSTRAINT CK_PipelineRuns_Status CHECK (Status IN ('Running', 'Succeeded', 'Failed'))
    );
END;
GO

IF COL_LENGTH(N'Pipeline.PipelineRuns', N'PipelineDefinitionID') IS NULL
    ALTER TABLE Pipeline.PipelineRuns ADD PipelineDefinitionID INT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_PipelineRuns_Definition')
    ALTER TABLE Pipeline.PipelineRuns ADD CONSTRAINT FK_PipelineRuns_Definition
        FOREIGN KEY (PipelineDefinitionID) REFERENCES Pipeline.PipelineDefinitions(PipelineDefinitionID);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Pipeline.PipelineRuns') AND name = N'IX_PipelineRuns_PipelineName_StartedAt')
    CREATE INDEX IX_PipelineRuns_PipelineName_StartedAt
        ON Pipeline.PipelineRuns (PipelineName, StartedAt DESC)
        INCLUDE (Status, CompletedAt, RowsProcessed);
GO

IF OBJECT_ID(N'Pipeline.PipelineStepRuns', N'U') IS NULL
BEGIN
    CREATE TABLE Pipeline.PipelineStepRuns
    (
        StepRunID       BIGINT         IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PipelineStepRuns PRIMARY KEY,
        RunID           BIGINT         NOT NULL,
        StepDefinitionID INT           NULL,
        StepOrder       TINYINT        NOT NULL,
        StepName        NVARCHAR(100)  NOT NULL,
        ProcedureName   NVARCHAR(256)  NOT NULL,
        Status          VARCHAR(20)    NOT NULL,
        StartedAt       DATETIME2(3)   NOT NULL CONSTRAINT DF_PipelineStepRuns_StartedAt DEFAULT SYSUTCDATETIME(),
        CompletedAt     DATETIME2(3)   NULL,
        DurationMs      INT            NULL,
        RowsProcessed   INT            NULL,
        ErrorNumber     INT            NULL,
        ErrorMessage    NVARCHAR(2048) NULL,
        CONSTRAINT FK_PipelineStepRuns_PipelineRuns FOREIGN KEY (RunID) REFERENCES Pipeline.PipelineRuns(RunID),
        CONSTRAINT FK_PipelineStepRuns_Definition FOREIGN KEY (StepDefinitionID)
            REFERENCES Pipeline.PipelineStepDefinitions(StepDefinitionID),
        CONSTRAINT UQ_PipelineStepRuns_Run_Step UNIQUE (RunID, StepOrder),
        CONSTRAINT CK_PipelineStepRuns_Status CHECK (Status IN ('Running', 'Succeeded', 'Failed'))
    );
END;
GO

IF COL_LENGTH(N'Pipeline.PipelineStepRuns', N'StepDefinitionID') IS NULL
    ALTER TABLE Pipeline.PipelineStepRuns ADD StepDefinitionID INT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_PipelineStepRuns_Definition')
    ALTER TABLE Pipeline.PipelineStepRuns ADD CONSTRAINT FK_PipelineStepRuns_Definition
        FOREIGN KEY (StepDefinitionID) REFERENCES Pipeline.PipelineStepDefinitions(StepDefinitionID);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Pipeline.PipelineStepRuns') AND name = N'IX_PipelineStepRuns_RunID_StepOrder')
    CREATE INDEX IX_PipelineStepRuns_RunID_StepOrder
        ON Pipeline.PipelineStepRuns (RunID, StepOrder)
        INCLUDE (Status, StartedAt, CompletedAt, RowsProcessed);
GO

IF OBJECT_ID(N'Pipeline.DataQualityResults', N'U') IS NULL
BEGIN
    CREATE TABLE Pipeline.DataQualityResults
    (
        QualityResultID BIGINT        IDENTITY(1, 1) NOT NULL CONSTRAINT PK_DataQualityResults PRIMARY KEY,
        RunID           BIGINT        NOT NULL,
        CheckName       NVARCHAR(120) NOT NULL,
        Severity        VARCHAR(10)   NOT NULL,
        Status          VARCHAR(10)   NOT NULL,
        IssueCount      INT           NOT NULL,
        Detail          NVARCHAR(500) NULL,
        CheckedAt       DATETIME2(3)  NOT NULL CONSTRAINT DF_DataQualityResults_CheckedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_DataQualityResults_Run FOREIGN KEY (RunID) REFERENCES Pipeline.PipelineRuns(RunID),
        CONSTRAINT CK_DataQualityResults_Severity CHECK (Severity IN ('Critical', 'Warning')),
        CONSTRAINT CK_DataQualityResults_Status CHECK (Status IN ('Passed', 'Failed'))
    );
END;
GO

IF OBJECT_ID(N'Sales.DailySalesSummary', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.DailySalesSummary
    (
        SalesDate        DATE           NOT NULL,
        Country          VARCHAR(50)    NOT NULL,
        CategoryName     NVARCHAR(80)   NOT NULL,
        OrderCount       INT            NOT NULL,
        UnitsSold        INT            NOT NULL,
        GrossRevenue     DECIMAL(14, 2) NOT NULL,
        DiscountAmount   DECIMAL(14, 2) NOT NULL,
        NetRevenue       DECIMAL(14, 2) NOT NULL,
        RefreshedAt      DATETIME2(3)   NOT NULL,
        RefreshedByRunID BIGINT         NULL,
        CONSTRAINT PK_DailySalesSummary PRIMARY KEY (SalesDate, Country, CategoryName)
    );
END;
GO

IF COL_LENGTH(N'Sales.DailySalesSummary', N'RefreshedByRunID') IS NULL
    ALTER TABLE Sales.DailySalesSummary ADD RefreshedByRunID BIGINT NULL;
GO

IF OBJECT_ID(N'Sales.CustomerValueSnapshot', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.CustomerValueSnapshot
    (
        CustomerID          INT            NOT NULL CONSTRAINT PK_CustomerValueSnapshot PRIMARY KEY,
        CustomerName        NVARCHAR(120)  NOT NULL,
        Country             VARCHAR(50)    NOT NULL,
        Segment             VARCHAR(20)    NULL,
        FirstOrderDate      DATE           NULL,
        LastOrderDate       DATE           NULL,
        LifetimeOrderCount  INT            NOT NULL,
        LifetimeNetRevenue  DECIMAL(14, 2) NOT NULL,
        AverageOrderValue   DECIMAL(14, 2) NULL,
        CustomerTier        VARCHAR(30)    NOT NULL,
        RefreshedAt         DATETIME2(3)   NOT NULL,
        RefreshedByRunID    BIGINT         NULL,
        CONSTRAINT FK_CustomerValueSnapshot_Customers FOREIGN KEY (CustomerID) REFERENCES Sales.Customers(CustomerID)
    );
END;
GO

IF COL_LENGTH(N'Sales.CustomerValueSnapshot', N'RefreshedByRunID') IS NULL
    ALTER TABLE Sales.CustomerValueSnapshot ADD RefreshedByRunID BIGINT NULL;
GO

IF OBJECT_ID(N'Sales.ProductPerformanceSnapshot', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.ProductPerformanceSnapshot
    (
        ProductID          INT            NOT NULL CONSTRAINT PK_ProductPerformanceSnapshot PRIMARY KEY,
        ProductName        NVARCHAR(120)  NOT NULL,
        CategoryName       NVARCHAR(80)   NOT NULL,
        OrderCount         INT            NOT NULL,
        UnitsSold          INT            NOT NULL,
        NetRevenue         DECIMAL(14, 2) NOT NULL,
        RefundAmount       DECIMAL(14, 2) NOT NULL,
        EstimatedMargin    DECIMAL(14, 2) NOT NULL,
        RevenueRank        INT            NOT NULL,
        RefreshedAt        DATETIME2(3)   NOT NULL,
        RefreshedByRunID   BIGINT         NOT NULL
    );
END;
GO

IF OBJECT_ID(N'Sales.ExecutiveKpiSnapshot', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.ExecutiveKpiSnapshot
    (
        SnapshotID          TINYINT         NOT NULL CONSTRAINT PK_ExecutiveKpiSnapshot PRIMARY KEY,
        AsOfDate            DATE            NOT NULL,
        TotalOrders         INT             NOT NULL,
        ActiveCustomers     INT             NOT NULL,
        NetRevenue          DECIMAL(14, 2)  NOT NULL,
        AverageOrderValue   DECIMAL(14, 2)  NOT NULL,
        RefundAmount        DECIMAL(14, 2)  NOT NULL,
        ReturnRatePct       DECIMAL(7, 2)   NOT NULL,
        TopCountry          VARCHAR(50)     NULL,
        TopStore            NVARCHAR(120)   NULL,
        TopProduct          NVARCHAR(120)   NULL,
        RefreshedAt         DATETIME2(3)    NOT NULL,
        RefreshedByRunID    BIGINT          NOT NULL,
        CONSTRAINT CK_ExecutiveKpiSnapshot_Singleton CHECK (SnapshotID = 1)
    );
END;
GO

IF COL_LENGTH(N'Sales.ExecutiveKpiSnapshot', N'TopStore') IS NULL
    ALTER TABLE Sales.ExecutiveKpiSnapshot ADD TopStore NVARCHAR(120) NULL;
GO
