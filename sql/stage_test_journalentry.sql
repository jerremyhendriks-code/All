/*
    Stage ONE bank transaction as a NetSuite journal entry (test).

    Uses only existing tables: reads tb_Bank_Transactions, writes
    tb_Netsuite_JournalEntry (header) + tb_Netsuite_JournalEntry_Line (2 lines,
    linked by Line.BPA_ParentID = Header.BPA_EntryID).

    Fill in the variables below, run step 1 (preview), then step 2.
    Running step 2 twice does nothing: it stops when the externalId already exists.
    The bank transaction itself is not changed.
*/
USE [BPAStaging]
GO

-- The bank transaction to stage. Default: the bank costs line "Kosten", -39.32
DECLARE @BankTransactionID uniqueidentifier = '7A8EE1D3-C1C3-F111-9386-00155D0A0313';

-- NetSuite internal IDs
DECLARE @SubsidiaryID    nvarchar(50) = '93';    -- GGOT (owner of NL74RABO0317955799)
DECLARE @CurrencyID      nvarchar(50) = '4';     -- EUR
DECLARE @BankAccountID   nvarchar(50) = '3428';  -- Rabobank 0317 9557 99 GGOT Euro
DECLARE @OffsetAccountID nvarchar(50) = '712';   -- Bank Charges (acctNumber 700001001)
DECLARE @EntityID        nvarchar(50) = NULL;    -- vendor/customer on the offset line; NULL for bank costs
                                                 -- (required when the offset account is AP or AR)

-- Step 1: preview what will be staged
SELECT
    t.BPA_EntryID, t.BPA_Origin, t.BPA_Reference, t.Bookdate, t.Amount, t.Currency,
    LEFT(COALESCE(t.Description, t.Kenmerk, t.Betalingskenmerk, ''), 250)   AS memo,
    'BANK-' + t.BPA_Origin + '-' + t.BPA_Reference                         AS externalId,
    @BankAccountID AS bank_line_account,
    CASE WHEN t.Amount > 0 THEN t.Amount END  AS bank_line_debit,
    CASE WHEN t.Amount < 0 THEN -t.Amount END AS bank_line_credit,
    @OffsetAccountID AS offset_line_account,
    CASE WHEN t.Amount < 0 THEN -t.Amount END AS offset_line_debit,
    CASE WHEN t.Amount > 0 THEN t.Amount END  AS offset_line_credit,
    @EntityID AS offset_line_entity
FROM tb_Bank_Transactions t
WHERE t.BPA_EntryID = @BankTransactionID;

-- Step 2: stage it
IF @OffsetAccountID IS NULL
    THROW 50001, 'Fill in @OffsetAccountID first.', 1;

IF EXISTS (SELECT 1
           FROM tb_Netsuite_JournalEntry je
           JOIN tb_Bank_Transactions t ON je.externalId = 'BANK-' + t.BPA_Origin + '-' + t.BPA_Reference
           WHERE t.BPA_EntryID = @BankTransactionID)
    THROW 50002, 'This bank transaction is already staged as a journal entry.', 1;

DECLARE @HeaderID uniqueidentifier = NEWID();

SET XACT_ABORT ON;
BEGIN TRANSACTION;

INSERT INTO tb_Netsuite_JournalEntry
(
    BPA_EntryID, BPA_Origin, BPA_Direction, BPA_Action, BPA_Status, BPA_Company,
    BPA_Reference, BPA_Orig_Entryid, BPA_Syscreator, id,
    externalId, subsidiaryId, currencyId, exchangeRate, tranDate, memo
)
SELECT
    @HeaderID, t.BPA_Origin, 'TO', 'I', 0, @SubsidiaryID,
    LEFT('BANK-' + t.BPA_Origin + '-' + t.BPA_Reference, 50), t.BPA_EntryID, 'stage_test_journalentry', '',
    'BANK-' + t.BPA_Origin + '-' + t.BPA_Reference, @SubsidiaryID, @CurrencyID, 1.0,
    t.Bookdate, LEFT(COALESCE(t.Description, t.Kenmerk, t.Betalingskenmerk, ''), 250)
FROM tb_Bank_Transactions t
WHERE t.BPA_EntryID = @BankTransactionID;

INSERT INTO tb_Netsuite_JournalEntry_Line
(
    BPA_EntryID, BPA_ParentID, BPA_Origin, BPA_Direction, BPA_Action, BPA_Status, BPA_Company,
    BPA_Reference, BPA_Orig_Entryid, BPA_Syscreator,
    line, accountId, debit, credit, entityId, memo
)
-- Line 0: bank account. Money in = debit, money out = credit
SELECT
    NEWID(), @HeaderID, t.BPA_Origin, 'TO', 'I', 0, @SubsidiaryID,
    LEFT('BANK-' + t.BPA_Origin + '-' + t.BPA_Reference, 50), t.BPA_EntryID, 'stage_test_journalentry',
    0, @BankAccountID,
    CASE WHEN t.Amount > 0 THEN t.Amount END,
    CASE WHEN t.Amount < 0 THEN -t.Amount END,
    NULL, LEFT(COALESCE(t.Description, t.Kenmerk, t.Betalingskenmerk, ''), 250)
FROM tb_Bank_Transactions t
WHERE t.BPA_EntryID = @BankTransactionID
UNION ALL
-- Line 1: offset account, the opposite side
SELECT
    NEWID(), @HeaderID, t.BPA_Origin, 'TO', 'I', 0, @SubsidiaryID,
    LEFT('BANK-' + t.BPA_Origin + '-' + t.BPA_Reference, 50), t.BPA_EntryID, 'stage_test_journalentry',
    1, @OffsetAccountID,
    CASE WHEN t.Amount < 0 THEN -t.Amount END,
    CASE WHEN t.Amount > 0 THEN t.Amount END,
    @EntityID, LEFT(COALESCE(t.Description, t.Kenmerk, t.Betalingskenmerk, ''), 250)
FROM tb_Bank_Transactions t
WHERE t.BPA_EntryID = @BankTransactionID;

COMMIT TRANSACTION;

-- Check: header + 2 lines, debit total = credit total
SELECT * FROM tb_Netsuite_JournalEntry WHERE BPA_EntryID = @HeaderID;
SELECT line, accountId, debit, credit, entityId, memo
FROM tb_Netsuite_JournalEntry_Line WHERE BPA_ParentID = @HeaderID ORDER BY line;
GO
