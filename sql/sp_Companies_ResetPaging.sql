/*
    dbo.sp_Companies_ResetPaging

    For the "Else" branch of the MoreRecords decision: the last page said
    <hasMore>false</hasMore> (sp_Companies_UpdateOffset set MoreRecords = 0),
    so the run of this object is complete.

    Updates the object's row in dbo.tb_Companies:
      - BPA_Status      = 1         (run finished)
      - Offset          = 0         (next run starts at the first page)
      - MoreRecords     = 0
      - BPA_Sysmodified = GETDATE()

    DateFilter isn't touched here: dbo.sp_Companies_Update moves it forward
    (latest fetched lastmodifieddate minus an overlap).

    The row is found by @BPA_Origin (e.g. 'NetSuite_vendorBill') and
    @BPA_Company (NULL = the row without company). Exactly one row must match,
    otherwise nothing is changed and the call fails, so a typo in the origin
    doesn't go unnoticed.

    Returns rows_updated.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Companies_ResetPaging
    @BPA_Origin  nvarchar(50),
    @BPA_Company nvarchar(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @rows int, @msg nvarchar(2048);

    -- A parameter value typed as NULL in TaskCentre may arrive as the text 'NULL'
    IF @BPA_Company = N'NULL' OR LTRIM(RTRIM(@BPA_Company)) = N''
        SET @BPA_Company = NULL;

    BEGIN TRANSACTION;

    UPDATE dbo.tb_Companies
    SET BPA_Status      = 1,
        Offset          = 0,
        MoreRecords     = 0,
        BPA_Sysmodified = GETDATE()
    WHERE BPA_Origin = @BPA_Origin
      AND (BPA_Company = @BPA_Company OR (@BPA_Company IS NULL AND BPA_Company IS NULL));

    SET @rows = @@ROWCOUNT;

    IF @rows <> 1
    BEGIN
        ROLLBACK TRANSACTION;
        SET @msg = N'sp_Companies_ResetPaging: expected 1 row in tb_Companies for BPA_Origin = '''
                 + ISNULL(@BPA_Origin, N'NULL') + N''', BPA_Company = '
                 + ISNULL(N'''' + @BPA_Company + N'''', N'NULL') + N', found '
                 + CAST(@rows AS nvarchar(12)) + N'; nothing changed.';
        THROW 50501, @msg, 1;
    END

    COMMIT TRANSACTION;

    SELECT rows_updated = @rows;
END
GO
