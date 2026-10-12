USE SalesDB;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'Pipeline.ConversionChallengeDefinitions', N'U') IS NULL
BEGIN
    CREATE TABLE Pipeline.ConversionChallengeDefinitions
    (
        ChallengeKey       VARCHAR(3)    NOT NULL CONSTRAINT PK_ConversionChallengeDefinitions PRIMARY KEY,
        ChallengeOrder     TINYINT       NOT NULL CONSTRAINT UQ_ConversionChallengeDefinitions_Order UNIQUE,
        ComplexityLevel    TINYINT       NOT NULL,
        ChallengeName      NVARCHAR(160) NOT NULL,
        TrapDescription    NVARCHAR(500) NOT NULL,
        IsActive           BIT           NOT NULL CONSTRAINT DF_ConversionChallengeDefinitions_IsActive DEFAULT (1),
        CONSTRAINT CK_ConversionChallengeDefinitions_Level CHECK (ComplexityLevel IN (1, 2, 3))
    );
END;
GO

IF OBJECT_ID(N'Pipeline.ConversionChallengeResults', N'U') IS NULL
BEGIN
    CREATE TABLE Pipeline.ConversionChallengeResults
    (
        ConversionResultID BIGINT         IDENTITY(1, 1) NOT NULL CONSTRAINT PK_ConversionChallengeResults PRIMARY KEY,
        RunID              BIGINT         NOT NULL,
        ChallengeKey       VARCHAR(3)     NOT NULL,
        Status             VARCHAR(20)    NOT NULL,
        SourceRowCount     INT            NULL,
        Detail             NVARCHAR(1000) NOT NULL,
        CapturedAt         DATETIME2(3)   NOT NULL CONSTRAINT DF_ConversionChallengeResults_CapturedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_ConversionChallengeResults_Run FOREIGN KEY (RunID) REFERENCES Pipeline.PipelineRuns(RunID),
        CONSTRAINT FK_ConversionChallengeResults_Challenge FOREIGN KEY (ChallengeKey)
            REFERENCES Pipeline.ConversionChallengeDefinitions(ChallengeKey),
        CONSTRAINT UQ_ConversionChallengeResults_Run_Challenge UNIQUE (RunID, ChallengeKey),
        CONSTRAINT CK_ConversionChallengeResults_Status CHECK (Status IN ('Passed', 'Failed'))
    );

    CREATE INDEX IX_ConversionChallengeResults_RunID
        ON Pipeline.ConversionChallengeResults (RunID, ChallengeKey)
        INCLUDE (Status, SourceRowCount, CapturedAt);
END;
GO

IF OBJECT_ID(N'Pipeline.ConversionValidationSnapshots', N'U') IS NULL
BEGIN
    CREATE TABLE Pipeline.ConversionValidationSnapshots
    (
        RunID             BIGINT       NOT NULL CONSTRAINT PK_ConversionValidationSnapshots PRIMARY KEY,
        TotalChallenges   TINYINT      NOT NULL,
        PassedChallenges  TINYINT      NOT NULL,
        FailedChallenges  TINYINT      NOT NULL,
        PublishedAt       DATETIME2(3) NOT NULL CONSTRAINT DF_ConversionValidationSnapshots_PublishedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_ConversionValidationSnapshots_Run FOREIGN KEY (RunID) REFERENCES Pipeline.PipelineRuns(RunID),
        CONSTRAINT CK_ConversionValidationSnapshots_Totals
            CHECK (TotalChallenges = PassedChallenges + FailedChallenges)
    );
END;
GO
