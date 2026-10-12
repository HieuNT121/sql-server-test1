/*
=============================================================================
 03-advanced-salesdb.sql
=============================================================================
 Adds "hard mode" objects and data to SalesDB for stress-testing a
 SQL Server (T-SQL) -> PySpark / Databricks converter.

 Run AFTER init-sqlserver-salesdb.sql and enrich-salesdb.sql.
 The script is idempotent: every object/data block is guarded, and it never
 drops or truncates the existing course tables.

 What it adds (and why it is hard to convert):
   Data types ...... MONEY, DATETIMEOFFSET, UNIQUEIDENTIFIER, XML, HIERARCHYID,
                     NVARCHAR with Unicode/emoji, computed PERSISTED columns,
                     SEQUENCE defaults
   Dirty data ...... case/trailing-space variants that SQL Server treats as equal,
                     NULL money, ship-before-order, malformed JSON, messy
                     varchar dates/numbers, duplicate timestamps (ties)
   Structures ...... system-versioned temporal table, SCD2 history,
                     exchange rates with gaps (as-of joins), overlapping promos,
                     1:N payments (fan-out double counting), JSON event stream
   Code ............ scalar UDF, inline TVF, multi-statement TVF, view,
                     AFTER UPDATE trigger, MERGE + OUTPUT SCD2 procedure,
                     cursor/WHILE procedure, dynamic-SQL PIVOT procedure
=============================================================================
*/
USE SalesDB;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ===========================================================================
   1. Sequence
   ======================================================================== */
IF OBJECT_ID(N'Sales.InvoiceNumberSeq', N'SO') IS NULL
    CREATE SEQUENCE Sales.InvoiceNumberSeq AS INT START WITH 50000 INCREMENT BY 1;
GO

/* ===========================================================================
   2. Edge-case customers and orders
      - 'germany' / 'Germany ' : equal to 'Germany' under the default CI collation
        and ANSI trailing-space comparison, but NOT equal in Spark
      - NULL country / score, apostrophes, leading spaces
   ======================================================================== */
IF NOT EXISTS (SELECT 1 FROM Sales.Customers WHERE CustomerID = 41)
BEGIN
    INSERT Sales.Customers (CustomerID, FirstName, LastName, Country, Score)
    VALUES
      (41, 'Siobhan', 'O''Brien', 'Ireland', 0),
      (42, ' Zoe',    'Müller ',  'germany', 610),
      (43, 'Minh',    'Nguyen',   'Vietnam', 700),
      (44, 'Carlos',  NULL,       NULL,      NULL),
      (45, 'Ana',     'Lima',     'Germany ', 455);
END;
GO

IF NOT EXISTS (SELECT 1 FROM Sales.CustomerProfiles WHERE CustomerID = 41)
BEGIN
    INSERT Sales.CustomerProfiles (CustomerID, Email, Segment, SignupDate, MarketingOptIn)
    VALUES
      (41, 'Siobhan.OBrien@Example.test', 'Consumer',       '2024-02-29', 1),
      (42, 'ZOE.MULLER@example.test',      'Small Business', '2023-12-31', 0),
      (43, 'minh.nguyen@example.test',     'Enterprise',     '2026-09-30', 1),
      (44, 'customer44@example.test',      'Consumer',       '2025-01-01', 0),
      (45, 'customer45@example.test',      'Consumer',       '2026-05-31', 1);
END;
GO

IF NOT EXISTS (SELECT 1 FROM Sales.Orders WHERE OrderID BETWEEN 2001 AND 2099)
BEGIN
    INSERT Sales.Orders
        (OrderID, ProductID, CustomerID, SalesPersonID, OrderDate, ShipDate,
         OrderStatus, ShipAddress, BillAddress, Quantity, Sales, CreationTime)
    VALUES
      -- two orders, same customer, same date, same CreationTime -> window-function ties
      (2001, 103, 41, 6, '2026-03-14', '2026-03-16', 'Delivered', '12 Grafton St', '12 Grafton St', 2, 40,  '2026-03-14T09:15:00'),
      (2002, 108, 41, 6, '2026-03-14', '2026-03-18', 'Delivered', '12 Grafton St', NULL,            1, 149, '2026-03-14T09:15:00'),
      -- 7 fractional digits: DATETIME2(7) precision vs Spark microseconds
      (2003, 105, 41, 7, '2026-04-02', NULL,         'Shipped',   '12 Grafton St', '',              1, 30,  '2026-04-02T23:59:59.9999999'),
      -- ship date BEFORE order date, lowercase status
      (2004, 111, 42, 7, '2026-02-28', '2026-02-27', 'delivered', 'Hauptstr. 5',   'Hauptstr. 5',   1, 179, '2026-02-28T00:00:00'),
      -- leap day, trailing space in status
      (2005, 110, 42, 6, '2024-02-29', '2024-03-04', 'Delivered ', 'Hauptstr. 5',  NULL,            2, 58,  '2024-02-29T12:00:00'),
      (2006, 112, 43, 4, '2026-09-30', '2026-10-02', 'Shipped',   '18 Pho Hue, Hanoi', '18 Pho Hue, Hanoi', 3, 102, '2026-09-30T17:30:00'),
      (2007, 109, 43, 4, '2026-09-30', '2026-10-01', 'Delivered', '18 Pho Hue, Hanoi', '',          1, 79,  '2026-09-30T17:30:00'),
      -- year boundary + zero quantity / zero sales
      (2008, 101, 44, 2, '2025-12-31', '2026-01-02', 'Delivered', NULL,            NULL,            0, 0,   '2025-12-31T23:30:00'),
      -- NULL Sales (AVG/SUM/COUNT behaviour)
      (2009, 102, 44, 2, '2026-01-01', NULL,         'Cancelled', NULL,            NULL,            1, NULL,'2026-01-01T00:00:01'),
      -- month-end dates for EOMONTH / DATEDIFF(month) semantics
      (2010, 106, 45, 3, '2026-05-31', '2026-06-02', 'Delivered', 'Hauptstr. 1',   'Hauptstr. 1',   1, 50,  '2026-05-31T08:00:00'),
      (2011, 106, 45, 3, '2026-06-30', '2026-07-01', 'Delivered', 'Hauptstr. 1',   'Hauptstr. 1',   1, 50,  '2026-06-30T08:00:00'),
      (2012, 107, 45, 3, '2026-07-31', '2026-08-01', 'Shipped',   'Hauptstr. 1',   'Hauptstr. 1',   4, 160, '2026-07-31T08:00:00');
END;
GO

IF NOT EXISTS (SELECT 1 FROM Sales.OrderLines WHERE OrderID BETWEEN 2001 AND 2099)
BEGIN
    INSERT Sales.OrderLines (OrderID, ProductID, Quantity, UnitPrice, DiscountPct)
    SELECT o.OrderID, o.ProductID,
           CONVERT(SMALLINT, CASE WHEN o.Quantity < 1 THEN 1 ELSE o.Quantity END),
           pc.ListPrice,
           CONVERT(DECIMAL(5,4), CASE WHEN o.OrderID % 2 = 0 THEN 0.0750 ELSE 0 END)
    FROM Sales.Orders AS o
    JOIN Sales.ProductCatalog AS pc ON pc.ProductID = o.ProductID
    WHERE o.OrderID BETWEEN 2001 AND 2099;
END;
GO

-- Several payments per order: joining Orders -> Payments and summing o.Sales double counts
IF NOT EXISTS (SELECT 1 FROM Sales.Payments WHERE OrderID BETWEEN 2001 AND 2099)
BEGIN
    INSERT Sales.Payments (OrderID, PaymentDate, PaymentMethod, PaymentStatus, Amount, TransactionRef)
    VALUES
      (2001, '2026-03-14T09:20:00', 'Card',          'Failed',   40.00, 'TX-2001-1'),
      (2001, '2026-03-14T09:22:00', 'Card',          'Captured', 40.00, 'TX-2001-2'),
      (2002, '2026-03-14T09:16:00', 'Wallet',        'Captured', 100.00,'TX-2002-1'),
      (2002, '2026-03-15T10:00:00', 'Wallet',        'Captured', 49.00, 'TX-2002-2'),
      (2004, '2026-02-28T00:05:00', 'Bank Transfer', 'Pending',  179.00,'TX-2004-1'),
      (2006, '2026-09-30T18:00:00', 'Card',          'Captured', 51.00, 'TX-2006-1'),
      (2006, '2026-09-30T18:00:00', 'PayPal',        'Captured', 51.00, 'TX-2006-2'),
      (2009, '2026-01-01T00:10:00', 'Card',          'Refunded', 15.00, 'TX-2009-1'),
      (2012, '2026-07-31T08:05:00', 'Card',          'Captured', 80.00, 'TX-2012-1'),
      (2012, '2026-08-15T08:05:00', 'Card',          'Captured', 80.00, 'TX-2012-2');
END;
GO

/* ===========================================================================
   3. Exchange rates with gaps (weekends, holidays, a 10-day VND outage)
      -> forces "latest rate on or before date" (as-of) joins
   ======================================================================== */
IF OBJECT_ID(N'Sales.ExchangeRates', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.ExchangeRates
    (
        CurrencyCode CHAR(3)        NOT NULL,
        RateDate     DATE           NOT NULL,
        RateToUSD    DECIMAL(18, 6) NOT NULL,   -- units of currency per 1 USD
        CONSTRAINT PK_ExchangeRates PRIMARY KEY (CurrencyCode, RateDate)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM Sales.ExchangeRates)
BEGIN
    ;WITH N AS
    (
        SELECT TOP (1004) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS d
        FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b
    ),
    Days AS
    (
        SELECT d, DATEADD(DAY, CONVERT(INT, d), CONVERT(DATE, '2024-01-01')) AS RateDate
        FROM N
    ),
    Cur AS
    (
        SELECT * FROM (VALUES
            ('EUR', CONVERT(DECIMAL(18,6), 0.92),   CONVERT(FLOAT, 0.03)),
            ('GBP', CONVERT(DECIMAL(18,6), 0.79),   CONVERT(FLOAT, 0.025)),
            ('JPY', CONVERT(DECIMAL(18,6), 148.50), CONVERT(FLOAT, 6.0)),
            ('VND', CONVERT(DECIMAL(18,6), 24600),  CONVERT(FLOAT, 450.0))
        ) AS v (CurrencyCode, BaseRate, Amp)
    )
    INSERT Sales.ExchangeRates (CurrencyCode, RateDate, RateToUSD)
    SELECT c.CurrencyCode,
           d.RateDate,
           CONVERT(DECIMAL(18,6), c.BaseRate + c.Amp * SIN(d.d / 45.0 + ASCII(c.CurrencyCode)))
    FROM Days AS d
    CROSS JOIN Cur AS c
    WHERE DATEDIFF(DAY, '19000101', d.RateDate) % 7 NOT IN (5, 6)             -- no weekends (DATEFIRST-independent)
      AND NOT (MONTH(d.RateDate) = 1  AND DAY(d.RateDate) = 1)                -- New Year
      AND NOT (MONTH(d.RateDate) = 12 AND DAY(d.RateDate) = 25)               -- Christmas
      AND NOT (c.CurrencyCode = 'VND' AND d.RateDate BETWEEN '2025-04-10' AND '2025-04-21'); -- outage
END;
GO

/* ===========================================================================
   4. Invoices: MONEY, DATETIMEOFFSET, UNIQUEIDENTIFIER, SEQUENCE default,
      PERSISTED computed columns, Unicode/emoji/control characters
   ======================================================================== */
IF OBJECT_ID(N'Sales.Invoices', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.Invoices
    (
        InvoiceID    INT              NOT NULL CONSTRAINT PK_Invoices PRIMARY KEY
                                      CONSTRAINT DF_Invoices_ID DEFAULT (NEXT VALUE FOR Sales.InvoiceNumberSeq),
        InvoiceGuid  UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Invoices_Guid DEFAULT (NEWID()),
        OrderID      INT              NOT NULL,
        CurrencyCode CHAR(3)          NOT NULL,
        IssuedAt     DATETIMEOFFSET(0) NOT NULL,
        AmountLocal  MONEY            NULL,
        TaxRate      DECIMAL(5, 4)    NOT NULL,
        TaxAmount    AS CONVERT(MONEY, ROUND(AmountLocal * TaxRate, 2)) PERSISTED,
        TotalAmount  AS CONVERT(MONEY, AmountLocal + ROUND(AmountLocal * TaxRate, 2)) PERSISTED,
        Notes        NVARCHAR(400)    NULL,
        CONSTRAINT FK_Invoices_Orders FOREIGN KEY (OrderID) REFERENCES Sales.Orders(OrderID),
        CONSTRAINT UQ_Invoices_Order UNIQUE (OrderID)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM Sales.Invoices)
BEGIN
    ;WITH Src AS
    (
        SELECT o.OrderID, o.OrderDate, o.Sales,
               CASE UPPER(LTRIM(RTRIM(c.Country)))
                    WHEN 'GERMANY' THEN 'EUR' WHEN 'FRANCE' THEN 'EUR' WHEN 'ITALY' THEN 'EUR'
                    WHEN 'SPAIN' THEN 'EUR' WHEN 'PORTUGAL' THEN 'EUR' WHEN 'IRELAND' THEN 'EUR'
                    WHEN 'UK' THEN 'GBP' WHEN 'JAPAN' THEN 'JPY' WHEN 'VIETNAM' THEN 'VND'
                    ELSE 'USD' END AS CurrencyCode,
               CASE UPPER(LTRIM(RTRIM(c.Country)))
                    WHEN 'GERMANY' THEN 0.19 WHEN 'FRANCE' THEN 0.20 WHEN 'ITALY' THEN 0.22
                    WHEN 'SPAIN' THEN 0.21 WHEN 'PORTUGAL' THEN 0.23 WHEN 'IRELAND' THEN 0.23
                    WHEN 'UK' THEN 0.20 WHEN 'JAPAN' THEN 0.10 WHEN 'VIETNAM' THEN 0.10
                    ELSE 0.0725 END AS TaxRate
        FROM Sales.Orders AS o
        LEFT JOIN Sales.Customers AS c ON c.CustomerID = o.CustomerID
        WHERE o.OrderID >= 1001
          AND o.OrderStatus <> 'Cancelled'
    )
    INSERT Sales.Invoices (InvoiceID, InvoiceGuid, OrderID, CurrencyCode, IssuedAt, AmountLocal, TaxRate, Notes)
    SELECT NEXT VALUE FOR Sales.InvoiceNumberSeq OVER (ORDER BY s.OrderID),
           CONVERT(UNIQUEIDENTIFIER, HASHBYTES('MD5', CONCAT('INV-', s.OrderID))),   -- deterministic GUID
           s.OrderID,
           s.CurrencyCode,
           -- issued 20:00-03:00 local time: local date, UTC date and order date can all differ
           TODATETIMEOFFSET(
               DATEADD(HOUR, 20 + s.OrderID % 8, CONVERT(DATETIME2(0), s.OrderDate)),
               CASE s.CurrencyCode WHEN 'EUR' THEN '+01:00' WHEN 'GBP' THEN '+00:00'
                                   WHEN 'JPY' THEN '+09:00' WHEN 'VND' THEN '+07:00'
                                   ELSE '-05:00' END),
           CONVERT(MONEY, s.Sales * CASE s.CurrencyCode WHEN 'EUR' THEN 0.92 WHEN 'GBP' THEN 0.79
                                                         WHEN 'JPY' THEN 148.5 WHEN 'VND' THEN 24600
                                                         ELSE 1 END),
           s.TaxRate,
           CASE s.OrderID % 9
                WHEN 0 THEN N'Giao hàng nhanh – khách VIP 🚚'
                WHEN 1 THEN N'Lieferung an Packstation – Straße 5'
                WHEN 2 THEN N'配送前に電話してください'
                WHEN 3 THEN N'   leading and trailing spaces   '
                WHEN 4 THEN N''
                WHEN 5 THEN NULL
                WHEN 6 THEN CONCAT(N'Tab', NCHAR(9), N'separated "quoted", value; ok')
                WHEN 7 THEN CONCAT(N'Line1', NCHAR(13), NCHAR(10), N'Line2')
                ELSE N'50% off – coupon [SPRING_25]'
           END
    FROM Src AS s;
END;
GO

/* ===========================================================================
   5. Raw customer feed: everything stored as text, mixed formats
   ======================================================================== */
IF OBJECT_ID(N'Sales.RawCustomerFeed', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.RawCustomerFeed
    (
        FeedRowID         INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_RawCustomerFeed PRIMARY KEY,
        SourceFile        NVARCHAR(100) NOT NULL,
        CustomerRef       NVARCHAR(20)  NULL,
        FullName          NVARCHAR(200) NULL,
        CountryRaw        NVARCHAR(60)  NULL,
        SignupDateRaw     VARCHAR(30)   NULL,
        LifetimeValueRaw  VARCHAR(30)   NULL,
        PhoneRaw          VARCHAR(40)   NULL,
        TagsCsv           NVARCHAR(200) NULL,
        LoadedAt          DATETIME2(3)  NOT NULL
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM Sales.RawCustomerFeed)
BEGIN
    INSERT Sales.RawCustomerFeed
        (SourceFile, CustomerRef, FullName, CountryRaw, SignupDateRaw, LifetimeValueRaw, PhoneRaw, TagsCsv, LoadedAt)
    VALUES
      (N'crm_2026_09.csv', N'C-0001', N'Jossef Goldberg',      N'Germany',      '2023-04-01',   '1234.50',    '+49 30 1234567',  N'vip,newsletter',        '2026-09-01T02:00:00.123'),
      (N'crm_2026_09.csv', N'c-0002', N'  Kevin  Brown ',      N'U.S.A.',       '04/15/2023',   '1,234.50',   '(212) 555-0199',  N'newsletter',            '2026-09-01T02:00:00.123'),
      (N'crm_2026_09.csv', N'C-0003', N'Mary',                 N'usa',          '15/04/2023',   '$980',       '212.555.0100',    N'',                      '2026-09-01T02:00:00.123'),
      (N'crm_2026_09.csv', N'C-0004', N'Mark Schwarz',         N'DE',           '20230501',     '1.2e3',      NULL,              N'vip, churn-risk ,',     '2026-09-01T02:00:00.123'),
      (N'crm_2026_09.csv', N'C-0005', N'Anna Adams',           N'United States','1 May 2023',   'n/a',        '555 0101',        NULL,                     '2026-09-01T02:00:00.123'),
      (N'crm_2026_09.csv', N'C-0043', N'Nguyễn Văn Minh',      N'Việt Nam',     '2026-09-30T23:59:59', '25.000.000', '+84 24 3826 1234', N'enterprise,vip',  '2026-09-01T02:00:00.123'),
      (N'crm_2026_09.csv', N'C-0042', N'Zoë Müller',           N'Deutschland',  '31.12.2023',   '610,00',     '+49 (0)89 123',   N'newsletter',            '2026-09-01T02:00:00.123'),
      (N'crm_2026_09.csv', N'C-0041', N'Siobhán O''Brien',     N'Ireland',      '2024-02-29',   '0',          '+353 1 555 0000', N'new',                   '2026-09-01T02:00:00.123'),
      (N'crm_2026_09.csv', N'C-0044', N'Carlos',               NULL,            '2025-02-30',   '-15.5',      '',                N'refund,refund',         '2026-09-01T02:00:00.123'),
      (N'crm_2026_09.csv', NULL,      N'田中 太郎',             N'Japan',        '2025/07/07',   '¥120000',    '03-1234-5678',    N'vip',                   '2026-09-01T02:00:00.123'),
      -- same customer delivered twice in a later file: latest load must win
      (N'crm_2026_10.csv', N'C-0002', N'Kevin Brown',          N'USA',          '2023-04-15',   '1500.75',    '+1 212 555 0199', N'newsletter,vip',        '2026-10-01T02:00:00.000'),
      (N'crm_2026_10.csv', N'C-0001', N'Jossef Goldberg',      N'Germany',      '2023-04-01',   '1234.50',    '+49 30 1234567',  N'vip,newsletter',        '2026-10-01T02:00:00.000'),
      (N'crm_2026_10.csv', N'C-0099', N'Test User',            N'N/A',          '',             '',           'xxx',             N'test',                  '2026-10-01T02:00:00.000'),
      (N'crm_2026_10.csv', N'C-0045', N'Ana Lima',             N' germany',     'May 31, 2026', '455.',       '+49 1',           N'newsletter',            '2026-10-01T02:00:00.000');
END;
GO

/* ===========================================================================
   6. Web event stream with JSON payloads (some malformed)
   ======================================================================== */
IF OBJECT_ID(N'Sales.WebEvents', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.WebEvents
    (
        EventID    BIGINT        NOT NULL CONSTRAINT PK_WebEvents PRIMARY KEY,
        CustomerID INT           NOT NULL,
        EventTime  DATETIME2(3)  NOT NULL,
        Payload    NVARCHAR(MAX) NOT NULL
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM Sales.WebEvents)
BEGIN
    ;WITH N AS
    (
        SELECT TOP (2970) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n
        FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b
    ),
    Base AS
    (
        SELECT n,
               CONVERT(INT, n / 45) AS r,
               CONVERT(INT, 1 + (n * 7) % 45) AS CustomerID
        FROM N
    ),
    Typed AS
    (
        SELECT b.*,
               CASE b.r % 6
                    WHEN 0 THEN 'page_view' WHEN 1 THEN 'page_view' WHEN 2 THEN 'search'
                    WHEN 3 THEN 'add_to_cart' WHEN 4 THEN 'checkout'
                    ELSE CASE WHEN (b.CustomerID + b.r / 6) % 3 = 0 THEN 'purchase' ELSE 'page_view' END
               END AS EventType,
               101 + b.n % 12       AS Product1,
               101 + (b.n + 5) % 12 AS Product2
        FROM Base AS b
    ),
    Built AS
    (
        SELECT t.n, t.CustomerID,
               DATEADD(MILLISECOND, (t.n * 131) % 1000,
                   DATEADD(SECOND, t.r * 600 + (t.r / 6) * 7200 + ((t.r * t.r) % 7) * 60 + t.CustomerID * 37,
                           CONVERT(DATETIME2(3), '2026-09-01T00:00:00'))) AS EventTime,
               CONCAT(
                   N'{"type":"', t.EventType, N'",',
                   N'"page":"/products/', t.Product1, N'",',
                   N'"device":{"os":"', CASE t.n % 3 WHEN 0 THEN N'iOS' WHEN 1 THEN N'Android' ELSE N'Web' END, N'",',
                   N'"appVersion":', CASE WHEN t.n % 3 = 2 THEN N'null' ELSE CONCAT(N'"', 3 + t.n % 2, N'.', t.n % 10, N'"') END, N'},',
                   N'"items":',
                   CASE WHEN t.EventType IN ('add_to_cart', 'checkout', 'purchase')
                        THEN CONCAT(N'[{"sku":"', p1.SKU, N'","qty":', 1 + t.n % 3, N',"price":', p1.ListPrice, N'},',
                                    N'{"sku":"', p2.SKU, N'","qty":1,"price":', p2.ListPrice, N'}]')
                        ELSE N'[]' END, N',',
                   N'"utm":', CASE WHEN t.n % 4 = 0 THEN N'{"source":"newsletter","campaign":"autumn-26"}' ELSE N'null' END,
                   N'}') AS Payload
        FROM Typed AS t
        JOIN Sales.ProductCatalog AS p1 ON p1.ProductID = t.Product1
        JOIN Sales.ProductCatalog AS p2 ON p2.ProductID = t.Product2
    )
    INSERT Sales.WebEvents (EventID, CustomerID, EventTime, Payload)
    SELECT 900000 + n,
           CustomerID,
           EventTime,
           CASE WHEN n % 250 = 0 THEN LEFT(Payload, 30) ELSE Payload END   -- malformed JSON
    FROM Built;
END;
GO

/* ===========================================================================
   7. Overlapping promotions (range joins + "best promo wins")
   ======================================================================== */
IF OBJECT_ID(N'Sales.Promotions', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.Promotions
    (
        PromoID     INT          NOT NULL CONSTRAINT PK_Promotions PRIMARY KEY,
        PromoCode   VARCHAR(30)  NOT NULL,
        CategoryID  INT          NULL,          -- NULL = site-wide
        StartDate   DATE         NOT NULL,
        EndDate     DATE         NULL,          -- NULL = open-ended
        DiscountPct DECIMAL(5,4) NOT NULL,
        Priority    TINYINT      NOT NULL
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM Sales.Promotions)
BEGIN
    INSERT Sales.Promotions (PromoID, PromoCode, CategoryID, StartDate, EndDate, DiscountPct, Priority)
    VALUES
      (1, 'NEWYEAR24',    NULL, '2024-01-01', '2024-01-15', 0.1000, 2),
      (2, 'SPRING_CYCLE', 1,    '2024-03-01', '2024-05-31', 0.1500, 1),
      (3, 'APPAREL25',    2,    '2025-01-01', '2025-12-31', 0.2000, 1),
      (4, 'SUMMER_ALL',   NULL, '2025-06-01', '2025-08-31', 0.1000, 3),
      (5, 'TECH_WEEK',    5,    '2025-08-25', '2025-09-01', 0.2500, 1),
      (6, 'CAMP_FOREVER', 4,    '2025-10-01', NULL,         0.0500, 5),
      (7, 'BLACKFRIDAY',  NULL, '2025-11-28', '2025-11-28', 0.3000, 0),
      (8, 'APPAREL25_EXT',2,    '2025-12-01', '2026-02-28', 0.2000, 1);  -- overlaps APPAREL25, same discount: tie
END;
GO

/* ===========================================================================
   8. Product attributes as XML
   ======================================================================== */
IF OBJECT_ID(N'Sales.ProductAttributes', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.ProductAttributes
    (
        ProductID  INT NOT NULL CONSTRAINT PK_ProductAttributes PRIMARY KEY,
        Attributes XML NOT NULL,
        CONSTRAINT FK_ProductAttributes_Products FOREIGN KEY (ProductID) REFERENCES Sales.ProductCatalog(ProductID)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM Sales.ProductAttributes)
BEGIN
    INSERT Sales.ProductAttributes (ProductID, Attributes)
    SELECT p.ProductID,
           CONVERT(XML, CONCAT(
               '<attributes sku="', p.SKU, '">',
               '<attr name="color">', CASE p.ProductID % 4 WHEN 0 THEN 'Black' WHEN 1 THEN 'Red'
                                                           WHEN 2 THEN 'Blue' ELSE 'Olive' END, '</attr>',
               '<attr name="weight_g">', (p.ProductID * 13) % 900 + 50, '</attr>',
               CASE WHEN p.CategoryID = 2
                    THEN '<sizes><size code="S" stock="4"/><size code="M" stock="0"/><size code="L" stock="7"/></sizes>'
                    ELSE '' END,
               CASE WHEN p.CategoryID = 5 THEN '<battery type="Li-ion" mAh="1200"/>' ELSE '' END,
               '</attributes>'))
    FROM Sales.ProductCatalog AS p;
END;
GO

/* ===========================================================================
   9. Org chart with HIERARCHYID
   ======================================================================== */
IF OBJECT_ID(N'Sales.OrgChart', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.OrgChart
    (
        EmployeeID INT         NOT NULL CONSTRAINT PK_OrgChart PRIMARY KEY,
        Node       HIERARCHYID NOT NULL CONSTRAINT UQ_OrgChart_Node UNIQUE,
        NodeLevel  AS Node.GetLevel() PERSISTED
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM Sales.OrgChart)
BEGIN
    ;WITH Sib AS
    (
        SELECT EmployeeID, ManagerID,
               ROW_NUMBER() OVER (PARTITION BY ManagerID ORDER BY EmployeeID) AS rn
        FROM Sales.Employees
    ),
    Tree AS
    (
        SELECT EmployeeID, CONVERT(VARCHAR(400), '/') AS NodePath
        FROM Sib WHERE ManagerID IS NULL
        UNION ALL
        SELECT s.EmployeeID, CONVERT(VARCHAR(400), t.NodePath + CONVERT(VARCHAR(10), s.rn) + '/')
        FROM Sib AS s
        JOIN Tree AS t ON s.ManagerID = t.EmployeeID
    )
    INSERT Sales.OrgChart (EmployeeID, Node)
    SELECT EmployeeID, hierarchyid::Parse(NodePath)
    FROM Tree;
END;
GO

/* ===========================================================================
   10. System-versioned temporal price list with back-filled history
   ======================================================================== */
IF OBJECT_ID(N'Sales.PriceList', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.PriceList
    (
        ProductID INT           NOT NULL CONSTRAINT PK_PriceList PRIMARY KEY,
        ListPrice DECIMAL(10,2) NOT NULL,
        Currency  CHAR(3)       NOT NULL,
        ValidFrom DATETIME2(0)  GENERATED ALWAYS AS ROW START NOT NULL,
        ValidTo   DATETIME2(0)  GENERATED ALWAYS AS ROW END   NOT NULL,
        PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo)
    );
END;
GO

IF OBJECT_ID(N'Sales.PriceListHistory', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.PriceListHistory
    (
        ProductID INT           NOT NULL,
        ListPrice DECIMAL(10,2) NOT NULL,
        Currency  CHAR(3)       NOT NULL,
        ValidFrom DATETIME2(0)  NOT NULL,
        ValidTo   DATETIME2(0)  NOT NULL
    );
END;
GO

IF EXISTS (SELECT 1 FROM sys.tables WHERE object_id = OBJECT_ID(N'Sales.PriceList') AND temporal_type = 0)
   AND NOT EXISTS (SELECT 1 FROM Sales.PriceList)
BEGIN
    -- Compile the history-table DML only while PriceListHistory is still a
    -- regular table. On repeat runs SQL Server rejects even unreachable DML
    -- that directly targets a temporal history table.
    EXEC sys.sp_executesql N'
        INSERT Sales.PriceList (ProductID, ListPrice, Currency)
        SELECT ProductID, ListPrice, ''USD'' FROM Sales.ProductCatalog;

        INSERT Sales.PriceListHistory (ProductID, ListPrice, Currency, ValidFrom, ValidTo)
        SELECT p.ProductID, CONVERT(DECIMAL(10,2), p.ListPrice * 0.85), ''USD'',
               CONVERT(DATETIME2(0), pc.LaunchDate), ''2025-01-01T00:00:00''
        FROM Sales.PriceList AS p
        JOIN Sales.ProductCatalog AS pc ON pc.ProductID = p.ProductID
        UNION ALL
        SELECT p.ProductID, CONVERT(DECIMAL(10,2), p.ListPrice * 0.95), ''USD'',
               ''2025-01-01T00:00:00'', DATEADD(SECOND, -1, p.ValidFrom)
        FROM Sales.PriceList AS p;';
END;
GO

-- A row end timestamp equal to the current row start can be considered a
-- future history value when this script is executed within the same second.
-- Keep the seeded history safely before the current system-time period.
IF EXISTS (SELECT 1 FROM sys.tables WHERE object_id = OBJECT_ID(N'Sales.PriceList') AND temporal_type = 0)
    EXEC sys.sp_executesql N'
        UPDATE history
        SET ValidTo = DATEADD(SECOND, -1, current_row.ValidFrom)
        FROM Sales.PriceListHistory AS history
        JOIN Sales.PriceList AS current_row ON current_row.ProductID = history.ProductID
        WHERE history.ValidTo >= current_row.ValidFrom;';
GO

IF EXISTS (SELECT 1 FROM sys.tables WHERE object_id = OBJECT_ID(N'Sales.PriceList') AND temporal_type = 0)
    ALTER TABLE Sales.PriceList
        SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = Sales.PriceListHistory, DATA_CONSISTENCY_CHECK = ON));
GO

/* ===========================================================================
   11. SCD Type 2 customer history + staged changes (applied by a MERGE proc)
       No FK / trigger on purpose: it is the target of composable DML.
   ======================================================================== */
IF OBJECT_ID(N'Sales.CustomerHistory', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.CustomerHistory
    (
        CustomerSK INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_CustomerHistory PRIMARY KEY,
        CustomerID INT          NOT NULL,
        Country    VARCHAR(50)  NULL,
        Segment    VARCHAR(20)  NULL,
        Score      INT          NULL,
        ValidFrom  DATE         NOT NULL,
        ValidTo    DATE         NULL,     -- NULL = still valid
        IsCurrent  BIT          NOT NULL
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM Sales.CustomerHistory)
BEGIN
    INSERT Sales.CustomerHistory (CustomerID, Country, Segment, Score, ValidFrom, ValidTo, IsCurrent)
    SELECT c.CustomerID, c.Country, p.Segment, c.Score,
           ISNULL(p.SignupDate, '2023-01-01'),
           CASE WHEN c.CustomerID % 6 = 0 AND p.SignupDate < '2025-06-01' THEN CONVERT(DATE, '2025-06-30') END,
           CASE WHEN c.CustomerID % 6 = 0 AND p.SignupDate < '2025-06-01' THEN 0 ELSE 1 END
    FROM Sales.Customers AS c
    LEFT JOIN Sales.CustomerProfiles AS p ON p.CustomerID = c.CustomerID;

    INSERT Sales.CustomerHistory (CustomerID, Country, Segment, Score, ValidFrom, ValidTo, IsCurrent)
    SELECT c.CustomerID, c.Country,
           CASE p.Segment WHEN 'Consumer' THEN 'Small Business' ELSE 'Enterprise' END,
           ISNULL(c.Score, 0) + 50,
           '2025-07-01', NULL, 1
    FROM Sales.Customers AS c
    JOIN Sales.CustomerProfiles AS p ON p.CustomerID = c.CustomerID
    WHERE c.CustomerID % 6 = 0 AND p.SignupDate < '2025-06-01';
END;
GO

IF OBJECT_ID(N'Sales.CustomerChanges', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.CustomerChanges
    (
        ChangeID   INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_CustomerChanges PRIMARY KEY,
        CustomerID INT         NOT NULL,
        ChangeDate DATE        NOT NULL,
        Country    VARCHAR(50) NULL,
        Segment    VARCHAR(20) NULL,
        Score      INT         NULL
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM Sales.CustomerChanges)
BEGIN
    INSERT Sales.CustomerChanges (CustomerID, ChangeDate, Country, Segment, Score)
    VALUES
      (2,  '2026-01-01', 'USA',     'Enterprise',     950),   -- real change
      (5,  '2026-01-01', 'USA',     'Consumer',       NULL),  -- NULL -> NULL score: must NOT version
      (44, '2026-01-01', 'Mexico',  'Consumer',       300),   -- NULL country -> value
      (46, '2026-01-01', 'Chile',   'Consumer',       500),   -- brand-new customer
      (41, '2026-07-01', 'Ireland', 'Consumer',       0),     -- no-op
      (2,  '2026-07-01', 'Canada',  'Enterprise',     950),   -- second change, same customer
      (45, '2026-07-01', 'Germany', 'Consumer',       455);   -- only trailing space differs: change or not?
END;
GO

/* ===========================================================================
   12. Status audit log + monthly KPI table (targets for procedural scripts)
   ======================================================================== */
IF OBJECT_ID(N'Sales.OrderStatusLog', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.OrderStatusLog
    (
        LogID     BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_OrderStatusLog PRIMARY KEY,
        OrderID   INT           NOT NULL,
        OldStatus VARCHAR(50)   NULL,
        NewStatus VARCHAR(50)   NULL,
        ChangedAt DATETIME2(3)  NOT NULL,
        ChangedBy NVARCHAR(128) NOT NULL
    );
END;
GO

IF OBJECT_ID(N'Sales.MonthlyCustomerKPI', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.MonthlyCustomerKPI
    (
        MonthStart       DATE          NOT NULL,
        CustomerID       INT           NOT NULL,
        Orders           INT           NOT NULL,
        Revenue          DECIMAL(14,2) NOT NULL,
        RevenuePrevMonth DECIMAL(14,2) NULL,
        RevenueRank      INT           NOT NULL,
        LoadedAt         DATETIME2(0)  NOT NULL,
        CONSTRAINT PK_MonthlyCustomerKPI PRIMARY KEY (MonthStart, CustomerID)
    );
END;
GO

/* ===========================================================================
   13. Programmable objects
   ======================================================================== */

-- Scalar UDF: fiscal quarter, fiscal year starts 1 July
CREATE OR ALTER FUNCTION Sales.fn_FiscalQuarter (@d DATE)
RETURNS CHAR(7)
WITH SCHEMABINDING
AS
BEGIN
    IF @d IS NULL RETURN NULL;
    DECLARE @shifted DATE = DATEADD(MONTH, 6, @d);
    RETURN CONCAT('FY', RIGHT(CONVERT(CHAR(4), YEAR(@shifted)), 2), '-Q', DATEPART(QUARTER, @shifted));
END;
GO

-- Scalar UDF with a data access + NULL handling
CREATE OR ALTER FUNCTION Sales.fn_ToUSD (@Amount MONEY, @Currency CHAR(3), @AsOf DATE)
RETURNS DECIMAL(14, 2)
AS
BEGIN
    IF @Currency = 'USD' RETURN CONVERT(DECIMAL(14,2), @Amount);
    DECLARE @rate DECIMAL(18,6);
    SELECT TOP (1) @rate = RateToUSD
    FROM Sales.ExchangeRates
    WHERE CurrencyCode = @Currency AND RateDate <= @AsOf
    ORDER BY RateDate DESC;
    RETURN CONVERT(DECIMAL(14,2), @Amount / NULLIF(@rate, 0));
END;
GO

-- Inline TVF
CREATE OR ALTER FUNCTION Sales.fn_CustomerOrders (@CustomerID INT, @FromDate DATE)
RETURNS TABLE
AS
RETURN
(
    SELECT o.OrderID, o.OrderDate, o.OrderStatus, o.Sales,
           ROW_NUMBER() OVER (ORDER BY o.OrderDate, o.OrderID) AS OrderSeq
    FROM Sales.Orders AS o
    WHERE o.CustomerID = @CustomerID
      AND o.OrderDate >= @FromDate
);
GO

-- Multi-statement TVF with a WHILE loop (date spine)
CREATE OR ALTER FUNCTION Sales.fn_DateSpine (@FromDate DATE, @ToDate DATE)
RETURNS @Days TABLE
(
    CalendarDate DATE NOT NULL PRIMARY KEY,
    MonthStart   DATE NOT NULL,
    IsWeekend    BIT  NOT NULL,
    FiscalQtr    CHAR(7) NOT NULL
)
AS
BEGIN
    DECLARE @d DATE = @FromDate;
    WHILE @d <= @ToDate
    BEGIN
        INSERT @Days (CalendarDate, MonthStart, IsWeekend, FiscalQtr)
        VALUES (@d,
                DATEFROMPARTS(YEAR(@d), MONTH(@d), 1),
                CASE WHEN DATEDIFF(DAY, '19000101', @d) % 7 IN (5, 6) THEN 1 ELSE 0 END,
                Sales.fn_FiscalQuarter(@d));
        SET @d = DATEADD(DAY, 1, @d);
    END;
    RETURN;
END;
GO

-- View: order financials with FX as-of lookup
CREATE OR ALTER VIEW Sales.vw_OrderFinancials
AS
SELECT o.OrderID,
       o.CustomerID,
       o.OrderDate,
       Sales.fn_FiscalQuarter(o.OrderDate) AS FiscalQuarter,
       o.OrderStatus,
       lines.LineCount,
       lines.GrossAmount,
       lines.NetAmount,
       i.InvoiceID,
       i.CurrencyCode,
       i.TotalAmount AS InvoiceTotalLocal,
       CONVERT(DECIMAL(14,2),
           i.TotalAmount / COALESCE(fx.RateToUSD, CASE WHEN i.CurrencyCode = 'USD' THEN 1 END)) AS InvoiceTotalUSD
FROM Sales.Orders AS o
OUTER APPLY
(
    SELECT COUNT(*) AS LineCount,
           SUM(ol.Quantity * ol.UnitPrice) AS GrossAmount,
           SUM(CONVERT(DECIMAL(14,2), ol.Quantity * ol.UnitPrice * (1 - ol.DiscountPct))) AS NetAmount
    FROM Sales.OrderLines AS ol
    WHERE ol.OrderID = o.OrderID
) AS lines
LEFT JOIN Sales.Invoices AS i ON i.OrderID = o.OrderID
OUTER APPLY
(
    SELECT TOP (1) r.RateToUSD
    FROM Sales.ExchangeRates AS r
    WHERE r.CurrencyCode = i.CurrencyCode
      AND r.RateDate <= CONVERT(DATE, i.IssuedAt)
    ORDER BY r.RateDate DESC
) AS fx;
GO

-- Trigger: audit status changes (uses inserted/deleted pseudo-tables)
CREATE OR ALTER TRIGGER Sales.trg_Orders_StatusAudit
ON Sales.Orders
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(OrderStatus) RETURN;

    INSERT Sales.OrderStatusLog (OrderID, OldStatus, NewStatus, ChangedAt, ChangedBy)
    SELECT i.OrderID, d.OrderStatus, i.OrderStatus, SYSUTCDATETIME(), SUSER_SNAME()
    FROM inserted AS i
    JOIN deleted  AS d ON d.OrderID = i.OrderID
    WHERE EXISTS (SELECT i.OrderStatus EXCEPT SELECT d.OrderStatus);   -- NULL-safe "is different"
END;
GO

-- SCD2 apply: composable DML (INSERT ... SELECT FROM (MERGE ... OUTPUT)), TRY/CATCH, THROW
CREATE OR ALTER PROCEDURE Sales.usp_ApplyCustomerChanges
    @ChangeDate DATE,
    @RowsClosed INT = NULL OUTPUT,
    @RowsOpened INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF EXISTS (SELECT CustomerID FROM Sales.CustomerChanges
               WHERE ChangeDate = @ChangeDate
               GROUP BY CustomerID HAVING COUNT(*) > 1)
        THROW 50010, 'Duplicate customer rows in the change batch.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- 1) close changed versions and insert brand-new customers
        INSERT Sales.CustomerHistory (CustomerID, Country, Segment, Score, ValidFrom, ValidTo, IsCurrent)
        SELECT chg.CustomerID, chg.Country, chg.Segment, chg.Score, @ChangeDate, NULL, 1
        FROM
        (
            MERGE Sales.CustomerHistory AS tgt
            USING (SELECT CustomerID, Country, Segment, Score
                   FROM Sales.CustomerChanges
                   WHERE ChangeDate = @ChangeDate) AS src
               ON tgt.CustomerID = src.CustomerID
              AND tgt.IsCurrent = 1
            WHEN MATCHED AND EXISTS (SELECT src.Country, src.Segment, src.Score
                                     EXCEPT
                                     SELECT tgt.Country, tgt.Segment, tgt.Score)
                THEN UPDATE SET tgt.ValidTo   = DATEADD(DAY, -1, @ChangeDate),
                                tgt.IsCurrent = 0
            WHEN NOT MATCHED BY TARGET
                THEN INSERT (CustomerID, Country, Segment, Score, ValidFrom, ValidTo, IsCurrent)
                     VALUES (src.CustomerID, src.Country, src.Segment, src.Score, @ChangeDate, NULL, 1)
            OUTPUT $action AS MergeAction, src.CustomerID, src.Country, src.Segment, src.Score
        ) AS chg
        WHERE chg.MergeAction = 'UPDATE';

        SET @RowsOpened = @@ROWCOUNT;

        SELECT @RowsClosed = COUNT(*)
        FROM Sales.CustomerHistory
        WHERE ValidTo = DATEADD(DAY, -1, @ChangeDate) AND IsCurrent = 0;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

-- Cursor + nested WHILE + temp table
CREATE OR ALTER PROCEDURE Sales.usp_InventoryReorderPlan
    @SnapshotDate DATE,
    @LeadTimeDays INT = 14,
    @PackSize     INT = 6
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #Plan
    (
        ProductID     INT,
        Warehouse     VARCHAR(30),
        OnHand        INT,
        ReorderPoint  INT,
        AvgDailyUnits DECIMAL(10,4),
        DaysOfCover   DECIMAL(10,2) NULL,
        OrderQty      INT,
        PlanAction    VARCHAR(20)
    );

    DECLARE @ProductID INT, @Warehouse VARCHAR(30), @OnHand INT, @Reorder INT,
            @Avg DECIMAL(10,4), @Qty INT;

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT ProductID, Warehouse, OnHand, ReorderPoint
        FROM Sales.InventorySnapshots
        WHERE SnapshotDate = @SnapshotDate
        ORDER BY ProductID, Warehouse;

    OPEN cur;
    FETCH NEXT FROM cur INTO @ProductID, @Warehouse, @OnHand, @Reorder;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- demand of last 90 days spread evenly over 3 warehouses
        SELECT @Avg = ISNULL(SUM(ol.Quantity), 0) / 90.0 / 3
        FROM Sales.OrderLines AS ol
        JOIN Sales.Orders AS o ON o.OrderID = ol.OrderID
        WHERE ol.ProductID = @ProductID
          AND o.OrderDate >  DATEADD(DAY, -90, @SnapshotDate)
          AND o.OrderDate <= @SnapshotDate
          AND o.OrderStatus <> 'Cancelled';

        SET @Qty = 0;
        WHILE @OnHand + @Qty < CEILING(@Avg * @LeadTimeDays) + @Reorder
            SET @Qty += @PackSize;

        INSERT #Plan
        VALUES (@ProductID, @Warehouse, @OnHand, @Reorder, @Avg,
                CASE WHEN @Avg = 0 THEN NULL ELSE @OnHand / @Avg END,
                @Qty,
                CASE WHEN @Qty = 0 THEN 'OK'
                     WHEN @OnHand < @Reorder THEN 'URGENT'
                     ELSE 'REORDER' END);

        FETCH NEXT FROM cur INTO @ProductID, @Warehouse, @OnHand, @Reorder;
    END;

    CLOSE cur;
    DEALLOCATE cur;

    SELECT *
    FROM #Plan
    ORDER BY CASE PlanAction WHEN 'URGENT' THEN 0 WHEN 'REORDER' THEN 1 ELSE 2 END,
             DaysOfCover, ProductID, Warehouse;
END;
GO

-- Dynamic-SQL PIVOT: column list is only known at run time
CREATE OR ALTER PROCEDURE Sales.usp_PivotRevenueByCategory
    @Year INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @cols NVARCHAR(MAX), @sql NVARCHAR(MAX);

    SELECT @cols = STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(CategoryName)), N', ')
                   WITHIN GROUP (ORDER BY CategoryName)
    FROM Sales.Categories;

    SET @sql = N'
SELECT MonthNo, ' + @cols + N'
FROM
(
    SELECT MONTH(o.OrderDate) AS MonthNo,
           c.CategoryName,
           ol.Quantity * ol.UnitPrice * (1 - ol.DiscountPct) AS NetAmount
    FROM Sales.Orders AS o
    JOIN Sales.OrderLines AS ol ON ol.OrderID = o.OrderID
    JOIN Sales.ProductCatalog AS p ON p.ProductID = ol.ProductID
    JOIN Sales.Categories AS c ON c.CategoryID = p.CategoryID
    WHERE YEAR(o.OrderDate) = @Year
      AND o.OrderStatus <> ''Cancelled''
) AS src
PIVOT (SUM(NetAmount) FOR CategoryName IN (' + @cols + N')) AS pvt
ORDER BY MonthNo;';

    EXEC sys.sp_executesql @sql, N'@Year INT', @Year = @Year;
END;
GO

PRINT 'SalesDB advanced (hard-mode) objects are ready.';
GO
