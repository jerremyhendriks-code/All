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
    - Nothing in staging yet (NULL): DateFilter stays as it is.
    - Origins without a staging table here keep their DateFilter; add a branch
      for each new object.

    BPA_Company NULL matches the row whose BPA_Company is NULL
    (BPA_Company = NULL is never true in SQL).
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Companies_Update
    @BPA_Origin  nvarchar(50),
    @BPA_Company nvarchar(50) = NULL,
    @OverlapDays int          = 1
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @MaxModified datetime;

    -- A parameter value typed as NULL in TaskCentre may arrive as the text 'NULL'
    IF @BPA_Company = N'NULL' OR LTRIM(RTRIM(@BPA_Company)) = N''
        SET @BPA_Company = NULL;

    IF @BPA_Origin = N'NetSuite_vendorBill'
        SELECT @MaxModified = MAX(TRY_CONVERT(datetime, last_modified, 120))
        FROM dbo.tb_Netsuite_VendorBill;

    UPDATE dbo.tb_Companies
    SET BPA_Status      = 1,
        BPA_Sysmodified = GETDATE(),
        DateFilter      = ISNULL(DATEADD(day, -ABS(@OverlapDays), @MaxModified), DateFilter)
    WHERE BPA_Origin = @BPA_Origin
      AND (BPA_Company = @BPA_Company OR (BPA_Company IS NULL AND @BPA_Company IS NULL));

    SELECT rows_updated = @@ROWCOUNT, max_last_modified = @MaxModified;
END
GO
