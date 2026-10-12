USE SalesDB;
GO

CREATE OR ALTER PROCEDURE Pipeline.usp_ValidateConversionFixtures
    @RunID BIGINT,
    @RowsProcessed INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ExpectedObjects INT = 13;
    DECLARE @FoundObjects INT;
    DECLARE @TemporalReady INT;
    DECLARE @FoundProcedures INT;
    DECLARE @DirtyOrderCount INT;
    DECLARE @MalformedJsonCount INT;
    DECLARE @FanoutOrderCount INT;

    SELECT @FoundObjects = COUNT(*)
    FROM sys.objects AS object_definition
    WHERE object_definition.object_id IN
    (
        OBJECT_ID(N'Sales.ExchangeRates'), OBJECT_ID(N'Sales.Invoices'),
        OBJECT_ID(N'Sales.RawCustomerFeed'), OBJECT_ID(N'Sales.WebEvents'),
        OBJECT_ID(N'Sales.Promotions'), OBJECT_ID(N'Sales.ProductAttributes'),
        OBJECT_ID(N'Sales.OrgChart'), OBJECT_ID(N'Sales.PriceList'),
        OBJECT_ID(N'Sales.PriceListHistory'), OBJECT_ID(N'Sales.CustomerHistory'),
        OBJECT_ID(N'Sales.CustomerChanges'), OBJECT_ID(N'Sales.OrderStatusLog'),
        OBJECT_ID(N'Sales.MonthlyCustomerKPI')
    );

    SELECT @TemporalReady = COUNT(*)
    FROM sys.tables
    WHERE object_id = OBJECT_ID(N'Sales.PriceList')
      AND temporal_type = 2;

    SELECT @FoundProcedures = COUNT(*)
    FROM sys.procedures
    WHERE object_id IN
    (
        OBJECT_ID(N'Sales.usp_ApplyCustomerChanges'),
        OBJECT_ID(N'Sales.usp_InventoryReorderPlan'),
        OBJECT_ID(N'Sales.usp_PivotRevenueByCategory')
    );

    SELECT @DirtyOrderCount = COUNT(*)
    FROM Sales.Orders
    WHERE OrderStatus <> 'Cancelled' AND ShipDate < OrderDate;

    SELECT @MalformedJsonCount = COUNT(*)
    FROM Sales.WebEvents
    WHERE ISJSON(Payload) = 0;

    SELECT @FanoutOrderCount = COUNT(*)
    FROM Sales.Payments
    GROUP BY OrderID
    HAVING COUNT(*) > 1;

    DELETE FROM Pipeline.DataQualityResults WHERE RunID = @RunID;

    INSERT Pipeline.DataQualityResults (RunID, CheckName, Severity, Status, IssueCount, Detail)
    VALUES
      (@RunID, N'Advanced source objects', 'Critical',
       CASE WHEN @FoundObjects = @ExpectedObjects THEN 'Passed' ELSE 'Failed' END,
       ABS(@ExpectedObjects - @FoundObjects),
       N'All hard-mode tables from 03-advanced-salesdb.sql must be deployed.'),
      (@RunID, N'System-versioned price history', 'Critical',
       CASE WHEN @TemporalReady = 1 THEN 'Passed' ELSE 'Failed' END,
       CASE WHEN @TemporalReady = 1 THEN 0 ELSE 1 END,
       N'Sales.PriceList must use system-versioning with Sales.PriceListHistory.'),
      (@RunID, N'Programmable conversion objects', 'Critical',
       CASE WHEN @FoundProcedures = 3 THEN 'Passed' ELSE 'Failed' END,
       ABS(3 - @FoundProcedures),
       N'SCD2, inventory-planning, and dynamic-pivot procedures must be available.'),
      (@RunID, N'Intentional dirty order scenario', 'Warning',
       CASE WHEN @DirtyOrderCount > 0 THEN 'Passed' ELSE 'Failed' END,
       CASE WHEN @DirtyOrderCount > 0 THEN 0 ELSE 1 END,
       N'At least one non-cancelled order must ship before its order date for conversion testing.'),
      (@RunID, N'Intentional malformed JSON scenario', 'Warning',
       CASE WHEN @MalformedJsonCount > 0 THEN 'Passed' ELSE 'Failed' END,
       CASE WHEN @MalformedJsonCount > 0 THEN 0 ELSE 1 END,
       N'At least one malformed JSON event must be present for guarded JSON parsing.'),
      (@RunID, N'Intentional payment fan-out scenario', 'Warning',
       CASE WHEN @FanoutOrderCount > 0 THEN 'Passed' ELSE 'Failed' END,
       CASE WHEN @FanoutOrderCount > 0 THEN 0 ELSE 1 END,
       N'At least one order must have multiple payments for fan-out aggregation testing.');

    SET @RowsProcessed = @@ROWCOUNT;

    IF EXISTS
    (
        SELECT 1
        FROM Pipeline.DataQualityResults
        WHERE RunID = @RunID AND Severity = 'Critical' AND Status = 'Failed'
    )
        THROW 51101, 'The conversion fixture quality gate found missing required objects.', 1;
END;
GO
