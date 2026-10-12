/*
    vw_Bank_BankAccounts: our own bank accounts and their booking settings.

    The view used to be a placeholder that always returned one row with
    Bankaccount = NULL, so fn_Bank_Match never found any default GL codes.

    Now:
    - The accounts come from tb_Bank_Bankaccounts (the accounts we pick up
      transactions for; IBAN = BPA_Origin in tb_Bank_Transactions).
    - The booking settings (journal, company, GL codes) come from a new table
      tb_Bank_Bankaccount_Settings, one row per IBAN. tb_Bank_Bankaccounts itself
      is not changed, so whatever fills it keeps working.

    Columns, names and order of the view are the same as before, so callers keep working.
    Safe to run more than once.
*/
USE [BPAStaging]
GO

IF OBJECT_ID(N'dbo.tb_Bank_Bankaccount_Settings', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.tb_Bank_Bankaccount_Settings
    (
        IBAN                    varchar(34)      NOT NULL PRIMARY KEY,  -- = tb_Bank_Bankaccounts.IBAN
        Journal                 nvarchar(20)     NULL,
        CompanyID               uniqueidentifier NULL,
        Company                 nvarchar(50)     NULL,                  -- NetSuite subsidiary
        DefaultGLCodeDebtor     nvarchar(9)      NULL,                  -- accounts receivable GL account
        DefaultGLCodeCreditor   nvarchar(9)      NULL,                  -- accounts payable GL account
        UnknownDebtor           nvarchar(100)    NULL,
        DiversDebtor            nvarchar(100)    NULL,
        UnknownCreditor         nvarchar(100)    NULL,
        DiversCreditor          nvarchar(100)    NULL,
        Incasso_PaymentMethod   nvarchar(100)    NULL,
        Incasso_Bedrijfsnaam    nvarchar(100)    NULL,
        Incasso_BIC             nvarchar(20)     NULL,
        Incasso_IncassantID     nvarchar(100)    NULL,
        Incasso_Batchbooking    bit              NULL,
        GLCodeBank              nvarchar(9)      NULL
    );
END
GO

-- One settings row for every account that doesn't have one yet
INSERT INTO dbo.tb_Bank_Bankaccount_Settings (IBAN, Journal, Company)
SELECT DISTINCT a.IBAN, 'JOURNAL', 'TEST'
FROM dbo.tb_Bank_Bankaccounts a
WHERE a.IBAN IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM dbo.tb_Bank_Bankaccount_Settings s WHERE s.IBAN = a.IBAN);
GO

-- Fill in the booking settings per account (values come from the NetSuite setup):
-- UPDATE dbo.tb_Bank_Bankaccount_Settings
-- SET Journal               = '<journal>',
--     Company               = '<NetSuite subsidiary>',
--     DefaultGLCodeDebtor   = '<AR GL account>',
--     DefaultGLCodeCreditor = '<AP GL account>',
--     GLCodeBank            = '<bank GL account>'
-- WHERE IBAN = 'NL74RABO0317955799';

ALTER VIEW [dbo].[vw_Bank_BankAccounts] AS
SELECT
    CAST(NULL AS uniqueidentifier) AS BusinessEntityID
,   CAST(NULL AS uniqueidentifier) AS BankType_BusinessentityID
,   a.BankType
,   CAST(a.IBAN AS varchar(100)) AS Bankaccount
,   a.BPA_Connection AS Bankaccount_BPAConnection
,   s.Journal
,   s.CompanyID
,   s.Company
,   s.DefaultGLCodeDebtor
,   s.DefaultGLCodeCreditor
,   s.UnknownDebtor
,   s.DiversDebtor
,   s.UnknownCreditor
,   s.DiversCreditor
,   a.BPA_Status AS Status
,   s.Incasso_PaymentMethod
,   s.Incasso_Bedrijfsnaam
,   s.Incasso_BIC
,   s.Incasso_IncassantID
,   s.Incasso_Batchbooking
,   s.GLCodeBank
FROM dbo.tb_Bank_Bankaccounts a
LEFT JOIN dbo.tb_Bank_Bankaccount_Settings s ON s.IBAN = a.IBAN
GO

-- Check 1: every account with transactions should say 'in view'
SELECT t.BPA_Origin,
       COUNT(*) AS transactions,
       CASE WHEN EXISTS (SELECT 1 FROM dbo.vw_Bank_BankAccounts b WHERE b.Bankaccount = t.BPA_Origin)
            THEN 'in view' ELSE 'MISSING' END AS status
FROM dbo.tb_Bank_Transactions t
GROUP BY t.BPA_Origin;

-- Check 2: each IBAN should be in tb_Bank_Bankaccounts only once (the table has no key)
SELECT IBAN, COUNT(*) AS times
FROM dbo.tb_Bank_Bankaccounts
GROUP BY IBAN
HAVING COUNT(*) > 1;
GO
