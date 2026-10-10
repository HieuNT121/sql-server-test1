USE SalesDB;
GO

CREATE OR ALTER PROCEDURE Pipeline.usp_ValidateSalesSource
    @RunID BIGINT,
    @RowsProcessed INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DELETE FROM Pipeline.DataQualityResults WHERE RunID = @RunID;

    INSERT Pipeline.DataQualityResults (RunID, CheckName, Severity, Status, IssueCount, Detail)
    SELECT @RunID, N'Orders reference valid customers', 'Critical',
           CASE WHEN COUNT_BIG(*) = 0 THEN 'Passed' ELSE 'Failed' END,
           COUNT(*), N'Orders whose CustomerID is missing from Sales.Customers.'
    FROM Sales.Orders AS o
    LEFT JOIN Sales.Customers AS c ON c.CustomerID = o.CustomerID
    WHERE c.CustomerID IS NULL
    UNION ALL
    SELECT @RunID, N'Orders reference valid products', 'Critical',
           CASE WHEN COUNT_BIG(*) = 0 THEN 'Passed' ELSE 'Failed' END,
           COUNT(*), N'Orders whose ProductID is missing from Sales.ProductCatalog.'
    FROM Sales.Orders AS o
    LEFT JOIN Sales.ProductCatalog AS p ON p.ProductID = o.ProductID
    WHERE p.ProductID IS NULL
    UNION ALL
    SELECT @RunID, N'Shipping dates follow order dates', 'Critical',
           CASE WHEN COUNT_BIG(*) = 0 THEN 'Passed' ELSE 'Failed' END,
           COUNT(*), N'Non-cancelled orders shipped before their order date.'
    FROM Sales.Orders
    WHERE OrderStatus <> 'Cancelled' AND ShipDate < OrderDate
    UNION ALL
    SELECT @RunID, N'Orders contain detail lines', 'Warning',
           CASE WHEN COUNT_BIG(*) = 0 THEN 'Passed' ELSE 'Failed' END,
           COUNT(*), N'Orders without records in Sales.OrderLines.'
    FROM Sales.Orders AS o
    LEFT JOIN Sales.OrderLines AS line ON line.OrderID = o.OrderID
    WHERE line.OrderID IS NULL
    UNION ALL
    SELECT @RunID, N'Delivered orders have captured payments', 'Warning',
           CASE WHEN COUNT_BIG(*) = 0 THEN 'Passed' ELSE 'Failed' END,
           COUNT(*), N'Delivered orders without a captured payment record.'
    FROM Sales.Orders AS o
    WHERE o.OrderStatus = 'Delivered'
      AND NOT EXISTS
          (SELECT 1 FROM Sales.Payments AS p WHERE p.OrderID = o.OrderID AND p.PaymentStatus = 'Captured');

    SET @RowsProcessed = @@ROWCOUNT;

    IF EXISTS
    (
        SELECT 1
        FROM Pipeline.DataQualityResults
        WHERE RunID = @RunID AND Severity = 'Critical' AND Status = 'Failed'
    )
        THROW 51001, 'The source quality gate found critical data errors.', 1;
END;
GO
