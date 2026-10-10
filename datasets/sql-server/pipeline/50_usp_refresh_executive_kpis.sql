USE SalesDB;
GO

CREATE OR ALTER PROCEDURE Pipeline.usp_RefreshExecutiveKpis
    @RunID BIGINT,
    @RowsProcessed INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @RowsProcessed = 0;

    DECLARE @TopCountry VARCHAR(50);
    DECLARE @TopStore NVARCHAR(120);
    DECLARE @TopProduct NVARCHAR(120);

    SELECT TOP (1) @TopCountry = Country
    FROM Sales.DailySalesSummary
    GROUP BY Country
    ORDER BY SUM(NetRevenue) DESC, Country;

    SELECT TOP (1) @TopStore = store.StoreName
    FROM Sales.DailyStoreSalesSummary AS summary
    JOIN Sales.StoreLocations AS store ON store.StoreID = summary.StoreID
    GROUP BY store.StoreID, store.StoreName
    ORDER BY SUM(summary.NetRevenue) DESC, store.StoreID;

    SELECT TOP (1) @TopProduct = ProductName
    FROM Sales.ProductPerformanceSnapshot
    ORDER BY RevenueRank, ProductID;

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE FROM Sales.ExecutiveKpiSnapshot;

        INSERT Sales.ExecutiveKpiSnapshot
            (SnapshotID, AsOfDate, TotalOrders, ActiveCustomers, NetRevenue,
             AverageOrderValue, RefundAmount, ReturnRatePct, TopCountry, TopStore, TopProduct,
             RefreshedAt, RefreshedByRunID)
        SELECT 1,
               MAX(o.OrderDate),
               COUNT(DISTINCT o.OrderID),
               COUNT(DISTINCT o.CustomerID),
               SUM(CONVERT(DECIMAL(14, 2), o.Sales)),
               AVG(CONVERT(DECIMAL(14, 2), o.Sales)),
               (SELECT COALESCE(SUM(RefundAmount), 0) FROM Sales.Returns),
               CONVERT(DECIMAL(7, 2), 100.0 *
                   (SELECT COALESCE(SUM(Quantity), 0) FROM Sales.Returns) /
                   NULLIF((SELECT SUM(CONVERT(BIGINT, Quantity)) FROM Sales.OrderLines), 0)),
               @TopCountry,
               @TopStore,
               @TopProduct,
               SYSUTCDATETIME(),
               @RunID
        FROM Sales.Orders AS o
        WHERE o.OrderStatus <> 'Cancelled';

        SET @RowsProcessed = @@ROWCOUNT;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
