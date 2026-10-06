/*
    Paging state for SuiteQL loops that restart themselves (TaskCentre "Start Self").

    Each restart of the task loses its variables, so the offset and the "since"
    filter of the run in progress live in dbo.tb_Netsuite_SuiteQL_Run, one row
    per query (e.g. 'vendorbill_header', 'vendorbill_lines').

    dbo.usp_Netsuite_SuiteQL_GetPaging  @QueryName, @SinceFromQuery = NULL, @Restart = 0
        Call at the start of the task, instead of computing the filter there.
        - A run of this query is in progress: returns its filter and offset
          (the restart continues where the previous page left off).
        - Otherwise starts a new run at offset 0 with a new filter:
            * @SinceFromQuery given: the filter of that query's latest run, so
              the lines run uses exactly the same filter as the header run.
            * else: latest last_modified in dbo.vw_Netsuite_VendorBill minus one
              day, or '1900-01-01 00:00:00' when staging is empty.
        - @Restart = 1 abandons a run in progress and starts a new one.
        Returns Incremental_Filter, Offset, Page_Number, Run_Started_At.

    dbo.usp_Netsuite_SuiteQL_AdvancePaging  @QueryName, @XmlText, @PageSize = 1000
        Call after the page was imported without errors, with the same
        Web Service Connector output.
        - Checks the page's <offset> is the run's current offset (refuses a page
          from another offset, so no page is silently skipped or doubled).
        - Next offset = <offset> + <count>.
        - The run is finished when <hasMore> is false OR <count> < @PageSize.
          (count < 1000 alone misses a total that is an exact multiple of 1000;
          hasMore alone is enough, the count check is an extra safety.)
        Returns Continue_Loop (1 = run 'Start Self' again, 0 = done),
        Next_Offset, Page_Number.

    A failed page leaves the run 'running' at the offset of that page: the next
    task run retries it with the same filter. Rows imported twice that way are
    harmless; the views take the latest row per bill / line.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'dbo.tb_Netsuite_SuiteQL_Run', N'U') IS NULL
    CREATE TABLE dbo.tb_Netsuite_SuiteQL_Run (
        query_name         nvarchar(100) NOT NULL CONSTRAINT PK_tb_Netsuite_SuiteQL_Run PRIMARY KEY,
        incremental_filter char(19)      NOT NULL,     -- 'YYYY-MM-DD HH:MI:SS' for {{since}}
        next_offset        int           NOT NULL,
        page_number        int           NOT NULL,     -- pages imported in this run
        status             nvarchar(10)  NOT NULL,     -- 'running' / 'done'
        run_started_at     datetime      NOT NULL,
        run_finished_at    datetime      NULL,
        last_page_at       datetime      NULL
    );
GO

CREATE OR ALTER PROCEDURE dbo.usp_Netsuite_SuiteQL_GetPaging
    @QueryName      nvarchar(100),
    @SinceFromQuery nvarchar(100) = NULL,
    @Restart        bit           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @since char(19), @msg nvarchar(2048);

    IF NULLIF(LTRIM(RTRIM(@QueryName)), N'') IS NULL
        THROW 50401, N'usp_Netsuite_SuiteQL_GetPaging: @QueryName is required.', 1;

    BEGIN TRANSACTION;

    IF @Restart = 1
       OR NOT EXISTS (SELECT 1 FROM dbo.tb_Netsuite_SuiteQL_Run WITH (UPDLOCK, HOLDLOCK)
                      WHERE query_name = @QueryName AND status = N'running')
    BEGIN
        IF @SinceFromQuery IS NOT NULL
        BEGIN
            SELECT @since = incremental_filter
            FROM dbo.tb_Netsuite_SuiteQL_Run
            WHERE query_name = @SinceFromQuery;

            IF @since IS NULL
            BEGIN
                SET @msg = N'usp_Netsuite_SuiteQL_GetPaging: no run of ''' + @SinceFromQuery + N''' to take the filter from.';
                ROLLBACK TRANSACTION;
                THROW 50402, @msg, 1;
            END
        END
        ELSE
            SELECT @since = CONVERT(char(19), ISNULL(DATEADD(day, -1, MAX(last_modified)), '19000101'), 120)
            FROM dbo.vw_Netsuite_VendorBill;

        UPDATE dbo.tb_Netsuite_SuiteQL_Run
        SET incremental_filter = @since, next_offset = 0, page_number = 0, status = N'running',
            run_started_at = GETDATE(), run_finished_at = NULL, last_page_at = NULL
        WHERE query_name = @QueryName;

        IF @@ROWCOUNT = 0
            INSERT INTO dbo.tb_Netsuite_SuiteQL_Run
                (query_name, incremental_filter, next_offset, page_number, status, run_started_at)
            VALUES (@QueryName, @since, 0, 0, N'running', GETDATE());
    END

    COMMIT TRANSACTION;

    SELECT Incremental_Filter = incremental_filter,
           Offset             = next_offset,
           Page_Number        = page_number,
           Run_Started_At     = run_started_at
    FROM dbo.tb_Netsuite_SuiteQL_Run
    WHERE query_name = @QueryName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Netsuite_SuiteQL_AdvancePaging
    @QueryName nvarchar(100),
    @XmlText   nvarchar(max),
    @PageSize  int = 1000
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @xml xml, @decl int, @msg nvarchar(2048),
            @count int, @offset int, @has_more bit, @expected int, @done bit;

    -- Drop the XML declaration, if any
    SET @decl = CHARINDEX(N'<?xml', @XmlText);
    IF @decl BETWEEN 1 AND 10
        SET @XmlText = STUFF(@XmlText, 1, CHARINDEX(N'?>', @XmlText, @decl) + 1, N'');

    SET @xml = CONVERT(xml, @XmlText);

    SELECT @count    = @xml.value(N'(//*:root/*:count/text())[1]',  N'int'),
           @offset   = @xml.value(N'(//*:root/*:offset/text())[1]', N'int'),
           @has_more = CASE LOWER(@xml.value(N'(//*:root/*:hasMore/text())[1]', N'nvarchar(10)'))
                           WHEN N'true' THEN 1 WHEN N'1' THEN 1 ELSE 0 END;

    IF @count IS NULL OR @offset IS NULL
        THROW 50411, N'usp_Netsuite_SuiteQL_AdvancePaging: <count> or <offset> missing; is this Web Service Connector output?', 1;

    BEGIN TRANSACTION;

    SELECT @expected = next_offset
    FROM dbo.tb_Netsuite_SuiteQL_Run WITH (UPDLOCK, HOLDLOCK)
    WHERE query_name = @QueryName AND status = N'running';

    IF @expected IS NULL
    BEGIN
        SET @msg = N'usp_Netsuite_SuiteQL_AdvancePaging: no running run of ''' + @QueryName
                 + N'''; call usp_Netsuite_SuiteQL_GetPaging first.';
        ROLLBACK TRANSACTION;
        THROW 50412, @msg, 1;
    END

    IF @offset <> @expected
    BEGIN
        SET @msg = N'usp_Netsuite_SuiteQL_AdvancePaging: page has offset ' + CAST(@offset AS nvarchar(12))
                 + N' but the run of ''' + @QueryName + N''' is at offset ' + CAST(@expected AS nvarchar(12))
                 + N'; did the request use the Offset from usp_Netsuite_SuiteQL_GetPaging?';
        ROLLBACK TRANSACTION;
        THROW 50413, @msg, 1;
    END

    SET @done = CASE WHEN @has_more = 0 OR @count < @PageSize THEN 1 ELSE 0 END;

    UPDATE dbo.tb_Netsuite_SuiteQL_Run
    SET next_offset     = @offset + @count,
        page_number     = page_number + 1,
        last_page_at    = GETDATE(),
        status          = CASE WHEN @done = 1 THEN N'done' ELSE N'running' END,
        run_finished_at = CASE WHEN @done = 1 THEN GETDATE() END
    WHERE query_name = @QueryName;

    COMMIT TRANSACTION;

    SELECT Continue_Loop = CAST(1 - @done AS int),
           Next_Offset   = @offset + @count,
           Page_Number   = page_number
    FROM dbo.tb_Netsuite_SuiteQL_Run
    WHERE query_name = @QueryName;
END
GO
