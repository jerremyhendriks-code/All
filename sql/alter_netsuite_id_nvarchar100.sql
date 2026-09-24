/*
    Widen the [id] column from nvarchar(50) to nvarchar(100) on the NetSuite tables.

    For each table:
    - Keeps the column's current NULL / NOT NULL setting and collation.
    - Drops every index, primary key, unique constraint and user-created statistic
      that uses [id], alters the column, then recreates them with the same name,
      type (clustered / nonclustered / unique), key columns and sort order, included
      columns, filter, fill factor, IGNORE_DUP_KEY, data compression and filegroup.
    - Skips tables where [id] is already nvarchar(100) or wider.
    - Runs in a single transaction: any error rolls everything back.

    Stops with an error (nothing changed) if [id] is used by an index type this
    script doesn't recreate (columnstore, XML, spatial) or a partitioned index.
    Foreign keys in other tables that reference these keys are not handled; the
    drop will fail with an error naming them.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
BEGIN TRANSACTION;

DECLARE @tables TABLE (name sysname);
INSERT INTO @tables (name) VALUES
    (N'tb_Netsuite_Account'),
    (N'tb_Netsuite_AccountingBook'),
    (N'tb_Netsuite_AccountingPeriod'),
    (N'tb_Netsuite_Classification'),
    (N'tb_Netsuite_Currency'),
    (N'tb_Netsuite_Department'),
    (N'tb_Netsuite_Location'),
    (N'tb_Netsuite_Subsidiary'),
    (N'tb_Netsuite_Vendor'),
    (N'tb_Netsuite_VendorBill'),
    (N'tb_Netsuite_VendorPayment');

IF OBJECT_ID(N'tempdb..#deps') IS NOT NULL DROP TABLE #deps;
CREATE TABLE #deps (
    obj_name   sysname       NOT NULL,
    drop_order int           NOT NULL,  -- stats, then nonclustered, then clustered
    drop_sql   nvarchar(max) NOT NULL,
    create_sql nvarchar(max) NOT NULL
);

DECLARE @t sysname, @qt nvarchar(300), @obj int, @nullable bit, @collation sysname,
        @maxlen smallint, @sql nvarchar(max), @name sysname, @msg nvarchar(2048);

DECLARE tbl CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM @tables;
OPEN tbl;
FETCH NEXT FROM tbl INTO @t;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @qt  = N'dbo.' + QUOTENAME(@t);
    SET @obj = OBJECT_ID(@qt);
    SELECT @nullable = NULL, @collation = NULL, @maxlen = NULL;

    SELECT @nullable = c.is_nullable, @collation = c.collation_name, @maxlen = c.max_length
    FROM sys.columns c
    WHERE c.object_id = @obj AND c.name = N'id';

    IF @nullable IS NULL
        PRINT N'Skipped ' + @qt + N' (table or [id] column not found)';
    ELSE IF @maxlen = -1 OR @maxlen >= 200
        PRINT N'Skipped ' + @qt + N' ([id] is already nvarchar(100) or wider)';
    ELSE
    BEGIN
        -- Refuse index types / layouts this script can't faithfully recreate
        IF EXISTS (SELECT 1
                   FROM sys.indexes i
                   JOIN sys.data_spaces ds ON ds.data_space_id = i.data_space_id
                   JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
                   JOIN sys.columns col ON col.object_id = ic.object_id AND col.column_id = ic.column_id
                   WHERE i.object_id = @obj AND col.name = N'id'
                     AND (i.type NOT IN (1, 2) OR ds.type <> 'FG'))
        BEGIN
            SET @msg = N'[id] on ' + @qt + N' is used by a columnstore/XML/spatial or partitioned index; handle it manually.';
            THROW 50001, @msg, 1;
        END

        TRUNCATE TABLE #deps;

        -- Indexes, primary keys and unique constraints that use [id]
        INSERT INTO #deps (obj_name, drop_order, drop_sql, create_sql)
        SELECT i.name,
               CASE WHEN i.type = 1 THEN 3 ELSE 2 END,
               CASE WHEN i.is_primary_key = 1 OR i.is_unique_constraint = 1
                    THEN N'ALTER TABLE ' + @qt + N' DROP CONSTRAINT ' + QUOTENAME(i.name) + N';'
                    ELSE N'DROP INDEX ' + QUOTENAME(i.name) + N' ON ' + @qt + N';' END,
               CASE WHEN i.is_primary_key = 1 OR i.is_unique_constraint = 1
                    THEN N'ALTER TABLE ' + @qt + N' ADD CONSTRAINT ' + QUOTENAME(i.name)
                         + CASE WHEN i.is_primary_key = 1 THEN N' PRIMARY KEY ' ELSE N' UNIQUE ' END
                         + i.type_desc + N' (' + k.cols + N')'
                    ELSE N'CREATE ' + CASE WHEN i.is_unique = 1 THEN N'UNIQUE ' ELSE N'' END
                         + i.type_desc + N' INDEX ' + QUOTENAME(i.name) + N' ON ' + @qt
                         + N' (' + k.cols + N')'
                         + ISNULL(N' INCLUDE (' + inc.cols + N')', N'')
                         + CASE WHEN i.has_filter = 1 THEN N' WHERE ' + i.filter_definition ELSE N'' END
               END
               + N' WITH (IGNORE_DUP_KEY = ' + CASE WHEN i.ignore_dup_key = 1 THEN N'ON' ELSE N'OFF' END
               + CASE WHEN i.fill_factor > 0 THEN N', FILLFACTOR = ' + CAST(i.fill_factor AS nvarchar(3)) ELSE N'' END
               + N', DATA_COMPRESSION = ' + p.data_compression_desc + N')'
               + N' ON ' + QUOTENAME(ds.name) + N';'
        FROM sys.indexes i
        JOIN sys.data_spaces ds ON ds.data_space_id = i.data_space_id
        CROSS APPLY (SELECT TOP (1) pt.data_compression_desc
                     FROM sys.partitions pt
                     WHERE pt.object_id = i.object_id AND pt.index_id = i.index_id) p
        CROSS APPLY (SELECT cols = STUFF((
                        SELECT N', ' + QUOTENAME(col.name)
                                     + CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N' ASC' END
                        FROM sys.index_columns ic
                        JOIN sys.columns col ON col.object_id = ic.object_id AND col.column_id = ic.column_id
                        WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id
                          AND ic.key_ordinal > 0
                        ORDER BY ic.key_ordinal
                        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'')) k
        CROSS APPLY (SELECT cols = STUFF((
                        SELECT N', ' + QUOTENAME(col.name)
                        FROM sys.index_columns ic
                        JOIN sys.columns col ON col.object_id = ic.object_id AND col.column_id = ic.column_id
                        WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id
                          AND ic.is_included_column = 1
                        ORDER BY ic.index_column_id
                        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'')) inc
        WHERE i.object_id = @obj
          AND i.type IN (1, 2)
          AND EXISTS (SELECT 1
                      FROM sys.index_columns ic
                      JOIN sys.columns col ON col.object_id = ic.object_id AND col.column_id = ic.column_id
                      WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND col.name = N'id');

        -- User-created statistics that use [id] (index statistics go with their index)
        INSERT INTO #deps (obj_name, drop_order, drop_sql, create_sql)
        SELECT s.name,
               1,
               N'DROP STATISTICS ' + @qt + N'.' + QUOTENAME(s.name) + N';',
               N'CREATE STATISTICS ' + QUOTENAME(s.name) + N' ON ' + @qt + N' (' + sc.cols + N')'
               + CASE WHEN s.has_filter = 1 THEN N' WHERE ' + s.filter_definition ELSE N'' END + N';'
        FROM sys.stats s
        CROSS APPLY (SELECT cols = STUFF((
                        SELECT N', ' + QUOTENAME(col.name)
                        FROM sys.stats_columns stc
                        JOIN sys.columns col ON col.object_id = stc.object_id AND col.column_id = stc.column_id
                        WHERE stc.object_id = s.object_id AND stc.stats_id = s.stats_id
                        ORDER BY stc.stats_column_id
                        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'')) sc
        WHERE s.object_id = @obj
          AND s.user_created = 1
          AND EXISTS (SELECT 1
                      FROM sys.stats_columns stc
                      JOIN sys.columns col ON col.object_id = stc.object_id AND col.column_id = stc.column_id
                      WHERE stc.object_id = s.object_id AND stc.stats_id = s.stats_id AND col.name = N'id');

        -- 1. Drop dependents (stats, nonclustered, then clustered)
        DECLARE d CURSOR LOCAL FAST_FORWARD FOR
            SELECT obj_name, drop_sql FROM #deps ORDER BY drop_order, obj_name;
        OPEN d;
        FETCH NEXT FROM d INTO @name, @sql;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC sys.sp_executesql @sql;
            PRINT N'  dropped   ' + @name;
            FETCH NEXT FROM d INTO @name, @sql;
        END
        CLOSE d;
        DEALLOCATE d;

        -- 2. Alter the column
        SET @sql = N'ALTER TABLE ' + @qt + N' ALTER COLUMN [id] nvarchar(100) COLLATE ' + @collation
                 + CASE WHEN @nullable = 1 THEN N' NULL' ELSE N' NOT NULL' END + N';';
        EXEC sys.sp_executesql @sql;

        -- 3. Recreate dependents (clustered, nonclustered, then stats)
        DECLARE r CURSOR LOCAL FAST_FORWARD FOR
            SELECT obj_name, create_sql FROM #deps ORDER BY drop_order DESC, obj_name;
        OPEN r;
        FETCH NEXT FROM r INTO @name, @sql;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC sys.sp_executesql @sql;
            PRINT N'  recreated ' + @name;
            FETCH NEXT FROM r INTO @name, @sql;
        END
        CLOSE r;
        DEALLOCATE r;

        PRINT N'Altered ' + @qt + N'.[id] -> nvarchar(100)';
    END

    FETCH NEXT FROM tbl INTO @t;
END

CLOSE tbl;
DEALLOCATE tbl;

DROP TABLE #deps;

COMMIT TRANSACTION;

-- Verify
SELECT t.name AS table_name, c.name AS column_name, ty.name AS data_type,
       c.max_length / 2 AS char_length, c.is_nullable
FROM sys.tables t
JOIN sys.columns c ON c.object_id = t.object_id AND c.name = N'id'
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE t.schema_id = SCHEMA_ID(N'dbo') AND t.name LIKE N'tb[_]Netsuite[_]%'
ORDER BY t.name;
