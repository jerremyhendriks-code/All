/*
    Test data for the whole bank chain, one bank transaction per scenario:

        tb_Rabobank_Transaction --sp_Bank_Transaction_Rabobank_Copy--> tb_Bank_Transactions
            --sp_Bank_Netsuite_FinancialEntry_Create (fn_Bank_Match)--> NetSuite records

    Inserts:
    - tb_Netsuite_VendorBill  one test bill    number BPATEST-VB-<run>,  amount_open = @TestAmount
    - tb_Netsuite_Invoice     one test invoice number BPATEST-INV-<run>, amount_open = @TestAmount
    - tb_Rabobank_Transaction three transactions on our own account @OwnIBAN:
        1. VENDORPAYMENT    money out, -@TestAmount, description = the test bill number
        2. CUSTOMERPAYMENT  money in,  +@TestAmount, description = the test invoice number
        3. JOURNALENTRY     money out, -@JournalAmount, description that matches nothing
      The other party is a dummy IBAN, so only the document number can make the match.

    The test bill and invoice carry the internal IDs of REAL open NetSuite documents
    (vendor_bill_id / invoice_id, vendor / customer, subsidiary, currency): the vendor
    payment is applied on vendor_bill_id, so NetSuite only accepts it when that bill
    exists, is open and belongs to that vendor. Only the number is made up, so it
    can't clash with anything; @TestAmount must not be more than what is really open
    (NetSuite then records a partial payment).
    Defaults are the sandbox documents used in the earlier NetSuite payment tests;
    check them before running.

    Every run uses new numbers and entryReferences (<run> = yyyyMMddHHmmss), so the
    script can be run again. Cleanup is at the bottom.

    Note: sp_Bank_Transaction_Rabobank_Copy copies ALL waiting Rabobank rows of
    @OwnIBAN, not only these three.
*/
USE [BPAStaging]
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

-- ===== Fill in =====
DECLARE @Company       nvarchar(50)   = N'89';          -- NetSuite subsidiary = BPA_Company of the bank transactions
DECLARE @OwnIBAN       varchar(34)    = NULL;           -- our bank account; NULL = the first complete one of @Company
DECLARE @TestAmount    decimal(18, 2) = 10.00;          -- vendor payment and customer payment
DECLARE @JournalAmount decimal(18, 2) = 12.34;          -- journal entry (money out)
DECLARE @DummyIBAN     varchar(34)    = 'NL00TEST0000000001';

-- Real open vendor bill: GGG, bill 77777777, vendor 21705 Lucas Westra B.V.
DECLARE @VB_BillID     nvarchar(100)  = N'37393';
DECLARE @VB_VendorID   nvarchar(100)  = N'5733';
DECLARE @VB_VendorName nvarchar(255)  = N'21705 Lucas Westra B.V.';
DECLARE @VB_Subsidiary nvarchar(100)  = N'89';
DECLARE @VB_CurrencyID nvarchar(100)  = N'4';           -- EUR

-- Real open invoice: customer 4044 (Italy 2). The customer scenario is not built yet;
-- for that scenario later the invoice must be in the same subsidiary as @OwnIBAN.
DECLARE @INV_InvoiceID    nvarchar(100) = N'17544';
DECLARE @INV_CustomerID   nvarchar(100) = N'4044';
DECLARE @INV_CustomerName nvarchar(255) = N'BPA test customer';
DECLARE @INV_Subsidiary   nvarchar(100) = N'45';
DECLARE @INV_CurrencyID   nvarchar(100) = N'4';         -- EUR
-- ===================

DECLARE @run      varchar(14) = FORMAT(GETDATE(), 'yyyyMMddHHmmss');
DECLARE @BillNo   nvarchar(60) = N'BPATEST-VB-'  + @run;
DECLARE @InvoiceNo nvarchar(60) = N'BPATEST-INV-' + @run;
DECLARE @JournalDescription nvarchar(255) = N'BPA test bankkosten ' + @run;
DECLARE @VB_Currency  nvarchar(100), @INV_Currency nvarchar(100), @msg nvarchar(2048);

-- ---------- Pre-checks ----------
IF @OwnIBAN IS NULL
    SELECT TOP (1) @OwnIBAN = bank.Bankaccount
    FROM vw_Bank_BankAccounts bank
    WHERE bank.Company = @Company
      AND bank.GLCodeBank IS NOT NULL
      AND bank.DefaultGLCodeCreditor IS NOT NULL
    ORDER BY bank.Bankaccount;

IF NOT EXISTS (SELECT 1 FROM vw_Bank_BankAccounts bank
               WHERE bank.Bankaccount = @OwnIBAN
                 AND bank.Company = @Company
                 AND bank.GLCodeBank IS NOT NULL
                 AND bank.DefaultGLCodeCreditor IS NOT NULL)
BEGIN
    SET @msg = N'No bank account of subsidiary ' + @Company + N' with Company, GLCodeBank and DefaultGLCodeCreditor '
             + N'in tb_Bank_Bankaccount_Settings' + ISNULL(N' (@OwnIBAN = ' + @OwnIBAN + N')', N'') + N'.';
    THROW 50001, @msg, 1;
END

IF @VB_Subsidiary <> @Company
    PRINT N'WARNING: the test bill is in subsidiary ' + @VB_Subsidiary + N', the bank account in ' + @Company
        + N': the vendor payment will be skipped.';

SELECT TOP (1) @VB_Currency  = symbol FROM tb_Netsuite_Currency WHERE id = @VB_CurrencyID;
SELECT TOP (1) @INV_Currency = symbol FROM tb_Netsuite_Currency WHERE id = @INV_CurrencyID;
IF @VB_Currency IS NULL OR @INV_Currency IS NULL
    THROW 50002, N'@VB_CurrencyID or @INV_CurrencyID not found in tb_Netsuite_Currency.', 1;

IF EXISTS (SELECT 1 FROM tb_Netsuite_Bank_account_details
           WHERE REPLACE(UPPER(custrecord_2663_entity_iban), ' ', '') = @DummyIBAN)
    THROW 50003, N'@DummyIBAN exists in tb_Netsuite_Bank_account_details; pick another one.', 1;

-- fn_Bank_Match matches on "number appears in the description": no existing number may
-- be part of a test description (e.g. an invoice '1013' inside the run timestamp)
SELECT @msg = ISNULL(@msg + N', ', N'') + d.number
FROM (SELECT LTRIM(RTRIM(invoice_number)) AS number FROM tb_Netsuite_Invoice
      UNION
      SELECT LTRIM(RTRIM(vendor_bill_number)) FROM tb_Netsuite_VendorBill) d
WHERE d.number <> ''
  AND (   @BillNo             LIKE '%' + d.number + '%'
       OR @InvoiceNo          LIKE '%' + d.number + '%'
       OR @JournalDescription LIKE '%' + d.number + '%');
IF @msg IS NOT NULL
BEGIN
    SET @msg = N'Existing document numbers appear in the test descriptions: ' + @msg + N'. Run again a minute later.';
    THROW 50004, @msg, 1;
END

-- A bill already waiting in an unsent vendor payment would be skipped
IF EXISTS (SELECT 1
           FROM tb_Netsuite_VendorPayment_Apply a
           JOIN tb_Netsuite_VendorPayment h ON h.BPA_EntryID = a.BPA_ParentID
           WHERE a.doc_id = @VB_BillID AND h.BPA_Direction = 'TO' AND h.BPA_Status = 0)
    PRINT N'WARNING: bill ' + @VB_BillID + N' is already in an unsent vendor payment: the vendor payment will be skipped.';

BEGIN TRANSACTION;

-- ---------- NetSuite documents ----------
INSERT INTO tb_Netsuite_VendorBill
(
    BPA_Origin, BPA_Direction, BPA_Company, BPA_Syscreator, BPA_Reference,
    id, vendor_bill_id, vendor_bill_number, vendor_id, vendor_name,
    invoice_total, amount_open, currency_id, currency_name, subsidiary_id,
    invoice_date, due_date, memo
)
VALUES
(
    N'TEST', N'FROM', @Company, N'BPA-TEST', @BillNo,
    @VB_BillID, @VB_BillID, @BillNo, @VB_VendorID, @VB_VendorName,
    @TestAmount, @TestAmount, @VB_CurrencyID, @VB_Currency, @VB_Subsidiary,
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
    N'TEST', N'FROM', @INV_Subsidiary, N'BPA-TEST', @InvoiceNo,
    @INV_InvoiceID, @InvoiceNo, @INV_CustomerID, @INV_CustomerName,
    @TestAmount, @TestAmount, @INV_CurrencyID, @INV_Currency, @INV_Subsidiary,
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
     -@TestAmount, @VB_Currency,
     @OwnIBAN, N'Ellomay', @DummyIBAN, @VB_VendorName,
     @BillNo),
    (@OwnIBAN, 'FROMUPDATE', 0, N'BPA-TEST',
     'BPATEST-CP-' + @run, CAST(GETDATE() AS date), CAST(GETDATE() AS date), GETUTCDATE(),
     @TestAmount, @INV_Currency,
     @DummyIBAN, @INV_CustomerName, @OwnIBAN, N'Ellomay',
     @InvoiceNo),
    (@OwnIBAN, 'FROMUPDATE', 0, N'BPA-TEST',
     'BPATEST-JE-' + @run, CAST(GETDATE() AS date), CAST(GETDATE() AS date), GETUTCDATE(),
     -@JournalAmount, @VB_Currency,
     @OwnIBAN, N'Ellomay', @DummyIBAN, N'BPA test bank',
     @JournalDescription);

COMMIT TRANSACTION;

-- ---------- Rabobank -> tb_Bank_Transactions ----------
EXEC sp_Bank_Transaction_Rabobank_Copy @OwnIBAN;

-- ---------- What fn_Bank_Match makes of them ----------
SELECT s.Expected,
       x.Actual,
       CASE WHEN x.Actual = s.Expected THEN 'PASS' ELSE 'FAIL' END AS Result,
       t.BPA_EntryID, t.BPA_Company, t.BPA_Reference, t.Amount, t.Currency, t.IBAN, t.Description,
       m.typematch, m.vendor_id, m.customer_id, m.Reference, m.GLCode
FROM (VALUES ('VENDORPAYMENT',   'BPATEST-VP-' + @run),
             ('CUSTOMERPAYMENT', 'BPATEST-CP-' + @run),
             ('JOURNALENTRY',    'BPATEST-JE-' + @run)) s(Expected, EntryReference)
LEFT JOIN tb_Bank_Transactions t ON t.BPA_Origin = @OwnIBAN AND t.BPA_Reference = s.EntryReference
OUTER APPLY dbo.fn_Bank_Match('BANK', t.BPA_EntryID, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) m
CROSS APPLY (SELECT CASE      -- same rule as sp_Bank_Netsuite_FinancialEntry_Create
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

PRINT N'Test run ' + @run + N' on ' + @OwnIBAN + N'. Next:';
PRINT N'    EXEC sp_Bank_Netsuite_FinancialEntry_Create ''' + @Company + N''', @Preview = 1;';
GO

/*
-- ---------- Cleanup: all test runs ----------
-- Run before the vendor payment is sent to NetSuite, or the BPA_Status = 1 bank rows
-- and the sent payment stay as the record of what happened.
BEGIN TRANSACTION;

DELETE a FROM tb_Netsuite_VendorPayment_Apply a
    JOIN tb_Netsuite_VendorPayment h ON h.BPA_EntryID = a.BPA_ParentID
    WHERE h.externalId LIKE 'BANK-%-BPATEST-%' AND h.BPA_Status = 0;
DELETE FROM tb_Netsuite_VendorPayment
    WHERE externalId LIKE 'BANK-%-BPATEST-%' AND BPA_Status = 0;

DELETE FROM tb_Bank_Transactions    WHERE BPA_Reference LIKE 'BPATEST-%';
DELETE FROM tb_Rabobank_Transaction WHERE entryReference LIKE 'BPATEST-%';
DELETE FROM tb_Netsuite_VendorBill  WHERE vendor_bill_number LIKE 'BPATEST-VB-%';
DELETE FROM tb_Netsuite_Invoice     WHERE invoice_number LIKE 'BPATEST-INV-%';

COMMIT TRANSACTION;
*/
