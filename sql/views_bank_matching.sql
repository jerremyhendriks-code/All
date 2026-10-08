/*
    Views used by usp_Bank_Match_Rabobank. Query them to see what the next run will do:

        SELECT * FROM dbo.vw_Bank_OpenTransaction;   -- bank transactions not handled yet
        SELECT * FROM dbo.vw_Netsuite_OpenItem;      -- open invoices / vendor bills not paid by a match yet
        SELECT * FROM dbo.vw_Bank_MatchProposal;     -- matches: one row per bank transaction + document

    "Handled" / "paid by a match" = present in tb_Bank_TransactionMatch.
*/
USE [BPAStaging];
GO

/*
    Rabobank transactions not handled yet, with the NetSuite settings of our bank account.
    - Only accounts in tb_Bank_Bankaccounts with subsidiary, bank GL account and currency filled.
      Our account is the debtor or creditor IBAN that is in tb_Bank_Bankaccounts
      (creditor side for money in, debtor side for money out).
    - A transaction is identified by our IBAN + entryReference; when it was fetched more than
      once, the most recently loaded row is used.
*/
CREATE OR ALTER VIEW dbo.vw_Bank_OpenTransaction
AS
SELECT t.bank_entry_id,
       t.bank_iban,
       t.entry_reference,
       CAST(CONCAT(N'RABO-', t.bank_iban, N'-', t.entry_reference) AS nvarchar(255)) AS external_id,
       t.booking_date,
       t.amount,
       t.search_text,
       LEFT(t.memo, 4000) AS memo,
       t.subsidiary_id,
       t.account_id,
       t.currency_id,
       t.suspense_account_id,
       co.BPA_Company AS company
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
WHERE t.rn = 1
  AND NOT EXISTS (SELECT 1 FROM dbo.tb_Bank_TransactionMatch m
                  WHERE m.bank_iban = t.bank_iban AND m.entry_reference = t.entry_reference);
GO

/*
    Open invoices and vendor bills (latest loaded row per id, amount_open > 0)
    that weren't paid by an earlier match.
*/
CREATE OR ALTER VIEW dbo.vw_Netsuite_OpenItem
AS
SELECT o.match_type, o.doc_id, o.doc_number, o.entity_id, o.subsidiary_id, o.currency_id, o.amount_open
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
WHERE o.rn = 1
  AND o.amount_open > 0
  AND NOT EXISTS (SELECT 1 FROM dbo.tb_Bank_TransactionMatch m
                  WHERE m.match_type = o.match_type AND m.document_id = o.doc_id);
GO

/*
    Matches between open bank transactions and open documents: one row per transaction + document.

    A document "is referenced" when its number (at least 4 characters) appears as a separate word
    in the structured / unstructured remittance information or the endToEndId of a transaction
    (money in -> invoices, money out -> vendor bills, same subsidiary and currency).
    1. REFERENCE_TOTAL   All referenced documents belong to one customer / vendor and their open
                         amounts add up to the transaction amount. Pays all of them.
    2. REFERENCE_AMOUNT  Otherwise: exactly one referenced document has an open amount equal to
                         the transaction amount. Pays that one.
    When two transactions claim the same document, neither is matched.
*/
CREATE OR ALTER VIEW dbo.vw_Bank_MatchProposal
AS
WITH candidate AS (
    SELECT t.bank_entry_id, t.bank_iban, t.entry_reference, t.external_id, t.booking_date,
           t.amount AS transaction_amount, t.memo, t.subsidiary_id, t.account_id, t.currency_id, t.company,
           o.match_type, o.doc_id, o.doc_number, o.entity_id, o.amount_open
    FROM   dbo.vw_Bank_OpenTransaction t
    JOIN   dbo.vw_Netsuite_OpenItem o
           ON  o.match_type    = CASE WHEN t.amount > 0 THEN 'CUSTOMERPAYMENT' ELSE 'VENDORPAYMENT' END
           AND o.subsidiary_id = t.subsidiary_id
           AND o.currency_id   = t.currency_id
    WHERE  LEN(o.doc_number) >= 4
      AND  t.search_text LIKE N'%[^0-9A-Z]'
                              + REPLACE(REPLACE(REPLACE(UPPER(o.doc_number), N'[', N'[[]'), N'_', N'[_]'), N'%', N'[%]')
                              + N'[^0-9A-Z]%'
),
transaction_totals AS (
    SELECT bank_iban, entry_reference,
           COUNT(DISTINCT entity_id) AS entities,
           SUM(amount_open) AS total_open,
           SUM(CASE WHEN amount_open = ABS(transaction_amount) THEN 1 ELSE 0 END) AS exact_amount_docs
    FROM   candidate
    GROUP BY bank_iban, entry_reference
),
matched AS (
    SELECT c.*, r.match_rule
    FROM   candidate c
    JOIN   transaction_totals tt ON tt.bank_iban = c.bank_iban AND tt.entry_reference = c.entry_reference
    CROSS APPLY (SELECT CASE WHEN tt.entities = 1 AND tt.total_open = ABS(c.transaction_amount)
                             THEN 'REFERENCE_TOTAL'
                             WHEN tt.exact_amount_docs = 1 AND c.amount_open = ABS(c.transaction_amount)
                             THEN 'REFERENCE_AMOUNT' END AS match_rule) r
    WHERE  r.match_rule IS NOT NULL
),
claimed_twice AS (
    SELECT match_type, doc_id
    FROM   matched
    GROUP BY match_type, doc_id
    HAVING COUNT(*) > 1
)
SELECT m.*
FROM   matched m
WHERE  NOT EXISTS (SELECT 1
                   FROM   matched same_txn
                   JOIN   claimed_twice ct ON ct.match_type = same_txn.match_type AND ct.doc_id = same_txn.doc_id
                   WHERE  same_txn.bank_iban = m.bank_iban AND same_txn.entry_reference = m.entry_reference);
GO
