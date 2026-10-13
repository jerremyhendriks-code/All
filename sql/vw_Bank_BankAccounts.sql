/*
    Booking settings per bank account for the bank engine.

    vw_Bank_BankAccounts used to return Company = '89' and NULL GL codes for every
    account (the Workflow4U source is no longer used). fn_Bank_Match and
    sp_Bank_Netsuite_FinancialEntry_Create need the NetSuite IDs per account, so:

    1. New table tb_Bank_BankAccount_Settings: one row per IBAN with the NetSuite
       internal IDs (subsidiary, bank / AP / AR GL accounts, unknown-relation accounts).
    2. A row for every account in tb_Bank_BankAccounts that has none yet, with the
       values the view returned until now (Journal 'JOURNAL', Company '89').
    3. vw_Bank_BankAccounts reads the settings from that table. Columns, names and
       order stay the same, so fn_Bank_Match and sp_Bank_Transaction_Rabobank_Copy
       keep working.

    Safe to run more than once. An account added to tb_Bank_BankAccounts later gets
    Company NULL in the view until it has a settings row: its transactions are then
    copied without BPA_Company and not booked until the account is set up.
*/
USE [BPAStaging]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- 1. Settings table
IF OBJECT_ID(N'dbo.tb_Bank_BankAccount_Settings', N'U') IS NULL
    CREATE TABLE dbo.tb_Bank_BankAccount_Settings
    (
        IBAN                    varchar(34)   NOT NULL
            CONSTRAINT PK_tb_Bank_BankAccount_Settings PRIMARY KEY,  -- = tb_Bank_BankAccounts.IBAN
        Journal                 nvarchar(20)  NULL,
        Company                 nvarchar(50)  NULL,     -- NetSuite subsidiary ID
        GLCodeBank              nvarchar(9)   NULL,     -- NetSuite account ID of this bank account
        DefaultGLCodeCreditor   nvarchar(9)   NULL,     -- NetSuite AP account ID
        DefaultGLCodeDebtor     nvarchar(9)   NULL,     -- NetSuite AR account ID
        UnknownCreditor         nvarchar(100) NULL,     -- money out, no relation found
        UnknownDebtor           nvarchar(100) NULL,     -- money in, no relation found
        DiversCreditor          nvarchar(100) NULL,
        DiversDebtor            nvarchar(100) NULL,
        Modified                datetime      NOT NULL
            CONSTRAINT DF_tb_Bank_BankAccount_Settings_Modified DEFAULT (GETDATE())
    );
GO

-- 2. A row for every account that has none yet: the values the view returned until now
INSERT INTO dbo.tb_Bank_BankAccount_Settings (IBAN, Journal, Company)
SELECT DISTINCT b.IBAN, N'JOURNAL', N'89'
FROM dbo.tb_Bank_BankAccounts b
WHERE b.IBAN IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM dbo.tb_Bank_BankAccount_Settings s WHERE s.IBAN = b.IBAN);
GO

-- 3. The view reads the settings
CREATE OR ALTER VIEW [dbo].[vw_Bank_BankAccounts] AS
SELECT
    CAST(NULL AS uniqueidentifier)      AS BusinessEntityID
,   CAST(NULL AS uniqueidentifier)      AS BankType_BusinessentityID
,   b.BankType                          AS BankType
,   CAST(b.IBAN AS varchar(100))        AS Bankaccount
,   b.BPA_Connection                    AS Bankaccount_BPAConnection
,   s.Journal                           AS Journal
,   CAST(NULL AS uniqueidentifier)      AS CompanyID
,   s.Company                           AS Company
,   s.DefaultGLCodeDebtor               AS DefaultGLCodeDebtor
,   s.DefaultGLCodeCreditor             AS DefaultGLCodeCreditor
,   s.UnknownDebtor                     AS UnknownDebtor
,   s.DiversDebtor                      AS DiversDebtor
,   s.UnknownCreditor                   AS UnknownCreditor
,   s.DiversCreditor                    AS DiversCreditor
,   NULL                                AS Status
,   NULL                                AS Incasso_PaymentMethod
,   NULL                                AS Incasso_Bedrijfsnaam
,   NULL                                AS Incasso_BIC
,   NULL                                AS Incasso_IncassantID
,   NULL                                AS Incasso_Batchbooking
,   s.GLCodeBank                        AS GLCodeBank
FROM dbo.tb_Bank_BankAccounts b
LEFT JOIN dbo.tb_Bank_BankAccount_Settings s ON s.IBAN = b.IBAN;
GO

-- 4. Fill in the NetSuite IDs per account
-- GGG, subsidiary 89
UPDATE dbo.tb_Bank_BankAccount_Settings
SET Company               = N'89',
    GLCodeBank            = N'3427',   -- Rabobank 0103 2754 60 GGG Euro (111001601)
    DefaultGLCodeCreditor = N'111',    -- 200000001 ACCOUNTS PAYABLE : Trade payables
    DefaultGLCodeDebtor   = N'119',    -- accounts receivable: check
    Modified              = GETDATE()
WHERE IBAN = 'NL76RABO0103275460';

-- GGOT, subsidiary 93: fill in once confirmed (then also move its open transactions:
-- UPDATE tb_Bank_Transactions SET BPA_Company = '93'
-- WHERE BPA_Origin = 'NL74RABO0317955799' AND BPA_Status = 0 AND BPA_Company = '89';)
-- UPDATE dbo.tb_Bank_BankAccount_Settings
-- SET Company               = N'93',
--     GLCodeBank            = N'3428',   -- Rabobank 0317 9557 99 GGOT Euro
--     DefaultGLCodeCreditor = N'<AP account>',
--     DefaultGLCodeDebtor   = N'<AR account>',
--     Modified              = GETDATE()
-- WHERE IBAN = 'NL74RABO0317955799';
GO

-- Check: every account, with transactions per account
SELECT bank.Bankaccount, bank.Company, bank.Journal,
       bank.GLCodeBank, bank.DefaultGLCodeCreditor, bank.DefaultGLCodeDebtor,
       (SELECT COUNT(*) FROM dbo.tb_Bank_Transactions t WHERE t.BPA_Origin = bank.Bankaccount) AS transactions
FROM dbo.vw_Bank_BankAccounts bank
ORDER BY bank.Company, bank.Bankaccount;
GO
