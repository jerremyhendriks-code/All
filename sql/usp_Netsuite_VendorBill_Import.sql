/*
    dbo.usp_Netsuite_VendorBill_Import

    Single entry point for TaskCentre: loads one page of Web Service Connector
    output into the vendor bill staging tables, from either
      - @xml_text:  the connector's XML output as a string, or
      - @file_path: the XML file the task saved, e.g. N'\\server\share\vb_0001.xml'.
    and passes it on to usp_Netsuite_VendorBill_Load (@record_type = 'header')
    or usp_Netsuite_VendorBillLine_Load (@record_type = 'lines').

    Returns the result row of that procedure:
    rows_in_page, rows_inserted, rows_updated, has_more, next_offset.

    Reading a file (OPENROWSET BULK):
    - The path is read by the SQL Server service, not by TaskCentre: it must
      exist on the SQL Server machine, or be a UNC share the SQL Server
      service account can read. A local path on the TaskCentre server won't work.
    - The caller needs ADMINISTER BULK OPERATIONS (server) or
      ADMINISTER DATABASE BULK OPERATIONS (database).
    - UTF-16 (with BOM) and UTF-8 (with or without BOM) files both work,
      whatever encoding the <?xml?> declaration claims.
    - @delete_file isn't offered: SQL Server can't delete files without
      xp_cmdshell; let TaskCentre clean up after a successful call.
*/
-- XML methods need these at CREATE time (sqlcmd defaults QUOTED_IDENTIFIER to OFF)
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Netsuite_VendorBill_Import
    @record_type nvarchar(10),              -- 'header' or 'lines'
    @xml_text    nvarchar(max)  = NULL,
    @file_path   nvarchar(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @blob varbinary(max), @sql nvarchar(max), @msg nvarchar(2048), @end int;

    IF @record_type NOT IN (N'header', N'lines')
        THROW 50131, N'usp_Netsuite_VendorBill_Import: @record_type must be ''header'' or ''lines''.', 1;

    IF (@xml_text IS NULL AND @file_path IS NULL) OR (@xml_text IS NOT NULL AND @file_path IS NOT NULL)
        THROW 50132, N'usp_Netsuite_VendorBill_Import: pass either @xml_text or @file_path.', 1;

    IF @file_path IS NOT NULL
    BEGIN
        -- OPENROWSET only takes a literal path
        SET @sql = N'SELECT @blob = BulkColumn FROM OPENROWSET(BULK N'''
                 + REPLACE(@file_path, N'''', N'''''') + N''', SINGLE_BLOB) AS f;';
        BEGIN TRY
            EXEC sys.sp_executesql @sql, N'@blob varbinary(max) OUTPUT', @blob = @blob OUTPUT;
        END TRY
        BEGIN CATCH
            SET @msg = N'usp_Netsuite_VendorBill_Import: cannot read ' + @file_path
                     + N' (path as seen from the SQL Server machine): ' + ERROR_MESSAGE();
            THROW 50133, @msg, 1;
        END CATCH

        IF @blob IS NULL OR DATALENGTH(@blob) = 0
        BEGIN
            SET @msg = N'usp_Netsuite_VendorBill_Import: ' + @file_path + N' is empty.';
            THROW 50134, @msg, 1;
        END

        IF SUBSTRING(@blob, 1, 2) = 0xFFFE OR SUBSTRING(@blob, 2, 1) = 0x00
            -- UTF-16 LE (with or without BOM): varbinary -> nvarchar reads UTF-16 LE
            SET @xml_text = CAST(CASE WHEN SUBSTRING(@blob, 1, 2) = 0xFFFE
                                      THEN SUBSTRING(@blob, 3, DATALENGTH(@blob)) ELSE @blob END AS nvarchar(max));
        ELSE
        BEGIN
            -- UTF-8: drop the BOM and the declaration (it may claim utf-16),
            -- then let the XML parser decode the bytes as UTF-8
            IF SUBSTRING(@blob, 1, 3) = 0xEFBBBF
                SET @blob = SUBSTRING(@blob, 4, DATALENGTH(@blob));
            IF SUBSTRING(@blob, 1, 5) = 0x3C3F786D6C                 -- '<?xml'
            BEGIN
                SET @end = CHARINDEX(0x3F3E, @blob);                  -- '?>'
                SET @blob = SUBSTRING(@blob, @end + 2, DATALENGTH(@blob));
            END
            SET @xml_text = CONVERT(nvarchar(max), CONVERT(xml, @blob));
        END
    END

    IF @record_type = N'header'
        EXEC dbo.usp_Netsuite_VendorBill_Load @xml_text = @xml_text;
    ELSE
        EXEC dbo.usp_Netsuite_VendorBillLine_Load @xml_text = @xml_text;
END
