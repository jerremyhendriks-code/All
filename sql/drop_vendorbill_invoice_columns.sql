/*
    Remove the invoice columns that were added to tb_Netsuite_VendorBill when the
    vendor bill task accidentally ran the invoice query:
        invoice_id, customer_id, customer_name, invoice_number
    The vendor bill query now returns these as vendor_bill_id, vendor_id,
    vendor_name and vendor_bill_number again.

    - Shows how many rows hold data in these columns before dropping them.
    - Drops DEFAULT / CHECK constraints and user-created statistics on the columns
      first, since they would block the DROP COLUMN.
    - Skips columns that don't exist, so it is safe to run more than once.
    - Runs in a single transaction: any error rolls everything back.

    Stops with an error (nothing changed) if one of the columns is used by an index,
    key or foreign key, so you can decide what to do with it.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

DECLARE @qt nvarchar(300) = N'dbo.' + QUOTENAME(N'tb_Netsuite_VendorBill');
DECLARE @obj int = OBJECT_ID(@qt);

IF @obj IS NULL
    THROW 50001, N'Table dbo.tb_Netsuite_VendorBill not found.', 1;

DECLARE @cols TABLE (name sysname);
INSERT INTO @cols (name) VALUES
    (N'invoice_id'),
    (N'customer_id'),
    (N'customer_name'),
    (N'invoice_number');

DECLARE @c sysname, @sql nvarchar(max), @name sysname, @msg nvarchar(2048), @n int;

-- Preview: rows that hold data in each column (these values are lost on drop)
DECLARE pv CURSOR LOCAL FAST_FORWARD FOR
    SELECT c.name FROM @cols c
    WHERE EXISTS (SELECT 1 FROM sys.columns sc WHERE sc.object_id = @obj AND sc.name = c.name);
OPEN pv;
FETCH NEXT FROM pv INTO @c;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'SELECT @n = COUNT(*) FROM ' + @qt + N' WHERE ' + QUOTENAME(@c) + N' IS NOT NULL;';
    EXEC sys.sp_executesql @sql, N'@n int OUTPUT', @n = @n OUTPUT;
    PRINT N'  ' + @c + N': ' + CAST(@n AS nvarchar(20)) + N' non-null rows';
    FETCH NEXT FROM pv INTO @c;
END
CLOSE pv;
DEALLOCATE pv;

-- Refuse if a column is part of an index, key or foreign key
SELECT @msg = ISNULL(@msg + N', ', N'') + N'[' + col.name + N'] in ' + i.name
FROM sys.indexes i
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
JOIN sys.columns col ON col.object_id = ic.object_id AND col.column_id = ic.column_id
WHERE i.object_id = @obj AND col.name IN (SELECT name FROM @cols);
IF @msg IS NOT NULL
BEGIN
    SET @msg = N'Columns used by an index or key on ' + @qt + N': ' + @msg + N'. Drop or change those first.';
    THROW 50002, @msg, 1;
END

SET @msg = NULL;
SELECT @msg = ISNULL(@msg + N', ', N'') + N'[' + col.name + N'] in ' + fk.name
FROM sys.foreign_key_columns fkc
JOIN sys.foreign_keys fk ON fk.object_id = fkc.constraint_object_id
JOIN sys.columns col ON col.object_id = fkc.parent_object_id AND col.column_id = fkc.parent_column_id
WHERE fkc.parent_object_id = @obj AND col.name IN (SELECT name FROM @cols);
IF @msg IS NOT NULL
BEGIN
    SET @msg = N'Columns used by a foreign key on ' + @qt + N': ' + @msg + N'. Drop those first.';
    THROW 50003, @msg, 1;
END

BEGIN TRANSACTION;

-- 1. Drop DEFAULT / CHECK constraints and user-created statistics on the columns
DECLARE d CURSOR LOCAL FAST_FORWARD FOR
    SELECT dc.name, N'ALTER TABLE ' + @qt + N' DROP CONSTRAINT ' + QUOTENAME(dc.name) + N';'
    FROM sys.default_constraints dc
    JOIN sys.columns col ON col.object_id = dc.parent_object_id AND col.column_id = dc.parent_column_id
    WHERE dc.parent_object_id = @obj AND col.name IN (SELECT name FROM @cols)
    UNION ALL
    SELECT cc.name, N'ALTER TABLE ' + @qt + N' DROP CONSTRAINT ' + QUOTENAME(cc.name) + N';'
    FROM sys.check_constraints cc
    JOIN sys.columns col ON col.object_id = cc.parent_object_id AND col.column_id = cc.parent_column_id
    WHERE cc.parent_object_id = @obj AND col.name IN (SELECT name FROM @cols)
    UNION ALL
    SELECT s.name, N'DROP STATISTICS ' + @qt + N'.' + QUOTENAME(s.name) + N';'
    FROM sys.stats s
    WHERE s.object_id = @obj
      AND s.user_created = 1
      AND EXISTS (SELECT 1
                  FROM sys.stats_columns stc
                  JOIN sys.columns col ON col.object_id = stc.object_id AND col.column_id = stc.column_id
                  WHERE stc.object_id = s.object_id AND stc.stats_id = s.stats_id
                    AND col.name IN (SELECT name FROM @cols));
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

-- 2. Drop the columns
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM @cols;
OPEN c;
FETCH NEXT FROM c INTO @c;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF COL_LENGTH(@qt, @c) IS NULL
        PRINT N'Skipped ' + @qt + N'.' + QUOTENAME(@c) + N' (column not found)';
    ELSE
    BEGIN
        SET @sql = N'ALTER TABLE ' + @qt + N' DROP COLUMN ' + QUOTENAME(@c) + N';';
        EXEC sys.sp_executesql @sql;
        PRINT N'Dropped ' + @qt + N'.' + QUOTENAME(@c);
    END
    FETCH NEXT FROM c INTO @c;
END
CLOSE c;
DEALLOCATE c;

COMMIT TRANSACTION;

-- Verify: remaining columns on the table
SELECT c.column_id, c.name AS column_name, ty.name AS data_type, c.max_length, c.is_nullable
FROM sys.columns c
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE c.object_id = @obj
ORDER BY c.column_id;
