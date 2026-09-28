/*
    Child table of tb_Netsuite_JournalEntry, filled from the journalEntry
    "accountingBookDetail" sublist of the NetSuite Connector (REST record).

    - One row per journal entry + accounting book (primary and secondary books,
      Multi-Book Accounting), with that book's exchange rate for the entry.
    - BPA_ParentID holds the BPA_EntryID of the parent row in tb_Netsuite_JournalEntry.
    - The record API does not return amounts per book. Secondary-book amounts are
      derived as line amount x exchangeRate of that book, which can differ by
      rounding from what NetSuite posts.

    An earlier version of this table was modelled on SuiteQL (one row per line per
    book). If that version exists and is still empty it is dropped and recreated;
    if it holds rows the script stops without changing anything.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
BEGIN TRANSACTION;

IF COL_LENGTH(N'dbo.tb_Netsuite_JournalEntry_AccountingBook', N'transactionline') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM [dbo].[tb_Netsuite_JournalEntry_AccountingBook])
        THROW 50001, N'dbo.tb_Netsuite_JournalEntry_AccountingBook has the old SuiteQL layout and contains rows; empty or drop it manually first.', 1;

    DROP TABLE [dbo].[tb_Netsuite_JournalEntry_AccountingBook];
    PRINT N'Dropped old layout of dbo.tb_Netsuite_JournalEntry_AccountingBook';
END

IF OBJECT_ID(N'dbo.tb_Netsuite_JournalEntry_AccountingBook', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[tb_Netsuite_JournalEntry_AccountingBook](
        [BPA_Origin] [nvarchar](50) NULL,
        [BPA_Direction] [nvarchar](50) NULL,
        [BPA_Company] [nvarchar](50) NULL,
        [BPA_EntryID] [uniqueidentifier] NOT NULL
            CONSTRAINT [DF_tb_Netsuite_JournalEntry_AccountingBook_EntryID] DEFAULT (newsequentialid()),
        [BPA_ParentID] [uniqueidentifier] NULL,
        [BPA_Status] [int] NULL
            CONSTRAINT [DF_tb_Netsuite_JournalEntry_AccountingBook_Status] DEFAULT ((0)),
        [BPA_Reference] [nvarchar](50) NULL,
        [BPA_Reference_Description] [nvarchar](100) NULL,
        [BPA_Reference2] [nvarchar](50) NULL,
        [BPA_Reference2_Description] [nvarchar](100) NULL,
        [BPA_Action] [nvarchar](1) NULL,
        [BPA_ReturnedID] [nvarchar](50) NULL,
        [BPA_Syscreated] [datetime] NULL
            CONSTRAINT [DF_tb_Netsuite_JournalEntry_AccountingBook_Syscreated] DEFAULT (getdate()),
        [BPA_Sysmodified] [datetime] NULL
            CONSTRAINT [DF_tb_Netsuite_JournalEntry_AccountingBook_Sysmodified] DEFAULT (getdate()),
        [BPA_Syscreator] [nvarchar](50) NULL,
        [BPA_Error] [nvarchar](max) NULL,
        [BPA_Error_Extended] [nvarchar](max) NULL,
        [BPA_Description] [nvarchar](255) NULL,
        [BPA_Failcount] [int] NULL
            CONSTRAINT [DF_tb_Netsuite_JournalEntry_AccountingBook_Failcount] DEFAULT ((0)),
        [BPA_Orig_Entryid] [uniqueidentifier] NULL,
        [BPA_TaskInstanceID] [int] NULL,
        [BPA_TaskID] [int] NULL,

        [accountingBook_id] [nvarchar](100) NULL,       -- accountingBook.id
        [accountingBook_refName] [nvarchar](255) NULL,  -- accountingBook.refName
        [exchangeRate] [decimal](28, 10) NULL,

        CONSTRAINT [PK_tb_Netsuite_JournalEntry_AccountingBook] PRIMARY KEY CLUSTERED
        (
            [BPA_EntryID] ASC
        ) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
    ) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY];

    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_JournalEntry_AccountingBook_BPA_ParentID]
        ON [dbo].[tb_Netsuite_JournalEntry_AccountingBook] ([BPA_ParentID]);

    PRINT N'Created dbo.tb_Netsuite_JournalEntry_AccountingBook';
END
ELSE
    PRINT N'Skipped dbo.tb_Netsuite_JournalEntry_AccountingBook (already exists)';

COMMIT TRANSACTION;
