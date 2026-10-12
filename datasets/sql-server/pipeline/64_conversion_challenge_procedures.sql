USE SalesDB;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

DROP PROCEDURE IF EXISTS Pipeline.usp_CaptureConversionBaselines;
GO

CREATE OR ALTER PROCEDURE Pipeline.usp_RecordConversionChallengeResult
    @RunID BIGINT,
    @ChallengeKey VARCHAR(3),
    @RowsProcessed INT
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM Pipeline.ConversionChallengeResults
    WHERE RunID = @RunID AND ChallengeKey = @ChallengeKey;

    INSERT Pipeline.ConversionChallengeResults
        (RunID, ChallengeKey, Status, SourceRowCount, Detail)
    SELECT @RunID, definition.ChallengeKey, 'Passed', @RowsProcessed,
           CONCAT(N'Executed ', QUOTENAME(N'Sales') + N'.' + QUOTENAME(N'usp_ConversionChallenge_' + definition.ChallengeKey),
                  N'. ', definition.TrapDescription)
    FROM Pipeline.ConversionChallengeDefinitions AS definition
    WHERE definition.ChallengeKey = @ChallengeKey AND definition.IsActive = 1;

    IF @@ROWCOUNT <> 1
        THROW 51130, 'The conversion challenge definition is missing or inactive.', 1;
END;
GO

/* C01: TOP WITH TIES */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C01
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (5) WITH TIES
           CustomerID, SUM(Sales) AS Revenue
    FROM Sales.Orders
    WHERE OrderStatus <> 'Cancelled'
    GROUP BY CustomerID
    ORDER BY Revenue DESC;

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C01', @RowsProcessed;
END;
GO

/* C02: OFFSET / FETCH paging with variables */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C02
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PageNo INT = 3, @PageSize INT = 20;
    SELECT OrderID, OrderDate, CustomerID, Sales
    FROM Sales.Orders
    ORDER BY OrderDate DESC, OrderID
    OFFSET (@PageNo - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C02', @RowsProcessed;
END;
GO

/* C03: CROSS APPLY with TOP n per outer row */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C03
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

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

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C03', @RowsProcessed;
END;
GO

/* C04: As-of join */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C04
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT i.InvoiceID, i.CurrencyCode, i.IssuedAt,
           CONVERT(DATE, i.IssuedAt) AS IssueDateLocal,
           i.TotalAmount, fx.RateDate, fx.RateToUSD,
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

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C04', @RowsProcessed;
END;
GO

/* C05: Recursive CTE org chart */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C05
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

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
    AncestorPairs AS
    (
        SELECT EmployeeID AS AncestorID, EmployeeID AS DescendantID FROM Sales.Employees
        UNION ALL
        SELECT ap.AncestorID, e.EmployeeID
        FROM AncestorPairs AS ap
        JOIN Sales.Employees AS e ON e.ManagerID = ap.DescendantID
    )
    SELECT REPLICATE('    ', o.Depth) + o.FirstName AS OrgTree,
           o.Depth, o.ChainOfCommand,
           COUNT(*) - 1 AS Reports,
           SUM(emp.Salary) AS SubtreeSalary
    FROM Org AS o
    JOIN AncestorPairs AS ap ON ap.AncestorID = o.EmployeeID
    JOIN Sales.Employees AS emp ON emp.EmployeeID = ap.DescendantID
    GROUP BY o.EmployeeID, o.FirstName, o.Depth, o.ChainOfCommand, o.SortPath
    ORDER BY o.SortPath
    OPTION (MAXRECURSION 20);

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C05', @RowsProcessed;
END;
GO

/* C06: Gaps and islands */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C06
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

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
    SELECT CustomerID, MIN(OrderMonth) AS StreakStart,
           MAX(OrderMonth) AS StreakEnd, COUNT(*) AS MonthsInStreak
    FROM G
    GROUP BY CustomerID, IslandKey
    HAVING COUNT(*) >= 2
    ORDER BY MonthsInStreak DESC, CustomerID, StreakStart;

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C06', @RowsProcessed;
END;
GO

/* C07: Sessionization of JSON events */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C07
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

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
           MIN(EventTime) AS SessionStart, MAX(EventTime) AS SessionEnd,
           DATEDIFF(SECOND, MIN(EventTime), MAX(EventTime)) AS DurationSec,
           COUNT(*) AS Events,
           MAX(CASE WHEN EventType = 'purchase' THEN 1 ELSE 0 END) AS Converted
    FROM S
    GROUP BY CustomerID, SessionNo
    ORDER BY CustomerID, SessionNo;

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C07', @RowsProcessed;
END;
GO

/* C08: Window frames and integer AVG */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C08
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT CustomerID, OrderDate, OrderID, Sales,
           SUM(Sales) OVER (PARTITION BY CustomerID ORDER BY OrderDate) AS RunTotal_DefaultRange,
           SUM(Sales) OVER (PARTITION BY CustomerID ORDER BY OrderDate, OrderID
                            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS RunTotal_Rows,
           AVG(Sales) OVER (PARTITION BY CustomerID) AS AvgSales_IntTruncated,
           AVG(CONVERT(DECIMAL(10,2), Sales)) OVER (PARTITION BY CustomerID ORDER BY OrderDate, OrderID
                                                    ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS Moving3
    FROM Sales.Orders
    WHERE CustomerID IN (41, 42, 44, 45, 2)
    ORDER BY CustomerID, OrderDate, OrderID;

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C08', @RowsProcessed;
END;
GO

/* C09: LAG, LEAD, FIRST_VALUE, and LAST_VALUE */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C09
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT CustomerID, OrderID, OrderDate, Sales,
           LAG(Sales, 1, 0) OVER (PARTITION BY CustomerID ORDER BY OrderDate, OrderID) AS PrevSales,
           LEAD(OrderDate) OVER (PARTITION BY CustomerID ORDER BY OrderDate, OrderID) AS NextOrderDate,
           DATEDIFF(DAY, OrderDate,
                    LEAD(OrderDate) OVER (PARTITION BY CustomerID ORDER BY OrderDate, OrderID)) AS DaysToNext,
           FIRST_VALUE(OrderID) OVER (PARTITION BY CustomerID ORDER BY OrderDate, OrderID) AS FirstOrder,
           LAST_VALUE(OrderID) OVER (PARTITION BY CustomerID ORDER BY OrderDate, OrderID) AS LastValue_Wrong,
           LAST_VALUE(OrderID) OVER (PARTITION BY CustomerID ORDER BY OrderDate, OrderID
                                     ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS LastOrder
    FROM Sales.Orders
    WHERE CustomerID BETWEEN 1 AND 5
    ORDER BY CustomerID, OrderDate, OrderID;

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C09', @RowsProcessed;
END;
GO

/* C10: Percentiles and NTILE */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C10
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT DISTINCT c.Country,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY o.Sales) OVER (PARTITION BY c.Country) AS MedianSales,
           PERCENTILE_DISC(0.9) WITHIN GROUP (ORDER BY o.Sales) OVER (PARTITION BY c.Country) AS P90Sales_Disc
    FROM Sales.Orders AS o
    JOIN Sales.Customers AS c ON c.CustomerID = o.CustomerID
    ORDER BY c.Country;

    SELECT CustomerID, Score,
           NTILE(4) OVER (ORDER BY Score DESC, CustomerID) AS Quartile,
           PERCENT_RANK() OVER (ORDER BY Score) AS PctRank,
           CUME_DIST() OVER (ORDER BY Score) AS CumeDist
    FROM Sales.Customers
    ORDER BY Score DESC, CustomerID;

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C10', @RowsProcessed;
END;
GO

/* C11: GROUPING SETS and ROLLUP */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C11
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT CASE WHEN GROUPING(c.Country) = 1 THEN '<ALL COUNTRIES>'
                ELSE ISNULL(c.Country, '<unknown>') END AS Country,
           CASE WHEN GROUPING(YEAR(o.OrderDate)) = 1 THEN 'ALL'
                ELSE CONVERT(VARCHAR(4), YEAR(o.OrderDate)) END AS OrderYear,
           GROUPING_ID(c.Country, YEAR(o.OrderDate)) AS GroupingLevel,
           COUNT(*) AS Orders, SUM(o.Sales) AS Revenue,
           COUNT(o.Sales) AS OrdersWithSales
    FROM Sales.Orders AS o
    JOIN Sales.Customers AS c ON c.CustomerID = o.CustomerID
    GROUP BY ROLLUP (c.Country, YEAR(o.OrderDate))
    ORDER BY GroupingLevel, Country, OrderYear;

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C11', @RowsProcessed;
END;
GO

/* C12: Static PIVOT and UNPIVOT */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C12
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT PaymentMethod, [Captured], [Pending], [Refunded], [Failed]
    FROM
    (
        SELECT PaymentMethod, PaymentStatus, Amount FROM Sales.Payments
    ) AS source_data
    PIVOT (SUM(Amount) FOR PaymentStatus IN ([Captured], [Pending], [Refunded], [Failed])) AS pivoted
    ORDER BY PaymentMethod;

    SELECT OrderID, AddressType, AddressValue
    FROM
    (
        SELECT OrderID, ShipAddress, BillAddress
        FROM Sales.Orders
        WHERE OrderID BETWEEN 2001 AND 2012
    ) AS source_data
    UNPIVOT (AddressValue FOR AddressType IN (ShipAddress, BillAddress)) AS unpivoted
    ORDER BY OrderID, AddressType;

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C12', @RowsProcessed;
END;
GO

/* C13: Ordered STRING_AGG and STRING_SPLIT with ordinal */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C13
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT o.CustomerID,
           STRING_AGG(CONVERT(VARCHAR(10), o.OrderID), ',')
               WITHIN GROUP (ORDER BY o.OrderDate DESC, o.OrderID) AS OrdersNewestFirst,
           STRING_AGG(o.OrderStatus, ' | ') AS Statuses
    FROM Sales.Orders AS o
    WHERE o.CustomerID >= 41
    GROUP BY o.CustomerID
    ORDER BY o.CustomerID;

    SELECT f.FeedRowID, f.TagsCsv, split.ordinal,
           split.value AS RawTag, LTRIM(RTRIM(split.value)) AS Tag
    FROM Sales.RawCustomerFeed AS f
    CROSS APPLY STRING_SPLIT(f.TagsCsv, ',', 1) AS split
    ORDER BY f.FeedRowID, split.ordinal;

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C13', @RowsProcessed;
END;
GO

/* C14: Date function semantics */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C14
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET DATEFIRST 1;

    SELECT o.OrderID, o.OrderDate, o.ShipDate,
           DATEDIFF(DAY, o.OrderDate, o.ShipDate) AS DaysToShip,
           DATEDIFF(MONTH, o.OrderDate, o.ShipDate) AS MonthBoundaries,
           DATEDIFF(YEAR, o.OrderDate, o.ShipDate) AS YearBoundaries,
           EOMONTH(o.OrderDate) AS MonthEnd,
           EOMONTH(o.OrderDate, -1) AS PrevMonthEnd,
           DATEADD(MONTH, 1, o.OrderDate) AS PlusOneMonth,
           DATEPART(WEEKDAY, o.OrderDate) AS WeekdayNo,
           DATENAME(WEEKDAY, o.OrderDate) AS WeekdayName,
           DATEPART(ISO_WEEK, o.OrderDate) AS IsoWeek,
           DATEPART(WEEK, o.OrderDate) AS UsWeek,
           DATETRUNC(QUARTER, o.OrderDate) AS QuarterStart,
           CONVERT(VARCHAR(10), o.OrderDate, 103) AS UkFormat,
           CONVERT(VARCHAR(8), o.OrderDate, 112) AS IsoBasic,
           FORMAT(o.OrderDate, 'dddd, d MMMM yyyy', 'de-DE') AS GermanLong,
           Sales.fn_FiscalQuarter(o.OrderDate) AS FiscalQuarter
    FROM Sales.Orders AS o
    WHERE o.OrderID BETWEEN 2001 AND 2012
    ORDER BY o.OrderID;

    SET @RowsProcessed = @@ROWCOUNT;
    SET DATEFIRST 7;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C14', @RowsProcessed;
END;
GO

/* C15: DATETIMEOFFSET and Windows time zones */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C15
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (25)
           InvoiceID, CurrencyCode, IssuedAt,
           DATEPART(TZOFFSET, IssuedAt) AS OffsetMinutes,
           SWITCHOFFSET(IssuedAt, '+00:00') AS IssuedUtc,
           CONVERT(DATE, IssuedAt) AS LocalDate,
           CONVERT(DATE, SWITCHOFFSET(IssuedAt, '+00:00')) AS UtcDate,
           IssuedAt AT TIME ZONE 'SE Asia Standard Time' AS IssuedBangkok,
           IssuedAt AT TIME ZONE 'W. Europe Standard Time' AS IssuedBerlin_DSTAware,
           CONVERT(DATETIME2(0), IssuedAt AT TIME ZONE 'Pacific Standard Time') AS IssuedLA_NoOffset
    FROM Sales.Invoices
    WHERE CONVERT(DATE, IssuedAt) <> CONVERT(DATE, SWITCHOFFSET(IssuedAt, '+00:00'))
    ORDER BY InvoiceID;

    SELECT value.LocalTime,
           value.LocalTime AT TIME ZONE 'W. Europe Standard Time' AS WithBerlinOffset
    FROM
    (
        VALUES (CONVERT(DATETIME2(0), '2026-03-29T02:30:00')),
               (CONVERT(DATETIME2(0), '2026-10-25T02:30:00')),
               (CONVERT(DATETIME2(0), '2026-07-01T12:00:00'))
    ) AS value (LocalTime);

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C15', @RowsProcessed;
END;
GO

/* C16: String and NULL semantics */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C16
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Country, COUNT(*) AS Customers, MIN(CustomerID) AS FirstID
    FROM Sales.Customers
    GROUP BY Country
    ORDER BY Country;

    SELECT CustomerID,
           FirstName + ' ' + LastName AS PlusConcat_NullProp,
           CONCAT(FirstName, ' ', LastName) AS ConcatFn,
           CONCAT_WS(' ', FirstName, LastName) AS ConcatWs,
           ISNULL(CONVERT(VARCHAR(3), NULL), 'Unknown') AS IsNull_Truncates,
           COALESCE(CONVERT(VARCHAR(3), NULL), 'Unknown') AS Coalesce_Full,
           LEN(LastName) AS Len_IgnoresTrailing,
           DATALENGTH(LastName) AS ByteLen,
           CASE WHEN Country = 'GERMANY' THEN 1 ELSE 0 END AS CaseInsensitiveEq,
           '10' + 5 AS ImplicitNumeric,
           7 / 2 AS IntDivision,
           7 / 2.0 AS DecDivision,
           Score % 7 AS ModNullable
    FROM Sales.Customers
    WHERE CustomerID IN (3, 5, 41, 42, 44, 45);

    SELECT InvoiceID, Notes,
           LEN(Notes) AS LenChars,
           DATALENGTH(Notes) AS Bytes,
           CHARINDEX(N'–', Notes) AS DashPos,
           CASE WHEN Notes LIKE N'%[[]SPRING[_]25]%' THEN 1 ELSE 0 END AS LikeEscapedBrackets,
           CASE WHEN Notes LIKE N'%50[%]%' THEN 1 ELSE 0 END AS LikeEscapedPercent,
           REPLACE(REPLACE(Notes, NCHAR(13), N''), NCHAR(10), N' ') AS OneLine
    FROM Sales.Invoices
    WHERE InvoiceID IN (SELECT MIN(InvoiceID) FROM Sales.Invoices GROUP BY OrderID % 9);

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C16', @RowsProcessed;
END;
GO

/* C17: Cleaning a text-typed feed */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C17
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    WITH Parsed AS
    (
        SELECT feed.*,
               UPPER(LTRIM(RTRIM(feed.CustomerRef))) AS CustomerKey,
               COALESCE(
                   TRY_CONVERT(DATE, feed.SignupDateRaw, 23),
                   TRY_CONVERT(DATE, feed.SignupDateRaw, 112),
                   TRY_CONVERT(DATE, feed.SignupDateRaw, 101),
                   TRY_CONVERT(DATE, feed.SignupDateRaw, 103),
                   TRY_CONVERT(DATE, feed.SignupDateRaw, 104),
                   TRY_CONVERT(DATE, feed.SignupDateRaw, 111),
                   TRY_CONVERT(DATE, LEFT(feed.SignupDateRaw, 10), 23),
                   TRY_PARSE(feed.SignupDateRaw AS DATE USING 'en-US')) AS SignupDate,
               ISNUMERIC(feed.LifetimeValueRaw) AS IsNumericSays,
               COALESCE(
                   TRY_PARSE(feed.LifetimeValueRaw AS DECIMAL(14,2) USING 'en-US'),
                   TRY_PARSE(feed.LifetimeValueRaw AS DECIMAL(14,2) USING 'de-DE'),
                   TRY_CONVERT(DECIMAL(14,2), TRY_CONVERT(FLOAT, feed.LifetimeValueRaw))) AS LifetimeValue,
               NULLIF(TRANSLATE(feed.PhoneRaw, '()-. ', '     '), '') AS PhoneSpaced,
               REPLACE(TRANSLATE(feed.PhoneRaw, '()-.+', '     '), ' ', '') AS PhoneDigits,
               CASE UPPER(LTRIM(RTRIM(feed.CountryRaw)))
                    WHEN 'U.S.A.' THEN 'USA' WHEN 'UNITED STATES' THEN 'USA' WHEN 'USA' THEN 'USA'
                    WHEN 'DE' THEN 'Germany' WHEN 'DEUTSCHLAND' THEN 'Germany' WHEN 'GERMANY' THEN 'Germany'
                    WHEN N'VIỆT NAM' THEN 'Vietnam'
                    WHEN 'N/A' THEN NULL
                    ELSE LTRIM(RTRIM(feed.CountryRaw)) END AS CountryClean,
               ROW_NUMBER() OVER
               (
                   PARTITION BY UPPER(LTRIM(RTRIM(feed.CustomerRef)))
                   ORDER BY feed.LoadedAt DESC, feed.FeedRowID DESC
               ) AS row_number
        FROM Sales.RawCustomerFeed AS feed
    )
    SELECT FeedRowID, CustomerKey, FullName,
           LTRIM(RTRIM(REPLACE(REPLACE(FullName, '  ', ' '), '  ', ' '))) AS FullNameClean,
           CountryClean, SignupDateRaw, SignupDate,
           LifetimeValueRaw, IsNumericSays, LifetimeValue,
           PhoneRaw, PhoneDigits,
           TRY_CONVERT(INT, SUBSTRING(CustomerKey, 3, 10)) AS CustomerID
    FROM Parsed
    WHERE row_number = 1 OR CustomerKey IS NULL
    ORDER BY CustomerKey;

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C17', @RowsProcessed;
END;
GO

/* C18: OPENJSON schema and nested arrays */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C18
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT event.EventID, event.CustomerID, event.EventTime,
           parsed.EventType, parsed.DeviceOS, parsed.AppVersion, parsed.UtmSource,
           item.Sku, item.Qty, item.Price,
           item.Qty * item.Price AS LineValue,
           JSON_QUERY(CASE WHEN ISJSON(event.Payload) = 1 THEN event.Payload END, '$.device') AS DeviceJson
    FROM Sales.WebEvents AS event
    CROSS APPLY OPENJSON(CASE WHEN ISJSON(event.Payload) = 1 THEN event.Payload END)
         WITH (EventType VARCHAR(20) '$.type',
               DeviceOS VARCHAR(10) '$.device.os',
               AppVersion VARCHAR(10) '$.device.appVersion',
               UtmSource VARCHAR(30) '$.utm.source',
               Items NVARCHAR(MAX) '$.items' AS JSON) AS parsed
    CROSS APPLY OPENJSON(parsed.Items)
         WITH (Sku VARCHAR(20) '$.sku', Qty INT '$.qty', Price DECIMAL(10,2) '$.price') AS item
    WHERE ISJSON(event.Payload) = 1
      AND parsed.EventType = 'purchase'
    ORDER BY event.EventTime, event.EventID;

    SELECT COALESCE(JSON_VALUE(json_data.Document, '$.device.os'), '<malformed>') AS DeviceOS,
           SUM(CASE WHEN JSON_VALUE(json_data.Document, '$.type') = 'page_view' THEN 1 ELSE 0 END) AS Views,
           SUM(CASE WHEN JSON_VALUE(json_data.Document, '$.type') = 'add_to_cart' THEN 1 ELSE 0 END) AS Carts,
           SUM(CASE WHEN JSON_VALUE(json_data.Document, '$.type') = 'purchase' THEN 1 ELSE 0 END) AS Purchases,
           SUM(CASE WHEN json_data.Document IS NULL THEN 1 ELSE 0 END) AS BadRows
    FROM Sales.WebEvents AS event
    CROSS APPLY
    (
        SELECT CASE WHEN ISJSON(event.Payload) = 1 THEN event.Payload END AS Document
    ) AS json_data
    GROUP BY COALESCE(JSON_VALUE(json_data.Document, '$.device.os'), '<malformed>');

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C18', @RowsProcessed;
END;
GO

/* C19: XML value, nodes, and exist methods */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C19
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT attributes.ProductID,
           attributes.Attributes.value('(/attributes/@sku)[1]', 'VARCHAR(20)') AS Sku,
           attributes.Attributes.value('(/attributes/attr[@name="color"])[1]', 'VARCHAR(20)') AS Color,
           attributes.Attributes.value('(/attributes/attr[@name="weight_g"])[1]', 'INT') AS WeightG,
           attributes.Attributes.exist('/attributes/battery') AS HasBattery,
           size_node.node.value('@code', 'VARCHAR(5)') AS SizeCode,
           size_node.node.value('@stock', 'INT') AS SizeStock
    FROM Sales.ProductAttributes AS attributes
    OUTER APPLY attributes.Attributes.nodes('/attributes/sizes/size') AS size_node(node)
    ORDER BY attributes.ProductID, SizeCode;

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C19', @RowsProcessed;
END;
GO

/* C20: Promotion range join */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C20
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    WITH Candidates AS
    (
        SELECT line.OrderLineID, order_header.OrderID, order_header.OrderDate,
               product.ProductID, product.CategoryID,
               promotion.PromoCode, promotion.DiscountPct AS PromoDiscount,
               line.DiscountPct AS AppliedDiscount,
               ROW_NUMBER() OVER
               (
                   PARTITION BY line.OrderLineID
                   ORDER BY promotion.Priority, promotion.DiscountPct DESC, promotion.PromoID
               ) AS row_number
        FROM Sales.OrderLines AS line
        JOIN Sales.Orders AS order_header ON order_header.OrderID = line.OrderID
        JOIN Sales.ProductCatalog AS product ON product.ProductID = line.ProductID
        JOIN Sales.Promotions AS promotion
          ON order_header.OrderDate >= promotion.StartDate
         AND (promotion.EndDate IS NULL OR order_header.OrderDate <= promotion.EndDate)
         AND (promotion.CategoryID IS NULL OR promotion.CategoryID = product.CategoryID)
    )
    SELECT OrderLineID, OrderID, OrderDate, ProductID, CategoryID,
           PromoCode, PromoDiscount, AppliedDiscount,
           CASE WHEN AppliedDiscount < PromoDiscount THEN 'UNDER-DISCOUNTED' ELSE 'OK' END AS Audit
    FROM Candidates
    WHERE row_number = 1
    ORDER BY OrderDate, OrderLineID;

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C20', @RowsProcessed;
END;
GO

/* C21: Anti-joins and NULLs */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C21
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT COUNT(*) AS NotIn_Count
    FROM Sales.Employees AS employee
    WHERE employee.EmployeeID NOT IN (SELECT ManagerID FROM Sales.Employees);

    SELECT employee.EmployeeID, employee.FirstName AS IndividualContributor
    FROM Sales.Employees AS employee
    WHERE NOT EXISTS
    (
        SELECT 1 FROM Sales.Employees AS report
        WHERE report.ManagerID = employee.EmployeeID
    )
    ORDER BY employee.EmployeeID;

    SELECT OrderID, ProductID, CustomerID, ShipAddress, BillAddress
    FROM Sales.OrdersArchive
    EXCEPT
    SELECT OrderID, ProductID, CustomerID, ShipAddress, BillAddress
    FROM Sales.Orders
    ORDER BY OrderID;

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C21', @RowsProcessed;
END;
GO

/* C22: System-versioned temporal queries */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C22
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @AsOf DATETIME2(0) = '2024-06-30T00:00:00';

    SELECT ProductID, ListPrice, ValidFrom, ValidTo
    FROM Sales.PriceList FOR SYSTEM_TIME AS OF @AsOf
    ORDER BY ProductID;

    SELECT ProductID, ListPrice, ValidFrom, ValidTo
    FROM Sales.PriceList FOR SYSTEM_TIME ALL
    WHERE ProductID IN (101, 111)
    ORDER BY ProductID, ValidFrom;

    SELECT order_header.OrderID, order_header.OrderDate, line.ProductID,
           line.UnitPrice AS ChargedPrice, price.ListPrice AS PriceThen,
           line.UnitPrice - price.ListPrice AS PriceDrift
    FROM Sales.Orders AS order_header
    JOIN Sales.OrderLines AS line ON line.OrderID = order_header.OrderID
    JOIN Sales.PriceList FOR SYSTEM_TIME ALL AS price
      ON price.ProductID = line.ProductID
     AND CONVERT(DATETIME2(0), order_header.OrderDate) >= price.ValidFrom
     AND CONVERT(DATETIME2(0), order_header.OrderDate) < price.ValidTo
    WHERE order_header.OrderID BETWEEN 1001 AND 1030
    ORDER BY order_header.OrderID, line.ProductID;

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C22', @RowsProcessed;
END;
GO

/* C23: SCD2 point-in-time join */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C23
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT order_header.OrderID, order_header.OrderDate, order_header.CustomerID,
           history.Segment AS SegmentAtOrderTime,
           current_history.Segment AS SegmentToday,
           order_header.Sales
    FROM Sales.Orders AS order_header
    LEFT JOIN Sales.CustomerHistory AS history
      ON history.CustomerID = order_header.CustomerID
     AND order_header.OrderDate >= history.ValidFrom
     AND order_header.OrderDate <= ISNULL(history.ValidTo, '9999-12-31')
    LEFT JOIN Sales.CustomerHistory AS current_history
      ON current_history.CustomerID = order_header.CustomerID
     AND current_history.IsCurrent = 1
    WHERE order_header.CustomerID IN (6, 12, 18, 24, 30, 36)
    ORDER BY order_header.CustomerID, order_header.OrderDate;

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C23', @RowsProcessed;
END;
GO

/* C24: HIERARCHYID */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C24
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT employee.EmployeeID, employee.FirstName,
           org.Node.ToString() AS NodePath,
           org.NodeLevel,
           manager.FirstName AS DirectManager,
           (SELECT COUNT(*)
            FROM Sales.OrgChart AS descendant
            WHERE descendant.Node.IsDescendantOf(org.Node) = 1
              AND descendant.EmployeeID <> org.EmployeeID) AS AllReports
    FROM Sales.OrgChart AS org
    JOIN Sales.Employees AS employee ON employee.EmployeeID = org.EmployeeID
    LEFT JOIN Sales.OrgChart AS manager_org ON manager_org.Node = org.Node.GetAncestor(1)
    LEFT JOIN Sales.Employees AS manager ON manager.EmployeeID = manager_org.EmployeeID
    ORDER BY org.Node;

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C24', @RowsProcessed;
END;
GO

/* C25: Fan-out double counting */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C25
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT order_header.CustomerID,
           SUM(order_header.Sales) AS Revenue_Wrong,
           SUM(DISTINCT order_header.Sales) AS Revenue_AlsoWrong,
           (SELECT SUM(correct_order.Sales)
            FROM Sales.Orders AS correct_order
            WHERE correct_order.CustomerID = order_header.CustomerID) AS Revenue_Right,
           SUM(CASE WHEN payment.PaymentStatus = 'Captured' THEN payment.Amount ELSE 0 END) AS Captured
    FROM Sales.Orders AS order_header
    LEFT JOIN Sales.Payments AS payment ON payment.OrderID = order_header.OrderID
    WHERE order_header.CustomerID BETWEEN 41 AND 45
    GROUP BY order_header.CustomerID
    ORDER BY order_header.CustomerID;

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C25', @RowsProcessed;
END;
GO

/* C26: Numeric precision and rounding */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C26
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT line.OrderLineID, line.UnitPrice, line.Quantity, line.DiscountPct,
           line.UnitPrice * line.Quantity * (1 - line.DiscountPct) AS NetExact,
           ROUND(line.UnitPrice * line.Quantity * (1 - line.DiscountPct), 2) AS NetRounded,
           ROUND(line.UnitPrice * line.Quantity * (1 - line.DiscountPct), 2, 1) AS NetTruncated,
           line.UnitPrice / 3 AS DecDivScale,
           CONVERT(MONEY, line.UnitPrice) / 3 AS MoneyDiv,
           CONVERT(FLOAT, line.UnitPrice) / 3 AS FloatDiv,
           CONVERT(INT, line.UnitPrice) AS IntTruncates,
           ROUND(CONVERT(DECIMAL(10,2), 2.5), 0) AS RoundHalf_Dec,
           ROUND(CONVERT(FLOAT, 2.675), 2) AS RoundHalf_Float,
           CEILING(line.UnitPrice) AS CeilingValue,
           FLOOR(-line.UnitPrice) AS FloorValue
    FROM Sales.OrderLines AS line
    WHERE line.OrderLineID IN
    (
        SELECT TOP (10) OrderLineID
        FROM Sales.OrderLines
        WHERE DiscountPct > 0
        ORDER BY OrderLineID
    );

    SELECT InvoiceID, AmountLocal, TaxRate, TaxAmount, TotalAmount,
           AmountLocal * TaxRate AS UnroundedTax
    FROM Sales.Invoices
    WHERE CurrencyCode IN ('JPY', 'VND')
    ORDER BY InvoiceID;

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C26', @RowsProcessed;
END;
GO

/* C27: Procedural monthly batch */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C27
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @FromMonth DATE = '2026-01-01',
            @ToMonth DATE = '2026-09-01',
            @Month DATE,
            @Rows INT,
            @Total INT = 0;

    DECLARE @Log TABLE (MonthStart DATE, RowsLoaded INT, Note VARCHAR(100));

    IF OBJECT_ID('tempdb..#MonthRevenue') IS NOT NULL DROP TABLE #MonthRevenue;
    CREATE TABLE #MonthRevenue
    (
        MonthStart DATE,
        CustomerID INT,
        Orders INT,
        Revenue DECIMAL(14,2)
    );

    BEGIN TRY
        SET @Month = @FromMonth;
        WHILE @Month <= @ToMonth
        BEGIN
            INSERT #MonthRevenue (MonthStart, CustomerID, Orders, Revenue)
            SELECT @Month, order_header.CustomerID, COUNT(*), SUM(ISNULL(order_header.Sales, 0))
            FROM Sales.Orders AS order_header
            WHERE order_header.OrderDate >= @Month
              AND order_header.OrderDate < DATEADD(MONTH, 1, @Month)
              AND order_header.OrderStatus <> 'Cancelled'
            GROUP BY order_header.CustomerID;

            SET @Rows = @@ROWCOUNT;
            SET @Total += @Rows;
            INSERT @Log VALUES (@Month, @Rows, CASE WHEN @Rows = 0 THEN 'no activity' ELSE 'ok' END);
            SET @Month = DATEADD(MONTH, 1, @Month);
        END;

        IF @Total = 0
            THROW 50020, 'Nothing to load for the requested range.', 1;

        BEGIN TRANSACTION;

        DELETE FROM Sales.MonthlyCustomerKPI
        WHERE MonthStart BETWEEN @FromMonth AND @ToMonth;

        INSERT Sales.MonthlyCustomerKPI
            (MonthStart, CustomerID, Orders, Revenue, RevenuePrevMonth, RevenueRank, LoadedAt)
        SELECT current_month.MonthStart, current_month.CustomerID,
               current_month.Orders, current_month.Revenue,
               previous_month.Revenue,
               DENSE_RANK() OVER
               (
                   PARTITION BY current_month.MonthStart
                   ORDER BY current_month.Revenue DESC
               ),
               SYSUTCDATETIME()
        FROM #MonthRevenue AS current_month
        LEFT JOIN #MonthRevenue AS previous_month
          ON previous_month.CustomerID = current_month.CustomerID
         AND previous_month.MonthStart = DATEADD(MONTH, -1, current_month.MonthStart);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        INSERT @Log VALUES (NULL, NULL, LEFT(ERROR_MESSAGE(), 100));
    END CATCH;

    SELECT * FROM @Log ORDER BY MonthStart;
    SELECT TOP (10) *
    FROM Sales.MonthlyCustomerKPI
    ORDER BY MonthStart DESC, RevenueRank;

    SET @RowsProcessed = (SELECT COUNT(*) FROM Sales.MonthlyCustomerKPI
                          WHERE MonthStart BETWEEN @FromMonth AND @ToMonth);
    DROP TABLE #MonthRevenue;

    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C27', @RowsProcessed;
END;
GO

/* C28: DML, OUTPUT, trigger side effects, and rollback */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C28
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRANSACTION;

    DECLARE @Changed TABLE
    (
        OrderID INT,
        OldStatus VARCHAR(50),
        NewStatus VARCHAR(50)
    );

    UPDATE order_header
    SET OrderStatus = 'Delivered'
    OUTPUT inserted.OrderID, deleted.OrderStatus, inserted.OrderStatus INTO @Changed
    FROM Sales.Orders AS order_header
    WHERE order_header.OrderStatus = 'Delivered'
      AND CONVERT(VARBINARY(100), order_header.OrderStatus)
          <> CONVERT(VARBINARY(100), 'Delivered');

    UPDATE order_header
    SET OrderStatus = 'Delivered'
    FROM Sales.Orders AS order_header
    JOIN
    (
        SELECT OrderID, MAX(PaymentDate) AS LastPayment
        FROM Sales.Payments
        WHERE PaymentStatus = 'Captured'
        GROUP BY OrderID
    ) AS payment ON payment.OrderID = order_header.OrderID
    WHERE order_header.OrderStatus = 'Shipped'
      AND order_header.ShipDate < DATEADD(DAY, -30, CONVERT(DATE, payment.LastPayment));

    SELECT * FROM @Changed;
    SELECT TOP (10) * FROM Sales.OrderStatusLog ORDER BY LogID DESC;

    DELETE TOP (5)
    FROM Sales.Payments
    WHERE PaymentStatus = 'Failed';

    SET @RowsProcessed = (SELECT COUNT(*) FROM @Changed);
    ROLLBACK TRANSACTION;

    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C28', @RowsProcessed;
END;
GO

/* C29: Programmable objects */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C29
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT *
    FROM Sales.fn_CustomerOrders(41, '2026-01-01')
    ORDER BY OrderSeq;

    SELECT date_spine.MonthStart,
           COUNT(*) AS Days,
           SUM(CONVERT(INT, date_spine.IsWeekend)) AS WeekendDays,
           MIN(date_spine.FiscalQtr) AS FiscalQtr
    FROM Sales.fn_DateSpine('2026-01-01', '2026-12-31') AS date_spine
    GROUP BY date_spine.MonthStart
    ORDER BY date_spine.MonthStart;

    SELECT TOP (20) OrderID, FiscalQuarter, NetAmount, CurrencyCode,
           InvoiceTotalLocal, InvoiceTotalUSD,
           Sales.fn_ToUSD(InvoiceTotalLocal, CurrencyCode, OrderDate) AS ViaScalarUdf
    FROM Sales.vw_OrderFinancials
    WHERE CurrencyCode <> 'USD'
    ORDER BY OrderID;

    EXEC Sales.usp_PivotRevenueByCategory @Year = 2025;
    EXEC Sales.usp_InventoryReorderPlan @SnapshotDate = '2026-09-30', @LeadTimeDays = 21;

    BEGIN TRANSACTION;
    DECLARE @Closed INT, @Opened INT;
    EXEC Sales.usp_ApplyCustomerChanges
        @ChangeDate = '2026-01-01', @RowsClosed = @Closed OUTPUT, @RowsOpened = @Opened OUTPUT;
    EXEC Sales.usp_ApplyCustomerChanges
        @ChangeDate = '2026-07-01', @RowsClosed = @Closed OUTPUT, @RowsOpened = @Opened OUTPUT;
    SELECT @Closed AS LastClosed, @Opened AS LastOpened;
    SELECT *
    FROM Sales.CustomerHistory
    WHERE CustomerID IN (2, 5, 41, 44, 45, 46)
    ORDER BY CustomerID, ValidFrom;
    ROLLBACK TRANSACTION;

    SET @RowsProcessed = 1;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C29', @RowsProcessed;
END;
GO

/* C30: Cohort retention matrix */
CREATE OR ALTER PROCEDURE Sales.usp_ConversionChallenge_C30
    @RunID BIGINT = NULL,
    @RowsProcessed INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    WITH FirstOrder AS
    (
        SELECT CustomerID,
               MIN(DATEFROMPARTS(YEAR(OrderDate), MONTH(OrderDate), 1)) AS CohortMonth
        FROM Sales.Orders
        WHERE OrderStatus <> 'Cancelled' AND ISNULL(Sales, 0) > 0
        GROUP BY CustomerID
    ),
    Activity AS
    (
        SELECT DISTINCT order_header.CustomerID, first_order.CohortMonth,
               DATEDIFF(MONTH, first_order.CohortMonth, order_header.OrderDate) AS MonthIndex
        FROM Sales.Orders AS order_header
        JOIN FirstOrder AS first_order ON first_order.CustomerID = order_header.CustomerID
        WHERE order_header.OrderStatus <> 'Cancelled' AND ISNULL(order_header.Sales, 0) > 0
    ),
    Cohorts AS
    (
        SELECT DATEFROMPARTS(YEAR(CohortMonth),
                             (DATEPART(QUARTER, CohortMonth) - 1) * 3 + 1, 1) AS CohortQuarter,
               CustomerID, MonthIndex
        FROM Activity
    )
    SELECT CohortQuarter,
           COUNT(DISTINCT CustomerID) AS CohortSize,
           CONVERT(DECIMAL(5,1),
                   100.0 * COUNT(DISTINCT CASE WHEN MonthIndex BETWEEN 1 AND 3 THEN CustomerID END)
                   / NULLIF(COUNT(DISTINCT CustomerID), 0)) AS RetainedM1_3_Pct,
           CONVERT(DECIMAL(5,1),
                   100.0 * COUNT(DISTINCT CASE WHEN MonthIndex BETWEEN 4 AND 6 THEN CustomerID END)
                   / NULLIF(COUNT(DISTINCT CustomerID), 0)) AS RetainedM4_6_Pct,
           CONVERT(DECIMAL(5,1),
                   100.0 * COUNT(DISTINCT CASE WHEN MonthIndex BETWEEN 7 AND 12 THEN CustomerID END)
                   / NULLIF(COUNT(DISTINCT CustomerID), 0)) AS RetainedM7_12_Pct
    FROM Cohorts
    GROUP BY CohortQuarter
    ORDER BY CohortQuarter;

    SET @RowsProcessed = @@ROWCOUNT;
    IF @RunID IS NOT NULL
        EXEC Pipeline.usp_RecordConversionChallengeResult @RunID, 'C30', @RowsProcessed;
END;
GO

/* Remove the legacy Pipeline-schema copies after all Sales procedures exist. */
DECLARE @DropLegacyProcedures NVARCHAR(MAX);

SELECT @DropLegacyProcedures = STRING_AGG(
           CONVERT(NVARCHAR(MAX),
               N'DROP PROCEDURE ' + QUOTENAME(schema_info.name) + N'.' + QUOTENAME(procedure_info.name)),
           N';')
FROM sys.procedures AS procedure_info
JOIN sys.schemas AS schema_info
  ON schema_info.schema_id = procedure_info.schema_id
JOIN Pipeline.ConversionChallengeDefinitions AS definition
  ON procedure_info.name = N'usp_ConversionChallenge_' + definition.ChallengeKey
WHERE schema_info.name = N'Pipeline';

IF @DropLegacyProcedures IS NOT NULL
    EXEC sys.sp_executesql @DropLegacyProcedures;
GO
