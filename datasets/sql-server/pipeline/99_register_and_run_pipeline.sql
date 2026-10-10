USE SalesDB;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF NOT EXISTS (SELECT 1 FROM Pipeline.PipelineDefinitions WHERE PipelineKey = 'sales-analytics')
BEGIN
    INSERT Pipeline.PipelineDefinitions (PipelineKey, PipelineName, Description)
    VALUES ('sales-analytics', N'Daily sales business pipeline',
            N'Maps store locations, aggregates daily sales, and publishes operational metrics.');
END;

UPDATE Pipeline.PipelineDefinitions
SET PipelineName = N'Daily sales business pipeline',
    Description = N'Maps store locations, aggregates daily sales, and publishes operational metrics.'
WHERE PipelineKey = 'sales-analytics';
GO

DECLARE @PipelineDefinitionID INT =
    (SELECT PipelineDefinitionID FROM Pipeline.PipelineDefinitions WHERE PipelineKey = 'sales-analytics');

DECLARE @Steps TABLE
(
    StepKey VARCHAR(80), StepOrder TINYINT, LayerNumber TINYINT, LayerName NVARCHAR(80),
    StepName NVARCHAR(120), ProcedureSchema SYSNAME, ProcedureName SYSNAME
);

INSERT @Steps
VALUES
 ('validate-source',       1, 1, N'Quality gate',          N'Validate sales source',             N'Pipeline', N'usp_ValidateSalesSource'),
 ('store-location',        2, 2, N'Reference extraction',  N'Extract store location mapping',    N'Pipeline', N'usp_ExtractStoreLocationMapping'),
 ('daily-sales',           3, 3, N'Daily operations',      N'Aggregate daily sales',              N'Pipeline', N'usp_RefreshDailySalesSummary'),
 ('daily-store-sales',     4, 3, N'Daily operations',      N'Aggregate daily store sales',        N'Pipeline', N'usp_AggregateDailyStoreSales'),
 ('customer-value',        5, 3, N'Daily operations',      N'Refresh customer value snapshot',   N'Pipeline', N'usp_RefreshCustomerValueSnapshot'),
 ('product-performance',   6, 4, N'Business metrics',      N'Refresh product performance',       N'Pipeline', N'usp_RefreshProductPerformance'),
 ('executive-kpis',        7, 5, N'Publication',           N'Publish executive KPI snapshot',    N'Pipeline', N'usp_RefreshExecutiveKpis');

UPDATE target
SET StepOrder = source.StepOrder,
    LayerNumber = source.LayerNumber,
    LayerName = source.LayerName,
    StepName = source.StepName,
    ProcedureSchema = source.ProcedureSchema,
    ProcedureName = source.ProcedureName,
    IsActive = 1
FROM Pipeline.PipelineStepDefinitions AS target
JOIN @Steps AS source ON source.StepKey = target.StepKey
WHERE target.PipelineDefinitionID = @PipelineDefinitionID;

INSERT Pipeline.PipelineStepDefinitions
    (PipelineDefinitionID, StepKey, StepOrder, LayerNumber, LayerName, StepName,
     ProcedureSchema, ProcedureName, IsActive)
SELECT @PipelineDefinitionID, source.StepKey, source.StepOrder, source.LayerNumber,
       source.LayerName, source.StepName, source.ProcedureSchema, source.ProcedureName, 1
FROM @Steps AS source
WHERE NOT EXISTS
(
    SELECT 1 FROM Pipeline.PipelineStepDefinitions AS target
    WHERE target.PipelineDefinitionID = @PipelineDefinitionID
      AND target.StepKey = source.StepKey
);

UPDATE Pipeline.PipelineStepDefinitions
SET IsActive = 0
WHERE PipelineDefinitionID = @PipelineDefinitionID
  AND StepKey NOT IN (SELECT StepKey FROM @Steps);
GO

DECLARE @PipelineDefinitionID INT =
    (SELECT PipelineDefinitionID FROM Pipeline.PipelineDefinitions WHERE PipelineKey = 'sales-analytics');

DECLARE @Dependencies TABLE (StepKey VARCHAR(80), DependsOnStepKey VARCHAR(80));
INSERT @Dependencies
VALUES
 ('store-location', 'validate-source'),
 ('daily-sales', 'validate-source'),
 ('daily-store-sales', 'store-location'),
 ('customer-value', 'validate-source'),
 ('product-performance', 'daily-sales'),
 ('executive-kpis', 'daily-sales'),
 ('executive-kpis', 'daily-store-sales'),
 ('executive-kpis', 'customer-value'),
 ('executive-kpis', 'product-performance');

DELETE dependency
FROM Pipeline.PipelineStepDependencies AS dependency
JOIN Pipeline.PipelineStepDefinitions AS step ON step.StepDefinitionID = dependency.StepDefinitionID
WHERE step.PipelineDefinitionID = @PipelineDefinitionID;

INSERT Pipeline.PipelineStepDependencies (StepDefinitionID, DependsOnStepDefinitionID)
SELECT step.StepDefinitionID, required.StepDefinitionID
FROM @Dependencies AS dependency
JOIN Pipeline.PipelineStepDefinitions AS step
  ON step.PipelineDefinitionID = @PipelineDefinitionID AND step.StepKey = dependency.StepKey
JOIN Pipeline.PipelineStepDefinitions AS required
  ON required.PipelineDefinitionID = @PipelineDefinitionID AND required.StepKey = dependency.DependsOnStepKey;
GO

DECLARE @PipelineDefinitionID INT =
    (SELECT PipelineDefinitionID FROM Pipeline.PipelineDefinitions WHERE PipelineKey = 'sales-analytics');
DECLARE @InitialRunID BIGINT;

IF NOT EXISTS
(
    SELECT 1
    FROM Pipeline.PipelineRuns AS run
    WHERE run.PipelineDefinitionID = @PipelineDefinitionID
      AND run.Status = 'Succeeded'
      AND (SELECT COUNT(*) FROM Pipeline.PipelineStepRuns AS step WHERE step.RunID = run.RunID) = 7
)
    EXEC Pipeline.usp_RunSalesAnalyticsPipeline
        @TriggeredBy = N'Docker layered pipeline initialization',
        @RunID = @InitialRunID OUTPUT;
GO

PRINT 'Layered sales analytics pipeline is ready.';
GO
