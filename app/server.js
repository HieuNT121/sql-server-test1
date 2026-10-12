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
app.use(express.json());

app.get("/health", async (_request, response) => {
  try {
    const pool = await getPool();
    await pool.request().query("SELECT 1 AS healthy");
    response.json({ status: "ok" });
  } catch (error) {
    response.status(503).json({ status: "unavailable", message: error.message });
  }
});

app.get("/api/dashboard", async (request, response) => {
  try {
    const pool = await getPool();
    const pipelineDefinitions = await pool.request().query(`
      SELECT
        PipelineKey AS pipelineKey,
        PipelineName AS pipelineName,
        Description AS description
      FROM Pipeline.PipelineDefinitions
      WHERE IsActive = 1
      ORDER BY CASE PipelineKey WHEN 'sales-analytics' THEN 0 ELSE 1 END, PipelineName
    `);

    const requestedPipelineKey = String(request.query.pipelineKey || "sales-analytics");
    const selectedPipeline = pipelineDefinitions.recordset.find(
      (pipeline) => pipeline.pipelineKey === requestedPipelineKey,
    );

    if (!selectedPipeline) {
      response.status(404).json({ error: "Pipeline not found" });
      return;
    }

    const pipelineKey = selectedPipeline.pipelineKey;
    const [
      server,
      metrics,
      orders,
      countries,
      tables,
      pipelineRun,
      pipelineSteps,
      pipelineStructure,
      pipelineDependencies,
      qualityResults,
      conversionChallenges,
    ] = await Promise.all([
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
          (SELECT COUNT(*) FROM Sales.ProductCatalog) AS products,
          (SELECT COUNT(*) FROM Sales.Orders) AS orders,
          (SELECT COALESCE(SUM(Sales), 0) FROM Sales.Orders) AS revenue
      `),
      pool.request().query(`
        SELECT TOP (8)
          o.OrderID AS orderId,
          CONVERT(VARCHAR(10), o.OrderDate, 23) AS orderDate,
          CONCAT(c.FirstName, ' ', COALESCE(c.LastName, '')) AS customer,
          COALESCE(pc.ProductName, p.Product) AS product,
          o.OrderStatus AS status,
          o.Quantity AS quantity,
          o.Sales AS sales
        FROM Sales.Orders o
        LEFT JOIN Sales.Customers c ON c.CustomerID = o.CustomerID
        LEFT JOIN Sales.Products p ON p.ProductID = o.ProductID
        LEFT JOIN Sales.ProductCatalog pc ON pc.ProductID = o.ProductID
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
      pool.request().input("pipelineKey", sql.VarChar(80), pipelineKey).query(`
        SELECT TOP (1)
          run.RunID AS runId,
          run.PipelineName AS pipelineName,
          run.Status AS status,
          run.TriggeredBy AS triggeredBy,
          run.StartedAt AS startedAt,
          run.CompletedAt AS completedAt,
          run.DurationMs AS durationMs,
          run.RowsProcessed AS rowsProcessed,
          run.ErrorMessage AS errorMessage
        FROM Pipeline.PipelineRuns AS run
        JOIN Pipeline.PipelineDefinitions AS pipeline
          ON pipeline.PipelineDefinitionID = run.PipelineDefinitionID
        WHERE pipeline.PipelineKey = @pipelineKey
        ORDER BY run.RunID DESC
      `),
      pool.request().input("pipelineKey", sql.VarChar(80), pipelineKey).query(`
        SELECT
          run.StepRunID AS stepRunId,
          run.StepDefinitionID AS stepDefinitionId,
          run.StepOrder AS stepOrder,
          definition.StepKey AS stepKey,
          definition.LayerNumber AS layerNumber,
          definition.LayerName AS layerName,
          run.StepName AS stepName,
          run.ProcedureName AS procedureName,
          run.Status AS status,
          run.StartedAt AS startedAt,
          run.CompletedAt AS completedAt,
          run.DurationMs AS durationMs,
          run.RowsProcessed AS rowsProcessed,
          run.ErrorMessage AS errorMessage
        FROM Pipeline.PipelineStepRuns AS run
        LEFT JOIN Pipeline.PipelineStepDefinitions AS definition
          ON definition.StepDefinitionID = run.StepDefinitionID
        JOIN Pipeline.PipelineDefinitions AS pipeline
          ON pipeline.PipelineDefinitionID = definition.PipelineDefinitionID
        WHERE run.RunID =
        (
          SELECT TOP (1) latest.RunID
          FROM Pipeline.PipelineRuns AS latest
          WHERE latest.PipelineDefinitionID = pipeline.PipelineDefinitionID
          ORDER BY latest.RunID DESC
        )
          AND pipeline.PipelineKey = @pipelineKey
        ORDER BY run.StepOrder
      `),
      pool.request().input("pipelineKey", sql.VarChar(80), pipelineKey).query(`
        SELECT
          step.StepDefinitionID AS stepDefinitionId,
          step.StepKey AS stepKey,
          step.StepOrder AS stepOrder,
          step.LayerNumber AS layerNumber,
          step.LayerName AS layerName,
          step.StepName AS stepName,
          CONCAT(step.ProcedureSchema, '.', step.ProcedureName) AS procedureName
        FROM Pipeline.PipelineStepDefinitions AS step
        JOIN Pipeline.PipelineDefinitions AS pipeline
          ON pipeline.PipelineDefinitionID = step.PipelineDefinitionID
        WHERE pipeline.PipelineKey = @pipelineKey AND step.IsActive = 1
        ORDER BY step.LayerNumber, step.StepOrder
      `),
      pool.request().input("pipelineKey", sql.VarChar(80), pipelineKey).query(`
        SELECT
          step.StepKey AS stepKey,
          required.StepKey AS dependsOnStepKey
        FROM Pipeline.PipelineStepDependencies AS dependency
        JOIN Pipeline.PipelineStepDefinitions AS step
          ON step.StepDefinitionID = dependency.StepDefinitionID
        JOIN Pipeline.PipelineStepDefinitions AS required
          ON required.StepDefinitionID = dependency.DependsOnStepDefinitionID
        JOIN Pipeline.PipelineDefinitions AS pipeline
          ON pipeline.PipelineDefinitionID = step.PipelineDefinitionID
        WHERE pipeline.PipelineKey = @pipelineKey
        ORDER BY step.StepOrder, required.StepOrder
      `),
      pool.request().input("pipelineKey", sql.VarChar(80), pipelineKey).query(`
        SELECT
          CheckName AS checkName,
          Severity AS severity,
          Status AS status,
          IssueCount AS issueCount,
          Detail AS detail
        FROM Pipeline.DataQualityResults
        WHERE RunID =
        (
          SELECT TOP (1) run.RunID
          FROM Pipeline.PipelineRuns AS run
          JOIN Pipeline.PipelineDefinitions AS pipeline
            ON pipeline.PipelineDefinitionID = run.PipelineDefinitionID
          WHERE pipeline.PipelineKey = @pipelineKey
          ORDER BY run.RunID DESC
        )
        ORDER BY CASE Severity WHEN 'Critical' THEN 1 ELSE 2 END, QualityResultID
      `),
      pool.request().input("pipelineKey", sql.VarChar(80), pipelineKey).query(`
        SELECT
          result.ChallengeKey AS challengeKey,
          definition.ChallengeOrder AS challengeOrder,
          definition.ComplexityLevel AS complexityLevel,
          definition.ChallengeName AS challengeName,
          result.Status AS status,
          result.SourceRowCount AS sourceRowCount,
          result.Detail AS detail
        FROM Pipeline.ConversionChallengeResults AS result
        JOIN Pipeline.ConversionChallengeDefinitions AS definition
          ON definition.ChallengeKey = result.ChallengeKey
        WHERE result.RunID =
        (
          SELECT TOP (1) run.RunID
          FROM Pipeline.PipelineRuns AS run
          JOIN Pipeline.PipelineDefinitions AS pipeline
            ON pipeline.PipelineDefinitionID = run.PipelineDefinitionID
          WHERE pipeline.PipelineKey = @pipelineKey
          ORDER BY run.RunID DESC
        )
        ORDER BY definition.ChallengeOrder
      `),
    ]);

    response.json({
      server: server.recordset[0],
      metrics: metrics.recordset[0],
      orders: orders.recordset,
      countries: countries.recordset,
      tables: tables.recordset,
      pipelines: pipelineDefinitions.recordset,
      pipeline: {
        key: pipelineKey,
        name: selectedPipeline.pipelineName,
        description: selectedPipeline.description,
        run: pipelineRun.recordset[0] || null,
        steps: pipelineSteps.recordset,
        structure: pipelineStructure.recordset,
        dependencies: pipelineDependencies.recordset,
        quality: qualityResults.recordset,
        conversionChallenges: conversionChallenges.recordset,
      },
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

app.post("/api/pipeline/run", async (request, response) => {
  try {
    const pool = await getPool();
    const pipelineKey = String(request.body?.pipelineKey || "sales-analytics");
    const runnerByPipelineKey = {
      "sales-analytics": "Pipeline.usp_RunSalesAnalyticsPipeline",
      "conversion-validation": "Pipeline.usp_RunConversionValidationPipeline",
    };
    const procedureName = runnerByPipelineKey[pipelineKey];

    if (!procedureName) {
      response.status(404).json({ error: "Pipeline not found" });
      return;
    }

    const result = await pool
      .request()
      .input("triggeredBy", sql.NVarChar(100), "Dashboard")
      .output("runId", sql.BigInt)
      .execute(procedureName);

    response.status(201).json({
      pipelineKey,
      runId: result.output.runId,
      run: result.recordset[0],
    });
  } catch (error) {
    console.error("Pipeline run failed:", error);
    response.status(500).json({
      error: "Pipeline execution failed",
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
