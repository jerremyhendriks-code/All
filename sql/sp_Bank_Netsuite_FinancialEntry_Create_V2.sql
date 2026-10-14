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
        PurchaseInvoice / ...Amount     filled            -               bill number        -> VENDORPAYMENT
        Sales...                        -                 filled          invoice number     -> CUSTOMERPAYMENT
                                                                          or ReferenceXML
        anything else                                                                        -> JOURNALENTRY

    0. Refresh the open bills / invoices fn_Bank_Match_V2 matches against:
       sp_Bank_Netsuite_Synchronise_Company @BPA_Company, 'OPEN'.
    1. Match all open transactions of @BPA_Company with fn_Bank_Match_V2 (fills Matched_*).
    2. A cursor walks the open transactions, oldest first; one NetSuite record per transaction.

       VENDORPAYMENT    tb_Netsuite_VendorPayment + _Apply (one line: the bill, ABS(bank amount)).
                        Bill = Matched_Creditor + bill number, latest loaded row per bill.
       CUSTOMERPAYMENT  tb_Netsuite_CustomerPayment + _Apply, paid into the bank GL account.
                        One invoice (Matched_Reference): one line for the bank amount.
                        A list (Matched_ReferenceXML): one line per invoice for its open amount;
                        the open amounts must add up to the bank amount.
       JOURNALENTRY     tb_Netsuite_JournalEntry + _Line, two lines:
                        line 0  bank GL account   (money in = debit, money out = credit)
                        line 1  the other side:
                                vendor known   -> AP account, entity = vendor
                                customer known -> AR account, entity = customer
                                nothing known  -> suspense account: UnknownCreditor (money out)
                                                  or UnknownDebtor (money in)

       Skipped (and reported, the transaction stays open) when something is missing or unsafe:
       wrong direction for the scenario, document not found or found twice, document not open or
       open amount too small, other subsidiary or currency than the bank account, a missing
       NetSuite ID (bank / AP / AR / suspense account, subsidiary, currency), the externalId is
       already staged, or a document already waits in an unsent payment (also one made earlier
       in this run: first transaction wins).

       Created: the NetSuite record(s) with BPA_Direction 'TO', BPA_Action 'A' (add), BPA_Status 0, and the bank
       transaction BPA_Status = 1, BPA_ReturnedID = BPA_EntryID of the NetSuite header, all in one
       transaction. An error on one bank transaction rolls back only that one; it is reported and
       the cursor moves on.
    3. Report: count per scenario/result, then every transaction with what happened.

    NetSuite internal IDs per bank account (hard-coded per IBAN in vw_Bank_BankAccounts):
        Company               = subsidiary ID
        GLCodeBank            = bank GL account ID   -> accountId (payments), line 0 (journals)
        DefaultGLCodeCreditor = AP account ID        -> apAcctId, journal line 1 for a vendor
        DefaultGLCodeDebtor   = AR account ID        -> aracctId, journal line 1 for a customer
        UnknownCreditor / UnknownDebtor = suspense accounts for journals without a relation
    externalId = 'BANK-<own IBAN>-<bank BPA_Reference>', so NetSuite refuses a second copy.
    id is NOT NULL without a default: sent as '' and filled once NetSuite has created the record.

    Run:
        EXEC sp_Bank_Netsuite_FinancialEntry_Create_V2 '89';
        EXEC sp_Bank_Netsuite_FinancialEntry_Create_V2 '89', @Preview = 1;      -- only matches (Matched_*), creates nothing
        EXEC sp_Bank_Netsuite_FinancialEntry_Create_V2 '89', @BPA_EntryID = '<one bank transaction>';
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

-- 0. Open bills / invoices of this subsidiary, as they are now (incl. payments made in earlier runs)
--    INSERT ... EXEC keeps its count report out of this procedure's results.
DECLARE @OpenCounts TABLE (Company varchar(50), open_vendor_bills int, open_invoices int);
INSERT INTO @OpenCounts
EXEC dbo.sp_Bank_Netsuite_Synchronise_Company @BPA_Company, 'OPEN';

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
,	RelationID           nvarchar(100)    NULL	-- vendor or customer
,	Documents            nvarchar(max)    NULL	-- bill / invoice number(s)
,	DocumentIDs          nvarchar(max)    NULL	-- their NetSuite internal IDs
,	DocAmountOpen        decimal(18, 2)   NULL	-- open amount of the document(s)
,	PayAmount            decimal(18, 2)   NULL
,	OffsetAccountID      nvarchar(100)    NULL	-- journal entry line 1
,	ExternalID           nvarchar(255)    NULL
,	NetsuiteEntryID      uniqueidentifier NULL
,	Result               varchar(20)      NOT NULL	-- created / would be created / skipped / error
,	Reason               nvarchar(2048)   NULL
);

-- The invoices of the customer payment being handled (one, or a list from Matched_ReferenceXML)
IF OBJECT_ID('tempdb..#docs') IS NOT NULL DROP TABLE #docs;
CREATE TABLE #docs
(
	line                 int IDENTITY(0, 1) NOT NULL
,	doc_number           nvarchar(100)    NOT NULL
,	found                int              NULL	-- rows (= invoices) with this number for the customer
,	doc_id               nvarchar(100)    NULL
,	amount_open          decimal(18, 2)   NULL
,	subsidiary_id        nvarchar(100)    NULL
,	currency_id          nvarchar(100)    NULL
,	apply_amount         decimal(18, 2)   NULL
);

-- Bills / invoices paid in this run, so a second transaction can't pay them again
IF OBJECT_ID('tempdb..#used_docs') IS NOT NULL DROP TABLE #used_docs;
CREATE TABLE #used_docs
(
	doc_type             varchar(20)      NOT NULL	-- VENDORBILL / INVOICE
,	doc_id               nvarchar(100)    NOT NULL
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
,	@ReferenceXML     xml
,	@Scenario         varchar(20)
	-- bank account settings
,	@SubsidiaryID     nvarchar(100)
,	@BankAccountID    nvarchar(100)
,	@APAccountID      nvarchar(100)
,	@ARAccountID      nvarchar(100)
,	@UnknownCreditor  nvarchar(100)
,	@UnknownDebtor    nvarchar(100)
,	@CurrencyID       nvarchar(100)
	-- documents
,	@BillsFound       int
,	@VendorBillID     nvarchar(100)
,	@BillAmountOpen   decimal(18, 2)
,	@BillSubsidiaryID nvarchar(100)
,	@BillCurrencyID   nvarchar(100)
,	@DocCount         int
,	@DocAmountOpen    decimal(18, 2)
,	@Documents        nvarchar(max)
,	@DocumentIDs      nvarchar(max)
	-- journal entry
,	@OffsetAccountID  nvarchar(100)
,	@EntityID         nvarchar(100)
	-- result
,	@PayAmount        decimal(18, 2)
,	@StagedAs         nvarchar(50)
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
	,	CAST(t.Matched_ReferenceXML AS xml)
	FROM tb_Bank_Transactions t
	WHERE t.BPA_Status = 0
		AND t.BPA_Company = @BPA_Company
		AND (@BPA_EntryID IS NULL OR t.BPA_EntryID = @BPA_EntryID)
	ORDER BY t.Bookdate, t.BPA_EntryID;

OPEN Transaction_Cursor;
FETCH NEXT FROM Transaction_Cursor INTO
	@EntryID, @Origin, @Bookdate, @Amount, @Currency, @Memo, @ExternalID,
	@typematch, @Creditor, @Debtor, @Reference, @ReferenceXML;

WHILE @@FETCH_STATUS = 0
BEGIN
	-- A SELECT that finds no row leaves a variable as it was: start every transaction clean
	SELECT
		@SubsidiaryID = NULL, @BankAccountID = NULL, @APAccountID = NULL, @ARAccountID = NULL,
		@UnknownCreditor = NULL, @UnknownDebtor = NULL, @CurrencyID = NULL,
		@BillsFound = 0, @VendorBillID = NULL, @BillAmountOpen = NULL, @BillSubsidiaryID = NULL,
		@BillCurrencyID = NULL, @DocCount = 0, @DocAmountOpen = NULL, @Documents = NULL, @DocumentIDs = NULL,
		@OffsetAccountID = NULL, @EntityID = NULL, @PayAmount = NULL, @StagedAs = NULL,
		@NewEntryID = NULL, @Reason = NULL;

	SET @Scenario =
		CASE
			WHEN @typematch LIKE 'Purchase%' AND @Creditor IS NOT NULL AND @Reference <> ''
				THEN 'VENDORPAYMENT'
			WHEN @typematch LIKE 'Sales%' AND @Debtor IS NOT NULL
				AND (@Reference <> '' OR @ReferenceXML IS NOT NULL)
				THEN 'CUSTOMERPAYMENT'
			ELSE 'JOURNALENTRY'
		END;

	BEGIN TRY
		-- Common: amount, bank account settings, currency, already staged?
		SET @PayAmount = CAST(ROUND(ABS(@Amount), 2) AS decimal(18, 2));

		SELECT
			@SubsidiaryID    = bank.Company
		,	@BankAccountID   = bank.GLCodeBank
		,	@APAccountID     = bank.DefaultGLCodeCreditor
		,	@ARAccountID     = bank.DefaultGLCodeDebtor
		,	@UnknownCreditor = bank.UnknownCreditor
		,	@UnknownDebtor   = bank.UnknownDebtor
		FROM vw_Bank_BankAccounts bank
		WHERE bank.Bankaccount = @Origin COLLATE database_default;

		SELECT TOP 1 @CurrencyID = c.id
		FROM tb_Netsuite_Currency c
		WHERE c.symbol = @Currency
			AND ISNULL(c.isInactive, 0) = 0;

		SET @StagedAs =
			CASE
				WHEN EXISTS (SELECT 1 FROM tb_Netsuite_VendorPayment   WHERE externalId = @ExternalID) THEN N'vendor payment'
				WHEN EXISTS (SELECT 1 FROM tb_Netsuite_CustomerPayment WHERE externalId = @ExternalID) THEN N'customer payment'
				WHEN EXISTS (SELECT 1 FROM tb_Netsuite_JournalEntry    WHERE externalId = @ExternalID) THEN N'journal entry'
			END;

		------------------------------------------------------------------------------------
		IF @Scenario = 'VENDORPAYMENT'
		BEGIN
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

			SELECT @Documents = @Reference, @DocumentIDs = @VendorBillID, @DocAmountOpen = @BillAmountOpen;

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
					WHEN @StagedAs IS NOT NULL                THEN 'Already staged as ' + @StagedAs + ' ' + @ExternalID
					WHEN EXISTS (SELECT 1
								 FROM tb_Netsuite_VendorPayment_Apply a
								 JOIN tb_Netsuite_VendorPayment h ON h.BPA_EntryID = a.BPA_ParentID
								 WHERE a.doc_id = @VendorBillID
									AND h.BPA_Direction = 'TO'
									AND h.BPA_Status = 0)
					  OR EXISTS (SELECT 1 FROM #used_docs u WHERE u.doc_type = 'VENDORBILL' AND u.doc_id = @VendorBillID)
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
					@NewEntryID, @Origin, 'TO', 'A', 0, @BPA_Company,
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
					NEWID(), @NewEntryID, @Origin, 'TO', 'A', 0, @BPA_Company,
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

			IF @Reason IS NULL
				INSERT INTO #used_docs (doc_type, doc_id) VALUES ('VENDORBILL', @VendorBillID);

			SET @EntityID = @Creditor;
		END

		------------------------------------------------------------------------------------
		ELSE IF @Scenario = 'CUSTOMERPAYMENT'
		BEGIN
			-- The invoice(s): one number in Matched_Reference, or a list in Matched_ReferenceXML
			TRUNCATE TABLE #docs;	-- also restarts line at 0

			IF @Reference <> ''
				INSERT INTO #docs (doc_number) VALUES (@Reference);
			ELSE
				INSERT INTO #docs (doc_number)
				SELECT DISTINCT LTRIM(RTRIM(n.c.value('.', 'nvarchar(100)')))
				FROM @ReferenceXML.nodes('/Invoices/invoice_number') n(c);

			-- Each invoice of this customer with this number; latest loaded row per invoice
			UPDATE d
			SET found         = x.invoices
			,	doc_id        = x.invoice_id
			,	amount_open   = x.amount_open
			,	subsidiary_id = x.subsidiary_id
			,	currency_id   = x.currency_id
			FROM #docs d
			CROSS APPLY (
				SELECT
					COUNT(*)              AS invoices
				,	MAX(i.invoice_id)     AS invoice_id
				,	MAX(i.amount_open)    AS amount_open
				,	MAX(i.subsidiary_id)  AS subsidiary_id
				,	MAX(i.currency_id)    AS currency_id
				FROM (
					SELECT
						CAST(inv.invoice_id AS nvarchar(100))               AS invoice_id
					,	TRY_CAST(inv.amount_open AS decimal(18, 2))         AS amount_open
					,	CAST(inv.subsidiary_id AS nvarchar(100))            AS subsidiary_id
					,	CAST(inv.currency_id AS nvarchar(100))              AS currency_id
					,	ROW_NUMBER() OVER (PARTITION BY inv.invoice_id
										   ORDER BY inv.BPA_Syscreated DESC, inv.BPA_EntryID DESC) AS rn
					FROM tb_Netsuite_Invoice inv
					WHERE CAST(inv.customer_id AS nvarchar(100)) = @Debtor
						AND LTRIM(RTRIM(inv.invoice_number)) = d.doc_number
				) i
				WHERE i.rn = 1
			) x;

			SELECT @DocCount = COUNT(*), @DocAmountOpen = SUM(amount_open) FROM #docs;

			-- One invoice: the bank amount. A list: each invoice for its open amount.
			UPDATE #docs SET apply_amount = CASE WHEN @DocCount = 1 THEN @PayAmount ELSE amount_open END;

			SELECT
				@Documents   = STUFF((SELECT N', ' + doc_number FROM #docs ORDER BY line
									  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'')
			,	@DocumentIDs = STUFF((SELECT N', ' + ISNULL(doc_id, N'?') FROM #docs ORDER BY line
									  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

			-- Don't send what isn't safe
			SET @Reason =
				CASE
					WHEN @Amount <= 0                         THEN 'Money going out, not a payment from the customer'
					WHEN @ExternalID IS NULL                  THEN 'No BPA_Origin / BPA_Reference for the externalId'
					WHEN @DocCount = 0                        THEN 'No invoice number in the match'
					WHEN EXISTS (SELECT 1 FROM #docs WHERE found = 0)
					                                          THEN 'Invoice ' + (SELECT TOP 1 doc_number FROM #docs WHERE found = 0 ORDER BY line)
					                                               + ' not found for customer ' + @Debtor
					WHEN EXISTS (SELECT 1 FROM #docs WHERE found > 1)
					                                          THEN 'Customer ' + @Debtor + ' has more than one invoice numbered '
					                                               + (SELECT TOP 1 doc_number FROM #docs WHERE found > 1 ORDER BY line)
					WHEN EXISTS (SELECT 1 FROM #docs WHERE amount_open IS NULL OR amount_open <= 0)
					                                          THEN 'Invoice ' + (SELECT TOP 1 doc_number FROM #docs WHERE amount_open IS NULL OR amount_open <= 0 ORDER BY line)
					                                               + ' is not open'
					WHEN @DocCount = 1 AND @PayAmount - @DocAmountOpen > 0.005
					                                          THEN 'Payment ' + CAST(@PayAmount AS varchar(20)) + ' is more than open amount ' + CAST(@DocAmountOpen AS varchar(20))
					WHEN @DocCount > 1 AND ABS(@PayAmount - @DocAmountOpen) > 0.005
					                                          THEN 'Invoices add up to ' + CAST(@DocAmountOpen AS varchar(20)) + ', payment is ' + CAST(@PayAmount AS varchar(20))
					WHEN @SubsidiaryID IS NULL                THEN 'No subsidiary (Company) for bank account ' + ISNULL(@Origin, '')
					WHEN @BankAccountID IS NULL               THEN 'No GLCodeBank for bank account ' + ISNULL(@Origin, '')
					WHEN @ARAccountID IS NULL                 THEN 'No AR account (DefaultGLCodeDebtor) for bank account ' + ISNULL(@Origin, '')
					WHEN @CurrencyID IS NULL                  THEN 'Unknown currency ' + ISNULL(@Currency, '')
					WHEN EXISTS (SELECT 1 FROM #docs WHERE subsidiary_id <> @SubsidiaryID)
					                                          THEN 'Invoice ' + (SELECT TOP 1 doc_number FROM #docs WHERE subsidiary_id <> @SubsidiaryID ORDER BY line)
					                                               + ' is in another subsidiary than bank account ' + @Origin + ' (' + @SubsidiaryID + ')'
					WHEN EXISTS (SELECT 1 FROM #docs WHERE currency_id <> @CurrencyID)
					                                          THEN 'Invoice ' + (SELECT TOP 1 doc_number FROM #docs WHERE currency_id <> @CurrencyID ORDER BY line)
					                                               + ' has another currency than the bank (' + @Currency + ')'
					WHEN @StagedAs IS NOT NULL                THEN 'Already staged as ' + @StagedAs + ' ' + @ExternalID
					WHEN EXISTS (SELECT 1
								 FROM #docs d
								 JOIN tb_Netsuite_CustomerPayment_Apply a ON a.docId = d.doc_id
								 JOIN tb_Netsuite_CustomerPayment h ON h.BPA_EntryID = a.BPA_ParentID
								 WHERE h.BPA_Direction = 'TO'
									AND h.BPA_Status = 0)
					  OR EXISTS (SELECT 1
								 FROM #docs d
								 JOIN #used_docs u ON u.doc_type = 'INVOICE' AND u.doc_id = d.doc_id)
					                                          THEN 'Invoice(s) ' + @Documents + ': already in a customer payment that is not sent yet'
				END;

			IF @Reason IS NULL AND @Preview = 0
			BEGIN
				SET @NewEntryID = NEWID();

				BEGIN TRANSACTION;

				-- Paid straight into the bank GL account
				INSERT INTO tb_Netsuite_CustomerPayment
				(
					BPA_EntryID, BPA_Origin, BPA_Direction, BPA_Action, BPA_Status, BPA_Company,
					BPA_Reference, BPA_Orig_Entryid, BPA_Syscreator, id,
					externalId, customerId, subsidiaryId, accountId, aracctId, currencyId,
					payment, tranDate, memo, toBeEmailed
				)
				VALUES
				(
					@NewEntryID, @Origin, 'TO', 'A', 0, @BPA_Company,
					LEFT(@ExternalID, 50), @EntryID, @Creator, '',
					@ExternalID, @Debtor, @SubsidiaryID, @BankAccountID, @ARAccountID, @CurrencyID,
					@PayAmount, CAST(@Bookdate AS date), @Memo, 0
				);

				-- One apply line per invoice
				INSERT INTO tb_Netsuite_CustomerPayment_Apply
				(
					BPA_EntryID, BPA_ParentID, BPA_Origin, BPA_Direction, BPA_Action, BPA_Status, BPA_Company,
					BPA_Reference, BPA_Orig_Entryid, BPA_Syscreator,
					line, docId, refNum, amount, apply
				)
				SELECT
					NEWID(), @NewEntryID, @Origin, 'TO', 'A', 0, @BPA_Company,
					LEFT(@ExternalID, 50), @EntryID, @Creator,
					d.line, d.doc_id, d.doc_number, d.apply_amount, 1
				FROM #docs d;

				UPDATE tb_Bank_Transactions
				SET BPA_Status = 1,
					BPA_ReturnedID = @NewEntryID
				WHERE BPA_EntryID = @EntryID;

				COMMIT TRANSACTION;
			END

			IF @Reason IS NULL
				INSERT INTO #used_docs (doc_type, doc_id)
				SELECT 'INVOICE', doc_id FROM #docs;

			SET @EntityID = @Debtor;
		END

		------------------------------------------------------------------------------------
		ELSE	-- JOURNALENTRY
		BEGIN
			-- The other side: AP / AR for a known relation, else the suspense account
			SELECT
				@EntityID        = COALESCE(@Creditor, @Debtor)
			,	@OffsetAccountID =
					CASE
						WHEN @Creditor IS NOT NULL THEN @APAccountID
						WHEN @Debtor   IS NOT NULL THEN @ARAccountID
						WHEN @Amount < 0           THEN @UnknownCreditor
						ELSE                            @UnknownDebtor
					END;

			SET @Reason =
				CASE
					WHEN @Amount = 0 OR @Amount IS NULL       THEN 'Amount is 0'
					WHEN @ExternalID IS NULL                  THEN 'No BPA_Origin / BPA_Reference for the externalId'
					WHEN @SubsidiaryID IS NULL                THEN 'No subsidiary (Company) for bank account ' + ISNULL(@Origin, '')
					WHEN @BankAccountID IS NULL               THEN 'No GLCodeBank for bank account ' + ISNULL(@Origin, '')
					WHEN @CurrencyID IS NULL                  THEN 'Unknown currency ' + ISNULL(@Currency, '')
					WHEN @OffsetAccountID IS NULL             THEN
						CASE
							WHEN @Creditor IS NOT NULL THEN 'No AP account (DefaultGLCodeCreditor) for bank account ' + @Origin
							WHEN @Debtor   IS NOT NULL THEN 'No AR account (DefaultGLCodeDebtor) for bank account ' + @Origin
							WHEN @Amount < 0           THEN 'No suspense account (UnknownCreditor) for bank account ' + @Origin
							ELSE                            'No suspense account (UnknownDebtor) for bank account ' + @Origin
						END
					WHEN @StagedAs IS NOT NULL                THEN 'Already staged as ' + @StagedAs + ' ' + @ExternalID
				END;

			IF @Reason IS NULL AND @Preview = 0
			BEGIN
				SET @NewEntryID = NEWID();

				BEGIN TRANSACTION;

				INSERT INTO tb_Netsuite_JournalEntry
				(
					BPA_EntryID, BPA_Origin, BPA_Direction, BPA_Action, BPA_Status, BPA_Company,
					BPA_Reference, BPA_Orig_Entryid, BPA_Syscreator, id,
					externalId, subsidiaryId, currencyId, tranDate, memo
				)
				VALUES
				(
					@NewEntryID, @Origin, 'TO', 'A', 0, @BPA_Company,
					LEFT(@ExternalID, 50), @EntryID, @Creator, '',
					@ExternalID, @SubsidiaryID, @CurrencyID, CAST(@Bookdate AS date), @Memo
				);

				INSERT INTO tb_Netsuite_JournalEntry_Line
				(
					BPA_EntryID, BPA_ParentID, BPA_Origin, BPA_Direction, BPA_Action, BPA_Status, BPA_Company,
					BPA_Reference, BPA_Orig_Entryid, BPA_Syscreator,
					line, accountId, debit, credit, entityId, memo
				)
				VALUES
				-- Line 0: bank. Money in = debit, money out = credit
				(
					NEWID(), @NewEntryID, @Origin, 'TO', 'A', 0, @BPA_Company,
					LEFT(@ExternalID, 50), @EntryID, @Creator,
					0, @BankAccountID,
					CASE WHEN @Amount > 0 THEN @PayAmount END,
					CASE WHEN @Amount < 0 THEN @PayAmount END,
					NULL, @Memo
				),
				-- Line 1: the other side, with the vendor / customer when known
				(
					NEWID(), @NewEntryID, @Origin, 'TO', 'A', 0, @BPA_Company,
					LEFT(@ExternalID, 50), @EntryID, @Creator,
					1, @OffsetAccountID,
					CASE WHEN @Amount < 0 THEN @PayAmount END,
					CASE WHEN @Amount > 0 THEN @PayAmount END,
					@EntityID, @Memo
				);

				UPDATE tb_Bank_Transactions
				SET BPA_Status = 1,
					BPA_ReturnedID = @NewEntryID
				WHERE BPA_EntryID = @EntryID;

				COMMIT TRANSACTION;
			END
		END

		INSERT INTO #result
		(
			BPA_EntryID, Bookdate, Amount, Currency, Memo, typematch, Scenario,
			RelationID, Documents, DocumentIDs, DocAmountOpen, PayAmount, OffsetAccountID,
			ExternalID, NetsuiteEntryID, Result, Reason
		)
		VALUES
		(
			@EntryID, @Bookdate, @Amount, @Currency, @Memo, @typematch, @Scenario,
			@EntityID, @Documents, @DocumentIDs, @DocAmountOpen, @PayAmount, @OffsetAccountID,
			@ExternalID, @NewEntryID,
			CASE WHEN @Reason IS NOT NULL THEN 'skipped'
				 WHEN @Preview = 1        THEN 'would be created'
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
			RelationID, Documents, ExternalID, Result, Reason
		)
		VALUES
		(
			@EntryID, @Bookdate, @Amount, @Currency, @Memo, @typematch, @Scenario,
			COALESCE(@Creditor, @Debtor), @Documents, @ExternalID, 'error',
			ERROR_MESSAGE() + ' (line ' + CAST(ERROR_LINE() AS varchar(10)) + ')'
		);
	END CATCH

	FETCH NEXT FROM Transaction_Cursor INTO
		@EntryID, @Origin, @Bookdate, @Amount, @Currency, @Memo, @ExternalID,
		@typematch, @Creditor, @Debtor, @Reference, @ReferenceXML;
END

CLOSE Transaction_Cursor;
DEALLOCATE Transaction_Cursor;

-- 3. Report
SELECT Scenario, Result, COUNT(*) AS transactions
FROM #result
GROUP BY Scenario, Result
ORDER BY Scenario, Result;

SELECT
	Result, Reason, Scenario, BPA_EntryID, Bookdate, Amount, Currency, Memo, typematch,
	RelationID, Documents, DocumentIDs, DocAmountOpen, PayAmount, OffsetAccountID,
	ExternalID, NetsuiteEntryID
FROM #result
ORDER BY CASE Result WHEN 'error' THEN 0 WHEN 'skipped' THEN 2 ELSE 1 END, Scenario, Bookdate, BPA_EntryID;
GO
