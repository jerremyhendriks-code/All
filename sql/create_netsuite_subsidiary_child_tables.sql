/*
    Create a "subsidiary" child table for every NetSuite object that can be
    shared across several subsidiaries.

    One row per (record, subsidiary) pair, mirroring NetSuite's own mapping tables:

        child table                              parent table                   NetSuite source
        ---------------------------------------  -----------------------------  ------------------------------
        tb_Netsuite_Account_Subsidiary           tb_Netsuite_Account            AccountSubsidiaryMap
        tb_Netsuite_AccountingBook_Subsidiary    tb_Netsuite_AccountingBook     AccountingBookSubsidiaries
        tb_Netsuite_Classification_Subsidiary    tb_Netsuite_Classification     ClassificationSubsidiaryMap
        tb_Netsuite_Department_Subsidiary        tb_Netsuite_Department         DepartmentSubsidiaryMap
        tb_Netsuite_Vendor_Subsidiary            tb_Netsuite_Vendor             VendorSubsidiaryRelationship

    Not included, because the record belongs to exactly one subsidiary (a plain
    subsidiary column on the parent table is enough) or to none:
        Location, VendorBill, VendorPayment  -> single subsidiary
        AccountingPeriod, Currency           -> not subsidiary-specific
        Subsidiary                           -> is the subsidiary itself

    For each child table:
    - [<object>_id] and [subsidiary_id] are nvarchar(100) NOT NULL, using the same
      collation as the parent's [id] column (database default if the parent is missing).
    - Clustered primary key on ([<object>_id], [subsidiary_id]), plus a nonclustered
      index on [subsidiary_id] for lookups by subsidiary.
    - No foreign keys, so the parent and child tables can be truncated and reloaded
      independently by the integration.
    - Skips tables that already exist.
    - Runs in a single transaction: any error rolls everything back.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
BEGIN TRANSACTION;

DECLARE @objects TABLE (parent sysname, key_column sysname);
INSERT INTO @objects (parent, key_column) VALUES
    (N'tb_Netsuite_Account',        N'account_id'),
    (N'tb_Netsuite_AccountingBook', N'accountingbook_id'),
    (N'tb_Netsuite_Classification', N'classification_id'),
    (N'tb_Netsuite_Department',     N'department_id'),
    (N'tb_Netsuite_Vendor',         N'vendor_id');

DECLARE @parent sysname, @key sysname, @child sysname, @qc nvarchar(300),
        @collation sysname, @sql nvarchar(max);

DECLARE obj CURSOR LOCAL FAST_FORWARD FOR SELECT parent, key_column FROM @objects;
OPEN obj;
FETCH NEXT FROM obj INTO @parent, @key;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @child = @parent + N'_Subsidiary';
    SET @qc    = N'dbo.' + QUOTENAME(@child);

    IF OBJECT_ID(@qc, N'U') IS NOT NULL
        PRINT N'Skipped ' + @qc + N' (already exists)';
    ELSE
    BEGIN
        SET @collation = NULL;
        SELECT @collation = c.collation_name
        FROM sys.columns c
        WHERE c.object_id = OBJECT_ID(N'dbo.' + QUOTENAME(@parent)) AND c.name = N'id';
        SET @collation = ISNULL(@collation, CAST(DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS sysname));

        SET @sql = N'CREATE TABLE ' + @qc + N' ('
                 + N' ' + QUOTENAME(@key) + N' nvarchar(100) COLLATE ' + @collation + N' NOT NULL,'
                 + N' [subsidiary_id] nvarchar(100) COLLATE ' + @collation + N' NOT NULL,'
                 + N' CONSTRAINT ' + QUOTENAME(N'PK_' + @child)
                 + N' PRIMARY KEY CLUSTERED (' + QUOTENAME(@key) + N' ASC, [subsidiary_id] ASC)'
                 + N');';
        EXEC sys.sp_executesql @sql;

        SET @sql = N'CREATE NONCLUSTERED INDEX ' + QUOTENAME(N'IX_' + @child + N'_subsidiary_id')
                 + N' ON ' + @qc + N' ([subsidiary_id] ASC);';
        EXEC sys.sp_executesql @sql;

        PRINT N'Created ' + @qc;
    END

    FETCH NEXT FROM obj INTO @parent, @key;
END

CLOSE obj;
DEALLOCATE obj;

COMMIT TRANSACTION;

-- Verify
SELECT t.name AS table_name, c.column_id, c.name AS column_name, ty.name AS data_type,
       c.max_length / 2 AS char_length, c.is_nullable, c.collation_name
FROM sys.tables t
JOIN sys.columns c ON c.object_id = t.object_id
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE t.schema_id = SCHEMA_ID(N'dbo') AND t.name LIKE N'tb[_]Netsuite[_]%[_]Subsidiary'
ORDER BY t.name, c.column_id;
