/*
    Test data for sp_Bank_Netsuite_FinancialEntry_Create: force three open bank
    transactions of @BPA_Company into the three scenarios.

        1. VENDORPAYMENT    money out, description = a vendor bill number, amount = -amount_open
        2. CUSTOMERPAYMENT  money in,  description = an invoice number,    amount =  amount_open
        3. JOURNALENTRY     money out, description that matches nothing (like bank costs)

    All three get a dummy IBAN, so fn_Bank_Match has to find the vendor / customer
    through the document number in the description (the IBAN can't interfere).

    The transactions are picked automatically (oldest open ones whose bank account has
    Company, GLCodeBank and DefaultGLCodeCreditor filled in); set @VendorEntry /
    @CustomerEntry / @JournalEntry to use specific ones.
    The vendor bill is picked so the procedure will accept it:
    - open, in the bank account's subsidiary, in currency @Currency;
    - its number identifies exactly one bill (no other bill or invoice number inside it);
    - every loaded row of the bill has the same amount_open;
    - not already in a vendor payment that hasn't been sent yet.
    The invoice is picked the same way (same subsidiary preferred).

    Only IBAN / Description / Amount / Currency / Kenmerk / Betalingskenmerk /
    Incassant / Machtiging are overwritten. The original rows are copied to
    tb_Bank_Transactions_TestBackup first (once per row); the restore is at the bottom.

    After this script:
        EXEC sp_Bank_Netsuite_FinancialEntry_Create '89', @Preview = 1;   -- vendor row: 'would be created'
        EXEC sp_Bank_Netsuite_FinancialEntry_Create '89';                 -- creates the vendor payment
*/
USE [BPAStaging]
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

-- ===== Fill in (NULL = pick automatically) =====
DECLARE @BPA_Company   varchar(50)      = '89';
DECLARE @Currency      varchar(20)      = 'EUR';
DECLARE @VendorEntry   uniqueidentifier = NULL;
DECLARE @CustomerEntry uniqueidentifier = NULL;
DECLARE @JournalEntry  uniqueidentifier = NULL;

DECLARE @DummyIBAN          varchar(33)  = 'NL00TEST0000000001';
DECLARE @JournalDescription varchar(255) = 'TEST bankkosten - geen match';
DECLARE @JournalAmount      float        = -12.34;
-- ===============================================

DECLARE @msg nvarchar(2048);

-- ---------- Pre-checks ----------
IF OBJECT_DEFINITION(OBJECT_ID(N'dbo.fn_Bank_Match')) LIKE N'%NL20ABNA0881342394%'
    PRINT N'WARNING: fn_Bank_Match still mentions NL20ABNA0881342394. If the hard-coded SET @IBAN / @Description / @Amount lines are active, every transaction gets the same result.';

IF EXISTS (SELECT 1 FROM tb_Netsuite_Bank_account_details
           WHERE REPLACE(UPPER(custrecord_2663_entity_iban), ' ', '') = @DummyIBAN)
    THROW 50001, N'@DummyIBAN exists in tb_Netsuite_Bank_account_details; pick another one.', 1;

IF EXISTS (SELECT 1 FROM tb_Netsuite_Invoice i
           WHERE LTRIM(RTRIM(i.invoice_number)) <> ''
             AND @JournalDescription LIKE '%' + LTRIM(RTRIM(i.invoice_number)) + '%')
OR EXISTS (SELECT 1 FROM tb_Netsuite_VendorBill v
           WHERE LTRIM(RTRIM(v.vendor_bill_number)) <> ''
             AND @JournalDescription LIKE '%' + LTRIM(RTRIM(v.vendor_bill_number)) + '%')
    THROW 50002, N'@JournalDescription contains an invoice or vendor bill number; pick another description.', 1;

-- ---------- Pick the three transactions ----------
DECLARE @candidates TABLE (rn int IDENTITY(1, 1), BPA_EntryID uniqueidentifier);

INSERT INTO @candidates (BPA_EntryID)
SELECT t.BPA_EntryID
FROM tb_Bank_Transactions t
JOIN vw_Bank_BankAccounts bank ON bank.Bankaccount = t.BPA_Origin COLLATE database_default
WHERE t.BPA_Status = 0
  AND t.BPA_Company = @BPA_Company
  AND t.BPA_Reference IS NOT NULL
  AND bank.Company IS NOT NULL
  AND bank.GLCodeBank IS NOT NULL
  AND bank.DefaultGLCodeCreditor IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM tb_Netsuite_VendorPayment h
                  WHERE h.externalId = 'BANK-' + t.BPA_Origin + '-' + t.BPA_Reference)
  AND t.BPA_EntryID NOT IN (ISNULL(@VendorEntry,   '00000000-0000-0000-0000-000000000000'),
                            ISNULL(@CustomerEntry, '00000000-0000-0000-0000-000000000000'),
                            ISNULL(@JournalEntry,  '00000000-0000-0000-0000-000000000000'))
ORDER BY t.Bookdate, t.BPA_EntryID;

IF @VendorEntry   IS NULL SELECT @VendorEntry   = BPA_EntryID FROM @candidates WHERE rn = 1;
IF @CustomerEntry IS NULL SELECT @CustomerEntry = BPA_EntryID FROM @candidates WHERE rn = 2;
IF @JournalEntry  IS NULL SELECT @JournalEntry  = BPA_EntryID FROM @candidates WHERE rn = 3;

IF @VendorEntry IS NULL OR @CustomerEntry IS NULL OR @JournalEntry IS NULL
    THROW 50003, N'Not enough usable open transactions: need BPA_Status = 0, a BPA_Reference, and a bank account with Company, GLCodeBank and DefaultGLCodeCreditor filled in tb_Bank_Bankaccount_Settings.', 1;

IF @VendorEntry IN (@CustomerEntry, @JournalEntry) OR @CustomerEntry = @JournalEntry
    THROW 50004, N'Use three different transactions.', 1;

-- Subsidiary of the bank accounts
DECLARE @VendorSubsidiary nvarchar(100), @CustomerSubsidiary nvarchar(100);

SELECT @VendorSubsidiary = bank.Company
FROM tb_Bank_Transactions t
JOIN vw_Bank_BankAccounts bank ON bank.Bankaccount = t.BPA_Origin COLLATE database_default
WHERE t.BPA_EntryID = @VendorEntry;

SELECT @CustomerSubsidiary = bank.Company
FROM tb_Bank_Transactions t
JOIN vw_Bank_BankAccounts bank ON bank.Bankaccount = t.BPA_Origin COLLATE database_default
WHERE t.BPA_EntryID = @CustomerEntry;

IF @VendorSubsidiary IS NULL
    THROW 50005, N'The vendor transaction''s bank account has no Company (subsidiary) in tb_Bank_Bankaccount_Settings.', 1;

-- ---------- Scenario 1: a vendor bill the procedure will accept ----------
DECLARE @V_VendorID nvarchar(100), @V_BillID nvarchar(100), @V_BillNo varchar(255), @V_Amount decimal(18, 2);

;WITH bill AS (
    SELECT CAST(v.vendor_bill_id AS nvarchar(100))      AS vendor_bill_id,
           CAST(v.vendor_id AS nvarchar(100))           AS vendor_id,
           LTRIM(RTRIM(v.vendor_bill_number))           AS bill_number,
           TRY_CAST(v.amount_open AS decimal(18, 2))    AS amount_open,
           CAST(v.subsidiary_id AS nvarchar(100))       AS subsidiary_id,
           CAST(v.currency_id AS nvarchar(100))         AS currency_id,
           ROW_NUMBER() OVER (PARTITION BY v.vendor_bill_id
                              ORDER BY v.BPA_Syscreated DESC, v.BPA_EntryID DESC) AS rn
    FROM tb_Netsuite_VendorBill v
)
SELECT TOP (1)
       @V_VendorID = b.vendor_id,
       @V_BillID   = b.vendor_bill_id,
       @V_BillNo   = b.bill_number,
       @V_Amount   = b.amount_open
FROM bill b
WHERE b.rn = 1
  AND b.amount_open > 0
  AND b.bill_number <> ''
  AND b.subsidiary_id = @VendorSubsidiary
  AND EXISTS (SELECT 1 FROM tb_Netsuite_Currency c WHERE c.id = b.currency_id AND c.symbol = @Currency)
  -- the number points at this bill only
  AND (SELECT COUNT(DISTINCT v2.vendor_bill_id) FROM tb_Netsuite_VendorBill v2
       WHERE LTRIM(RTRIM(v2.vendor_bill_number)) <> ''
         AND b.bill_number LIKE '%' + LTRIM(RTRIM(v2.vendor_bill_number)) + '%') = 1
  -- and at no invoice (that would make it a customer)
  AND NOT EXISTS (SELECT 1 FROM tb_Netsuite_Invoice i
                  WHERE LTRIM(RTRIM(i.invoice_number)) <> ''
                    AND b.bill_number LIKE '%' + LTRIM(RTRIM(i.invoice_number)) + '%')
  -- fn_Bank_Match reads every loaded row of the bill: they must agree on the open amount
  AND NOT EXISTS (SELECT 1 FROM tb_Netsuite_VendorBill v3
                  WHERE CAST(v3.vendor_bill_id AS nvarchar(100)) = b.vendor_bill_id
                    AND ISNULL(TRY_CAST(v3.amount_open AS decimal(18, 2)), -1) <> b.amount_open)
  -- not waiting in an unsent vendor payment
  AND NOT EXISTS (SELECT 1
                  FROM tb_Netsuite_VendorPayment_Apply a
                  JOIN tb_Netsuite_VendorPayment h ON h.BPA_EntryID = a.BPA_ParentID
                  WHERE a.doc_id = b.vendor_bill_id AND h.BPA_Direction = 'TO' AND h.BPA_Status = 0)
ORDER BY b.amount_open, b.vendor_bill_id;

IF @V_BillID IS NULL
BEGIN
    SET @msg = N'No usable vendor bill: need an open ' + @Currency + N' bill in subsidiary ' + @VendorSubsidiary
             + N' with a unique bill number. Check tb_Netsuite_VendorBill (subsidiary_id, currency_id, amount_open).';
    THROW 50010, @msg, 1;
END

-- ---------- Scenario 2: an invoice ----------
DECLARE @C_CustomerID nvarchar(100), @C_InvoiceID nvarchar(100), @C_InvoiceNo varchar(255), @C_Amount decimal(18, 2);

;WITH inv AS (
    SELECT CAST(i.invoice_id AS nvarchar(100))          AS invoice_id,
           CAST(i.customer_id AS nvarchar(100))         AS customer_id,
           LTRIM(RTRIM(i.invoice_number))               AS invoice_number,
           TRY_CAST(i.amount_open AS decimal(18, 2))    AS amount_open,
           CAST(i.subsidiary_id AS nvarchar(100))       AS subsidiary_id,
           CAST(i.currency_id AS nvarchar(100))         AS currency_id,
           ROW_NUMBER() OVER (PARTITION BY i.invoice_id
                              ORDER BY i.BPA_Syscreated DESC, i.BPA_EntryID DESC) AS rn
    FROM tb_Netsuite_Invoice i
)
SELECT TOP (1)
       @C_CustomerID = x.customer_id,
       @C_InvoiceID  = x.invoice_id,
       @C_InvoiceNo  = x.invoice_number,
       @C_Amount     = x.amount_open
FROM inv x
WHERE x.rn = 1
  AND x.amount_open > 0
  AND x.invoice_number <> ''
  AND EXISTS (SELECT 1 FROM tb_Netsuite_Currency c WHERE c.id = x.currency_id AND c.symbol = @Currency)
  AND (SELECT COUNT(DISTINCT i2.invoice_id) FROM tb_Netsuite_Invoice i2
       WHERE LTRIM(RTRIM(i2.invoice_number)) <> ''
         AND x.invoice_number LIKE '%' + LTRIM(RTRIM(i2.invoice_number)) + '%') = 1
  AND NOT EXISTS (SELECT 1 FROM tb_Netsuite_VendorBill v
                  WHERE LTRIM(RTRIM(v.vendor_bill_number)) <> ''
                    AND x.invoice_number LIKE '%' + LTRIM(RTRIM(v.vendor_bill_number)) + '%')
  AND NOT EXISTS (SELECT 1 FROM tb_Netsuite_Invoice i3
                  WHERE CAST(i3.invoice_id AS nvarchar(100)) = x.invoice_id
                    AND ISNULL(TRY_CAST(i3.amount_open AS decimal(18, 2)), -1) <> x.amount_open)
ORDER BY CASE WHEN x.subsidiary_id = @CustomerSubsidiary THEN 0 ELSE 1 END, x.amount_open, x.invoice_id;

IF @C_InvoiceID IS NULL
BEGIN
    SET @msg = N'No usable invoice: need an open ' + @Currency + N' invoice with a unique invoice number.';
    THROW 50011, @msg, 1;
END

-- ---------- Backup + overwrite ----------
BEGIN TRANSACTION;

IF OBJECT_ID(N'dbo.tb_Bank_Transactions_TestBackup') IS NULL
    SELECT * INTO dbo.tb_Bank_Transactions_TestBackup
    FROM tb_Bank_Transactions
    WHERE BPA_EntryID IN (@VendorEntry, @CustomerEntry, @JournalEntry);
ELSE
    INSERT INTO dbo.tb_Bank_Transactions_TestBackup
    SELECT t.* FROM tb_Bank_Transactions t
    WHERE t.BPA_EntryID IN (@VendorEntry, @CustomerEntry, @JournalEntry)
      AND NOT EXISTS (SELECT 1 FROM dbo.tb_Bank_Transactions_TestBackup b WHERE b.BPA_EntryID = t.BPA_EntryID);

UPDATE tb_Bank_Transactions
SET IBAN = @DummyIBAN, Description = @V_BillNo, Amount = -@V_Amount, Currency = @Currency,
    Kenmerk = NULL, Betalingskenmerk = NULL, Incassant = NULL, Machtiging = NULL
WHERE BPA_EntryID = @VendorEntry;

UPDATE tb_Bank_Transactions
SET IBAN = @DummyIBAN, Description = @C_InvoiceNo, Amount = @C_Amount, Currency = @Currency,
    Kenmerk = NULL, Betalingskenmerk = NULL, Incassant = NULL, Machtiging = NULL
WHERE BPA_EntryID = @CustomerEntry;

UPDATE tb_Bank_Transactions
SET IBAN = @DummyIBAN, Description = @JournalDescription, Amount = @JournalAmount, Currency = @Currency,
    Kenmerk = NULL, Betalingskenmerk = NULL, Incassant = NULL, Machtiging = NULL
WHERE BPA_EntryID = @JournalEntry;

COMMIT TRANSACTION;

-- ---------- What was set, and what fn_Bank_Match makes of it ----------
SELECT s.Scenario AS Expected,
       x.Actual,
       CASE WHEN x.Actual = s.Expected THEN 'PASS' ELSE 'FAIL' END AS Result,
       s.BPA_EntryID, t.Amount, t.Description, s.Source,
       m.typematch, m.vendor_id, m.customer_id, m.Reference, m.GLCode
FROM (VALUES ('VENDORPAYMENT',   @VendorEntry,   N'vendor ' + @V_VendorID + N', vendor_bill_id ' + @V_BillID),
             ('CUSTOMERPAYMENT', @CustomerEntry, N'customer ' + @C_CustomerID + N', invoice_id ' + @C_InvoiceID),
             ('JOURNALENTRY',    @JournalEntry,  N'no relation')) s(Scenario, BPA_EntryID, Source)
JOIN tb_Bank_Transactions t ON t.BPA_EntryID = s.BPA_EntryID
CROSS APPLY dbo.fn_Bank_Match('BANK', s.BPA_EntryID, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) m
CROSS APPLY (SELECT CASE      -- same rule as sp_Bank_Netsuite_FinancialEntry_Create
                 WHEN m.typematch LIKE 'Purchase%' AND m.vendor_id IS NOT NULL AND LTRIM(RTRIM(m.Reference)) <> ''
                     THEN 'VENDORPAYMENT'
                 WHEN m.typematch LIKE 'Sales%' AND m.customer_id IS NOT NULL
                      AND (LTRIM(RTRIM(m.Reference)) <> '' OR m.ReferenceXML IS NOT NULL)
                     THEN 'CUSTOMERPAYMENT'
                 ELSE 'JOURNALENTRY'
             END AS Actual) x
ORDER BY s.Scenario DESC;
GO

/*
-- ---------- Restore the original rows ----------
-- (BPA_Status / BPA_ReturnedID are not restored: a transaction that became a vendor
--  payment stays done, so it can't create a second payment.)
UPDATE t
SET IBAN = b.IBAN, Description = b.Description, Amount = b.Amount, Currency = b.Currency,
    Kenmerk = b.Kenmerk, Betalingskenmerk = b.Betalingskenmerk, Incassant = b.Incassant, Machtiging = b.Machtiging
FROM tb_Bank_Transactions t
JOIN dbo.tb_Bank_Transactions_TestBackup b ON b.BPA_EntryID = t.BPA_EntryID;

DROP TABLE dbo.tb_Bank_Transactions_TestBackup;
*/
