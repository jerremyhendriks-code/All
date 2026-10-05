/*
    Create a "subsidiary" child table for the NetSuite objects listed below.

    One row per (record, subsidiary) pair. For the master-data objects this mirrors
    NetSuite's own mapping tables:

        child table                              parent table                   NetSuite source
        ---------------------------------------  -----------------------------  ------------------------------
        tb_Netsuite_Account_Subsidiary           tb_Netsuite_Account            AccountSubsidiaryMap
        tb_Netsuite_AccountingBook_Subsidiary    tb_Netsuite_AccountingBook     AccountingBookSubsidiaries
        tb_Netsuite_Classification_Subsidiary    tb_Netsuite_Classification     ClassificationSubsidiaryMap
        tb_Netsuite_Department_Subsidiary        tb_Netsuite_Department         DepartmentSubsidiaryMap
        tb_Netsuite_Vendor_Subsidiary            tb_Netsuite_Vendor             VendorSubsidiaryRelationship

    The transaction objects have a single subsidiary in NetSuite (transaction.subsidiary),
    so these hold one row per transaction; they keep the model the same for every object:

        tb_Netsuite_VendorBill_Subsidiary        tb_Netsuite_VendorBill         Transaction.subsidiary
        tb_Netsuite_CustomerPayment_Subsidiary   tb_Netsuite_CustomerPayment    Transaction.subsidiary
        tb_Netsuite_VendorPayment_Subsidiary     tb_Netsuite_VendorPayment      Transaction.subsidiary

    Not included:
        Location                             -> single subsidiary
        AccountingPeriod, Currency           -> not subsidiary-specific
        Subsidiary                           -> is the subsidiary itself

    For each child table:
    - The standard BPA_* control fields first, as on the other tb_Netsuite_* tables
      (same types and defaults as tools/generate_netsuite_tables.py). BPA_ParentID
      points to the BPA_EntryID of the parent row.
    - [<object>_id] and [subsidiary_id]: nvarchar(100) NULL, using the same collation
      as the parent's [id] column (database default if the parent is missing).
    - Clustered primary key on BPA_EntryID, nonclustered indexes on BPA_ParentID,
      ([<object>_id], [subsidiary_id]) and [subsidiary_id].
    - No foreign keys, so the parent and child tables can be truncated and reloaded
      independently by the integration.

    Existing tables:
    - Already has BPA_EntryID: skipped.
    - Created by the earlier version of this script (no BPA_* fields): renamed to
      <table>_bak (primary key too), the new table is created and the existing rows are
      copied into it. Drop the _bak tables once loading works. Stops without changes if
      a _bak table already exists.

    Runs in a single transaction: any error rolls everything back.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
BEGIN TRANSACTION;

DECLARE @objects TABLE (parent sysname, key_column sysname);
INSERT INTO @objects (parent, key_column) VALUES
    (N'tb_Netsuite_Account',         N'account_id'),
    (N'tb_Netsuite_AccountingBook',  N'accountingbook_id'),
    (N'tb_Netsuite_Classification',  N'classification_id'),
    (N'tb_Netsuite_Department',      N'department_id'),
    (N'tb_Netsuite_Vendor',          N'vendor_id'),
    (N'tb_Netsuite_VendorBill',      N'vendorbill_id'),
    (N'tb_Netsuite_CustomerPayment', N'customerpayment_id'),
    (N'tb_Netsuite_VendorPayment',   N'vendorpayment_id');

-- BPA_* control fields; {t} is replaced by the table name for the default constraint names
DECLARE @bpa nvarchar(max) = N'
    BPA_Origin                 nvarchar(50)     NULL,
    BPA_Direction              nvarchar(50)     NULL,
    BPA_Company                nvarchar(50)     NULL,
    BPA_EntryID                uniqueidentifier NOT NULL CONSTRAINT [DF_{t}_EntryID] DEFAULT (newsequentialid()),
    BPA_ParentID               uniqueidentifier NULL,
    BPA_Status                 int              NULL CONSTRAINT [DF_{t}_Status] DEFAULT ((0)),
    BPA_Reference              nvarchar(50)     NULL,
    BPA_Reference_Description  nvarchar(100)    NULL,
    BPA_Reference2             nvarchar(50)     NULL,
    BPA_Reference2_Description nvarchar(100)    NULL,
    BPA_Action                 nvarchar(1)      NULL,
    BPA_ReturnedID             nvarchar(50)     NULL,
    BPA_Syscreated             datetime         NULL CONSTRAINT [DF_{t}_Syscreated] DEFAULT (getdate()),
    BPA_Sysmodified            datetime         NULL CONSTRAINT [DF_{t}_Sysmodified] DEFAULT (getdate()),
    BPA_Syscreator             nvarchar(50)     NULL,
    BPA_Error                  nvarchar(max)    NULL,
    BPA_Error_Extended         nvarchar(max)    NULL,
    BPA_Description            nvarchar(255)    NULL,
    BPA_Failcount              int              NULL CONSTRAINT [DF_{t}_Failcount] DEFAULT ((0)),
    BPA_Orig_Entryid           uniqueidentifier NULL,
    BPA_TaskInstanceID         int              NULL,
    BPA_TaskID                 int              NULL,';

DECLARE @parent sysname, @key sysname, @child sysname, @bak sysname, @qc nvarchar(300),
        @qb nvarchar(300), @collation sysname, @sql nvarchar(max), @old sysname, @new sysname,
        @msg nvarchar(2048), @migrate bit, @rows int;

DECLARE obj CURSOR LOCAL FAST_FORWARD FOR SELECT parent, key_column FROM @objects;
OPEN obj;
FETCH NEXT FROM obj INTO @parent, @key;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @child   = @parent + N'_Subsidiary';
    SET @bak     = @child + N'_bak';
    SET @qc      = N'dbo.' + QUOTENAME(@child);
    SET @qb      = N'dbo.' + QUOTENAME(@bak);
    SET @migrate = 0;

    IF OBJECT_ID(@qc, N'U') IS NOT NULL AND COL_LENGTH(@qc, N'BPA_EntryID') IS NOT NULL
        PRINT N'Skipped  ' + @qc + N' (already has the BPA_* fields)';
    ELSE
    BEGIN
        -- Table from the earlier version of this script: move it aside, keep its rows
        IF OBJECT_ID(@qc, N'U') IS NOT NULL
        BEGIN
            IF OBJECT_ID(@qb, N'U') IS NOT NULL
            BEGIN
                SET @msg = @qb + N' already exists; drop or rename it first.';
                THROW 50001, @msg, 1;
            END

            EXEC sys.sp_rename @objname = @qc, @newname = @bak, @objtype = N'OBJECT';

            DECLARE con CURSOR LOCAL FAST_FORWARD FOR
                SELECT name FROM sys.objects
                WHERE parent_object_id = OBJECT_ID(@qb) AND type IN ('PK', 'UQ', 'D', 'C', 'F');
            OPEN con;
            FETCH NEXT FROM con INTO @old;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @new = LEFT(@old, 124) + N'_bak';
                SET @sql = N'dbo.' + QUOTENAME(@old);
                EXEC sys.sp_rename @objname = @sql, @newname = @new, @objtype = N'OBJECT';
                FETCH NEXT FROM con INTO @old;
            END
            CLOSE con;
            DEALLOCATE con;

            PRINT N'Renamed  ' + @qc + N' -> ' + @bak;
            SET @migrate = 1;
        END

        SET @collation = NULL;
        SELECT @collation = c.collation_name
        FROM sys.columns c
        WHERE c.object_id = OBJECT_ID(N'dbo.' + QUOTENAME(@parent)) AND c.name = N'id';
        SET @collation = ISNULL(@collation, CAST(DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS sysname));

        SET @sql = N'CREATE TABLE ' + @qc + N' (' + REPLACE(@bpa, N'{t}', @child)
                 + N'
    ' + QUOTENAME(@key) + N' nvarchar(100) COLLATE ' + @collation + N' NULL,
    [subsidiary_id] nvarchar(100) COLLATE ' + @collation + N' NULL,
    CONSTRAINT ' + QUOTENAME(N'PK_' + @child) + N' PRIMARY KEY CLUSTERED (BPA_EntryID)
);';
        EXEC sys.sp_executesql @sql;

        SET @sql = N'CREATE NONCLUSTERED INDEX ' + QUOTENAME(N'IX_' + @child + N'_ParentID')
                 + N' ON ' + @qc + N' (BPA_ParentID);'
                 + N'CREATE NONCLUSTERED INDEX ' + QUOTENAME(N'IX_' + @child + N'_' + @key)
                 + N' ON ' + @qc + N' (' + QUOTENAME(@key) + N', [subsidiary_id]);'
                 + N'CREATE NONCLUSTERED INDEX ' + QUOTENAME(N'IX_' + @child + N'_subsidiary_id')
                 + N' ON ' + @qc + N' ([subsidiary_id]);';
        EXEC sys.sp_executesql @sql;

        PRINT N'Created  ' + @qc;

        IF @migrate = 1
        BEGIN
            SET @sql = N'INSERT INTO ' + @qc + N' (' + QUOTENAME(@key) + N', [subsidiary_id])'
                     + N' SELECT ' + QUOTENAME(@key) + N', [subsidiary_id] FROM ' + @qb + N';'
                     + N' SET @rows = @@ROWCOUNT;';
            EXEC sys.sp_executesql @sql, N'@rows int OUTPUT', @rows = @rows OUTPUT;
            PRINT N'  copied ' + CAST(@rows AS nvarchar(20)) + N' row(s) from ' + @bak;
        END
    END

    FETCH NEXT FROM obj INTO @parent, @key;
END

CLOSE obj;
DEALLOCATE obj;

COMMIT TRANSACTION;

-- Verify
SELECT t.name AS table_name, c.column_id, c.name AS column_name, ty.name AS data_type,
       CASE WHEN ty.name LIKE N'n%char' AND c.max_length > 0 THEN c.max_length / 2 ELSE c.max_length END AS length,
       c.is_nullable, c.collation_name
FROM sys.tables t
JOIN sys.columns c ON c.object_id = t.object_id
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE t.schema_id = SCHEMA_ID(N'dbo') AND t.name LIKE N'tb[_]Netsuite[_]%[_]Subsidiary'
ORDER BY t.name, c.column_id;
