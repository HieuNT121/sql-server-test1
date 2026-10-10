const path = require("path");
const express = require("express");
const sql = require("mssql");

const app = express();
const port = Number(process.env.PORT || 3000);

const config = {
  server: process.env.DB_HOST || "localhost",
  port: Number(process.env.DB_PORT || 1433),
  database: process.env.DB_NAME || "SalesDB",
  user: process.env.DB_USER || "sa",
  password: process.env.DB_PASSWORD,
  options: {
    encrypt: false,
    trustServerCertificate: true,
  },
  pool: {
    max: 10,
    min: 0,
    idleTimeoutMillis: 30000,
  },
};

let poolPromise;

function getPool() {
  if (!poolPromise) {
    poolPromise = new sql.ConnectionPool(config).connect().catch((error) => {
      poolPromise = undefined;
      throw error;
    });
  }
  return poolPromise;
}

app.use(express.static(path.join(__dirname, "public")));

app.get("/health", async (_request, response) => {
  try {
    const pool = await getPool();
    await pool.request().query("SELECT 1 AS healthy");
    response.json({ status: "ok" });
  } catch (error) {
    response.status(503).json({ status: "unavailable", message: error.message });
  }
});

app.get("/api/dashboard", async (_request, response) => {
  try {
    const pool = await getPool();
    const [server, metrics, orders, countries, tables] = await Promise.all([
      pool.request().query(`
        SELECT
          CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(50)) AS productVersion,
          CAST(SERVERPROPERTY('ProductLevel') AS NVARCHAR(50)) AS productLevel,
          CAST(SERVERPROPERTY('Edition') AS NVARCHAR(100)) AS edition,
          DB_NAME() AS databaseName
      `),
      pool.request().query(`
        SELECT
          (SELECT COUNT(*) FROM Sales.Customers) AS customers,
          (SELECT COUNT(*) FROM Sales.Employees) AS employees,
          (SELECT COUNT(*) FROM Sales.Products) AS products,
          (SELECT COUNT(*) FROM Sales.Orders) AS orders,
          (SELECT COALESCE(SUM(Sales), 0) FROM Sales.Orders) AS revenue
      `),
      pool.request().query(`
        SELECT TOP (8)
          o.OrderID AS orderId,
          CONVERT(VARCHAR(10), o.OrderDate, 23) AS orderDate,
          CONCAT(c.FirstName, ' ', COALESCE(c.LastName, '')) AS customer,
          p.Product AS product,
          o.OrderStatus AS status,
          o.Quantity AS quantity,
          o.Sales AS sales
        FROM Sales.Orders o
        LEFT JOIN Sales.Customers c ON c.CustomerID = o.CustomerID
        LEFT JOIN Sales.Products p ON p.ProductID = o.ProductID
        ORDER BY o.OrderDate DESC, o.OrderID DESC
      `),
      pool.request().query(`
        SELECT
          COALESCE(c.Country, 'Unknown') AS country,
          SUM(o.Sales) AS sales
        FROM Sales.Orders o
        LEFT JOIN Sales.Customers c ON c.CustomerID = o.CustomerID
        GROUP BY c.Country
        ORDER BY sales DESC
      `),
      pool.request().query(`
        SELECT
          s.name AS [schema],
          t.name AS [name],
          SUM(p.rows) AS [rows]
        FROM sys.tables t
        JOIN sys.schemas s ON s.schema_id = t.schema_id
        JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
        GROUP BY s.name, t.name
        ORDER BY s.name, t.name
      `),
    ]);

    response.json({
      server: server.recordset[0],
      metrics: metrics.recordset[0],
      orders: orders.recordset,
      countries: countries.recordset,
      tables: tables.recordset,
      refreshedAt: new Date().toISOString(),
    });
  } catch (error) {
    console.error("Dashboard query failed:", error);
    response.status(503).json({
      error: "SQL Server is not available",
      message: error.message,
    });
  }
});

app.get("*", (_request, response) => {
  response.sendFile(path.join(__dirname, "public", "index.html"));
});

app.listen(port, "0.0.0.0", () => {
  console.log(`Dashboard listening on port ${port}`);
});

async function shutdown() {
  if (poolPromise) {
    const pool = await poolPromise.catch(() => undefined);
    await pool?.close();
  }
  process.exit(0);
}

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
