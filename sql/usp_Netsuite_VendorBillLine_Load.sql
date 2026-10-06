/*
    dbo.usp_Netsuite_VendorBillLine_Load

    Loads one page of Web Service Connector output (suiteql/vendorbill_lines.sql,
    shaped like xsd/netsuite_vendorbill_lines.xsd) into dbo.tb_Netsuite_VendorBillLine.

    - Upsert on (vendor_bill_id, line_id). Lines removed from a bill in NetSuite
      are deleted by usp_Netsuite_VendorBill_Finalize at the end of the run:
      a bill's lines can be split over two pages, so this procedure can't tell.
    - Same input handling, validation and result row as usp_Netsuite_VendorBill_Load.
*/
-- XML methods need these at CREATE time (sqlcmd defaults QUOTED_IDENTIFIER to OFF)
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Netsuite_VendorBillLine_Load
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
        THROW 50111, N'usp_Netsuite_VendorBillLine_Load: expected a <root> element (Web Service Connector output).', 1;

    -- 1. Shred to text (*: = any namespace)
    SELECT
        vendor_bill_id   = NULLIF(LTRIM(RTRIM(i.value(N'(*:vendor_bill_id/text())[1]', N'nvarchar(4000)'))), N''),
        line_id          = NULLIF(LTRIM(RTRIM(i.value(N'(*:line_id/text())[1]',        N'nvarchar(4000)'))), N''),
        line_number      = i.value(N'(*:line_number/text())[1]',       N'nvarchar(4000)'),
        line_type        = i.value(N'(*:line_type/text())[1]',         N'nvarchar(4000)'),
        item_id          = i.value(N'(*:item_id/text())[1]',           N'nvarchar(4000)'),
        item_name        = i.value(N'(*:item_name/text())[1]',         N'nvarchar(4000)'),
        account_id       = i.value(N'(*:account_id/text())[1]',        N'nvarchar(4000)'),
        account_name     = i.value(N'(*:account_name/text())[1]',      N'nvarchar(4000)'),
        memo             = i.value(N'(*:memo/text())[1]',              N'nvarchar(4000)'),
        quantity         = i.value(N'(*:quantity/text())[1]',          N'nvarchar(4000)'),
        rate             = i.value(N'(*:rate/text())[1]',              N'nvarchar(4000)'),
        amount           = i.value(N'(*:amount/text())[1]',            N'nvarchar(4000)'),
        base_amount      = i.value(N'(*:base_amount/text())[1]',       N'nvarchar(4000)'),
        department_id    = i.value(N'(*:department_id/text())[1]',     N'nvarchar(4000)'),
        department_name  = i.value(N'(*:department_name/text())[1]',   N'nvarchar(4000)'),
        class_id         = i.value(N'(*:class_id/text())[1]',          N'nvarchar(4000)'),
        class_name       = i.value(N'(*:class_name/text())[1]',        N'nvarchar(4000)'),
        location_id      = i.value(N'(*:location_id/text())[1]',       N'nvarchar(4000)'),
        location_name    = i.value(N'(*:location_name/text())[1]',     N'nvarchar(4000)'),
        line_entity_id   = i.value(N'(*:line_entity_id/text())[1]',    N'nvarchar(4000)'),
        line_entity_name = i.value(N'(*:line_entity_name/text())[1]',  N'nvarchar(4000)')
    INTO #src
    FROM @xml.nodes(N'/*:root/*:items') AS x(i);

    -- 2. Convert to the staging types
    SELECT
        s.vendor_bill_id, s.line_id,
        line_number = TRY_CONVERT(int, s.line_number),
        s.line_type, s.item_id, s.item_name, s.account_id, s.account_name, s.memo,
        quantity    = COALESCE(TRY_CONVERT(decimal(28,10), s.quantity),  TRY_CONVERT(decimal(28,10), TRY_CONVERT(float, s.quantity))),
        rate        = COALESCE(TRY_CONVERT(decimal(28,10), s.rate),      TRY_CONVERT(decimal(28,10), TRY_CONVERT(float, s.rate))),
        amount      = COALESCE(TRY_CONVERT(decimal(19,4), s.amount),     TRY_CONVERT(decimal(19,4), TRY_CONVERT(float, s.amount))),
        base_amount = COALESCE(TRY_CONVERT(decimal(19,4), s.base_amount), TRY_CONVERT(decimal(19,4), TRY_CONVERT(float, s.base_amount))),
        s.department_id, s.department_name, s.class_id, s.class_name,
        s.location_id, s.location_name, s.line_entity_id, s.line_entity_name
    INTO #line
    FROM #src s;

    -- 3. Validate
    SELECT TOP (1) @msg = N'usp_Netsuite_VendorBillLine_Load: an <items> element has no '
         + CASE WHEN vendor_bill_id IS NULL THEN N'vendor_bill_id' ELSE N'line_id (vendor bill ' + vendor_bill_id + N')' END + N'.'
    FROM #src WHERE vendor_bill_id IS NULL OR line_id IS NULL;
    IF @msg IS NOT NULL THROW 50112, @msg, 1;

    SELECT TOP (1) @msg = N'usp_Netsuite_VendorBillLine_Load: vendor bill ' + vendor_bill_id + N' line ' + line_id
         + N' appears more than once in this page (check the accounting book filter in the query).'
    FROM #src GROUP BY vendor_bill_id, line_id HAVING COUNT(*) > 1;
    IF @msg IS NOT NULL THROW 50113, @msg, 1;

    SELECT TOP (1) @msg = N'usp_Netsuite_VendorBillLine_Load: vendor bill ' + s.vendor_bill_id + N' line ' + s.line_id
         + N', value not convertible: '
         + CASE
               WHEN s.line_number IS NOT NULL AND l.line_number IS NULL THEN N'line_number = ' + s.line_number
               WHEN s.quantity    IS NOT NULL AND l.quantity    IS NULL THEN N'quantity = '    + s.quantity
               WHEN s.rate        IS NOT NULL AND l.rate        IS NULL THEN N'rate = '        + s.rate
               WHEN s.amount      IS NOT NULL AND l.amount      IS NULL THEN N'amount = '      + s.amount
               ELSE N'base_amount = ' + s.base_amount
           END
    FROM #src s
    JOIN #line l ON l.vendor_bill_id = s.vendor_bill_id AND l.line_id = s.line_id
    WHERE (s.line_number IS NOT NULL AND l.line_number IS NULL)
       OR (s.quantity    IS NOT NULL AND l.quantity    IS NULL)
       OR (s.rate        IS NOT NULL AND l.rate        IS NULL)
       OR (s.amount      IS NOT NULL AND l.amount      IS NULL)
       OR (s.base_amount IS NOT NULL AND l.base_amount IS NULL);
    IF @msg IS NOT NULL THROW 50114, @msg, 1;

    -- 4. Upsert
    BEGIN TRANSACTION;

    UPDATE t SET
        line_number = l.line_number, line_type = l.line_type,
        item_id = l.item_id, item_name = l.item_name,
        account_id = l.account_id, account_name = l.account_name, memo = l.memo,
        quantity = l.quantity, rate = l.rate, amount = l.amount, base_amount = l.base_amount,
        department_id = l.department_id, department_name = l.department_name,
        class_id = l.class_id, class_name = l.class_name,
        location_id = l.location_id, location_name = l.location_name,
        line_entity_id = l.line_entity_id, line_entity_name = l.line_entity_name,
        last_loaded_at = @now
    FROM dbo.tb_Netsuite_VendorBillLine t WITH (UPDLOCK, HOLDLOCK)
    JOIN #line l ON l.vendor_bill_id = t.vendor_bill_id AND l.line_id = t.line_id;
    SET @updated = @@ROWCOUNT;

    INSERT INTO dbo.tb_Netsuite_VendorBillLine (
        vendor_bill_id, line_id, line_number, line_type, item_id, item_name,
        account_id, account_name, memo, quantity, rate, amount, base_amount,
        department_id, department_name, class_id, class_name, location_id, location_name,
        line_entity_id, line_entity_name, first_loaded_at, last_loaded_at)
    SELECT
        l.vendor_bill_id, l.line_id, l.line_number, l.line_type, l.item_id, l.item_name,
        l.account_id, l.account_name, l.memo, l.quantity, l.rate, l.amount, l.base_amount,
        l.department_id, l.department_name, l.class_id, l.class_name, l.location_id, l.location_name,
        l.line_entity_id, l.line_entity_name, @now, @now
    FROM #line l
    WHERE NOT EXISTS (SELECT 1 FROM dbo.tb_Netsuite_VendorBillLine t WITH (UPDLOCK, HOLDLOCK)
                      WHERE t.vendor_bill_id = l.vendor_bill_id AND t.line_id = l.line_id);
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
