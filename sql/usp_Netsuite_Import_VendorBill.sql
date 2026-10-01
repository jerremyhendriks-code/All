/*
    dbo.usp_Netsuite_Import_VendorBill

    Writes the vendorBill records from a NetSuite connector Search response into the
    header table and the expense and item line tables. Use it instead of the SQL
    connector step.

    Expected input (the connector's raw response, with or without an <?xml ...?> declaration):
        <Response><Operations><Operation Name="Search"><Object>
            <vendorBill> ... <expense><items>..</items></expense> <item><items>..</items></item> </vendorBill>
            <vendorBill> ... </vendorBill>
        </Object></Operation></Operations></Response>

    How fields map to columns (column names are matched case-insensitively):
    - Plain fields go to the column with the same name:
          <tranId>, <dueDate>, <amount>               -> tranId, dueDate, amount
    - Reference fields go to <field>_<child> columns:
          <entity><id>, <taxCode><refName>            -> entity_id, taxCode_refName
    - Header fields come from <vendorBill>. Expense lines come from <expense><items>, and
      item lines from <item><items>.
    - Lines are linked to their header through BPA_ParentID = the header row's
      BPA_EntryID. BPA_EntryID is read back from each header row after it is inserted,
      so it can be an identity, a column with a default (NEWID(), a sequence), or a
      uniqueidentifier without a default, in which case the procedure fills it with NEWID().
    - The NetSuite <id> of a bill goes to the header's id column. That is how a bill
      already in the table is recognised.
    - A column with no matching field in the response is left out of the INSERT, so it
      gets its default or NULL. A field with no matching column is ignored.
    - Identity, computed and rowversion columns are never written.
    - These columns get fixed values in every table that has them:
          BPA_Direction = 'FROMUPDATE', BPA_origin = 'Netsuite'

    How values are converted to the column type:
    - bit                    : True/T -> 1, False/F -> 0
    - date / time types      : ISO 8601 (2026-09-28, 2026-09-28T15:17:00.0000000Z;
                               Z timestamps keep their UTC clock time) or dd/mm/yyyy [hh:mi:ss]
    - numbers and other types: TRY_CONVERT
    If a value doesn't convert, nothing is written. The procedure stops with an error
    that names the table, column, bill id and value.

    Bills that are already in the header table (same id, BPA_Direction = 'FROMUPDATE',
    BPA_origin = 'Netsuite') are deleted together with their lines first and then
    inserted again, so running it twice gives the same result. Rows with another
    direction or origin aren't touched.

    The whole import runs in one transaction. Any error rolls back everything.
    Requires SQL Server 2017 or later (STRING_AGG).

    The table and link column names are set at the top of the procedure body.

    Example:
        EXEC dbo.usp_Netsuite_Import_VendorBill @ResponseXml = @response;
*/
-- Required for the XML methods used below; stored with the procedure when it is created
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Netsuite_Import_VendorBill
    @ResponseXml nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Target tables (all in dbo)
    DECLARE @HeaderTable      sysname = N'tb_Netsuite_vendorbill',
            @ExpenseTable     sysname = N'tb_Netsuite_vendorBill_Expense',
            @ItemTable        sysname = N'tb_Netsuite_vendorBill_item',
            @BillIdColumn     sysname = N'id',             -- header column holding the NetSuite bill id
            @HeaderKeyColumn  sysname = N'BPA_EntryID',    -- header key the lines point to
            @LineParentColumn sysname = N'BPA_ParentID';   -- line column holding the header's BPA_EntryID

    DECLARE @x xml, @sql nvarchar(max), @msg nvarchar(2048), @n int,
            @s char(1), @t sysname, @cols nvarchar(max), @exprs nvarchar(max),
            @badTable sysname, @badCol sysname, @badBill nvarchar(100),
            @badVal nvarchar(4000), @hFilter nvarchar(max);

    -- Columns that always get a fixed value, in every table that has them
    DECLARE @fixed TABLE (name sysname PRIMARY KEY, val nvarchar(100) NOT NULL);
    INSERT INTO @fixed (name, val) VALUES
        (N'BPA_Direction', N'FROMUPDATE'),
        (N'BPA_origin',    N'Netsuite');

    /* ---- Parse the response -------------------------------------------------------- */

    IF @ResponseXml IS NULL OR LTRIM(@ResponseXml) = N''
        THROW 50006, N'@ResponseXml is empty.', 1;

    -- XML passed as escaped text (&lt;Response&gt;...): unescape it first
    IF CHARINDEX(N'<', @ResponseXml) = 0 AND CHARINDEX(N'&lt;', @ResponseXml) > 0
        SET @ResponseXml = CAST(@ResponseXml AS xml).value('.', 'nvarchar(max)');

    -- An nvarchar string that declares encoding="utf-8" can't be cast to xml, so drop the declaration
    SET @ResponseXml = LTRIM(REPLACE(@ResponseXml, NCHAR(65279), N''));
    IF CHARINDEX(N'<?xml', @ResponseXml) > 0
        SET @ResponseXml = STUFF(@ResponseXml, CHARINDEX(N'<?xml', @ResponseXml),
                                 CHARINDEX(N'?>', @ResponseXml, CHARINDEX(N'<?xml', @ResponseXml)) - CHARINDEX(N'<?xml', @ResponseXml) + 2, N'');
    SET @x = CAST(@ResponseXml AS xml);

    -- Element names are matched with local-name() throughout, so namespaces and prefixes don't matter

    /* ---- Target tables ------------------------------------------------------------- */

    DECLARE @tables TABLE (
        sublist   char(1) PRIMARY KEY,   -- H = header, E = expense lines, I = item lines
        name      sysname NOT NULL,
        obj       int     NULL,
        keycol    sysname NOT NULL,      -- column that must exist: bill id (header) / parent link (lines)
        ins_order int     NOT NULL
    );
    INSERT INTO @tables (sublist, name, obj, keycol, ins_order) VALUES
        ('H', @HeaderTable,  OBJECT_ID(N'dbo.' + QUOTENAME(@HeaderTable)),  @BillIdColumn,     1),
        ('E', @ExpenseTable, OBJECT_ID(N'dbo.' + QUOTENAME(@ExpenseTable)), @LineParentColumn, 2),
        ('I', @ItemTable,    OBJECT_ID(N'dbo.' + QUOTENAME(@ItemTable)),    @LineParentColumn, 3);

    SELECT TOP (1) @msg = CASE WHEN t.obj IS NULL
                               THEN N'Table dbo.' + QUOTENAME(t.name) + N' not found.'
                               ELSE N'Column ' + QUOTENAME(t.keycol) + N' not found in dbo.' + QUOTENAME(t.name) + N'.' END
    FROM @tables t
    WHERE t.obj IS NULL
       OR NOT EXISTS (SELECT 1 FROM sys.columns c WHERE c.object_id = t.obj AND c.name = t.keycol)
    ORDER BY t.ins_order;
    IF @msg IS NOT NULL THROW 50001, @msg, 1;

    -- The header key must be filled in by SQL Server, or be a uniqueidentifier we can fill with NEWID()
    IF NOT EXISTS (SELECT 1 FROM sys.columns c
                   WHERE c.object_id = OBJECT_ID(N'dbo.' + QUOTENAME(@HeaderTable)) AND c.name = @HeaderKeyColumn
                     AND (c.is_identity = 1 OR c.is_computed = 1 OR c.default_object_id <> 0
                          OR TYPE_NAME(c.system_type_id) = N'uniqueidentifier'))
    BEGIN
        SET @msg = N'Column ' + QUOTENAME(@HeaderKeyColumn) + N' not found in dbo.' + QUOTENAME(@HeaderTable)
                 + N', or it is not an identity, has no default and is not a uniqueidentifier.';
        THROW 50001, @msg, 1;
    END

    /* ---- Split into bills, lines and name/value pairs ------------------------------ */

    CREATE TABLE #bill (bill_id nvarchar(100) COLLATE DATABASE_DEFAULT NULL, x xml NOT NULL);
    INSERT INTO #bill (bill_id, x)
    SELECT b.n.value('(*[local-name() = "id"]/text())[1]', 'nvarchar(100)'), b.n.query('.')
    FROM @x.nodes('//*[local-name() = "vendorBill"]') b(n);

    -- Nothing found although the text mentions vendorBill: the input isn't what we expect, so don't silently do nothing
    IF NOT EXISTS (SELECT 1 FROM #bill) AND CHARINDEX(N'vendorBill', @ResponseXml) > 0
    BEGIN
        SET @msg = N'No <vendorBill> elements could be read from @ResponseXml. It starts with: '
                 + LEFT(REPLACE(REPLACE(@ResponseXml, NCHAR(13), N' '), NCHAR(10), N' '), 300);
        THROW 50007, @msg, 1;
    END

    IF EXISTS (SELECT 1 FROM #bill WHERE bill_id IS NULL)
        THROW 50002, N'The response contains a vendorBill without an <id>.', 1;
    IF EXISTS (SELECT 1 FROM #bill GROUP BY bill_id HAVING COUNT(*) > 1)
        THROW 50003, N'The response contains the same vendorBill <id> more than once.', 1;

    CREATE TABLE #line (sublist char(1) NOT NULL, bill_id nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
                        line_no int NOT NULL, x xml NOT NULL);
    INSERT INTO #line (sublist, bill_id, line_no, x)
    SELECT 'E', b.bill_id, ROW_NUMBER() OVER (PARTITION BY b.bill_id ORDER BY (SELECT NULL)), l.n.query('.')
    FROM #bill b CROSS APPLY b.x.nodes('*/*[local-name() = "expense"]/*[local-name() = "items"]') l(n);
    INSERT INTO #line (sublist, bill_id, line_no, x)
    SELECT 'I', b.bill_id, ROW_NUMBER() OVER (PARTITION BY b.bill_id ORDER BY (SELECT NULL)), l.n.query('.')
    FROM #bill b CROSS APPLY b.x.nodes('*/*[local-name() = "item"]/*[local-name() = "items"]') l(n);

    -- One row per field: plain fields keep their name, reference fields become parent_child
    CREATE TABLE #v (
        sublist char(1)       NOT NULL,
        bill_id nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
        line_no int           NOT NULL,   -- 0 for header fields
        name    nvarchar(300) COLLATE Latin1_General_CI_AS NOT NULL,
        val     nvarchar(max) COLLATE DATABASE_DEFAULT NULL
    );
    CREATE CLUSTERED INDEX ix ON #v (sublist, bill_id, line_no, name);

    INSERT INTO #v (sublist, bill_id, line_no, name, val)
    SELECT 'H', b.bill_id, 0, f.n.value('local-name(.)', 'nvarchar(300)'), f.n.value('text()[1]', 'nvarchar(max)')
    FROM #bill b CROSS APPLY b.x.nodes('*/*[not(*)]') f(n);

    INSERT INTO #v (sublist, bill_id, line_no, name, val)
    SELECT 'H', b.bill_id, 0,
           f.n.value('local-name(..)', 'nvarchar(150)') + N'_' + f.n.value('local-name(.)', 'nvarchar(150)'),
           f.n.value('text()[1]', 'nvarchar(max)')
    FROM #bill b
    CROSS APPLY b.x.nodes('*/*[local-name() != "expense" and local-name() != "item"]/*[not(*)]') f(n);

    INSERT INTO #v (sublist, bill_id, line_no, name, val)
    SELECT l.sublist, l.bill_id, l.line_no, f.n.value('local-name(.)', 'nvarchar(300)'), f.n.value('text()[1]', 'nvarchar(max)')
    FROM #line l CROSS APPLY l.x.nodes('*/*[not(*)]') f(n);

    INSERT INTO #v (sublist, bill_id, line_no, name, val)
    SELECT l.sublist, l.bill_id, l.line_no,
           f.n.value('local-name(..)', 'nvarchar(150)') + N'_' + f.n.value('local-name(.)', 'nvarchar(150)'),
           f.n.value('text()[1]', 'nvarchar(max)')
    FROM #line l CROSS APPLY l.x.nodes('*/*/*[not(*)]') f(n);

    -- Every line gets a parent link; the value (the header's key) is filled in after the header insert
    DELETE FROM #v WHERE sublist IN ('E', 'I') AND name = @LineParentColumn;
    INSERT INTO #v (sublist, bill_id, line_no, name, val)
    SELECT l.sublist, l.bill_id, l.line_no, @LineParentColumn, NULL
    FROM #line l;

    /* ---- Map fields to columns ----------------------------------------------------- */

    -- conv is the conversion expression for the column's type, with {v} standing for the raw value
    CREATE TABLE #map (sublist char(1) NOT NULL, col sysname NOT NULL, src nvarchar(300) COLLATE DATABASE_DEFAULT NULL,
                       fixed nvarchar(100) NULL, conv nvarchar(max) NOT NULL);
    INSERT INTO #map (sublist, col, src, fixed, conv)
    SELECT t.sublist, c.name, src.name, f.val,
           CASE
               WHEN ty.name IN ('char', 'varchar', 'nchar', 'nvarchar', 'text', 'ntext')
                   THEN N'{v}'
               WHEN ty.name = 'bit'
                   THEN N'CASE WHEN {v} IN (N''True'', N''T'') THEN 1 WHEN {v} IN (N''False'', N''F'') THEN 0 ELSE TRY_CONVERT(bit, {v}) END'
               WHEN ty.name IN ('date', 'datetime', 'datetime2', 'smalldatetime', 'datetimeoffset', 'time')
                   THEN N'COALESCE(TRY_CONVERT(' + d.decl + N', TRY_CONVERT(datetimeoffset(7), {v})), TRY_CONVERT(' + d.decl + N', {v}, 103))'
               ELSE N'TRY_CONVERT(' + d.decl + N', {v})'
           END
    FROM @tables t
    JOIN sys.columns c ON c.object_id = t.obj
    JOIN sys.types ty ON ty.user_type_id = c.system_type_id
    CROSS APPLY (SELECT decl = ty.name + CASE
                     WHEN ty.name IN ('decimal', 'numeric')
                         THEN N'(' + CAST(c.precision AS nvarchar(3)) + N', ' + CAST(c.scale AS nvarchar(3)) + N')'
                     WHEN ty.name IN ('datetime2', 'datetimeoffset', 'time')
                         THEN N'(' + CAST(c.scale AS nvarchar(3)) + N')'
                     WHEN ty.name IN ('binary', 'varbinary')
                         THEN N'(' + CASE WHEN c.max_length = -1 THEN N'max' ELSE CAST(c.max_length AS nvarchar(5)) END + N')'
                     ELSE N'' END) d
    OUTER APPLY (SELECT TOP (1) v.name FROM #v v
                 WHERE v.sublist = t.sublist AND v.name = c.name COLLATE Latin1_General_CI_AS) src
    LEFT JOIN @fixed f ON f.name = c.name COLLATE Latin1_General_CI_AS
    WHERE c.is_identity = 0
      AND c.is_computed = 0
      AND ty.name <> 'timestamp'
      AND (src.name IS NOT NULL OR f.val IS NOT NULL);

    -- A uniqueidentifier BPA_EntryID that SQL Server doesn't fill in itself gets NEWID()
    INSERT INTO #map (sublist, col, src, fixed, conv)
    SELECT t.sublist, c.name, NULL, NULL, N'NEWID()'
    FROM @tables t
    JOIN sys.columns c ON c.object_id = t.obj
    WHERE c.name = @HeaderKeyColumn
      AND c.is_identity = 0 AND c.is_computed = 0 AND c.default_object_id = 0
      AND TYPE_NAME(c.system_type_id) = N'uniqueidentifier'
      AND NOT EXISTS (SELECT 1 FROM #map m WHERE m.sublist = t.sublist AND m.col = c.name);

    /* ---- Check that every value converts before writing anything ------------------- */

    SELECT @sql = STRING_AGG(CAST(
                      N'SELECT N''' + REPLACE(m.col, N'''', N'''''') + N''' AS col, v.sublist, v.bill_id, v.val FROM #v v'
                    + N' WHERE v.sublist = ''' + m.sublist + N''' AND v.name = N''' + REPLACE(m.src, N'''', N'''''') + N''''
                    + N' AND v.val IS NOT NULL AND ' + REPLACE(m.conv, N'{v}', N'v.val') + N' IS NULL'
                  AS nvarchar(max)), N' UNION ALL ')
    FROM #map m
    WHERE m.fixed IS NULL AND m.src IS NOT NULL AND m.conv <> N'{v}';

    IF @sql IS NOT NULL
    BEGIN
        SET @sql = N'SELECT TOP (1) @c = q.col, @s = q.sublist, @b = q.bill_id, @val = LEFT(q.val, 4000) FROM (' + @sql + N') q;';
        EXEC sys.sp_executesql @sql,
             N'@c sysname OUTPUT, @s char(1) OUTPUT, @b nvarchar(100) OUTPUT, @val nvarchar(4000) OUTPUT',
             @c = @badCol OUTPUT, @s = @s OUTPUT, @b = @badBill OUTPUT, @val = @badVal OUTPUT;
        IF @badCol IS NOT NULL
        BEGIN
            SELECT @badTable = name FROM @tables WHERE sublist = @s;
            SET @msg = N'Value ''' + @badVal + N''' for ' + QUOTENAME(@badTable) + N'.' + QUOTENAME(@badCol)
                     + N' (vendorBill id ' + @badBill + N') does not convert to the column type. Nothing was written.';
            THROW 50004, @msg, 1;
        END
    END

    /* ---- Write --------------------------------------------------------------------- */

    DECLARE @result TABLE (table_name sysname, rows_deleted int NULL, rows_inserted int NULL, ins_order int);
    INSERT INTO @result (table_name, ins_order) SELECT name, ins_order FROM @tables;

    -- Bills already in the header table, as a filter on alias h
    SELECT @hFilter = N'h.' + QUOTENAME(@BillIdColumn) + N' IN (SELECT b.bill_id FROM #bill b)'
                    + ISNULL(STRING_AGG(CAST(N' AND h.' + QUOTENAME(c.name) + N' = N''' + REPLACE(f.val, N'''', N'''''') + N''''
                                             AS nvarchar(max)), N''), N'')
    FROM sys.columns c
    JOIN @fixed f ON f.name = c.name COLLATE Latin1_General_CI_AS
    WHERE c.object_id = OBJECT_ID(N'dbo.' + QUOTENAME(@HeaderTable));

    CREATE TABLE #hdrkey (bill_id nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL, entry_id nvarchar(100) COLLATE DATABASE_DEFAULT NULL);

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Delete the bills that are already there: their lines first, then the headers
        DECLARE del CURSOR LOCAL FAST_FORWARD FOR
            SELECT sublist, name FROM @tables ORDER BY ins_order DESC;
        OPEN del;
        FETCH NEXT FROM del INTO @s, @t;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF @s = 'H'
                SET @sql = N'DELETE h FROM dbo.' + QUOTENAME(@HeaderTable) + N' h WHERE ' + @hFilter + N';';
            ELSE
                SET @sql = N'DELETE t FROM dbo.' + QUOTENAME(@t) + N' t WHERE t.' + QUOTENAME(@LineParentColumn)
                         + N' IN (SELECT h.' + QUOTENAME(@HeaderKeyColumn) + N' FROM dbo.' + QUOTENAME(@HeaderTable)
                         + N' h WHERE ' + @hFilter + N');';
            SET @sql += N' SET @n = @@ROWCOUNT;';
            EXEC sys.sp_executesql @sql, N'@n int OUTPUT', @n = @n OUTPUT;
            UPDATE @result SET rows_deleted = @n WHERE table_name = @t;

            FETCH NEXT FROM del INTO @s, @t;
        END
        CLOSE del;
        DEALLOCATE del;

        -- Insert: headers first (capturing their BPA_EntryID), then lines
        DECLARE ins CURSOR LOCAL FAST_FORWARD FOR
            SELECT sublist, name FROM @tables ORDER BY ins_order;
        OPEN ins;
        FETCH NEXT FROM ins INTO @s, @t;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SELECT @cols  = STRING_AGG(CAST(QUOTENAME(m.col) AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY m.col),
                   @exprs = STRING_AGG(CAST(
                                CASE WHEN m.fixed IS NOT NULL
                                     THEN N'N''' + REPLACE(m.fixed, N'''', N'''''') + N''''
                                     WHEN m.src IS NULL
                                     THEN m.conv
                                     ELSE REPLACE(m.conv, N'{v}',
                                                  N'(SELECT TOP (1) v.val FROM #v v WHERE v.sublist = g.sublist AND v.bill_id = g.bill_id'
                                                + N' AND v.line_no = g.line_no AND v.name = N''' + REPLACE(m.src, N'''', N'''''') + N''')')
                                END AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY m.col)
            FROM #map m
            WHERE m.sublist = @s;

            SET @n = 0;
            IF @cols IS NOT NULL AND EXISTS (SELECT 1 FROM #v WHERE sublist = @s)
            BEGIN
                SET @sql = N'INSERT INTO dbo.' + QUOTENAME(@t) + N' (' + @cols + N')'
                         + CASE WHEN @s = 'H'
                                THEN N' OUTPUT CAST(inserted.' + QUOTENAME(@BillIdColumn) + N' AS nvarchar(100)),'
                                   + N' CAST(inserted.' + QUOTENAME(@HeaderKeyColumn) + N' AS nvarchar(100)) INTO #hdrkey (bill_id, entry_id)'
                                ELSE N'' END
                         + N' SELECT ' + @exprs
                         + N' FROM (SELECT DISTINCT sublist, bill_id, line_no FROM #v WHERE sublist = @s) g;'
                         + N' SET @n = @@ROWCOUNT;';
                EXEC sys.sp_executesql @sql, N'@s char(1), @n int OUTPUT', @s = @s, @n = @n OUTPUT;
            END
            UPDATE @result SET rows_inserted = @n WHERE table_name = @t;

            IF @s = 'H'
            BEGIN
                IF EXISTS (SELECT 1 FROM #hdrkey WHERE entry_id IS NULL)
                BEGIN
                    SET @msg = QUOTENAME(@HeaderKeyColumn) + N' is empty after inserting into dbo.' + QUOTENAME(@HeaderTable)
                             + N', so the lines cannot be linked. Nothing was written.';
                    THROW 50005, @msg, 1;
                END

                UPDATE v SET v.val = k.entry_id
                FROM #v v
                JOIN #hdrkey k ON k.bill_id = v.bill_id
                WHERE v.sublist IN ('E', 'I') AND v.name = @LineParentColumn;
            END

            FETCH NEXT FROM ins INTO @s, @t;
        END
        CLOSE ins;
        DEALLOCATE ins;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT table_name, rows_deleted, rows_inserted FROM @result ORDER BY ins_order;
END
