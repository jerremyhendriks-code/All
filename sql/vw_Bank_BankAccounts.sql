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
    --  IBAN                    Company  GLCodeBank  DefaultGLCodeCreditor  DefaultGLCodeDebtor  UnknownCreditor  UnknownDebtor
    -- GGG: Rabobank 0103 2754 60 GGG Euro (111001601), AP 200000001 Trade payables, AR to check
    (  'NL76RABO0103275460',    '89',    '3427',     '111',                 '119',               NULL,            NULL )
    -- GGOT: Rabobank 0317 9557 99 GGOT Euro; fill in AP / AR, then remove the -- (and see the note below)
--, (  'NL74RABO0317955799',    '93',    '3428',     '<AP>',                '<AR>',              NULL,            NULL )
--, (  'NL16RABO3633747710',    '<sub>', '<bank>',   '<AP>',                '<AR>',              NULL,            NULL )
--, (  'NL45RABO0306680653',    '<sub>', '<bank>',   '<AP>',                '<AR>',              NULL,            NULL )
) s (IBAN, Company, GLCodeBank, DefaultGLCodeCreditor, DefaultGLCodeDebtor, UnknownCreditor, UnknownDebtor)
    ON s.IBAN = b.IBAN;
GO

/*
    Note: when an account's Company changes, its open transactions still carry the old
    BPA_Company (it's copied in at sp_Bank_Transaction_Rabobank_Copy). Move them along:

    UPDATE tb_Bank_Transactions SET BPA_Company = '93'
    WHERE BPA_Origin = 'NL74RABO0317955799' AND BPA_Status = 0 AND BPA_Company = '89';
*/

-- Check: every account, with transactions per account
SELECT bank.Bankaccount, bank.Company, bank.Journal,
       bank.GLCodeBank, bank.DefaultGLCodeCreditor, bank.DefaultGLCodeDebtor,
       (SELECT COUNT(*) FROM dbo.tb_Bank_Transactions t WHERE t.BPA_Origin = bank.Bankaccount) AS transactions
FROM dbo.vw_Bank_BankAccounts bank
ORDER BY bank.Company, bank.Bankaccount;
GO
