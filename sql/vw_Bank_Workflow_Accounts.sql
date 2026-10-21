USE [BPAStaging]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

-- One row per Rabobank account with its company and NetSuite bank account.
-- Used by the Bank Workflow Report (dropdowns + sp_Bank_Workflow_Overzicht).
--
-- Company:          tb_Companies via BPA_Connection (same link as vw_Bank_OpenTransaction).
--                   No link yet -> '(no company)', so the account still shows in the report.
-- NetSuite account: the NetSuite account name holds the Dutch account number, the last 10 digits
--                   of the IBAN, with spaces in between:
--                       NL76RABO0103275460  ->  'Rabobank 0103 2754 60 GGG Euro'
--                   So we take RIGHT(iban, 10) and look for it in the account name without spaces.
--                   tb_Netsuite_Account can hold the same account more than once (several loads);
--                   TOP (1) takes the latest one.
CREATE OR ALTER VIEW [dbo].[vw_Bank_Workflow_Accounts]
AS
SELECT
	b.iban                                              AS Bankaccount
,	b.BankType
,	b.BPA_Connection
,	ISNULL(co.BPA_Company, N'(no company)')             AS Company
,	COALESCE(co.BPA_Company_Description, co.BPA_Company, N'(no company)') AS CompanyDescription
,	co.subsidiary_ID                                    AS SubsidiaryID
,	acc.id                                              AS NetsuiteAccountID
,	acc.acctNumber                                      AS NetsuiteAccountNumber
,	acc.acctName                                        AS NetsuiteAccountName
FROM (
	SELECT DISTINCT
		UPPER(REPLACE(ba.IBAN, ' ', '')) AS iban
	,	ba.BankType
	,	ba.BPA_Connection
	FROM dbo.tb_Bank_Bankaccounts ba
	WHERE ba.IBAN IS NOT NULL
) b
OUTER APPLY (
	SELECT TOP (1) c.BPA_Company, c.BPA_Company_Description, c.subsidiary_ID
	FROM dbo.tb_Companies c
	WHERE c.BPA_Company_BPAConnection = b.BPA_Connection
		AND c.subsidiary_ID IS NOT NULL
	ORDER BY c.BPA_Sysmodified DESC
) co
OUTER APPLY (
	SELECT TOP (1) a.id, a.acctNumber, a.acctName
	FROM dbo.tb_Netsuite_Account a
	WHERE ISNULL(a.isInactive, 0) = 0
		AND LEN(b.iban) >= 10
		AND REPLACE(a.acctName, N' ', N'') LIKE N'%' + RIGHT(b.iban, 10) + N'%'
	ORDER BY a.lastModifiedDate DESC, a.BPA_Syscreated DESC
) acc;
GO

-- Check: every bank account should have a NetSuite account
SELECT Bankaccount, Company, SubsidiaryID, NetsuiteAccountID, NetsuiteAccountNumber, NetsuiteAccountName
FROM dbo.vw_Bank_Workflow_Accounts
ORDER BY Company, Bankaccount;
GO
