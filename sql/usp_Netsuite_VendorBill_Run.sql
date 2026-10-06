/*
    Start / finish a vendor bill load run.

    dbo.usp_Netsuite_VendorBill_BeginRun
        Call once before the first page. Returns:
        - run_started_at: pass it to usp_Netsuite_VendorBill_Finalize.
        - since: the value for {{since}} in both SuiteQL queries
          (latest last_modified in staging minus @overlap_days, or
          '1900-01-01 00:00:00' when staging is empty or @full_load = 1).

    dbo.usp_Netsuite_VendorBill_Finalize
        Call once after the last header page AND the last line page loaded
        without errors. Don't call it after a failed or partial run.
        - Deletes lines of bills that were (re)loaded in this run but that no
          longer came back, i.e. lines removed from the bill in NetSuite.
        - Sets is_stale = 1 on bills that are open in staging but weren't
          returned by this run. The queries return every open bill, so these
          are no longer open in NetSuite (paid, voided or deleted) without
          having been modified since {{since}}.
        Returns lines_deleted, bills_marked_stale.
*/
-- Same settings as the load procedures (sqlcmd defaults QUOTED_IDENTIFIER to OFF)
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Netsuite_VendorBill_BeginRun
    @full_load    bit = 0,
    @overlap_days int = 1
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @max datetime2(0) = CASE WHEN @full_load = 0
                                     THEN (SELECT MAX(last_modified) FROM dbo.tb_Netsuite_VendorBill) END;

    SELECT run_started_at = SYSUTCDATETIME(),
           since          = CONVERT(char(19), ISNULL(DATEADD(day, -ABS(@overlap_days), @max), '19000101'), 120);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Netsuite_VendorBill_Finalize
    @run_started_at datetime2(3)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @lines_deleted int = 0, @bills_stale int = 0;

    IF @run_started_at IS NULL OR @run_started_at > SYSUTCDATETIME()
        THROW 50121, N'usp_Netsuite_VendorBill_Finalize: @run_started_at must be the run_started_at returned by usp_Netsuite_VendorBill_BeginRun.', 1;

    BEGIN TRANSACTION;

    DELETE l
    FROM dbo.tb_Netsuite_VendorBillLine l
    WHERE (l.last_loaded_at < @run_started_at OR l.last_loaded_at IS NULL)
      AND EXISTS (SELECT 1 FROM dbo.tb_Netsuite_VendorBillLine r
                  WHERE r.vendor_bill_id = l.vendor_bill_id AND r.last_loaded_at >= @run_started_at);
    SET @lines_deleted = @@ROWCOUNT;

    -- Only when this run loaded headers at all: an empty run more likely means
    -- the header pages were skipped than that NetSuite has no open bills.
    IF EXISTS (SELECT 1 FROM dbo.tb_Netsuite_VendorBill WHERE last_loaded_at >= @run_started_at)
    BEGIN
        UPDATE dbo.tb_Netsuite_VendorBill
        SET is_stale = 1
        WHERE is_stale = 0
          AND amount_open > 0
          AND (last_loaded_at < @run_started_at OR last_loaded_at IS NULL);
        SET @bills_stale = @@ROWCOUNT;
    END

    COMMIT TRANSACTION;

    SELECT lines_deleted = @lines_deleted, bills_marked_stale = @bills_stale;
END
GO
