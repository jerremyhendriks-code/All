/*
    Stage ONE bank transaction in tb_Bank_Transactions: run fn_Bank_Match for it
    and store the result in its Matched_* columns.

    Nothing is written to the NetSuite tables and BPA_Status stays 0, so
    sp_Bank_Netsuite_FinancialEntry_Create can pick it up later.

    @OffsetAccountID is only used when the function finds no GL code
    (e.g. bank costs: no vendor, no customer).
*/
USE [BPAStaging]
GO

DECLARE @BankTransactionID uniqueidentifier = '7A8EE1D3-C1C3-F111-9386-00155D0A0313';  -- "Kosten", -39.32
DECLARE @OffsetAccountID   varchar(9)       = NULL;  -- NetSuite internal ID of e.g. the bank costs account

-- Step 1: what does the function say?
SELECT t.BPA_EntryID, t.Amount, t.Description, m.*
FROM tb_Bank_Transactions t
CROSS APPLY dbo.fn_Bank_Match('BANK', t.BPA_EntryID, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) m
WHERE t.BPA_EntryID = @BankTransactionID;

-- Step 2: store it on the bank transaction
UPDATE t
SET Matched_NewCustomer  = m.NewCustomer
,   Matched_typematch    = m.typematch
,   Matched_GLCode       = ISNULL(m.GLCode, @OffsetAccountID)
,   Matched_Creditor     = m.vendor_id
,   Matched_Debtor       = m.customer_id
,   Matched_Costcenter   = m.Costcenter
,   Matched_CostUnit     = m.CostUnit
,   Matched_Reference    = m.Reference
,   Matched_VatCode      = m.VatCode
,   Matched_ReferenceXML = m.ReferenceXML
FROM tb_Bank_Transactions t
CROSS APPLY dbo.fn_Bank_Match('BANK', t.BPA_EntryID, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) m
WHERE t.BPA_EntryID = @BankTransactionID
  AND t.BPA_Status = 0;

-- Step 3: check, with the category sp_Bank_Netsuite_FinancialEntry_Create will give it
SELECT t.BPA_EntryID, t.BPA_Status, t.Amount, t.Description,
       t.Matched_typematch, t.Matched_GLCode, t.Matched_Creditor, t.Matched_Debtor, t.Matched_Reference,
       CASE
           WHEN t.Matched_Creditor IS NOT NULL AND t.Matched_Reference IS NOT NULL AND t.Amount < 0 THEN 'VENDORPAYMENT'
           WHEN t.Matched_Debtor IS NOT NULL AND t.Amount > 0
                AND (t.Matched_Reference IS NOT NULL OR t.Matched_ReferenceXML IS NOT NULL)          THEN 'CUSTOMERPAYMENT'
           ELSE 'JOURNALENTRY'
       END AS will_become
FROM tb_Bank_Transactions t
WHERE t.BPA_EntryID = @BankTransactionID;
GO
