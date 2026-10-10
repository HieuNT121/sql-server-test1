/*
    Advanced Sales Analytics — SQL Server 2022
    Prerequisite: run datasets/sql-server/enrich-salesdb.sql in SalesDB.

    Topics: multi-CTE modeling, window functions, cohort retention,
    rolling periods, contribution analysis, inventory risk and reconciliation.
*/
USE SalesDB;
GO

/* 1. Monthly revenue, prior-month comparison, running total and 3-month average. */
;WITH MonthlySales AS
(
    SELECT DATEFROMPARTS(YEAR(OrderDate), MONTH(OrderDate), 1) AS SalesMonth,
           SUM(CONVERT(DECIMAL(14,2), Sales)) AS Revenue,
           COUNT_BIG(*) AS OrderCount
    FROM Sales.Orders
    WHERE OrderStatus <> 'Cancelled'
    GROUP BY DATEFROMPARTS(YEAR(OrderDate), MONTH(OrderDate), 1)
),
WithComparisons AS
(
    SELECT SalesMonth, Revenue, OrderCount,
           LAG(Revenue) OVER (ORDER BY SalesMonth) AS PreviousMonthRevenue,
           SUM(Revenue) OVER (ORDER BY SalesMonth ROWS UNBOUNDED PRECEDING) AS RunningRevenue,
           AVG(Revenue) OVER (ORDER BY SalesMonth ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS Rolling3MonthRevenue
    FROM MonthlySales
)
SELECT SalesMonth, Revenue, PreviousMonthRevenue,
       CONVERT(DECIMAL(8,2), 100.0 * (Revenue - PreviousMonthRevenue) / NULLIF(PreviousMonthRevenue, 0)) AS MoMPercent,
       RunningRevenue, Rolling3MonthRevenue, OrderCount
FROM WithComparisons
ORDER BY SalesMonth;
GO

/* 2. Customer RFM scoring: recency, frequency, monetary value and tier. */
;WITH CustomerRFM AS
(
    SELECT c.CustomerID,
           CONCAT(c.FirstName, ' ', c.LastName) AS CustomerName,
           c.Country,
           DATEDIFF(DAY, MAX(o.OrderDate), (SELECT MAX(OrderDate) FROM Sales.Orders)) AS RecencyDays,
           COUNT(DISTINCT o.OrderID) AS Frequency,
           SUM(CONVERT(DECIMAL(14,2), o.Sales)) AS MonetaryValue
    FROM Sales.Customers AS c
    JOIN Sales.Orders AS o ON o.CustomerID = c.CustomerID
    WHERE o.OrderStatus <> 'Cancelled'
    GROUP BY c.CustomerID, c.FirstName, c.LastName, c.Country
),
Scored AS
(
    SELECT *,
           NTILE(5) OVER (ORDER BY RecencyDays DESC) AS RecencyScore,
           NTILE(5) OVER (ORDER BY Frequency) AS FrequencyScore,
           NTILE(5) OVER (ORDER BY MonetaryValue) AS MonetaryScore
    FROM CustomerRFM
)
SELECT CustomerID, CustomerName, Country, RecencyDays, Frequency, MonetaryValue,
       RecencyScore, FrequencyScore, MonetaryScore,
       CASE WHEN RecencyScore >= 4 AND FrequencyScore >= 4 AND MonetaryScore >= 4 THEN 'Champions'
            WHEN RecencyScore >= 3 AND FrequencyScore >= 3 THEN 'Loyal customers'
            WHEN RecencyScore <= 2 AND FrequencyScore >= 3 THEN 'At risk'
            WHEN FrequencyScore = 1 THEN 'New / occasional'
            ELSE 'Needs attention' END AS CustomerTier
FROM Scored
ORDER BY MonetaryValue DESC;
GO

/* 3. Product Pareto: cumulative share of net sales by product. */
;WITH ProductRevenue AS
(
    SELECT pc.ProductID, pc.ProductName, cat.CategoryName,
           SUM(CONVERT(DECIMAL(14,2), ol.Quantity * ol.UnitPrice * (1 - ol.DiscountPct))) AS NetRevenue
    FROM Sales.OrderLines AS ol
    JOIN Sales.ProductCatalog AS pc ON pc.ProductID = ol.ProductID
    JOIN Sales.Categories AS cat ON cat.CategoryID = pc.CategoryID
    JOIN Sales.Orders AS o ON o.OrderID = ol.OrderID
    WHERE o.OrderStatus <> 'Cancelled'
    GROUP BY pc.ProductID, pc.ProductName, cat.CategoryName
),
Pareto AS
(
    SELECT *,
           SUM(NetRevenue) OVER (ORDER BY NetRevenue DESC, ProductID ROWS UNBOUNDED PRECEDING) AS CumulativeRevenue,
           SUM(NetRevenue) OVER () AS TotalRevenue
    FROM ProductRevenue
)
SELECT ProductID, ProductName, CategoryName, NetRevenue,
       CONVERT(DECIMAL(7,2), 100.0 * NetRevenue / NULLIF(TotalRevenue, 0)) AS RevenueSharePct,
       CONVERT(DECIMAL(7,2), 100.0 * CumulativeRevenue / NULLIF(TotalRevenue, 0)) AS CumulativeSharePct,
       CASE WHEN CumulativeRevenue - NetRevenue < TotalRevenue * 0.8 THEN 'Top 80% contributor' ELSE 'Long tail' END AS ParetoGroup
FROM Pareto
ORDER BY NetRevenue DESC;
GO

/* 4. Monthly cohort retention: first purchase month vs subsequent active months. */
;WITH FirstPurchase AS
(
    SELECT CustomerID, DATEFROMPARTS(YEAR(MIN(OrderDate)), MONTH(MIN(OrderDate)), 1) AS CohortMonth
    FROM Sales.Orders
    WHERE OrderStatus <> 'Cancelled'
    GROUP BY CustomerID
),
CustomerActivity AS
(
    SELECT DISTINCT o.CustomerID,
           DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1) AS ActivityMonth
    FROM Sales.Orders AS o
    WHERE o.OrderStatus <> 'Cancelled'
),
CohortActivity AS
(
    SELECT fp.CohortMonth, DATEDIFF(MONTH, fp.CohortMonth, ca.ActivityMonth) AS MonthNumber,
           COUNT(DISTINCT ca.CustomerID) AS ActiveCustomers
    FROM FirstPurchase AS fp
    JOIN CustomerActivity AS ca ON ca.CustomerID = fp.CustomerID
    GROUP BY fp.CohortMonth, DATEDIFF(MONTH, fp.CohortMonth, ca.ActivityMonth)
),
CohortSizes AS
(
    SELECT CohortMonth, COUNT(*) AS CohortCustomers
    FROM FirstPurchase
    GROUP BY CohortMonth
)
SELECT ca.CohortMonth, ca.MonthNumber, cs.CohortCustomers, ca.ActiveCustomers,
       CONVERT(DECIMAL(7,2), 100.0 * ca.ActiveCustomers / NULLIF(cs.CohortCustomers, 0)) AS RetentionPct
FROM CohortActivity AS ca
JOIN CohortSizes AS cs ON cs.CohortMonth = ca.CohortMonth
ORDER BY ca.CohortMonth, ca.MonthNumber;
GO

/* 5. Salesperson leaderboard with within-department rank and share. */
;WITH EmployeeSales AS
(
    SELECT e.EmployeeID, CONCAT(e.FirstName, ' ', e.LastName) AS EmployeeName,
           e.Department, e.ManagerID,
           COUNT(o.OrderID) AS OrderCount,
           SUM(CONVERT(DECIMAL(14,2), COALESCE(o.Sales, 0))) AS Revenue
    FROM Sales.Employees AS e
    LEFT JOIN Sales.Orders AS o
      ON o.SalesPersonID = e.EmployeeID AND o.OrderStatus <> 'Cancelled'
    GROUP BY e.EmployeeID, e.FirstName, e.LastName, e.Department, e.ManagerID
),
Ranked AS
(
    SELECT *,
           DENSE_RANK() OVER (PARTITION BY Department ORDER BY Revenue DESC) AS DepartmentRank,
           SUM(Revenue) OVER (PARTITION BY Department) AS DepartmentRevenue
    FROM EmployeeSales
)
SELECT EmployeeID, EmployeeName, Department, ManagerID, OrderCount, Revenue, DepartmentRank,
       CONVERT(DECIMAL(7,2), 100.0 * Revenue / NULLIF(DepartmentRevenue, 0)) AS DepartmentSharePct
FROM Ranked
ORDER BY Department, DepartmentRank, EmployeeID;
GO

/* 6. Return rate and refund exposure by product. */
;WITH Sold AS
(
    SELECT ProductID, SUM(Quantity) AS UnitsSold,
           SUM(CONVERT(DECIMAL(14,2), Quantity * UnitPrice * (1 - DiscountPct))) AS GrossLineRevenue
    FROM Sales.OrderLines
    GROUP BY ProductID
),
Returned AS
(
    SELECT ProductID, SUM(Quantity) AS UnitsReturned, SUM(RefundAmount) AS RefundAmount
    FROM Sales.Returns
    GROUP BY ProductID
)
SELECT pc.ProductName, s.UnitsSold, COALESCE(r.UnitsReturned, 0) AS UnitsReturned,
       CONVERT(DECIMAL(7,2), 100.0 * COALESCE(r.UnitsReturned, 0) / NULLIF(s.UnitsSold, 0)) AS UnitReturnRatePct,
       s.GrossLineRevenue, COALESCE(r.RefundAmount, 0) AS RefundAmount,
       s.GrossLineRevenue - COALESCE(r.RefundAmount, 0) AS RevenueAfterRefunds
FROM Sold AS s
JOIN Sales.ProductCatalog AS pc ON pc.ProductID = s.ProductID
LEFT JOIN Returned AS r ON r.ProductID = s.ProductID
ORDER BY UnitReturnRatePct DESC, RefundAmount DESC;
GO

/* 7. Inventory pressure: compare last snapshot with trailing 90-day unit demand. */
;WITH LatestSnapshotDate AS
(
    SELECT MAX(SnapshotDate) AS SnapshotDate FROM Sales.InventorySnapshots
),
RecentDemand AS
(
    SELECT ol.ProductID, SUM(ol.Quantity) AS UnitsLast90Days
    FROM Sales.OrderLines AS ol
    JOIN Sales.Orders AS o ON o.OrderID = ol.OrderID
    CROSS JOIN LatestSnapshotDate AS d
    WHERE o.OrderDate >= DATEADD(DAY, -90, d.SnapshotDate)
      AND o.OrderDate < DATEADD(DAY, 1, d.SnapshotDate)
      AND o.OrderStatus <> 'Cancelled'
    GROUP BY ol.ProductID
),
Inventory AS
(
    SELECT i.ProductID, i.Warehouse, i.OnHand, i.ReorderPoint,
           SUM(i.OnHand) OVER (PARTITION BY i.ProductID) AS TotalNetworkOnHand
    FROM Sales.InventorySnapshots AS i
    JOIN LatestSnapshotDate AS d ON d.SnapshotDate = i.SnapshotDate
)
SELECT pc.ProductName, i.Warehouse, i.OnHand, i.ReorderPoint,
       COALESCE(rd.UnitsLast90Days, 0) AS UnitsLast90Days,
       CONVERT(DECIMAL(8,2), 90.0 * i.TotalNetworkOnHand / NULLIF(rd.UnitsLast90Days, 0)) AS ApproxDaysOfCover,
       CASE WHEN i.OnHand <= i.ReorderPoint THEN 'Reorder now'
            WHEN i.TotalNetworkOnHand < COALESCE(rd.UnitsLast90Days, 0) THEN 'Watch closely'
            ELSE 'Healthy' END AS StockSignal
FROM Inventory AS i
JOIN Sales.ProductCatalog AS pc ON pc.ProductID = i.ProductID
LEFT JOIN RecentDemand AS rd ON rd.ProductID = i.ProductID
ORDER BY CASE WHEN i.OnHand <= i.ReorderPoint THEN 0 ELSE 1 END, ApproxDaysOfCover;
GO

/* 8. Data quality and financial reconciliation checks. */
;WITH LineTotals AS
(
    SELECT OrderID, SUM(Quantity * UnitPrice * (1 - DiscountPct)) AS CalculatedLineSales
    FROM Sales.OrderLines
    GROUP BY OrderID
),
PaymentTotals AS
(
    SELECT OrderID,
           SUM(CASE WHEN PaymentStatus = 'Captured' THEN Amount ELSE 0 END) AS CapturedAmount,
           SUM(CASE WHEN PaymentStatus = 'Refunded' THEN Amount ELSE 0 END) AS RefundedAmount
    FROM Sales.Payments
    GROUP BY OrderID
)
SELECT o.OrderID, o.OrderStatus, o.Sales AS HeaderSales,
       COALESCE(lt.CalculatedLineSales, 0) AS CalculatedLineSales,
       COALESCE(pt.CapturedAmount, 0) AS CapturedAmount,
       COALESCE(pt.RefundedAmount, 0) AS RefundedAmount,
       CASE WHEN ABS(o.Sales - COALESCE(lt.CalculatedLineSales, 0)) > 1 THEN 'Review line total'
            WHEN o.OrderStatus = 'Delivered' AND COALESCE(pt.CapturedAmount, 0) = 0 THEN 'Missing capture'
            ELSE 'OK' END AS AuditResult
FROM Sales.Orders AS o
LEFT JOIN LineTotals AS lt ON lt.OrderID = o.OrderID
LEFT JOIN PaymentTotals AS pt ON pt.OrderID = o.OrderID
WHERE o.OrderID >= 1001
ORDER BY CASE WHEN o.Sales <> COALESCE(lt.CalculatedLineSales, 0) THEN 0 ELSE 1 END, o.OrderID;
GO

/* 9. Parameterized stored procedure example: country and date range summary. */
CREATE OR ALTER PROCEDURE Sales.GetCountrySalesSummary
    @StartDate DATE,
    @EndDate   DATE,
    @Country   VARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @StartDate IS NULL OR @EndDate IS NULL OR @EndDate < @StartDate
        THROW 50001, 'Provide a valid inclusive date range.', 1;

    SELECT c.Country,
           COUNT(DISTINCT o.OrderID) AS OrderCount,
           COUNT(DISTINCT o.CustomerID) AS CustomerCount,
           SUM(CONVERT(DECIMAL(14,2), o.Sales)) AS Revenue,
           AVG(CONVERT(DECIMAL(14,2), o.Sales)) AS AverageOrderValue
    FROM Sales.Orders AS o
    JOIN Sales.Customers AS c ON c.CustomerID = o.CustomerID
    WHERE o.OrderDate >= @StartDate
      AND o.OrderDate < DATEADD(DAY, 1, @EndDate)
      AND o.OrderStatus <> 'Cancelled'
      AND (@Country IS NULL OR c.Country = @Country)
    GROUP BY c.Country
    ORDER BY Revenue DESC;
END;
GO

EXEC Sales.GetCountrySalesSummary
    @StartDate = '2025-01-01', @EndDate = '2025-12-31', @Country = NULL;
GO
