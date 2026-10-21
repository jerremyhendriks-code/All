/*
    vw_Bank_Matching: the bank matching rules from Workflow Platform, for fn_Bank_Match_V2.
    NetSuite version of the SIT template view (Exact).

    A rule is a workflow of type "Bank rule" (WorkflowTypeID 915785CB-...) with status approved
    (CurrentStatusID 5455308E-...), made from the Bank Workflow Report with one of the three actions:
        Submit and approve                  general rule: GL account, relation, VAT, cost centre / unit
        Submit and approve bankaccount      IBAN -> relation
        Submit and recognize relation       description etc. -> relation

    Changes to the template, for NetSuite:
        BankAccount   bank account entity BusinessEntityCode (= IBAN without spaces; the template read
                      TextField2, which vw_WF_BankAccounts doesn't fill)
        Company       Company entity code = NetSuite subsidiary id (fn_Bank_Match_V2 filters on this,
                      CompanyID is kept for reference)
        GLcode        NetSuite internal account id: GL code entity ExternalReference (vw_WF_GLCodes), else
                      looked up by account number in tb_Netsuite_Account. GLAccountNumber = the entity code.
        CredDebCode   GL code entity TextField1: D = Accounts Receivable, C = Accounts Payable (vw_WF_GLCodes)
        vendor_id     relation entity TextField3 = NetSuite vendor id   (vw_WF_Relations; was "Creditor")
        customer_id   relation entity TextField1 = NetSuite customer id (vw_WF_Relations; was "Debtor")
        CostCenter    NetSuite department id (vw_WF_CostCenters: code = internal id)
        CostUnit      NetSuite class id      (vw_WF_CostUnits: code = internal id)
        VATcode       tax code entity ExternalReference, else its code (no vw_WF_ view fills it yet)
        AmountTo      NumberField2 (the template had NumberField1, the same field as Amount)  -- CHECK with the first rule
        Empty text fields become NULL, so "field IS NULL" means "no condition".
        Text columns are COLLATE DATABASE_DEFAULT: Workflow Platform may use another collation.

    fn_Bank_Match_Rules returns the rules that fit one bank transaction, most specific first.
*/
USE [BPAStaging]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER VIEW dbo.vw_Bank_Matching
AS
SELECT
	BankAccount         = UPPER(REPLACE(bank.BusinessEntityCode, ' ', '')) COLLATE DATABASE_DEFAULT
,	CompanyID           = div.BusinessEntityID
,	Company             = div.BusinessEntityCode COLLATE DATABASE_DEFAULT
,	BankaccountRelation = NULLIF(UPPER(REPLACE(wf.TextField1, ' ', '')), '') COLLATE DATABASE_DEFAULT
,	PaymentDirection    = NULLIF(wf.TextField2, '') COLLATE DATABASE_DEFAULT	-- A = all, P = money in, N = money out
,	Description         = NULLIF(wf.TextField3, '') COLLATE DATABASE_DEFAULT
,	Kenmerk             = NULLIF(wf.TextField4, '') COLLATE DATABASE_DEFAULT
,	Betalingskenmerk    = NULLIF(wf.TextField5, '') COLLATE DATABASE_DEFAULT
,	Machtiging          = NULLIF(wf.TextField9, '') COLLATE DATABASE_DEFAULT
,	Incassant           = NULLIF(wf.TextField10, '') COLLATE DATABASE_DEFAULT
,	Amount              = wf.NumberField1
,	AmountTo            = wf.NumberField2
,	AmountCompare       = NULLIF(wf.TextField11, '') COLLATE DATABASE_DEFAULT	-- = < > <>
,	MutationCode        = Mut.BusinessEntityCode COLLATE DATABASE_DEFAULT
,	GLcode              = COALESCE(NULLIF(gl.ExternalReference, ''), acc.id) COLLATE DATABASE_DEFAULT
,	GLAccountNumber     = gl.BusinessEntityCode COLLATE DATABASE_DEFAULT
,	GLAccountName       = gl.Description COLLATE DATABASE_DEFAULT
,	CredDebCode         = NULLIF(gl.TextField1, '') COLLATE DATABASE_DEFAULT
,	VATcode             = COALESCE(NULLIF(tax.ExternalReference, ''), tax.BusinessEntityCode) COLLATE DATABASE_DEFAULT
,	CostCenter          = Costcenter.BusinessEntityCode COLLATE DATABASE_DEFAULT
,	CostUnit            = Costunit.BusinessEntityCode COLLATE DATABASE_DEFAULT
,	vendor_id           = NULLIF(Aca.TextField3, '') COLLATE DATABASE_DEFAULT
,	customer_id         = NULLIF(Aca.TextField1, '') COLLATE DATABASE_DEFAULT
,	RelationName        = Aca.Description COLLATE DATABASE_DEFAULT
,	wf.WorkflowNumber
,	wf.WorkflowID
FROM [WorkflowPlatform].dbo.Workflows wf (NOLOCK)
LEFT JOIN [WorkflowPlatform].dbo.BusinessEntities bank       (NOLOCK) ON bank.BusinessEntityID       = wf.BusinessEntity1ID
LEFT JOIN [WorkflowPlatform].dbo.BusinessEntities div        (NOLOCK) ON div.BusinessEntityID        = wf.BusinessEntity10ID
LEFT JOIN [WorkflowPlatform].dbo.BusinessEntities gl         (NOLOCK) ON gl.BusinessEntityID         = wf.BusinessEntity2ID
LEFT JOIN [WorkflowPlatform].dbo.BusinessEntities tax        (NOLOCK) ON tax.BusinessEntityID        = wf.BusinessEntity3ID
LEFT JOIN [WorkflowPlatform].dbo.BusinessEntities Costcenter (NOLOCK) ON Costcenter.BusinessEntityID = wf.BusinessEntity4ID
LEFT JOIN [WorkflowPlatform].dbo.BusinessEntities Costunit   (NOLOCK) ON Costunit.BusinessEntityID   = wf.BusinessEntity5ID
LEFT JOIN [WorkflowPlatform].dbo.BusinessEntities Aca        (NOLOCK) ON Aca.BusinessEntityID        = wf.BusinessEntity7ID
LEFT JOIN [WorkflowPlatform].dbo.BusinessEntities Mut        (NOLOCK) ON Mut.BusinessEntityID        = wf.BusinessEntity8ID
-- GL code entity without ExternalReference: the NetSuite id by account number
OUTER APPLY (
	SELECT TOP (1) a.id
	FROM dbo.tb_Netsuite_Account a
	WHERE NULLIF(gl.ExternalReference, '') IS NULL
	  AND a.acctNumber = gl.BusinessEntityCode COLLATE DATABASE_DEFAULT
	ORDER BY a.BPA_Syscreated DESC
) acc
WHERE wf.WorkflowTypeID  = '915785CB-6BD2-4F5F-9711-D134E10EEAE6'	-- bank rule
  AND wf.CurrentStatusID = '5455308E-B9B5-4052-818E-42D571593CFD'	-- approved
  AND wf.IsDeleted = 0;
GO

/*
    fn_Bank_Match_Rules: the rules that fit one bank transaction, most specific first.
    A rule condition that is empty (NULL) always fits. Amounts are compared without sign;
    PaymentDirection decides money in (P) / out (N) / both (A, or empty).
*/
CREATE OR ALTER FUNCTION dbo.fn_Bank_Match_Rules
(
	@Company          nvarchar(100)
,	@BankAccount      nvarchar(50)	-- own IBAN (BPA_Origin)
,	@IBAN             nvarchar(50)	-- counterparty IBAN
,	@Amount           float
,	@Description      nvarchar(255)
,	@Kenmerk          nvarchar(255)
,	@Betalingskenmerk nvarchar(255)
,	@Machtiging       nvarchar(255)
,	@Incassant        nvarchar(255)
,	@Mutationcode     nvarchar(50)
)
RETURNS TABLE
AS
RETURN
	SELECT
		m.*
	,	Specificity =
			  CASE WHEN m.BankaccountRelation IS NOT NULL THEN 8 ELSE 0 END
			+ CASE WHEN m.Description         IS NOT NULL THEN 4 ELSE 0 END
			+ CASE WHEN m.Amount              IS NOT NULL THEN 2 ELSE 0 END
			+ CASE WHEN m.Kenmerk IS NOT NULL OR m.Betalingskenmerk IS NOT NULL OR m.Machtiging IS NOT NULL
					 OR m.Incassant IS NOT NULL OR m.MutationCode IS NOT NULL THEN 1 ELSE 0 END
	FROM dbo.vw_Bank_Matching m
	WHERE m.Company = @Company
	  AND m.BankAccount = UPPER(REPLACE(@BankAccount, ' ', ''))
	  AND (m.BankaccountRelation IS NULL OR m.BankaccountRelation = UPPER(REPLACE(@IBAN, ' ', '')))
	  AND (m.Description IS NULL OR @Description LIKE '%' + m.Description + '%')
	  AND (m.Amount IS NULL
		   OR (ISNULL(m.AmountCompare, '=') = '=' AND ABS(ABS(@Amount) - m.Amount) < 0.005)
		   OR (m.AmountCompare = '<'  AND ABS(@Amount) < m.Amount)
		   OR (m.AmountCompare = '>'  AND ABS(@Amount) > m.Amount)
		   OR (m.AmountCompare = '<>' AND ABS(@Amount) BETWEEN m.Amount AND m.AmountTo))
	  AND (ISNULL(m.PaymentDirection, 'A') = 'A'
		   OR (m.PaymentDirection = 'P' AND @Amount > 0)
		   OR (m.PaymentDirection = 'N' AND @Amount < 0))
	  AND (m.MutationCode     IS NULL OR m.MutationCode = @Mutationcode)
	  AND (m.Kenmerk          IS NULL OR @Kenmerk          LIKE '%' + m.Kenmerk + '%')
	  AND (m.Betalingskenmerk IS NULL OR @Betalingskenmerk LIKE '%' + m.Betalingskenmerk + '%')
	  AND (m.Machtiging       IS NULL OR @Machtiging       LIKE '%' + m.Machtiging + '%')
	  AND (m.Incassant        IS NULL OR @Incassant        LIKE '%' + m.Incassant + '%');
GO

-- Check: the approved bank rules
SELECT WorkflowNumber, Company, BankAccount, BankaccountRelation, PaymentDirection, Description,
       Amount, AmountCompare, AmountTo, GLAccountNumber, GLcode, CredDebCode,
       vendor_id, customer_id, RelationName, CostCenter, CostUnit, VATcode
FROM dbo.vw_Bank_Matching
ORDER BY Company, BankAccount, WorkflowNumber;
GO
