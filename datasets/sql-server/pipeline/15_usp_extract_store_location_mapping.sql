USE SalesDB;
GO

/* Extracts customer location and maps every order to its serving store. */
CREATE OR ALTER PROCEDURE Pipeline.usp_ExtractStoreLocationMapping
    @RunID BIGINT,
    @RowsProcessed INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @RowsProcessed = 0;

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE FROM Sales.OrderStoreMapping;

        INSERT Sales.OrderStoreMapping
            (OrderID, StoreID, CustomerCountry, MappingMethod, MappedAt, MappedByRunID)
        SELECT o.OrderID,
               COALESCE(storeRule.StoreID, 10),
               c.Country,
               CASE WHEN storeRule.StoreID IS NULL THEN 'Regional default' ELSE 'Country rule' END,
               SYSUTCDATETIME(),
               @RunID
        FROM Sales.Orders AS o
        LEFT JOIN Sales.Customers AS c ON c.CustomerID = o.CustomerID
        LEFT JOIN Sales.CountryStoreRules AS storeRule ON storeRule.CustomerCountry = c.Country;

        SET @RowsProcessed = @@ROWCOUNT;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
