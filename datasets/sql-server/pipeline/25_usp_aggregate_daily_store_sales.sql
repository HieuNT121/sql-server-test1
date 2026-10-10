USE SalesDB;
GO

/* Uses the location mapping produced by usp_ExtractStoreLocationMapping. */
CREATE OR ALTER PROCEDURE Pipeline.usp_AggregateDailyStoreSales
    @RunID BIGINT,
    @RowsProcessed INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @RowsProcessed = 0;

    IF EXISTS
    (
        SELECT 1 FROM Sales.Orders AS o
        LEFT JOIN Sales.OrderStoreMapping AS mapping ON mapping.OrderID = o.OrderID
        WHERE mapping.OrderID IS NULL OR mapping.MappedByRunID <> @RunID
    )
        THROW 51030, 'Store location mapping must run before daily store aggregation.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE FROM Sales.DailyStoreSalesSummary;

        INSERT Sales.DailyStoreSalesSummary
            (SalesDate, StoreID, CategoryName, OrderCount, UnitsSold, NetRevenue,
             RefreshedAt, RefreshedByRunID)
        SELECT o.OrderDate,
               mapping.StoreID,
               category.CategoryName,
               COUNT(DISTINCT o.OrderID),
               SUM(CONVERT(INT, line.Quantity)),
               SUM(CONVERT(DECIMAL(14, 2), line.Quantity * line.UnitPrice * (1 - line.DiscountPct))),
               SYSUTCDATETIME(),
               @RunID
        FROM Sales.Orders AS o
        JOIN Sales.OrderStoreMapping AS mapping ON mapping.OrderID = o.OrderID
        JOIN Sales.OrderLines AS line ON line.OrderID = o.OrderID
        JOIN Sales.ProductCatalog AS product ON product.ProductID = line.ProductID
        JOIN Sales.Categories AS category ON category.CategoryID = product.CategoryID
        WHERE o.OrderStatus <> 'Cancelled'
        GROUP BY o.OrderDate, mapping.StoreID, category.CategoryName;

        SET @RowsProcessed = @@ROWCOUNT;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
