/*
    Enriches the SalesDB course database with a realistic, repeatable dataset.
    This script never drops or truncates existing course tables.
*/
USE SalesDB;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID(N'Sales.Categories', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.Categories
    (
        CategoryID   INT           NOT NULL CONSTRAINT PK_Categories PRIMARY KEY,
        CategoryName NVARCHAR(80)  NOT NULL CONSTRAINT UQ_Categories_Name UNIQUE,
        Department   NVARCHAR(80)  NOT NULL
    );
END;
GO

IF OBJECT_ID(N'Sales.ProductCatalog', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.ProductCatalog
    (
        ProductID       INT             NOT NULL CONSTRAINT PK_ProductCatalog PRIMARY KEY,
        SKU             VARCHAR(20)     NOT NULL CONSTRAINT UQ_ProductCatalog_SKU UNIQUE,
        ProductName     NVARCHAR(120)   NOT NULL,
        CategoryID      INT             NOT NULL,
        UnitCost        DECIMAL(10, 2)  NOT NULL,
        ListPrice       DECIMAL(10, 2)  NOT NULL,
        LaunchDate      DATE            NOT NULL,
        IsActive        BIT             NOT NULL CONSTRAINT DF_ProductCatalog_IsActive DEFAULT (1),
        CONSTRAINT FK_ProductCatalog_Categories FOREIGN KEY (CategoryID) REFERENCES Sales.Categories(CategoryID),
        CONSTRAINT CK_ProductCatalog_Cost CHECK (UnitCost >= 0),
        CONSTRAINT CK_ProductCatalog_Price CHECK (ListPrice >= UnitCost)
    );
END;
GO

IF OBJECT_ID(N'Sales.CustomerProfiles', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.CustomerProfiles
    (
        CustomerID       INT            NOT NULL CONSTRAINT PK_CustomerProfiles PRIMARY KEY,
        Email            VARCHAR(160)   NOT NULL CONSTRAINT UQ_CustomerProfiles_Email UNIQUE,
        Segment          VARCHAR(20)    NOT NULL,
        SignupDate       DATE           NOT NULL,
        MarketingOptIn   BIT            NOT NULL,
        CONSTRAINT FK_CustomerProfiles_Customers FOREIGN KEY (CustomerID) REFERENCES Sales.Customers(CustomerID),
        CONSTRAINT CK_CustomerProfiles_Segment CHECK (Segment IN ('Consumer', 'Small Business', 'Enterprise'))
    );
END;
GO

IF OBJECT_ID(N'Sales.OrderLines', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.OrderLines
    (
        OrderLineID   BIGINT          IDENTITY(1, 1) NOT NULL CONSTRAINT PK_OrderLines PRIMARY KEY,
        OrderID       INT             NOT NULL,
        ProductID     INT             NOT NULL,
        Quantity      SMALLINT        NOT NULL,
        UnitPrice     DECIMAL(10, 2)  NOT NULL,
        DiscountPct   DECIMAL(5, 4)   NOT NULL CONSTRAINT DF_OrderLines_Discount DEFAULT (0),
        CONSTRAINT FK_OrderLines_Orders FOREIGN KEY (OrderID) REFERENCES Sales.Orders(OrderID),
        CONSTRAINT FK_OrderLines_Products FOREIGN KEY (ProductID) REFERENCES Sales.ProductCatalog(ProductID),
        CONSTRAINT UQ_OrderLines_Order_Product UNIQUE (OrderID, ProductID),
        CONSTRAINT CK_OrderLines_Quantity CHECK (Quantity > 0),
        CONSTRAINT CK_OrderLines_UnitPrice CHECK (UnitPrice >= 0),
        CONSTRAINT CK_OrderLines_Discount CHECK (DiscountPct >= 0 AND DiscountPct < 1)
    );
END;
GO

IF OBJECT_ID(N'Sales.Payments', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.Payments
    (
        PaymentID      BIGINT          IDENTITY(1, 1) NOT NULL CONSTRAINT PK_Payments PRIMARY KEY,
        OrderID        INT             NOT NULL,
        PaymentDate    DATETIME2(0)    NOT NULL,
        PaymentMethod  VARCHAR(30)     NOT NULL,
        PaymentStatus  VARCHAR(20)     NOT NULL,
        Amount         DECIMAL(12, 2)  NOT NULL,
        TransactionRef VARCHAR(40)     NOT NULL CONSTRAINT UQ_Payments_Ref UNIQUE,
        CONSTRAINT FK_Payments_Orders FOREIGN KEY (OrderID) REFERENCES Sales.Orders(OrderID),
        CONSTRAINT CK_Payments_Amount CHECK (Amount >= 0),
        CONSTRAINT CK_Payments_Status CHECK (PaymentStatus IN ('Captured', 'Pending', 'Refunded', 'Failed'))
    );
END;
GO

IF OBJECT_ID(N'Sales.Returns', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.Returns
    (
        ReturnID       INT             NOT NULL CONSTRAINT PK_Returns PRIMARY KEY,
        OrderID        INT             NOT NULL,
        ProductID      INT             NOT NULL,
        ReturnDate     DATE            NOT NULL,
        Quantity       SMALLINT        NOT NULL,
        ReturnReason   VARCHAR(40)     NOT NULL,
        RefundAmount   DECIMAL(10, 2)  NOT NULL,
        CONSTRAINT FK_Returns_Orders FOREIGN KEY (OrderID) REFERENCES Sales.Orders(OrderID),
        CONSTRAINT FK_Returns_Products FOREIGN KEY (ProductID) REFERENCES Sales.ProductCatalog(ProductID),
        CONSTRAINT CK_Returns_Quantity CHECK (Quantity > 0),
        CONSTRAINT CK_Returns_Refund CHECK (RefundAmount >= 0)
    );
END;
GO

IF OBJECT_ID(N'Sales.InventorySnapshots', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.InventorySnapshots
    (
        SnapshotDate DATE      NOT NULL,
        ProductID    INT       NOT NULL,
        Warehouse    VARCHAR(30) NOT NULL,
        OnHand       INT       NOT NULL,
        ReorderPoint INT       NOT NULL,
        CONSTRAINT PK_InventorySnapshots PRIMARY KEY (SnapshotDate, ProductID, Warehouse),
        CONSTRAINT FK_InventorySnapshots_Products FOREIGN KEY (ProductID) REFERENCES Sales.ProductCatalog(ProductID),
        CONSTRAINT CK_Inventory_OnHand CHECK (OnHand >= 0),
        CONSTRAINT CK_Inventory_Reorder CHECK (ReorderPoint >= 0)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM Sales.Categories)
BEGIN
    INSERT Sales.Categories (CategoryID, CategoryName, Department)
    VALUES (1, N'Accessories', N'Cycling'), (2, N'Clothing', N'Apparel'),
           (3, N'Components', N'Cycling'), (4, N'Outdoor', N'Camping'),
           (5, N'Electronics', N'Technology');
END;
GO

IF NOT EXISTS (SELECT 1 FROM Sales.ProductCatalog)
BEGIN
    INSERT Sales.ProductCatalog (ProductID, SKU, ProductName, CategoryID, UnitCost, ListPrice, LaunchDate)
    VALUES
      (101, 'ACC-BOT-01', N'Trail Bottle', 1, 3.50, 10.00, '2022-02-01'),
      (102, 'ACC-TIR-01', N'All-Terrain Tire', 1, 7.25, 15.00, '2022-03-15'),
      (103, 'APP-SOC-01', N'Merino Socks', 2, 8.00, 20.00, '2022-01-12'),
      (104, 'APP-CAP-01', N'Performance Cap', 2, 9.50, 25.00, '2022-04-20'),
      (105, 'APP-GLV-01', N'Riding Gloves', 2, 12.00, 30.00, '2022-05-08'),
      (106, 'CMP-LGT-01', N'Alloy Handlebar', 3, 22.00, 49.99, '2022-06-01'),
      (107, 'CMP-PMP-01', N'Mini Floor Pump', 3, 18.50, 39.99, '2022-07-15'),
      (108, 'OUT-TNT-01', N'Solo Trail Tent', 4, 78.00, 149.00, '2023-02-01'),
      (109, 'OUT-BAG-01', N'Daypack 22L', 4, 34.00, 79.00, '2023-03-12'),
      (110, 'ELC-LMP-01', N'USB Safety Light', 5, 11.00, 29.00, '2023-04-05'),
      (111, 'ELC-GPS-01', N'Cycle GPS Mini', 5, 95.00, 179.00, '2023-06-10'),
      (112, 'ACC-TOOL-1', N'Multi-tool 12-in-1', 1, 14.00, 34.00, '2023-08-19');
END;
GO

IF NOT EXISTS (SELECT 1 FROM Sales.Customers WHERE CustomerID = 6)
BEGIN
    INSERT Sales.Customers (CustomerID, FirstName, LastName, Country, Score)
    VALUES
      (6, 'Lena', 'Fischer', 'Germany', 810), (7, 'Oliver', 'Smith', 'UK', 670),
      (8, 'Ava', 'Johnson', 'USA', 920), (9, 'Noah', 'Martin', 'France', 580),
      (10, 'Sofia', 'Rossi', 'Italy', 760), (11, 'Liam', 'Wilson', 'Canada', 640),
      (12, 'Emma', 'Chen', 'Australia', 880), (13, 'Mateo', 'Garcia', 'Spain', 720),
      (14, 'Mila', 'Novak', 'Germany', 490), (15, 'Ethan', 'Brown', 'USA', 350),
      (16, 'Isla', 'Taylor', 'UK', 810), (17, 'Lucas', 'Dubois', 'France', 700),
      (18, 'Amara', 'Okafor', 'Canada', 560), (19, 'Aria', 'Bianchi', 'Italy', 940),
      (20, 'Kai', 'Miller', 'Australia', 610), (21, 'Nora', 'Andersson', 'Sweden', 830),
      (22, 'Hugo', 'Silva', 'Portugal', 450), (23, 'Yuna', 'Kim', 'Japan', 890),
      (24, 'Theo', 'Laurent', 'France', 770), (25, 'Zara', 'Khan', 'UK', 690),
      (26, 'Leo', 'Schmidt', 'Germany', 930), (27, 'Maya', 'Patel', 'USA', 520),
      (28, 'Felix', 'Meyer', 'Switzerland', 860), (29, 'Chloe', 'Martin', 'Canada', 740),
      (30, 'Daniel', 'Costa', 'Brazil', 600), (31, 'Freya', 'Johansson', 'Sweden', 910),
      (32, 'Adam', 'Nowak', 'Poland', 480), (33, 'Grace', 'Lee', 'Australia', 790),
      (34, 'Ravi', 'Sharma', 'India', 680), (35, 'Elena', 'Popov', 'Spain', 850),
      (36, 'Oscar', 'Nielsen', 'Denmark', 730), (37, 'Mina', 'Sato', 'Japan', 955),
      (38, 'Jack', 'Evans', 'UK', 430), (39, 'Layla', 'Haddad', 'UAE', 820),
      (40, 'Ben', 'Carter', 'USA', 570);
END;
GO

IF NOT EXISTS (SELECT 1 FROM Sales.CustomerProfiles)
BEGIN
    INSERT Sales.CustomerProfiles (CustomerID, Email, Segment, SignupDate, MarketingOptIn)
    SELECT CustomerID,
           CONCAT('customer', CustomerID, '@example.test'),
           CASE WHEN CustomerID % 10 = 0 THEN 'Enterprise'
                WHEN CustomerID % 3 = 0 THEN 'Small Business' ELSE 'Consumer' END,
           DATEADD(DAY, -((CustomerID * 37) % 1300), CONVERT(DATE, '2026-09-30')),
           CONVERT(BIT, CASE WHEN CustomerID % 4 = 0 THEN 0 ELSE 1 END)
    FROM Sales.Customers;
END;
GO

IF NOT EXISTS (SELECT 1 FROM Sales.Employees WHERE EmployeeID BETWEEN 6 AND 12)
BEGIN
    INSERT Sales.Employees (EmployeeID, FirstName, LastName, Department, BirthDate, Gender, Salary, ManagerID)
    VALUES
      (6, 'Priya', 'Shah', 'Sales', '1990-08-14', 'F', 68000, 3),
      (7, 'Daniel', 'Morris', 'Sales', '1985-03-22', 'M', 72000, 3),
      (8, 'Sofia', 'Klein', 'Operations', '1992-11-09', 'F', 64000, 2),
      (9, 'Ethan', 'Park', 'Operations', '1989-05-17', 'M', 61000, 8),
      (10, 'Nina', 'Patel', 'Marketing', '1991-07-30', 'F', 70000, 2),
      (11, 'Marco', 'Rossi', 'Support', '1987-01-18', 'M', 59000, 8),
      (12, 'Olivia', 'Green', 'Support', '1994-04-06', 'F', 57000, 11);
END;
GO

IF NOT EXISTS (SELECT 1 FROM Sales.Orders WHERE OrderID >= 1001)
BEGIN
    ;WITH N AS
    (
        SELECT TOP (240) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
        FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b
    ),
    OrderSeed AS
    (
        SELECT n,
               DATEADD(DAY, (n * 17) % 1000, CONVERT(DATE, '2024-01-01')) AS OrderDate,
               1 + ((n * 13) % 40) AS CustomerID,
               1 + ((n * 3) % 7) AS SalesPersonID,
               CASE WHEN n % 20 = 0 THEN 'Cancelled'
                    WHEN n % 5 = 0 THEN 'Shipped' ELSE 'Delivered' END AS OrderStatus,
               101 + (n % 12) AS ProductID,
               1 + ((n * 11) % 4) AS Quantity
        FROM N
    ),
    OrderFacts AS
    (
        SELECT s.*,
               pc.ListPrice,
               CONVERT(DECIMAL(5,4), CASE WHEN n % 9 = 0 THEN 0.1500
                                          WHEN n % 4 = 0 THEN 0.0500 ELSE 0 END) AS DiscountPct
        FROM OrderSeed AS s
        JOIN Sales.ProductCatalog AS pc ON pc.ProductID = s.ProductID
    )
    INSERT Sales.Orders
        (OrderID, ProductID, CustomerID, SalesPersonID, OrderDate, ShipDate,
         OrderStatus, ShipAddress, BillAddress, Quantity, Sales, CreationTime)
    SELECT 1000 + n,
           ProductID,
           CustomerID,
           SalesPersonID,
           OrderDate,
           CASE WHEN OrderStatus = 'Cancelled' THEN NULL ELSE DATEADD(DAY, 1 + (n % 8), OrderDate) END,
           OrderStatus,
           CONCAT(100 + n, ' Market Street'),
           CASE WHEN n % 7 = 0 THEN NULL ELSE CONCAT(50 + n, ' Commerce Avenue') END,
           Quantity,
           CONVERT(INT, ROUND(ListPrice * Quantity * (1 - DiscountPct), 0)),
           DATEADD(MINUTE, (n * 37) % 1440, CONVERT(DATETIME2, OrderDate))
    FROM OrderFacts;
END;
GO

-- Keep the generated training range deterministic when upgrading an existing volume.
UPDATE Sales.Orders
SET CustomerID = 1 + (((OrderID - 1000) * 13) % 40),
    SalesPersonID = 1 + (((OrderID - 1000) * 3) % 7),
    OrderDate = DATEADD(DAY, (((OrderID - 1000) * 17) % 1000), CONVERT(DATE, '2024-01-01')),
    ShipDate = CASE WHEN OrderStatus = 'Cancelled' THEN NULL
                    ELSE DATEADD(DAY, 1 + ((OrderID - 1000) % 8),
                                 DATEADD(DAY, (((OrderID - 1000) * 17) % 1000), CONVERT(DATE, '2024-01-01'))) END,
    CreationTime = DATEADD(MINUTE, (((OrderID - 1000) * 37) % 1440),
                           CONVERT(DATETIME2, DATEADD(DAY, (((OrderID - 1000) * 17) % 1000), CONVERT(DATE, '2024-01-01'))))
WHERE OrderID BETWEEN 1001 AND 1240;
GO

IF NOT EXISTS (SELECT 1 FROM Sales.OrderLines)
BEGIN
    INSERT Sales.OrderLines (OrderID, ProductID, Quantity, UnitPrice, DiscountPct)
    SELECT o.OrderID,
           pc.ProductID,
           CONVERT(SMALLINT, CASE WHEN o.Quantity < 1 THEN 1 ELSE o.Quantity END),
           pc.ListPrice,
           CONVERT(DECIMAL(5,4), CASE WHEN o.OrderID % 9 = 0 THEN 0.1500
                                      WHEN o.OrderID % 4 = 0 THEN 0.0500 ELSE 0 END)
    FROM Sales.Orders AS o
    JOIN Sales.ProductCatalog AS pc ON pc.ProductID = o.ProductID
    WHERE o.OrderID >= 1001;

    INSERT Sales.OrderLines (OrderID, ProductID, Quantity, UnitPrice, DiscountPct)
    SELECT o.OrderID,
           pc.ProductID,
           CONVERT(SMALLINT, 1 + (o.OrderID % 2)),
           pc.ListPrice,
           CONVERT(DECIMAL(5,4), CASE WHEN o.OrderID % 6 = 0 THEN 0.1000 ELSE 0 END)
    FROM Sales.Orders AS o
    JOIN Sales.ProductCatalog AS pc ON pc.ProductID = 105 + (o.OrderID % 8)
    WHERE o.OrderID >= 1001
      AND o.OrderID % 3 = 0
      AND NOT EXISTS
      (
          SELECT 1
          FROM Sales.OrderLines AS existing
          WHERE existing.OrderID = o.OrderID
            AND existing.ProductID = pc.ProductID
      );
END;
GO

IF NOT EXISTS (SELECT 1 FROM Sales.Payments)
BEGIN
    INSERT Sales.Payments (OrderID, PaymentDate, PaymentMethod, PaymentStatus, Amount, TransactionRef)
    SELECT o.OrderID,
           DATEADD(HOUR, 2 + (o.OrderID % 36), CONVERT(DATETIME2, o.OrderDate)),
           CASE o.OrderID % 4 WHEN 0 THEN 'Card' WHEN 1 THEN 'PayPal'
                              WHEN 2 THEN 'Bank Transfer' ELSE 'Wallet' END,
           CASE WHEN o.OrderStatus = 'Cancelled' THEN 'Refunded'
                WHEN o.OrderID % 17 = 0 THEN 'Pending' ELSE 'Captured' END,
           CONVERT(DECIMAL(12,2), o.Sales),
           CONCAT('TX-', FORMAT(o.OrderID, '000000'))
    FROM Sales.Orders AS o
    WHERE o.OrderID >= 1001;
END;
GO

UPDATE p
SET PaymentDate = DATEADD(HOUR, 2 + (o.OrderID % 36), CONVERT(DATETIME2, o.OrderDate))
FROM Sales.Payments AS p
JOIN Sales.Orders AS o ON o.OrderID = p.OrderID
WHERE o.OrderID BETWEEN 1001 AND 1240;
GO

IF NOT EXISTS (SELECT 1 FROM Sales.Returns)
BEGIN
    INSERT Sales.Returns (ReturnID, OrderID, ProductID, ReturnDate, Quantity, ReturnReason, RefundAmount)
    SELECT 1 + (o.OrderID - 1001), o.OrderID, o.ProductID,
           DATEADD(DAY, 8 + (o.OrderID % 20), o.OrderDate), 1,
           CASE o.OrderID % 4 WHEN 0 THEN 'Damaged' WHEN 1 THEN 'Wrong size'
                              WHEN 2 THEN 'Changed mind' ELSE 'Not as described' END,
           CONVERT(DECIMAL(10,2), pc.ListPrice)
    FROM Sales.Orders AS o
    JOIN Sales.ProductCatalog AS pc ON pc.ProductID = o.ProductID
    WHERE o.OrderID >= 1001 AND o.OrderID % 19 = 0;
END;
GO

UPDATE r
SET ReturnDate = DATEADD(DAY, 8 + (o.OrderID % 20), o.OrderDate)
FROM Sales.Returns AS r
JOIN Sales.Orders AS o ON o.OrderID = r.OrderID
WHERE o.OrderID BETWEEN 1001 AND 1240;
GO

IF NOT EXISTS (SELECT 1 FROM Sales.InventorySnapshots)
BEGIN
    ;WITH SnapshotDates AS
    (
        SELECT CONVERT(DATE, '2026-06-30') AS SnapshotDate
        UNION ALL SELECT '2026-07-31'
        UNION ALL SELECT '2026-08-31'
        UNION ALL SELECT '2026-09-30'
    ),
    Warehouses AS
    (
        SELECT 'US-EAST' AS Warehouse
        UNION ALL SELECT 'EU-CENTRAL'
        UNION ALL SELECT 'APAC'
    )
    INSERT Sales.InventorySnapshots (SnapshotDate, ProductID, Warehouse, OnHand, ReorderPoint)
    SELECT d.SnapshotDate, p.ProductID, w.Warehouse,
           8 + ((p.ProductID * 7 + MONTH(d.SnapshotDate) * 11 + LEN(w.Warehouse)) % 95),
           12 + (p.ProductID % 12)
    FROM SnapshotDates AS d
    CROSS JOIN Sales.ProductCatalog AS p
    CROSS JOIN Warehouses AS w;
END;
GO

IF NOT EXISTS (SELECT 1 FROM Sales.OrdersArchive WHERE OrderID >= 1001)
BEGIN
    INSERT Sales.OrdersArchive
        (OrderID, ProductID, CustomerID, SalesPersonID, OrderDate, ShipDate,
         OrderStatus, ShipAddress, BillAddress, Quantity, Sales, CreationTime)
    SELECT o.OrderID, o.ProductID, o.CustomerID, o.SalesPersonID,
           DATEADD(YEAR, -1, o.OrderDate), DATEADD(YEAR, -1, o.ShipDate),
           'Delivered', o.ShipAddress, o.BillAddress, o.Quantity, o.Sales,
           DATEADD(YEAR, -1, o.CreationTime)
    FROM Sales.Orders AS o
    WHERE o.OrderID BETWEEN 1001 AND 1060;
END;
GO

UPDATE a
SET OrderDate = DATEADD(YEAR, -1, o.OrderDate),
    ShipDate = DATEADD(YEAR, -1, o.ShipDate),
    CreationTime = DATEADD(YEAR, -1, o.CreationTime)
FROM Sales.OrdersArchive AS a
JOIN Sales.Orders AS o ON o.OrderID = a.OrderID
WHERE a.OrderID BETWEEN 1001 AND 1060;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Sales.Orders') AND name = N'IX_Orders_OrderDate_Status')
    CREATE INDEX IX_Orders_OrderDate_Status ON Sales.Orders(OrderDate, OrderStatus) INCLUDE (CustomerID, ProductID, Sales, Quantity);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Sales.Orders') AND name = N'IX_Orders_Customer_Date')
    CREATE INDEX IX_Orders_Customer_Date ON Sales.Orders(CustomerID, OrderDate DESC) INCLUDE (Sales, OrderStatus);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Sales.OrderLines') AND name = N'IX_OrderLines_Product')
    CREATE INDEX IX_OrderLines_Product ON Sales.OrderLines(ProductID, OrderID) INCLUDE (Quantity, UnitPrice, DiscountPct);
GO

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

PRINT 'SalesDB enrichment is complete.';
GO
