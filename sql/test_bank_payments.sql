/*
    Test: one vendor payment and one customer payment through the whole bank chain.

        tb_Rabobank_Transaction --sp_Bank_Transaction_Rabobank_Copy--> tb_Bank_Transactions
            --sp_Bank_Netsuite_FinancialEntry_Create_V2 (fn_Bank_Match_V2)--> tb_Netsuite_VendorPayment / CustomerPayment
            --BPA TO tasks--> NetSuite

    1. Refreshes the snapshot of @Company and picks a REAL open EUR bill and invoice of @Company from it
       (or the internal IDs filled in below), with at least @TestAmount open.
    2. Inserts a test copy of each (BPA_Origin 'TEST'): same internal id, vendor / customer, subsidiary and
       currency, but a made-up number (BPT-VB-<tag> / BPT-IN-<tag>) and amount_open = @TestAmount.
       The snapshot takes the newest row per document, so the engine sees the test number; NetSuite gets
       the real internal id, so the payment is applied to the real document: a partial payment of
       @TestAmount (sandbox only!).
    3. Inserts two Rabobank transactions on our own account, the other party a dummy IBAN, so only the
       number in the description can make the match:
           money out -@TestAmount, description = test bill number     -> PurchaseInvoice  -> VENDORPAYMENT
           money in  +@TestAmount, description = test invoice number  -> SalesInvoice     -> CUSTOMERPAYMENT
    4. Copies them to tb_Bank_Transactions and shows what fn_Bank_Match_V2 makes of them.

    <tag> = MMddHHmmss in letters (0 -> A ... 9 -> J): no digits in the description, every run new numbers.
    Cleanup is at the bottom.
*/
USE [BPAStaging]
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

-- ===== Fill in =====
DECLARE @Company       nvarchar(50)   = N'89';          -- subsidiary of the bank account and both documents
DECLARE @OwnIBAN       varchar(34)    = NULL;           -- our bank account; NULL = the first complete one of @Company
DECLARE @TestAmount    decimal(18, 2) = 10.00;          -- paid on the bill and on the invoice
DECLARE @DummyIBAN     varchar(34)    = 'NL00TEST0000000001';
DECLARE @VB_BillID     nvarchar(100)  = NULL;           -- NULL = pick an open bill of @Company
DECLARE @INV_InvoiceID nvarchar(100)  = NULL;           -- NULL = pick an open invoice of @Company
-- ===================

DECLARE @run       varchar(14)  = FORMAT(GETDATE(), 'yyyyMMddHHmmss');
DECLARE @tag       varchar(10)  = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(RIGHT(@run, 10),
                        '0', 'A'), '1', 'B'), '2', 'C'), '3', 'D'), '4', 'E'), '5', 'F'), '6', 'G'), '7', 'H'), '8', 'I'), '9', 'J');
DECLARE @BillNo    nvarchar(20) = N'BPT-VB-' + @tag;
DECLARE @InvoiceNo nvarchar(20) = N'BPT-IN-' + @tag;
DECLARE @EurID     nvarchar(100);
DECLARE @VB_VendorID nvarchar(100), @VB_VendorName nvarchar(255), @VB_Open decimal(19, 2),
        @INV_CustomerID nvarchar(100), @INV_CustomerName nvarchar(255), @INV_Open decimal(19, 2),
        @msg nvarchar(2048);

-- ---------- Pre-checks ----------
IF @OwnIBAN IS NULL
    SELECT TOP (1) @OwnIBAN = bank.Bankaccount
    FROM vw_Bank_BankAccounts bank
    WHERE bank.Company = @Company
      AND bank.GLCodeBank IS NOT NULL
      AND bank.DefaultGLCodeCreditor IS NOT NULL
      AND bank.DefaultGLCodeDebtor IS NOT NULL
    ORDER BY bank.Bankaccount;

IF @OwnIBAN IS NULL
BEGIN
    SET @msg = N'No bank account of subsidiary ' + @Company + N' with GLCodeBank, AP and AR account in vw_Bank_BankAccounts.';
    THROW 50001, @msg, 1;
END

SELECT TOP (1) @EurID = c.id FROM tb_Netsuite_Currency c WHERE c.symbol = 'EUR' AND ISNULL(c.isInactive, 0) = 0;

IF EXISTS (SELECT 1 FROM dbo.vw_Bank_Relation_IBAN WHERE custrecord_2663_entity_iban = @DummyIBAN)
    THROW 50002, N'@DummyIBAN belongs to a relation; pick another one.', 1;

-- Fresh snapshot: only documents that are open in the latest load
EXEC dbo.sp_Bank_Synchronise_Company_V2 @Subsidiary = @Company, @Report = 0;

-- The real bill and invoice: open, EUR, in @Company, not waiting in an unsent payment, not a test copy
SELECT TOP (1) @VB_BillID = b.vendor_bill_id, @VB_VendorID = b.vendor_id, @VB_VendorName = b.vendor_name, @VB_Open = b.amount_open
FROM dbo.vw_Bank_Open_VendorBill b
WHERE b.subsidiary_id = @Company
  AND b.currency_id = @EurID
  AND b.amount_open >= @TestAmount
  AND b.vendor_id IS NOT NULL
  AND b.vendor_bill_number NOT LIKE 'BPT-%'
  AND (@VB_BillID IS NULL OR b.vendor_bill_id = @VB_BillID)
  AND NOT EXISTS (SELECT 1
                  FROM tb_Netsuite_VendorPayment_Apply a
                  JOIN tb_Netsuite_VendorPayment h ON h.BPA_EntryID = a.BPA_ParentID
                  WHERE a.doc_id = b.vendor_bill_id AND h.BPA_Direction = 'TO' AND h.BPA_Status = 0)
ORDER BY b.amount_open DESC, b.vendor_bill_id;

SELECT TOP (1) @INV_InvoiceID = i.invoice_id, @INV_CustomerID = i.customer_id, @INV_CustomerName = i.customer_name, @INV_Open = i.amount_open
FROM dbo.vw_Bank_Open_Invoice i
WHERE i.subsidiary_id = @Company
  AND i.currency_id = @EurID
  AND i.amount_open >= @TestAmount
  AND i.customer_id IS NOT NULL
  AND i.invoice_number NOT LIKE 'BPT-%'
  AND (@INV_InvoiceID IS NULL OR i.invoice_id = @INV_InvoiceID)
  AND NOT EXISTS (SELECT 1
                  FROM tb_Netsuite_CustomerPayment_Apply a
                  JOIN tb_Netsuite_CustomerPayment h ON h.BPA_EntryID = a.BPA_ParentID
                  WHERE a.docId = i.invoice_id AND h.BPA_Direction = 'TO' AND h.BPA_Status = 0)
ORDER BY i.amount_open DESC, i.invoice_id;

IF @VB_VendorID IS NULL OR @INV_CustomerID IS NULL
BEGIN
    SET @msg = N'Subsidiary ' + @Company + N' has no '
             + CASE WHEN @VB_VendorID IS NULL THEN N'open EUR vendor bill' ELSE N'' END
             + CASE WHEN @VB_VendorID IS NULL AND @INV_CustomerID IS NULL THEN N' and no ' ELSE N'' END
             + CASE WHEN @INV_CustomerID IS NULL THEN N'open EUR invoice' ELSE N'' END
             + N' with at least ' + CAST(@TestAmount AS nvarchar(20)) + N' open in the snapshot. '
             + N'See the counts per subsidiary: SELECT Subsidiary, DocType, COUNT(*) FROM tb_Bank_Synch_OpenItems GROUP BY Subsidiary, DocType.';
    THROW 50003, @msg, 1;
END

BEGIN TRANSACTION;

-- ---------- Test copies of the documents (BPA_Origin 'TEST') ----------
INSERT INTO tb_Netsuite_VendorBill
(
    BPA_Origin, BPA_Direction, BPA_Company, BPA_Syscreator, BPA_Reference,
    vendor_bill_id, vendor_bill_number, vendor_id, vendor_name,
    invoice_total, amount_open, currency_id, currency_name, subsidiary_id,
    invoice_date, due_date, memo
)
VALUES
(
    N'TEST', N'FROM', @Company, N'BPA-TEST', @BillNo,
    @VB_BillID, @BillNo, @VB_VendorID, @VB_VendorName,
    @TestAmount, @TestAmount, @EurID, N'EUR', @Company,
    CONVERT(varchar(10), GETDATE(), 23), CONVERT(varchar(10), GETDATE(), 23), N'BPA bank engine test'
);

INSERT INTO tb_Netsuite_Invoice
(
    BPA_Origin, BPA_Direction, BPA_Company, BPA_Syscreator, BPA_Reference,
    invoice_id, invoice_number, customer_id, customer_name,
    invoice_total, amount_open, currency_id, currency_name, subsidiary_id,
    invoice_date, due_date, memo
)
VALUES
(
    N'TEST', N'FROM', @Company, N'BPA-TEST', @InvoiceNo,
    @INV_InvoiceID, @InvoiceNo, @INV_CustomerID, @INV_CustomerName,
    @TestAmount, @TestAmount, @EurID, N'EUR', @Company,
    CONVERT(varchar(10), GETDATE(), 23), CONVERT(varchar(10), GETDATE(), 23), N'BPA bank engine test'
);

-- ---------- Rabobank transactions ----------
-- Money out: we are the debtor, the other party the creditor. Money in: the reverse.
INSERT INTO tb_Rabobank_Transaction
(
    BPA_Origin, BPA_Direction, BPA_Status, BPA_Syscreator,
    entryReference, bookingDate, valueDate, raboBookingDateTime,
    transactionAmount_value, transactionAmount_currency,
    debtorAccount_iban, debtorName, creditorAccount_iban, creditorName,
    remittanceInformationUnstructured
)
VALUES
    (@OwnIBAN, 'FROMUPDATE', 0, N'BPA-TEST',
     'BPATEST-VP-' + @run, CAST(GETDATE() AS date), CAST(GETDATE() AS date), GETUTCDATE(),
     -@TestAmount, 'EUR',
     @OwnIBAN, N'Ellomay', @DummyIBAN, @VB_VendorName,
     @BillNo),
    (@OwnIBAN, 'FROMUPDATE', 0, N'BPA-TEST',
     'BPATEST-CP-' + @run, CAST(GETDATE() AS date), CAST(GETDATE() AS date), GETUTCDATE(),
     @TestAmount, 'EUR',
     @DummyIBAN, @INV_CustomerName, @OwnIBAN, N'Ellomay',
     @InvoiceNo);

COMMIT TRANSACTION;

-- ---------- Rabobank -> tb_Bank_Transactions, snapshot with the test copies ----------
EXEC sp_Bank_Transaction_Rabobank_Copy @OwnIBAN;
EXEC dbo.sp_Bank_Synchronise_Company_V2 @Subsidiary = @Company, @Report = 0;

-- ---------- What fn_Bank_Match_V2 makes of them ----------
SELECT s.Expected,
       x.Actual,
       CASE WHEN x.Actual = s.Expected THEN 'PASS' ELSE 'FAIL' END AS Result,
       t.BPA_EntryID, t.BPA_Company, t.BPA_Reference, t.Amount, t.Currency, t.IBAN, t.Description,
       m.typematch, m.vendor_id, m.customer_id, m.Reference, m.GLCode
FROM (VALUES ('VENDORPAYMENT',   'BPATEST-VP-' + @run),
             ('CUSTOMERPAYMENT', 'BPATEST-CP-' + @run)) s(Expected, EntryReference)
LEFT JOIN tb_Bank_Transactions t ON t.BPA_Origin = @OwnIBAN AND t.BPA_Reference = s.EntryReference
OUTER APPLY dbo.fn_Bank_Match_V2('BANK', t.BPA_EntryID, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) m
CROSS APPLY (SELECT CASE      -- same rule as sp_Bank_Netsuite_FinancialEntry_Create_V2
                 WHEN t.BPA_EntryID IS NULL
                     THEN 'not copied to tb_Bank_Transactions'
                 WHEN m.typematch LIKE 'Purchase%' AND m.vendor_id IS NOT NULL AND LTRIM(RTRIM(m.Reference)) <> ''
                     THEN 'VENDORPAYMENT'
                 WHEN m.typematch LIKE 'Sales%' AND m.customer_id IS NOT NULL
                      AND (LTRIM(RTRIM(m.Reference)) <> '' OR m.ReferenceXML IS NOT NULL)
                     THEN 'CUSTOMERPAYMENT'
                 ELSE 'JOURNALENTRY'
             END AS Actual) x
ORDER BY s.Expected DESC;

-- The real documents the payments will be applied to in NetSuite
SELECT 'vendor bill' AS document, @VB_BillID AS internal_id, @BillNo AS test_number, @VB_VendorID AS relation_id,
       @VB_VendorName AS relation_name, @VB_Open AS really_open, @TestAmount AS test_payment
UNION ALL
SELECT 'invoice', @INV_InvoiceID, @InvoiceNo, @INV_CustomerID, @INV_CustomerName, @INV_Open, @TestAmount;

-- Both bank transaction ids, for the engine
SELECT t.BPA_EntryID, t.BPA_Reference, t.Amount, t.Description
FROM tb_Bank_Transactions t
WHERE t.BPA_Origin = @OwnIBAN AND t.BPA_Reference IN ('BPATEST-VP-' + @run, 'BPATEST-CP-' + @run);

PRINT N'Test run ' + @run + N' on ' + @OwnIBAN + N'. Next, per transaction above:';
PRINT N'    EXEC sp_Bank_Netsuite_FinancialEntry_Create_V2 ''' + @Company + N''', @BPA_EntryID = ''<BPA_EntryID>'', @Synchronise = 0, @Preview = 1;';
GO

/*
-- ---------- Cleanup: all test runs ----------
-- Only what isn't sent yet (BPA_Status = 0): a payment that is in NetSuite stays, with its bank transaction,
-- as the record of what happened. The test copies of the documents can always go.
BEGIN TRANSACTION;

DELETE a FROM tb_Netsuite_VendorPayment_Apply a
    JOIN tb_Netsuite_VendorPayment h ON h.BPA_EntryID = a.BPA_ParentID
    WHERE h.externalId LIKE 'BANK-%-BPATEST-%' AND h.BPA_Status = 0;
DELETE FROM tb_Netsuite_VendorPayment
    WHERE externalId LIKE 'BANK-%-BPATEST-%' AND BPA_Status = 0;
DELETE a FROM tb_Netsuite_CustomerPayment_Apply a
    JOIN tb_Netsuite_CustomerPayment h ON h.BPA_EntryID = a.BPA_ParentID
    WHERE h.externalId LIKE 'BANK-%-BPATEST-%' AND h.BPA_Status = 0;
DELETE FROM tb_Netsuite_CustomerPayment
    WHERE externalId LIKE 'BANK-%-BPATEST-%' AND BPA_Status = 0;

DELETE FROM tb_Bank_Transactions    WHERE BPA_Reference LIKE 'BPATEST-%' AND BPA_Status = 0;
DELETE FROM tb_Rabobank_Transaction WHERE entryReference LIKE 'BPATEST-%'
    AND NOT EXISTS (SELECT 1 FROM tb_Bank_Transactions t WHERE t.BPA_Reference = tb_Rabobank_Transaction.entryReference);
DELETE FROM tb_Netsuite_VendorBill  WHERE BPA_Origin = N'TEST' AND vendor_bill_number LIKE 'BPT-VB-%';
DELETE FROM tb_Netsuite_Invoice     WHERE BPA_Origin = N'TEST' AND invoice_number LIKE 'BPT-IN-%';

COMMIT TRANSACTION;

EXEC dbo.sp_Bank_Synchronise_Company_V2 @Subsidiary = '89', @Report = 0;	-- snapshot without the test copies
*/
