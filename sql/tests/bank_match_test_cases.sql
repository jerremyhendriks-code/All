/*
    Step 2 of testing fn_Bank_Match against existing data (sandbox).

    Read-only: runs fn_Bank_Match for a fixed list of existing bank transactions
    and compares the outcome with what you expect. Pick the transactions with
    bank_match_find_candidates.sql (step 1) and fill in @cases below.

    Routing (from sp_Bank_Netsuite_FinancialEntry_Create):
      1. vendor_id + Reference filled                      -> VendorPayment
      2. customer_id + Reference (or ReferenceXML) filled  -> CustomerPayment
      3. everything else                                    -> JournalEntry

    exp_* = NULL means "expect NULL"; '*' means "don't check".

    Run this before sp_Bank_Netsuite_FinancialEntry_Create and before the next
    NetSuite sync: once a payment is booked the bill / invoice is no longer open
    (amount_open changes) and the SP sets BPA_Status = 1, so the expected
    outcome no longer holds.
*/
SET NOCOUNT ON;

DECLARE @cases TABLE (
    case_id       varchar(10) PRIMARY KEY,
    scenario      varchar(100),
    BPA_EntryID   uniqueidentifier,
    exp_route     varchar(20),
    exp_vendor    nvarchar(100),
    exp_customer  nvarchar(100),
    exp_reference nvarchar(100)
);

INSERT INTO @cases (case_id, scenario, BPA_EntryID, exp_route, exp_vendor, exp_customer, exp_reference)
VALUES
-- 1. Vendor bill + transaction: vendor_id (via IBAN) + vendor_bill_number in description
--    exp_reference = vendor_bill_id
  ('VP1', '<omschrijving>', '00000000-0000-0000-0000-000000000000', 'VendorPayment',   N'<vendor_id>', NULL, N'<vendor_bill_id>')

-- 2. Invoice + transaction: invoice_number in description or betalingskenmerk
--    exp_reference = invoice_number
, ('CP1', '<omschrijving>', '00000000-0000-0000-0000-000000000000', 'CustomerPayment', NULL, N'<customer_id>', N'<invoice_number>')

-- 3. Remaining entries
, ('JE1', '<omschrijving>', '00000000-0000-0000-0000-000000000000', 'JournalEntry',    NULL, NULL, NULL);

------------------------------------------------------------------------------
-- Preflight
------------------------------------------------------------------------------
DECLARE @def nvarchar(max) = REPLACE(REPLACE(REPLACE(LOWER(OBJECT_DEFINITION(OBJECT_ID(N'dbo.fn_Bank_Match'))),
                                     N' ', N''), CHAR(9), N''), N'--', N'#');
IF @def IS NULL
    THROW 50001, N'dbo.fn_Bank_Match not found.', 1;

-- Commented-out lines start with '#' after the replace above
IF @def LIKE N'%' + CHAR(10) + N'set@bpa_entryid=%'
OR @def LIKE N'%' + CHAR(10) + N'set@iban=''%'
OR @def LIKE N'%' + CHAR(10) + N'set@description=''%'
OR @def LIKE N'%' + CHAR(10) + N'set@amount=[0-9-]%'
    THROW 50002, N'fn_Bank_Match still overrides @BPA_EntryID / @IBAN / @Description / @Amount with hard-coded values. Remove or comment out those lines first.', 1;

DECLARE @list nvarchar(max) = STUFF((
    SELECT N', ' + c.case_id
    FROM @cases c
    WHERE NOT EXISTS (SELECT 1 FROM tb_Bank_Transactions t WHERE t.BPA_EntryID = c.BPA_EntryID AND t.BPA_Status = 0)
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
IF @list IS NOT NULL
    PRINT N'Warning: not found in tb_Bank_Transactions with BPA_Status = 0: ' + @list;

------------------------------------------------------------------------------
-- Run and report
------------------------------------------------------------------------------
;WITH r AS (
    SELECT c.*,
           t.Amount, t.Description,
           m.typematch, m.vendor_id, m.customer_id, m.Reference,
           CAST(m.ReferenceXML AS nvarchar(max)) AS ReferenceXML,
           RTRIM(m.GLCode) AS GLCode,
           CASE WHEN m.vendor_id IS NOT NULL AND m.Reference IS NOT NULL THEN 'VendorPayment'
                WHEN m.customer_id IS NOT NULL AND (m.Reference IS NOT NULL OR m.ReferenceXML IS NOT NULL) THEN 'CustomerPayment'
                ELSE 'JournalEntry' END AS act_route
    FROM @cases c
    LEFT JOIN tb_Bank_Transactions t ON t.BPA_EntryID = c.BPA_EntryID
    OUTER APPLY dbo.fn_Bank_Match('BANK', c.BPA_EntryID, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) m
),
d AS (
    SELECT r.*,
           CASE WHEN Amount IS NULL THEN N', transaction not found' ELSE N'' END
         + CASE WHEN act_route <> exp_route THEN N', route' ELSE N'' END
         + CASE WHEN ISNULL(exp_vendor, N'') <> N'*' AND ISNULL(vendor_id, N'<null>') <> ISNULL(exp_vendor, N'<null>') THEN N', vendor_id' ELSE N'' END
         + CASE WHEN ISNULL(exp_customer, N'') <> N'*' AND ISNULL(customer_id, N'<null>') <> ISNULL(exp_customer, N'<null>') THEN N', customer_id' ELSE N'' END
         + CASE WHEN ISNULL(exp_reference, N'') <> N'*' AND ISNULL(Reference, N'<null>') <> ISNULL(exp_reference, N'<null>') THEN N', Reference' ELSE N'' END
           AS diffs
    FROM r
)
SELECT CASE WHEN diffs = N'' THEN 'PASS' ELSE 'FAIL' END AS result,
       case_id, scenario, BPA_EntryID,
       STUFF(diffs, 1, 2, N'') AS differs_in,
       exp_route, act_route,
       exp_vendor, vendor_id,
       exp_customer, customer_id,
       exp_reference, Reference,
       typematch, GLCode, ReferenceXML,
       Amount, Description
FROM d
ORDER BY case_id;
