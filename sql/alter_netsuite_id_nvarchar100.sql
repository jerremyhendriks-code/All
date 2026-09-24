/*
    Widen the [id] column from nvarchar(50) to nvarchar(100) on the NetSuite tables.

    - Keeps the column's current NULL / NOT NULL setting.
    - If [id] is part of the primary key, the PK is dropped and recreated
      (same name, same clustered/nonclustered type, same key columns).
    - Runs in a single transaction: any error rolls everything back.
*/
SET XACT_ABORT ON;
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

DECLARE @t sysname, @obj int, @nullable bit,
        @pk sysname, @pkType nvarchar(60), @pkCols nvarchar(max),
        @sql nvarchar(max);

DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM @tables;
OPEN c;
FETCH NEXT FROM c INTO @t;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @obj = OBJECT_ID(N'dbo.' + QUOTENAME(@t));
    SELECT @nullable = NULL, @pk = NULL, @pkType = NULL, @pkCols = NULL;

    SELECT @nullable = is_nullable
    FROM sys.columns
    WHERE object_id = @obj AND name = N'id';

    IF @nullable IS NULL
    BEGIN
        PRINT N'Skipped dbo.' + @t + N' (table or [id] column not found)';
    END
    ELSE
    BEGIN
        -- Primary key that contains [id], if any
        SELECT @pk = kc.name,
               @pkType = i.type_desc,
               @pkCols = STUFF((
                    SELECT N', ' + QUOTENAME(col.name)
                                 + CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N'' END
                    FROM sys.index_columns ic
                    JOIN sys.columns col ON col.object_id = ic.object_id AND col.column_id = ic.column_id
                    WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal > 0
                    ORDER BY ic.key_ordinal
                    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'')
        FROM sys.key_constraints kc
        JOIN sys.indexes i ON i.object_id = kc.parent_object_id AND i.index_id = kc.unique_index_id
        WHERE kc.parent_object_id = @obj
          AND kc.type = 'PK'
          AND EXISTS (SELECT 1
                      FROM sys.index_columns ic
                      JOIN sys.columns col ON col.object_id = ic.object_id AND col.column_id = ic.column_id
                      WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND col.name = N'id');

        IF @pk IS NOT NULL
        BEGIN
            SET @sql = N'ALTER TABLE dbo.' + QUOTENAME(@t) + N' DROP CONSTRAINT ' + QUOTENAME(@pk) + N';';
            EXEC sys.sp_executesql @sql;
        END

        SET @sql = N'ALTER TABLE dbo.' + QUOTENAME(@t) + N' ALTER COLUMN [id] nvarchar(100) '
                 + CASE WHEN @nullable = 1 THEN N'NULL' ELSE N'NOT NULL' END + N';';
        EXEC sys.sp_executesql @sql;

        IF @pk IS NOT NULL
        BEGIN
            SET @sql = N'ALTER TABLE dbo.' + QUOTENAME(@t) + N' ADD CONSTRAINT ' + QUOTENAME(@pk)
                     + N' PRIMARY KEY ' + @pkType + N' (' + @pkCols + N');';
            EXEC sys.sp_executesql @sql;
        END

        PRINT N'Altered dbo.' + @t + N'.[id] -> nvarchar(100)'
            + CASE WHEN @pk IS NOT NULL THEN N' (PK ' + @pk + N' recreated)' ELSE N'' END;
    END

    FETCH NEXT FROM c INTO @t;
END

CLOSE c;
DEALLOCATE c;

COMMIT TRANSACTION;

-- Verify
SELECT t.name AS table_name, c.name AS column_name, ty.name AS data_type,
       c.max_length / 2 AS char_length, c.is_nullable
FROM sys.tables t
JOIN sys.columns c ON c.object_id = t.object_id AND c.name = N'id'
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE t.schema_id = SCHEMA_ID(N'dbo') AND t.name LIKE N'tb[_]Netsuite[_]%'
ORDER BY t.name;
