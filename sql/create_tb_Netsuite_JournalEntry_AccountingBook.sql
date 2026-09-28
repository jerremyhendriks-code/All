/*
    Child table of tb_Netsuite_JournalEntry: the GL impact of each journal entry
    line per accounting book (primary and secondary books, Multi-Book Accounting).

    - One row per journal entry + line + accounting book.
    - BPA_ParentID holds the BPA_EntryID of the parent row in tb_Netsuite_JournalEntry.
    - Amounts are in the base currency of the line's subsidiary for that book.
    - Book-specific journal entries only have rows for their own book.

    Source (SuiteQL):

        SELECT tal.transaction,
               tal.transactionline,
               tal.accountingbook,
               tl.subsidiary,
               tal.account,
               tal.debit,
               tal.credit,
               tal.amount,
               tal.netamount,
               tal.exchangerate,
               tal.posting,
               t.lastmodifieddate
        FROM transactionaccountingline tal
        JOIN transaction t      ON t.id = tal.transaction
        JOIN transactionline tl ON tl.transaction = tal.transaction
                               AND tl.id = tal.transactionline
        WHERE t.type = 'Journal'

    A changed journal entry can change its lines in every book, so replace all rows
    for a changed [transaction] on each sync instead of upserting line by line.
*/
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

        [transaction] [nvarchar](100) NULL,      -- journal entry id
        [transactionline] [nvarchar](100) NULL,  -- line id within the journal entry
        [accountingbook] [nvarchar](100) NULL,
        [subsidiary] [nvarchar](100) NULL,       -- administration
        [account] [nvarchar](100) NULL,
        [debit] [decimal](19, 4) NULL,
        [credit] [decimal](19, 4) NULL,
        [amount] [decimal](19, 4) NULL,
        [netamount] [decimal](19, 4) NULL,
        [exchangerate] [decimal](28, 10) NULL,
        [posting] [nvarchar](1) NULL,            -- 'T' / 'F'
        [lastmodifieddate] [datetime] NULL,

        CONSTRAINT [PK_tb_Netsuite_JournalEntry_AccountingBook] PRIMARY KEY CLUSTERED
        (
            [BPA_EntryID] ASC
        ) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
    ) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY];

    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_JournalEntry_AccountingBook_BPA_ParentID]
        ON [dbo].[tb_Netsuite_JournalEntry_AccountingBook] ([BPA_ParentID]);

    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_JournalEntry_AccountingBook_Key]
        ON [dbo].[tb_Netsuite_JournalEntry_AccountingBook] ([transaction], [transactionline], [accountingbook]);

    PRINT N'Created dbo.tb_Netsuite_JournalEntry_AccountingBook';
END
ELSE
    PRINT N'Skipped dbo.tb_Netsuite_JournalEntry_AccountingBook (already exists)';
