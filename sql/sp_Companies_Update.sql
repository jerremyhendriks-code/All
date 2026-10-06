/*
    dbo.sp_Companies_Update

    End of a run of an object: sets BPA_Status = 1 and moves DateFilter forward
    to the latest lastmodifieddate fetched for that object, minus @OverlapDays.

    - The latest value comes from the staging table, so it's NetSuite's own
      clock: no time-zone difference with this server.
    - The overlap catches records that were changed while the run was paging
      (an earlier page already fetched, its record edited before a later page
      was fetched). Records picked up twice are harmless (the views take the
      latest row).
    - The staging table is tb_ + @BPA_Origin (BPA_Origin 'NetSuite_vendorBill'
      -> dbo.tb_NetSuite_vendorBill, which matches tb_Netsuite_VendorBill in a
      case-insensitive database). @ModifiedColumn is the column holding the
      lastmodifieddate (default last_modified, the alias in the SuiteQL).
    - Fails, changing nothing, when that table or column doesn't exist, so a
      typo in the origin doesn't silently leave the filter where it was.
    - Nothing in staging yet (NULL): DateFilter stays as it is.

    BPA_Company NULL matches the row whose BPA_Company is NULL
    (BPA_Company = NULL is never true in SQL).
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Companies_Update
    @BPA_Origin     nvarchar(50),
    @BPA_Company    nvarchar(50) = NULL,
    @OverlapDays    int          = 1,
    @ModifiedColumn sysname      = N'last_modified'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @MaxModified datetime, @table nvarchar(300), @sql nvarchar(max), @msg nvarchar(2048);

    -- A parameter value typed as NULL in TaskCentre may arrive as the text 'NULL'
    IF @BPA_Company = N'NULL' OR LTRIM(RTRIM(@BPA_Company)) = N''
        SET @BPA_Company = NULL;

    -- Staging table of this object: tb_<BPA_Origin>
    SET @table = N'dbo.' + QUOTENAME(N'tb_' + @BPA_Origin);

    IF OBJECT_ID(@table, N'U') IS NULL
    BEGIN
        SET @msg = N'sp_Companies_Update: staging table ' + @table + N' for BPA_Origin '''
                 + ISNULL(@BPA_Origin, N'NULL') + N''' does not exist; nothing changed.';
        THROW 50511, @msg, 1;
    END

    IF COL_LENGTH(@table, @ModifiedColumn) IS NULL
    BEGIN
        SET @msg = N'sp_Companies_Update: ' + @table + N' has no column ' + QUOTENAME(@ModifiedColumn)
                 + N'; nothing changed.';
        THROW 50512, @msg, 1;
    END

    -- Text 'YYYY-MM-DD HH:MI:SS' (BPA_ImportXml stores everything as text) or a date type
    SET @sql = N'SELECT @max = MAX(TRY_CONVERT(datetime, ' + QUOTENAME(@ModifiedColumn) + N', 120)) FROM ' + @table + N';';
    EXEC sys.sp_executesql @sql, N'@max datetime OUTPUT', @max = @MaxModified OUTPUT;

    UPDATE dbo.tb_Companies
    SET BPA_Status      = 1,
        BPA_Sysmodified = GETDATE(),
        DateFilter      = ISNULL(DATEADD(day, -ABS(@OverlapDays), @MaxModified), DateFilter)
    WHERE BPA_Origin = @BPA_Origin
      AND (BPA_Company = @BPA_Company OR (BPA_Company IS NULL AND @BPA_Company IS NULL));

    SELECT rows_updated = @@ROWCOUNT, max_last_modified = @MaxModified;
END
GO
