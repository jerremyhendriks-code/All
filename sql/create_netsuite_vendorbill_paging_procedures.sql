/*
    Paging log table and procedures for the vendorBill sync.
    Requires dbo.tb_Netsuite_PaginationSettings (create_netsuite_pagination_settings.sql).

    dbo.tb_Netsuite_PaginationLog
        One row per reset, fetched page and completed run, so you can see how a
        sync progressed and where it stopped.

    dbo.usp_Netsuite_VendorBill_ResetPaging
        Call before starting a sync. Sets current_offset back to 0, clears
        total_results, sets has_more = 1 and stamps last_run_started_at.
        - @full_load = 1 also clears last_modified_from, so all vendor bills are
          fetched instead of only those modified since the last completed run.
        - @last_modified_from sets the watermark explicitly (ignored when @full_load = 1).
        - @page_size changes the page size (1-1000).
        Returns the settings row.

    dbo.usp_Netsuite_VendorBill_UpdatePaging
        Call after each page is fetched and stored.
        - A run must be in progress (ResetPaging called, last page not yet reported).
        - @offset must equal the stored current_offset; otherwise the page is out of
          order (or already processed) and the procedure raises an error.
        - Moves current_offset on by @rows_fetched and stores total_results / has_more.
        - When @has_more = 0 the run is complete: last_run_completed_at is set,
          last_modified_from moves to last_run_started_at (so records changed during
          the run are picked up next time) and current_offset goes back to 0.
        Returns the settings row.

    Both procedures take @record_type (default N'vendorBill'), so they can be used
    for invoices later as well.

    Safe to re-run: the table is only created if missing; procedures use CREATE OR ALTER.
*/
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'dbo.tb_Netsuite_PaginationLog', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.tb_Netsuite_PaginationLog (
        id                  bigint IDENTITY(1, 1) NOT NULL,
        record_type         nvarchar(50)          NOT NULL,
        event_type          nvarchar(20)          NOT NULL,
        run_started_at      datetime2(0)          NULL,
        page_offset         int                   NULL,
        page_size           int                   NULL,
        rows_fetched        int                   NULL,
        total_results       int                   NULL,
        has_more            bit                   NULL,
        last_modified_from  datetime2(0)          NULL,
        logged_at           datetime2(0)          NOT NULL
            CONSTRAINT DF_tb_Netsuite_PaginationLog_logged_at DEFAULT (SYSUTCDATETIME()),

        CONSTRAINT PK_tb_Netsuite_PaginationLog
            PRIMARY KEY CLUSTERED (id),
        CONSTRAINT CK_tb_Netsuite_PaginationLog_event_type
            CHECK (event_type IN (N'reset', N'page', N'completed'))
    );

    CREATE NONCLUSTERED INDEX IX_tb_Netsuite_PaginationLog_record_type_logged_at
        ON dbo.tb_Netsuite_PaginationLog (record_type, logged_at);

    PRINT N'Created dbo.[tb_Netsuite_PaginationLog]';
END
ELSE
    PRINT N'Skipped dbo.[tb_Netsuite_PaginationLog] (already exists)';
GO

CREATE OR ALTER PROCEDURE dbo.usp_Netsuite_VendorBill_ResetPaging
    @record_type        nvarchar(50) = N'vendorBill',
    @full_load          bit          = 0,
    @last_modified_from datetime2(0) = NULL,
    @page_size          int          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @now datetime2(0) = SYSUTCDATETIME(), @msg nvarchar(2048);

    IF @page_size IS NOT NULL AND @page_size NOT BETWEEN 1 AND 1000
        THROW 50010, N'@page_size must be between 1 and 1000.', 1;

    BEGIN TRANSACTION;

    UPDATE dbo.tb_Netsuite_PaginationSettings
    SET current_offset        = 0,
        total_results         = NULL,
        has_more              = 1,
        page_size             = ISNULL(@page_size, page_size),
        last_modified_from    = CASE WHEN @full_load = 1 THEN NULL
                                     ELSE ISNULL(@last_modified_from, last_modified_from) END,
        last_run_started_at   = @now,
        last_run_completed_at = NULL,
        updated_at            = @now
    WHERE record_type = @record_type;

    IF @@ROWCOUNT = 0
    BEGIN
        SET @msg = N'No pagination settings found for record type ''' + @record_type + N'''.';
        THROW 50011, @msg, 1;
    END

    INSERT INTO dbo.tb_Netsuite_PaginationLog
        (record_type, event_type, run_started_at, page_offset, page_size, last_modified_from)
    SELECT record_type, N'reset', last_run_started_at, current_offset, page_size, last_modified_from
    FROM dbo.tb_Netsuite_PaginationSettings
    WHERE record_type = @record_type;

    COMMIT TRANSACTION;

    SELECT id, record_type, is_enabled, page_size, current_offset, total_results, has_more,
           last_modified_from, last_run_started_at, last_run_completed_at, updated_at
    FROM dbo.tb_Netsuite_PaginationSettings
    WHERE record_type = @record_type;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Netsuite_VendorBill_UpdatePaging
    @offset         int,
    @rows_fetched   int,
    @has_more       bit,
    @total_results  int          = NULL,
    @record_type    nvarchar(50) = N'vendorBill'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @now datetime2(0) = SYSUTCDATETIME(), @msg nvarchar(2048),
            @stored_offset int, @stored_has_more bit, @run_started_at datetime2(0);

    IF @offset IS NULL OR @offset < 0
        THROW 50020, N'@offset must be 0 or greater.', 1;
    IF @rows_fetched IS NULL OR @rows_fetched < 0
        THROW 50021, N'@rows_fetched must be 0 or greater.', 1;
    IF @has_more IS NULL
        THROW 50022, N'@has_more is required.', 1;
    IF @total_results < 0
        THROW 50023, N'@total_results must be 0 or greater.', 1;

    BEGIN TRANSACTION;

    SELECT @stored_offset = current_offset, @stored_has_more = has_more,
           @run_started_at = last_run_started_at
    FROM dbo.tb_Netsuite_PaginationSettings WITH (UPDLOCK, HOLDLOCK)
    WHERE record_type = @record_type;

    IF @stored_offset IS NULL
    BEGIN
        SET @msg = N'No pagination settings found for record type ''' + @record_type + N'''.';
        THROW 50024, @msg, 1;
    END

    IF @stored_has_more = 0
    BEGIN
        SET @msg = N'No run in progress for ''' + @record_type
                 + N'''; call usp_Netsuite_VendorBill_ResetPaging first.';
        THROW 50026, @msg, 1;
    END

    IF @stored_offset <> @offset
    BEGIN
        SET @msg = N'Page at offset ' + CAST(@offset AS nvarchar(12)) + N' for ''' + @record_type
                 + N''' is out of order: expected offset ' + CAST(@stored_offset AS nvarchar(12)) + N'.';
        THROW 50025, @msg, 1;
    END

    INSERT INTO dbo.tb_Netsuite_PaginationLog
        (record_type, event_type, run_started_at, page_offset, page_size, rows_fetched,
         total_results, has_more, last_modified_from)
    SELECT record_type, N'page', last_run_started_at, @offset, page_size, @rows_fetched,
           ISNULL(@total_results, total_results), @has_more, last_modified_from
    FROM dbo.tb_Netsuite_PaginationSettings
    WHERE record_type = @record_type;

    IF @has_more = 1
    BEGIN
        UPDATE dbo.tb_Netsuite_PaginationSettings
        SET current_offset = @offset + @rows_fetched,
            total_results  = ISNULL(@total_results, total_results),
            has_more       = 1,
            updated_at     = @now
        WHERE record_type = @record_type;
    END
    ELSE
    BEGIN
        -- Last page: close the run and move the watermark to when it started
        UPDATE dbo.tb_Netsuite_PaginationSettings
        SET current_offset        = 0,
            total_results         = ISNULL(@total_results, total_results),
            has_more              = 0,
            last_modified_from    = ISNULL(@run_started_at, last_modified_from),
            last_run_completed_at = @now,
            updated_at            = @now
        WHERE record_type = @record_type;

        INSERT INTO dbo.tb_Netsuite_PaginationLog
            (record_type, event_type, run_started_at, page_offset, page_size,
             total_results, has_more, last_modified_from)
        SELECT record_type, N'completed', @run_started_at, @offset + @rows_fetched, page_size,
               total_results, 0, last_modified_from
        FROM dbo.tb_Netsuite_PaginationSettings
        WHERE record_type = @record_type;
    END

    COMMIT TRANSACTION;

    SELECT id, record_type, is_enabled, page_size, current_offset, total_results, has_more,
           last_modified_from, last_run_started_at, last_run_completed_at, updated_at
    FROM dbo.tb_Netsuite_PaginationSettings
    WHERE record_type = @record_type;
END
GO

/*
    Example sync loop:

    EXEC dbo.usp_Netsuite_VendorBill_ResetPaging;                    -- incremental
    EXEC dbo.usp_Netsuite_VendorBill_ResetPaging @full_load = 1;     -- full reload

    -- after fetching each page from NetSuite (offset 0, 1000, 2000, ...):
    EXEC dbo.usp_Netsuite_VendorBill_UpdatePaging
        @offset = 0, @rows_fetched = 1000, @total_results = 2350, @has_more = 1;
*/
