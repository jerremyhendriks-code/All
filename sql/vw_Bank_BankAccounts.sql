/*
    vw_Bank_BankAccounts: our own bank accounts with their booking settings.

    The settings (NetSuite internal IDs) are hard-coded per IBAN in the VALUES list
    below. To set up an account: add or change its line and run this script again.
    Accounts without a line keep the old defaults (Journal 'JOURNAL', Company '89',
    no GL codes), so fn_Bank_Match and sp_Bank_Netsuite_FinancialEntry_Create skip them.

        Company               NetSuite subsidiary ID
        GLCodeBank            NetSuite account ID of this bank account
        DefaultGLCodeCreditor NetSuite AP account ID
        DefaultGLCodeDebtor   NetSuite AR account ID
        UnknownCreditor       account for money out without a relation (journal entries)
        UnknownDebtor         account for money in without a relation (journal entries)

    Columns, names and order are unchanged, so callers keep working.
*/
USE [BPAStaging]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER VIEW [dbo].[vw_Bank_BankAccounts] AS
SELECT
    CAST(NULL AS uniqueidentifier)                  AS BusinessEntityID
,   CAST(NULL AS uniqueidentifier)                  AS BankType_BusinessentityID
,   b.BankType                                      AS BankType
,   CAST(b.IBAN AS varchar(100))                    AS Bankaccount
,   b.BPA_Connection                                AS Bankaccount_BPAConnection
,   'JOURNAL'                                       AS Journal
,   CAST(NULL AS uniqueidentifier)                  AS CompanyID
,   ISNULL(s.Company, '89')                         AS Company
,   s.DefaultGLCodeDebtor                           AS DefaultGLCodeDebtor
,   s.DefaultGLCodeCreditor                         AS DefaultGLCodeCreditor
,   CAST(s.UnknownDebtor AS varchar(100))           AS UnknownDebtor
,   CAST(NULL AS varchar(100))                      AS DiversDebtor
,   CAST(s.UnknownCreditor AS varchar(100))         AS UnknownCreditor
,   CAST(NULL AS varchar(100))                      AS DiversCreditor
,   NULL                                            AS Status
,   NULL                                            AS Incasso_PaymentMethod
,   NULL                                            AS Incasso_Bedrijfsnaam
,   NULL                                            AS Incasso_BIC
,   NULL                                            AS Incasso_IncassantID
,   NULL                                            AS Incasso_Batchbooking
,   s.GLCodeBank                                    AS GLCodeBank
FROM dbo.tb_Bank_BankAccounts b
LEFT JOIN (VALUES
    -- Bank GL accounts and subsidiaries from tb_Netsuite_Account (account name) and tb_Companies.
    -- AP 111 = 200000001 Trade payables, AR 119 = 121000001 Accounts Receivable: the same for every
    -- subsidiary until we know otherwise.
    -- Suspense account (UnknownCreditor / UnknownDebtor, journal entries without a relation):
    -- TEMPORARY sandbox test account 3429 = 134000008 Other receivables account, for money in and out.
    -- Replace it with the account Ellomay finance chooses before going live.
    --  IBAN                    Company  GLCodeBank  DefaultGLCodeCreditor  DefaultGLCodeDebtor  UnknownCreditor  UnknownDebtor
    (  'NL76RABO0103275460',    '89',    '3427',     '111',                 '119',               '3429',          '3429' )   -- GGG:  Rabobank 0103 2754 60 GGG Euro  (111001601)
,   (  'NL74RABO0317955799',    '93',    '3428',     '111',                 '119',               '3429',          '3429' )   -- GGOT: Rabobank 0317 9557 99 GGOT Euro (111001602)
,   (  'NL45RABO0306680653',    '94',    '3527',     '111',                 '119',               '3429',          '3429' )   -- GGB:  Rabobank 0306 6806 53 GGB Euro  (111001603)
,   (  'NL16RABO3633747710',    '94',    '3528',     '111',                 '119',               '3429',          '3429' )   -- GGB:  Rabobank 3633 7477 10 GGB Euro  (111002603)
) s (IBAN, Company, GLCodeBank, DefaultGLCodeCreditor, DefaultGLCodeDebtor, UnknownCreditor, UnknownDebtor)
    ON s.IBAN = b.IBAN;
GO

-- Open transactions carry the BPA_Company they were copied with (sp_Bank_Transaction_Rabobank_Copy);
-- move the ones whose bank account now belongs to another subsidiary along.
UPDATE t
SET BPA_Company = bank.Company
FROM dbo.tb_Bank_Transactions t
JOIN dbo.vw_Bank_BankAccounts bank ON bank.Bankaccount = t.BPA_Origin COLLATE database_default
WHERE t.BPA_Status = 0
  AND ISNULL(t.BPA_Company, '') <> bank.Company;

SELECT @@ROWCOUNT AS open_transactions_moved;
GO

-- Check: every account, with transactions per account
SELECT bank.Bankaccount, bank.Company, bank.Journal,
       bank.GLCodeBank, bank.DefaultGLCodeCreditor, bank.DefaultGLCodeDebtor,
       (SELECT COUNT(*) FROM dbo.tb_Bank_Transactions t WHERE t.BPA_Origin = bank.Bankaccount) AS transactions
FROM dbo.vw_Bank_BankAccounts bank
ORDER BY bank.Company, bank.Bankaccount;
GO
