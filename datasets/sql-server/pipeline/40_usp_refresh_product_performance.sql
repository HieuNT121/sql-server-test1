USE SalesDB;
GO

CREATE OR ALTER PROCEDURE Pipeline.usp_RefreshProductPerformance
    @RunID BIGINT,
    @RowsProcessed INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @RowsProcessed = 0;

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE FROM Sales.ProductPerformanceSnapshot;

        ;WITH ProductSales AS
        (
            SELECT product.ProductID, product.ProductName, category.CategoryName,
                   COUNT(DISTINCT o.OrderID) AS OrderCount,
                   SUM(CONVERT(INT, line.Quantity)) AS UnitsSold,
                   SUM(CONVERT(DECIMAL(14, 2), line.Quantity * line.UnitPrice * (1 - line.DiscountPct))) AS NetRevenue,
                   SUM(CONVERT(DECIMAL(14, 2), line.Quantity *
                       ((line.UnitPrice * (1 - line.DiscountPct)) - product.UnitCost))) AS EstimatedMargin
            FROM Sales.OrderLines AS line
            JOIN Sales.Orders AS o ON o.OrderID = line.OrderID
            JOIN Sales.ProductCatalog AS product ON product.ProductID = line.ProductID
            JOIN Sales.Categories AS category ON category.CategoryID = product.CategoryID
            WHERE o.OrderStatus <> 'Cancelled'
            GROUP BY product.ProductID, product.ProductName, category.CategoryName
        ),
        ProductReturns AS
        (
            SELECT ProductID, SUM(RefundAmount) AS RefundAmount
            FROM Sales.Returns
            GROUP BY ProductID
        ),
        RankedProducts AS
        (
            SELECT sales.*,
                   COALESCE(returns.RefundAmount, 0) AS RefundAmount,
                   DENSE_RANK() OVER (ORDER BY sales.NetRevenue DESC) AS RevenueRank
            FROM ProductSales AS sales
            LEFT JOIN ProductReturns AS returns ON returns.ProductID = sales.ProductID
        )
        INSERT Sales.ProductPerformanceSnapshot
            (ProductID, ProductName, CategoryName, OrderCount, UnitsSold, NetRevenue,
             RefundAmount, EstimatedMargin, RevenueRank, RefreshedAt, RefreshedByRunID)
        SELECT ProductID, ProductName, CategoryName, OrderCount, UnitsSold, NetRevenue,
               RefundAmount, EstimatedMargin, RevenueRank, SYSUTCDATETIME(), @RunID
        FROM RankedProducts;

        SET @RowsProcessed = @@ROWCOUNT;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
