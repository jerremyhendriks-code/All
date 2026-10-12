/*
    Test cases for dbo.fn_Bank_Match and the routing in sp_Bank_Netsuite_FinancialEntry_Create.

    Routing (from the SP):
      1. vendor_id + Reference filled                      -> VendorPayment
      2. customer_id + Reference (or ReferenceXML) filled  -> CustomerPayment
      3. everything else                                    -> JournalEntry

    How it works:
    - Seeds test vendors, vendor bills, invoices, IBANs and bank transactions,
      runs fn_Bank_Match for each test transaction, then ROLLS BACK. Nothing stays behind.
    - Results are kept in a table variable (survives the rollback) and reported
      as PASS / FAIL per case, with the fields that differ.
    - All test data uses ids 9900xx / 9990xxxx, IBANs NL00TEST099xxxxxxx and
      numbers TSTVB9xxx / TSTINV9xxx. The script stops before seeding if any of
      these already exist, or if a real invoice number appears in a test
      description (the engine matches invoice numbers with LIKE '%nr%').
    - The SP itself is not executed: it updates every BPA_Status = 0 row of a company.

    Before running:
    - Set @TestBankAccount to a bank account that exists in vw_Bank_BankAccounts.
    - Remove the debug lines from fn_Bank_Match (set @BPA_EntryID=..., set @IBAN=...,
      set @Description=..., set @Amount=...). The script refuses to run while they're there.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

DECLARE @TestBankAccount varchar(50) = '<<vul hier een BPA_Origin / Bankaccount in>>';
DECLARE @TestCompany     varchar(50) = '501';

DECLARE @msg nvarchar(2048), @list nvarchar(max);

------------------------------------------------------------------------------
-- Preflight 1: fn_Bank_Match must not contain hard-coded debug values
------------------------------------------------------------------------------
DECLARE @def nvarchar(max) = REPLACE(REPLACE(REPLACE(LOWER(OBJECT_DEFINITION(OBJECT_ID(N'dbo.fn_Bank_Match'))),
                                     N' ', N''), CHAR(9), N''), N'--', N'#');
IF @def IS NULL
    THROW 50001, N'dbo.fn_Bank_Match not found.', 1;

-- Lines that are commented out start with '#' after the replace above
IF @def LIKE N'%' + CHAR(10) + N'set@bpa_entryid=%'
OR @def LIKE N'%' + CHAR(10) + N'set@iban=''%'
OR @def LIKE N'%' + CHAR(10) + N'set@description=''%'
OR @def LIKE N'%' + CHAR(10) + N'set@amount=[0-9-]%'
    THROW 50002, N'fn_Bank_Match still overrides @BPA_EntryID / @IBAN / @Description / @Amount with hard-coded values. Remove or comment out those lines first.', 1;

------------------------------------------------------------------------------
-- Preflight 2: bank account defaults (used for the expected GL codes)
------------------------------------------------------------------------------
DECLARE @CompanyID uniqueidentifier, @Journal nvarchar(20),
        @GLCreditor nvarchar(9), @GLDebtor nvarchar(9), @GLJournal nvarchar(9);

SELECT @CompanyID  = CompanyID,
       @Journal    = Journal,
       @GLCreditor = RTRIM(DefaultGLCodeCreditor),
       @GLDebtor   = RTRIM(DefaultGLCodeDebtor)
FROM vw_Bank_BankAccounts
WHERE Bankaccount = @TestBankAccount;

IF @Journal IS NULL
BEGIN
    SET @msg = N'Bank account ' + @TestBankAccount + N' not found in vw_Bank_BankAccounts. Set @TestBankAccount.';
    THROW 50003, @msg, 1;
END

SELECT @GLJournal = RTRIM(glcode) FROM vw_Bank_Journal WHERE CompanyID = @CompanyID AND Journal = @Journal;

------------------------------------------------------------------------------
-- Test data
------------------------------------------------------------------------------
DECLARE @vendors TABLE (vendor_id nvarchar(6), iban varchar(34));
INSERT INTO @vendors VALUES
    (N'990001', 'NL00TEST0990000001'),   -- vendor with open bills
    (N'990002', 'NL00TEST0990000002');   -- vendor without bills

DECLARE @customers TABLE (customer_id nvarchar(6), iban varchar(34));
INSERT INTO @customers VALUES
    (N'990101', 'NL00TEST0990000101');

DECLARE @bills TABLE (vendor_bill_id nvarchar(20), vendor_id nvarchar(6), vendor_bill_number nvarchar(20), amount_open decimal(18,2));
INSERT INTO @bills VALUES
    (N'99900101', N'990001', N'TSTVB9001', 1250.50),
    (N'99900102', N'990001', N'TSTVB9002',  777.25);

DECLARE @invoices TABLE (customer_id nvarchar(6), invoice_number nvarchar(20), amount_open decimal(18,2), due_date date);
INSERT INTO @invoices VALUES
    (N'990101', N'TSTINV9001', 500.00, '2026-10-01'),
    (N'990101', N'TSTINV9002', 320.75, '2026-10-05');

-- One row per test transaction with the expected engine output.
-- exp_* = NULL means "expect NULL"; '*' means "don't check".
-- exp_gl: CRED / DEB / JOURNAL = default GL of the test bank account.
DECLARE @cases TABLE (
    case_id          varchar(10) PRIMARY KEY,
    scenario         varchar(60),
    entry_id         uniqueidentifier DEFAULT NEWID(),
    iban             varchar(34),
    amount           decimal(18,2),
    description      varchar(255),
    betalingskenmerk varchar(255),
    exp_route        varchar(20),
    exp_typematch    nvarchar(50),
    exp_vendor       nvarchar(6),
    exp_customer     nvarchar(6),
    exp_reference    nvarchar(20),
    exp_xml          nvarchar(max),
    exp_gl           varchar(10)
);

INSERT INTO @cases (case_id, scenario, iban, amount, description, betalingskenmerk,
                    exp_route, exp_typematch, exp_vendor, exp_customer, exp_reference, exp_xml, exp_gl)
VALUES
-- 1. Vendor bill + transaction (vendor_id via IBAN + vendor_bill_number in description)
  ('VP1', 'Vendor IBAN + bill number, exact amount',
          'NL00TEST0990000001',  1250.50, 'Betaling factuur TSTVB9001', NULL,
          'VendorPayment', N'PurchaseInvoice', N'990001', NULL, N'99900101', NULL, 'CRED')
, ('VP2', 'Same as VP1, outgoing amount stored negative',
          'NL00TEST0990000001', -1250.50, 'Betaling factuur TSTVB9001', NULL,
          'VendorPayment', N'PurchaseInvoice', N'990001', NULL, N'99900101', NULL, 'CRED')
, ('VP3', 'Vendor IBAN, no bill number, one open bill with this amount',
          'NL00TEST0990000001',   777.25, 'Betaling oktober', NULL,
          'VendorPayment', N'PurchaseInvoiceAmount', N'990001', NULL, N'99900102', NULL, 'CRED')
, ('VP4', 'Vendor IBAN + bill number, partial amount',
          'NL00TEST0990000001',  1000.00, 'Betaling factuur TSTVB9001', NULL,
          'JournalEntry', N'PurchaseInvoice', N'990001', NULL, NULL, NULL, 'CRED')
, ('VP5', 'Bill number of vendor 990001 paid from IBAN of vendor 990002',
          'NL00TEST0990000002',  1250.50, 'Betaling factuur TSTVB9001', NULL,
          'JournalEntry', N'IBAN', N'990002', NULL, NULL, NULL, 'JOURNAL')

-- 2. Invoice + transaction (invoice_number in description or betalingskenmerk)
, ('CP1', 'Unknown IBAN, invoice number in description, exact amount',
          'NL00TEST0990000999',   500.00, 'Factuur TSTINV9001', NULL,
          'CustomerPayment', N'SalesInvoice', NULL, N'990101', N'TSTINV9001', NULL, 'DEB')
, ('CP2', 'Unknown IBAN, invoice number in betalingskenmerk',
          'NL00TEST0990000999',   320.75, 'Betaling', 'TSTINV9002',
          'CustomerPayment', N'SalesInvoice', NULL, N'990101', N'TSTINV9002', NULL, 'DEB')
, ('CP3', 'Customer IBAN + invoice number in description',
          'NL00TEST0990000101',   500.00, 'Factuur TSTINV9001', NULL,
          'CustomerPayment', N'SalesInvoice', NULL, N'990101', N'TSTINV9001', NULL, 'DEB')
, ('CP4', 'Two invoice numbers in description, amount = sum',
          'NL00TEST0990000999',   820.75, 'Facturen TSTINV9001 TSTINV9002', NULL,
          'CustomerPayment', N'SalesinvoiceListDescription', NULL, N'990101', NULL,
          N'<Invoices><invoice_number>TSTINV9001</invoice_number><invoice_number>TSTINV9002</invoice_number></Invoices>', 'DEB')
, ('CP5', 'Invoice number in description, partial amount',
          'NL00TEST0990000999',   450.00, 'Factuur TSTINV9001', NULL,
          'JournalEntry', N'SalesInvoice', NULL, N'990101', NULL, NULL, 'DEB')

-- 3. Remaining entries
, ('JE1', 'Unknown IBAN, no reference',
          'NL00TEST0990000999',   -12.50, 'Bankkosten oktober', NULL,
          'JournalEntry', NULL, NULL, NULL, NULL, NULL, 'JOURNAL');

------------------------------------------------------------------------------
-- Preflight 3: required columns and collisions with existing data
------------------------------------------------------------------------------
DECLARE @filled TABLE (tbl sysname, col sysname);
INSERT INTO @filled VALUES
    (N'tb_Netsuite_Bank_account_details', N'Vendorid'),
    (N'tb_Netsuite_Bank_account_details', N'CustomerID'),
    (N'tb_Netsuite_Bank_account_details', N'custrecord_2663_entity_iban'),
    (N'tb_Netsuite_VendorBill', N'id'),
    (N'tb_Netsuite_VendorBill', N'vendor_bill_id'),
    (N'tb_Netsuite_VendorBill', N'vendor_id'),
    (N'tb_Netsuite_VendorBill', N'vendor_bill_number'),
    (N'tb_Netsuite_VendorBill', N'amount_open'),
    (N'tb_Netsuite_VendorBill', N'currency_name'),
    (N'tb_Netsuite_Invoice', N'customer_id'),
    (N'tb_Netsuite_Invoice', N'invoice_number'),
    (N'tb_Netsuite_Invoice', N'amount_open'),
    (N'tb_Netsuite_Invoice', N'currency_name'),
    (N'tb_Netsuite_Invoice', N'due_date'),
    (N'tb_Bank_Transactions', N'BPA_EntryID'),
    (N'tb_Bank_Transactions', N'BPA_Origin'),
    (N'tb_Bank_Transactions', N'BPA_Company'),
    (N'tb_Bank_Transactions', N'BPA_Status'),
    (N'tb_Bank_Transactions', N'Bookdate'),
    (N'tb_Bank_Transactions', N'IBAN'),
    (N'tb_Bank_Transactions', N'Customername'),
    (N'tb_Bank_Transactions', N'Amount'),
    (N'tb_Bank_Transactions', N'Currency'),
    (N'tb_Bank_Transactions', N'Description'),
    (N'tb_Bank_Transactions', N'Betalingskenmerk');

SET @list = STUFF((
    SELECT N', ' + t.name + N'.' + c.name
    FROM sys.tables t
    JOIN sys.columns c ON c.object_id = t.object_id
    WHERE t.schema_id = SCHEMA_ID(N'dbo')
      AND t.name IN (SELECT tbl FROM @filled)
      AND c.is_nullable = 0 AND c.default_object_id = 0
      AND c.is_identity = 0 AND c.is_computed = 0 AND c.system_type_id <> 189  -- rowversion
      AND NOT EXISTS (SELECT 1 FROM @filled f WHERE f.tbl = t.name AND f.col = c.name)
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
IF @list IS NOT NULL
BEGIN
    SET @msg = N'NOT NULL columns without default that this script does not fill: ' + @list
             + N'. Add them to @filled and to the INSERTs below.';
    THROW 50004, @msg, 1;
END

SET @list = STUFF((
    SELECT N'; ' + x.what
    FROM (
        SELECT N'IBAN ' + b.custrecord_2663_entity_iban + N' in tb_Netsuite_Bank_account_details' AS what
        FROM tb_Netsuite_Bank_account_details b
        WHERE b.custrecord_2663_entity_iban IN (SELECT iban FROM @vendors UNION SELECT iban FROM @customers
                                                UNION SELECT iban FROM @cases)
        UNION
        SELECT N'vendor ' + CAST(v.vendor_id AS nvarchar(100)) + N' / bill ' + CAST(v.vendor_bill_id AS nvarchar(100))
             + N' in tb_Netsuite_VendorBill'
        FROM tb_Netsuite_VendorBill v
        WHERE v.vendor_id IN (SELECT vendor_id FROM @vendors)
           OR v.vendor_bill_id IN (SELECT vendor_bill_id FROM @bills)
           OR v.vendor_bill_number IN (SELECT vendor_bill_number FROM @bills)
        UNION
        SELECT N'invoice ' + i.invoice_number + N' (customer ' + CAST(i.customer_id AS nvarchar(100))
             + N') matches test case ' + c.case_id
        FROM tb_Netsuite_Invoice i
        JOIN @cases c ON c.description LIKE N'%' + LTRIM(RTRIM(i.invoice_number)) + N'%'
                      OR c.betalingskenmerk LIKE N'%' + LTRIM(RTRIM(i.invoice_number)) + N'%'
        UNION
        SELECT N'customer ' + CAST(i.customer_id AS nvarchar(100)) + N' in tb_Netsuite_Invoice'
        FROM tb_Netsuite_Invoice i
        WHERE i.customer_id IN (SELECT customer_id FROM @customers)
        UNION
        SELECT N'BPA_EntryID ' + CAST(t.BPA_EntryID AS nvarchar(36)) + N' in tb_Bank_Transactions'
        FROM tb_Bank_Transactions t
        WHERE t.BPA_EntryID IN (SELECT entry_id FROM @cases)
    ) x
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
IF @list IS NOT NULL
BEGIN
    SET @msg = LEFT(N'Test data collides with existing data: ' + @list, 2048);
    THROW 50005, @msg, 1;
END

------------------------------------------------------------------------------
-- Seed, run the engine, roll back
------------------------------------------------------------------------------
DECLARE @results TABLE (
    case_id     varchar(10),
    GLCode      nvarchar(9),
    vendor_id   nvarchar(6),
    customer_id nvarchar(6),
    Reference   nvarchar(20),
    typematch   nvarchar(50),
    NewCustomer int,
    ReferenceXML nvarchar(max)
);

BEGIN TRANSACTION;

INSERT INTO tb_Netsuite_Bank_account_details (Vendorid, CustomerID, custrecord_2663_entity_iban)
SELECT vendor_id, CAST(NULL AS nvarchar(6)), iban FROM @vendors
UNION ALL
SELECT CAST(NULL AS nvarchar(6)), customer_id, iban FROM @customers;

INSERT INTO tb_Netsuite_VendorBill (id, vendor_bill_id, vendor_id, vendor_bill_number, amount_open, currency_name)
SELECT vendor_bill_id, vendor_bill_id, vendor_id, vendor_bill_number, amount_open, 'EUR' FROM @bills;

INSERT INTO tb_Netsuite_Invoice (customer_id, invoice_number, amount_open, currency_name, due_date)
SELECT customer_id, invoice_number, amount_open, 'EUR', due_date FROM @invoices;

INSERT INTO tb_Bank_Transactions (BPA_EntryID, BPA_Origin, BPA_Company, BPA_Status, Bookdate,
                                  IBAN, Customername, Amount, Currency, Description, Betalingskenmerk)
SELECT entry_id, @TestBankAccount, @TestCompany, 0, CAST(GETDATE() AS date),
       iban, 'TEST ' + case_id, amount, 'EUR', description, betalingskenmerk
FROM @cases;

INSERT INTO @results
SELECT c.case_id, RTRIM(m.GLCode), m.vendor_id, m.customer_id, m.Reference, m.typematch, m.NewCustomer,
       CAST(m.ReferenceXML AS nvarchar(max))
FROM @cases c
CROSS APPLY dbo.fn_Bank_Match('BANK', c.entry_id, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) m;

ROLLBACK TRANSACTION;

------------------------------------------------------------------------------
-- Report
------------------------------------------------------------------------------
;WITH r AS (
    SELECT c.case_id, c.scenario,
           CASE WHEN x.vendor_id IS NOT NULL AND x.Reference IS NOT NULL THEN 'VendorPayment'
                WHEN x.customer_id IS NOT NULL AND (x.Reference IS NOT NULL OR x.ReferenceXML IS NOT NULL) THEN 'CustomerPayment'
                ELSE 'JournalEntry' END AS act_route,
           c.exp_route,
           x.typematch, c.exp_typematch,
           x.vendor_id, c.exp_vendor,
           x.customer_id, c.exp_customer,
           x.Reference, c.exp_reference,
           x.ReferenceXML, c.exp_xml,
           x.GLCode,
           CASE c.exp_gl WHEN 'CRED' THEN @GLCreditor WHEN 'DEB' THEN @GLDebtor
                         WHEN 'JOURNAL' THEN @GLJournal ELSE c.exp_gl END AS exp_glcode,
           x.NewCustomer
    FROM @cases c
    LEFT JOIN @results x ON x.case_id = c.case_id
),
d AS (
    SELECT r.*,
                 CASE WHEN act_route <> exp_route THEN N', route' ELSE N'' END
               + CASE WHEN ISNULL(exp_typematch, N'') <> N'*' AND ISNULL(typematch, N'<null>') <> ISNULL(exp_typematch, N'<null>') THEN N', typematch' ELSE N'' END
               + CASE WHEN ISNULL(exp_vendor, N'') <> N'*' AND ISNULL(vendor_id, N'<null>') <> ISNULL(exp_vendor, N'<null>') THEN N', vendor_id' ELSE N'' END
               + CASE WHEN ISNULL(exp_customer, N'') <> N'*' AND ISNULL(customer_id, N'<null>') <> ISNULL(exp_customer, N'<null>') THEN N', customer_id' ELSE N'' END
               + CASE WHEN ISNULL(exp_reference, N'') <> N'*' AND ISNULL(Reference, N'<null>') <> ISNULL(exp_reference, N'<null>') THEN N', Reference' ELSE N'' END
               + CASE WHEN ISNULL(exp_xml, N'') <> N'*' AND ISNULL(ReferenceXML, N'<null>') <> ISNULL(exp_xml, N'<null>') THEN N', ReferenceXML' ELSE N'' END
               + CASE WHEN ISNULL(exp_glcode, N'') <> N'*' AND ISNULL(GLCode, N'<null>') <> ISNULL(exp_glcode, N'<null>') THEN N', GLCode' ELSE N'' END AS diffs
    FROM r
)
SELECT CASE WHEN diffs = N'' THEN 'PASS' ELSE 'FAIL' END AS result,
       case_id, scenario,
       STUFF(diffs, 1, 2, N'') AS differs_in,
       exp_route, act_route,
       exp_typematch, typematch,
       exp_vendor, vendor_id,
       exp_customer, customer_id,
       exp_reference, Reference,
       exp_glcode, GLCode,
       exp_xml, ReferenceXML,
       NewCustomer
FROM d
ORDER BY case_id;
