/*
    Staging tables for NetSuite vendor bills (headers + lines).

    - Creates dbo.tb_Netsuite_VendorBill / dbo.tb_Netsuite_VendorBillLine when
      they don't exist yet.
    - When a table already exists, adds any column from the list below that it
      doesn't have. Existing columns are never changed or dropped; a column
      whose type differs from the list is reported with a PRINT so you can
      decide what to do with it.
    - Existing NOT NULL columns that aren't in the list below must have a
      default, otherwise the load procedures can't insert new rows.

    NetSuite ids (the bill, vendor, currency, ...) are nvarchar(100), the same
    as the [id] columns on the other tb_Netsuite_ tables.

    Safe to run more than once.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
BEGIN TRANSACTION;

IF OBJECT_ID(N'dbo.tb_Netsuite_VendorBill', N'U') IS NULL
    CREATE TABLE dbo.tb_Netsuite_VendorBill (
        [id] nvarchar(100) NOT NULL CONSTRAINT PK_tb_Netsuite_VendorBill PRIMARY KEY CLUSTERED
    );

IF OBJECT_ID(N'dbo.tb_Netsuite_VendorBillLine', N'U') IS NULL
    CREATE TABLE dbo.tb_Netsuite_VendorBillLine (
        vendor_bill_id nvarchar(100) NOT NULL,
        line_id        nvarchar(100) NOT NULL,
        CONSTRAINT PK_tb_Netsuite_VendorBillLine PRIMARY KEY CLUSTERED (vendor_bill_id, line_id)
    );

DECLARE @cols TABLE (
    table_name  sysname       NOT NULL,
    ordinal     int           NOT NULL,
    column_name sysname       NOT NULL,
    definition  nvarchar(200) NOT NULL,   -- type plus NULL / NOT NULL DEFAULT
    PRIMARY KEY (table_name, ordinal)
);

INSERT INTO @cols (table_name, ordinal, column_name, definition) VALUES
    (N'tb_Netsuite_VendorBill',  1, N'bill_number',            N'nvarchar(100) NULL'),
    (N'tb_Netsuite_VendorBill',  2, N'vendor_invoice_number',  N'nvarchar(100) NULL'),
    (N'tb_Netsuite_VendorBill',  3, N'external_id',            N'nvarchar(255) NULL'),
    (N'tb_Netsuite_VendorBill',  4, N'bill_date',              N'date NULL'),
    (N'tb_Netsuite_VendorBill',  5, N'due_date',               N'date NULL'),
    (N'tb_Netsuite_VendorBill',  6, N'vendor_id',              N'nvarchar(100) NULL'),
    (N'tb_Netsuite_VendorBill',  7, N'vendor_name',            N'nvarchar(400) NULL'),
    (N'tb_Netsuite_VendorBill',  8, N'memo',                   N'nvarchar(4000) NULL'),
    (N'tb_Netsuite_VendorBill',  9, N'terms_id',               N'nvarchar(100) NULL'),
    (N'tb_Netsuite_VendorBill', 10, N'terms_name',             N'nvarchar(200) NULL'),
    (N'tb_Netsuite_VendorBill', 11, N'currency_id',            N'nvarchar(100) NULL'),
    (N'tb_Netsuite_VendorBill', 12, N'currency_name',          N'nvarchar(200) NULL'),
    (N'tb_Netsuite_VendorBill', 13, N'exchange_rate',          N'decimal(28,10) NULL'),
    (N'tb_Netsuite_VendorBill', 14, N'bill_total',             N'decimal(19,4) NULL'),
    (N'tb_Netsuite_VendorBill', 15, N'amount_open',            N'decimal(19,4) NULL'),
    (N'tb_Netsuite_VendorBill', 16, N'subsidiary_id',          N'nvarchar(100) NULL'),
    (N'tb_Netsuite_VendorBill', 17, N'subsidiary_name',        N'nvarchar(400) NULL'),
    (N'tb_Netsuite_VendorBill', 18, N'department_id',          N'nvarchar(100) NULL'),
    (N'tb_Netsuite_VendorBill', 19, N'department_name',        N'nvarchar(400) NULL'),
    (N'tb_Netsuite_VendorBill', 20, N'class_id',               N'nvarchar(100) NULL'),
    (N'tb_Netsuite_VendorBill', 21, N'class_name',             N'nvarchar(400) NULL'),
    (N'tb_Netsuite_VendorBill', 22, N'location_id',            N'nvarchar(100) NULL'),
    (N'tb_Netsuite_VendorBill', 23, N'location_name',          N'nvarchar(400) NULL'),
    (N'tb_Netsuite_VendorBill', 24, N'ap_account_id',          N'nvarchar(100) NULL'),
    (N'tb_Netsuite_VendorBill', 25, N'ap_account_name',        N'nvarchar(400) NULL'),
    (N'tb_Netsuite_VendorBill', 26, N'posting_period_id',      N'nvarchar(100) NULL'),
    (N'tb_Netsuite_VendorBill', 27, N'posting_period_name',    N'nvarchar(200) NULL'),
    (N'tb_Netsuite_VendorBill', 28, N'status_code',            N'nvarchar(50) NULL'),
    (N'tb_Netsuite_VendorBill', 29, N'status_name',            N'nvarchar(200) NULL'),
    (N'tb_Netsuite_VendorBill', 30, N'approval_status_id',     N'nvarchar(100) NULL'),
    (N'tb_Netsuite_VendorBill', 31, N'approval_status_name',   N'nvarchar(200) NULL'),
    (N'tb_Netsuite_VendorBill', 32, N'is_posting',             N'bit NULL'),
    (N'tb_Netsuite_VendorBill', 33, N'is_voided',              N'bit NULL'),
    (N'tb_Netsuite_VendorBill', 34, N'created_date',           N'datetime2(0) NULL'),
    (N'tb_Netsuite_VendorBill', 35, N'last_modified',          N'datetime2(0) NULL'),
    -- Load bookkeeping (UTC, set by the procedures)
    (N'tb_Netsuite_VendorBill', 36, N'first_loaded_at',        N'datetime2(3) NULL'),
    (N'tb_Netsuite_VendorBill', 37, N'last_loaded_at',         N'datetime2(3) NULL'),
    -- 1 = was open here but not returned by the latest run: no longer open in
    -- NetSuite (paid / voided / deleted), the other values may be out of date.
    (N'tb_Netsuite_VendorBill', 38, N'is_stale',               N'bit NOT NULL CONSTRAINT DF_tb_Netsuite_VendorBill_is_stale DEFAULT (0)'),

    (N'tb_Netsuite_VendorBillLine',  1, N'line_number',        N'int NULL'),
    (N'tb_Netsuite_VendorBillLine',  2, N'line_type',          N'nvarchar(20) NULL'),
    (N'tb_Netsuite_VendorBillLine',  3, N'item_id',            N'nvarchar(100) NULL'),
    (N'tb_Netsuite_VendorBillLine',  4, N'item_name',          N'nvarchar(400) NULL'),
    (N'tb_Netsuite_VendorBillLine',  5, N'account_id',         N'nvarchar(100) NULL'),
    (N'tb_Netsuite_VendorBillLine',  6, N'account_name',       N'nvarchar(400) NULL'),
    (N'tb_Netsuite_VendorBillLine',  7, N'memo',               N'nvarchar(4000) NULL'),
    (N'tb_Netsuite_VendorBillLine',  8, N'quantity',           N'decimal(28,10) NULL'),
    (N'tb_Netsuite_VendorBillLine',  9, N'rate',               N'decimal(28,10) NULL'),
    (N'tb_Netsuite_VendorBillLine', 10, N'amount',             N'decimal(19,4) NULL'),
    (N'tb_Netsuite_VendorBillLine', 11, N'base_amount',        N'decimal(19,4) NULL'),
    (N'tb_Netsuite_VendorBillLine', 12, N'department_id',      N'nvarchar(100) NULL'),
    (N'tb_Netsuite_VendorBillLine', 13, N'department_name',    N'nvarchar(400) NULL'),
    (N'tb_Netsuite_VendorBillLine', 14, N'class_id',           N'nvarchar(100) NULL'),
    (N'tb_Netsuite_VendorBillLine', 15, N'class_name',         N'nvarchar(400) NULL'),
    (N'tb_Netsuite_VendorBillLine', 16, N'location_id',        N'nvarchar(100) NULL'),
    (N'tb_Netsuite_VendorBillLine', 17, N'location_name',      N'nvarchar(400) NULL'),
    (N'tb_Netsuite_VendorBillLine', 18, N'line_entity_id',     N'nvarchar(100) NULL'),
    (N'tb_Netsuite_VendorBillLine', 19, N'line_entity_name',   N'nvarchar(400) NULL'),
    (N'tb_Netsuite_VendorBillLine', 20, N'first_loaded_at',    N'datetime2(3) NULL'),
    (N'tb_Netsuite_VendorBillLine', 21, N'last_loaded_at',     N'datetime2(3) NULL');

DECLARE @t sysname, @c sysname, @def nvarchar(200), @sql nvarchar(max), @actual nvarchar(200);

DECLARE col CURSOR LOCAL FAST_FORWARD FOR
    SELECT table_name, column_name, definition FROM @cols ORDER BY table_name, ordinal;
OPEN col;
FETCH NEXT FROM col INTO @t, @c, @def;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @actual = NULL;

    SELECT @actual = ty.name
         + CASE
               WHEN ty.name IN (N'nvarchar', N'nchar')
                   THEN N'(' + CASE WHEN c.max_length = -1 THEN N'max' ELSE CAST(c.max_length / 2 AS nvarchar(10)) END + N')'
               WHEN ty.name IN (N'varchar', N'char')
                   THEN N'(' + CASE WHEN c.max_length = -1 THEN N'max' ELSE CAST(c.max_length AS nvarchar(10)) END + N')'
               WHEN ty.name IN (N'decimal', N'numeric')
                   THEN N'(' + CAST(c.precision AS nvarchar(10)) + N',' + CAST(c.scale AS nvarchar(10)) + N')'
               WHEN ty.name IN (N'datetime2', N'time', N'datetimeoffset')
                   THEN N'(' + CAST(c.scale AS nvarchar(10)) + N')'
               ELSE N''
           END
    FROM sys.columns c
    JOIN sys.types ty ON ty.user_type_id = c.user_type_id
    WHERE c.object_id = OBJECT_ID(N'dbo.' + QUOTENAME(@t)) AND c.name = @c;

    IF @actual IS NULL
    BEGIN
        SET @sql = N'ALTER TABLE dbo.' + QUOTENAME(@t) + N' ADD ' + QUOTENAME(@c) + N' ' + @def + N';';
        EXEC sys.sp_executesql @sql;
        PRINT N'Added    dbo.' + @t + N'.' + @c;
    END
    ELSE IF @def NOT LIKE @actual + N' %'
        PRINT N'Check    dbo.' + @t + N'.' + @c + N' is ' + @actual + N', expected ' + LEFT(@def, CHARINDEX(N' ', @def) - 1);

    FETCH NEXT FROM col INTO @t, @c, @def;
END

CLOSE col;
DEALLOCATE col;

-- Finalize looks up lines that weren't refreshed by the latest run
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID(N'dbo.tb_Netsuite_VendorBillLine')
                 AND name = N'IX_tb_Netsuite_VendorBillLine_last_loaded_at')
    -- dynamic: the column may only just have been added in this batch
    EXEC (N'CREATE NONCLUSTERED INDEX IX_tb_Netsuite_VendorBillLine_last_loaded_at
              ON dbo.tb_Netsuite_VendorBillLine (last_loaded_at) INCLUDE (vendor_bill_id);');

COMMIT TRANSACTION;
