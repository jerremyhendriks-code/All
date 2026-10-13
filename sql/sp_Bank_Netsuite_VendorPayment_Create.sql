USE [BPAStaging]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
/*
    sp_Bank_Netsuite_VendorPayment_Create

    Step 1 of the bank engine for Ellomay: open bank transactions that fn_Bank_Match
    matched to a vendor + vendor bill become a NetSuite vendor payment on that bill.

    The scenario comes from fn_Bank_Match's typematch:
        typematch                       vendor_id  customer_id  Reference      -> scenario
        PurchaseInvoice / ...Amount     filled     -            bill number    -> VENDORPAYMENT    (this procedure)
        Sales...                        -          filled       invoice number -> CUSTOMERPAYMENT  (later)
                                                                or ReferenceXML
        anything else                                                          -> JOURNALENTRY     (later)
    Transactions in the other scenarios are not touched: they stay BPA_Status = 0.

    Per open bank transaction (tb_Bank_Transactions, BPA_Status = 0, @BPA_Company):
    1. Run fn_Bank_Match and store the result in the Matched_* columns.
    2. VENDORPAYMENT: look up the vendor bill by vendor_id + bill number (Matched_Reference)
       -> vendor_bill_id. Latest loaded row per bill is used.
    3. Skip (and report) when something is missing or unsafe; the transaction stays open:
       money coming in, bill not found or found twice, bill paid / open amount too small,
       other subsidiary or currency than the bank account, missing NetSuite IDs,
       the bill is claimed by another transaction in this run or waits in an unsent
       vendor payment, or the externalId is already staged.
    4. Insert tb_Netsuite_VendorPayment (header) + tb_Netsuite_VendorPayment_Apply
       (one line: the bill, amount = ABS(bank amount)), BPA_Direction 'TO', BPA_Status 0.
    5. Bank transaction: BPA_Status = 1, BPA_ReturnedID = BPA_EntryID of the payment header.

    NetSuite internal IDs per bank account (vw_Bank_BankAccounts / tb_Bank_Bankaccount_Settings):
        Company               = subsidiary ID
        GLCodeBank            = bank GL account ID   -> accountId
        DefaultGLCodeCreditor = AP account ID        -> apAcctId
    externalId = 'BANK-<own IBAN>-<bank BPA_Reference>', so NetSuite refuses a second copy.
    id is NOT NULL without a default: sent as '' and filled once NetSuite has created the payment.

    Run:
        EXEC sp_Bank_Netsuite_VendorPayment_Create @BPA_Company = '89', @Preview = 1;   -- show only
        EXEC sp_Bank_Netsuite_VendorPayment_Create @BPA_Company = '89';                 -- create
        EXEC sp_Bank_Netsuite_VendorPayment_Create '89', @BPA_EntryID = '<one bank transaction>';
*/
CREATE OR ALTER PROCEDURE [dbo].[sp_Bank_Netsuite_VendorPayment_Create]
(
	@BPA_Company varchar(50)
,	@BPA_EntryID uniqueidentifier = NULL	-- NULL = all open transactions of @BPA_Company
,	@Preview     bit = 0					-- 1 = show the result, change nothing
)
AS
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Creator nvarchar(50) = N'sp_Bank_Netsuite_VendorPayment_Create';

-- 1. Match the open transactions
IF OBJECT_ID('tempdb..#t') IS NOT NULL DROP TABLE #t;

SELECT
	t.BPA_EntryID
,	NEWID()                                                         AS NewEntryID
,	t.BPA_Origin
,	t.Bookdate
,	t.Amount
,	t.Currency
,	LEFT(COALESCE(t.Description, t.Kenmerk, t.Betalingskenmerk, ''), 250) AS Memo
,	'BANK-' + t.BPA_Origin + '-' + t.BPA_Reference                  AS ExternalID
,	m.typematch
,	m.GLCode
,	m.vendor_id
,	m.customer_id
,	m.Costcenter
,	m.CostUnit
,	LTRIM(RTRIM(m.Reference))                                       AS Reference
,	m.NewCustomer
,	m.VatCode
,	m.ReferenceXML
,	CASE
		WHEN m.typematch LIKE 'Purchase%' AND m.vendor_id IS NOT NULL AND LTRIM(RTRIM(m.Reference)) <> ''
			THEN 'VENDORPAYMENT'
		WHEN m.typematch LIKE 'Sales%' AND m.customer_id IS NOT NULL
			AND (LTRIM(RTRIM(m.Reference)) <> '' OR m.ReferenceXML IS NOT NULL)
			THEN 'CUSTOMERPAYMENT'
		ELSE 'JOURNALENTRY'
	END                                                             AS Scenario
INTO #t
FROM tb_Bank_Transactions t
CROSS APPLY dbo.fn_Bank_Match('BANK', t.BPA_EntryID, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) m
WHERE t.BPA_Status = 0
	AND t.BPA_Company = @BPA_Company
	AND (@BPA_EntryID IS NULL OR t.BPA_EntryID = @BPA_EntryID);

-- 2. Vendor payments: everything NetSuite needs, looked up
IF OBJECT_ID('tempdb..#vp') IS NOT NULL DROP TABLE #vp;

SELECT
	x.BPA_EntryID
,	x.NewEntryID
,	x.BPA_Origin
,	x.Bookdate
,	x.Amount
,	CAST(ABS(x.Amount) AS decimal(18, 2))                           AS PayAmount
,	x.Currency
,	x.Memo
,	x.ExternalID
,	x.typematch
,	x.vendor_id
,	x.Reference                                                     AS BillNumber
,	bank.Company                                                    AS SubsidiaryID
,	bank.GLCodeBank                                                 AS BankAccountID
,	bank.DefaultGLCodeCreditor                                      AS APAccountID
,	cur.id                                                          AS CurrencyID
,	bill.bills                                                      AS BillsFound
,	bill.vendor_bill_id                                             AS VendorBillID
,	bill.amount_open                                                AS BillAmountOpen
,	bill.subsidiary_id                                              AS BillSubsidiaryID
,	bill.currency_id                                                AS BillCurrencyID
,	CAST(NULL AS nvarchar(200))                                     AS SkipReason
INTO #vp
FROM #t x
LEFT JOIN vw_Bank_BankAccounts bank
	ON bank.Bankaccount = x.BPA_Origin COLLATE database_default
OUTER APPLY (
	SELECT TOP 1 c.id
	FROM tb_Netsuite_Currency c
	WHERE c.symbol = x.Currency
		AND ISNULL(c.isInactive, 0) = 0
) cur
OUTER APPLY (
	-- The bill(s) of this vendor with this number; latest loaded row per bill
	SELECT
		COUNT(*)                                                    AS bills
	,	MAX(b.vendor_bill_id)                                       AS vendor_bill_id
	,	MAX(b.amount_open)                                          AS amount_open
	,	MAX(b.subsidiary_id)                                        AS subsidiary_id
	,	MAX(b.currency_id)                                          AS currency_id
	FROM (
		SELECT
			CAST(v.vendor_bill_id AS nvarchar(100))                 AS vendor_bill_id
		,	TRY_CAST(v.amount_open AS decimal(18, 2))               AS amount_open
		,	CAST(v.subsidiary_id AS nvarchar(100))                  AS subsidiary_id
		,	CAST(v.currency_id AS nvarchar(100))                    AS currency_id
		,	ROW_NUMBER() OVER (PARTITION BY v.vendor_bill_id
							   ORDER BY v.BPA_Syscreated DESC, v.BPA_EntryID DESC) AS rn
		FROM tb_Netsuite_VendorBill v
		WHERE CAST(v.vendor_id AS nvarchar(100)) = x.vendor_id
			AND LTRIM(RTRIM(v.vendor_bill_number)) = x.Reference
	) b
	WHERE b.rn = 1
) bill
WHERE x.Scenario = 'VENDORPAYMENT';

-- 3. Don't send what isn't safe: the transaction stays open and is listed at the end
UPDATE p SET SkipReason = r.Reason
FROM #vp p
CROSS APPLY (SELECT CASE
	WHEN p.Amount >= 0                         THEN 'Money coming in, not a payment to the vendor'
	WHEN p.ExternalID IS NULL                  THEN 'No BPA_Origin / BPA_Reference for the externalId'
	WHEN p.BillsFound = 0                      THEN 'Vendor bill ' + p.BillNumber + ' not found for vendor ' + p.vendor_id
	WHEN p.BillsFound > 1                      THEN 'Vendor ' + p.vendor_id + ' has ' + CAST(p.BillsFound AS varchar(10)) + ' bills numbered ' + p.BillNumber
	WHEN p.BillAmountOpen IS NULL
	  OR p.BillAmountOpen <= 0                 THEN 'Vendor bill ' + p.BillNumber + ' is not open'
	WHEN p.PayAmount - p.BillAmountOpen > 0.005 THEN 'Payment ' + CAST(p.PayAmount AS varchar(20)) + ' is more than open amount ' + CAST(p.BillAmountOpen AS varchar(20))
	WHEN p.SubsidiaryID IS NULL                THEN 'No subsidiary (Company) for bank account ' + ISNULL(p.BPA_Origin, '')
	WHEN p.BankAccountID IS NULL               THEN 'No GLCodeBank for bank account ' + ISNULL(p.BPA_Origin, '')
	WHEN p.APAccountID IS NULL                 THEN 'No AP account (DefaultGLCodeCreditor) for bank account ' + ISNULL(p.BPA_Origin, '')
	WHEN p.CurrencyID IS NULL                  THEN 'Unknown currency ' + ISNULL(p.Currency, '')
	WHEN p.BillSubsidiaryID <> p.SubsidiaryID  THEN 'Bill is in subsidiary ' + p.BillSubsidiaryID + ', bank account in ' + p.SubsidiaryID
	WHEN p.BillCurrencyID <> p.CurrencyID      THEN 'Bill currency ' + p.BillCurrencyID + ' differs from bank currency ' + p.CurrencyID
	WHEN EXISTS (SELECT 1 FROM #vp o
				 WHERE o.VendorBillID = p.VendorBillID AND o.BPA_EntryID <> p.BPA_EntryID)
	                                           THEN 'Bill ' + p.BillNumber + ' is matched by more than one bank transaction'
	WHEN EXISTS (SELECT 1 FROM tb_Netsuite_VendorPayment h
				 WHERE h.externalId = p.ExternalID)
	                                           THEN 'Already staged as vendor payment ' + p.ExternalID
	WHEN EXISTS (SELECT 1
				 FROM tb_Netsuite_VendorPayment_Apply a
				 JOIN tb_Netsuite_VendorPayment h ON h.BPA_EntryID = a.BPA_ParentID
				 WHERE a.doc_id = p.VendorBillID
					AND h.BPA_Direction = 'TO'
					AND h.BPA_Status = 0)
	                                           THEN 'Bill ' + p.BillNumber + ' is already in a vendor payment that is not sent yet'
END AS Reason) r
WHERE r.Reason IS NOT NULL;

IF @Preview = 0
BEGIN
	BEGIN TRANSACTION;

	-- Store the match on every transaction looked at (also the ones for later scenarios)
	UPDATE t
	SET
		Matched_NewCustomer  = x.NewCustomer
	,	Matched_typematch    = x.typematch
	,	Matched_GLCode       = x.GLCode
	,	Matched_Creditor     = x.vendor_id
	,	Matched_Debtor       = x.customer_id
	,	Matched_Costcenter   = x.Costcenter
	,	Matched_CostUnit     = x.CostUnit
	,	Matched_Reference    = x.Reference
	,	Matched_VatCode      = x.VatCode
	,	Matched_ReferenceXML = x.ReferenceXML
	FROM tb_Bank_Transactions t
	JOIN #t x ON x.BPA_EntryID = t.BPA_EntryID;

	-- 4. Vendor payment header
	INSERT INTO tb_Netsuite_VendorPayment
	(
		BPA_EntryID, BPA_Origin, BPA_Direction, BPA_Action, BPA_Status, BPA_Company,
		BPA_Reference, BPA_Orig_Entryid, BPA_Syscreator, id,
		externalId, entityId, subsidiaryId, accountId, apAcctId, currencyId,
		tranDate, memo, toBeEmailed, toBePrinted
	)
	SELECT
		NewEntryID, BPA_Origin, 'TO', 'I', 0, @BPA_Company,
		LEFT(ExternalID, 50), BPA_EntryID, @Creator, '',
		ExternalID, vendor_id, SubsidiaryID, BankAccountID, APAccountID, CurrencyID,
		CONVERT(varchar(10), Bookdate, 23), Memo, 0, 0
	FROM #vp
	WHERE SkipReason IS NULL;

	-- One apply line: the matched bill, for the amount paid at the bank
	INSERT INTO tb_Netsuite_VendorPayment_Apply
	(
		BPA_EntryID, BPA_ParentID, BPA_Origin, BPA_Direction, BPA_Action, BPA_Status, BPA_Company,
		BPA_Reference, BPA_Orig_Entryid, BPA_Syscreator,
		line, doc_id, refNum, amount, apply
	)
	SELECT
		NEWID(), NewEntryID, BPA_Origin, 'TO', 'I', 0, @BPA_Company,
		LEFT(ExternalID, 50), BPA_EntryID, @Creator,
		0, VendorBillID, BillNumber, PayAmount, 1
	FROM #vp
	WHERE SkipReason IS NULL;

	-- 5. Bank transaction done, linked to the vendor payment
	UPDATE t
	SET BPA_Status = 1,
		BPA_ReturnedID = p.NewEntryID
	FROM tb_Bank_Transactions t
	JOIN #vp p ON p.BPA_EntryID = t.BPA_EntryID
	WHERE p.SkipReason IS NULL;

	COMMIT TRANSACTION;
END

-- 6. Report
SELECT
	Scenario
,	CASE WHEN Scenario <> 'VENDORPAYMENT' THEN 'not handled yet'
		 WHEN p.SkipReason IS NOT NULL     THEN 'skipped'
		 WHEN @Preview = 1                 THEN 'would be created'
		 ELSE 'created' END                AS Result
,	COUNT(*)                               AS transactions
FROM #t x
LEFT JOIN #vp p ON p.BPA_EntryID = x.BPA_EntryID
GROUP BY Scenario,
	CASE WHEN Scenario <> 'VENDORPAYMENT' THEN 'not handled yet'
		 WHEN p.SkipReason IS NOT NULL     THEN 'skipped'
		 WHEN @Preview = 1                 THEN 'would be created'
		 ELSE 'created' END
ORDER BY Scenario, Result;

SELECT
	BPA_EntryID, Bookdate, Amount, Currency, Memo, typematch,
	vendor_id, BillNumber, VendorBillID, BillAmountOpen, PayAmount,
	ExternalID, NewEntryID AS VendorPaymentEntryID, SkipReason
FROM #vp
ORDER BY CASE WHEN SkipReason IS NULL THEN 0 ELSE 1 END, Bookdate, BPA_EntryID;
GO
