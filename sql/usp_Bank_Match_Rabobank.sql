/*
    Turn matched Rabobank transactions into NetSuite records to create
    (BPA_Direction = 'TO', BPA_Origin = 'Matched Transaction'):
    - incoming money matched to invoices       -> tb_Netsuite_CustomerPayment (+ _Apply)
    - outgoing money matched to vendor bills   -> tb_Netsuite_VendorPayment   (+ _Apply)
    - still unmatched after @JournalAfterDays  -> tb_Netsuite_JournalEntry    (+ _Line),
                                                  bank account vs. @SuspenseAccountNumber
    Afterwards every handled transaction is logged in tb_Bank_TransactionMatch, so it
    (and the documents it paid) drops out of the views on the next run.

    The matching itself is in the views (views_bank_matching.sql):
        vw_Bank_OpenTransaction, vw_Netsuite_OpenItem, vw_Bank_MatchProposal.
    Lines are linked to their header through externalId ('RABO-<IBAN>-<entryReference>').

    !! Assumed, not yet checked against the DDL:
       tb_Netsuite_CustomerPayment_Apply has the same columns as tb_Netsuite_VendorPayment_Apply.
*/
USE [BPAStaging];
GO

-- Required for writing to tables with filtered indexes
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Bank_Match_Rabobank
    @SuspenseAccountNumber nvarchar(255),   -- NetSuite acctNumber of the suspense account
    @JournalAfterDays      int = 5
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @direction     nvarchar(50) = N'TO',
            @origin        nvarchar(50) = N'Matched Transaction',
            @journal_until date         = DATEADD(day, -@JournalAfterDays, CAST(GETDATE() AS date)),
            @suspense_account_id nvarchar(100);

    SELECT TOP (1) @suspense_account_id = id
    FROM   dbo.tb_Netsuite_Account
    WHERE  acctNumber = @SuspenseAccountNumber
    ORDER BY BPA_Syscreated DESC;

    IF @suspense_account_id IS NULL
        THROW 50001, 'Suspense account not found in tb_Netsuite_Account (acctNumber = @SuspenseAccountNumber).', 1;

    BEGIN TRANSACTION;

    -- 1. Customer payments
    INSERT INTO dbo.tb_Netsuite_CustomerPayment
           (BPA_Direction, BPA_Origin, BPA_Company, id, externalId,
            customerId, subsidiaryId, accountId, currencyId, tranDate, payment, memo)
    SELECT DISTINCT @direction, @origin, company, N'', external_id,
           entity_id, subsidiary_id, account_id, currency_id, booking_date, transaction_amount, memo
    FROM   dbo.vw_Bank_MatchProposal
    WHERE  match_type = 'CUSTOMERPAYMENT';

    INSERT INTO dbo.tb_Netsuite_CustomerPayment_Apply
           (BPA_ParentID, BPA_Direction, BPA_Origin, BPA_Company, doc_id, refNum, apply, amount)
    SELECT h.BPA_EntryID, @direction, @origin, p.company, p.doc_id, p.doc_number, 1, p.amount_open
    FROM   dbo.vw_Bank_MatchProposal p
    JOIN   dbo.tb_Netsuite_CustomerPayment h ON h.externalId = p.external_id AND h.BPA_Origin = @origin
    WHERE  p.match_type = 'CUSTOMERPAYMENT';

    -- 2. Vendor payments (the amount paid comes from the apply lines)
    INSERT INTO dbo.tb_Netsuite_VendorPayment
           (BPA_Direction, BPA_Origin, BPA_Company, id, externalId,
            entityId, subsidiaryId, accountId, currencyId, tranDate, memo)
    SELECT DISTINCT @direction, @origin, company, N'', external_id,
           entity_id, subsidiary_id, account_id, currency_id, CONVERT(nvarchar(10), booking_date, 23), memo
    FROM   dbo.vw_Bank_MatchProposal
    WHERE  match_type = 'VENDORPAYMENT';

    INSERT INTO dbo.tb_Netsuite_VendorPayment_Apply
           (BPA_ParentID, BPA_Direction, BPA_Origin, BPA_Company, doc_id, refNum, apply, amount)
    SELECT h.BPA_EntryID, @direction, @origin, p.company, p.doc_id, p.doc_number, 1, p.amount_open
    FROM   dbo.vw_Bank_MatchProposal p
    JOIN   dbo.tb_Netsuite_VendorPayment h ON h.externalId = p.external_id AND h.BPA_Origin = @origin
    WHERE  p.match_type = 'VENDORPAYMENT';

    -- 3. Journal entries for transactions still unmatched after @JournalAfterDays
    --    money in = debit bank / credit suspense, money out = the reverse
    INSERT INTO dbo.tb_Netsuite_JournalEntry
           (BPA_Direction, BPA_Origin, BPA_Company, id, externalId, subsidiaryId, currencyId, tranDate, memo)
    SELECT @direction, @origin, t.company, N'', t.external_id, t.subsidiary_id, t.currency_id, t.booking_date, t.memo
    FROM   dbo.vw_Bank_OpenTransaction t
    WHERE  t.booking_date <= @journal_until
      AND  t.mapping_issue IS NULL
      AND  NOT EXISTS (SELECT 1 FROM dbo.vw_Bank_MatchProposal p WHERE p.external_id = t.external_id);

    INSERT INTO dbo.tb_Netsuite_JournalEntry_Line
           (BPA_ParentID, BPA_Direction, BPA_Origin, BPA_Company, line, accountId, debit, credit, memo)
    SELECT h.BPA_EntryID, @direction, @origin, t.company, l.line, l.account_id, l.debit, l.credit, t.memo
    FROM   dbo.vw_Bank_OpenTransaction t
    JOIN   dbo.tb_Netsuite_JournalEntry h ON h.externalId = t.external_id AND h.BPA_Origin = @origin
    CROSS APPLY (VALUES (1, t.account_id,
                         CASE WHEN t.amount > 0 THEN t.amount END, CASE WHEN t.amount < 0 THEN -t.amount END),
                        (2, @suspense_account_id,
                         CASE WHEN t.amount < 0 THEN -t.amount END, CASE WHEN t.amount > 0 THEN t.amount END)
                ) l (line, account_id, debit, credit);

    -- 4. Log what was handled. This has to come last: until now the views must still show
    --    these transactions.
    INSERT INTO dbo.tb_Bank_TransactionMatch
           (bank_iban, entry_reference, bank_entry_id, booking_date, transaction_amount,
            match_type, match_rule, document_id, document_number, entity_id, applied_amount, output_entry_id)
    SELECT p.bank_iban, p.entry_reference, p.bank_entry_id, p.booking_date, p.transaction_amount,
           p.match_type, p.match_rule, p.doc_id, p.doc_number, p.entity_id, p.amount_open, h.BPA_EntryID
    FROM   dbo.vw_Bank_MatchProposal p
    JOIN  (SELECT BPA_EntryID, externalId FROM dbo.tb_Netsuite_CustomerPayment WHERE BPA_Origin = @origin
           UNION ALL
           SELECT BPA_EntryID, externalId FROM dbo.tb_Netsuite_VendorPayment WHERE BPA_Origin = @origin) h
           ON h.externalId = p.external_id
    UNION ALL
    SELECT t.bank_iban, t.entry_reference, t.bank_entry_id, t.booking_date, t.amount,
           'JOURNALENTRY', 'UNMATCHED', NULL, NULL, NULL, t.amount, h.BPA_EntryID
    FROM   dbo.vw_Bank_OpenTransaction t
    JOIN   dbo.tb_Netsuite_JournalEntry h ON h.externalId = t.external_id AND h.BPA_Origin = @origin;

    COMMIT TRANSACTION;
END
GO
