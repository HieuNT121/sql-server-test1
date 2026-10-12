USE SalesDB;
GO

CREATE OR ALTER PROCEDURE Pipeline.usp_RunConversionValidationPipeline
    @TriggeredBy NVARCHAR(100) = N'Manual execution',
    @RunID BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PipelineDefinitionID INT;
    DECLARE @PipelineName NVARCHAR(150);
    DECLARE @StepDefinitionID INT;
    DECLARE @RowsProcessed INT;
    DECLARE @TotalRowsProcessed INT = 0;
    DECLARE @StartedAt DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @LockResult INT;

    EXEC @LockResult = sys.sp_getapplock
        @Resource = N'Pipeline:ConversionValidation',
        @LockMode = 'Exclusive',
        @LockOwner = 'Session',
        @LockTimeout = 0;

    IF @LockResult < 0
        THROW 51120, 'The conversion validation pipeline is already running.', 1;

    SELECT @PipelineDefinitionID = PipelineDefinitionID,
           @PipelineName = PipelineName
    FROM Pipeline.PipelineDefinitions
    WHERE PipelineKey = 'conversion-validation' AND IsActive = 1;

    IF @PipelineDefinitionID IS NULL
    BEGIN
        EXEC sys.sp_releaseapplock @Resource = N'Pipeline:ConversionValidation', @LockOwner = 'Session';
        THROW 51121, 'The conversion validation pipeline definition is missing or inactive.', 1;
    END;

    INSERT Pipeline.PipelineRuns
        (PipelineDefinitionID, PipelineName, Status, TriggeredBy, StartedAt)
    VALUES
        (@PipelineDefinitionID, @PipelineName, 'Running', @TriggeredBy, @StartedAt);

    SET @RunID = SCOPE_IDENTITY();

    DECLARE step_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT StepDefinitionID
        FROM Pipeline.PipelineStepDefinitions
        WHERE PipelineDefinitionID = @PipelineDefinitionID AND IsActive = 1
        ORDER BY LayerNumber, StepOrder;

    BEGIN TRY
        OPEN step_cursor;
        FETCH NEXT FROM step_cursor INTO @StepDefinitionID;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC Pipeline.usp_ExecutePipelineStep
                @RunID = @RunID,
                @StepDefinitionID = @StepDefinitionID,
                @RowsProcessed = @RowsProcessed OUTPUT;

            SET @TotalRowsProcessed += @RowsProcessed;
            FETCH NEXT FROM step_cursor INTO @StepDefinitionID;
        END;

        CLOSE step_cursor;
        DEALLOCATE step_cursor;

        UPDATE Pipeline.PipelineRuns
        SET Status = 'Succeeded', CompletedAt = SYSUTCDATETIME(),
            DurationMs = DATEDIFF(MILLISECOND, StartedAt, SYSUTCDATETIME()),
            RowsProcessed = @TotalRowsProcessed
        WHERE RunID = @RunID;

        EXEC sys.sp_releaseapplock @Resource = N'Pipeline:ConversionValidation', @LockOwner = 'Session';
    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local', 'step_cursor') >= 0 CLOSE step_cursor;
        IF CURSOR_STATUS('local', 'step_cursor') > -3 DEALLOCATE step_cursor;

        UPDATE Pipeline.PipelineRuns
        SET Status = 'Failed', CompletedAt = SYSUTCDATETIME(),
            DurationMs = DATEDIFF(MILLISECOND, StartedAt, SYSUTCDATETIME()),
            RowsProcessed = @TotalRowsProcessed,
            ErrorNumber = ERROR_NUMBER(), ErrorMessage = ERROR_MESSAGE()
        WHERE RunID = @RunID;

        EXEC sys.sp_releaseapplock @Resource = N'Pipeline:ConversionValidation', @LockOwner = 'Session';
        THROW;
    END CATCH;

    SELECT RunID, PipelineName, Status, TriggeredBy, StartedAt, CompletedAt, DurationMs, RowsProcessed
    FROM Pipeline.PipelineRuns
    WHERE RunID = @RunID;
END;
GO
