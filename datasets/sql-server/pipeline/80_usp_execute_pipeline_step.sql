USE SalesDB;
GO

CREATE OR ALTER PROCEDURE Pipeline.usp_ExecutePipelineStep
    @RunID BIGINT,
    @StepDefinitionID INT,
    @RowsProcessed INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @StepRunID BIGINT;
    DECLARE @StepKey VARCHAR(80);
    DECLARE @StepOrder TINYINT;
    DECLARE @StepName NVARCHAR(120);
    DECLARE @ProcedureSchema SYSNAME;
    DECLARE @ProcedureName SYSNAME;
    DECLARE @QualifiedProcedure NVARCHAR(517);

    SELECT @StepKey = StepKey,
           @StepOrder = StepOrder,
           @StepName = StepName,
           @ProcedureSchema = ProcedureSchema,
           @ProcedureName = ProcedureName
    FROM Pipeline.PipelineStepDefinitions
    WHERE StepDefinitionID = @StepDefinitionID AND IsActive = 1;

    IF @StepOrder IS NULL
        THROW 51010, 'The requested pipeline step is missing or inactive.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM Pipeline.PipelineStepDependencies AS dependency
        LEFT JOIN Pipeline.PipelineStepRuns AS completed
          ON completed.RunID = @RunID
         AND completed.StepDefinitionID = dependency.DependsOnStepDefinitionID
         AND completed.Status = 'Succeeded'
        WHERE dependency.StepDefinitionID = @StepDefinitionID
          AND completed.StepRunID IS NULL
    )
        THROW 51011, 'A pipeline step dependency has not completed successfully.', 1;

    SET @QualifiedProcedure = QUOTENAME(@ProcedureSchema) + N'.' + QUOTENAME(@ProcedureName);
    SET @RowsProcessed = 0;

    BEGIN TRY
        INSERT Pipeline.PipelineStepRuns
            (RunID, StepDefinitionID, StepOrder, StepName, ProcedureName, Status, StartedAt)
        VALUES
            (@RunID, @StepDefinitionID, @StepOrder, @StepName, @QualifiedProcedure, 'Running', SYSUTCDATETIME());

        SET @StepRunID = SCOPE_IDENTITY();

        /*
            Explicit calls to already-existing procedures. The pipeline does not
            create these procedures; their definitions live in separate files.
        */
        IF @StepKey = 'validate-source'
            EXEC Pipeline.usp_ValidateSalesSource
                @RunID = @RunID, @RowsProcessed = @RowsProcessed OUTPUT;
        ELSE IF @StepKey = 'store-location'
            EXEC Pipeline.usp_ExtractStoreLocationMapping
                @RunID = @RunID, @RowsProcessed = @RowsProcessed OUTPUT;
        ELSE IF @StepKey = 'daily-sales'
            EXEC Pipeline.usp_RefreshDailySalesSummary
                @RunID = @RunID, @RowsProcessed = @RowsProcessed OUTPUT;
        ELSE IF @StepKey = 'daily-store-sales'
            EXEC Pipeline.usp_AggregateDailyStoreSales
                @RunID = @RunID, @RowsProcessed = @RowsProcessed OUTPUT;
        ELSE IF @StepKey = 'customer-value'
            EXEC Pipeline.usp_RefreshCustomerValueSnapshot
                @RunID = @RunID, @RowsProcessed = @RowsProcessed OUTPUT;
        ELSE IF @StepKey = 'product-performance'
            EXEC Pipeline.usp_RefreshProductPerformance
                @RunID = @RunID, @RowsProcessed = @RowsProcessed OUTPUT;
        ELSE IF @StepKey = 'executive-kpis'
            EXEC Pipeline.usp_RefreshExecutiveKpis
                @RunID = @RunID, @RowsProcessed = @RowsProcessed OUTPUT;
        ELSE
            THROW 51012, 'The pipeline step does not have an explicit procedure call.', 1;

        UPDATE Pipeline.PipelineStepRuns
        SET Status = 'Succeeded', CompletedAt = SYSUTCDATETIME(),
            DurationMs = DATEDIFF(MILLISECOND, StartedAt, SYSUTCDATETIME()),
            RowsProcessed = @RowsProcessed
        WHERE StepRunID = @StepRunID;
    END TRY
    BEGIN CATCH
        UPDATE Pipeline.PipelineStepRuns
        SET Status = 'Failed', CompletedAt = SYSUTCDATETIME(),
            DurationMs = DATEDIFF(MILLISECOND, StartedAt, SYSUTCDATETIME()),
            RowsProcessed = @RowsProcessed,
            ErrorNumber = ERROR_NUMBER(), ErrorMessage = ERROR_MESSAGE()
        WHERE StepRunID = @StepRunID;

        THROW;
    END CATCH;
END;
GO
