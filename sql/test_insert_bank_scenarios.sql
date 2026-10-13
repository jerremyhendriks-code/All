/*
    Test data for the whole bank chain, one bank transaction per scenario:

        tb_Rabobank_Transaction --sp_Bank_Transaction_Rabobank_Copy--> tb_Bank_Transactions
            --sp_Bank_Netsuite_FinancialEntry_Create (fn_Bank_Match)--> NetSuite records

    Inserts:
    - tb_Netsuite_VendorBill  one test bill    number BPATEST-VB-<tag>,  amount_open = @TestAmount
    - tb_Netsuite_Invoice     one test invoice number BPATEST-INV-<tag>, amount_open = @TestAmount
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
    By default the script picks an open bill and invoice from the staging tables
    (the latest loaded row of each), so they exist in NetSuite.

    Every run uses new numbers and entryReferences (<run> = yyyyMMddHHmmss, <tag> = the
    same in letters, so no digits end up in a description), so the script can be run again. Cleanup is at the bottom.

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

-- The real NetSuite documents the test bill / invoice point at.
-- NULL = pick an open EUR one from staging: the bill in @Company (open amount >= @TestAmount),
-- the invoice preferably in @Company. Or fill in an internal ID to use that document.
DECLARE @VB_BillID     nvarchar(100)  = NULL;
DECLARE @INV_InvoiceID nvarchar(100)  = NULL;
-- ===================

DECLARE @run      varchar(14) = FORMAT(GETDATE(), 'yyyyMMddHHmmss');
-- The descriptions get the run as letters (0 -> A ... 9 -> J): fn_Bank_Match matches a document
-- number anywhere in the description, and the staging tables hold numbers like '1'.
DECLARE @tag      varchar(14) = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@run,
                        '0', 'A'), '1', 'B'), '2', 'C'), '3', 'D'), '4', 'E'), '5', 'F'), '6', 'G'), '7', 'H'), '8', 'I'), '9', 'J');
DECLARE @BillNo   nvarchar(60) = N'BPATEST-VB-'  + @tag;
DECLARE @InvoiceNo nvarchar(60) = N'BPATEST-INV-' + @tag;
DECLARE @JournalDescription nvarchar(255) = N'BPA test bankkosten ' + @tag;
DECLARE @VB_VendorID nvarchar(100), @VB_VendorName nvarchar(255), @VB_Subsidiary nvarchar(100),
        @VB_CurrencyID nvarchar(100), @VB_Currency nvarchar(100),
        @INV_CustomerID nvarchar(100), @INV_CustomerName nvarchar(255), @INV_Subsidiary nvarchar(100),
        @INV_CurrencyID nvarchar(100), @INV_Currency nvarchar(100),
        @msg nvarchar(2048);

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
             + N'in vw_Bank_BankAccounts' + ISNULL(N' (@OwnIBAN = ' + @OwnIBAN + N')', N'') + N'.';
    THROW 50001, @msg, 1;
END

-- The real vendor bill: latest loaded row per bill, open, EUR, in @Company
;WITH bill AS (
    SELECT CAST(v.vendor_bill_id AS nvarchar(100))      AS vendor_bill_id,
           CAST(v.vendor_id AS nvarchar(100))           AS vendor_id,
           v.vendor_name,
           CAST(v.subsidiary_id AS nvarchar(100))       AS subsidiary_id,
           CAST(v.currency_id AS nvarchar(100))         AS currency_id,
           TRY_CAST(v.amount_open AS decimal(18, 2))    AS amount_open,
           ROW_NUMBER() OVER (PARTITION BY v.vendor_bill_id
                              ORDER BY v.BPA_Syscreated DESC, v.BPA_EntryID DESC) AS rn
    FROM tb_Netsuite_VendorBill v
    WHERE v.vendor_bill_number NOT LIKE 'BPATEST-%'
)
SELECT TOP (1)
       @VB_BillID     = b.vendor_bill_id,
       @VB_VendorID   = b.vendor_id,
       @VB_VendorName = b.vendor_name,
       @VB_Subsidiary = b.subsidiary_id,
       @VB_CurrencyID = b.currency_id,
       @VB_Currency   = c.symbol
FROM bill b
JOIN tb_Netsuite_Currency c ON c.id = b.currency_id
WHERE b.rn = 1
  AND b.vendor_id IS NOT NULL
  AND (   b.vendor_bill_id = @VB_BillID
       OR (@VB_BillID IS NULL AND b.subsidiary_id = @Company AND c.symbol = 'EUR' AND b.amount_open >= @TestAmount))
  -- not waiting in an unsent vendor payment
  AND NOT EXISTS (SELECT 1
                  FROM tb_Netsuite_VendorPayment_Apply a
                  JOIN tb_Netsuite_VendorPayment h ON h.BPA_EntryID = a.BPA_ParentID
                  WHERE a.doc_id = b.vendor_bill_id AND h.BPA_Direction = 'TO' AND h.BPA_Status = 0)
ORDER BY b.amount_open DESC, b.vendor_bill_id;

IF @VB_VendorID IS NULL
BEGIN
    SET @msg = N'No vendor bill found: ' + ISNULL(N'bill ' + @VB_BillID + N' is not in tb_Netsuite_VendorBill',
               N'no open EUR bill in subsidiary ' + @Company + N' with at least ' + CAST(@TestAmount AS nvarchar(20)) + N' open') + N'.';
    THROW 50002, @msg, 1;
END

IF @VB_Subsidiary <> @Company
    PRINT N'WARNING: the test bill is in subsidiary ' + @VB_Subsidiary + N', the bank account in ' + @Company
        + N': the vendor payment will be skipped.';

-- The real invoice: latest loaded row per invoice, open, EUR, preferably in @Company
;WITH inv AS (
    SELECT CAST(i.invoice_id AS nvarchar(100))          AS invoice_id,
           CAST(i.customer_id AS nvarchar(100))         AS customer_id,
           i.customer_name,
           CAST(i.subsidiary_id AS nvarchar(100))       AS subsidiary_id,
           CAST(i.currency_id AS nvarchar(100))         AS currency_id,
           TRY_CAST(i.amount_open AS decimal(18, 2))    AS amount_open,
           ROW_NUMBER() OVER (PARTITION BY i.invoice_id
                              ORDER BY i.BPA_Syscreated DESC, i.BPA_EntryID DESC) AS rn
    FROM tb_Netsuite_Invoice i
    WHERE i.invoice_number NOT LIKE 'BPATEST-%'
)
SELECT TOP (1)
       @INV_InvoiceID    = x.invoice_id,
       @INV_CustomerID   = x.customer_id,
       @INV_CustomerName = x.customer_name,
       @INV_Subsidiary   = x.subsidiary_id,
       @INV_CurrencyID   = x.currency_id,
       @INV_Currency     = c.symbol
FROM inv x
JOIN tb_Netsuite_Currency c ON c.id = x.currency_id
WHERE x.rn = 1
  AND x.customer_id IS NOT NULL
  AND (   x.invoice_id = @INV_InvoiceID
       OR (@INV_InvoiceID IS NULL AND c.symbol = 'EUR' AND x.amount_open >= @TestAmount))
ORDER BY CASE WHEN x.subsidiary_id = @Company THEN 0 ELSE 1 END, x.amount_open DESC, x.invoice_id;

IF @INV_CustomerID IS NULL
BEGIN
    SET @msg = N'No invoice found: ' + ISNULL(N'invoice ' + @INV_InvoiceID + N' is not in tb_Netsuite_Invoice',
               N'no open EUR invoice with at least ' + CAST(@TestAmount AS nvarchar(20)) + N' open') + N'.';
    THROW 50005, @msg, 1;
END

IF @INV_Subsidiary <> @Company
    PRINT N'NOTE: the test invoice is in subsidiary ' + @INV_Subsidiary + N' (none open in ' + @Company
        + N'); fine for now, the customer scenario is not built yet.';

IF EXISTS (SELECT 1 FROM tb_Netsuite_Bank_account_details
           WHERE REPLACE(UPPER(custrecord_2663_entity_iban), ' ', '') = @DummyIBAN)
    THROW 50003, N'@DummyIBAN exists in tb_Netsuite_Bank_account_details; pick another one.', 1;

-- fn_Bank_Match matches on "number appears in the description": no existing number may
-- be part of a test description
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
    SET @msg = N'Existing document numbers appear in the test descriptions: ' + @msg + N'.';
    THROW 50004, @msg, 1;
END

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

SELECT 'vendor bill' AS document, @VB_BillID AS internal_id, @BillNo AS test_number, @VB_VendorID AS relation_id,
       @VB_VendorName AS relation_name, @VB_Subsidiary AS subsidiary_id, @VB_Currency AS currency
UNION ALL
SELECT 'invoice', @INV_InvoiceID, @InvoiceNo, @INV_CustomerID, @INV_CustomerName, @INV_Subsidiary, @INV_Currency;

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
