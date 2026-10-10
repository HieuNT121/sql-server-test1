USE SalesDB;
GO

IF OBJECT_ID(N'Sales.StoreLocations', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.StoreLocations
    (
        StoreID      INT           NOT NULL CONSTRAINT PK_StoreLocations PRIMARY KEY,
        StoreCode    VARCHAR(20)   NOT NULL CONSTRAINT UQ_StoreLocations_Code UNIQUE,
        StoreName    NVARCHAR(120) NOT NULL,
        City         NVARCHAR(80)  NOT NULL,
        Country      VARCHAR(50)   NOT NULL,
        Region       VARCHAR(30)   NOT NULL,
        IsActive     BIT           NOT NULL CONSTRAINT DF_StoreLocations_IsActive DEFAULT (1)
    );
END;
GO

IF OBJECT_ID(N'Sales.CountryStoreRules', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.CountryStoreRules
    (
        CustomerCountry VARCHAR(50) NOT NULL CONSTRAINT PK_CountryStoreRules PRIMARY KEY,
        StoreID         INT         NOT NULL,
        RulePriority    TINYINT     NOT NULL CONSTRAINT DF_CountryStoreRules_Priority DEFAULT (1),
        CONSTRAINT FK_CountryStoreRules_Store FOREIGN KEY (StoreID) REFERENCES Sales.StoreLocations(StoreID)
    );
END;
GO

IF OBJECT_ID(N'Sales.OrderStoreMapping', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.OrderStoreMapping
    (
        OrderID          INT           NOT NULL CONSTRAINT PK_OrderStoreMapping PRIMARY KEY,
        StoreID          INT           NOT NULL,
        CustomerCountry  VARCHAR(50)   NULL,
        MappingMethod    VARCHAR(30)   NOT NULL,
        MappedAt         DATETIME2(3)  NOT NULL,
        MappedByRunID    BIGINT        NOT NULL,
        CONSTRAINT FK_OrderStoreMapping_Order FOREIGN KEY (OrderID) REFERENCES Sales.Orders(OrderID),
        CONSTRAINT FK_OrderStoreMapping_Store FOREIGN KEY (StoreID) REFERENCES Sales.StoreLocations(StoreID)
    );

    CREATE INDEX IX_OrderStoreMapping_StoreID ON Sales.OrderStoreMapping(StoreID, OrderID);
END;
GO

IF OBJECT_ID(N'Sales.DailyStoreSalesSummary', N'U') IS NULL
BEGIN
    CREATE TABLE Sales.DailyStoreSalesSummary
    (
        SalesDate        DATE           NOT NULL,
        StoreID          INT            NOT NULL,
        CategoryName     NVARCHAR(80)   NOT NULL,
        OrderCount       INT            NOT NULL,
        UnitsSold        INT            NOT NULL,
        NetRevenue       DECIMAL(14, 2) NOT NULL,
        RefreshedAt      DATETIME2(3)   NOT NULL,
        RefreshedByRunID BIGINT         NOT NULL,
        CONSTRAINT PK_DailyStoreSalesSummary PRIMARY KEY (SalesDate, StoreID, CategoryName),
        CONSTRAINT FK_DailyStoreSalesSummary_Store FOREIGN KEY (StoreID) REFERENCES Sales.StoreLocations(StoreID)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM Sales.StoreLocations)
BEGIN
    INSERT Sales.StoreLocations (StoreID, StoreCode, StoreName, City, Country, Region)
    VALUES
      (1, 'US-NYC', N'New York Flagship', N'New York', 'USA', 'North America'),
      (2, 'DE-BER', N'Berlin Central', N'Berlin', 'Germany', 'Europe'),
      (3, 'GB-LON', N'London Riverside', N'London', 'UK', 'Europe'),
      (4, 'FR-PAR', N'Paris République', N'Paris', 'France', 'Europe'),
      (5, 'CA-TOR', N'Toronto Market', N'Toronto', 'Canada', 'North America'),
      (6, 'AU-SYD', N'Sydney Harbour', N'Sydney', 'Australia', 'Asia Pacific'),
      (7, 'IT-MIL', N'Milan Navigli', N'Milan', 'Italy', 'Europe'),
      (8, 'JP-TYO', N'Tokyo Shibuya', N'Tokyo', 'Japan', 'Asia Pacific'),
      (9, 'ES-MAD', N'Madrid Centro', N'Madrid', 'Spain', 'Europe'),
      (10, 'SG-HUB', N'Singapore Regional Hub', N'Singapore', 'Singapore', 'Asia Pacific');
END;
GO

IF NOT EXISTS (SELECT 1 FROM Sales.CountryStoreRules)
BEGIN
    INSERT Sales.CountryStoreRules (CustomerCountry, StoreID)
    VALUES
      ('USA', 1), ('Germany', 2), ('Switzerland', 2), ('Sweden', 2), ('Denmark', 2), ('Poland', 2),
      ('UK', 3), ('Portugal', 3), ('France', 4), ('Canada', 5), ('Australia', 6),
      ('Italy', 7), ('Japan', 8), ('Spain', 9), ('Brazil', 9), ('India', 10), ('UAE', 10);
END;
GO
