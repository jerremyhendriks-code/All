/*
    End-to-end test for the vendor bill staging procedures.
    Run in a SCRATCH database after:
      sql/netsuite_vendorbill_staging_tables.sql
      sql/usp_Netsuite_VendorBill_Load.sql
      sql/usp_Netsuite_VendorBillLine_Load.sql
      sql/usp_Netsuite_VendorBill_Run.sql
      sql/usp_Netsuite_VendorBill_Import.sql
    It empties dbo.tb_Netsuite_VendorBill and dbo.tb_Netsuite_VendorBillLine.
    Prints PASS/FAIL per check and ends with an error if anything failed.
*/
SET NOCOUNT ON;
IF DB_NAME() IN (N'master', N'model', N'msdb', N'tempdb') THROW 50000, N'Run this in a scratch database.', 1;

DELETE FROM dbo.tb_Netsuite_VendorBillLine;
DELETE FROM dbo.tb_Netsuite_VendorBill;

DECLARE @fail int = 0, @run datetime2(3), @err nvarchar(2048);
DECLARE @r TABLE (rows_in_page int, rows_inserted int, rows_updated int, has_more bit, next_offset int);
DECLARE @headers nvarchar(max) = N'<?xml version="1.0" encoding="utf-16"?>
<root xmlns="http://www.orbis-software.com/WebSvcCon">
  <links Array="true">
    <rel>next</rel>
    <href>https://1234567.suitetalk.api.netsuite.com/services/rest/query/v1/suiteql?limit=2&amp;offset=2</href>
  </links>
  <links Array="true">
    <rel>self</rel>
    <href>https://1234567.suitetalk.api.netsuite.com/services/rest/query/v1/suiteql?limit=2&amp;offset=0</href>
  </links>
  <count>2</count>
  <hasMore>true</hasMore>
  <items Array="true">
    <amount_open>1210.5</amount_open>
    <ap_account_id>111</ap_account_id>
    <ap_account_name>2000 Accounts Payable</ap_account_name>
    <approval_status_id>2</approval_status_id>
    <approval_status_name>Approved</approval_status_name>
    <bill_date>2026-09-14</bill_date>
    <bill_number>VENDBILL1001</bill_number>
    <bill_total>1210.5</bill_total>
    <created_date>2026-09-14 10:02:11</created_date>
    <currency_id>1</currency_id>
    <currency_name>EUR</currency_name>
    <due_date>2026-10-14</due_date>
    <exchange_rate>1</exchange_rate>
    <is_posting>T</is_posting>
    <is_voided>F</is_voided>
    <last_modified>2026-09-15 08:30:00</last_modified>
    <memo>Office supplies Q3 &amp; "toner" for Jan''s printer</memo>
    <posting_period_id>145</posting_period_id>
    <posting_period_name>Sep 2026</posting_period_name>
    <status_code>A</status_code>
    <status_name>Bill : Open</status_name>
    <subsidiary_id>3</subsidiary_id>
    <subsidiary_name>Parent : NL BV</subsidiary_name>
    <terms_id>2</terms_id>
    <terms_name>Net 30</terms_name>
    <vendor_bill_id>98765</vendor_bill_id>
    <vendor_id>4321</vendor_id>
    <vendor_invoice_number>INV-2026-0042</vendor_invoice_number>
    <vendor_name>Kantoorhuis B.V.</vendor_name>
  </items>
  <items Array="true">
    <vendor_bill_id>98766</vendor_bill_id>
    <bill_number>VENDBILL1002</bill_number>
    <bill_date>2026-09-20</bill_date>
    <vendor_id>4322</vendor_id>
    <vendor_name>Müller GmbH</vendor_name>
    <currency_id>2</currency_id>
    <currency_name>USD</currency_name>
    <exchange_rate>0.9123456789</exchange_rate>
    <bill_total>2.5E3</bill_total>
    <amount_open>2500</amount_open>
    <subsidiary_id>3</subsidiary_id>
    <status_code>A</status_code>
    <is_posting>F</is_posting>
    <is_voided>F</is_voided>
    <last_modified>2026-09-20 16:45:59</last_modified>
  </items>
  <offset>0</offset>
  <totalResults>2</totalResults>
</root>
';
DECLARE @lines nvarchar(max) = N'<?xml version="1.0" encoding="utf-16"?>
<root xmlns="http://www.orbis-software.com/WebSvcCon">
  <links Array="true">
    <rel>self</rel>
    <href>https://1234567.suitetalk.api.netsuite.com/services/rest/query/v1/suiteql?limit=1000&amp;offset=0</href>
  </links>
  <count>4</count>
  <hasMore>false</hasMore>
  <items Array="true">
    <account_id>612</account_id>
    <account_name>6100 Office Supplies</account_name>
    <amount>1000</amount>
    <base_amount>1000</base_amount>
    <department_id>7</department_id>
    <department_name>Finance</department_name>
    <line_id>1</line_id>
    <line_number>1</line_number>
    <line_type>expense</line_type>
    <memo>Paper</memo>
    <vendor_bill_id>98765</vendor_bill_id>
  </items>
  <items Array="true">
    <account_id>612</account_id>
    <amount>0.5</amount>
    <line_id>2</line_id>
    <line_number>2</line_number>
    <line_type>expense</line_type>
    <vendor_bill_id>98765</vendor_bill_id>
  </items>
  <items Array="true">
    <account_id>1510</account_id>
    <amount>210</amount>
    <base_amount>210</base_amount>
    <line_id>3</line_id>
    <line_number>3</line_number>
    <line_type>tax</line_type>
    <vendor_bill_id>98765</vendor_bill_id>
  </items>
  <items Array="true">
    <item_id>55</item_id>
    <item_name>Widget</item_name>
    <quantity>10</quantity>
    <rate>250</rate>
    <amount>2500</amount>
    <line_id>1</line_id>
    <line_number>1</line_number>
    <line_type>item</line_type>
    <vendor_bill_id>98766</vendor_bill_id>
  </items>
  <offset>0</offset>
  <totalResults>4</totalResults>
</root>
';

------------------------------------------------------------------------
-- Run 1: initial load
------------------------------------------------------------------------
DECLARE @b TABLE (run_started_at datetime2(3), since char(19));
INSERT INTO @b EXEC dbo.usp_Netsuite_VendorBill_BeginRun;
SELECT @run = run_started_at FROM @b;
IF (SELECT since FROM @b) <> '1900-01-01 00:00:00' BEGIN SET @fail += 1; PRINT 'FAIL since on empty staging'; END ELSE PRINT 'PASS since on empty staging';

INSERT INTO @r EXEC dbo.usp_Netsuite_VendorBill_Import @record_type = N'header', @xml_text = @headers;
IF NOT EXISTS (SELECT 1 FROM @r WHERE rows_in_page = 2 AND rows_inserted = 2 AND rows_updated = 0 AND has_more = 1 AND next_offset = 2)
    BEGIN SET @fail += 1; PRINT 'FAIL header page result row'; END ELSE PRINT 'PASS header page result row';

IF NOT EXISTS (SELECT 1 FROM dbo.tb_Netsuite_VendorBill
               WHERE id = N'98765' AND bill_number = N'VENDBILL1001' AND vendor_invoice_number = N'INV-2026-0042'
                 AND bill_date = '2026-09-14' AND due_date = '2026-10-14' AND bill_total = 1210.50 AND amount_open = 1210.50
                 AND memo = N'Office supplies Q3 & "toner" for Jan''s printer' AND is_posting = 1 AND is_voided = 0
                 AND last_modified = '2026-09-15 08:30:00' AND ap_account_name = N'2000 Accounts Payable' AND is_stale = 0)
    BEGIN SET @fail += 1; PRINT 'FAIL bill 98765 values'; END ELSE PRINT 'PASS bill 98765 values';

IF NOT EXISTS (SELECT 1 FROM dbo.tb_Netsuite_VendorBill
               WHERE id = N'98766' AND vendor_name = N'Müller GmbH' AND bill_total = 2500 AND exchange_rate = 0.9123456789
                 AND due_date IS NULL AND memo IS NULL AND is_posting = 0)
    BEGIN SET @fail += 1; PRINT 'FAIL bill 98766 values (exponent, unicode, omitted nulls)'; END ELSE PRINT 'PASS bill 98766 values (exponent, unicode, omitted nulls)';

DELETE FROM @r;
INSERT INTO @r EXEC dbo.usp_Netsuite_VendorBill_Import @record_type = N'lines', @xml_text = @lines;
IF NOT EXISTS (SELECT 1 FROM @r WHERE rows_in_page = 4 AND rows_inserted = 4 AND has_more = 0)
    BEGIN SET @fail += 1; PRINT 'FAIL lines page result row'; END ELSE PRINT 'PASS lines page result row';
IF (SELECT SUM(amount) FROM dbo.tb_Netsuite_VendorBillLine WHERE vendor_bill_id = N'98765') <> 1210.50
    BEGIN SET @fail += 1; PRINT 'FAIL line amounts add up to bill total'; END ELSE PRINT 'PASS line amounts add up to bill total';

DECLARE @f TABLE (lines_deleted int, bills_marked_stale int);
INSERT INTO @f EXEC dbo.usp_Netsuite_VendorBill_Finalize @run_started_at = @run;
IF NOT EXISTS (SELECT 1 FROM @f WHERE lines_deleted = 0 AND bills_marked_stale = 0)
    BEGIN SET @fail += 1; PRINT 'FAIL finalize run 1 changes nothing'; END ELSE PRINT 'PASS finalize run 1 changes nothing';

------------------------------------------------------------------------
-- Run 2: 98765 modified (line 2 removed, partly paid), 98766 paid and
-- not returned any more. Header XML without declaration or namespace.
------------------------------------------------------------------------
WAITFOR DELAY '00:00:00.020';
DELETE FROM @b;
INSERT INTO @b EXEC dbo.usp_Netsuite_VendorBill_BeginRun;
SELECT @run = run_started_at FROM @b;
IF (SELECT since FROM @b) <> '2026-09-19 16:45:59' BEGIN SET @fail += 1; PRINT 'FAIL since = max last_modified - 1 day'; END ELSE PRINT 'PASS since = max last_modified - 1 day';

DELETE FROM @r;
INSERT INTO @r EXEC dbo.usp_Netsuite_VendorBill_Load @xml_text = N'<root><count>1</count><hasMore>false</hasMore>
  <items Array="true"><vendor_bill_id>98765</vendor_bill_id><bill_total>1210.5</bill_total><amount_open>200</amount_open>
  <status_code>A</status_code><last_modified>2026-10-01 09:00:00</last_modified></items>
  <offset>0</offset><totalResults>1</totalResults></root>';
IF NOT EXISTS (SELECT 1 FROM @r WHERE rows_inserted = 0 AND rows_updated = 1 AND next_offset = 1)
    BEGIN SET @fail += 1; PRINT 'FAIL update result row'; END ELSE PRINT 'PASS update result row';
IF NOT EXISTS (SELECT 1 FROM dbo.tb_Netsuite_VendorBill WHERE id = N'98765' AND amount_open = 200 AND memo IS NULL AND first_loaded_at < last_loaded_at)
    BEGIN SET @fail += 1; PRINT 'FAIL bill updated (omitted field becomes NULL)'; END ELSE PRINT 'PASS bill updated (omitted field becomes NULL)';

DELETE FROM @r;
INSERT INTO @r EXEC dbo.usp_Netsuite_VendorBillLine_Load @xml_text = N'<?xml version="1.0" encoding="utf-8"?>
<root xmlns="http://www.orbis-software.com/WebSvcCon"><count>2</count><hasMore>false</hasMore>
  <items Array="true"><vendor_bill_id>98765</vendor_bill_id><line_id>1</line_id><amount>1000.5</amount></items>
  <items Array="true"><vendor_bill_id>98765</vendor_bill_id><line_id>3</line_id><amount>210</amount></items>
  <offset>0</offset><totalResults>2</totalResults></root>';

DELETE FROM @f;
INSERT INTO @f EXEC dbo.usp_Netsuite_VendorBill_Finalize @run_started_at = @run;
IF NOT EXISTS (SELECT 1 FROM @f WHERE lines_deleted = 1 AND bills_marked_stale = 1)
    BEGIN SET @fail += 1; PRINT 'FAIL finalize run 2 result'; END ELSE PRINT 'PASS finalize run 2 result';
IF EXISTS (SELECT 1 FROM dbo.tb_Netsuite_VendorBillLine WHERE vendor_bill_id = N'98765' AND line_id = N'2')
    BEGIN SET @fail += 1; PRINT 'FAIL removed line deleted'; END ELSE PRINT 'PASS removed line deleted';
IF NOT EXISTS (SELECT 1 FROM dbo.tb_Netsuite_VendorBillLine WHERE vendor_bill_id = N'98766' AND line_id = N'1')
    BEGIN SET @fail += 1; PRINT 'FAIL lines of bills not in this run kept'; END ELSE PRINT 'PASS lines of bills not in this run kept';
IF NOT EXISTS (SELECT 1 FROM dbo.tb_Netsuite_VendorBill WHERE id = N'98766' AND is_stale = 1)
   OR EXISTS (SELECT 1 FROM dbo.tb_Netsuite_VendorBill WHERE id = N'98765' AND is_stale = 1)
    BEGIN SET @fail += 1; PRINT 'FAIL stale flag'; END ELSE PRINT 'PASS stale flag';

------------------------------------------------------------------------
-- Errors: bad page writes nothing; empty page is fine
------------------------------------------------------------------------
BEGIN TRY
    EXEC dbo.usp_Netsuite_VendorBill_Load @xml_text = N'<root><count>2</count><hasMore>false</hasMore>
      <items><vendor_bill_id>1</vendor_bill_id><bill_total>5</bill_total></items>
      <items><vendor_bill_id>2</vendor_bill_id><bill_date>14-09-2026</bill_date></items>
      <offset>0</offset><totalResults>2</totalResults></root>';
    SET @fail += 1; PRINT 'FAIL bad date accepted';
END TRY
BEGIN CATCH
    SET @err = ERROR_MESSAGE();
    IF @err LIKE N'%vendor bill 2, value not convertible: bill_date = 14-09-2026%'
       AND NOT EXISTS (SELECT 1 FROM dbo.tb_Netsuite_VendorBill WHERE id IN (N'1', N'2'))
        PRINT 'PASS bad date rejected, page not written';
    ELSE BEGIN SET @fail += 1; PRINT 'FAIL bad date: ' + @err; END
END CATCH

BEGIN TRY
    EXEC dbo.usp_Netsuite_VendorBillLine_Load @xml_text = N'<root><count>2</count><hasMore>false</hasMore>
      <items><vendor_bill_id>1</vendor_bill_id><line_id>1</line_id></items>
      <items><vendor_bill_id>1</vendor_bill_id><line_id>1</line_id></items>
      <offset>0</offset><totalResults>2</totalResults></root>';
    SET @fail += 1; PRINT 'FAIL duplicate line accepted';
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 50113 PRINT 'PASS duplicate line rejected';
    ELSE BEGIN SET @fail += 1; PRINT 'FAIL duplicate line: ' + ERROR_MESSAGE(); END
END CATCH

BEGIN TRY
    EXEC dbo.usp_Netsuite_VendorBill_Import @record_type = N'header', @xml_text = N'<root/>', @file_path = N'x.xml';
    SET @fail += 1; PRINT 'FAIL import with both inputs accepted';
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 50132 PRINT 'PASS import with both inputs rejected';
    ELSE BEGIN SET @fail += 1; PRINT 'FAIL import with both inputs: ' + ERROR_MESSAGE(); END
END CATCH

DELETE FROM @r;
INSERT INTO @r EXEC dbo.usp_Netsuite_VendorBill_Load @xml_text = N'<root xmlns="http://www.orbis-software.com/WebSvcCon"><links Array="true"><rel>self</rel><href>x</href></links><count>0</count><hasMore>false</hasMore><offset>0</offset><totalResults>0</totalResults></root>';
IF NOT EXISTS (SELECT 1 FROM @r WHERE rows_in_page = 0 AND has_more = 0 AND next_offset = 0)
    BEGIN SET @fail += 1; PRINT 'FAIL empty page'; END ELSE PRINT 'PASS empty page';

IF @fail > 0 BEGIN SET @err = CAST(@fail AS nvarchar(10)) + N' check(s) failed'; THROW 50001, @err, 1; END
PRINT 'All checks passed';
