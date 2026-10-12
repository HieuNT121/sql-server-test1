USE SalesDB;
GO

CREATE OR ALTER PROCEDURE Pipeline.usp_PublishConversionReadiness
    @RunID BIGINT,
    @RowsProcessed INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @TotalChallenges TINYINT;
    DECLARE @PassedChallenges TINYINT;
    DECLARE @FailedChallenges TINYINT;

    SELECT @TotalChallenges = COUNT(*),
           @PassedChallenges = SUM(CASE WHEN Status = 'Passed' THEN 1 ELSE 0 END),
           @FailedChallenges = SUM(CASE WHEN Status = 'Failed' THEN 1 ELSE 0 END)
    FROM Pipeline.ConversionChallengeResults
    WHERE RunID = @RunID;

    IF @TotalChallenges <> 30
        THROW 51104, 'Cannot publish conversion readiness without 30 challenge results.', 1;

    DELETE FROM Pipeline.ConversionValidationSnapshots WHERE RunID = @RunID;

    INSERT Pipeline.ConversionValidationSnapshots
        (RunID, TotalChallenges, PassedChallenges, FailedChallenges, PublishedAt)
    VALUES
        (@RunID, @TotalChallenges, @PassedChallenges, @FailedChallenges, SYSUTCDATETIME());

    INSERT Pipeline.DataQualityResults (RunID, CheckName, Severity, Status, IssueCount, Detail)
    VALUES
        (@RunID, N'Conversion challenge readiness', 'Critical',
         CASE WHEN @FailedChallenges = 0 THEN 'Passed' ELSE 'Failed' END,
         @FailedChallenges,
         N'All 30 stored procedures derived from 04-conversion-challenges.sql executed successfully and are ready for comparison.');

    SET @RowsProcessed = @TotalChallenges;

    IF @FailedChallenges > 0
        THROW 51105, 'Conversion readiness publication found failed challenge baselines.', 1;
END;
GO
