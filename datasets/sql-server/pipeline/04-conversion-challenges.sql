/*
=============================================================================
 04-conversion-challenges.sql
=============================================================================
 30 T-SQL scripts against SalesDB (after 03-advanced-salesdb.sql) that
 exercise behaviour which is easy to convert WRONG into PySpark/Spark SQL.

 Each block is self-contained (its own GO batch) and starts with:
   -- TRAP: what a naive conversion gets wrong
 Run each block in SQL Server and in the converted Databricks notebook,
 then diff the results. Many of them still RUN after a bad conversion but
 return different numbers, which is exactly what you want to catch.

 Levels:  [L1] syntax mapping   [L2] semantic difference   [L3] procedural / no direct equivalent
=============================================================================
*/
USE SalesDB;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* C01 [L1] TOP WITH TIES
   TRAP: .limit(5) drops tied customers; needs rank() <= 5. */
SELECT TOP (5) WITH TIES
       CustomerID, SUM(Sales) AS Revenue
FROM Sales.Orders
WHERE OrderStatus <> 'Cancelled'
GROUP BY CustomerID
ORDER BY Revenue DESC;
GO

/* C02 [L1] OFFSET / FETCH paging with variables
   TRAP: Spark has OFFSET only in newer runtimes; ordering must be total (tie-breaker). */
DECLARE @PageNo INT = 3, @PageSize INT = 20;
SELECT OrderID, OrderDate, CustomerID, Sales
FROM Sales.Orders
ORDER BY OrderDate DESC, OrderID
OFFSET (@PageNo - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
GO

/* C03 [L2] CROSS APPLY with TOP n per outer row
   TRAP: correlated TOP has no Spark equivalent; must become row_number() over a partition.
         Customers with no orders must disappear (CROSS, not OUTER). */
SELECT c.CustomerID, c.FirstName, x.OrderID, x.OrderDate, x.Sales
FROM Sales.Customers AS c
CROSS APPLY
(
    SELECT TOP (2) o.OrderID, o.OrderDate, o.Sales
    FROM Sales.Orders AS o
    WHERE o.CustomerID = c.CustomerID
    ORDER BY o.OrderDate DESC, o.OrderID DESC
) AS x
ORDER BY c.CustomerID, x.OrderDate DESC;
GO

/* C04 [L2] As-of join (latest FX rate on or before the invoice date)
   TRAPS: OUTER APPLY TOP 1 -> range join + window; gaps (weekends, VND outage);
          CONVERT(DATE, datetimeoffset) uses the LOCAL date, not UTC;
          USD has no rate rows. */
SELECT i.InvoiceID, i.CurrencyCode,
       i.IssuedAt,
       CONVERT(DATE, i.IssuedAt) AS IssueDateLocal,
       i.TotalAmount,
       fx.RateDate,
       fx.RateToUSD,
       DATEDIFF(DAY, fx.RateDate, CONVERT(DATE, i.IssuedAt)) AS RateAgeDays,
       CONVERT(DECIMAL(14,2),
           i.TotalAmount / COALESCE(fx.RateToUSD, CASE WHEN i.CurrencyCode = 'USD' THEN 1 END)) AS TotalUSD
FROM Sales.Invoices AS i
OUTER APPLY
(
    SELECT TOP (1) r.RateDate, r.RateToUSD
    FROM Sales.ExchangeRates AS r
    WHERE r.CurrencyCode = i.CurrencyCode
      AND r.RateDate <= CONVERT(DATE, i.IssuedAt)
    ORDER BY r.RateDate DESC
) AS fx
ORDER BY RateAgeDays DESC, i.InvoiceID;
GO

/* C05 [L3] Recursive CTE: org chart path + subtree salary, MAXRECURSION hint
   TRAP: Spark has no recursive CTE on most runtimes; needs an iterative loop. */
WITH Org AS
(
    SELECT EmployeeID, ManagerID, FirstName, 0 AS Depth,
           CONVERT(VARCHAR(500), FirstName) AS ChainOfCommand,
           CONVERT(VARCHAR(500), RIGHT('000' + CONVERT(VARCHAR(3), EmployeeID), 3)) AS SortPath
    FROM Sales.Employees
    WHERE ManagerID IS NULL
    UNION ALL
    SELECT e.EmployeeID, e.ManagerID, e.FirstName, o.Depth + 1,
           CONVERT(VARCHAR(500), o.ChainOfCommand + ' > ' + e.FirstName),
           CONVERT(VARCHAR(500), o.SortPath + '.' + RIGHT('000' + CONVERT(VARCHAR(3), e.EmployeeID), 3))
    FROM Sales.Employees AS e
    JOIN Org AS o ON e.ManagerID = o.EmployeeID
),
AncestorPairs AS   -- every (ancestor, descendant) pair incl. self
(
    SELECT EmployeeID AS AncestorID, EmployeeID AS DescendantID FROM Sales.Employees
    UNION ALL
    SELECT ap.AncestorID, e.EmployeeID
    FROM AncestorPairs AS ap
    JOIN Sales.Employees AS e ON e.ManagerID = ap.DescendantID
)
SELECT REPLICATE('    ', o.Depth) + o.FirstName AS OrgTree,
       o.Depth,
       o.ChainOfCommand,
       COUNT(*) - 1          AS Reports,
       SUM(emp.Salary)       AS SubtreeSalary
FROM Org AS o
JOIN AncestorPairs AS ap ON ap.AncestorID = o.EmployeeID
JOIN Sales.Employees AS emp ON emp.EmployeeID = ap.DescendantID
GROUP BY o.EmployeeID, o.FirstName, o.Depth, o.ChainOfCommand, o.SortPath
ORDER BY o.SortPath
OPTION (MAXRECURSION 20);
GO

/* C06 [L2] Gaps and islands: consecutive months with orders
   TRAPS: DATEADD(MONTH, -bigint) needs INT; month arithmetic on day 1 only. */
WITH M AS
(
    SELECT DISTINCT CustomerID,
           DATEFROMPARTS(YEAR(OrderDate), MONTH(OrderDate), 1) AS OrderMonth
    FROM Sales.Orders
    WHERE OrderStatus <> 'Cancelled'
),
G AS
(
    SELECT CustomerID, OrderMonth,
           DATEADD(MONTH,
                   -CONVERT(INT, ROW_NUMBER() OVER (PARTITION BY CustomerID ORDER BY OrderMonth)),
                   OrderMonth) AS IslandKey
    FROM M
)
SELECT CustomerID,
       MIN(OrderMonth) AS StreakStart,
       MAX(OrderMonth) AS StreakEnd,
       COUNT(*)        AS MonthsInStreak
FROM G
GROUP BY CustomerID, IslandKey
HAVING COUNT(*) >= 2
ORDER BY MonthsInStreak DESC, CustomerID, StreakStart;
GO

/* C07 [L2] Sessionization of JSON events (30-minute inactivity rule)
   TRAPS: DATEDIFF(MINUTE) counts minute BOUNDARIES crossed, not elapsed minutes
          (10:00:59 -> 10:01:00 = 1); ISJSON filter; JSON_VALUE path. */
WITH E AS
(
    SELECT EventID, CustomerID, EventTime,
           JSON_VALUE(CASE WHEN ISJSON(Payload) = 1 THEN Payload END, '$.type') AS EventType,
           CASE WHEN DATEDIFF(MINUTE,
                              LAG(EventTime) OVER (PARTITION BY CustomerID ORDER BY EventTime, EventID),
                              EventTime) <= 30
                THEN 0 ELSE 1 END AS IsNewSession
    FROM Sales.WebEvents
    WHERE ISJSON(Payload) = 1
),
S AS
(
    SELECT *,
           SUM(IsNewSession) OVER (PARTITION BY CustomerID ORDER BY EventTime, EventID
                                   ROWS UNBOUNDED PRECEDING) AS SessionNo
    FROM E
)
SELECT CustomerID, SessionNo,
       MIN(EventTime) AS SessionStart,
       MAX(EventTime) AS SessionEnd,
       DATEDIFF(SECOND, MIN(EventTime), MAX(EventTime)) AS DurationSec,
       COUNT(*) AS Events,
       MAX(CASE WHEN EventType = 'purchase' THEN 1 ELSE 0 END) AS Converted
FROM S
GROUP BY CustomerID, SessionNo
ORDER BY CustomerID, SessionNo;
GO

/* C08 [L2] Window frames and integer AVG
   TRAPS: default frame with ORDER BY is RANGE (ties on OrderDate share a total);
          AVG over an INT column returns INT in SQL Server (truncated) but double in Spark. */
SELECT CustomerID, OrderDate, OrderID, Sales,
       SUM(Sales) OVER (PARTITION BY CustomerID ORDER BY OrderDate)                     AS RunTotal_DefaultRange,
       SUM(Sales) OVER (PARTITION BY CustomerID ORDER BY OrderDate, OrderID
                        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)              AS RunTotal_Rows,
       AVG(Sales) OVER (PARTITION BY CustomerID)                                       AS AvgSales_IntTruncated,
       AVG(CONVERT(DECIMAL(10,2), Sales)) OVER (PARTITION BY CustomerID ORDER BY OrderDate, OrderID
                                                ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS Moving3
FROM Sales.Orders
WHERE CustomerID IN (41, 42, 44, 45, 2)
ORDER BY CustomerID, OrderDate, OrderID;
GO

/* C09 [L2] LAG/LEAD defaults, FIRST_VALUE / LAST_VALUE frame trap
   TRAP: LAST_VALUE with default frame returns the CURRENT row, not the last one. */
SELECT CustomerID, OrderID, OrderDate, Sales,
       LAG(Sales, 1, 0)  OVER (PARTITION BY CustomerID ORDER BY OrderDate, OrderID) AS PrevSales,
       LEAD(OrderDate)   OVER (PARTITION BY CustomerID ORDER BY OrderDate, OrderID) AS NextOrderDate,
       DATEDIFF(DAY, OrderDate,
                LEAD(OrderDate) OVER (PARTITION BY CustomerID ORDER BY OrderDate, OrderID)) AS DaysToNext,
       FIRST_VALUE(OrderID) OVER (PARTITION BY CustomerID ORDER BY OrderDate, OrderID) AS FirstOrder,
       LAST_VALUE(OrderID)  OVER (PARTITION BY CustomerID ORDER BY OrderDate, OrderID) AS LastValue_Wrong,
       LAST_VALUE(OrderID)  OVER (PARTITION BY CustomerID ORDER BY OrderDate, OrderID
                                  ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS LastOrder
FROM Sales.Orders
WHERE CustomerID BETWEEN 1 AND 5
ORDER BY CustomerID, OrderDate, OrderID;
GO

/* C10 [L2] PERCENTILE_CONT / PERCENTILE_DISC as window functions + NTILE
   TRAP: in T-SQL these are windowed (need DISTINCT); in Spark they are aggregates. */
SELECT DISTINCT
       c.Country,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY o.Sales) OVER (PARTITION BY c.Country) AS MedianSales,
       PERCENTILE_DISC(0.9) WITHIN GROUP (ORDER BY o.Sales) OVER (PARTITION BY c.Country) AS P90Sales_Disc
FROM Sales.Orders AS o
JOIN Sales.Customers AS c ON c.CustomerID = o.CustomerID
ORDER BY c.Country;

SELECT CustomerID, Score,
       NTILE(4) OVER (ORDER BY Score DESC, CustomerID) AS Quartile,
       PERCENT_RANK() OVER (ORDER BY Score) AS PctRank,
       CUME_DIST()    OVER (ORDER BY Score) AS CumeDist
FROM Sales.Customers
ORDER BY Score DESC, CustomerID;
GO

/* C11 [L1] GROUPING SETS / ROLLUP / CUBE with GROUPING() labels
   TRAP: NULL Country from data vs NULL from the rollup must be told apart. */
SELECT CASE WHEN GROUPING(c.Country) = 1 THEN '<ALL COUNTRIES>'
            ELSE ISNULL(c.Country, '<unknown>') END                    AS Country,
       CASE WHEN GROUPING(YEAR(o.OrderDate)) = 1 THEN 'ALL'
            ELSE CONVERT(VARCHAR(4), YEAR(o.OrderDate)) END            AS OrderYear,
       GROUPING_ID(c.Country, YEAR(o.OrderDate))                       AS GroupingLevel,
       COUNT(*)            AS Orders,
       SUM(o.Sales)        AS Revenue,
       COUNT(o.Sales)      AS OrdersWithSales
FROM Sales.Orders AS o
JOIN Sales.Customers AS c ON c.CustomerID = o.CustomerID
GROUP BY ROLLUP (c.Country, YEAR(o.OrderDate))
ORDER BY GroupingLevel, Country, OrderYear;
GO

/* C12 [L1] Static PIVOT and UNPIVOT
   TRAP: UNPIVOT silently drops NULLs; Spark stack()/unpivot keeps them unless filtered. */
SELECT PaymentMethod, [Captured], [Pending], [Refunded], [Failed]
FROM
(
    SELECT PaymentMethod, PaymentStatus, Amount FROM Sales.Payments
) AS src
PIVOT (SUM(Amount) FOR PaymentStatus IN ([Captured], [Pending], [Refunded], [Failed])) AS p
ORDER BY PaymentMethod;

SELECT OrderID, AddressType, AddressValue
FROM (SELECT OrderID, ShipAddress, BillAddress FROM Sales.Orders WHERE OrderID BETWEEN 2001 AND 2012) AS s
UNPIVOT (AddressValue FOR AddressType IN (ShipAddress, BillAddress)) AS u
ORDER BY OrderID, AddressType;
GO

/* C13 [L1] STRING_AGG ordered, STRING_SPLIT with ordinal
   TRAPS: WITHIN GROUP ordering (collect_list is unordered);
          STRING_SPLIT keeps empty strings and does not trim. */
SELECT o.CustomerID,
       STRING_AGG(CONVERT(VARCHAR(10), o.OrderID), ',') WITHIN GROUP (ORDER BY o.OrderDate DESC, o.OrderID) AS OrdersNewestFirst,
       STRING_AGG(o.OrderStatus, ' | ')                                                                     AS Statuses
FROM Sales.Orders AS o
WHERE o.CustomerID >= 41
GROUP BY o.CustomerID
ORDER BY o.CustomerID;

SELECT f.FeedRowID, f.TagsCsv, s.ordinal, s.value AS RawTag, LTRIM(RTRIM(s.value)) AS Tag
FROM Sales.RawCustomerFeed AS f
CROSS APPLY STRING_SPLIT(f.TagsCsv, ',', 1) AS s
ORDER BY f.FeedRowID, s.ordinal;
GO

/* C14 [L2] Date function semantics
   TRAPS: DATEDIFF counts boundaries (Dec 31 -> Jan 1 = 1 year) vs months_between/floor;
          DATEPART(WEEKDAY) depends on SET DATEFIRST; ISO_WEEK; FORMAT is .NET formatting;
          CONVERT style codes; DATETRUNC; EOMONTH(date, offset). */
SET DATEFIRST 1;   -- Monday = 1 (session setting that changes results!)
SELECT o.OrderID, o.OrderDate, o.ShipDate,
       DATEDIFF(DAY,   o.OrderDate, o.ShipDate)                 AS DaysToShip,
       DATEDIFF(MONTH, o.OrderDate, o.ShipDate)                 AS MonthBoundaries,
       DATEDIFF(YEAR,  o.OrderDate, o.ShipDate)                 AS YearBoundaries,
       EOMONTH(o.OrderDate)                                     AS MonthEnd,
       EOMONTH(o.OrderDate, -1)                                 AS PrevMonthEnd,
       DATEADD(MONTH, 1, o.OrderDate)                           AS PlusOneMonth,   -- May 31 -> Jun 30
       DATEPART(WEEKDAY, o.OrderDate)                           AS WeekdayNo,
       DATENAME(WEEKDAY, o.OrderDate)                           AS WeekdayName,
       DATEPART(ISO_WEEK, o.OrderDate)                          AS IsoWeek,
       DATEPART(WEEK, o.OrderDate)                              AS UsWeek,
       DATETRUNC(QUARTER, o.OrderDate)                          AS QuarterStart,
       CONVERT(VARCHAR(10), o.OrderDate, 103)                   AS UkFormat,
       CONVERT(VARCHAR(8),  o.OrderDate, 112)                   AS IsoBasic,
       FORMAT(o.OrderDate, 'dddd, d MMMM yyyy', 'de-DE')        AS GermanLong,
       Sales.fn_FiscalQuarter(o.OrderDate)                      AS FiscalQuarter
FROM Sales.Orders AS o
WHERE o.OrderID BETWEEN 2001 AND 2012
ORDER BY o.OrderID;
SET DATEFIRST 7;
GO

/* C15 [L2] Time zones with DATETIMEOFFSET and Windows zone names
   TRAPS: 'SE Asia Standard Time' / 'W. Europe Standard Time' are Windows IDs
          (Spark needs IANA: Asia/Bangkok, Europe/Berlin); DST; Spark TIMESTAMP has no offset. */
SELECT TOP (25)
       InvoiceID, CurrencyCode, IssuedAt,
       DATEPART(TZOFFSET, IssuedAt)                                        AS OffsetMinutes,
       SWITCHOFFSET(IssuedAt, '+00:00')                                    AS IssuedUtc,
       CONVERT(DATE, IssuedAt)                                             AS LocalDate,
       CONVERT(DATE, SWITCHOFFSET(IssuedAt, '+00:00'))                     AS UtcDate,
       IssuedAt AT TIME ZONE 'SE Asia Standard Time'                       AS IssuedBangkok,
       IssuedAt AT TIME ZONE 'W. Europe Standard Time'                     AS IssuedBerlin_DSTAware,
       CONVERT(DATETIME2(0), IssuedAt AT TIME ZONE 'Pacific Standard Time') AS IssuedLA_NoOffset
FROM Sales.Invoices
WHERE CONVERT(DATE, IssuedAt) <> CONVERT(DATE, SWITCHOFFSET(IssuedAt, '+00:00'))
ORDER BY InvoiceID;

-- naive local datetime -> offset, including a DST gap/overlap day in Europe
SELECT v.LocalTime,
       v.LocalTime AT TIME ZONE 'W. Europe Standard Time' AS WithBerlinOffset
FROM (VALUES (CONVERT(DATETIME2(0), '2026-03-29T02:30:00')),   -- does not exist (spring forward)
             (CONVERT(DATETIME2(0), '2026-10-25T02:30:00')),   -- happens twice (fall back)
             (CONVERT(DATETIME2(0), '2026-07-01T12:00:00'))) AS v (LocalTime);
GO

/* C16 [L2] String and NULL semantics that differ from Spark
   TRAPS: case-insensitive collation and trailing-space-insensitive '=' and GROUP BY;
          '+' with NULL -> NULL but CONCAT ignores NULL; ISNULL truncates to the first arg's type;
          LEN ignores trailing spaces, DATALENGTH counts bytes; emoji = 2 UTF-16 units;
          '10' + 5 = 15 (implicit numeric), integer division. */
SELECT Country, COUNT(*) AS Customers, MIN(CustomerID) AS FirstID
FROM Sales.Customers
GROUP BY Country                       -- 'Germany', 'germany', 'Germany ' => ONE group here
ORDER BY Country;

SELECT CustomerID,
       FirstName + ' ' + LastName                         AS PlusConcat_NullProp,
       CONCAT(FirstName, ' ', LastName)                   AS ConcatFn,
       CONCAT_WS(' ', FirstName, LastName)                AS ConcatWs,
       ISNULL(CONVERT(VARCHAR(3), NULL), 'Unknown')       AS IsNull_Truncates,     -- 'Unk'
       COALESCE(CONVERT(VARCHAR(3), NULL), 'Unknown')     AS Coalesce_Full,
       LEN(LastName)                                      AS Len_IgnoresTrailing,
       DATALENGTH(LastName)                               AS ByteLen,
       CASE WHEN Country = 'GERMANY' THEN 1 ELSE 0 END    AS CaseInsensitiveEq,
       '10' + 5                                           AS ImplicitNumeric,
       7 / 2                                              AS IntDivision,
       7 / 2.0                                            AS DecDivision,
       Score % 7                                          AS ModNullable
FROM Sales.Customers
WHERE CustomerID IN (3, 5, 41, 42, 44, 45);

SELECT InvoiceID, Notes,
       LEN(Notes)        AS LenChars,
       DATALENGTH(Notes) AS Bytes,
       CHARINDEX(N'–', Notes) AS DashPos,
       CASE WHEN Notes LIKE N'%[[]SPRING[_]25]%' THEN 1 ELSE 0 END AS LikeEscapedBrackets,
       CASE WHEN Notes LIKE N'%50[%]%'           THEN 1 ELSE 0 END AS LikeEscapedPercent,
       REPLACE(REPLACE(Notes, NCHAR(13), N''), NCHAR(10), N' ') AS OneLine
FROM Sales.Invoices
WHERE InvoiceID IN (SELECT MIN(InvoiceID) FROM Sales.Invoices GROUP BY OrderID % 9);
GO

/* C17 [L2] Cleaning a text-typed feed: TRY_CONVERT / TRY_PARSE / ISNUMERIC
   TRAPS: style codes (101 US, 103 UK, 104 DE, 112 ISO basic); TRY_PARSE culture;
          ISNUMERIC('$980') = 1 and ISNUMERIC('1.2e3') = 1 but CONVERT(INT) fails;
          '2025-02-30' must become NULL, not an error or Mar 2;
          latest load per CustomerRef wins (dedupe). */
WITH Parsed AS
(
    SELECT f.*,
           UPPER(LTRIM(RTRIM(f.CustomerRef))) AS CustomerKey,
           COALESCE(
               TRY_CONVERT(DATE, f.SignupDateRaw, 23),     -- yyyy-mm-dd
               TRY_CONVERT(DATE, f.SignupDateRaw, 112),    -- yyyymmdd
               TRY_CONVERT(DATE, f.SignupDateRaw, 101),    -- mm/dd/yyyy
               TRY_CONVERT(DATE, f.SignupDateRaw, 103),    -- dd/mm/yyyy
               TRY_CONVERT(DATE, f.SignupDateRaw, 104),    -- dd.mm.yyyy
               TRY_CONVERT(DATE, f.SignupDateRaw, 111),    -- yyyy/mm/dd
               TRY_CONVERT(DATE, LEFT(f.SignupDateRaw, 10), 23),
               TRY_PARSE(f.SignupDateRaw AS DATE USING 'en-US')) AS SignupDate,
           ISNUMERIC(f.LifetimeValueRaw) AS IsNumericSays,
           COALESCE(
               TRY_PARSE(f.LifetimeValueRaw AS DECIMAL(14,2) USING 'en-US'),
               TRY_PARSE(f.LifetimeValueRaw AS DECIMAL(14,2) USING 'de-DE'),
               TRY_CONVERT(DECIMAL(14,2), TRY_CONVERT(FLOAT, f.LifetimeValueRaw))) AS LifetimeValue,
           NULLIF(TRANSLATE(f.PhoneRaw, '()-. ', '     '), '') AS PhoneSpaced,
           REPLACE(TRANSLATE(f.PhoneRaw, '()-.+', '     '), ' ', '') AS PhoneDigits,
           CASE UPPER(LTRIM(RTRIM(f.CountryRaw)))
                WHEN 'U.S.A.' THEN 'USA' WHEN 'UNITED STATES' THEN 'USA' WHEN 'USA' THEN 'USA'
                WHEN 'DE' THEN 'Germany' WHEN 'DEUTSCHLAND' THEN 'Germany' WHEN 'GERMANY' THEN 'Germany'
                WHEN N'VIỆT NAM' THEN 'Vietnam'
                WHEN 'N/A' THEN NULL
                ELSE LTRIM(RTRIM(f.CountryRaw)) END AS CountryClean,
           ROW_NUMBER() OVER (PARTITION BY UPPER(LTRIM(RTRIM(f.CustomerRef)))
                              ORDER BY f.LoadedAt DESC, f.FeedRowID DESC) AS rn
    FROM Sales.RawCustomerFeed AS f
)
SELECT FeedRowID, CustomerKey, FullName,
       LTRIM(RTRIM(REPLACE(REPLACE(FullName, '  ', ' '), '  ', ' '))) AS FullNameClean,
       CountryClean, SignupDateRaw, SignupDate,
       LifetimeValueRaw, IsNumericSays, LifetimeValue,
       PhoneRaw, PhoneDigits,
       TRY_CONVERT(INT, SUBSTRING(CustomerKey, 3, 10)) AS CustomerID
FROM Parsed
WHERE rn = 1 OR CustomerKey IS NULL
ORDER BY CustomerKey;
GO

/* C18 [L2] JSON: OPENJSON WITH schema, nested arrays, JSON_QUERY
   TRAPS: OPENJSON + CROSS APPLY -> from_json + explode; malformed rows must be skipped;
          JSON null vs missing key; numbers in JSON vs DECIMAL. */
SELECT e.EventID, e.CustomerID, e.EventTime,
       j.EventType, j.DeviceOS, j.AppVersion, j.UtmSource,
       it.Sku, it.Qty, it.Price,
       it.Qty * it.Price AS LineValue,
       JSON_QUERY(CASE WHEN ISJSON(e.Payload) = 1 THEN e.Payload END, '$.device') AS DeviceJson
FROM Sales.WebEvents AS e
CROSS APPLY OPENJSON(CASE WHEN ISJSON(e.Payload) = 1 THEN e.Payload END)   -- guard: invalid JSON raises an error
     WITH (EventType  VARCHAR(20)  '$.type',
           DeviceOS   VARCHAR(10)  '$.device.os',
           AppVersion VARCHAR(10)  '$.device.appVersion',
           UtmSource  VARCHAR(30)  '$.utm.source',
           Items      NVARCHAR(MAX) '$.items' AS JSON) AS j
CROSS APPLY OPENJSON(j.Items)
     WITH (Sku   VARCHAR(20)   '$.sku',
           Qty   INT           '$.qty',
           Price DECIMAL(10,2) '$.price') AS it
WHERE ISJSON(e.Payload) = 1
  AND j.EventType = 'purchase'
ORDER BY e.EventTime, e.EventID;

-- funnel by device, counting malformed payloads separately
SELECT COALESCE(JSON_VALUE(j.Doc, '$.device.os'), '<malformed>') AS DeviceOS,
       SUM(CASE WHEN JSON_VALUE(j.Doc, '$.type') = 'page_view'   THEN 1 ELSE 0 END) AS Views,
       SUM(CASE WHEN JSON_VALUE(j.Doc, '$.type') = 'add_to_cart' THEN 1 ELSE 0 END) AS Carts,
       SUM(CASE WHEN JSON_VALUE(j.Doc, '$.type') = 'purchase'    THEN 1 ELSE 0 END) AS Purchases,
       SUM(CASE WHEN j.Doc IS NULL THEN 1 ELSE 0 END)                             AS BadRows
FROM Sales.WebEvents AS e
CROSS APPLY (SELECT CASE WHEN ISJSON(e.Payload) = 1 THEN e.Payload END AS Doc) AS j
GROUP BY COALESCE(JSON_VALUE(j.Doc, '$.device.os'), '<malformed>');
GO

/* C19 [L3] XML: .value(), .nodes(), .exist()
   TRAP: no XML type in Spark; needs xpath functions or a UDF. */
SELECT pa.ProductID,
       pa.Attributes.value('(/attributes/@sku)[1]', 'VARCHAR(20)')                       AS Sku,
       pa.Attributes.value('(/attributes/attr[@name="color"])[1]', 'VARCHAR(20)')        AS Color,
       pa.Attributes.value('(/attributes/attr[@name="weight_g"])[1]', 'INT')             AS WeightG,
       pa.Attributes.exist('/attributes/battery')                                        AS HasBattery,
       s.n.value('@code', 'VARCHAR(5)')                                                   AS SizeCode,
       s.n.value('@stock', 'INT')                                                         AS SizeStock
FROM Sales.ProductAttributes AS pa
OUTER APPLY pa.Attributes.nodes('/attributes/sizes/size') AS s(n)
ORDER BY pa.ProductID, SizeCode;
GO

/* C20 [L2] Range join: best applicable promotion per order line
   TRAPS: open-ended EndDate (NULL), category-specific vs site-wide (NULL),
          tie-breaking by Priority then DiscountPct then PromoID. */
WITH Candidates AS
(
    SELECT ol.OrderLineID, o.OrderID, o.OrderDate, p.ProductID, p.CategoryID,
           pr.PromoCode, pr.DiscountPct AS PromoDiscount, ol.DiscountPct AS AppliedDiscount,
           ROW_NUMBER() OVER (PARTITION BY ol.OrderLineID
                              ORDER BY pr.Priority, pr.DiscountPct DESC, pr.PromoID) AS rn
    FROM Sales.OrderLines AS ol
    JOIN Sales.Orders AS o          ON o.OrderID = ol.OrderID
    JOIN Sales.ProductCatalog AS p  ON p.ProductID = ol.ProductID
    JOIN Sales.Promotions AS pr
      ON o.OrderDate >= pr.StartDate
     AND (pr.EndDate IS NULL OR o.OrderDate <= pr.EndDate)
     AND (pr.CategoryID IS NULL OR pr.CategoryID = p.CategoryID)
)
SELECT OrderLineID, OrderID, OrderDate, ProductID, CategoryID,
       PromoCode, PromoDiscount, AppliedDiscount,
       CASE WHEN AppliedDiscount < PromoDiscount THEN 'UNDER-DISCOUNTED' ELSE 'OK' END AS Audit
FROM Candidates
WHERE rn = 1
ORDER BY OrderDate, OrderLineID;
GO

/* C21 [L2] Anti-joins and NULLs
   TRAP: NOT IN with a NULL in the subquery returns NO rows at all;
         NOT EXISTS / left_anti behave differently. EXCEPT treats NULLs as equal. */
SELECT COUNT(*) AS NotIn_Count            -- 0 because ManagerID contains NULL
FROM Sales.Employees AS e
WHERE e.EmployeeID NOT IN (SELECT ManagerID FROM Sales.Employees);

SELECT e.EmployeeID, e.FirstName AS IndividualContributor
FROM Sales.Employees AS e
WHERE NOT EXISTS (SELECT 1 FROM Sales.Employees AS r WHERE r.ManagerID = e.EmployeeID)
ORDER BY e.EmployeeID;

SELECT OrderID, ProductID, CustomerID, ShipAddress, BillAddress FROM Sales.OrdersArchive
EXCEPT
SELECT OrderID, ProductID, CustomerID, ShipAddress, BillAddress FROM Sales.Orders
ORDER BY OrderID;
GO

/* C22 [L3] Temporal table queries
   TRAP: FOR SYSTEM_TIME needs Delta time travel or an explicit SCD join on the history. */
DECLARE @AsOf DATETIME2(0) = '2024-06-30T00:00:00';
SELECT ProductID, ListPrice, ValidFrom, ValidTo
FROM Sales.PriceList FOR SYSTEM_TIME AS OF @AsOf
ORDER BY ProductID;

SELECT ProductID, ListPrice, ValidFrom, ValidTo
FROM Sales.PriceList FOR SYSTEM_TIME ALL
WHERE ProductID IN (101, 111)
ORDER BY ProductID, ValidFrom;

-- revenue at the price valid on each order date
SELECT o.OrderID, o.OrderDate, ol.ProductID, ol.UnitPrice AS ChargedPrice, pl.ListPrice AS PriceThen,
       ol.UnitPrice - pl.ListPrice AS PriceDrift
FROM Sales.Orders AS o
JOIN Sales.OrderLines AS ol ON ol.OrderID = o.OrderID
JOIN Sales.PriceList FOR SYSTEM_TIME ALL AS pl
  ON pl.ProductID = ol.ProductID
 AND CONVERT(DATETIME2(0), o.OrderDate) >= pl.ValidFrom
 AND CONVERT(DATETIME2(0), o.OrderDate) <  pl.ValidTo
WHERE o.OrderID BETWEEN 1001 AND 1030
ORDER BY o.OrderID, ol.ProductID;
GO

/* C23 [L2] SCD2 point-in-time join
   TRAP: ValidTo NULL = open; join condition BETWEEN with inclusive end. */
SELECT o.OrderID, o.OrderDate, o.CustomerID, h.Segment AS SegmentAtOrderTime,
       cur.Segment AS SegmentToday, o.Sales
FROM Sales.Orders AS o
LEFT JOIN Sales.CustomerHistory AS h
       ON h.CustomerID = o.CustomerID
      AND o.OrderDate >= h.ValidFrom
      AND o.OrderDate <= ISNULL(h.ValidTo, '9999-12-31')
LEFT JOIN Sales.CustomerHistory AS cur
       ON cur.CustomerID = o.CustomerID AND cur.IsCurrent = 1
WHERE o.CustomerID IN (6, 12, 18, 24, 30, 36)
ORDER BY o.CustomerID, o.OrderDate;
GO

/* C24 [L1] HIERARCHYID
   TRAP: no Spark type; needs a path string or closure table. */
SELECT e.EmployeeID, e.FirstName,
       oc.Node.ToString()               AS NodePath,
       oc.NodeLevel,
       mgr.FirstName                    AS DirectManager,
       (SELECT COUNT(*) FROM Sales.OrgChart AS d
        WHERE d.Node.IsDescendantOf(oc.Node) = 1 AND d.EmployeeID <> oc.EmployeeID) AS AllReports
FROM Sales.OrgChart AS oc
JOIN Sales.Employees AS e ON e.EmployeeID = oc.EmployeeID
LEFT JOIN Sales.OrgChart AS moc ON moc.Node = oc.Node.GetAncestor(1)
LEFT JOIN Sales.Employees AS mgr ON mgr.EmployeeID = moc.EmployeeID
ORDER BY oc.Node;
GO

/* C25 [L2] Fan-out double counting (1 order : N payments)
   TRAP: SUM(o.Sales) after joining Payments counts an order once per payment. */
SELECT o.CustomerID,
       SUM(o.Sales)                                   AS Revenue_Wrong,
       SUM(DISTINCT o.Sales)                          AS Revenue_AlsoWrong,   -- collapses equal amounts
       (SELECT SUM(o2.Sales) FROM Sales.Orders AS o2 WHERE o2.CustomerID = o.CustomerID) AS Revenue_Right,
       SUM(CASE WHEN p.PaymentStatus = 'Captured' THEN p.Amount ELSE 0 END) AS Captured
FROM Sales.Orders AS o
LEFT JOIN Sales.Payments AS p ON p.OrderID = o.OrderID
WHERE o.CustomerID BETWEEN 41 AND 45
GROUP BY o.CustomerID
ORDER BY o.CustomerID;
GO

/* C26 [L2] Numeric precision and rounding
   TRAPS: DECIMAL division result scale rules; MONEY keeps 4 dp; ROUND(x, 0) half away
          from zero on DECIMAL but FLOAT is binary; CAST(2.7 AS INT) truncates;
          ROUND(x, 2, 1) truncates; SUM over DECIMAL(10,2) widens to DECIMAL(38,2). */
SELECT ol.OrderLineID,
       ol.UnitPrice, ol.Quantity, ol.DiscountPct,
       ol.UnitPrice * ol.Quantity * (1 - ol.DiscountPct)          AS NetExact,
       ROUND(ol.UnitPrice * ol.Quantity * (1 - ol.DiscountPct), 2) AS NetRounded,
       ROUND(ol.UnitPrice * ol.Quantity * (1 - ol.DiscountPct), 2, 1) AS NetTruncated,
       ol.UnitPrice / 3                                            AS DecDivScale,
       CONVERT(MONEY, ol.UnitPrice) / 3                            AS MoneyDiv,
       CONVERT(FLOAT, ol.UnitPrice) / 3                            AS FloatDiv,
       CONVERT(INT, ol.UnitPrice)                                  AS IntTruncates,
       ROUND(CONVERT(DECIMAL(10,2), 2.5), 0)                       AS RoundHalf_Dec,
       ROUND(CONVERT(FLOAT, 2.675), 2)                             AS RoundHalf_Float,
       CEILING(ol.UnitPrice), FLOOR(-ol.UnitPrice)
FROM Sales.OrderLines AS ol
WHERE ol.OrderLineID IN (SELECT TOP (10) OrderLineID FROM Sales.OrderLines WHERE DiscountPct > 0 ORDER BY OrderLineID);

SELECT InvoiceID, AmountLocal, TaxRate, TaxAmount, TotalAmount,
       AmountLocal * TaxRate AS UnroundedTax
FROM Sales.Invoices
WHERE CurrencyCode IN ('JPY', 'VND')
ORDER BY InvoiceID;
GO

/* C27 [L3] Procedural batch: variables, table variable, temp table, WHILE, IF,
   TRY/CATCH, idempotent DELETE + INSERT into a target table.
   TRAP: must become a Python loop + Delta MERGE/replaceWhere; @@ROWCOUNT; THROW. */
SET NOCOUNT ON;
DECLARE @FromMonth DATE = '2026-01-01',
        @ToMonth   DATE = '2026-09-01',
        @m         DATE,
        @rows      INT,
        @total     INT = 0;

DECLARE @Log TABLE (MonthStart DATE, RowsLoaded INT, Note VARCHAR(100));

IF OBJECT_ID('tempdb..#MonthRevenue') IS NOT NULL DROP TABLE #MonthRevenue;
CREATE TABLE #MonthRevenue (MonthStart DATE, CustomerID INT, Orders INT, Revenue DECIMAL(14,2));

BEGIN TRY
    SET @m = @FromMonth;
    WHILE @m <= @ToMonth
    BEGIN
        INSERT #MonthRevenue (MonthStart, CustomerID, Orders, Revenue)
        SELECT @m, o.CustomerID, COUNT(*), SUM(ISNULL(o.Sales, 0))
        FROM Sales.Orders AS o
        WHERE o.OrderDate >= @m AND o.OrderDate < DATEADD(MONTH, 1, @m)
          AND o.OrderStatus <> 'Cancelled'
        GROUP BY o.CustomerID;

        SET @rows = @@ROWCOUNT;
        SET @total += @rows;

        INSERT @Log VALUES (@m, @rows, CASE WHEN @rows = 0 THEN 'no activity' ELSE 'ok' END);
        SET @m = DATEADD(MONTH, 1, @m);
    END;

    IF @total = 0
        THROW 50020, 'Nothing to load for the requested range.', 1;

    BEGIN TRANSACTION;

    DELETE FROM Sales.MonthlyCustomerKPI
    WHERE MonthStart BETWEEN @FromMonth AND @ToMonth;

    INSERT Sales.MonthlyCustomerKPI
        (MonthStart, CustomerID, Orders, Revenue, RevenuePrevMonth, RevenueRank, LoadedAt)
    SELECT cur.MonthStart, cur.CustomerID, cur.Orders, cur.Revenue,
           prev.Revenue,
           DENSE_RANK() OVER (PARTITION BY cur.MonthStart ORDER BY cur.Revenue DESC),
           SYSUTCDATETIME()
    FROM #MonthRevenue AS cur
    LEFT JOIN #MonthRevenue AS prev
           ON prev.CustomerID = cur.CustomerID
          AND prev.MonthStart = DATEADD(MONTH, -1, cur.MonthStart);

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    INSERT @Log VALUES (NULL, NULL, LEFT(ERROR_MESSAGE(), 100));
END CATCH;

SELECT * FROM @Log ORDER BY MonthStart;
SELECT TOP (10) * FROM Sales.MonthlyCustomerKPI ORDER BY MonthStart DESC, RevenueRank;
DROP TABLE #MonthRevenue;
GO

/* C28 [L3] DML family: UPDATE ... FROM with aggregate, OUTPUT INTO, DELETE TOP,
   trigger side effect, MERGE
   TRAP: Delta MERGE syntax differs; triggers do not exist in Spark (audit rows vanish);
         wrapped in a transaction and rolled back so the course data stays unchanged. */
BEGIN TRANSACTION;

DECLARE @changed TABLE (OrderID INT, OldStatus VARCHAR(50), NewStatus VARCHAR(50));

-- normalise messy statuses ('delivered', 'Delivered ') - fires the audit trigger
UPDATE o
SET OrderStatus = 'Delivered'
OUTPUT inserted.OrderID, deleted.OrderStatus, inserted.OrderStatus INTO @changed
FROM Sales.Orders AS o
WHERE o.OrderStatus = 'Delivered'                       -- matches all three spellings (CI + trailing space)
  AND CONVERT(VARBINARY(100), o.OrderStatus) <> CONVERT(VARBINARY(100), 'Delivered');

-- mark orders shipped long ago as delivered, using a join + aggregate
UPDATE o
SET OrderStatus = 'Delivered'
FROM Sales.Orders AS o
JOIN (SELECT OrderID, MAX(PaymentDate) AS LastPayment
      FROM Sales.Payments
      WHERE PaymentStatus = 'Captured'
      GROUP BY OrderID) AS p ON p.OrderID = o.OrderID
WHERE o.OrderStatus = 'Shipped'
  AND o.ShipDate < DATEADD(DAY, -30, CONVERT(DATE, p.LastPayment));

SELECT * FROM @changed;
SELECT TOP (10) * FROM Sales.OrderStatusLog ORDER BY LogID DESC;

-- delete the oldest 5 failed payments only
DELETE TOP (5) FROM Sales.Payments WHERE PaymentStatus = 'Failed';

ROLLBACK TRANSACTION;
GO

/* C29 [L3] Calling programmable objects
   TRAP: procs with OUTPUT params, multi-result-set procs, dynamic SQL, TVFs, UDFs
         all need hand-designed Python equivalents. Wrapped in a rolled-back transaction. */
SELECT * FROM Sales.fn_CustomerOrders(41, '2026-01-01') ORDER BY OrderSeq;

SELECT ds.MonthStart, COUNT(*) AS Days, SUM(CONVERT(INT, ds.IsWeekend)) AS WeekendDays, MIN(ds.FiscalQtr) AS FiscalQtr
FROM Sales.fn_DateSpine('2026-01-01', '2026-12-31') AS ds
GROUP BY ds.MonthStart
ORDER BY ds.MonthStart;

SELECT TOP (20) OrderID, FiscalQuarter, NetAmount, CurrencyCode, InvoiceTotalLocal, InvoiceTotalUSD,
       Sales.fn_ToUSD(InvoiceTotalLocal, CurrencyCode, OrderDate) AS ViaScalarUdf
FROM Sales.vw_OrderFinancials
WHERE CurrencyCode <> 'USD'
ORDER BY OrderID;

EXEC Sales.usp_PivotRevenueByCategory @Year = 2025;
EXEC Sales.usp_InventoryReorderPlan @SnapshotDate = '2026-09-30', @LeadTimeDays = 21;

BEGIN TRANSACTION;
DECLARE @closed INT, @opened INT;
EXEC Sales.usp_ApplyCustomerChanges @ChangeDate = '2026-01-01', @RowsClosed = @closed OUTPUT, @RowsOpened = @opened OUTPUT;
EXEC Sales.usp_ApplyCustomerChanges @ChangeDate = '2026-07-01', @RowsClosed = @closed OUTPUT, @RowsOpened = @opened OUTPUT;
SELECT @closed AS LastClosed, @opened AS LastOpened;
SELECT * FROM Sales.CustomerHistory WHERE CustomerID IN (2, 5, 41, 44, 45, 46) ORDER BY CustomerID, ValidFrom;
ROLLBACK TRANSACTION;
GO

/* C30 [L2] Final boss: cohort retention matrix
   Combines date bucketing, DATEDIFF month semantics, window functions,
   conditional aggregation, NULLIF division and a dirty-data filter. */
WITH FirstOrder AS
(
    SELECT CustomerID, MIN(DATEFROMPARTS(YEAR(OrderDate), MONTH(OrderDate), 1)) AS CohortMonth
    FROM Sales.Orders
    WHERE OrderStatus <> 'Cancelled' AND ISNULL(Sales, 0) > 0
    GROUP BY CustomerID
),
Activity AS
(
    SELECT DISTINCT o.CustomerID, f.CohortMonth,
           DATEDIFF(MONTH, f.CohortMonth, o.OrderDate) AS MonthIndex
    FROM Sales.Orders AS o
    JOIN FirstOrder AS f ON f.CustomerID = o.CustomerID
    WHERE o.OrderStatus <> 'Cancelled' AND ISNULL(o.Sales, 0) > 0
),
Cohorts AS
(
    SELECT DATEFROMPARTS(YEAR(CohortMonth), (DATEPART(QUARTER, CohortMonth) - 1) * 3 + 1, 1) AS CohortQuarter,
           CustomerID, MonthIndex
    FROM Activity
)
SELECT CohortQuarter,
       COUNT(DISTINCT CustomerID) AS CohortSize,
       CONVERT(DECIMAL(5,1), 100.0 * COUNT(DISTINCT CASE WHEN MonthIndex BETWEEN 1 AND 3  THEN CustomerID END)
                             / NULLIF(COUNT(DISTINCT CustomerID), 0)) AS RetainedM1_3_Pct,
       CONVERT(DECIMAL(5,1), 100.0 * COUNT(DISTINCT CASE WHEN MonthIndex BETWEEN 4 AND 6  THEN CustomerID END)
                             / NULLIF(COUNT(DISTINCT CustomerID), 0)) AS RetainedM4_6_Pct,
       CONVERT(DECIMAL(5,1), 100.0 * COUNT(DISTINCT CASE WHEN MonthIndex BETWEEN 7 AND 12 THEN CustomerID END)
                             / NULLIF(COUNT(DISTINCT CustomerID), 0)) AS RetainedM7_12_Pct
FROM Cohorts
GROUP BY CohortQuarter
ORDER BY CohortQuarter;
GO
