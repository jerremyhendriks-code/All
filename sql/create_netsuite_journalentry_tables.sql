/*
    Staging tables for the journalEntry TO task (SQL -> NetSuite).

    tb_Netsuite_JournalEntry      one row per journal entry (header)
    tb_Netsuite_JournalEntryLine  two or more rows per journal entry; debits must equal credits

    [externalId] is our key and is sent to NetSuite as externalId, so re-sending the
    same entry updates it instead of creating a duplicate. [id] is the NetSuite
    internal id, written back after a successful send; NULL means "not sent yet".
    Reference columns (subsidiary, account, ...) hold NetSuite internal ids from the
    matching tb_Netsuite_* tables.

    Safe to re-run: creates only the tables that don't exist yet.
*/
SET NOCOUNT ON;

IF OBJECT_ID(N'dbo.tb_Netsuite_JournalEntry', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.tb_Netsuite_JournalEntry (
        externalId  nvarchar(100)  NOT NULL,
        id          nvarchar(100)  NULL,      -- NetSuite internal id (writeback)
        subsidiary  nvarchar(100)  NOT NULL,  -- tb_Netsuite_Subsidiary.id
        tranDate    date           NOT NULL,
        currency    nvarchar(100)  NULL,      -- tb_Netsuite_Currency.id; NULL = subsidiary base currency
        memo        nvarchar(4000) NULL,
        createdAt   datetime2(0)   NOT NULL CONSTRAINT DF_tb_Netsuite_JournalEntry_createdAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_tb_Netsuite_JournalEntry PRIMARY KEY CLUSTERED (externalId)
    );
    PRINT N'Created dbo.tb_Netsuite_JournalEntry';
END
ELSE
    PRINT N'Skipped dbo.tb_Netsuite_JournalEntry (already exists)';

IF OBJECT_ID(N'dbo.tb_Netsuite_JournalEntryLine', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.tb_Netsuite_JournalEntryLine (
        externalId  nvarchar(100)  NOT NULL,  -- tb_Netsuite_JournalEntry.externalId
        lineNumber  int            NOT NULL,
        account     nvarchar(100)  NOT NULL,  -- tb_Netsuite_Account.id
        debit       decimal(18, 2) NULL,
        credit      decimal(18, 2) NULL,
        entity      nvarchar(100)  NULL,      -- customer/vendor/employee id; required on AR/AP accounts
        department  nvarchar(100)  NULL,      -- tb_Netsuite_Department.id
        [class]     nvarchar(100)  NULL,      -- tb_Netsuite_Classification.id
        location    nvarchar(100)  NULL,      -- tb_Netsuite_Location.id
        memo        nvarchar(4000) NULL,
        CONSTRAINT PK_tb_Netsuite_JournalEntryLine PRIMARY KEY CLUSTERED (externalId, lineNumber),
        CONSTRAINT FK_tb_Netsuite_JournalEntryLine_JournalEntry FOREIGN KEY (externalId)
            REFERENCES dbo.tb_Netsuite_JournalEntry (externalId) ON DELETE CASCADE,
        -- Exactly one of debit / credit, and it must be positive
        CONSTRAINT CK_tb_Netsuite_JournalEntryLine_DebitOrCredit CHECK (
            (debit > 0 AND credit IS NULL) OR (credit > 0 AND debit IS NULL))
    );
    PRINT N'Created dbo.tb_Netsuite_JournalEntryLine';
END
ELSE
    PRINT N'Skipped dbo.tb_Netsuite_JournalEntryLine (already exists)';
