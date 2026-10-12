/*
    Step 1 of testing fn_Bank_Match against existing data (sandbox).

    Read-only: nothing is inserted or updated. Finds existing bank transactions
    (BPA_Status = 0) that are good candidates for each of the three scenarios:

      1. VendorPayment   - IBAN belongs to exactly one vendor and the description
                           contains a vendor_bill_number of that vendor
      2. CustomerPayment - description or betalingskenmerk contains an invoice_number
      3. JournalEntry    - IBAN unknown and no bill / invoice number found

    For each candidate it also shows what fn_Bank_Match returns today, so you can
    see straight away whether the engine agrees. Pick the transactions you want
    to use and put them in bank_match_test_cases.sql (step 2).

    amount_open is read with TRY_CAST because the NetSuite tables store it as text.

    Requires the hard-coded debug lines (set @BPA_EntryID=..., set @IBAN=...,
    set @Description=..., set @Amount=...) to be removed from fn_Bank_Match:
    with them in place every transaction returns the same result.
*/
SET NOCOUNT ON;

DECLARE @Company varchar(50) = NULL;   -- e.g. '501'; NULL = all companies
DECLARE @Top     int         = 50;     -- rows per scenario

------------------------------------------------------------------------------
-- 1. VendorPayment candidates
------------------------------------------------------------------------------
;WITH vendor_iban AS (
    -- Same rule as the engine: the IBAN must point to exactly one vendor
    SELECT custrecord_2663_entity_iban AS iban, MAX(Vendorid) AS vendor_id
    FROM tb_Netsuite_Bank_account_details
    WHERE Vendorid IS NOT NULL
    GROUP BY custrecord_2663_entity_iban
    HAVING COUNT(DISTINCT Vendorid) = 1
)
SELECT TOP (@Top)
       'VendorPayment' AS scenario,
       t.BPA_EntryID, t.BPA_Company, t.Bookdate, t.IBAN, t.Amount, t.Currency, t.Description,
       v.vendor_id, v.vendor_bill_id, v.vendor_bill_number, TRY_CAST(v.amount_open AS decimal(18,2)) AS amount_open, v.currency_name,
       CASE WHEN t.Amount = TRY_CAST(v.amount_open AS decimal(18,2))  THEN 'exact'
            WHEN -t.Amount = TRY_CAST(v.amount_open AS decimal(18,2)) THEN 'exact, sign flipped'
            ELSE 'differs' END AS amount_check,
       m.typematch, m.vendor_id AS engine_vendor_id, m.customer_id AS engine_customer_id,
       m.Reference AS engine_reference, RTRIM(m.GLCode) AS engine_glcode
FROM tb_Bank_Transactions t
JOIN vendor_iban b ON b.iban = t.IBAN
JOIN tb_Netsuite_VendorBill v ON v.vendor_id = b.vendor_id
                             AND LTRIM(RTRIM(v.vendor_bill_number)) <> ''
                             AND t.Description LIKE '%' + LTRIM(RTRIM(v.vendor_bill_number)) + '%'
CROSS APPLY dbo.fn_Bank_Match('BANK', t.BPA_EntryID, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) m
WHERE t.BPA_Status = 0
  AND (@Company IS NULL OR t.BPA_Company = @Company)
ORDER BY CASE WHEN t.Amount = TRY_CAST(v.amount_open AS decimal(18,2)) OR -t.Amount = TRY_CAST(v.amount_open AS decimal(18,2)) THEN 0 ELSE 1 END, t.Bookdate DESC;

------------------------------------------------------------------------------
-- 2. CustomerPayment candidates
------------------------------------------------------------------------------
SELECT TOP (@Top)
       'CustomerPayment' AS scenario,
       t.BPA_EntryID, t.BPA_Company, t.Bookdate, t.IBAN, t.Amount, t.Currency, t.Description, t.Betalingskenmerk,
       i.customer_id, i.invoice_number, TRY_CAST(i.amount_open AS decimal(18,2)) AS amount_open, i.currency_name,
       CASE WHEN t.Description LIKE '%' + LTRIM(RTRIM(i.invoice_number)) + '%' THEN 'description'
            ELSE 'betalingskenmerk' END AS found_in,
       COUNT(*) OVER (PARTITION BY t.BPA_EntryID) AS invoices_found,
       CASE WHEN t.Amount = TRY_CAST(i.amount_open AS decimal(18,2)) THEN 'exact' ELSE 'differs' END AS amount_check,
       m.typematch, m.vendor_id AS engine_vendor_id, m.customer_id AS engine_customer_id,
       m.Reference AS engine_reference, CAST(m.ReferenceXML AS nvarchar(max)) AS engine_reference_xml,
       RTRIM(m.GLCode) AS engine_glcode
FROM tb_Bank_Transactions t
JOIN tb_Netsuite_Invoice i ON LTRIM(RTRIM(i.invoice_number)) <> ''
                          AND (   t.Description      LIKE '%' + LTRIM(RTRIM(i.invoice_number)) + '%'
                               OR t.Betalingskenmerk LIKE '%' + LTRIM(RTRIM(i.invoice_number)) + '%')
CROSS APPLY dbo.fn_Bank_Match('BANK', t.BPA_EntryID, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) m
WHERE t.BPA_Status = 0
  AND (@Company IS NULL OR t.BPA_Company = @Company)
ORDER BY CASE WHEN t.Amount = TRY_CAST(i.amount_open AS decimal(18,2)) THEN 0 ELSE 1 END, invoices_found, t.Bookdate DESC;

------------------------------------------------------------------------------
-- 3. JournalEntry candidates: unknown IBAN, no bill or invoice number
------------------------------------------------------------------------------
SELECT TOP (@Top)
       'JournalEntry' AS scenario,
       t.BPA_EntryID, t.BPA_Company, t.Bookdate, t.IBAN, t.Amount, t.Currency, t.Description, t.Betalingskenmerk,
       m.typematch, m.vendor_id AS engine_vendor_id, m.customer_id AS engine_customer_id,
       m.Reference AS engine_reference, RTRIM(m.GLCode) AS engine_glcode
FROM tb_Bank_Transactions t
CROSS APPLY dbo.fn_Bank_Match('BANK', t.BPA_EntryID, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) m
WHERE t.BPA_Status = 0
  AND (@Company IS NULL OR t.BPA_Company = @Company)
  AND NOT EXISTS (SELECT 1 FROM tb_Netsuite_Bank_account_details b WHERE b.custrecord_2663_entity_iban = t.IBAN)
  AND NOT EXISTS (SELECT 1 FROM tb_Netsuite_VendorBill v
                  WHERE LTRIM(RTRIM(v.vendor_bill_number)) <> ''
                    AND t.Description LIKE '%' + LTRIM(RTRIM(v.vendor_bill_number)) + '%')
  AND NOT EXISTS (SELECT 1 FROM tb_Netsuite_Invoice i
                  WHERE LTRIM(RTRIM(i.invoice_number)) <> ''
                    AND (   t.Description      LIKE '%' + LTRIM(RTRIM(i.invoice_number)) + '%'
                         OR t.Betalingskenmerk LIKE '%' + LTRIM(RTRIM(i.invoice_number)) + '%'))
ORDER BY t.Bookdate DESC;
