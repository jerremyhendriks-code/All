/*
    vw_Bank_Journal: the Journal business entities from Workflow Platform, one per own bank account.

        Journal      = BusinessEntityCode = NetSuite account NUMBER of the bank account (e.g. 111001601),
                       the same as vw_Bank_Workflow_Accounts.NetsuiteAccountNumber
        Company      = subsidiary (TextField2 of the Company entity), CompanyID = that entity's id
        glcode       = default GL code of the journal (businessentity1id), not filled yet
        glcodebank   = GL code of the bank account (businessentity2id), an account NUMBER as well

    Workflow entities hold NetSuite account numbers, not internal ids: translate them through
    tb_Netsuite_Account (acctNumber -> id) before sending anything to NetSuite.

    fn_Bank_Match_V2 reads glcode as the last fallback GL code (by CompanyID + Journal).
*/
USE [BPAStaging]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER VIEW [dbo].[vw_Bank_Journal]
AS
SELECT
	be.BusinessEntity10ID           AS CompanyID
,	div.TextField2                  AS Company
,	div.BusinessEntityCode          AS CompanyCode
,	div.TextField3                  AS Company_BPAConnection
,	be.BusinessEntityID
,	be.BusinessEntityCode           AS Journal
,	be.Description                  AS description
,	glcodes.BusinessEntityCode      AS glcode
,	glcodesbank.BusinessEntityCode  AS glcodebank
FROM [WorkflowPlatform].dbo.BusinessEntities be (NOLOCK)
LEFT JOIN [WorkflowPlatform].dbo.BusinessEntities div         (NOLOCK) ON div.BusinessEntityID         = be.BusinessEntity10ID
LEFT JOIN [WorkflowPlatform].dbo.BusinessEntities glcodes     (NOLOCK) ON glcodes.BusinessEntityID     = be.BusinessEntity1ID
LEFT JOIN [WorkflowPlatform].dbo.BusinessEntities glcodesbank (NOLOCK) ON glcodesbank.BusinessEntityID = be.BusinessEntity2ID
WHERE be.BusinessEntityTypeID = '840f5d43-bb78-44d4-80ed-06eb201c06fa';	-- Journal
GO

-- Check: one journal per own bank account
SELECT CompanyID, Company, Journal, description, glcode, glcodebank
FROM dbo.vw_Bank_Journal
ORDER BY Company, Journal;
GO
