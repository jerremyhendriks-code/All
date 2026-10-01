/*
    Bring dbo.tb_Netsuite_VendorBill in line with the vendorBill connector schema
    (schemas/netsuite/vendorBill.xsd) for the openstaande posten FROM task.

    1. Adds the header fields needed for open items. String fields follow the
       table's existing nvarchar(255); amounts, dates and booleans get real types
       so open amounts can be calculated without conversions.
    2. Changes BPA_Error, BPA_Error_Extended and BPA_Description from varchar to
       nvarchar, as in the other tb_Netsuite_* tables, so error text with non-ASCII
       characters is kept.
    3. Gives the unnamed default constraints the DF_<table>_<field> names the other
       tb_Netsuite_* tables use.

    Existing columns and data are not changed otherwise, so the current FROM task
    mapping keeps working. Each step is skipped when already done, so the script is
    safe to run more than once. Runs in a single transaction: any error rolls
    everything back.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
BEGIN TRANSACTION;

DECLARE @tbl nvarchar(300) = N'dbo.tb_Netsuite_VendorBill';
DECLARE @obj int = OBJECT_ID(@tbl, N'U');
DECLARE @name sysname, @def nvarchar(400), @sql nvarchar(max), @old sysname, @new sysname;

IF @obj IS NULL
    THROW 50001, N'dbo.tb_Netsuite_VendorBill not found.', 1;

/* 1. New columns */
DECLARE @cols TABLE (seq int IDENTITY, name sysname, def nvarchar(400));
INSERT INTO @cols (name, def) VALUES
    (N'transactionNumber', N'nvarchar(255)  NULL'),
    (N'documentStatus',    N'nvarchar(255)  NULL'),
    (N'dueDate',           N'date           NULL'),
    (N'accountId',         N'nvarchar(255)  NULL'),
    (N'accountRefName',    N'nvarchar(255)  NULL'),
    (N'exchangeRate',      N'decimal(28,10) NULL'),
    (N'total',             N'decimal(19,4)  NULL'),
    (N'userTotal',         N'decimal(19,4)  NULL'),
    (N'taxTotal',          N'decimal(19,4)  NULL'),
    (N'discountAmount',    N'decimal(19,4)  NULL'),
    (N'discountDate',      N'date           NULL'),
    (N'paymentHold',       N'bit            NULL'),
    (N'vatRegNum',         N'nvarchar(255)  NULL'),
    (N'memo',              N'nvarchar(4000) NULL');

DECLARE col CURSOR LOCAL FAST_FORWARD FOR SELECT name, def FROM @cols ORDER BY seq;
OPEN col;
FETCH NEXT FROM col INTO @name, @def;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF COL_LENGTH(@tbl, @name) IS NULL
    BEGIN
        SET @sql = N'ALTER TABLE ' + @tbl + N' ADD ' + QUOTENAME(@name) + N' ' + @def + N';';
        EXEC sys.sp_executesql @sql;
        PRINT N'Added    ' + @name;
    END
    ELSE
        PRINT N'Skipped  ' + @name + N' (already exists)';
    FETCH NEXT FROM col INTO @name, @def;
END
CLOSE col;
DEALLOCATE col;

/* 2. varchar -> nvarchar for the BPA error/description fields */
DECLARE @types TABLE (name sysname, def nvarchar(100));
INSERT INTO @types (name, def) VALUES
    (N'BPA_Error',          N'nvarchar(max) NULL'),
    (N'BPA_Error_Extended', N'nvarchar(max) NULL'),
    (N'BPA_Description',    N'nvarchar(255) NULL');

DECLARE typ CURSOR LOCAL FAST_FORWARD FOR
    SELECT t.name, t.def
    FROM @types t
    JOIN sys.columns c ON c.object_id = @obj AND c.name = t.name
    WHERE c.system_type_id = TYPE_ID(N'varchar');
OPEN typ;
FETCH NEXT FROM typ INTO @name, @def;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'ALTER TABLE ' + @tbl + N' ALTER COLUMN ' + QUOTENAME(@name) + N' ' + @def + N';';
    EXEC sys.sp_executesql @sql;
    PRINT N'Altered  ' + @name + N' -> ' + @def;
    FETCH NEXT FROM typ INTO @name, @def;
END
CLOSE typ;
DEALLOCATE typ;

/* 3. Name the default constraints */
DECLARE @dfs TABLE (col sysname, new_name sysname);
INSERT INTO @dfs (col, new_name) VALUES
    (N'BPA_EntryID',     N'DF_tb_Netsuite_VendorBill_EntryID'),
    (N'BPA_Status',      N'DF_tb_Netsuite_VendorBill_Status'),
    (N'BPA_Syscreated',  N'DF_tb_Netsuite_VendorBill_Syscreated'),
    (N'BPA_Sysmodified', N'DF_tb_Netsuite_VendorBill_Sysmodified'),
    (N'BPA_Failcount',   N'DF_tb_Netsuite_VendorBill_Failcount');

DECLARE df CURSOR LOCAL FAST_FORWARD FOR
    SELECT dc.name, d.new_name
    FROM @dfs d
    JOIN sys.columns c ON c.object_id = @obj AND c.name = d.col
    JOIN sys.default_constraints dc ON dc.parent_object_id = @obj AND dc.parent_column_id = c.column_id
    WHERE dc.name <> d.new_name
      AND OBJECT_ID(N'dbo.' + QUOTENAME(d.new_name)) IS NULL;
OPEN df;
FETCH NEXT FROM df INTO @old, @new;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'dbo.' + QUOTENAME(@old);
    EXEC sys.sp_rename @objname = @sql, @newname = @new, @objtype = N'OBJECT';
    PRINT N'Renamed  ' + @old + N' -> ' + @new;
    FETCH NEXT FROM df INTO @old, @new;
END
CLOSE df;
DEALLOCATE df;

COMMIT TRANSACTION;
