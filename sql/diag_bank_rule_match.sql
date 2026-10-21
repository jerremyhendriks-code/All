/*
    Diagnose: why does a bank transaction not get typematch MATCH from a workflow rule?
    Fill in @EntryID and run the whole script; each result set answers one question.
*/
USE [BPAStaging]
GO

DECLARE @EntryID uniqueidentifier = '94E4F39C-F7C6-F111-9386-00155D0A0313';

-- 1. Is the new fn_Bank_Match_V2 installed (with the workflow blocks)?
SELECT
	fn_Bank_Match_V2     = CASE WHEN OBJECT_DEFINITION(OBJECT_ID('dbo.fn_Bank_Match_V2')) LIKE '%fn_Bank_Match_Rules%' THEN 'new' ELSE 'OLD: install fn_Bank_Match_V2.sql' END
,	fn_Bank_Match_Rules  = CASE WHEN OBJECT_ID('dbo.fn_Bank_Match_Rules') IS NOT NULL THEN 'exists' ELSE 'MISSING' END
,	modified             = (SELECT modify_date FROM sys.objects WHERE object_id = OBJECT_ID('dbo.fn_Bank_Match_V2'));

-- 2. What the engine reads for this transaction (Company comes from vw_Bank_BankAccounts, not from BPA_Company)
SELECT
	t.BPA_Origin, t.BPA_Company, b.Company AS Company_from_BankAccounts,
	t.IBAN, t.Amount, t.Currency, t.Description, t.Kenmerk, t.Betalingskenmerk,
	t.Machtiging, t.Incassant, t.Mutationcode, t.BPA_Status
FROM dbo.tb_Bank_Transactions t
LEFT JOIN dbo.vw_Bank_BankAccounts b ON b.Bankaccount = t.BPA_Origin COLLATE DATABASE_DEFAULT
WHERE t.BPA_EntryID = @EntryID;

-- 3. Every approved rule against this transaction, one column per condition (0 = this condition blocks)
SELECT
	m.WorkflowNumber, m.Company, m.BankAccount, m.PaymentDirection, m.Description, m.GLcode, m.CredDebCode,
	ok_Company     = CASE WHEN m.Company = b.Company THEN 1 ELSE 0 END,
	ok_BankAccount = CASE WHEN m.BankAccount = UPPER(REPLACE(t.BPA_Origin, ' ', '')) THEN 1 ELSE 0 END,
	ok_RelIBAN     = CASE WHEN m.BankaccountRelation IS NULL OR m.BankaccountRelation = UPPER(REPLACE(t.IBAN, ' ', '')) THEN 1 ELSE 0 END,
	ok_Description = CASE WHEN m.Description IS NULL OR t.Description LIKE '%' + m.Description + '%' THEN 1 ELSE 0 END,
	ok_Direction   = CASE WHEN ISNULL(m.PaymentDirection, 'A') = 'A'
	                        OR (m.PaymentDirection = 'P' AND t.Amount > 0)
	                        OR (m.PaymentDirection = 'N' AND t.Amount < 0) THEN 1 ELSE 0 END,
	ok_Amount      = CASE WHEN m.Amount IS NULL THEN 1 ELSE NULL END,	-- NULL: rule has an amount, see fn_Bank_Match_Rules
	ok_Mutation    = CASE WHEN m.MutationCode IS NULL OR m.MutationCode = t.Mutationcode THEN 1 ELSE 0 END,
	ok_GLcode      = CASE WHEN m.GLcode IS NOT NULL THEN 1 ELSE 0 END,
	ok_NotCredDeb  = CASE WHEN ISNULL(m.CredDebCode, '') NOT IN ('C', 'D') THEN 1 ELSE 0 END
FROM dbo.tb_Bank_Transactions t
LEFT JOIN dbo.vw_Bank_BankAccounts b ON b.Bankaccount = t.BPA_Origin COLLATE DATABASE_DEFAULT
CROSS JOIN dbo.vw_Bank_Matching m
WHERE t.BPA_EntryID = @EntryID;

-- 4. The rules fn_Bank_Match_Rules returns for this transaction
SELECT r.WorkflowNumber, r.GLcode, r.CredDebCode, r.Specificity
FROM dbo.tb_Bank_Transactions t
LEFT JOIN dbo.vw_Bank_BankAccounts b ON b.Bankaccount = t.BPA_Origin COLLATE DATABASE_DEFAULT
CROSS APPLY dbo.fn_Bank_Match_Rules(b.Company, t.BPA_Origin, t.IBAN, t.Amount, t.Description, t.Kenmerk,
                                    t.Betalingskenmerk, t.Machtiging, t.Incassant, t.Mutationcode) r
WHERE t.BPA_EntryID = @EntryID;

-- 5. What fn_Bank_Match_V2 makes of it
SELECT *
FROM dbo.fn_Bank_Match_V2('BANK', @EntryID, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
GO
