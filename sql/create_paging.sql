/*
    One paging table for all BPA objects, in the same style as dbo.tb_Companies.
    Each object is identified by BPA_Origin (e.g. N'VendorBill', N'Invoice').

    dbo.tb_Paging
        One row per run of a FROM task. Offset is the offset of the next page to
        fetch and is always a multiple of the page limit (1000).
        - BPA_Status            0 = run in progress, 1 = run complete
        - LastRun               when the task last ran (start or last iteration)
        - RecordsLastIteration  records picked up in the last iteration (page)
        - RecordsThisRun        records picked up in this run in total
        - DateFilter            only records modified on or after this are fetched;
                                NULL means a full load

    dbo.usp_Paging_Init @Origin
        Call at the start of every iteration of the FROM task; returns the row to
        page with (use its Offset and DateFilter in the request).
        - If the object has a run in progress (BPA_Status = 0), that row is returned
          and nothing is inserted, so iterations of the same run share one row.
        - Only when there is no run in progress (the last one completed, or this is
          the first run) is a new row inserted, with BPA_Status = 0, Offset = 0,
          MoreRecords = 1 and the counters at 0.
        For a new run, DateFilter is set once and then kept for the whole run:
        1. @FullLoad = 1          -> NULL (fetch everything)
        2. @DateFilter            -> that value
        3. @StagingTable          -> MAX(@LastModifiedColumn) of the object's staging
                                     table (e.g. N'dbo.tb_Netsuite_VendorBill' with
                                     column N'last_modified'); NULL if the table is empty
        4. otherwise              -> start of the object's last completed run
        It is fixed at the start of the run because the staging table's max changes
        as pages are imported during the run. These parameters are ignored when a
        run is already in progress.
        The returned DateFilterText is DateFilter as 'YYYY-MM-DD HH:MI:SS', ready for
        the query placeholder (TO_DATE(..., 'YYYY-MM-DD HH24:MI:SS') in SuiteQL).

    dbo.usp_Paging_Update @Origin, @ResponseXml
        Call at the end of each iteration with the webservice connector's response
        XML (mapped as a string). The procedure reads the first <count> and
        <hasMore> elements at the start of the response:
            <count>1000</count>
            <hasMore>true</hasMore>
        and updates the object's current run (its latest row with BPA_Status = 0):
        sets LastRun, RecordsLastIteration = count and adds count to RecordsThisRun.
        - If hasMore is true, Offset moves on by the page limit (1000).
        - If hasMore is false, the run is complete: MoreRecords = 0 and
          BPA_Status = 1, so the next usp_Paging_Init starts a new run.
        - If <hasMore> is missing, a full page (count = 1000) counts as more records
          and anything less (count < 1000) completes the run.
        Raises an error if <count> is missing or not a number from 0 to 1000.
        Returns the updated row.

    Safe to re-run: the table is only created if missing; procedures use CREATE OR ALTER.
*/
USE [BPAStaging]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID(N'dbo.tb_Paging', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[tb_Paging](
        [BPA_EntryID] [uniqueidentifier] NOT NULL,
        [BPA_Origin] [nvarchar](50) NOT NULL,
        [BPA_Status] [int] NULL,
        [BPA_Syscreated] [datetime] NULL,
        [BPA_Sysmodified] [datetime] NULL,
        [Offset] [int] NOT NULL,
        [MoreRecords] [bit] NOT NULL,
        [DateFilter] [datetime] NULL,
        [LastRun] [datetime] NULL,
        [RecordsLastIteration] [int] NOT NULL,
        [RecordsThisRun] [int] NOT NULL,
     CONSTRAINT [PK_tb_Paging_BPA_EntryID] PRIMARY KEY CLUSTERED
    (
        [BPA_EntryID] ASC
    )WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
    ) ON [PRIMARY];

    ALTER TABLE [dbo].[tb_Paging] ADD CONSTRAINT [DF_tb_Paging_BPA_EntryID] DEFAULT (newsequentialid()) FOR [BPA_EntryID];
    ALTER TABLE [dbo].[tb_Paging] ADD CONSTRAINT [DF_tb_Paging_BPA_Status] DEFAULT ((0)) FOR [BPA_Status];
    ALTER TABLE [dbo].[tb_Paging] ADD CONSTRAINT [DF_tb_Paging_BPA_Syscreated] DEFAULT (getdate()) FOR [BPA_Syscreated];
    ALTER TABLE [dbo].[tb_Paging] ADD CONSTRAINT [DF_tb_Paging_BPA_Sysmodified] DEFAULT (getdate()) FOR [BPA_Sysmodified];
    ALTER TABLE [dbo].[tb_Paging] ADD CONSTRAINT [DF_tb_Paging_Offset] DEFAULT ((0)) FOR [Offset];
    ALTER TABLE [dbo].[tb_Paging] ADD CONSTRAINT [DF_tb_Paging_MoreRecords] DEFAULT ((1)) FOR [MoreRecords];
    ALTER TABLE [dbo].[tb_Paging] ADD CONSTRAINT [DF_tb_Paging_RecordsLastIteration] DEFAULT ((0)) FOR [RecordsLastIteration];
    ALTER TABLE [dbo].[tb_Paging] ADD CONSTRAINT [DF_tb_Paging_RecordsThisRun] DEFAULT ((0)) FOR [RecordsThisRun];

    -- Offset is always a multiple of the page limit (1000)
    ALTER TABLE [dbo].[tb_Paging] ADD CONSTRAINT [CK_tb_Paging_Offset]
        CHECK ([Offset] >= 0 AND [Offset] % 1000 = 0);
    ALTER TABLE [dbo].[tb_Paging] ADD CONSTRAINT [CK_tb_Paging_RecordsLastIteration]
        CHECK ([RecordsLastIteration] BETWEEN 0 AND 1000);
    ALTER TABLE [dbo].[tb_Paging] ADD CONSTRAINT [CK_tb_Paging_RecordsThisRun]
        CHECK ([RecordsThisRun] >= 0);

    CREATE NONCLUSTERED INDEX [IX_tb_Paging_BPA_Origin_BPA_Syscreated]
        ON [dbo].[tb_Paging] ([BPA_Origin], [BPA_Syscreated]) INCLUDE ([BPA_Status], [MoreRecords]) ON [PRIMARY];

    PRINT N'Created [dbo].[tb_Paging]';
END
ELSE
    PRINT N'Skipped [dbo].[tb_Paging] (already exists)';
GO

CREATE OR ALTER PROCEDURE [dbo].[usp_Paging_Init]
    @Origin             nvarchar(50),
    @StagingTable       nvarchar(256) = NULL,
    @LastModifiedColumn sysname       = N'last_modified',
    @DateFilter         datetime      = NULL,
    @FullLoad           bit           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @now datetime = getdate(), @entryID uniqueidentifier, @msg nvarchar(2048),
            @objectID int, @sql nvarchar(max);

    IF @Origin IS NULL
        THROW 50010, N'@Origin is required.', 1;

    BEGIN TRANSACTION;

    -- Run in progress: keep using its row
    SELECT TOP (1) @entryID = [BPA_EntryID]
    FROM [dbo].[tb_Paging] WITH (UPDLOCK, HOLDLOCK)
    WHERE [BPA_Origin] = @Origin AND [BPA_Status] = 0
    ORDER BY [BPA_Syscreated] DESC;

    -- No run in progress: start a new one
    IF @entryID IS NULL
    BEGIN
        IF @FullLoad = 1
            SET @DateFilter = NULL;
        ELSE IF @DateFilter IS NULL AND @StagingTable IS NOT NULL
        BEGIN
            -- Latest last-modified date already in the object's staging table
            SET @objectID = OBJECT_ID(@StagingTable, N'U');
            IF @objectID IS NULL
            BEGIN
                SET @msg = N'Staging table ''' + @StagingTable + N''' not found.';
                THROW 50011, @msg, 1;
            END
            IF COL_LENGTH(@StagingTable, @LastModifiedColumn) IS NULL
            BEGIN
                SET @msg = N'Column ''' + @LastModifiedColumn + N''' not found in ''' + @StagingTable + N'''.';
                THROW 50012, @msg, 1;
            END

            -- Style 120 reads text stored as 'YYYY-MM-DD HH:MI:SS'; datetime columns are taken as is
            SET @sql = N'SELECT @maxDate = MAX(TRY_CONVERT(datetime, ' + QUOTENAME(@LastModifiedColumn) + N', 120)) FROM '
                     + QUOTENAME(OBJECT_SCHEMA_NAME(@objectID)) + N'.' + QUOTENAME(OBJECT_NAME(@objectID)) + N';';
            EXEC sys.sp_executesql @sql, N'@maxDate datetime OUTPUT', @maxDate = @DateFilter OUTPUT;
        END
        ELSE IF @DateFilter IS NULL
            -- No staging table given: start of the object's last completed run
            SELECT TOP (1) @DateFilter = [BPA_Syscreated]
            FROM [dbo].[tb_Paging]
            WHERE [BPA_Origin] = @Origin AND [BPA_Status] = 1
            ORDER BY [BPA_Syscreated] DESC;

        SET @entryID = newid();

        INSERT INTO [dbo].[tb_Paging]
            ([BPA_EntryID], [BPA_Origin], [BPA_Status], [BPA_Syscreated], [BPA_Sysmodified], [Offset],
             [MoreRecords], [DateFilter], [LastRun], [RecordsLastIteration], [RecordsThisRun])
        VALUES
            (@entryID, @Origin, 0, @now, @now, 0, 1, @DateFilter, @now, 0, 0);
    END

    COMMIT TRANSACTION;

    SELECT [BPA_EntryID], [BPA_Origin], [BPA_Status], [Offset], [MoreRecords], [DateFilter],
           CONVERT(varchar(19), [DateFilter], 120) AS [DateFilterText],
           [LastRun], [RecordsLastIteration], [RecordsThisRun], [BPA_Syscreated], [BPA_Sysmodified]
    FROM [dbo].[tb_Paging]
    WHERE [BPA_EntryID] = @entryID;
END
GO

CREATE OR ALTER PROCEDURE [dbo].[usp_Paging_Update]
    @Origin      nvarchar(50),
    @ResponseXml nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @pageLimit int = 1000, @now datetime = getdate(), @msg nvarchar(2048),
            @entryID uniqueidentifier, @Records int, @MoreRecords bit,
            @start int, @end int, @value nvarchar(50);

    IF @Origin IS NULL
        THROW 50020, N'@Origin is required.', 1;
    IF @ResponseXml IS NULL
        THROW 50023, N'@ResponseXml is required.', 1;

    -- <count>...</count>: the first one in the response (before the items)
    SET @start = CHARINDEX(N'<count>', @ResponseXml);
    SET @end   = CASE WHEN @start > 0 THEN CHARINDEX(N'</count>', @ResponseXml, @start) ELSE 0 END;
    IF @end = 0
        THROW 50024, N'No <count> element found in @ResponseXml.', 1;

    SET @value   = LTRIM(RTRIM(SUBSTRING(@ResponseXml, @start + LEN(N'<count>'), @end - @start - LEN(N'<count>'))));
    SET @Records = TRY_CAST(@value AS int);
    IF @Records IS NULL OR @Records NOT BETWEEN 0 AND @pageLimit
    BEGIN
        SET @msg = N'<count> in @ResponseXml must be a number from 0 to 1000 (the page limit), got '''
                 + @value + N'''.';
        THROW 50021, @msg, 1;
    END

    -- <hasMore>true|false</hasMore>; if missing, a full page means there are more records
    SET @start = CHARINDEX(N'<hasMore>', @ResponseXml);
    SET @end   = CASE WHEN @start > 0 THEN CHARINDEX(N'</hasMore>', @ResponseXml, @start) ELSE 0 END;
    IF @end > 0
    BEGIN
        SET @value       = LTRIM(RTRIM(SUBSTRING(@ResponseXml, @start + LEN(N'<hasMore>'), @end - @start - LEN(N'<hasMore>'))));
        SET @MoreRecords = TRY_CAST(@value AS bit);
        IF @MoreRecords IS NULL
        BEGIN
            SET @msg = N'<hasMore> in @ResponseXml must be true or false, got ''' + @value + N'''.';
            THROW 50025, @msg, 1;
        END
    END
    ELSE
        SET @MoreRecords = CASE WHEN @Records = @pageLimit THEN 1 ELSE 0 END;

    BEGIN TRANSACTION;

    -- Current run: the object's latest row that hasn't completed
    SELECT TOP (1) @entryID = [BPA_EntryID]
    FROM [dbo].[tb_Paging] WITH (UPDLOCK, HOLDLOCK)
    WHERE [BPA_Origin] = @Origin AND [BPA_Status] = 0
    ORDER BY [BPA_Syscreated] DESC;

    IF @entryID IS NULL
    BEGIN
        SET @msg = N'No run in progress for origin ''' + @Origin + N'''; call usp_Paging_Init first.';
        THROW 50022, @msg, 1;
    END

    UPDATE [dbo].[tb_Paging]
    SET [Offset]               = CASE WHEN @MoreRecords = 1 THEN [Offset] + @pageLimit ELSE [Offset] END,
        [MoreRecords]          = @MoreRecords,
        [BPA_Status]           = CASE WHEN @MoreRecords = 1 THEN 0 ELSE 1 END,  -- 1 = run complete
        [LastRun]              = @now,
        [RecordsLastIteration] = @Records,
        [RecordsThisRun]       = [RecordsThisRun] + @Records,
        [BPA_Sysmodified]      = @now
    WHERE [BPA_EntryID] = @entryID;

    COMMIT TRANSACTION;

    SELECT [BPA_EntryID], [BPA_Origin], [BPA_Status], [Offset], [MoreRecords], [DateFilter],
           [LastRun], [RecordsLastIteration], [RecordsThisRun], [BPA_Syscreated], [BPA_Sysmodified]
    FROM [dbo].[tb_Paging]
    WHERE [BPA_EntryID] = @entryID;
END
GO

/*
    Example FROM task for vendor bills:

    -- start of every iteration: returns the run in progress, or starts a new one
    EXEC dbo.usp_Paging_Init @Origin = N'VendorBill',
         @StagingTable = N'dbo.tb_Netsuite_VendorBill', @LastModifiedColumn = N'last_modified';  -- incremental
    EXEC dbo.usp_Paging_Init @Origin = N'VendorBill', @FullLoad = 1;   -- full load (new run only)

    -- fetch a page at the returned Offset, then at the end of the iteration:
    -- (map the webservice connector's response XML to @ResponseXml in the BPA step)
    EXEC dbo.usp_Paging_Update @Origin = N'VendorBill',
        @ResponseXml = N'<Response><count>1000</count><hasMore>true</hasMore><items>...</items></Response>';
        -- Offset 0 -> 1000
    EXEC dbo.usp_Paging_Update @Origin = N'VendorBill',
        @ResponseXml = N'<Response><count>350</count><hasMore>false</hasMore><items>...</items></Response>';
        -- last page: run complete (BPA_Status = 1)

    -- current / last run per object
    SELECT p.*
    FROM dbo.tb_Paging p
    WHERE p.[BPA_Syscreated] = (SELECT MAX(x.[BPA_Syscreated])
                                FROM dbo.tb_Paging x
                                WHERE x.[BPA_Origin] = p.[BPA_Origin]);

    -- One-off cleanup after the earlier version, which didn't set BPA_Status and
    -- inserted a row per iteration:
    -- 1. mark runs that already finished as complete
    UPDATE dbo.tb_Paging SET [BPA_Status] = 1 WHERE [MoreRecords] = 0 AND [BPA_Status] = 0;
    -- 2. keep only the latest in-progress row per object
    DELETE p
    FROM dbo.tb_Paging p
    WHERE p.[BPA_Status] = 0
      AND EXISTS (SELECT 1 FROM dbo.tb_Paging x
                  WHERE x.[BPA_Origin] = p.[BPA_Origin] AND x.[BPA_Status] = 0
                    AND x.[BPA_Syscreated] > p.[BPA_Syscreated]);
*/
