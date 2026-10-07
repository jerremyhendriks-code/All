/*
    Paging settings per company and record type (vendorBill, invoice), in the same
    BPA style as dbo.tb_Companies, plus a log table and the reset / update procedures.

    dbo.tb_CompanyPaging
        One row per company and record type: page size, Offset of the next page,
        MoreRecords, DateFilter (only records modified on or after it are fetched;
        NULL means a full load) and when the current / last run started and finished.
        Seeded with a vendorBill and an invoice row for every company in tb_Companies.

    dbo.tb_CompanyPagingLog
        One row per reset, fetched page and completed run. Page rows hold the rows
        fetched, inserted, updated and skipped for that page; the completed row holds
        the totals for the whole run.

    dbo.usp_Netsuite_VendorBill_ResetPaging
        Call before starting a sync. Sets Offset back to 0, clears TotalResults,
        sets MoreRecords = 1 and stamps RunStartedAt.
        - @Company = NULL resets every company for @RecordType.
        - @FullLoad = 1 also clears DateFilter, so all records are fetched instead of
          only those modified since the last completed run.
        - @DateFilter sets the date filter explicitly (ignored when @FullLoad = 1).
        - @PageSize changes the page size (1-1000).
        Returns the reset rows.

    dbo.usp_Netsuite_VendorBill_UpdatePaging
        Call after each page is fetched and stored, for one company.
        - A run must be in progress (ResetPaging called, last page not yet reported).
        - @Offset must equal the stored Offset; otherwise the page is out of order
          (or already processed) and the procedure raises an error.
        - Moves Offset on by @RowsFetched and stores TotalResults / MoreRecords.
        - @RowsInserted, @RowsUpdated and @RowsSkipped (optional) are logged on the page row.
        - When @MoreRecords = 0 the run is complete: RunCompletedAt is set, DateFilter
          moves to RunStartedAt (so records changed during the run are picked up next
          time), Offset goes back to 0 and a 'completed' log row is added with the
          run's totals (summed over its page rows).
        Returns the company's row.

    Both procedures take @RecordType (default N'vendorBill'), so they work for
    invoices as well.

    Safe to re-run: tables are only created if missing, seed rows are only added for
    company / record type pairs that aren't there yet, and procedures use CREATE OR ALTER.
*/
USE [BPAStaging]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID(N'dbo.tb_CompanyPaging', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[tb_CompanyPaging](
        [BPA_EntryID] [uniqueidentifier] NOT NULL
            CONSTRAINT [DF_tb_CompanyPaging_BPA_EntryID] DEFAULT (newsequentialid()),
        [BPA_Origin] [nvarchar](50) NULL,
        [BPA_Status] [int] NULL
            CONSTRAINT [DF_tb_CompanyPaging_BPA_Status] DEFAULT ((0)),
        [BPA_Company] [nvarchar](50) NOT NULL,
        [RecordType] [nvarchar](50) NOT NULL,
        [PageSize] [int] NOT NULL
            CONSTRAINT [DF_tb_CompanyPaging_PageSize] DEFAULT ((1000)),
        [Offset] [int] NOT NULL
            CONSTRAINT [DF_tb_CompanyPaging_Offset] DEFAULT ((0)),
        [MoreRecords] [bit] NOT NULL
            CONSTRAINT [DF_tb_CompanyPaging_MoreRecords] DEFAULT ((0)),
        [TotalResults] [int] NULL,
        [DateFilter] [datetime] NULL,
        [RunStartedAt] [datetime] NULL,
        [RunCompletedAt] [datetime] NULL,
        [BPA_Syscreated] [datetime] NULL
            CONSTRAINT [DF_tb_CompanyPaging_BPA_Syscreated] DEFAULT (getdate()),
        [BPA_Sysmodified] [datetime] NULL
            CONSTRAINT [DF_tb_CompanyPaging_BPA_Sysmodified] DEFAULT (getdate()),
     CONSTRAINT [PK_tb_CompanyPaging_BPA_EntryID] PRIMARY KEY CLUSTERED
    (
        [BPA_EntryID] ASC
    ) ON [PRIMARY],
     CONSTRAINT [UQ_tb_CompanyPaging_Company_RecordType] UNIQUE NONCLUSTERED
    (
        [BPA_Company] ASC,
        [RecordType] ASC
    ) ON [PRIMARY],
     CONSTRAINT [CK_tb_CompanyPaging_PageSize] CHECK ([PageSize] BETWEEN 1 AND 1000),
     CONSTRAINT [CK_tb_CompanyPaging_Offset] CHECK ([Offset] >= 0),
     CONSTRAINT [CK_tb_CompanyPaging_TotalResults] CHECK ([TotalResults] IS NULL OR [TotalResults] >= 0)
    ) ON [PRIMARY];

    PRINT N'Created [dbo].[tb_CompanyPaging]';
END
ELSE
    PRINT N'Skipped [dbo].[tb_CompanyPaging] (already exists)';
GO

IF OBJECT_ID(N'dbo.tb_CompanyPagingLog', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[tb_CompanyPagingLog](
        [BPA_EntryID] [uniqueidentifier] NOT NULL
            CONSTRAINT [DF_tb_CompanyPagingLog_BPA_EntryID] DEFAULT (newsequentialid()),
        [BPA_Company] [nvarchar](50) NOT NULL,
        [RecordType] [nvarchar](50) NOT NULL,
        [EventType] [nvarchar](20) NOT NULL,
        [RunStartedAt] [datetime] NULL,
        [Offset] [int] NULL,
        [PageSize] [int] NULL,
        [RowsFetched] [int] NULL,
        [RowsInserted] [int] NULL,
        [RowsUpdated] [int] NULL,
        [RowsSkipped] [int] NULL,
        [TotalResults] [int] NULL,
        [MoreRecords] [bit] NULL,
        [DateFilter] [datetime] NULL,
        [BPA_Syscreated] [datetime] NOT NULL
            CONSTRAINT [DF_tb_CompanyPagingLog_BPA_Syscreated] DEFAULT (getdate()),
     CONSTRAINT [PK_tb_CompanyPagingLog_BPA_EntryID] PRIMARY KEY CLUSTERED
    (
        [BPA_EntryID] ASC
    ) ON [PRIMARY],
     CONSTRAINT [CK_tb_CompanyPagingLog_EventType] CHECK ([EventType] IN (N'reset', N'page', N'completed')),
     CONSTRAINT [CK_tb_CompanyPagingLog_RowCounts] CHECK (
            ([RowsFetched]  IS NULL OR [RowsFetched]  >= 0)
        AND ([RowsInserted] IS NULL OR [RowsInserted] >= 0)
        AND ([RowsUpdated]  IS NULL OR [RowsUpdated]  >= 0)
        AND ([RowsSkipped]  IS NULL OR [RowsSkipped]  >= 0))
    ) ON [PRIMARY];

    CREATE NONCLUSTERED INDEX [IX_tb_CompanyPagingLog_Company_RecordType_Run]
        ON [dbo].[tb_CompanyPagingLog] ([BPA_Company], [RecordType], [RunStartedAt], [EventType]) ON [PRIMARY];

    PRINT N'Created [dbo].[tb_CompanyPagingLog]';
END
ELSE
    PRINT N'Skipped [dbo].[tb_CompanyPagingLog] (already exists)';
GO

-- Seed a vendorBill and an invoice row for every company that doesn't have one yet
INSERT INTO [dbo].[tb_CompanyPaging] ([BPA_Origin], [BPA_Company], [RecordType])
SELECT MIN(c.[BPA_Origin]), c.[BPA_Company], rt.[RecordType]
FROM [dbo].[tb_Companies] c
CROSS JOIN (VALUES (N'vendorBill'), (N'invoice')) rt ([RecordType])
WHERE c.[BPA_Company] IS NOT NULL
  AND NOT EXISTS (SELECT 1
                  FROM [dbo].[tb_CompanyPaging] p
                  WHERE p.[BPA_Company] = c.[BPA_Company]
                    AND p.[RecordType] = rt.[RecordType])
GROUP BY c.[BPA_Company], rt.[RecordType];

PRINT N'Seeded ' + CAST(@@ROWCOUNT AS nvarchar(10)) + N' row(s)';
GO

CREATE OR ALTER PROCEDURE [dbo].[usp_Netsuite_VendorBill_ResetPaging]
    @Company    nvarchar(50) = NULL,
    @RecordType nvarchar(50) = N'vendorBill',
    @FullLoad   bit          = 0,
    @DateFilter datetime     = NULL,
    @PageSize   int          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @now datetime = getdate(), @msg nvarchar(2048);

    IF @PageSize IS NOT NULL AND @PageSize NOT BETWEEN 1 AND 1000
        THROW 50010, N'@PageSize must be between 1 and 1000.', 1;

    BEGIN TRANSACTION;

    UPDATE [dbo].[tb_CompanyPaging]
    SET [Offset]          = 0,
        [TotalResults]    = NULL,
        [MoreRecords]     = 1,
        [PageSize]        = ISNULL(@PageSize, [PageSize]),
        [DateFilter]      = CASE WHEN @FullLoad = 1 THEN NULL
                                 ELSE ISNULL(@DateFilter, [DateFilter]) END,
        [RunStartedAt]    = @now,
        [RunCompletedAt]  = NULL,
        [BPA_Sysmodified] = @now
    WHERE [RecordType] = @RecordType
      AND (@Company IS NULL OR [BPA_Company] = @Company);

    IF @@ROWCOUNT = 0
    BEGIN
        SET @msg = N'No paging settings found for record type ''' + @RecordType + N''''
                 + ISNULL(N' and company ''' + @Company + N'''', N'') + N'.';
        THROW 50011, @msg, 1;
    END

    INSERT INTO [dbo].[tb_CompanyPagingLog]
        ([BPA_Company], [RecordType], [EventType], [RunStartedAt], [Offset], [PageSize], [DateFilter])
    SELECT [BPA_Company], [RecordType], N'reset', [RunStartedAt], [Offset], [PageSize], [DateFilter]
    FROM [dbo].[tb_CompanyPaging]
    WHERE [RecordType] = @RecordType
      AND (@Company IS NULL OR [BPA_Company] = @Company);

    COMMIT TRANSACTION;

    SELECT [BPA_Company], [RecordType], [BPA_Status], [PageSize], [Offset], [MoreRecords],
           [TotalResults], [DateFilter], [RunStartedAt], [RunCompletedAt], [BPA_Sysmodified]
    FROM [dbo].[tb_CompanyPaging]
    WHERE [RecordType] = @RecordType
      AND (@Company IS NULL OR [BPA_Company] = @Company)
    ORDER BY [BPA_Company];
END
GO

CREATE OR ALTER PROCEDURE [dbo].[usp_Netsuite_VendorBill_UpdatePaging]
    @Company      nvarchar(50),
    @Offset       int,
    @RowsFetched  int,
    @MoreRecords  bit,
    @TotalResults int          = NULL,
    @RowsInserted int          = NULL,
    @RowsUpdated  int          = NULL,
    @RowsSkipped  int          = NULL,
    @RecordType   nvarchar(50) = N'vendorBill'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @now datetime = getdate(), @msg nvarchar(2048),
            @storedOffset int, @storedMoreRecords bit, @runStartedAt datetime;

    IF @Company IS NULL
        THROW 50020, N'@Company is required.', 1;
    IF @Offset IS NULL OR @Offset < 0
        THROW 50021, N'@Offset must be 0 or greater.', 1;
    IF @RowsFetched IS NULL OR @RowsFetched < 0
        THROW 50022, N'@RowsFetched must be 0 or greater.', 1;
    IF @MoreRecords IS NULL
        THROW 50023, N'@MoreRecords is required.', 1;
    IF @TotalResults < 0
        THROW 50024, N'@TotalResults must be 0 or greater.', 1;
    IF @RowsInserted < 0 OR @RowsUpdated < 0 OR @RowsSkipped < 0
        THROW 50025, N'@RowsInserted, @RowsUpdated and @RowsSkipped must be 0 or greater.', 1;

    BEGIN TRANSACTION;

    SELECT @storedOffset = [Offset], @storedMoreRecords = [MoreRecords],
           @runStartedAt = [RunStartedAt]
    FROM [dbo].[tb_CompanyPaging] WITH (UPDLOCK, HOLDLOCK)
    WHERE [BPA_Company] = @Company AND [RecordType] = @RecordType;

    IF @storedOffset IS NULL
    BEGIN
        SET @msg = N'No paging settings found for company ''' + @Company
                 + N''' and record type ''' + @RecordType + N'''.';
        THROW 50026, @msg, 1;
    END

    IF @storedMoreRecords = 0
    BEGIN
        SET @msg = N'No run in progress for company ''' + @Company + N''' and record type '''
                 + @RecordType + N'''; call usp_Netsuite_VendorBill_ResetPaging first.';
        THROW 50027, @msg, 1;
    END

    IF @storedOffset <> @Offset
    BEGIN
        SET @msg = N'Page at offset ' + CAST(@Offset AS nvarchar(12)) + N' for company ''' + @Company
                 + N''' and record type ''' + @RecordType + N''' is out of order: expected offset '
                 + CAST(@storedOffset AS nvarchar(12)) + N'.';
        THROW 50028, @msg, 1;
    END

    INSERT INTO [dbo].[tb_CompanyPagingLog]
        ([BPA_Company], [RecordType], [EventType], [RunStartedAt], [Offset], [PageSize],
         [RowsFetched], [RowsInserted], [RowsUpdated], [RowsSkipped], [TotalResults],
         [MoreRecords], [DateFilter])
    SELECT [BPA_Company], [RecordType], N'page', [RunStartedAt], @Offset, [PageSize],
           @RowsFetched, @RowsInserted, @RowsUpdated, @RowsSkipped,
           ISNULL(@TotalResults, [TotalResults]), @MoreRecords, [DateFilter]
    FROM [dbo].[tb_CompanyPaging]
    WHERE [BPA_Company] = @Company AND [RecordType] = @RecordType;

    IF @MoreRecords = 1
    BEGIN
        UPDATE [dbo].[tb_CompanyPaging]
        SET [Offset]          = @Offset + @RowsFetched,
            [TotalResults]    = ISNULL(@TotalResults, [TotalResults]),
            [MoreRecords]     = 1,
            [BPA_Sysmodified] = @now
        WHERE [BPA_Company] = @Company AND [RecordType] = @RecordType;
    END
    ELSE
    BEGIN
        -- Last page: close the run and move the date filter to when it started
        UPDATE [dbo].[tb_CompanyPaging]
        SET [Offset]          = 0,
            [TotalResults]    = ISNULL(@TotalResults, [TotalResults]),
            [MoreRecords]     = 0,
            [DateFilter]      = ISNULL(@runStartedAt, [DateFilter]),
            [RunCompletedAt]  = @now,
            [BPA_Sysmodified] = @now
        WHERE [BPA_Company] = @Company AND [RecordType] = @RecordType;

        -- Run totals: sum of this run's page rows (including the one logged above)
        INSERT INTO [dbo].[tb_CompanyPagingLog]
            ([BPA_Company], [RecordType], [EventType], [RunStartedAt], [Offset], [PageSize],
             [RowsFetched], [RowsInserted], [RowsUpdated], [RowsSkipped], [TotalResults],
             [MoreRecords], [DateFilter])
        SELECT p.[BPA_Company], p.[RecordType], N'completed', @runStartedAt, @Offset + @RowsFetched,
               p.[PageSize], t.[RowsFetched], t.[RowsInserted], t.[RowsUpdated], t.[RowsSkipped],
               p.[TotalResults], 0, p.[DateFilter]
        FROM [dbo].[tb_CompanyPaging] p
        CROSS APPLY (SELECT [RowsFetched]  = SUM(l.[RowsFetched]),
                            [RowsInserted] = SUM(l.[RowsInserted]),
                            [RowsUpdated]  = SUM(l.[RowsUpdated]),
                            [RowsSkipped]  = SUM(l.[RowsSkipped])
                     FROM [dbo].[tb_CompanyPagingLog] l
                     WHERE l.[BPA_Company] = @Company
                       AND l.[RecordType] = @RecordType
                       AND l.[RunStartedAt] = @runStartedAt
                       AND l.[EventType] = N'page') t
        WHERE p.[BPA_Company] = @Company AND p.[RecordType] = @RecordType;
    END

    COMMIT TRANSACTION;

    SELECT [BPA_Company], [RecordType], [BPA_Status], [PageSize], [Offset], [MoreRecords],
           [TotalResults], [DateFilter], [RunStartedAt], [RunCompletedAt], [BPA_Sysmodified]
    FROM [dbo].[tb_CompanyPaging]
    WHERE [BPA_Company] = @Company AND [RecordType] = @RecordType;
END
GO

/*
    Example sync loop:

    EXEC dbo.usp_Netsuite_VendorBill_ResetPaging;                                  -- all companies, incremental
    EXEC dbo.usp_Netsuite_VendorBill_ResetPaging @Company = N'ACME', @FullLoad = 1; -- one company, full reload

    -- after fetching and storing each page for a company (offset 0, 1000, 2000, ...):
    EXEC dbo.usp_Netsuite_VendorBill_UpdatePaging
        @Company = N'ACME', @Offset = 0, @RowsFetched = 1000, @TotalResults = 2350, @MoreRecords = 1,
        @RowsInserted = 940, @RowsUpdated = 55, @RowsSkipped = 5;

    -- row counts per run
    SELECT [BPA_Company], [RunStartedAt], [BPA_Syscreated] AS [RunCompletedAt],
           [RowsFetched], [RowsInserted], [RowsUpdated], [RowsSkipped]
    FROM dbo.tb_CompanyPagingLog
    WHERE [RecordType] = N'vendorBill' AND [EventType] = N'completed'
    ORDER BY [RunStartedAt] DESC, [BPA_Company];
*/
