USE SalesDB;
GO

CREATE OR ALTER PROCEDURE Pipeline.usp_RefreshDailySalesSummary
    @RunID BIGINT,
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
             DiscountAmount, NetRevenue, RefreshedAt, RefreshedByRunID)
        SELECT o.OrderDate,
               COALESCE(c.Country, 'Unknown'),
               category.CategoryName,
               COUNT(DISTINCT o.OrderID),
               SUM(CONVERT(INT, line.Quantity)),
               SUM(CONVERT(DECIMAL(14, 2), line.Quantity * line.UnitPrice)),
               SUM(CONVERT(DECIMAL(14, 2), line.Quantity * line.UnitPrice * line.DiscountPct)),
               SUM(CONVERT(DECIMAL(14, 2), line.Quantity * line.UnitPrice * (1 - line.DiscountPct))),
               SYSUTCDATETIME(),
               @RunID
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
