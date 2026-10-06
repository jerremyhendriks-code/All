/*
    dbo.usp_Netsuite_VendorBill_Load

    Loads one page of Web Service Connector output (suiteql/vendorbill_header.sql,
    shaped like xsd/netsuite_vendorbill_header.xsd) into dbo.tb_Netsuite_VendorBill.

    - Upsert on [id] = vendor_bill_id: existing bills are updated, new ones
      inserted, nothing is deleted (see usp_Netsuite_VendorBill_Finalize).
    - Accepts the XML as text, with or without the <?xml ... ?> declaration
      (an encoding="utf-8" declaration would otherwise make SQL Server refuse
      nvarchar input), with or without the WebSvcCon namespace.
    - All or nothing per page: a missing id, a duplicate id, or a value that
      doesn't convert (date, number, T/F flag) raises an error naming the bill
      and nothing from that page is written.
    - Returns one row the TaskCentre loop can use:
      rows_in_page, rows_inserted, rows_updated, has_more, next_offset.
*/
-- XML methods need these at CREATE time (sqlcmd defaults QUOTED_IDENTIFIER to OFF)
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Netsuite_VendorBill_Load
    @xml_text nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @now datetime2(3) = SYSUTCDATETIME(),
            @decl int, @xml xml, @msg nvarchar(2048),
            @inserted int = 0, @updated int = 0;

    -- Drop the XML declaration, if any
    SET @decl = CHARINDEX(N'<?xml', @xml_text);
    IF @decl BETWEEN 1 AND 10
        SET @xml_text = STUFF(@xml_text, 1, CHARINDEX(N'?>', @xml_text, @decl) + 1, N'');

    SET @xml = CONVERT(xml, @xml_text);

    IF @xml.exist(N'/*:root') = 0
        THROW 50101, N'usp_Netsuite_VendorBill_Load: expected a <root> element (Web Service Connector output).', 1;

    -- 1. Shred to text (*: = any namespace)
    SELECT
        id                    = NULLIF(LTRIM(RTRIM(i.value(N'(*:vendor_bill_id/text())[1]',        N'nvarchar(4000)'))), N''),
        bill_number           = i.value(N'(*:bill_number/text())[1]',            N'nvarchar(4000)'),
        vendor_invoice_number = i.value(N'(*:vendor_invoice_number/text())[1]',  N'nvarchar(4000)'),
        external_id           = i.value(N'(*:external_id/text())[1]',            N'nvarchar(4000)'),
        bill_date             = i.value(N'(*:bill_date/text())[1]',              N'nvarchar(4000)'),
        due_date              = i.value(N'(*:due_date/text())[1]',               N'nvarchar(4000)'),
        vendor_id             = i.value(N'(*:vendor_id/text())[1]',              N'nvarchar(4000)'),
        vendor_name           = i.value(N'(*:vendor_name/text())[1]',            N'nvarchar(4000)'),
        memo                  = i.value(N'(*:memo/text())[1]',                   N'nvarchar(4000)'),
        terms_id              = i.value(N'(*:terms_id/text())[1]',               N'nvarchar(4000)'),
        terms_name            = i.value(N'(*:terms_name/text())[1]',             N'nvarchar(4000)'),
        currency_id           = i.value(N'(*:currency_id/text())[1]',            N'nvarchar(4000)'),
        currency_name         = i.value(N'(*:currency_name/text())[1]',          N'nvarchar(4000)'),
        exchange_rate         = i.value(N'(*:exchange_rate/text())[1]',          N'nvarchar(4000)'),
        bill_total            = i.value(N'(*:bill_total/text())[1]',             N'nvarchar(4000)'),
        amount_open           = i.value(N'(*:amount_open/text())[1]',            N'nvarchar(4000)'),
        subsidiary_id         = i.value(N'(*:subsidiary_id/text())[1]',          N'nvarchar(4000)'),
        subsidiary_name       = i.value(N'(*:subsidiary_name/text())[1]',        N'nvarchar(4000)'),
        department_id         = i.value(N'(*:department_id/text())[1]',          N'nvarchar(4000)'),
        department_name       = i.value(N'(*:department_name/text())[1]',        N'nvarchar(4000)'),
        class_id              = i.value(N'(*:class_id/text())[1]',               N'nvarchar(4000)'),
        class_name            = i.value(N'(*:class_name/text())[1]',             N'nvarchar(4000)'),
        location_id           = i.value(N'(*:location_id/text())[1]',            N'nvarchar(4000)'),
        location_name         = i.value(N'(*:location_name/text())[1]',          N'nvarchar(4000)'),
        ap_account_id         = i.value(N'(*:ap_account_id/text())[1]',          N'nvarchar(4000)'),
        ap_account_name       = i.value(N'(*:ap_account_name/text())[1]',        N'nvarchar(4000)'),
        posting_period_id     = i.value(N'(*:posting_period_id/text())[1]',      N'nvarchar(4000)'),
        posting_period_name   = i.value(N'(*:posting_period_name/text())[1]',    N'nvarchar(4000)'),
        status_code           = i.value(N'(*:status_code/text())[1]',            N'nvarchar(4000)'),
        status_name           = i.value(N'(*:status_name/text())[1]',            N'nvarchar(4000)'),
        approval_status_id    = i.value(N'(*:approval_status_id/text())[1]',     N'nvarchar(4000)'),
        approval_status_name  = i.value(N'(*:approval_status_name/text())[1]',   N'nvarchar(4000)'),
        is_posting            = i.value(N'(*:is_posting/text())[1]',             N'nvarchar(4000)'),
        is_voided             = i.value(N'(*:is_voided/text())[1]',              N'nvarchar(4000)'),
        created_date          = i.value(N'(*:created_date/text())[1]',           N'nvarchar(4000)'),
        last_modified         = i.value(N'(*:last_modified/text())[1]',          N'nvarchar(4000)')
    INTO #src
    FROM @xml.nodes(N'/*:root/*:items') AS x(i);

    -- 2. Convert to the staging types
    SELECT
        s.id, s.bill_number, s.vendor_invoice_number, s.external_id,
        bill_date     = TRY_CONVERT(date, s.bill_date, 23),
        due_date      = TRY_CONVERT(date, s.due_date, 23),
        s.vendor_id, s.vendor_name, s.memo, s.terms_id, s.terms_name, s.currency_id, s.currency_name,
        exchange_rate = COALESCE(TRY_CONVERT(decimal(28,10), s.exchange_rate), TRY_CONVERT(decimal(28,10), TRY_CONVERT(float, s.exchange_rate))),
        bill_total    = COALESCE(TRY_CONVERT(decimal(19,4), s.bill_total),     TRY_CONVERT(decimal(19,4), TRY_CONVERT(float, s.bill_total))),
        amount_open   = COALESCE(TRY_CONVERT(decimal(19,4), s.amount_open),    TRY_CONVERT(decimal(19,4), TRY_CONVERT(float, s.amount_open))),
        s.subsidiary_id, s.subsidiary_name, s.department_id, s.department_name,
        s.class_id, s.class_name, s.location_id, s.location_name,
        s.ap_account_id, s.ap_account_name, s.posting_period_id, s.posting_period_name,
        s.status_code, s.status_name, s.approval_status_id, s.approval_status_name,
        is_posting    = CASE WHEN s.is_posting IN (N'T', N'true', N'1') THEN CAST(1 AS bit)
                             WHEN s.is_posting IN (N'F', N'false', N'0') THEN CAST(0 AS bit) END,
        is_voided     = CASE WHEN s.is_voided IN (N'T', N'true', N'1') THEN CAST(1 AS bit)
                             WHEN s.is_voided IN (N'F', N'false', N'0') THEN CAST(0 AS bit) END,
        created_date  = TRY_CONVERT(datetime2(0), s.created_date, 120),
        last_modified = TRY_CONVERT(datetime2(0), s.last_modified, 120)
    INTO #bill
    FROM #src s;

    -- 3. Validate
    IF EXISTS (SELECT 1 FROM #src WHERE id IS NULL)
        THROW 50102, N'usp_Netsuite_VendorBill_Load: an <items> element has no vendor_bill_id.', 1;

    SELECT TOP (1) @msg = N'usp_Netsuite_VendorBill_Load: vendor_bill_id ' + id + N' appears more than once in this page.'
    FROM #src GROUP BY id HAVING COUNT(*) > 1;
    IF @msg IS NOT NULL THROW 50103, @msg, 1;

    SELECT TOP (1) @msg = N'usp_Netsuite_VendorBill_Load: vendor bill ' + s.id + N', value not convertible: '
         + CASE
               WHEN s.bill_date     IS NOT NULL AND b.bill_date     IS NULL THEN N'bill_date = '     + s.bill_date
               WHEN s.due_date      IS NOT NULL AND b.due_date      IS NULL THEN N'due_date = '      + s.due_date
               WHEN s.exchange_rate IS NOT NULL AND b.exchange_rate IS NULL THEN N'exchange_rate = ' + s.exchange_rate
               WHEN s.bill_total    IS NOT NULL AND b.bill_total    IS NULL THEN N'bill_total = '    + s.bill_total
               WHEN s.amount_open   IS NOT NULL AND b.amount_open   IS NULL THEN N'amount_open = '   + s.amount_open
               WHEN s.is_posting    IS NOT NULL AND b.is_posting    IS NULL THEN N'is_posting = '    + s.is_posting
               WHEN s.is_voided     IS NOT NULL AND b.is_voided     IS NULL THEN N'is_voided = '     + s.is_voided
               WHEN s.created_date  IS NOT NULL AND b.created_date  IS NULL THEN N'created_date = '  + s.created_date
               ELSE N'last_modified = ' + s.last_modified
           END
    FROM #src s
    JOIN #bill b ON b.id = s.id
    WHERE (s.bill_date     IS NOT NULL AND b.bill_date     IS NULL)
       OR (s.due_date      IS NOT NULL AND b.due_date      IS NULL)
       OR (s.exchange_rate IS NOT NULL AND b.exchange_rate IS NULL)
       OR (s.bill_total    IS NOT NULL AND b.bill_total    IS NULL)
       OR (s.amount_open   IS NOT NULL AND b.amount_open   IS NULL)
       OR (s.is_posting    IS NOT NULL AND b.is_posting    IS NULL)
       OR (s.is_voided     IS NOT NULL AND b.is_voided     IS NULL)
       OR (s.created_date  IS NOT NULL AND b.created_date  IS NULL)
       OR (s.last_modified IS NOT NULL AND b.last_modified IS NULL);
    IF @msg IS NOT NULL THROW 50104, @msg, 1;

    -- 4. Upsert
    BEGIN TRANSACTION;

    UPDATE t SET
        bill_number = b.bill_number, vendor_invoice_number = b.vendor_invoice_number,
        external_id = b.external_id, bill_date = b.bill_date, due_date = b.due_date,
        vendor_id = b.vendor_id, vendor_name = b.vendor_name, memo = b.memo,
        terms_id = b.terms_id, terms_name = b.terms_name,
        currency_id = b.currency_id, currency_name = b.currency_name, exchange_rate = b.exchange_rate,
        bill_total = b.bill_total, amount_open = b.amount_open,
        subsidiary_id = b.subsidiary_id, subsidiary_name = b.subsidiary_name,
        department_id = b.department_id, department_name = b.department_name,
        class_id = b.class_id, class_name = b.class_name,
        location_id = b.location_id, location_name = b.location_name,
        ap_account_id = b.ap_account_id, ap_account_name = b.ap_account_name,
        posting_period_id = b.posting_period_id, posting_period_name = b.posting_period_name,
        status_code = b.status_code, status_name = b.status_name,
        approval_status_id = b.approval_status_id, approval_status_name = b.approval_status_name,
        is_posting = b.is_posting, is_voided = b.is_voided,
        created_date = b.created_date, last_modified = b.last_modified,
        last_loaded_at = @now, is_stale = 0
    FROM dbo.tb_Netsuite_VendorBill t WITH (UPDLOCK, HOLDLOCK)
    JOIN #bill b ON b.id = t.id;
    SET @updated = @@ROWCOUNT;

    INSERT INTO dbo.tb_Netsuite_VendorBill (
        id, bill_number, vendor_invoice_number, external_id, bill_date, due_date,
        vendor_id, vendor_name, memo, terms_id, terms_name, currency_id, currency_name, exchange_rate,
        bill_total, amount_open, subsidiary_id, subsidiary_name, department_id, department_name,
        class_id, class_name, location_id, location_name, ap_account_id, ap_account_name,
        posting_period_id, posting_period_name, status_code, status_name,
        approval_status_id, approval_status_name, is_posting, is_voided, created_date, last_modified,
        first_loaded_at, last_loaded_at, is_stale)
    SELECT
        b.id, b.bill_number, b.vendor_invoice_number, b.external_id, b.bill_date, b.due_date,
        b.vendor_id, b.vendor_name, b.memo, b.terms_id, b.terms_name, b.currency_id, b.currency_name, b.exchange_rate,
        b.bill_total, b.amount_open, b.subsidiary_id, b.subsidiary_name, b.department_id, b.department_name,
        b.class_id, b.class_name, b.location_id, b.location_name, b.ap_account_id, b.ap_account_name,
        b.posting_period_id, b.posting_period_name, b.status_code, b.status_name,
        b.approval_status_id, b.approval_status_name, b.is_posting, b.is_voided, b.created_date, b.last_modified,
        @now, @now, 0
    FROM #bill b
    WHERE NOT EXISTS (SELECT 1 FROM dbo.tb_Netsuite_VendorBill t WITH (UPDLOCK, HOLDLOCK) WHERE t.id = b.id);
    SET @inserted = @@ROWCOUNT;

    COMMIT TRANSACTION;

    -- 5. Paging info for the caller
    DECLARE @count int    = @xml.value(N'(/*:root/*:count/text())[1]',   N'int'),
            @offset int   = @xml.value(N'(/*:root/*:offset/text())[1]',  N'int'),
            @has_more bit = CASE @xml.value(N'(/*:root/*:hasMore/text())[1]', N'nvarchar(10)')
                                WHEN N'true' THEN 1 WHEN N'True' THEN 1 WHEN N'1' THEN 1 ELSE 0 END;

    SELECT rows_in_page  = (SELECT COUNT(*) FROM #src),
           rows_inserted = @inserted,
           rows_updated  = @updated,
           has_more      = @has_more,
           next_offset   = ISNULL(@offset, 0) + ISNULL(@count, (SELECT COUNT(*) FROM #src));
END
