/*
    Sales analytics pipeline for SQL Server 2022.

    Flow:
      Pipeline.usp_RunSalesAnalyticsPipeline
        -> Pipeline.usp_RefreshDailySalesSummary
        -> Pipeline.usp_RefreshCustomerValueSnapshot

    Every run and step is auditable through Pipeline.PipelineRuns and
    Pipeline.PipelineStepRuns. The child procedures own their transactions;
    the orchestrator records the result of each step.
*/
USE SalesDB;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'Pipeline')
    EXEC(N'CREATE SCHEMA Pipeline');
GO

IF OBJECT_ID(N'Pipeline.PipelineRuns', N'U') IS NULL
BEGIN
    CREATE TABLE Pipeline.PipelineRuns
    (
        RunID          BIGINT         IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PipelineRuns PRIMARY KEY,
        PipelineName   SYSNAME        NOT NULL,
        Status         VARCHAR(20)    NOT NULL,
        TriggeredBy    NVARCHAR(100)  NOT NULL,
        StartedAt      DATETIME2(3)   NOT NULL CONSTRAINT DF_PipelineRuns_StartedAt DEFAULT SYSUTCDATETIME(),
        CompletedAt    DATETIME2(3)   NULL,
        DurationMs     INT            NULL,
        RowsProcessed  INT            NULL,
        ErrorNumber    INT            NULL,
        ErrorMessage   NVARCHAR(2048) NULL,
        CONSTRAINT CK_PipelineRuns_Status CHECK (Status IN ('Running', 'Succeeded', 'Failed'))
    );

    CREATE INDEX IX_PipelineRuns_PipelineName_StartedAt
        ON Pipeline.PipelineRuns (PipelineName, StartedAt DESC)
        INCLUDE (Status, CompletedAt, RowsProcessed);
END;
GO

IF OBJECT_ID(N'Pipeline.PipelineStepRuns', N'U') IS NULL
BEGIN
    CREATE TABLE Pipeline.PipelineStepRuns
    (
        StepRunID       BIGINT         IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PipelineStepRuns PRIMARY KEY,
        RunID           BIGINT         NOT NULL,
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
        CONSTRAINT UQ_PipelineStepRuns_Run_Step UNIQUE (RunID, StepOrder),
        CONSTRAINT CK_PipelineStepRuns_Status CHECK (Status IN ('Running', 'Succeeded', 'Failed'))
    );

    CREATE INDEX IX_PipelineStepRuns_RunID_StepOrder
        ON Pipeline.PipelineStepRuns (RunID, StepOrder)
        INCLUDE (Status, StartedAt, CompletedAt, RowsProcessed);
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
        RefreshedAt      DATETIME2(3)  NOT NULL,
        CONSTRAINT PK_DailySalesSummary PRIMARY KEY (SalesDate, Country, CategoryName)
    );
END;
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
        RefreshedAt         DATETIME2(3)  NOT NULL,
        CONSTRAINT FK_CustomerValueSnapshot_Customers FOREIGN KEY (CustomerID) REFERENCES Sales.Customers(CustomerID)
    );
END;
GO

CREATE OR ALTER PROCEDURE Pipeline.usp_RefreshDailySalesSummary
    @RowsProcessed INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @RowsProcessed = 0;

    BEGIN TRY
        BEGIN TRANSACTION;

        DELETE FROM Sales.DailySalesSummary;

        INSERT Sales.DailySalesSummary
            (SalesDate, Country, CategoryName, OrderCount, UnitsSold, GrossRevenue,
             DiscountAmount, NetRevenue, RefreshedAt)
        SELECT o.OrderDate,
               COALESCE(c.Country, 'Unknown'),
               category.CategoryName,
               COUNT(DISTINCT o.OrderID),
               SUM(CONVERT(INT, line.Quantity)),
               SUM(CONVERT(DECIMAL(14, 2), line.Quantity * line.UnitPrice)),
               SUM(CONVERT(DECIMAL(14, 2), line.Quantity * line.UnitPrice * line.DiscountPct)),
               SUM(CONVERT(DECIMAL(14, 2), line.Quantity * line.UnitPrice * (1 - line.DiscountPct))),
               SYSUTCDATETIME()
        FROM Sales.Orders AS o
        JOIN Sales.OrderLines AS line ON line.OrderID = o.OrderID
        JOIN Sales.ProductCatalog AS product ON product.ProductID = line.ProductID
        JOIN Sales.Categories AS category ON category.CategoryID = product.CategoryID
        LEFT JOIN Sales.Customers AS c ON c.CustomerID = o.CustomerID
        WHERE o.OrderStatus <> 'Cancelled'
        GROUP BY o.OrderDate, COALESCE(c.Country, 'Unknown'), category.CategoryName;

        SET @RowsProcessed = @@ROWCOUNT;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE Pipeline.usp_RefreshCustomerValueSnapshot
    @RowsProcessed INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @RowsProcessed = 0;

    BEGIN TRY
        BEGIN TRANSACTION;

        DELETE FROM Sales.CustomerValueSnapshot;

        ;WITH OrderMetrics AS
        (
            SELECT CustomerID,
                   MIN(OrderDate) AS FirstOrderDate,
                   MAX(OrderDate) AS LastOrderDate,
                   COUNT(DISTINCT OrderID) AS LifetimeOrderCount,
                   SUM(CONVERT(DECIMAL(14, 2), Sales)) AS LifetimeNetRevenue
            FROM Sales.Orders
            WHERE OrderStatus <> 'Cancelled'
            GROUP BY CustomerID
        ),
        CustomerOrders AS
        (
            SELECT c.CustomerID,
                   CONCAT(c.FirstName, ' ', COALESCE(c.LastName, '')) AS CustomerName,
                   COALESCE(c.Country, 'Unknown') AS Country,
                   profile.Segment,
                   orders.FirstOrderDate,
                   orders.LastOrderDate,
                   COALESCE(orders.LifetimeOrderCount, 0) AS LifetimeOrderCount,
                   COALESCE(orders.LifetimeNetRevenue, 0) AS LifetimeNetRevenue
            FROM Sales.Customers AS c
            LEFT JOIN Sales.CustomerProfiles AS profile ON profile.CustomerID = c.CustomerID
            LEFT JOIN OrderMetrics AS orders ON orders.CustomerID = c.CustomerID
        ),
        RankedCustomers AS
        (
            SELECT *,
                   NTILE(4) OVER (ORDER BY LifetimeNetRevenue) AS RevenueQuartile
            FROM CustomerOrders
        )
        INSERT Sales.CustomerValueSnapshot
            (CustomerID, CustomerName, Country, Segment, FirstOrderDate, LastOrderDate,
             LifetimeOrderCount, LifetimeNetRevenue, AverageOrderValue, CustomerTier, RefreshedAt)
        SELECT CustomerID,
               CustomerName,
               Country,
               Segment,
               FirstOrderDate,
               LastOrderDate,
               LifetimeOrderCount,
               COALESCE(LifetimeNetRevenue, 0),
               COALESCE(LifetimeNetRevenue, 0) / NULLIF(LifetimeOrderCount, 0),
               CASE WHEN LifetimeOrderCount = 0 THEN 'Prospect'
                    WHEN RevenueQuartile = 4 THEN 'High value'
                    WHEN RevenueQuartile = 3 THEN 'Growth'
                    WHEN RevenueQuartile = 2 THEN 'Core'
                    ELSE 'Developing' END,
               SYSUTCDATETIME()
        FROM RankedCustomers;

        SET @RowsProcessed = @@ROWCOUNT;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE Pipeline.usp_RunSalesAnalyticsPipeline
    @TriggeredBy NVARCHAR(100) = N'Manual execution',
    @RunID BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @StepRunID BIGINT;
    DECLARE @RowsProcessed INT;
    DECLARE @TotalRowsProcessed INT = 0;
    DECLARE @StartedAt DATETIME2(3) = SYSUTCDATETIME();

    INSERT Pipeline.PipelineRuns (PipelineName, Status, TriggeredBy, StartedAt)
    VALUES (N'Sales analytics refresh', 'Running', @TriggeredBy, @StartedAt);

    SET @RunID = SCOPE_IDENTITY();

    BEGIN TRY
        INSERT Pipeline.PipelineStepRuns (RunID, StepOrder, StepName, ProcedureName, Status, StartedAt)
        VALUES (@RunID, 1, N'Refresh daily sales summary', N'Pipeline.usp_RefreshDailySalesSummary', 'Running', SYSUTCDATETIME());

        SET @StepRunID = SCOPE_IDENTITY();
        EXEC Pipeline.usp_RefreshDailySalesSummary @RowsProcessed = @RowsProcessed OUTPUT;
        SET @TotalRowsProcessed += @RowsProcessed;

        UPDATE Pipeline.PipelineStepRuns
        SET Status = 'Succeeded', CompletedAt = SYSUTCDATETIME(),
            DurationMs = DATEDIFF(MILLISECOND, StartedAt, SYSUTCDATETIME()), RowsProcessed = @RowsProcessed
        WHERE StepRunID = @StepRunID;

        INSERT Pipeline.PipelineStepRuns (RunID, StepOrder, StepName, ProcedureName, Status, StartedAt)
        VALUES (@RunID, 2, N'Refresh customer value snapshot', N'Pipeline.usp_RefreshCustomerValueSnapshot', 'Running', SYSUTCDATETIME());

        SET @StepRunID = SCOPE_IDENTITY();
        EXEC Pipeline.usp_RefreshCustomerValueSnapshot @RowsProcessed = @RowsProcessed OUTPUT;
        SET @TotalRowsProcessed += @RowsProcessed;

        UPDATE Pipeline.PipelineStepRuns
        SET Status = 'Succeeded', CompletedAt = SYSUTCDATETIME(),
            DurationMs = DATEDIFF(MILLISECOND, StartedAt, SYSUTCDATETIME()), RowsProcessed = @RowsProcessed
        WHERE StepRunID = @StepRunID;

        UPDATE Pipeline.PipelineRuns
        SET Status = 'Succeeded', CompletedAt = SYSUTCDATETIME(),
            DurationMs = DATEDIFF(MILLISECOND, StartedAt, SYSUTCDATETIME()),
            RowsProcessed = @TotalRowsProcessed
        WHERE RunID = @RunID;
    END TRY
    BEGIN CATCH
        UPDATE Pipeline.PipelineStepRuns
        SET Status = 'Failed', CompletedAt = SYSUTCDATETIME(),
            DurationMs = DATEDIFF(MILLISECOND, StartedAt, SYSUTCDATETIME()),
            ErrorNumber = ERROR_NUMBER(), ErrorMessage = ERROR_MESSAGE()
        WHERE StepRunID = @StepRunID AND Status = 'Running';

        UPDATE Pipeline.PipelineRuns
        SET Status = 'Failed', CompletedAt = SYSUTCDATETIME(),
            DurationMs = DATEDIFF(MILLISECOND, StartedAt, SYSUTCDATETIME()),
            RowsProcessed = @TotalRowsProcessed,
            ErrorNumber = ERROR_NUMBER(), ErrorMessage = ERROR_MESSAGE()
        WHERE RunID = @RunID;

        THROW;
    END CATCH;

    SELECT RunID, PipelineName, Status, TriggeredBy, StartedAt, CompletedAt, DurationMs, RowsProcessed
    FROM Pipeline.PipelineRuns
    WHERE RunID = @RunID;
END;
GO

DECLARE @InitialRunID BIGINT;

IF NOT EXISTS (SELECT 1 FROM Pipeline.PipelineRuns WHERE PipelineName = N'Sales analytics refresh')
    EXEC Pipeline.usp_RunSalesAnalyticsPipeline @TriggeredBy = N'Docker initialization', @RunID = @InitialRunID OUTPUT;
GO

PRINT 'Sales analytics pipeline is ready.';
GO
