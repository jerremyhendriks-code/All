USE [BPAStaging]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
/*
    sp_Bank_Netsuite_FinancialEntry_Create

    Turns open bank transactions (tb_Bank_Transactions, BPA_Status = 0) into NetSuite records:

    1. Match every open transaction with fn_Bank_Match (fills the Matched_* columns).
    2. Put each transaction in one category:
       - VENDORPAYMENT   : vendor found + its vendor bill found + money going out
       - CUSTOMERPAYMENT : customer found + invoice(s) found  + money coming in
       - JOURNALENTRY    : everything else (bank costs, no match, vendor/customer without document)
       - SKIP            : a NetSuite ID we need is missing; stays BPA_Status = 0 and is listed at the end
    3. Insert into tb_Netsuite_VendorPayment(+_Apply), tb_Netsuite_CustomerPayment(+_Apply)
       or tb_Netsuite_JournalEntry(+_Line). One NetSuite record per bank transaction.
    4. Set BPA_Status = 1 and BPA_ReturnedID = the new record's BPA_EntryID on the bank transaction.

    NetSuite needs internal IDs, not account numbers. Per bank account (vw_Bank_BankAccounts):
        Company               = subsidiary internal ID   (e.g. 89)
        GLCodeBank            = bank GL account ID       (e.g. 3427)
        DefaultGLCodeCreditor = AP account ID            (e.g. 111)
        DefaultGLCodeDebtor   = AR account ID            (e.g. 119)

    externalId = 'BANK-<own IBAN>-<bank entry reference>', so NetSuite refuses a second copy.

    Columns marked "-- CHECK" are assumed (table definition not seen yet).

    Run: EXEC sp_Bank_Netsuite_FinancialEntry_Create '89'
*/
ALTER PROCEDURE [dbo].[sp_Bank_Netsuite_FinancialEntry_Create](@BPA_Company varchar(50)) AS
SET NOCOUNT ON;
SET XACT_ABORT ON;

-- 1. Match the open transactions
UPDATE Transactions
SET
	Matched_NewCustomer  = m.NewCustomer
,	Matched_typematch    = m.typematch
,	Matched_GLCode       = m.GLCode
,	Matched_Creditor     = m.vendor_id
,	Matched_Debtor       = m.customer_id
,	Matched_Costcenter   = m.Costcenter
,	Matched_CostUnit     = m.CostUnit
,	Matched_Reference    = m.Reference
,	Matched_VatCode      = m.VatCode
,	Matched_ReferenceXML = m.ReferenceXML
FROM tb_Bank_Transactions Transactions
CROSS APPLY dbo.fn_Bank_Match('BANK', Transactions.BPA_EntryID, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) m
WHERE Transactions.BPA_Status = 0
	AND Transactions.BPA_Company = @BPA_Company;

-- 2. Work list: one row per open transaction, with all NetSuite IDs looked up
IF OBJECT_ID('tempdb..#t') IS NOT NULL DROP TABLE #t;

SELECT
	t.BPA_EntryID
,	NEWID()                                                         AS NewEntryID
,	t.BPA_Origin
,	t.Bookdate
,	t.Amount
,	t.Currency
,	t.Matched_Creditor
,	t.Matched_Debtor
,	LTRIM(RTRIM(t.Matched_GLCode))                                  AS OffsetAccountID
,	LTRIM(RTRIM(t.Matched_Reference))                               AS Matched_Reference
,	CAST(t.Matched_ReferenceXML AS xml)                             AS Matched_ReferenceXML
,	LEFT(COALESCE(t.Description, t.Kenmerk, t.Betalingskenmerk, ''), 250) AS Memo
,	'BANK-' + t.BPA_Origin + '-' + t.BPA_Reference                  AS ExternalID
,	bank.Company                                                    AS SubsidiaryID
,	bank.GLCodeBank                                                 AS BankAccountID
,	bank.DefaultGLCodeCreditor                                      AS APAccountID
,	bank.DefaultGLCodeDebtor                                        AS ARAccountID
,	cur.id                                                          AS CurrencyID
,	vb.vendor_bill_id                                               AS VendorBillID
,	inv.invoice_id                                                  AS InvoiceID
,	CAST(NULL AS varchar(20))                                       AS Category
,	CAST(NULL AS varchar(100))                                      AS SkipReason
INTO #t
FROM tb_Bank_Transactions t
LEFT JOIN vw_Bank_BankAccounts bank
	ON bank.Bankaccount = t.BPA_Origin COLLATE database_default
LEFT JOIN tb_Netsuite_Currency cur                                  -- CHECK: id + ISO code column
	ON cur.symbol = t.Currency
OUTER APPLY (
	SELECT TOP 1 v.vendor_bill_id
	FROM tb_Netsuite_vendorBill v
	WHERE v.vendor_id = t.Matched_Creditor
		AND LTRIM(RTRIM(v.vendor_bill_number)) = LTRIM(RTRIM(t.Matched_Reference))
) vb
OUTER APPLY (
	SELECT TOP 1 i.invoice_id                                       -- CHECK: invoice internal ID column
	FROM tb_Netsuite_Invoice i
	WHERE i.customer_id = t.Matched_Debtor
		AND LTRIM(RTRIM(i.invoice_number)) = LTRIM(RTRIM(t.Matched_Reference))
) inv
WHERE t.BPA_Status = 0
	AND t.BPA_Company = @BPA_Company;

-- 3. Category
UPDATE #t SET Category =
	CASE
		WHEN Matched_Creditor IS NOT NULL AND VendorBillID IS NOT NULL AND Amount < 0
			THEN 'VENDORPAYMENT'
		WHEN Matched_Debtor IS NOT NULL AND Amount > 0
			AND (InvoiceID IS NOT NULL OR Matched_ReferenceXML IS NOT NULL)
			THEN 'CUSTOMERPAYMENT'
		ELSE 'JOURNALENTRY'
	END;

-- Missing NetSuite IDs: don't send, leave the transaction open
UPDATE x SET Category = 'SKIP', SkipReason = r.Reason
FROM #t x
CROSS APPLY (SELECT CASE
	WHEN x.Amount = 0                                              THEN 'Amount is 0'
	WHEN x.SubsidiaryID IS NULL                                    THEN 'No subsidiary (Company) for bank account'
	WHEN x.BankAccountID IS NULL                                   THEN 'No GLCodeBank for bank account'
	WHEN x.CurrencyID IS NULL                                      THEN 'Unknown currency ' + ISNULL(x.Currency, '')
	WHEN x.Category = 'VENDORPAYMENT'   AND x.APAccountID IS NULL  THEN 'No AP account (DefaultGLCodeCreditor)'
	WHEN x.Category = 'CUSTOMERPAYMENT' AND x.ARAccountID IS NULL  THEN 'No AR account (DefaultGLCodeDebtor)'
	WHEN x.Category = 'JOURNALENTRY'    AND x.OffsetAccountID IS NULL THEN 'No GL account for the offset line'
END AS Reason) r
WHERE r.Reason IS NOT NULL;

BEGIN TRANSACTION;

-- 4a. Vendor payments: one payment, one apply line on the matched bill
INSERT INTO tb_Netsuite_VendorPayment
(
	BPA_EntryID, BPA_Origin, BPA_Direction, BPA_Action, BPA_Status, BPA_Company,
	BPA_Reference, BPA_Orig_Entryid,
	externalId, entityId, subsidiaryId, accountId, apAcctId, currencyId, exchangeRate,
	tranDate, memo, toBeEmailed, toBePrinted
)
SELECT
	NewEntryID, BPA_Origin, 'TO', 'I', 0, @BPA_Company,
	ExternalID, BPA_EntryID,
	ExternalID, Matched_Creditor, SubsidiaryID, BankAccountID, APAccountID, CurrencyID,
	CASE WHEN Currency = 'EUR' THEN 1.0 END,
	Bookdate, Memo, 'False', 'False'
FROM #t
WHERE Category = 'VENDORPAYMENT';

INSERT INTO tb_Netsuite_VendorPayment_Apply
(
	BPA_EntryID, BPA_ParentID, BPA_Origin, BPA_Direction, BPA_Action, BPA_Status, BPA_Company,
	BPA_Reference, BPA_Orig_Entryid,
	line, doc_id, amount, apply
)
SELECT
	NEWID(), NewEntryID, BPA_Origin, 'TO', 'I', 0, @BPA_Company,
	ExternalID, BPA_EntryID,
	0, VendorBillID, ABS(Amount), 'True'
FROM #t
WHERE Category = 'VENDORPAYMENT';

-- 4b. Customer payments: one payment, one apply line per invoice
INSERT INTO tb_Netsuite_CustomerPayment                            -- CHECK: column names
(
	BPA_EntryID, BPA_Origin, BPA_Direction, BPA_Action, BPA_Status, BPA_Company,
	BPA_Reference, BPA_Orig_Entryid,
	externalId, customerId, subsidiaryId, accountId, arAcctId, currencyId, exchangeRate,
	payment, tranDate, memo
)
SELECT
	NewEntryID, BPA_Origin, 'TO', 'I', 0, @BPA_Company,
	ExternalID, BPA_EntryID,
	ExternalID, Matched_Debtor, SubsidiaryID, BankAccountID, ARAccountID, CurrencyID,
	CASE WHEN Currency = 'EUR' THEN 1.0 END,
	Amount, Bookdate, Memo
FROM #t
WHERE Category = 'CUSTOMERPAYMENT';

INSERT INTO tb_Netsuite_CustomerPayment_Apply                      -- CHECK: column names
(
	BPA_EntryID, BPA_ParentID, BPA_Origin, BPA_Direction, BPA_Action, BPA_Status, BPA_Company,
	BPA_Reference, BPA_Orig_Entryid,
	line, doc_id, amount, apply
)
-- One invoice (SalesInvoice / SalesinvoiceAmount): the whole amount
SELECT
	NEWID(), x.NewEntryID, x.BPA_Origin, 'TO', 'I', 0, @BPA_Company,
	x.ExternalID, x.BPA_EntryID,
	0, x.InvoiceID, x.Amount, 'True'
FROM #t x
WHERE x.Category = 'CUSTOMERPAYMENT' AND x.InvoiceID IS NOT NULL
UNION ALL
-- A list of invoices (SalesinvoiceList...): each invoice for its open amount
SELECT
	NEWID(), x.NewEntryID, x.BPA_Origin, 'TO', 'I', 0, @BPA_Company,
	x.ExternalID, x.BPA_EntryID,
	ROW_NUMBER() OVER (PARTITION BY x.BPA_EntryID ORDER BY i.invoice_id) - 1,
	i.invoice_id, i.amount_open, 'True'
FROM #t x
CROSS APPLY x.Matched_ReferenceXML.nodes('/Invoices/invoice_number') n(c)
CROSS APPLY (
	SELECT TOP 1 inv.invoice_id, inv.amount_open                   -- CHECK: invoice internal ID column
	FROM tb_Netsuite_Invoice inv
	WHERE inv.customer_id = x.Matched_Debtor
		AND LTRIM(RTRIM(inv.invoice_number)) = n.c.value('.', 'nvarchar(100)')
) i
WHERE x.Category = 'CUSTOMERPAYMENT' AND x.InvoiceID IS NULL;

-- 4c. Journal entries: bank line + offset line
INSERT INTO tb_Netsuite_JournalEntry                               -- CHECK: column names
(
	BPA_EntryID, BPA_Origin, BPA_Direction, BPA_Action, BPA_Status, BPA_Company,
	BPA_Reference, BPA_Orig_Entryid,
	externalId, subsidiaryId, currencyId, exchangeRate, tranDate, memo
)
SELECT
	NewEntryID, BPA_Origin, 'TO', 'I', 0, @BPA_Company,
	ExternalID, BPA_EntryID,
	ExternalID, SubsidiaryID, CurrencyID,
	CASE WHEN Currency = 'EUR' THEN 1.0 END,
	Bookdate, Memo
FROM #t
WHERE Category = 'JOURNALENTRY';

INSERT INTO tb_Netsuite_JournalEntry_Line                          -- CHECK: table + column names
(
	BPA_EntryID, BPA_ParentID, BPA_Origin, BPA_Direction, BPA_Action, BPA_Status, BPA_Company,
	BPA_Reference, BPA_Orig_Entryid,
	line, accountId, debit, credit, entityId, memo
)
-- Bank line: money in = debit, money out = credit
SELECT
	NEWID(), NewEntryID, BPA_Origin, 'TO', 'I', 0, @BPA_Company,
	ExternalID, BPA_EntryID,
	0, BankAccountID,
	CASE WHEN Amount > 0 THEN Amount END,
	CASE WHEN Amount < 0 THEN -Amount END,
	NULL, Memo
FROM #t
WHERE Category = 'JOURNALENTRY'
UNION ALL
-- Offset line: the opposite side, on the matched GL account (with the vendor/customer when known)
SELECT
	NEWID(), NewEntryID, BPA_Origin, 'TO', 'I', 0, @BPA_Company,
	ExternalID, BPA_EntryID,
	1, OffsetAccountID,
	CASE WHEN Amount < 0 THEN -Amount END,
	CASE WHEN Amount > 0 THEN Amount END,
	ISNULL(Matched_Creditor, Matched_Debtor), Memo
FROM #t
WHERE Category = 'JOURNALENTRY';

-- 5. Mark the bank transactions as processed, with a link to the NetSuite record
UPDATE t
SET BPA_Status = 1,
	BPA_ReturnedID = x.NewEntryID
FROM tb_Bank_Transactions t
JOIN #t x ON x.BPA_EntryID = t.BPA_EntryID
WHERE x.Category <> 'SKIP';

COMMIT TRANSACTION;

-- 6. Report
SELECT Category, COUNT(*) AS transactions
FROM #t
GROUP BY Category;

SELECT BPA_EntryID, Bookdate, Amount, Memo, Matched_Creditor, Matched_Debtor, SkipReason
FROM #t
WHERE Category = 'SKIP';
GO
