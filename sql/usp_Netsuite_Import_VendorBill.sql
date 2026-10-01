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
      item lines from <item><items>. Each line row also gets the bill's <id> in
      @LineParentColumn.
    - A column with no matching field in the response is left out of the INSERT, so it
      gets its default or NULL. A field with no matching column is ignored. Run with
      @ReportUnmapped = 1 to list those fields.
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

    @ReplaceExisting = 1 (the default) first deletes the rows for the bill ids in the
    response from all three tables, then inserts them again, so running it twice gives
    the same result. Where a table has the BPA_Direction / BPA_origin columns, it only
    deletes rows that have the fixed values above, so rows from other directions or
    origins stay put.

    The whole import runs in one transaction. Any error rolls back everything.
    Requires SQL Server 2017 or later (STRING_AGG).

    Example:
        EXEC dbo.usp_Netsuite_Import_VendorBill
             @ResponseXml      = @response,
             @ExpenseTable     = N'tb_Netsuite_VendorBill_Expense',
             @ItemTable        = N'tb_Netsuite_VendorBill_Item',
             @LineParentColumn = N'vendorBill_id',
             @ReportUnmapped   = 1;
*/
-- Required for the XML methods used below; stored with the procedure when it is created
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Netsuite_Import_VendorBill
    @ResponseXml      nvarchar(max),
    @HeaderTable      sysname = N'tb_Netsuite_VendorBill',
    @ExpenseTable     sysname = N'tb_Netsuite_VendorBill_Expense',
    @ItemTable        sysname = N'tb_Netsuite_VendorBill_Item',
    @LineParentColumn sysname = N'vendorBill_id',   -- column in both line tables holding the bill id
    @ReplaceExisting  bit     = 1,
    @ReportUnmapped   bit     = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @x xml, @sql nvarchar(max), @msg nvarchar(2048), @n int,
            @s char(1), @t sysname, @key sysname, @cols nvarchar(max), @exprs nvarchar(max),
            @where nvarchar(max), @badTable sysname, @badCol sysname, @badBill nvarchar(100),
            @badVal nvarchar(4000);

    -- Columns that always get a fixed value, in every table that has them
    DECLARE @fixed TABLE (name sysname PRIMARY KEY, val nvarchar(100) NOT NULL);
    INSERT INTO @fixed (name, val) VALUES
        (N'BPA_Direction', N'FROMUPDATE'),
        (N'BPA_origin',    N'Netsuite');

    /* ---- Parse the response -------------------------------------------------------- */

    -- An nvarchar string that declares encoding="utf-8" can't be cast to xml, so drop the declaration
    SET @ResponseXml = LTRIM(REPLACE(@ResponseXml, NCHAR(65279), N''));
    IF LEFT(@ResponseXml, 5) = N'<?xml'
        SET @ResponseXml = STUFF(@ResponseXml, 1, CHARINDEX(N'?>', @ResponseXml) + 1, N'');
    SET @x = CAST(@ResponseXml AS xml);

    /* ---- Target tables ------------------------------------------------------------- */

    DECLARE @tables TABLE (
        sublist   char(1) PRIMARY KEY,   -- H = header, E = expense lines, I = item lines
        name      sysname NOT NULL,
        obj       int     NULL,
        keycol    sysname NOT NULL,      -- column holding the bill id
        ins_order int     NOT NULL
    );
    INSERT INTO @tables (sublist, name, obj, keycol, ins_order) VALUES
        ('H', @HeaderTable,  OBJECT_ID(N'dbo.' + QUOTENAME(@HeaderTable)),  N'id',              1),
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

    /* ---- Split into bills, lines and name/value pairs ------------------------------ */

    CREATE TABLE #bill (bill_id nvarchar(100) COLLATE DATABASE_DEFAULT NULL, x xml NOT NULL);
    INSERT INTO #bill (bill_id, x)
    SELECT b.n.value('(id/text())[1]', 'nvarchar(100)'), b.n.query('.')
    FROM @x.nodes('//Object/vendorBill') b(n);

    IF EXISTS (SELECT 1 FROM #bill WHERE bill_id IS NULL)
        THROW 50002, N'The response contains a vendorBill without an <id>.', 1;
    IF EXISTS (SELECT 1 FROM #bill GROUP BY bill_id HAVING COUNT(*) > 1)
        THROW 50003, N'The response contains the same vendorBill <id> more than once.', 1;

    CREATE TABLE #line (sublist char(1) NOT NULL, bill_id nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
                        line_no int NOT NULL, x xml NOT NULL);
    INSERT INTO #line (sublist, bill_id, line_no, x)
    SELECT 'E', b.bill_id, ROW_NUMBER() OVER (PARTITION BY b.bill_id ORDER BY (SELECT NULL)), l.n.query('.')
    FROM #bill b CROSS APPLY b.x.nodes('vendorBill/expense/items') l(n);
    INSERT INTO #line (sublist, bill_id, line_no, x)
    SELECT 'I', b.bill_id, ROW_NUMBER() OVER (PARTITION BY b.bill_id ORDER BY (SELECT NULL)), l.n.query('.')
    FROM #bill b CROSS APPLY b.x.nodes('vendorBill/item/items') l(n);

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
    FROM #bill b CROSS APPLY b.x.nodes('vendorBill/*[not(*)]') f(n);

    INSERT INTO #v (sublist, bill_id, line_no, name, val)
    SELECT 'H', b.bill_id, 0,
           f.n.value('local-name(..)', 'nvarchar(150)') + N'_' + f.n.value('local-name(.)', 'nvarchar(150)'),
           f.n.value('text()[1]', 'nvarchar(max)')
    FROM #bill b
    CROSS APPLY b.x.nodes('vendorBill/*[local-name() != "expense" and local-name() != "item"]/*[not(*)]') f(n);

    INSERT INTO #v (sublist, bill_id, line_no, name, val)
    SELECT l.sublist, l.bill_id, l.line_no, f.n.value('local-name(.)', 'nvarchar(300)'), f.n.value('text()[1]', 'nvarchar(max)')
    FROM #line l CROSS APPLY l.x.nodes('items/*[not(*)]') f(n);

    INSERT INTO #v (sublist, bill_id, line_no, name, val)
    SELECT l.sublist, l.bill_id, l.line_no,
           f.n.value('local-name(..)', 'nvarchar(150)') + N'_' + f.n.value('local-name(.)', 'nvarchar(150)'),
           f.n.value('text()[1]', 'nvarchar(max)')
    FROM #line l CROSS APPLY l.x.nodes('items/*/*[not(*)]') f(n);

    -- The bill id goes into the parent column of every line
    DELETE FROM #v WHERE sublist IN ('E', 'I') AND name = @LineParentColumn;
    INSERT INTO #v (sublist, bill_id, line_no, name, val)
    SELECT l.sublist, l.bill_id, l.line_no, @LineParentColumn, l.bill_id
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

    /* ---- Check that every value converts before writing anything ------------------- */

    SELECT @sql = STRING_AGG(CAST(
                      N'SELECT N''' + REPLACE(m.col, N'''', N'''''') + N''' AS col, v.sublist, v.bill_id, v.val FROM #v v'
                    + N' WHERE v.sublist = ''' + m.sublist + N''' AND v.name = N''' + REPLACE(m.src, N'''', N'''''') + N''''
                    + N' AND v.val IS NOT NULL AND ' + REPLACE(m.conv, N'{v}', N'v.val') + N' IS NULL'
                  AS nvarchar(max)), N' UNION ALL ')
    FROM #map m
    WHERE m.fixed IS NULL AND m.conv <> N'{v}';

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

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Delete existing rows: lines first, then headers
        IF @ReplaceExisting = 1
        BEGIN
            DECLARE del CURSOR LOCAL FAST_FORWARD FOR
                SELECT sublist, name, keycol FROM @tables ORDER BY ins_order DESC;
            OPEN del;
            FETCH NEXT FROM del INTO @s, @t, @key;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @where = STRING_AGG(CAST(N' AND t.' + QUOTENAME(c.name) + N' = N''' + REPLACE(f.val, N'''', N'''''') + N''''
                                           AS nvarchar(max)), N'')
                FROM @tables tb
                JOIN sys.columns c ON c.object_id = tb.obj
                JOIN @fixed f ON f.name = c.name COLLATE Latin1_General_CI_AS
                WHERE tb.sublist = @s;

                SET @sql = N'DELETE t FROM dbo.' + QUOTENAME(@t) + N' t WHERE t.' + QUOTENAME(@key)
                         + N' IN (SELECT b.bill_id FROM #bill b)' + ISNULL(@where, N'') + N'; SET @n = @@ROWCOUNT;';
                EXEC sys.sp_executesql @sql, N'@n int OUTPUT', @n = @n OUTPUT;
                UPDATE @result SET rows_deleted = @n WHERE table_name = @t;

                FETCH NEXT FROM del INTO @s, @t, @key;
            END
            CLOSE del;
            DEALLOCATE del;
        END

        -- Insert: headers first, then lines
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
                         + N' SELECT ' + @exprs
                         + N' FROM (SELECT DISTINCT sublist, bill_id, line_no FROM #v WHERE sublist = @s) g;'
                         + N' SET @n = @@ROWCOUNT;';
                EXEC sys.sp_executesql @sql, N'@s char(1), @n int OUTPUT', @s = @s, @n = @n OUTPUT;
            END
            UPDATE @result SET rows_inserted = @n WHERE table_name = @t;

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

    IF @ReportUnmapped = 1
        SELECT DISTINCT t.name AS table_name, v.name AS unmapped_field
        FROM #v v
        JOIN @tables t ON t.sublist = v.sublist
        WHERE NOT EXISTS (SELECT 1 FROM #map m WHERE m.sublist = v.sublist AND m.src = v.name COLLATE DATABASE_DEFAULT)
        ORDER BY t.name, v.name;
END
