/*
    Link each Rabobank account in tb_Bank_Bankaccounts to NetSuite.
    Used by usp_Bank_Match_Rabobank; a bank account without these values is skipped.

    - netsuite_subsidiary_id          Subsidiary the account belongs to (tb_Companies.subsidiary_ID).
    - netsuite_account_id             Bank GL account the payments and journal entries post to.
    - netsuite_currency_id            NetSuite currency id of the account (matches currency_id on invoices / bills).
    - netsuite_suspense_account_id    Suspense GL account for unmatched transactions.

    Safe to run more than once. Fill the values for the 4 Ellomay accounts afterwards, e.g.:
        UPDATE dbo.tb_Bank_Bankaccounts
        SET    netsuite_subsidiary_id = N'2', netsuite_account_id = N'123',
               netsuite_currency_id = N'1', netsuite_suspense_account_id = N'456'
        WHERE  IBAN = 'NL00RABO0123456789';
*/
USE [BPAStaging];
GO

IF COL_LENGTH(N'dbo.tb_Bank_Bankaccounts', N'netsuite_subsidiary_id') IS NULL
    ALTER TABLE dbo.tb_Bank_Bankaccounts ADD netsuite_subsidiary_id nvarchar(100) NULL;
GO

IF COL_LENGTH(N'dbo.tb_Bank_Bankaccounts', N'netsuite_account_id') IS NULL
    ALTER TABLE dbo.tb_Bank_Bankaccounts ADD netsuite_account_id nvarchar(100) NULL;
GO

IF COL_LENGTH(N'dbo.tb_Bank_Bankaccounts', N'netsuite_currency_id') IS NULL
    ALTER TABLE dbo.tb_Bank_Bankaccounts ADD netsuite_currency_id nvarchar(100) NULL;
GO

IF COL_LENGTH(N'dbo.tb_Bank_Bankaccounts', N'netsuite_suspense_account_id') IS NULL
    ALTER TABLE dbo.tb_Bank_Bankaccounts ADD netsuite_suspense_account_id nvarchar(100) NULL;
GO
