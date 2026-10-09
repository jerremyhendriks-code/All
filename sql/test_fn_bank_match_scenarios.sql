/*
    Force two bank transactions in tb_Bank_Transactions into two of the
    fn_Bank_Match outcomes, then run the function on them:

        1. vendor_id   + Reference  -> vendorPayment
        3. no vendor / no customer  -> journalEntry

    (Scenario 2, customer_id + Reference -> customerPayment, is left out: there is
    no usable open invoice to test it with.)

    The two BPA_EntryIDs are picked automatically: the first two rows of
    tb_Bank_Transactions by BPA_EntryID. Set @VendorEntry / @JournalEntry below to
    use specific rows instead. Re-running picks the same rows again.
    The script overwrites IBAN / Description / Amount / Currency / Kenmerk /
    Betalingskenmerk / Incassant / Machtiging on those two rows. BPA_Origin (the
    bank account) is left as is.

    - Scenario 1: an open vendor bill whose vendor has an IBAN in
      tb_Netsuite_Bank_account_details that belongs to that vendor only.
      IBAN = that IBAN, Description = the bill number, Amount = amount_open.
    - Scenario 3: a dummy IBAN and a description that match nothing.

    The original rows are copied to tb_Bank_Transactions_TestBackup first
    (only the first time a row is backed up); the restore is at the bottom.

    vw_Bank_BankAccounts is currently the "Workflow variant" placeholder (one row,
    Bankaccount = NULL), so BPA_Origin can't be found there. That is reported as a
    warning, not an error; if fn_Bank_Match needs the bank account row, the
    function returns nothing and the result shows 'no result'.

    Remove the hard-coded SET @IBAN / @Description / @Amount lines from
    fn_Bank_Match first, or both rows get the same values.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

-- ===== Fill in (NULL = pick automatically) =====
DECLARE @VendorEntry   uniqueidentifier = NULL;
DECLARE @JournalEntry  uniqueidentifier = NULL;

DECLARE @DummyIBAN_Journal  varchar(33)  = 'NL00TEST0000000002';
DECLARE @JournalDescription varchar(255) = 'TEST journal entry - no match';
DECLARE @JournalAmount      float        = 12.34;
DECLARE @JournalCurrency    varchar(20)  = 'EUR';
-- ===============================================

DECLARE @msg nvarchar(2048);

-- ---------- Pick the two rows ----------
IF @VendorEntry IS NULL
    SELECT TOP (1) @VendorEntry = t.BPA_EntryID
    FROM tb_Bank_Transactions t
    WHERE t.BPA_EntryID <> ISNULL(@JournalEntry, '00000000-0000-0000-0000-000000000000')
    ORDER BY t.BPA_EntryID;

IF @JournalEntry IS NULL
    SELECT TOP (1) @JournalEntry = t.BPA_EntryID
    FROM tb_Bank_Transactions t
    WHERE t.BPA_EntryID <> @VendorEntry
    ORDER BY t.BPA_EntryID;

IF @VendorEntry IS NULL OR @JournalEntry IS NULL
    THROW 50000, N'tb_Bank_Transactions needs at least two rows.', 1;

-- ---------- Pre-checks ----------
IF OBJECT_DEFINITION(OBJECT_ID(N'dbo.fn_Bank_Match')) LIKE N'%NL20ABNA0881342394%'
    PRINT N'WARNING: fn_Bank_Match still mentions NL20ABNA0881342394. If the hard-coded SET @IBAN / @Description / @Amount lines are still active, every row gets those values.';

IF @VendorEntry = @JournalEntry
    THROW 50001, N'Use two different BPA_EntryIDs.', 1;

SELECT @msg = ISNULL(@msg + N', ', N'') + CAST(e.id AS nvarchar(36))
FROM (VALUES (@VendorEntry), (@JournalEntry)) e(id)
WHERE NOT EXISTS (SELECT 1 FROM tb_Bank_Transactions t WHERE t.BPA_EntryID = e.id);
IF @msg IS NOT NULL
BEGIN
    SET @msg = N'Not found in tb_Bank_Transactions: ' + @msg;
    THROW 50002, @msg, 1;
END

SET @msg = NULL;
SELECT @msg = ISNULL(@msg + N', ', N'') + CAST(t.BPA_EntryID AS nvarchar(36)) + N' (' + ISNULL(t.BPA_Origin, N'NULL') + N')'
FROM tb_Bank_Transactions t
WHERE t.BPA_EntryID IN (@VendorEntry, @JournalEntry)
  AND NOT EXISTS (SELECT 1 FROM vw_Bank_BankAccounts b WHERE b.Bankaccount = t.BPA_Origin);
IF @msg IS NOT NULL
    PRINT N'WARNING: BPA_Origin not in vw_Bank_BankAccounts (placeholder view, no default GL codes / journal): ' + @msg;

-- An empty invoice_number becomes LIKE '%%' in the function and matches every description
IF EXISTS (SELECT 1 FROM tb_Netsuite_Invoice WHERE invoice_number IS NOT NULL AND LTRIM(RTRIM(invoice_number)) = '')
    THROW 50004, N'tb_Netsuite_Invoice has rows with an empty invoice_number; they match every description. Clean those up first.', 1;

IF EXISTS (SELECT 1 FROM tb_Netsuite_Bank_account_details
           WHERE custrecord_2663_entity_iban = @DummyIBAN_Journal)
    THROW 50005, N'The dummy IBAN exists in tb_Netsuite_Bank_account_details; pick another one.', 1;

IF EXISTS (SELECT 1 FROM tb_Netsuite_Invoice i
           WHERE @JournalDescription LIKE '%' + LTRIM(RTRIM(i.invoice_number)) + '%')
    THROW 50006, N'@JournalDescription contains an invoice number; pick another description.', 1;

-- ---------- Scenario 1: vendor ----------
DECLARE @V_IBAN varchar(33), @V_VendorID nvarchar(50), @V_BillID nvarchar(50),
        @V_BillNo varchar(255), @V_Amount float, @V_Currency varchar(20);

SELECT TOP (1)
       @V_IBAN     = b.iban,
       @V_VendorID = v.vendor_id,
       @V_BillID   = v.vendor_bill_id,
       @V_BillNo   = LTRIM(RTRIM(v.vendor_bill_number)),
       @V_Amount   = v.amount_open,
       @V_Currency = v.currency_name
FROM tb_Netsuite_vendorBill v
JOIN (SELECT custrecord_2663_entity_iban AS iban, MAX(Vendorid) AS Vendorid
      FROM tb_Netsuite_Bank_account_details
      WHERE custrecord_2663_entity_iban IS NOT NULL
      GROUP BY custrecord_2663_entity_iban
      HAVING COUNT(DISTINCT Vendorid) = 1 AND COUNT(CustomerID) = 0) b
  ON CAST(b.Vendorid AS nvarchar(50)) = CAST(v.vendor_id AS nvarchar(50))
WHERE v.amount_open > 0
  AND v.currency_name IS NOT NULL
  AND LEN(v.vendor_id) <= 6                       -- function holds vendor_id in varchar(6)
  AND LEN(b.iban) <= 33                           -- function holds @IBAN in varchar(33)
  AND LTRIM(RTRIM(ISNULL(v.vendor_bill_number, ''))) <> ''
  -- the bill number must not hit an invoice (that would also set a customer)
  AND NOT EXISTS (SELECT 1 FROM tb_Netsuite_Invoice i
                  WHERE LTRIM(RTRIM(v.vendor_bill_number)) LIKE '%' + LTRIM(RTRIM(i.invoice_number)) + '%')
  -- and only this bill of the vendor may match the description
  AND (SELECT COUNT(*) FROM tb_Netsuite_vendorBill v2
       WHERE v2.vendor_id = v.vendor_id
         AND LTRIM(RTRIM(v.vendor_bill_number)) LIKE '%' + LTRIM(RTRIM(v2.vendor_bill_number)) + '%') = 1
ORDER BY v.vendor_bill_id;

IF @V_IBAN IS NULL
    THROW 50010, N'No usable vendor bill found: need an open bill with a bill number, whose vendor has an IBAN in tb_Netsuite_Bank_account_details that no other relation uses.', 1;

-- ---------- Backup + update ----------
BEGIN TRANSACTION;

IF OBJECT_ID(N'dbo.tb_Bank_Transactions_TestBackup') IS NULL
    SELECT * INTO dbo.tb_Bank_Transactions_TestBackup
    FROM tb_Bank_Transactions
    WHERE BPA_EntryID IN (@VendorEntry, @JournalEntry);
ELSE
    INSERT INTO dbo.tb_Bank_Transactions_TestBackup
    SELECT t.* FROM tb_Bank_Transactions t
    WHERE t.BPA_EntryID IN (@VendorEntry, @JournalEntry)
      AND NOT EXISTS (SELECT 1 FROM dbo.tb_Bank_Transactions_TestBackup b WHERE b.BPA_EntryID = t.BPA_EntryID);

UPDATE tb_Bank_Transactions
SET IBAN = @V_IBAN, Description = @V_BillNo, Amount = @V_Amount, Currency = @V_Currency,
    Kenmerk = NULL, Betalingskenmerk = NULL, Incassant = NULL, Machtiging = NULL
WHERE BPA_EntryID = @VendorEntry;

UPDATE tb_Bank_Transactions
SET IBAN = @DummyIBAN_Journal, Description = @JournalDescription, Amount = @JournalAmount, Currency = @JournalCurrency,
    Kenmerk = NULL, Betalingskenmerk = NULL, Incassant = NULL, Machtiging = NULL
WHERE BPA_EntryID = @JournalEntry;

COMMIT TRANSACTION;

-- ---------- What was set ----------
SELECT 1 AS Scenario, 'vendorPayment' AS Expected, @VendorEntry AS BPA_EntryID,
       @V_IBAN AS IBAN, @V_BillNo AS Description, @V_Amount AS Amount, @V_Currency AS Currency,
       N'vendor ' + @V_VendorID + N', vendor_bill_id ' + @V_BillID AS Source
UNION ALL
SELECT 3, 'journalEntry', @JournalEntry, @DummyIBAN_Journal, @JournalDescription, @JournalAmount, @JournalCurrency,
       N'no relation';

-- ---------- Run the function ----------
SELECT s.Scenario, s.Expected, x.Actual,
       CASE WHEN x.Actual = s.Expected THEN 'PASS' ELSE 'FAIL' END AS Result,
       r.*
FROM (VALUES (1, 'vendorPayment', @VendorEntry),
             (3, 'journalEntry',  @JournalEntry)) s(Scenario, Expected, BPA_EntryID)
OUTER APPLY (SELECT 1 AS has_row, f.*
             FROM dbo.fn_Bank_Match('BANK', s.BPA_EntryID, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) f) r
CROSS APPLY (SELECT CASE
                 WHEN r.has_row IS NULL THEN 'no result'
                 WHEN r.vendor_id IS NOT NULL AND r.Reference IS NOT NULL THEN 'vendorPayment'
                 WHEN r.customer_id IS NOT NULL AND (r.Reference IS NOT NULL OR r.ReferenceXML IS NOT NULL) THEN 'customerPayment'
                 WHEN r.vendor_id IS NULL AND r.customer_id IS NULL THEN 'journalEntry'
                 ELSE 'relation without reference'
             END AS Actual) x
ORDER BY s.Scenario;

/*
-- ---------- Restore the original rows ----------
UPDATE t
SET IBAN = b.IBAN, Description = b.Description, Amount = b.Amount, Currency = b.Currency,
    Kenmerk = b.Kenmerk, Betalingskenmerk = b.Betalingskenmerk, Incassant = b.Incassant, Machtiging = b.Machtiging
FROM tb_Bank_Transactions t
JOIN dbo.tb_Bank_Transactions_TestBackup b ON b.BPA_EntryID = t.BPA_EntryID;

DROP TABLE dbo.tb_Bank_Transactions_TestBackup;
*/
