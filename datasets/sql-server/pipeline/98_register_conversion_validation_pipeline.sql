USE SalesDB;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF NOT EXISTS (SELECT 1 FROM Pipeline.PipelineDefinitions WHERE PipelineKey = 'conversion-validation')
BEGIN
    INSERT Pipeline.PipelineDefinitions (PipelineKey, PipelineName, Description)
    VALUES
    (
        'conversion-validation',
        N'T-SQL conversion readiness pipeline',
        N'Validates hard-mode fixtures and publishes the 30 T-SQL-to-Spark conversion challenge baselines.'
    );
END;

UPDATE Pipeline.PipelineDefinitions
SET PipelineName = N'T-SQL conversion readiness pipeline',
    Description = N'Validates hard-mode fixtures and publishes the 30 T-SQL-to-Spark conversion challenge baselines.',
    IsActive = 1
WHERE PipelineKey = 'conversion-validation';
GO

MERGE Pipeline.ConversionChallengeDefinitions AS target
USING
(
    VALUES
      ('C01',  1, 1, N'TOP WITH TIES', N'Preserve ties with rank() rather than a fixed limit.'),
      ('C02',  2, 1, N'OFFSET / FETCH paging', N'Use a total order and preserve variable paging semantics.'),
      ('C03',  3, 2, N'CROSS APPLY top-N per parent', N'Rewrite correlated TOP as partitioned row_number().'),
      ('C04',  4, 2, N'As-of exchange-rate join', N'Use latest rate on or before the local invoice date.'),
      ('C05',  5, 3, N'Recursive CTE org chart', N'Replace recursive traversal with an iterative hierarchy strategy.'),
      ('C06',  6, 2, N'Gaps and islands', N'Preserve month-boundary arithmetic and integer DATEADD inputs.'),
      ('C07',  7, 2, N'JSON event sessionization', N'Guard malformed JSON and preserve DATEDIFF boundary semantics.'),
      ('C08',  8, 2, N'Window frames and integer AVG', N'Account for RANGE frames and integer-division behaviour.'),
      ('C09',  9, 2, N'LAG, LEAD, and LAST_VALUE', N'Use an explicit full frame for the final value.'),
      ('C10', 10, 2, N'Percentiles and NTILE', N'Preserve windowed percentile semantics and distinct rows.'),
      ('C11', 11, 1, N'ROLLUP and GROUPING', N'Distinguish data NULLs from rollup-generated NULLs.'),
      ('C12', 12, 1, N'PIVOT and UNPIVOT', N'UNPIVOT drops NULLs; match that behaviour deliberately.'),
      ('C13', 13, 1, N'STRING_AGG and STRING_SPLIT', N'Preserve aggregate ordering, ordinal positions, and empty values.'),
      ('C14', 14, 2, N'Date function semantics', N'Preserve boundary-counting, DATEFIRST, formats, and fiscal dates.'),
      ('C15', 15, 2, N'DATETIMEOFFSET and time zones', N'Map Windows zones to IANA zones and retain offset semantics.'),
      ('C16', 16, 2, N'String and NULL semantics', N'Preserve collation, trailing spaces, NULL concatenation, and lengths.'),
      ('C17', 17, 2, N'Text feed parsing', N'Preserve TRY_CONVERT styles, cultures, and latest-record deduplication.'),
      ('C18', 18, 2, N'JSON schema and arrays', N'Guard malformed JSON before parsing and exploding nested arrays.'),
      ('C19', 19, 3, N'XML methods', N'Replace XML values, nodes, and exists checks with an explicit strategy.'),
      ('C20', 20, 2, N'Promotion range join', N'Preserve open dates, site-wide rows, and deterministic tie-breaking.'),
      ('C21', 21, 2, N'Anti-joins and NULLs', N'NOT IN, NOT EXISTS, and EXCEPT do not share NULL semantics.'),
      ('C22', 22, 3, N'System-versioned temporal queries', N'Replace system time with time travel or a history join.'),
      ('C23', 23, 2, N'SCD2 point-in-time join', N'Handle open ValidTo values and inclusive date boundaries.'),
      ('C24', 24, 1, N'HIERARCHYID', N'Represent hierarchy as a path or closure-table structure.'),
      ('C25', 25, 2, N'Payment fan-out aggregation', N'Prevent double counting after one-to-many payment joins.'),
      ('C26', 26, 2, N'Numeric precision and rounding', N'Preserve DECIMAL, MONEY, FLOAT, truncation, and rounding rules.'),
      ('C27', 27, 3, N'Procedural monthly batch', N'Replace loops, temp state, and transaction control explicitly.'),
      ('C28', 28, 3, N'DML, OUTPUT, and triggers', N'Account for Delta MERGE differences and absent trigger side effects.'),
      ('C29', 29, 3, N'Programmable objects', N'Redesign output parameters, dynamic SQL, TVFs, and UDFs.'),
      ('C30', 30, 2, N'Cohort retention matrix', N'Preserve month bucketing, NULLIF, and dirty-data filtering.')
) AS source (ChallengeKey, ChallengeOrder, ComplexityLevel, ChallengeName, TrapDescription)
ON target.ChallengeKey = source.ChallengeKey
WHEN MATCHED THEN
    UPDATE SET ChallengeOrder = source.ChallengeOrder,
               ComplexityLevel = source.ComplexityLevel,
               ChallengeName = source.ChallengeName,
               TrapDescription = source.TrapDescription,
               IsActive = 1
WHEN NOT MATCHED BY TARGET THEN
    INSERT (ChallengeKey, ChallengeOrder, ComplexityLevel, ChallengeName, TrapDescription, IsActive)
    VALUES (source.ChallengeKey, source.ChallengeOrder, source.ComplexityLevel,
            source.ChallengeName, source.TrapDescription, 1);
GO

UPDATE Pipeline.ConversionChallengeDefinitions
SET IsActive = 0
WHERE ChallengeKey NOT BETWEEN 'C01' AND 'C30';
GO

DECLARE @PipelineDefinitionID INT =
    (SELECT PipelineDefinitionID FROM Pipeline.PipelineDefinitions WHERE PipelineKey = 'conversion-validation');

DECLARE @Steps TABLE
(
    StepKey VARCHAR(80), StepOrder TINYINT, LayerNumber TINYINT, LayerName NVARCHAR(80),
    StepName NVARCHAR(120), ProcedureSchema SYSNAME, ProcedureName SYSNAME
);

INSERT @Steps
VALUES
 ('validate-conversion-fixtures', 1, 1, N'Fixture readiness', N'Validate advanced conversion fixtures', N'Pipeline', N'usp_ValidateConversionFixtures');

INSERT @Steps
SELECT CONCAT('challenge-', LOWER(definition.ChallengeKey)),
       CONVERT(TINYINT, definition.ChallengeOrder + 1),
       CONVERT(TINYINT,
           CASE
               WHEN definition.ChallengeOrder <= 13 THEN 2
               WHEN definition.ChallengeOrder <= 20 THEN 3
               WHEN definition.ChallengeOrder <= 26 THEN 4
               ELSE 5
           END),
       CASE
           WHEN definition.ChallengeOrder <= 13 THEN N'Relational semantics'
           WHEN definition.ChallengeOrder <= 20 THEN N'Types and documents'
           WHEN definition.ChallengeOrder <= 26 THEN N'History and precision'
           ELSE N'Procedural integration'
       END,
       CONCAT(definition.ChallengeKey, N': ', definition.ChallengeName),
       N'Sales',
       CONCAT(N'usp_ConversionChallenge_', definition.ChallengeKey)
FROM Pipeline.ConversionChallengeDefinitions AS definition
WHERE definition.IsActive = 1;

INSERT @Steps
VALUES
 ('publish-conversion-readiness', 32, 6, N'Publication', N'Publish conversion readiness', N'Pipeline', N'usp_PublishConversionReadiness');

;WITH ObsoleteSteps AS
(
    SELECT target.StepDefinitionID,
           ROW_NUMBER() OVER (ORDER BY target.StepDefinitionID) AS ObsoleteOrder
    FROM Pipeline.PipelineStepDefinitions AS target
    WHERE target.PipelineDefinitionID = @PipelineDefinitionID
      AND target.StepKey NOT IN (SELECT StepKey FROM @Steps)
)
UPDATE target
SET StepOrder = CONVERT(TINYINT, 200 + obsolete.ObsoleteOrder),
    IsActive = 0
FROM Pipeline.PipelineStepDefinitions AS target
JOIN ObsoleteSteps AS obsolete ON obsolete.StepDefinitionID = target.StepDefinitionID;

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
    (SELECT PipelineDefinitionID FROM Pipeline.PipelineDefinitions WHERE PipelineKey = 'conversion-validation');

DECLARE @Dependencies TABLE (StepKey VARCHAR(80), DependsOnStepKey VARCHAR(80));
INSERT @Dependencies
SELECT CONCAT('challenge-', LOWER(ChallengeKey)), 'validate-conversion-fixtures'
FROM Pipeline.ConversionChallengeDefinitions
WHERE IsActive = 1;

INSERT @Dependencies
SELECT 'publish-conversion-readiness', CONCAT('challenge-', LOWER(ChallengeKey))
FROM Pipeline.ConversionChallengeDefinitions
WHERE IsActive = 1;

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
    (SELECT PipelineDefinitionID FROM Pipeline.PipelineDefinitions WHERE PipelineKey = 'conversion-validation');
DECLARE @InitialRunID BIGINT;

IF NOT EXISTS
(
    SELECT 1
    FROM Pipeline.PipelineRuns AS run
    WHERE run.PipelineDefinitionID = @PipelineDefinitionID
      AND run.Status = 'Succeeded'
      AND (SELECT COUNT(*) FROM Pipeline.PipelineStepRuns AS step WHERE step.RunID = run.RunID) = 32
)
    EXEC Pipeline.usp_RunConversionValidationPipeline
        @TriggeredBy = N'Docker conversion pipeline initialization',
        @RunID = @InitialRunID OUTPUT;
GO

PRINT 'T-SQL conversion readiness pipeline is ready.';
GO
