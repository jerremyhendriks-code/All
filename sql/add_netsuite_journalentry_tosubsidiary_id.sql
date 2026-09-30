/*
    Add [toSubsidiary_id] to the NetSuite journal entry staging table, so the
    receiving subsidiary of an intercompany journal entry can be passed to the
    journalEntry.toSubsidiary child object in the NetSuite connector.

    - nvarchar(100) NULL, same width as the widened NetSuite [id] columns.
      NULL = normal (single subsidiary) journal entry.
    - Skips the table if the column already exists; safe to run more than once.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

DECLARE @table sysname = N'tb_Netsuite_JournalEntry';   -- ADJUST: journal entry staging table

IF OBJECT_ID(N'dbo.' + QUOTENAME(@table), N'U') IS NULL
    THROW 50000, N'Staging table not found; check @table.', 1;

IF COL_LENGTH(N'dbo.' + QUOTENAME(@table), N'toSubsidiary_id') IS NULL
BEGIN
    DECLARE @sql nvarchar(max) =
        N'ALTER TABLE dbo.' + QUOTENAME(@table) + N' ADD [toSubsidiary_id] nvarchar(100) NULL;';
    EXEC sys.sp_executesql @sql;
    PRINT N'Added [toSubsidiary_id] to dbo.' + @table + N'.';
END
ELSE
    PRINT N'[toSubsidiary_id] already exists on dbo.' + @table + N'; nothing changed.';
