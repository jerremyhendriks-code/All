/*
    dbo.usp_Netsuite_VendorBill_ImportXml

    Imports one page of Web Service Connector output, the XML string, into the
    vendor bill staging tables through dbo.BPA_ImportXml. One procedure for both
    loops of the TaskCentre task:
      - header pages (suiteql/vendorbill_header.sql) -> dbo.tb_Netsuite_VendorBill
      - line pages   (suiteql/vendorbill_lines.sql)  -> dbo.tb_Netsuite_VendorBillLine

    What it adds on top of calling BPA_ImportXml directly:
    - Takes the XML as text, with or without the <?xml ... ?> declaration (an
      encoding="utf-8" declaration would otherwise make SQL Server refuse it).
    - Tells headers from lines by their fields (lines have line_id). Pass
      @RecordType to make it check instead: a header page sent as 'lines', or
      the other way round, is refused.
    - Skips a page without <items> (count = 0) instead of letting
      BPA_ImportXml import <links> as records.
    - Refuses a page with an item without vendor_bill_id (or line_id), so no
      row lands in staging that the views can't place.
    - Links every imported line to its bill: BPA_ParentID = BPA_EntryID of the
      latest imported header row of that bill. Import each run's header pages
      before its line pages.
    - Returns one row the TaskCentre loop can use:
      record_type, rows_imported, lines_linked, has_more, next_offset.

    All or nothing per page: an error rolls back everything this call wrote.
    Requires dbo.BPA_ImportXml and sql/netsuite_vendorbill_bpa_setup.sql.
*/
-- XML methods need these at CREATE time (sqlcmd defaults QUOTED_IDENTIFIER to OFF)
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Netsuite_VendorBill_ImportXml
    @XmlText    nvarchar(max),
    @RecordType nvarchar(10) = NULL     -- 'header', 'lines', or NULL to detect
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @xml xml, @decl int, @detected nvarchar(10), @msg nvarchar(2048),
            @items int, @lines_linked int = 0, @started datetime,
            @count int, @offset int, @has_more bit;

    IF @RecordType IS NOT NULL AND @RecordType NOT IN (N'header', N'lines')
        THROW 50301, N'usp_Netsuite_VendorBill_ImportXml: @RecordType must be ''header'', ''lines'' or NULL.', 1;

    IF NULLIF(LTRIM(RTRIM(@XmlText)), N'') IS NULL
        THROW 50302, N'usp_Netsuite_VendorBill_ImportXml: @XmlText is empty.', 1;

    -- Drop the XML declaration, if any
    SET @decl = CHARINDEX(N'<?xml', @XmlText);
    IF @decl BETWEEN 1 AND 10
        SET @XmlText = STUFF(@XmlText, 1, CHARINDEX(N'?>', @XmlText, @decl) + 1, N'');

    SET @xml = CONVERT(xml, @XmlText);

    -- Paging info (*: = any namespace, // = also when TaskCentre wraps <root>)
    SELECT @count    = @xml.value(N'(//*:root/*:count/text())[1]',  N'int'),
           @offset   = @xml.value(N'(//*:root/*:offset/text())[1]', N'int'),
           @has_more = CASE LOWER(@xml.value(N'(//*:root/*:hasMore/text())[1]', N'nvarchar(10)'))
                           WHEN N'true' THEN 1 WHEN N'1' THEN 1 ELSE 0 END,
           @items    = @xml.value(N'count(//*:root/*:items)', N'int');

    IF @xml.exist(N'//*:root') = 0
        THROW 50303, N'usp_Netsuite_VendorBill_ImportXml: no <root> element; is this Web Service Connector output?', 1;

    -- Nothing to import: no BPA_ImportXml call at all
    IF @items = 0
    BEGIN
        SELECT record_type   = @RecordType,
               rows_imported = 0,
               lines_linked  = 0,
               has_more      = @has_more,
               next_offset   = ISNULL(@offset, 0) + ISNULL(@count, 0);
        RETURN;
    END

    -- Headers or lines?
    SET @detected = CASE
                        WHEN @xml.exist(N'//*:root/*:items/*:line_id') = 1 THEN N'lines'
                        WHEN @xml.exist(N'//*:root/*:items/*:vendor_bill_id') = 1 THEN N'header'
                    END;

    IF @detected IS NULL
        THROW 50304, N'usp_Netsuite_VendorBill_ImportXml: the <items> have neither vendor_bill_id nor line_id; is this a vendor bill page?', 1;

    IF @RecordType IS NOT NULL AND @RecordType <> @detected
    BEGIN
        SET @msg = N'usp_Netsuite_VendorBill_ImportXml: @RecordType is ''' + @RecordType
                 + N''' but the page contains ' + @detected + N'.';
        THROW 50305, @msg, 1;
    END

    -- Every item needs its keys
    IF @xml.exist(N'//*:root/*:items[empty(*:vendor_bill_id/text())]') = 1
        THROW 50306, N'usp_Netsuite_VendorBill_ImportXml: an <items> element has no vendor_bill_id.', 1;

    IF @detected = N'lines' AND @xml.exist(N'//*:root/*:items[empty(*:line_id/text())]') = 1
        THROW 50307, N'usp_Netsuite_VendorBill_ImportXml: a line has no line_id.', 1;

    BEGIN TRANSACTION;

    SET @started = GETDATE();   -- same clock as BPA_Syscreated

    IF @detected = N'header'
        EXEC dbo.BPA_ImportXml
            @Xml                       = @xml,
            @BaseTableName             = N'dbo.tb_Netsuite_VendorBill',
            @RecordPath                = N'items',
            @BPA_Origin                = N'NetSuite',
            @BPA_ReferenceField        = N'vendor_bill_id',
            @BPA_Reference_Description = N'Vendor bill';
    ELSE
    BEGIN
        EXEC dbo.BPA_ImportXml
            @Xml                       = @xml,
            @BaseTableName             = N'dbo.tb_Netsuite_VendorBillLine',
            @RecordPath                = N'items',
            @BPA_Origin                = N'NetSuite',
            @BPA_ReferenceField        = N'vendor_bill_id',
            @BPA_Reference_Description = N'Vendor bill line';

        -- Link the lines this call imported to the latest header row of their bill
        UPDATE l
        SET BPA_ParentID = h.BPA_EntryID
        FROM dbo.tb_Netsuite_VendorBillLine l
        CROSS APPLY (SELECT TOP (1) hb.BPA_EntryID
                     FROM dbo.tb_Netsuite_VendorBill hb
                     WHERE hb.BPA_Reference = l.BPA_Reference
                     ORDER BY hb.BPA_Syscreated DESC, hb.BPA_EntryID DESC) h
        WHERE l.BPA_Syscreated >= @started
          AND l.BPA_ParentID IS NULL;
        SET @lines_linked = @@ROWCOUNT;
    END

    COMMIT TRANSACTION;

    SELECT record_type   = @detected,
           rows_imported = @items,
           lines_linked  = @lines_linked,
           has_more      = @has_more,
           next_offset   = ISNULL(@offset, 0) + ISNULL(@count, @items);
END
GO
