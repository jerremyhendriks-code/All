/*
    vw_Bank_BankAccounts: our own bank accounts and their booking settings.

    The view used to be a placeholder that always returned one row with
    Bankaccount = NULL, so fn_Bank_Match never found any default GL codes.
    It now reads from tb_Bank_BankAccounts: one row per account the Rabobank
    task picks up transactions for (Bankaccount = BPA_Origin in tb_Bank_Transactions).

    Columns, names and order are the same as before, so callers keep working.
    Safe to run more than once.
*/
USE [BPAStaging]
GO

IF OBJECT_ID(N'dbo.tb_Bank_BankAccounts', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.tb_Bank_BankAccounts
    (
        Bankaccount             varchar(100)     NOT NULL PRIMARY KEY,  -- our own IBAN, as in BPA_Origin
        BankType                varchar(10)      NOT NULL DEFAULT 'RABO',
        Bankaccount_BPAConnection nvarchar(100)  NULL,
        Journal                 nvarchar(20)     NULL,
        CompanyID               uniqueidentifier NULL,
        Company                 nvarchar(50)     NULL,                  -- NetSuite subsidiary
        DefaultGLCodeDebtor     nvarchar(9)      NULL,                  -- accounts receivable GL account
        DefaultGLCodeCreditor   nvarchar(9)      NULL,                  -- accounts payable GL account
        UnknownDebtor           nvarchar(100)    NULL,
        DiversDebtor            nvarchar(100)    NULL,
        UnknownCreditor         nvarchar(100)    NULL,
        DiversCreditor          nvarchar(100)    NULL,
        Status                  int              NULL,
        Incasso_PaymentMethod   nvarchar(100)    NULL,
        Incasso_Bedrijfsnaam    nvarchar(100)    NULL,
        Incasso_BIC             nvarchar(20)     NULL,
        Incasso_IncassantID     nvarchar(100)    NULL,
        Incasso_Batchbooking    bit              NULL,
        GLCodeBank              nvarchar(9)      NULL
    );
END
GO

-- The account that already has transactions. Add the other 4 accounts the same way.
IF NOT EXISTS (SELECT 1 FROM dbo.tb_Bank_BankAccounts WHERE Bankaccount = 'NL74RABO0317955799')
    INSERT INTO dbo.tb_Bank_BankAccounts (Bankaccount, BankType, Journal, Company)
    VALUES ('NL74RABO0317955799', 'RABO', 'JOURNAL', 'TEST');
GO

-- Fill in the booking settings per account (values come from the NetSuite setup):
-- UPDATE dbo.tb_Bank_BankAccounts
-- SET Journal               = '<journal>',
--     Company               = '<NetSuite subsidiary>',
--     DefaultGLCodeDebtor   = '<AR GL account>',
--     DefaultGLCodeCreditor = '<AP GL account>',
--     GLCodeBank            = '<bank GL account>'
-- WHERE Bankaccount = 'NL74RABO0317955799';

ALTER VIEW [dbo].[vw_Bank_BankAccounts] AS
SELECT
    CAST(NULL AS uniqueidentifier) AS BusinessEntityID
,   CAST(NULL AS uniqueidentifier) AS BankType_BusinessentityID
,   b.BankType
,   b.Bankaccount
,   b.Bankaccount_BPAConnection
,   b.Journal
,   b.CompanyID
,   b.Company
,   b.DefaultGLCodeDebtor
,   b.DefaultGLCodeCreditor
,   b.UnknownDebtor
,   b.DiversDebtor
,   b.UnknownCreditor
,   b.DiversCreditor
,   b.Status
,   b.Incasso_PaymentMethod
,   b.Incasso_Bedrijfsnaam
,   b.Incasso_BIC
,   b.Incasso_IncassantID
,   b.Incasso_Batchbooking
,   b.GLCodeBank
FROM dbo.tb_Bank_BankAccounts b
GO

-- Check: every account with transactions should say 'in view'
SELECT t.BPA_Origin,
       COUNT(*) AS transactions,
       CASE WHEN EXISTS (SELECT 1 FROM dbo.vw_Bank_BankAccounts b WHERE b.Bankaccount = t.BPA_Origin)
            THEN 'in view' ELSE 'MISSING' END AS status
FROM dbo.tb_Bank_Transactions t
GROUP BY t.BPA_Origin;
GO
