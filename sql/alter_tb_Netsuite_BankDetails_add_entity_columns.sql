/*
    Add the vendor / customer link of the entity bank details
    (custrecord_2663_parent_vendor / custrecord_2663_parent_customer) to the
    bank details staging table.

    - Set @table to the name of the bank details table before running.
    - Skips columns that already exist; runs in a single transaction.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

DECLARE @table sysname = N'tb_Netsuite_BankDetails';

DECLARE @qt  nvarchar(300) = N'dbo.' + QUOTENAME(@table),
        @sql nvarchar(max), @col sysname, @type nvarchar(50), @msg nvarchar(2048);

IF OBJECT_ID(@qt, N'U') IS NULL
BEGIN
    SET @msg = @qt + N' does not exist; set @table to the bank details table.';
    THROW 50001, @msg, 1;
END

DECLARE @cols TABLE (ord int, name sysname, type nvarchar(50));
INSERT INTO @cols (ord, name, type) VALUES
    (1, N'customerid',      N'nvarchar(100)'),   -- custrecord_2663_parent_customer.id
    (2, N'customerrefname', N'nvarchar(400)'),   -- custrecord_2663_parent_customer.refName
    (3, N'vendorid',        N'nvarchar(100)'),   -- custrecord_2663_parent_vendor.id
    (4, N'vendorrefname',   N'nvarchar(400)');   -- custrecord_2663_parent_vendor.refName

BEGIN TRANSACTION;

DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT name, type FROM @cols ORDER BY ord;
OPEN c;
FETCH NEXT FROM c INTO @col, @type;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF COL_LENGTH(@qt, @col) IS NULL
    BEGIN
        SET @sql = N'ALTER TABLE ' + @qt + N' ADD ' + QUOTENAME(@col) + N' ' + @type + N' NULL;';
        EXEC sys.sp_executesql @sql;
        PRINT N'Added ' + @qt + N'.' + @col;
    END
    ELSE
        PRINT N'Skipped ' + @qt + N'.' + @col + N' (already exists)';
    FETCH NEXT FROM c INTO @col, @type;
END
CLOSE c;
DEALLOCATE c;

COMMIT TRANSACTION;
