/*
    One-off repair for tb_Bank_Transactions rows copied before the fix in
    sp_Bank_Transaction_Rabobank_Copy: incoming payments got our own IBAN
    (and the wrong BIC / Customername) instead of the payer's.

    Step 1 shows what will change. Run step 2 only when that looks right.
*/
USE [BPAStaging]
GO

-- Step 1: preview
SELECT b.BPA_EntryID, b.Amount, b.Description,
       b.IBAN AS iban_now,         ISNULL(r.debtorAccount_iban, r.debtorAccount_bban) AS iban_new,
       b.Customername AS name_now, r.debtorName AS name_new,
       b.BIC AS bic_now,           r.debtorAgent AS bic_new
FROM tb_Bank_Transactions b
JOIN tb_Rabobank_Transaction r ON r.BPA_EntryID = b.BPA_Orig_Entryid
WHERE b.IBAN = b.BPA_Origin
  AND r.creditorAccount_iban = r.BPA_Origin
  AND ISNULL(r.debtorAccount_iban, r.debtorAccount_bban) IS NOT NULL;
GO

-- Step 2: repair
-- UPDATE b
-- SET b.IBAN         = ISNULL(r.debtorAccount_iban, r.debtorAccount_bban),
--     b.BIC          = r.debtorAgent,
--     b.Customername = r.debtorName
-- FROM tb_Bank_Transactions b
-- JOIN tb_Rabobank_Transaction r ON r.BPA_EntryID = b.BPA_Orig_Entryid
-- WHERE b.IBAN = b.BPA_Origin
--   AND r.creditorAccount_iban = r.BPA_Origin
--   AND ISNULL(r.debtorAccount_iban, r.debtorAccount_bban) IS NOT NULL;
