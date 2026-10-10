USE SalesDB;
GO

CREATE OR ALTER PROCEDURE Pipeline.usp_RefreshCustomerValueSnapshot
    @RunID BIGINT,
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
            SELECT *, NTILE(4) OVER (ORDER BY LifetimeNetRevenue) AS RevenueQuartile
            FROM CustomerOrders
        )
        INSERT Sales.CustomerValueSnapshot
            (CustomerID, CustomerName, Country, Segment, FirstOrderDate, LastOrderDate,
             LifetimeOrderCount, LifetimeNetRevenue, AverageOrderValue, CustomerTier,
             RefreshedAt, RefreshedByRunID)
        SELECT CustomerID, CustomerName, Country, Segment, FirstOrderDate, LastOrderDate,
               LifetimeOrderCount, LifetimeNetRevenue,
               LifetimeNetRevenue / NULLIF(LifetimeOrderCount, 0),
               CASE WHEN LifetimeOrderCount = 0 THEN 'Prospect'
                    WHEN RevenueQuartile = 4 THEN 'High value'
                    WHEN RevenueQuartile = 3 THEN 'Growth'
                    WHEN RevenueQuartile = 2 THEN 'Core'
                    ELSE 'Developing' END,
               SYSUTCDATETIME(), @RunID
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
