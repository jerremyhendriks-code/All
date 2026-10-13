USE [BPAStaging]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
/*
    sp_Bank_Netsuite_FinancialEntry_Create_V2

    New version of sp_Bank_Netsuite_FinancialEntry_Create; the original stays as it is
    (backup) until this one replaces it.

    Bank engine for Ellomay: turns open bank transactions (tb_Bank_Transactions,
    BPA_Status = 0) into NetSuite records. Three scenarios, decided by fn_Bank_Match_V2:

        typematch                       Matched_Creditor  Matched_Debtor  Matched_Reference  -> scenario
        PurchaseInvoice / ...Amount     filled            -               bill number        -> VENDORPAYMENT    (built)
        Sales...                        -                 filled          invoice number     -> CUSTOMERPAYMENT  (to do)
                                                                          or ReferenceXML
        anything else                                                                        -> JOURNALENTRY     (to do)

    Transactions in a scenario that isn't built yet stay BPA_Status = 0.

    1. Match all open transactions of @BPA_Company with fn_Bank_Match_V2 (fills Matched_*).
    2. A cursor walks the open transactions, oldest first; one NetSuite record per transaction.
       VENDORPAYMENT:
       - Look up the vendor bill by Matched_Creditor + bill number (Matched_Reference)
         -> vendor_bill_id (latest loaded row per bill), and the bank account's NetSuite IDs.
       - Skip (and report) when something is missing or unsafe; the transaction stays open:
         money coming in, bill not found or found twice, bill paid / open amount too small,
         other subsidiary or currency than the bank account, missing NetSuite IDs,
         the externalId is already staged, or the bill already waits in an unsent
         vendor payment (also one made earlier in this run: first transaction wins).
       - In one transaction: tb_Netsuite_VendorPayment (header) + tb_Netsuite_VendorPayment_Apply
         (one line: the bill, amount = ABS(bank amount)), BPA_Direction 'TO', BPA_Status 0;
         bank transaction BPA_Status = 1, BPA_ReturnedID = BPA_EntryID of the payment header.
       An error on one transaction rolls back only that transaction; it is reported and
       the cursor moves on.
    3. Report: count per scenario/result, then the details of the vendor payments and errors.

    NetSuite internal IDs per bank account (hard-coded per IBAN in vw_Bank_BankAccounts):
        Company               = subsidiary ID
        GLCodeBank            = bank GL account ID   -> accountId
        DefaultGLCodeCreditor = AP account ID        -> apAcctId
    externalId = 'BANK-<own IBAN>-<bank BPA_Reference>', so NetSuite refuses a second copy.
    id is NOT NULL without a default: sent as '' and filled once NetSuite has created the payment.

    Run:
        EXEC sp_Bank_Netsuite_FinancialEntry_Create_V2 '501';
        EXEC sp_Bank_Netsuite_FinancialEntry_Create_V2 '501', @Preview = 1;      -- only matches (Matched_*), creates nothing
        EXEC sp_Bank_Netsuite_FinancialEntry_Create_V2 '501', @BPA_EntryID = '<one bank transaction>';
*/
CREATE OR ALTER PROCEDURE [dbo].[sp_Bank_Netsuite_FinancialEntry_Create_V2]
(
	@BPA_Company varchar(50)
,	@BPA_EntryID uniqueidentifier = NULL	-- NULL = all open transactions of @BPA_Company
,	@Preview     bit = 0					-- 1 = match and report, create no NetSuite records
)
AS
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Creator nvarchar(50) = N'sp_Bank_Netsuite_FinancialEntry_Create_V2';

-- 1. Match the open transactions
UPDATE Transactions
SET
	Matched_NewCustomer  = m.NewCustomer
,	Matched_typematch    = m.typematch
,	Matched_GLCode       = m.GLCode
,	Matched_Creditor     = m.vendor_id
,	Matched_Debtor       = m.customer_id
,	Matched_Costcenter   = m.Costcenter
,	Matched_CostUnit     = m.CostUnit
,	Matched_Reference    = m.Reference
,	Matched_VatCode      = m.VatCode
,	Matched_ReferenceXML = m.ReferenceXML
FROM tb_Bank_Transactions Transactions
CROSS APPLY dbo.fn_Bank_Match_V2('BANK', Transactions.BPA_EntryID, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) m
WHERE Transactions.BPA_Status = 0
	AND Transactions.BPA_Company = @BPA_Company
	AND (@BPA_EntryID IS NULL OR Transactions.BPA_EntryID = @BPA_EntryID);

-- What happened to each transaction; the report at the end
IF OBJECT_ID('tempdb..#result') IS NOT NULL DROP TABLE #result;
CREATE TABLE #result
(
	BPA_EntryID          uniqueidentifier NOT NULL
,	Bookdate             datetime         NULL
,	Amount               float            NULL
,	Currency             varchar(20)      NULL
,	Memo                 nvarchar(250)    NULL
,	typematch            nvarchar(50)     NULL
,	Scenario             varchar(20)      NULL
,	vendor_id            nvarchar(100)    NULL
,	BillNumber           nvarchar(60)     NULL
,	VendorBillID         nvarchar(100)    NULL
,	BillAmountOpen       decimal(18, 2)   NULL
,	PayAmount            decimal(18, 2)   NULL
,	ExternalID           nvarchar(255)    NULL
,	NetsuiteEntryID      uniqueidentifier NULL
,	Result               varchar(20)      NOT NULL	-- created / would be created / skipped / not handled yet / error
,	Reason               nvarchar(2048)   NULL
);

DECLARE
	-- bank transaction + its match
	@EntryID          uniqueidentifier
,	@Origin           nvarchar(100)
,	@Bookdate         datetime
,	@Amount           float
,	@Currency         varchar(20)
,	@Memo             nvarchar(250)
,	@ExternalID       nvarchar(255)
,	@typematch        nvarchar(50)
,	@Creditor         nvarchar(100)
,	@Debtor           nvarchar(100)
,	@Reference        nvarchar(60)
,	@HasReferenceXML  bit
,	@Scenario         varchar(20)
	-- NetSuite IDs
,	@SubsidiaryID     nvarchar(100)
,	@BankAccountID    nvarchar(100)
,	@APAccountID      nvarchar(100)
,	@CurrencyID       nvarchar(100)
,	@BillsFound       int
,	@VendorBillID     nvarchar(100)
,	@BillAmountOpen   decimal(18, 2)
,	@BillSubsidiaryID nvarchar(100)
,	@BillCurrencyID   nvarchar(100)
,	@PayAmount        decimal(18, 2)
,	@NewEntryID       uniqueidentifier
,	@Reason           nvarchar(2048);

-- 2. One pass per bank transaction.
--    STATIC: the list and its values are fixed at OPEN; BPA_Status changes inside the loop.
DECLARE Transaction_Cursor CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
	SELECT
		t.BPA_EntryID
	,	t.BPA_Origin
	,	t.Bookdate
	,	t.Amount
	,	t.Currency
	,	LEFT(COALESCE(t.Description, t.Kenmerk, t.Betalingskenmerk, ''), 250)
	,	'BANK-' + t.BPA_Origin + '-' + t.BPA_Reference
	,	t.Matched_typematch
	,	t.Matched_Creditor
	,	t.Matched_Debtor
	,	LTRIM(RTRIM(t.Matched_Reference))
	,	CASE WHEN t.Matched_ReferenceXML IS NOT NULL THEN 1 ELSE 0 END
	FROM tb_Bank_Transactions t
	WHERE t.BPA_Status = 0
		AND t.BPA_Company = @BPA_Company
		AND (@BPA_EntryID IS NULL OR t.BPA_EntryID = @BPA_EntryID)
	ORDER BY t.Bookdate, t.BPA_EntryID;

OPEN Transaction_Cursor;
FETCH NEXT FROM Transaction_Cursor INTO
	@EntryID, @Origin, @Bookdate, @Amount, @Currency, @Memo, @ExternalID,
	@typematch, @Creditor, @Debtor, @Reference, @HasReferenceXML;

WHILE @@FETCH_STATUS = 0
BEGIN
	-- A SELECT that finds no row leaves a variable as it was: start every transaction clean
	SELECT
		@SubsidiaryID = NULL, @BankAccountID = NULL, @APAccountID = NULL, @CurrencyID = NULL,
		@BillsFound = 0, @VendorBillID = NULL, @BillAmountOpen = NULL, @BillSubsidiaryID = NULL,
		@BillCurrencyID = NULL, @PayAmount = NULL, @NewEntryID = NULL, @Reason = NULL;

	SET @Scenario =
		CASE
			WHEN @typematch LIKE 'Purchase%' AND @Creditor IS NOT NULL AND @Reference <> ''
				THEN 'VENDORPAYMENT'
			WHEN @typematch LIKE 'Sales%' AND @Debtor IS NOT NULL
				AND (@Reference <> '' OR @HasReferenceXML = 1)
				THEN 'CUSTOMERPAYMENT'
			ELSE 'JOURNALENTRY'
		END;

	BEGIN TRY
		IF @Scenario = 'VENDORPAYMENT'
		BEGIN
			SET @PayAmount = CAST(ROUND(ABS(@Amount), 2) AS decimal(18, 2));

			SELECT
				@SubsidiaryID  = bank.Company
			,	@BankAccountID = bank.GLCodeBank
			,	@APAccountID   = bank.DefaultGLCodeCreditor
			FROM vw_Bank_BankAccounts bank
			WHERE bank.Bankaccount = @Origin COLLATE database_default;

			SELECT TOP 1 @CurrencyID = c.id
			FROM tb_Netsuite_Currency c
			WHERE c.symbol = @Currency
				AND ISNULL(c.isInactive, 0) = 0;

			-- The bill(s) of this vendor with this number; latest loaded row per bill
			SELECT
				@BillsFound       = COUNT(*)
			,	@VendorBillID     = MAX(b.vendor_bill_id)
			,	@BillAmountOpen   = MAX(b.amount_open)
			,	@BillSubsidiaryID = MAX(b.subsidiary_id)
			,	@BillCurrencyID   = MAX(b.currency_id)
			FROM (
				SELECT
					CAST(v.vendor_bill_id AS nvarchar(100))                 AS vendor_bill_id
				,	TRY_CAST(v.amount_open AS decimal(18, 2))               AS amount_open
				,	CAST(v.subsidiary_id AS nvarchar(100))                  AS subsidiary_id
				,	CAST(v.currency_id AS nvarchar(100))                    AS currency_id
				,	ROW_NUMBER() OVER (PARTITION BY v.vendor_bill_id
									   ORDER BY v.BPA_Syscreated DESC, v.BPA_EntryID DESC) AS rn
				FROM tb_Netsuite_VendorBill v
				WHERE CAST(v.vendor_id AS nvarchar(100)) = @Creditor
					AND LTRIM(RTRIM(v.vendor_bill_number)) = @Reference
			) b
			WHERE b.rn = 1;

			-- Don't send what isn't safe
			SET @Reason =
				CASE
					WHEN @Amount >= 0                         THEN 'Money coming in, not a payment to the vendor'
					WHEN @ExternalID IS NULL                  THEN 'No BPA_Origin / BPA_Reference for the externalId'
					WHEN @BillsFound = 0                      THEN 'Vendor bill ' + @Reference + ' not found for vendor ' + @Creditor
					WHEN @BillsFound > 1                      THEN 'Vendor ' + @Creditor + ' has ' + CAST(@BillsFound AS varchar(10)) + ' bills numbered ' + @Reference
					WHEN @BillAmountOpen IS NULL
					  OR @BillAmountOpen <= 0                 THEN 'Vendor bill ' + @Reference + ' is not open'
					WHEN @PayAmount - @BillAmountOpen > 0.005 THEN 'Payment ' + CAST(@PayAmount AS varchar(20)) + ' is more than open amount ' + CAST(@BillAmountOpen AS varchar(20))
					WHEN @SubsidiaryID IS NULL                THEN 'No subsidiary (Company) for bank account ' + ISNULL(@Origin, '')
					WHEN @BankAccountID IS NULL               THEN 'No GLCodeBank for bank account ' + ISNULL(@Origin, '')
					WHEN @APAccountID IS NULL                 THEN 'No AP account (DefaultGLCodeCreditor) for bank account ' + ISNULL(@Origin, '')
					WHEN @CurrencyID IS NULL                  THEN 'Unknown currency ' + ISNULL(@Currency, '')
					WHEN @BillSubsidiaryID <> @SubsidiaryID   THEN 'Bill is in subsidiary ' + @BillSubsidiaryID + ', bank account in ' + @SubsidiaryID
					WHEN @BillCurrencyID <> @CurrencyID       THEN 'Bill currency ' + @BillCurrencyID + ' differs from bank currency ' + @CurrencyID
					WHEN EXISTS (SELECT 1 FROM tb_Netsuite_VendorPayment h
								 WHERE h.externalId = @ExternalID)
					                                          THEN 'Already staged as vendor payment ' + @ExternalID
					WHEN EXISTS (SELECT 1
								 FROM tb_Netsuite_VendorPayment_Apply a
								 JOIN tb_Netsuite_VendorPayment h ON h.BPA_EntryID = a.BPA_ParentID
								 WHERE a.doc_id = @VendorBillID
									AND h.BPA_Direction = 'TO'
									AND h.BPA_Status = 0)
					  OR EXISTS (SELECT 1 FROM #result r	-- earlier in this run (needed for @Preview = 1)
								 WHERE r.VendorBillID = @VendorBillID
									AND r.Result IN ('created', 'would be created'))
					                                          THEN 'Bill ' + @Reference + ' is already in a vendor payment that is not sent yet'
				END;

			IF @Reason IS NULL AND @Preview = 0
			BEGIN
				SET @NewEntryID = NEWID();

				BEGIN TRANSACTION;

				INSERT INTO tb_Netsuite_VendorPayment
				(
					BPA_EntryID, BPA_Origin, BPA_Direction, BPA_Action, BPA_Status, BPA_Company,
					BPA_Reference, BPA_Orig_Entryid, BPA_Syscreator, id,
					externalId, entityId, subsidiaryId, accountId, apAcctId, currencyId,
					tranDate, memo, toBeEmailed, toBePrinted
				)
				VALUES
				(
					@NewEntryID, @Origin, 'TO', 'I', 0, @BPA_Company,
					LEFT(@ExternalID, 50), @EntryID, @Creator, '',
					@ExternalID, @Creditor, @SubsidiaryID, @BankAccountID, @APAccountID, @CurrencyID,
					CONVERT(varchar(10), @Bookdate, 23), @Memo, 0, 0
				);

				-- One apply line: the matched bill, for the amount paid at the bank
				INSERT INTO tb_Netsuite_VendorPayment_Apply
				(
					BPA_EntryID, BPA_ParentID, BPA_Origin, BPA_Direction, BPA_Action, BPA_Status, BPA_Company,
					BPA_Reference, BPA_Orig_Entryid, BPA_Syscreator,
					line, doc_id, refNum, amount, apply
				)
				VALUES
				(
					NEWID(), @NewEntryID, @Origin, 'TO', 'I', 0, @BPA_Company,
					LEFT(@ExternalID, 50), @EntryID, @Creator,
					0, @VendorBillID, @Reference, @PayAmount, 1
				);

				-- Bank transaction done; BPA_ReturnedID leads back to the NetSuite record
				UPDATE tb_Bank_Transactions
				SET BPA_Status = 1,
					BPA_ReturnedID = @NewEntryID
				WHERE BPA_EntryID = @EntryID;

				COMMIT TRANSACTION;
			END
		END

		-- CUSTOMERPAYMENT and JOURNALENTRY: to do, the transaction stays open

		INSERT INTO #result
		(
			BPA_EntryID, Bookdate, Amount, Currency, Memo, typematch, Scenario,
			vendor_id, BillNumber, VendorBillID, BillAmountOpen, PayAmount, ExternalID,
			NetsuiteEntryID, Result, Reason
		)
		VALUES
		(
			@EntryID, @Bookdate, @Amount, @Currency, @Memo, @typematch, @Scenario,
			@Creditor, @Reference, @VendorBillID, @BillAmountOpen, @PayAmount, @ExternalID,
			@NewEntryID,
			CASE WHEN @Scenario <> 'VENDORPAYMENT' THEN 'not handled yet'
				 WHEN @Reason IS NOT NULL          THEN 'skipped'
				 WHEN @Preview = 1                 THEN 'would be created'
				 ELSE 'created' END,
			@Reason
		);
	END TRY
	BEGIN CATCH
		IF XACT_STATE() <> 0
			ROLLBACK TRANSACTION;

		INSERT INTO #result
		(
			BPA_EntryID, Bookdate, Amount, Currency, Memo, typematch, Scenario,
			vendor_id, BillNumber, VendorBillID, ExternalID, Result, Reason
		)
		VALUES
		(
			@EntryID, @Bookdate, @Amount, @Currency, @Memo, @typematch, @Scenario,
			@Creditor, @Reference, @VendorBillID, @ExternalID, 'error',
			ERROR_MESSAGE() + ' (line ' + CAST(ERROR_LINE() AS varchar(10)) + ')'
		);
	END CATCH

	FETCH NEXT FROM Transaction_Cursor INTO
		@EntryID, @Origin, @Bookdate, @Amount, @Currency, @Memo, @ExternalID,
		@typematch, @Creditor, @Debtor, @Reference, @HasReferenceXML;
END

CLOSE Transaction_Cursor;
DEALLOCATE Transaction_Cursor;

-- 3. Report
SELECT Scenario, Result, COUNT(*) AS transactions
FROM #result
GROUP BY Scenario, Result
ORDER BY Scenario, Result;

SELECT
	BPA_EntryID, Bookdate, Amount, Currency, Memo, typematch, Scenario,
	vendor_id, BillNumber, VendorBillID, BillAmountOpen, PayAmount,
	ExternalID, NetsuiteEntryID, Result, Reason
FROM #result
WHERE Scenario = 'VENDORPAYMENT' OR Result = 'error'
ORDER BY CASE Result WHEN 'error' THEN 0 WHEN 'skipped' THEN 1 ELSE 2 END, Bookdate, BPA_EntryID;
GO
