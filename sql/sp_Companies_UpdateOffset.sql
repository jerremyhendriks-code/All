/*
    dbo.sp_Companies_UpdateOffset

    Call after every page, with the Web Service Connector's XML string.
    Reads <count> (the number of records picked up) and <hasMore>, and moves
    the object's row in dbo.tb_Companies forward:

      Offset      = Offset + count
      MoreRecords = 1 when <hasMore> is true (fetch the next page),
                    0 otherwise (Else branch: run is done, sp_Companies_ResetPaging)

    The run must stop on the page that says <hasMore>false</hasMore>, not one
    page later at count = 0: NetSuite only accepts offsets that are a multiple
    of the page size, so after a partial last page (say 175 records at offset
    3000) the next offset, 3175, is refused with INVALID_OFFSET.
    If <hasMore> is missing, MoreRecords = 1 only for a full page
    (count = @PageSize).

    Safety check: the page's <offset> must equal the stored Offset. If not, the
    request didn't use the stored Offset, or this page was already processed;
    the call fails and changes nothing, so the offset can never skip ahead.

    The row is found by @BPA_Origin and @BPA_Company (NULL = the row without
    company); exactly one row must match.

    Accepts the XML with or without the <?xml ... ?> declaration, the
    WebSvcCon namespace and the WebService/SuiteQL/OutputSchema wrapper.

    Returns Records_Count, Offset (the new value) and MoreRecords.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Companies_UpdateOffset
    @BPA_Origin  nvarchar(50),
    @BPA_Company nvarchar(50) = NULL,
    @XmlText     nvarchar(max),
    @PageSize    int          = 1000    -- the limit= in the request URL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @xml xml, @decl int, @msg nvarchar(2048),
            @count int, @page_offset int, @has_more nvarchar(10), @more bit, @stored int, @rows int;

    -- A parameter value typed as NULL in TaskCentre may arrive as the text 'NULL'
    IF @BPA_Company = N'NULL' OR LTRIM(RTRIM(@BPA_Company)) = N''
        SET @BPA_Company = NULL;

    -- Drop the XML declaration, if any (an encoding="utf-8" one is refused for nvarchar)
    SET @decl = CHARINDEX(N'<?xml', @XmlText);
    IF @decl BETWEEN 1 AND 10
        SET @XmlText = STUFF(@XmlText, 1, CHARINDEX(N'?>', @XmlText, @decl) + 1, N'');

    SET @xml = CONVERT(xml, @XmlText);

    -- *: = any namespace, // = also inside the WebService/SuiteQL/OutputSchema wrapper
    SELECT @count       = @xml.value(N'(//*:root/*:count/text())[1]',  N'int'),
           @page_offset = @xml.value(N'(//*:root/*:offset/text())[1]', N'int'),
           @has_more    = LOWER(@xml.value(N'(//*:root/*:hasMore/text())[1]', N'nvarchar(10)'));

    IF @count IS NULL
        THROW 50521, N'sp_Companies_UpdateOffset: no <count> in the XML; is this Web Service Connector output (and not an error response)?', 1;

    SET @more = CASE
                    WHEN @count = 0                     THEN 0
                    WHEN @has_more IN (N'true', N'1')   THEN 1
                    WHEN @has_more IN (N'false', N'0')  THEN 0
                    WHEN @count >= @PageSize            THEN 1   -- no <hasMore>: full page, maybe more
                    ELSE 0
                END;

    BEGIN TRANSACTION;

    SELECT @stored = ISNULL(Offset, 0)
    FROM dbo.tb_Companies WITH (UPDLOCK, HOLDLOCK)
    WHERE BPA_Origin = @BPA_Origin
      AND (BPA_Company = @BPA_Company OR (BPA_Company IS NULL AND @BPA_Company IS NULL));

    SET @rows = @@ROWCOUNT;

    IF @rows <> 1
    BEGIN
        ROLLBACK TRANSACTION;
        SET @msg = N'sp_Companies_UpdateOffset: expected 1 row in tb_Companies for BPA_Origin = '''
                 + ISNULL(@BPA_Origin, N'NULL') + N''', BPA_Company = '
                 + ISNULL(N'''' + @BPA_Company + N'''', N'NULL') + N', found '
                 + CAST(@rows AS nvarchar(12)) + N'; nothing changed.';
        THROW 50522, @msg, 1;
    END

    IF @page_offset IS NOT NULL AND @page_offset <> @stored
    BEGIN
        ROLLBACK TRANSACTION;
        SET @msg = N'sp_Companies_UpdateOffset: the page has offset ' + CAST(@page_offset AS nvarchar(12))
                 + N' but tb_Companies.Offset is ' + CAST(@stored AS nvarchar(12))
                 + N'; did the request use the stored Offset, or was this page already processed? Nothing changed.';
        THROW 50523, @msg, 1;
    END

    UPDATE dbo.tb_Companies
    SET Offset          = @stored + @count,
        MoreRecords     = @more,
        BPA_Sysmodified = GETDATE()
    WHERE BPA_Origin = @BPA_Origin
      AND (BPA_Company = @BPA_Company OR (BPA_Company IS NULL AND @BPA_Company IS NULL));

    COMMIT TRANSACTION;

    SELECT Records_Count = @count,
           Offset        = @stored + @count,
           MoreRecords   = @more;
END
GO
