/*
    Add the book-specific journal entry fields to tb_Netsuite_JournalEntry.

    With Multi-Book Accounting a journal entry can post to a single book only.
    The journalEntry "accountingBook" field of the NetSuite Connector holds that
    book (empty for a normal entry that posts to all books); the book's details
    are in tb_Netsuite_AccountingBook, so only the reference is stored here.

    Skips columns that already exist.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
BEGIN TRANSACTION;

IF COL_LENGTH(N'dbo.tb_Netsuite_JournalEntry', N'isBookSpecific') IS NULL
BEGIN
    ALTER TABLE [dbo].[tb_Netsuite_JournalEntry] ADD [isBookSpecific] [bit] NULL;
    PRINT N'Added tb_Netsuite_JournalEntry.isBookSpecific';
END

IF COL_LENGTH(N'dbo.tb_Netsuite_JournalEntry', N'accountingBook_id') IS NULL
BEGIN
    ALTER TABLE [dbo].[tb_Netsuite_JournalEntry] ADD [accountingBook_id] [nvarchar](100) NULL;
    PRINT N'Added tb_Netsuite_JournalEntry.accountingBook_id';
END

IF COL_LENGTH(N'dbo.tb_Netsuite_JournalEntry', N'accountingBook_refName') IS NULL
BEGIN
    ALTER TABLE [dbo].[tb_Netsuite_JournalEntry] ADD [accountingBook_refName] [nvarchar](255) NULL;
    PRINT N'Added tb_Netsuite_JournalEntry.accountingBook_refName';
END

COMMIT TRANSACTION;
