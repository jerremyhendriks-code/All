/*
    Test for sql/usp_Netsuite_SuiteQL_Paging.sql. Run in a SCRATCH database
    after sql/netsuite_vendorbill_bpa_setup.sql (it reads vw_Netsuite_VendorBill)
    and sql/usp_Netsuite_SuiteQL_Paging.sql. It empties dbo.tb_Netsuite_SuiteQL_Run.
    Prints PASS/FAIL per check and ends with an error if anything failed.
*/
SET NOCOUNT ON;
IF DB_NAME() IN (N'master', N'model', N'msdb', N'tempdb') THROW 50000, N'Run this in a scratch database.', 1;

DELETE FROM dbo.tb_Netsuite_SuiteQL_Run;

DECLARE @fail int = 0, @err nvarchar(2048), @since char(19), @x nvarchar(max);
DECLARE @g TABLE (Incremental_Filter char(19), Offset int, Page_Number int, Run_Started_At datetime);
DECLARE @a TABLE (Continue_Loop int, Next_Offset int, Page_Number int);

-- A page as the connector returns it (only the paging elements matter here)
DECLARE @page nvarchar(max) = N'<?xml version="1.0" encoding="utf-16"?>
<root xmlns="http://www.orbis-software.com/WebSvcCon"><count>{count}</count><hasMore>{more}</hasMore>
<items Array="true"><vendor_bill_id>1</vendor_bill_id></items><offset>{offset}</offset><totalResults>2500</totalResults></root>';

------------------------------------------------------------------------
-- Run with 3 pages: 1000, 1000, 500 (restart via GetPaging between pages)
------------------------------------------------------------------------
INSERT INTO @g EXEC dbo.usp_Netsuite_SuiteQL_GetPaging @QueryName = N'vendorbill_header';
SELECT @since = Incremental_Filter FROM @g;
IF NOT EXISTS (SELECT 1 FROM @g WHERE Offset = 0 AND Page_Number = 0 AND LEN(Incremental_Filter) = 19)
    BEGIN SET @fail += 1; PRINT 'FAIL new run starts at offset 0'; END ELSE PRINT 'PASS new run starts at offset 0';

SET @x = REPLACE(REPLACE(REPLACE(@page, N'{count}', N'1000'), N'{more}', N'true'), N'{offset}', N'0');
INSERT INTO @a EXEC dbo.usp_Netsuite_SuiteQL_AdvancePaging @QueryName = N'vendorbill_header',
    @XmlText = @x;
IF NOT EXISTS (SELECT 1 FROM @a WHERE Continue_Loop = 1 AND Next_Offset = 1000 AND Page_Number = 1)
    BEGIN SET @fail += 1; PRINT 'FAIL page 1 advances to 1000'; END ELSE PRINT 'PASS page 1 advances to 1000';

-- "Start Self": the task asks again and must get the same filter, next offset
DELETE FROM @g;
WAITFOR DELAY '00:00:00.010';
INSERT INTO @g EXEC dbo.usp_Netsuite_SuiteQL_GetPaging @QueryName = N'vendorbill_header';
IF NOT EXISTS (SELECT 1 FROM @g WHERE Offset = 1000 AND Incremental_Filter = @since AND Page_Number = 1)
    BEGIN SET @fail += 1; PRINT 'FAIL restart resumes with same filter'; END ELSE PRINT 'PASS restart resumes with same filter';

-- Wrong offset is refused and changes nothing
BEGIN TRY
    SET @x = REPLACE(REPLACE(REPLACE(@page, N'{count}', N'1000'), N'{more}', N'true'), N'{offset}', N'0');
EXEC dbo.usp_Netsuite_SuiteQL_AdvancePaging @QueryName = N'vendorbill_header',
        @XmlText = @x;
    SET @fail += 1; PRINT 'FAIL page with old offset accepted';
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 50413 AND (SELECT next_offset FROM dbo.tb_Netsuite_SuiteQL_Run WHERE query_name = N'vendorbill_header') = 1000
        PRINT 'PASS page with old offset refused';
    ELSE BEGIN SET @fail += 1; PRINT 'FAIL old offset: ' + ERROR_MESSAGE(); END
END CATCH

DELETE FROM @a;
SET @x = REPLACE(REPLACE(REPLACE(@page, N'{count}', N'1000'), N'{more}', N'true'), N'{offset}', N'1000');
INSERT INTO @a EXEC dbo.usp_Netsuite_SuiteQL_AdvancePaging @QueryName = N'vendorbill_header',
    @XmlText = @x;
SET @x = REPLACE(REPLACE(REPLACE(@page, N'{count}', N'500'), N'{more}', N'false'), N'{offset}', N'2000');
INSERT INTO @a EXEC dbo.usp_Netsuite_SuiteQL_AdvancePaging @QueryName = N'vendorbill_header',
    @XmlText = @x;
IF NOT EXISTS (SELECT 1 FROM @a WHERE Continue_Loop = 0 AND Next_Offset = 2500 AND Page_Number = 3)
   OR NOT EXISTS (SELECT 1 FROM dbo.tb_Netsuite_SuiteQL_Run WHERE query_name = N'vendorbill_header' AND status = N'done' AND run_finished_at IS NOT NULL)
    BEGIN SET @fail += 1; PRINT 'FAIL last page (count 500) ends the run'; END ELSE PRINT 'PASS last page (count 500) ends the run';

------------------------------------------------------------------------
-- Lines run takes the header run's filter; total = exact multiple of 1000
------------------------------------------------------------------------
DELETE FROM @g;
INSERT INTO @g EXEC dbo.usp_Netsuite_SuiteQL_GetPaging @QueryName = N'vendorbill_lines', @SinceFromQuery = N'vendorbill_header';
IF NOT EXISTS (SELECT 1 FROM @g WHERE Offset = 0 AND Incremental_Filter = @since)
    BEGIN SET @fail += 1; PRINT 'FAIL lines run uses header filter'; END ELSE PRINT 'PASS lines run uses header filter';

DELETE FROM @a;
SET @x = REPLACE(REPLACE(REPLACE(@page, N'{count}', N'1000'), N'{more}', N'false'), N'{offset}', N'0');
INSERT INTO @a EXEC dbo.usp_Netsuite_SuiteQL_AdvancePaging @QueryName = N'vendorbill_lines',
    @XmlText = @x;
IF NOT EXISTS (SELECT 1 FROM @a WHERE Continue_Loop = 0 AND Next_Offset = 1000)
    BEGIN SET @fail += 1; PRINT 'FAIL hasMore=false ends run even with count = 1000'; END ELSE PRINT 'PASS hasMore=false ends run even with count = 1000';

------------------------------------------------------------------------
-- After a finished run, the next task run starts over at 0; @Restart abandons
------------------------------------------------------------------------
DELETE FROM @g;
INSERT INTO @g EXEC dbo.usp_Netsuite_SuiteQL_GetPaging @QueryName = N'vendorbill_header';
DELETE FROM @a;
SET @x = REPLACE(REPLACE(REPLACE(@page, N'{count}', N'1000'), N'{more}', N'true'), N'{offset}', N'0');
INSERT INTO @a EXEC dbo.usp_Netsuite_SuiteQL_AdvancePaging @QueryName = N'vendorbill_header',
    @XmlText = @x;
DELETE FROM @g;
INSERT INTO @g EXEC dbo.usp_Netsuite_SuiteQL_GetPaging @QueryName = N'vendorbill_header', @Restart = 1;
IF NOT EXISTS (SELECT 1 FROM @g WHERE Offset = 0 AND Page_Number = 0)
    BEGIN SET @fail += 1; PRINT 'FAIL @Restart starts over'; END ELSE PRINT 'PASS @Restart starts over';

BEGIN TRY
    EXEC dbo.usp_Netsuite_SuiteQL_AdvancePaging @QueryName = N'nonexistent',
        @XmlText = N'<root><count>1</count><hasMore>false</hasMore><offset>0</offset></root>';
    SET @fail += 1; PRINT 'FAIL advance without run accepted';
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 50412 PRINT 'PASS advance without run refused';
    ELSE BEGIN SET @fail += 1; PRINT 'FAIL no run: ' + ERROR_MESSAGE(); END
END CATCH

IF @fail > 0 BEGIN SET @err = CAST(@fail AS nvarchar(10)) + N' check(s) failed'; THROW 50001, @err, 1; END
PRINT 'All checks passed';
