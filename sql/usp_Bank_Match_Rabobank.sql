/*
    Match Rabobank transactions to open NetSuite invoices / vendor bills and stage the
    NetSuite records to create (BPA_Direction = 'TO', BPA_Origin = 'Matched Transaction'):
    - incoming money matched to invoices       -> tb_Netsuite_customerPayment (+ _apply)
    - outgoing money matched to vendor bills   -> tb_Netsuite_vendorPayment   (+ _apply)
    - still unmatched after @JournalAfterDays  -> tb_Netsuite_journalEntry    (+ _line),
                                                  bank account vs. suspense account
    Lines point to their header through BPA_ParentID = header BPA_EntryID.

    !! Child table and column names below are placeholders until checked against the DDL:
       header   external_id, customer_id / vendor_id, subsidiary_id, account_id, currency_id,
                tran_date, payment_amount, memo         (journalEntry: no customer/vendor/account/amount)
       _apply   invoice_id + invoice_number / vendor_bill_id + vendor_bill_number, amount
       _line    line_no, account_id, debit, credit, memo

    Every handled transaction gets rows in tb_Bank_TransactionMatch and is skipped on later runs.
    Requires create_tb_Bank_TransactionMatch.sql and alter_tb_Bank_Bankaccounts_add_netsuite_columns.sql.

    Bank transactions
    - Only accounts in tb_Bank_Bankaccounts with subsidiary, bank GL account and currency filled.
      Our account is the debtor or creditor IBAN that is in tb_Bank_Bankaccounts.
    - A transaction is identified by our IBAN + entryReference; when it was fetched more than
      once, the most recently loaded row is used.

    Open items (latest loaded row per invoice_id / vendor_bill_id, amount_open > 0)
    - Same subsidiary and currency as the bank account.
    - Not already paid by an earlier match.

    Matching (a document "is referenced" when its number, at least 4 characters, appears as a
    separate word in the structured or unstructured remittance information or the endToEndId)
    1. REFERENCE_TOTAL   All referenced documents belong to one customer / vendor and their open
                         amounts add up to the transaction amount. Pays all of them.
    2. REFERENCE_AMOUNT  Otherwise: exactly one referenced document has an open amount equal to
                         the transaction amount. Pays that one.
    Only full open amounts are paid. When two transactions claim the same document, neither is
    matched in this run.
*/
USE [BPAStaging];
GO

-- Required for writing to tables with filtered indexes
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Bank_Match_Rabobank
    @JournalAfterDays int = 5
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @direction nvarchar(50) = N'TO',
            @origin    nvarchar(50) = N'Matched Transaction';
    DECLARE @journal_until date = DATEADD(day, -@JournalAfterDays, CAST(GETDATE() AS date));

    -- 1. Bank transactions not handled yet
    SELECT t.bank_entry_id, t.bank_iban, t.entry_reference, t.booking_date, t.amount,
           t.search_text, LEFT(t.memo, 999) AS memo,
           t.subsidiary_id, t.account_id, t.currency_id, t.suspense_account_id,
           co.BPA_Company AS company
    INTO   #txn
    FROM  (SELECT r.BPA_EntryID AS bank_entry_id,
                  b.iban AS bank_iban,
                  CAST(COALESCE(r.entryReference, CONVERT(varchar(36), r.BPA_EntryID)) AS varchar(100)) AS entry_reference,
                  CAST(COALESCE(r.bookingDate, r.valueDate) AS date) AS booking_date,
                  CAST(ROUND(r.transactionAmount_value, 2) AS decimal(18, 2)) AS amount,
                  UPPER(CONCAT(' ', r.remittanceInformationStructured, ' ', r.remittanceInformationUnstructured,
                               ' ', r.endToEndId, ' ')) AS search_text,
                  STUFF(CONCAT(N' - ' + CASE WHEN r.transactionAmount_value > 0 THEN r.debtorName ELSE r.creditorName END,
                               N' - ' + r.remittanceInformationUnstructured,
                               N' - ' + r.remittanceInformationStructured), 1, 3, N'') AS memo,
                  b.netsuite_subsidiary_id AS subsidiary_id,
                  b.netsuite_account_id AS account_id,
                  b.netsuite_currency_id AS currency_id,
                  b.netsuite_suspense_account_id AS suspense_account_id,
                  ROW_NUMBER() OVER (PARTITION BY b.iban, COALESCE(r.entryReference, CONVERT(varchar(36), r.BPA_EntryID))
                                     ORDER BY r.BPA_Syscreated DESC, r.BPA_EntryID DESC) AS rn
           FROM   dbo.tb_Rabobank_Transaction r
           -- Our account: creditor side for money in, debtor side for money out (the other side as fallback)
           CROSS APPLY (SELECT TOP (1) UPPER(REPLACE(ba.IBAN, ' ', '')) AS iban,
                               ba.netsuite_subsidiary_id, ba.netsuite_account_id,
                               ba.netsuite_currency_id, ba.netsuite_suspense_account_id
                        FROM   dbo.tb_Bank_Bankaccounts ba
                        WHERE  UPPER(REPLACE(ba.IBAN, ' ', '')) IN (UPPER(REPLACE(r.creditorAccount_iban, ' ', '')),
                                                                    UPPER(REPLACE(r.debtorAccount_iban, ' ', '')))
                        ORDER BY CASE WHEN UPPER(REPLACE(ba.IBAN, ' ', '')) =
                                           UPPER(REPLACE(CASE WHEN r.transactionAmount_value > 0
                                                              THEN r.creditorAccount_iban
                                                              ELSE r.debtorAccount_iban END, ' ', ''))
                                      THEN 0 ELSE 1 END) b
           WHERE  r.transactionAmount_value <> 0
             AND  b.netsuite_subsidiary_id IS NOT NULL
             AND  b.netsuite_account_id IS NOT NULL
             AND  b.netsuite_currency_id IS NOT NULL) t
    LEFT JOIN dbo.tb_Companies co ON co.subsidiary_ID = t.subsidiary_id
    WHERE  t.rn = 1
      AND  NOT EXISTS (SELECT 1 FROM dbo.tb_Bank_TransactionMatch m
                       WHERE m.bank_iban = t.bank_iban AND m.entry_reference = t.entry_reference);

    -- 2. Open invoices and vendor bills not paid by an earlier match
    SELECT o.match_type, o.doc_id, o.doc_number, o.entity_id, o.subsidiary_id, o.currency_id, o.amount_open
    INTO   #open
    FROM  (SELECT 'CUSTOMERPAYMENT' AS match_type,
                  CAST(i.invoice_id AS nvarchar(100)) AS doc_id,
                  CAST(i.invoice_number AS nvarchar(100)) AS doc_number,
                  CAST(i.customer_id AS nvarchar(100)) AS entity_id,
                  CAST(i.subsidiary_id AS nvarchar(100)) AS subsidiary_id,
                  CAST(i.currency_id AS nvarchar(100)) AS currency_id,
                  TRY_CONVERT(decimal(18, 2), i.amount_open) AS amount_open,
                  ROW_NUMBER() OVER (PARTITION BY CAST(i.invoice_id AS nvarchar(100))
                                     ORDER BY i.BPA_Syscreated DESC, i.BPA_EntryID DESC) AS rn
           FROM   dbo.tb_Netsuite_Invoice i
           WHERE  i.invoice_id IS NOT NULL
           UNION ALL
           SELECT 'VENDORPAYMENT',
                  CAST(v.vendor_bill_id AS nvarchar(100)),
                  CAST(v.vendor_bill_number AS nvarchar(100)),
                  CAST(v.vendor_id AS nvarchar(100)),
                  CAST(v.subsidiary_id AS nvarchar(100)),
                  CAST(v.currency_id AS nvarchar(100)),
                  TRY_CONVERT(decimal(18, 2), v.amount_open),
                  ROW_NUMBER() OVER (PARTITION BY CAST(v.vendor_bill_id AS nvarchar(100))
                                     ORDER BY v.BPA_Syscreated DESC, v.BPA_EntryID DESC)
           FROM   dbo.tb_Netsuite_vendorBill v
           WHERE  v.vendor_bill_id IS NOT NULL) o
    WHERE  o.rn = 1
      AND  o.amount_open > 0
      AND  NOT EXISTS (SELECT 1 FROM dbo.tb_Bank_TransactionMatch m
                       WHERE m.match_type = o.match_type AND m.document_id = o.doc_id);

    -- 3. Candidates: documents referenced in the transaction's payment information
    SELECT t.bank_iban, t.entry_reference, t.amount AS txn_amount,
           o.match_type, o.doc_id, o.doc_number, o.entity_id, o.amount_open
    INTO   #cand
    FROM   #txn t
    JOIN   #open o ON o.match_type    = CASE WHEN t.amount > 0 THEN 'CUSTOMERPAYMENT' ELSE 'VENDORPAYMENT' END
                  AND o.subsidiary_id = t.subsidiary_id
                  AND o.currency_id   = t.currency_id
    WHERE  LEN(o.doc_number) >= 4
      AND  t.search_text LIKE N'%[^0-9A-Z]'
                              + REPLACE(REPLACE(REPLACE(UPPER(o.doc_number), N'[', N'[[]'), N'_', N'[_]'), N'%', N'[%]')
                              + N'[^0-9A-Z]%';

    -- 4a. Rule REFERENCE_TOTAL
    SELECT c.*, CAST('REFERENCE_TOTAL' AS varchar(50)) AS match_rule
    INTO   #match
    FROM   #cand c
    WHERE  EXISTS (SELECT 1
                   FROM   #cand g
                   WHERE  g.bank_iban = c.bank_iban AND g.entry_reference = c.entry_reference
                   GROUP BY g.bank_iban, g.entry_reference, g.txn_amount
                   HAVING COUNT(DISTINCT g.entity_id) = 1 AND SUM(g.amount_open) = ABS(g.txn_amount));

    -- 4b. Rule REFERENCE_AMOUNT
    INSERT INTO #match
    SELECT c.*, 'REFERENCE_AMOUNT'
    FROM   #cand c
    WHERE  c.amount_open = ABS(c.txn_amount)
      AND  NOT EXISTS (SELECT 1 FROM #match m
                       WHERE m.bank_iban = c.bank_iban AND m.entry_reference = c.entry_reference)
      AND  1 = (SELECT COUNT(*) FROM #cand c2
                WHERE c2.bank_iban = c.bank_iban AND c2.entry_reference = c.entry_reference
                  AND c2.amount_open = ABS(c2.txn_amount));

    -- 4c. Drop transactions that claim a document another transaction also claims
    DELETE m
    FROM   #match m
    WHERE  EXISTS (SELECT 1
                   FROM   #match mine
                   JOIN   #match other ON other.match_type = mine.match_type
                                      AND other.doc_id     = mine.doc_id
                                      AND (other.bank_iban <> mine.bank_iban OR other.entry_reference <> mine.entry_reference)
                   WHERE  mine.bank_iban = m.bank_iban AND mine.entry_reference = m.entry_reference);

    -- 5. One payment per matched transaction, one journal entry per old unmatched transaction
    SELECT t.*, p.match_type, p.entity_id, NEWID() AS header_id
    INTO   #pay
    FROM   #txn t
    JOIN  (SELECT DISTINCT bank_iban, entry_reference, match_type, entity_id FROM #match) p
           ON p.bank_iban = t.bank_iban AND p.entry_reference = t.entry_reference;

    SELECT t.*, NEWID() AS header_id
    INTO   #je
    FROM   #txn t
    WHERE  t.booking_date <= @journal_until
      AND  t.suspense_account_id IS NOT NULL
      AND  NOT EXISTS (SELECT 1 FROM #pay p WHERE p.bank_iban = t.bank_iban AND p.entry_reference = t.entry_reference);

    BEGIN TRANSACTION;

    -- Match log
    INSERT INTO dbo.tb_Bank_TransactionMatch
           (bank_iban, entry_reference, bank_entry_id, booking_date, transaction_amount,
            match_type, match_rule, document_id, document_number, entity_id, applied_amount, output_entry_id)
    SELECT p.bank_iban, p.entry_reference, p.bank_entry_id, p.booking_date, p.amount,
           m.match_type, m.match_rule, m.doc_id, m.doc_number, m.entity_id, m.amount_open, p.header_id
    FROM   #match m
    JOIN   #pay p ON p.bank_iban = m.bank_iban AND p.entry_reference = m.entry_reference
    UNION ALL
    SELECT j.bank_iban, j.entry_reference, j.bank_entry_id, j.booking_date, j.amount,
           'JOURNALENTRY', 'UNMATCHED', NULL, NULL, NULL, j.amount, j.header_id
    FROM   #je j;

    -- Customer payments
    INSERT INTO dbo.tb_Netsuite_customerPayment
           (BPA_EntryID, BPA_Direction, BPA_Origin, BPA_Company, external_id, customer_id, subsidiary_id,
            account_id, currency_id, tran_date, payment_amount, memo)
    SELECT header_id, @direction, @origin, company, CONCAT(N'RABO-', bank_iban, N'-', entry_reference), entity_id, subsidiary_id,
           account_id, currency_id, booking_date, amount, memo
    FROM   #pay
    WHERE  match_type = 'CUSTOMERPAYMENT';

    INSERT INTO dbo.tb_Netsuite_customerPayment_apply
           (BPA_ParentID, BPA_Direction, BPA_Origin, BPA_Company, invoice_id, invoice_number, amount)
    SELECT p.header_id, @direction, @origin, p.company, m.doc_id, m.doc_number, m.amount_open
    FROM   #match m
    JOIN   #pay p ON p.bank_iban = m.bank_iban AND p.entry_reference = m.entry_reference
    WHERE  m.match_type = 'CUSTOMERPAYMENT';

    -- Vendor payments (bank amount is negative, payment amount positive)
    INSERT INTO dbo.tb_Netsuite_vendorPayment
           (BPA_EntryID, BPA_Direction, BPA_Origin, BPA_Company, external_id, vendor_id, subsidiary_id,
            account_id, currency_id, tran_date, payment_amount, memo)
    SELECT header_id, @direction, @origin, company, CONCAT(N'RABO-', bank_iban, N'-', entry_reference), entity_id, subsidiary_id,
           account_id, currency_id, booking_date, -amount, memo
    FROM   #pay
    WHERE  match_type = 'VENDORPAYMENT';

    INSERT INTO dbo.tb_Netsuite_vendorPayment_apply
           (BPA_ParentID, BPA_Direction, BPA_Origin, BPA_Company, vendor_bill_id, vendor_bill_number, amount)
    SELECT p.header_id, @direction, @origin, p.company, m.doc_id, m.doc_number, m.amount_open
    FROM   #match m
    JOIN   #pay p ON p.bank_iban = m.bank_iban AND p.entry_reference = m.entry_reference
    WHERE  m.match_type = 'VENDORPAYMENT';

    -- Journal entries: money in = debit bank / credit suspense, money out = the reverse
    INSERT INTO dbo.tb_Netsuite_journalEntry
           (BPA_EntryID, BPA_Direction, BPA_Origin, BPA_Company, external_id, subsidiary_id, currency_id, tran_date, memo)
    SELECT header_id, @direction, @origin, company, CONCAT(N'RABO-', bank_iban, N'-', entry_reference), subsidiary_id,
           currency_id, booking_date, memo
    FROM   #je;

    INSERT INTO dbo.tb_Netsuite_journalEntry_line
           (BPA_ParentID, BPA_Direction, BPA_Origin, BPA_Company, line_no, account_id, debit, credit, memo)
    SELECT header_id, @direction, @origin, company, 1, account_id,
           CASE WHEN amount > 0 THEN amount END, CASE WHEN amount < 0 THEN -amount END, memo
    FROM   #je
    UNION ALL
    SELECT header_id, @direction, @origin, company, 2, suspense_account_id,
           CASE WHEN amount < 0 THEN -amount END, CASE WHEN amount > 0 THEN amount END, memo
    FROM   #je;

    COMMIT TRANSACTION;

    SELECT (SELECT COUNT(*) FROM #txn)                                             AS open_transactions,
           (SELECT COUNT(*) FROM #pay WHERE match_type = 'CUSTOMERPAYMENT')         AS customer_payments,
           (SELECT COUNT(*) FROM #pay WHERE match_type = 'VENDORPAYMENT')           AS vendor_payments,
           (SELECT COUNT(*) FROM #je)                                               AS journal_entries,
           (SELECT COUNT(*) FROM #txn) - (SELECT COUNT(*) FROM #pay) - (SELECT COUNT(*) FROM #je) AS still_waiting;
END
GO
