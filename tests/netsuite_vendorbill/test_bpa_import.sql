/*
    End-to-end test: NetSuite vendor bill pages (XML strings as the Web Service
    Connector outputs them) -> dbo.usp_Netsuite_VendorBill_ImportXml
    -> dbo.BPA_ImportXml -> staging tables and views.
    Run in a SCRATCH database that has dbo.BPA_ImportXml, after
    sql/netsuite_vendorbill_bpa_setup.sql and sql/usp_Netsuite_VendorBill_ImportXml.sql.
    It empties dbo.tb_Netsuite_VendorBill and dbo.tb_Netsuite_VendorBillLine.
    Prints PASS/FAIL per check and ends with an error if anything failed.
*/
SET NOCOUNT ON;
IF DB_NAME() IN (N'master', N'model', N'msdb', N'tempdb') THROW 50000, N'Run this in a scratch database.', 1;

DELETE FROM dbo.tb_Netsuite_VendorBillLine;
DELETE FROM dbo.tb_Netsuite_VendorBill;

DECLARE @fail int = 0, @err nvarchar(2048);
DECLARE @r TABLE (record_type nvarchar(10), rows_imported int, lines_linked int, has_more bit, next_offset int);
-- Exactly as the connector outputs it: text with a utf-16 declaration
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
-- Run 1
------------------------------------------------------------------------
INSERT INTO @r EXEC dbo.usp_Netsuite_VendorBill_ImportXml @XmlText = @headers;
IF NOT EXISTS (SELECT 1 FROM @r WHERE record_type = N'header' AND rows_imported = 2 AND has_more = 1 AND next_offset = 2)
    BEGIN SET @fail += 1; PRINT 'FAIL header page detected and imported'; END ELSE PRINT 'PASS header page detected and imported';

DELETE FROM @r;
INSERT INTO @r EXEC dbo.usp_Netsuite_VendorBill_ImportXml @XmlText = @lines, @RecordType = N'lines';
IF NOT EXISTS (SELECT 1 FROM @r WHERE record_type = N'lines' AND rows_imported = 4 AND lines_linked = 4 AND has_more = 0 AND next_offset = 4)
    BEGIN SET @fail += 1; PRINT 'FAIL lines page imported and linked'; END ELSE PRINT 'PASS lines page imported and linked';

IF EXISTS (SELECT 1 FROM dbo.tb_Netsuite_VendorBillLine l
           LEFT JOIN dbo.tb_Netsuite_VendorBill h ON h.BPA_EntryID = l.BPA_ParentID
           WHERE h.BPA_EntryID IS NULL OR h.BPA_Reference <> l.BPA_Reference)
    BEGIN SET @fail += 1; PRINT 'FAIL every line points to its own bill (BPA_ParentID)'; END ELSE PRINT 'PASS every line points to its own bill (BPA_ParentID)';

IF NOT EXISTS (SELECT 1 FROM dbo.vw_Netsuite_VendorBill
               WHERE vendor_bill_id = N'98765' AND bill_number = N'VENDBILL1001' AND vendor_invoice_number = N'INV-2026-0042'
                 AND bill_date = '2026-09-14' AND due_date = '2026-10-14' AND bill_total = 1210.50 AND amount_open = 1210.50
                 AND memo = N'Office supplies Q3 & "toner" for Jan''s printer' AND is_posting = 1 AND is_voided = 0
                 AND last_modified = '2026-09-15 08:30:00')
    BEGIN SET @fail += 1; PRINT 'FAIL bill 98765 typed values'; END ELSE PRINT 'PASS bill 98765 typed values';

IF NOT EXISTS (SELECT 1 FROM dbo.vw_Netsuite_VendorBill
               WHERE vendor_bill_id = N'98766' AND vendor_name = N'Müller GmbH' AND bill_total = 2500
                 AND exchange_rate = 0.9123456789 AND due_date IS NULL AND memo IS NULL AND is_posting = 0)
    BEGIN SET @fail += 1; PRINT 'FAIL bill 98766 (exponent, unicode, omitted fields)'; END ELSE PRINT 'PASS bill 98766 (exponent, unicode, omitted fields)';

IF NOT EXISTS (SELECT 1 FROM dbo.tb_Netsuite_VendorBill WHERE BPA_Reference = N'98765' AND BPA_Origin = N'NetSuite' AND BPA_Status = 0)
    BEGIN SET @fail += 1; PRINT 'FAIL BPA columns set'; END ELSE PRINT 'PASS BPA columns set';

IF (SELECT COUNT(*) FROM dbo.vw_Netsuite_VendorBillLine) <> 4
   OR (SELECT SUM(amount) FROM dbo.vw_Netsuite_VendorBillLine WHERE vendor_bill_id = N'98765') <> 1210.50
    BEGIN SET @fail += 1; PRINT 'FAIL run 1 lines in view'; END ELSE PRINT 'PASS run 1 lines in view';

------------------------------------------------------------------------
-- Run 2: 98765 partly paid and line 2 removed; 98766 not returned.
-- utf-8 declaration, no namespace.
------------------------------------------------------------------------
WAITFOR DELAY '00:00:00.050';
DELETE FROM @r;
INSERT INTO @r EXEC dbo.usp_Netsuite_VendorBill_ImportXml @RecordType = N'header', @XmlText = N'<?xml version="1.0" encoding="utf-8"?>
<root><count>1</count><hasMore>false</hasMore>
  <items Array="true"><vendor_bill_id>98765</vendor_bill_id><bill_total>1210.5</bill_total><amount_open>200</amount_open>
  <last_modified>2026-10-01 09:00:00</last_modified></items><offset>0</offset><totalResults>1</totalResults></root>';
INSERT INTO @r EXEC dbo.usp_Netsuite_VendorBill_ImportXml @XmlText = N'<root><count>2</count><hasMore>false</hasMore>
  <items Array="true"><vendor_bill_id>98765</vendor_bill_id><line_id>1</line_id><amount>1000.5</amount></items>
  <items Array="true"><vendor_bill_id>98765</vendor_bill_id><line_id>3</line_id><amount>210</amount></items>
  <offset>0</offset><totalResults>2</totalResults></root>';

IF (SELECT COUNT(*) FROM dbo.tb_Netsuite_VendorBill) <> 3
    BEGIN SET @fail += 1; PRINT 'FAIL raw table keeps every import'; END ELSE PRINT 'PASS raw table keeps every import';
IF (SELECT COUNT(*) FROM dbo.tb_Netsuite_VendorBillLine
    WHERE BPA_Reference = N'98765'
      AND BPA_ParentID = (SELECT TOP (1) BPA_EntryID FROM dbo.tb_Netsuite_VendorBill
                          WHERE BPA_Reference = N'98765' ORDER BY BPA_Syscreated DESC, BPA_EntryID DESC)) <> 2
    BEGIN SET @fail += 1; PRINT 'FAIL run 2 lines linked to run 2 header'; END ELSE PRINT 'PASS run 2 lines linked to run 2 header';
IF NOT EXISTS (SELECT 1 FROM dbo.vw_Netsuite_VendorBill WHERE vendor_bill_id = N'98765' AND amount_open = 200 AND memo IS NULL)
   OR (SELECT COUNT(*) FROM dbo.vw_Netsuite_VendorBill) <> 2
    BEGIN SET @fail += 1; PRINT 'FAIL view shows latest row per bill'; END ELSE PRINT 'PASS view shows latest row per bill';
IF EXISTS (SELECT 1 FROM dbo.vw_Netsuite_VendorBillLine WHERE vendor_bill_id = N'98765' AND line_id = N'2')
   OR (SELECT SUM(amount) FROM dbo.vw_Netsuite_VendorBillLine WHERE vendor_bill_id = N'98765') <> 1210.50
    BEGIN SET @fail += 1; PRINT 'FAIL removed line drops out'; END ELSE PRINT 'PASS removed line drops out';
IF NOT EXISTS (SELECT 1 FROM dbo.vw_Netsuite_VendorBillLine WHERE vendor_bill_id = N'98766' AND line_id = N'1' AND quantity = 10)
    BEGIN SET @fail += 1; PRINT 'FAIL lines of bill not in run 2 kept'; END ELSE PRINT 'PASS lines of bill not in run 2 kept';

------------------------------------------------------------------------
-- Empty page, wrong type, missing keys
------------------------------------------------------------------------
DECLARE @before_h int = (SELECT COUNT(*) FROM dbo.tb_Netsuite_VendorBill),
        @before_l int = (SELECT COUNT(*) FROM dbo.tb_Netsuite_VendorBillLine);

DELETE FROM @r;
INSERT INTO @r EXEC dbo.usp_Netsuite_VendorBill_ImportXml @XmlText = N'<root xmlns="http://www.orbis-software.com/WebSvcCon"><links Array="true"><rel>self</rel><href>x</href></links><count>0</count><hasMore>false</hasMore><offset>0</offset><totalResults>0</totalResults></root>';
IF NOT EXISTS (SELECT 1 FROM @r WHERE rows_imported = 0 AND has_more = 0 AND next_offset = 0)
   OR (SELECT COUNT(*) FROM dbo.tb_Netsuite_VendorBill) <> @before_h
   OR COL_LENGTH(N'dbo.tb_Netsuite_VendorBill', N'rel') IS NOT NULL
    BEGIN SET @fail += 1; PRINT 'FAIL empty page skipped'; END ELSE PRINT 'PASS empty page skipped';

BEGIN TRY
    EXEC dbo.usp_Netsuite_VendorBill_ImportXml @XmlText = @lines, @RecordType = N'header';
    SET @fail += 1; PRINT 'FAIL lines page sent as header accepted';
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 50305 PRINT 'PASS lines page sent as header refused';
    ELSE BEGIN SET @fail += 1; PRINT 'FAIL wrong type: ' + ERROR_MESSAGE(); END
END CATCH

BEGIN TRY
    EXEC dbo.usp_Netsuite_VendorBill_ImportXml @XmlText = N'<root><count>2</count><hasMore>false</hasMore>
      <items><vendor_bill_id>1</vendor_bill_id><line_id>1</line_id></items>
      <items><vendor_bill_id>1</vendor_bill_id><amount>5</amount></items>
      <offset>0</offset><totalResults>2</totalResults></root>';
    SET @fail += 1; PRINT 'FAIL line without line_id accepted';
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 50307 AND (SELECT COUNT(*) FROM dbo.tb_Netsuite_VendorBillLine) = @before_l
        PRINT 'PASS line without line_id refused, nothing written';
    ELSE BEGIN SET @fail += 1; PRINT 'FAIL missing line_id: ' + ERROR_MESSAGE(); END
END CATCH

IF @fail > 0 BEGIN SET @err = CAST(@fail AS nvarchar(10)) + N' check(s) failed'; THROW 50001, @err, 1; END
PRINT 'All checks passed';
