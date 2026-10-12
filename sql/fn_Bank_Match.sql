/*
    fn_Bank_Match

    Takes one bank transaction and works out who it belongs to:
    1. Load the transaction from tb_Bank_Transactions (when @BPA_Type = 'BANK').
    2. Get the default GL codes for our own bank account.
    3. Look up the other party's IBAN in tb_Netsuite_Bank_account_details
       -> one vendor and/or one customer.
    4. Look for an invoice number in the description -> customer.
       No vendor yet: look for a vendor bill number in the description -> vendor.
    5. Vendor found: find the open vendor bill (by number in description, else by amount).
    6. No customer yet: find a sales invoice by number in description / payment reference.
    7. Customer found: find the open invoice (by number, by amount, by a list of
       invoices that adds up to the amount).
    8. Still both a vendor and a customer: negative amount = vendor, positive = customer.
    9. No GL code yet: use the customer default, else the journal's GL code.

    Amounts are compared to the cent (difference < 0.005) instead of with "=",
    because @Amount is a float. Vendor bills are compared with ABS(@Amount),
    because a payment to a vendor is negative on the bank but positive in amount_open.

    Workflow-rule matching (vw_Bank_Matching) is not active in this version.

    Test with a real transaction:
        SELECT * FROM dbo.fn_Bank_Match('BANK', '7D8EE1D3-C1C3-F111-9386-00155D0A0313',
            NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);

    Test with made-up values (any @BPA_Type other than 'BANK' uses the values you pass):
        SELECT * FROM dbo.fn_Bank_Match('TEST', NULL,
            '<our own bank account>', 'NL20ABNA0881342394', -1609.25, 'EUR',
            '221A', NULL, NULL, NULL, NULL, NULL);
*/
ALTER FUNCTION [dbo].[fn_Bank_Match]
(
	@BPA_Type varchar(10)
,	@BPA_EntryID uniqueidentifier
,	@BankAccount varchar(50)
,	@IBAN varchar(33)
,	@Amount float
,	@Currency varchar(20)
,	@Description varchar(255)
,	@kenmerk varchar(255)
,	@incassant varchar(255)
,	@betalingskenmerk varchar(255)
,	@Machtiging varchar(255)
,	@Mutationcode varchar(5)
)
RETURNS @retreport TABLE
(
	GLCode char(9),
	vendor_id nvarchar(100),
	customer_id nvarchar(100),
	Costcenter varchar(10),
	CostUnit nvarchar(10),
	Reference nvarchar(60),
	typematch nvarchar(50),
	NewCustomer int,
	VatCode nvarchar(10),
	ReferenceXML xml,
	WorkflowNumber int,
	WorkflowID uniqueidentifier
)
AS
BEGIN
	-- 1. Load the transaction
	IF @BPA_Type = 'BANK' AND @BPA_EntryID IS NOT NULL
	BEGIN
		SELECT
			@BankAccount		= g.BPA_Origin
		,	@IBAN				= g.IBAN
		,	@Amount				= g.Amount
		,	@Currency			= g.Currency
		,	@Description		= g.Description
		,	@kenmerk			= g.Kenmerk
		,	@incassant			= g.Incassant
		,	@betalingskenmerk	= g.Betalingskenmerk
		,	@Machtiging			= g.Machtiging
		,	@Mutationcode		= g.Mutationcode
		FROM tb_Bank_Transactions g
		WHERE g.BPA_EntryID = @BPA_EntryID
	END

	DECLARE
		@CompanyID uniqueidentifier,
		@Company nvarchar(50),
		@Journal nvarchar(20),
		@DefaultGLCodevendor_id nvarchar(9),
		@DefaultGLCodecustomer_id nvarchar(9),
		@WorkflowNumber int,
		@WorkflowID uniqueidentifier,
		@ReferenceXML xml,
		@costCenter varchar(10),
		@CostUnit nvarchar(10),
		@vatcode nvarchar(10),
		@Newcustomer bit = 0,
		@typematch varchar(50),
		@vendor_id nvarchar(100),
		@customer_id nvarchar(100),
		@GLCode varchar(9),
		@reference nvarchar(60)

	-- 2. Default GL codes for our own bank account
	SELECT
		@Journal					= Journal
	,	@DefaultGLCodevendor_id		= DefaultGLCodeCreditor
	,	@DefaultGLCodecustomer_id	= DefaultGLCodeDebtor
	,	@CompanyID					= CompanyID
	,	@Company					= Company
	FROM vw_Bank_BankAccounts
	WHERE Bankaccount = @BankAccount

	-- 3. Who owns the other party's IBAN? (spaces and lower case ignored)
	SELECT
		@typematch		= 'IBAN'
	,	@vendor_id		= CASE WHEN COUNT(DISTINCT b.Vendorid) = 1 THEN MAX(b.Vendorid) END
	,	@customer_id	= CASE WHEN COUNT(DISTINCT b.CustomerID) = 1 THEN MAX(b.CustomerID) END
	FROM tb_Netsuite_Bank_account_details b
	WHERE REPLACE(UPPER(b.custrecord_2663_entity_iban), ' ', '') = REPLACE(UPPER(@IBAN), ' ', '')
	HAVING COUNT(DISTINCT b.Vendorid) = 1
		OR COUNT(DISTINCT b.CustomerID) = 1

	-- 4. Always check for an invoice number in the description: the IBAN can be linked to the wrong relation.
	SELECT
		@typematch		= 'IBANInvoice'
	,	@GLCode			= @DefaultGLCodecustomer_id
	,	@Newcustomer	= CASE WHEN @customer_id IS NULL THEN 1 ELSE 0 END
	,	@customer_id	= i.customer_id
	FROM tb_Netsuite_Invoice i
	WHERE LTRIM(RTRIM(i.invoice_number)) <> ''
		AND @Description LIKE '%' + LTRIM(RTRIM(i.invoice_number)) + '%'

	-- 4b. No vendor from the IBAN: look for a vendor bill number in the description
	IF @vendor_id IS NULL
		SELECT @vendor_id = v.vendor_id
		FROM tb_Netsuite_vendorBill v
		WHERE LTRIM(RTRIM(v.vendor_bill_number)) <> ''
			AND @Description LIKE '%' + LTRIM(RTRIM(v.vendor_bill_number)) + '%'

	-- 5. Vendor found: find the vendor bill
	IF @vendor_id IS NOT NULL
	BEGIN
		-- Bill number in the description
		SELECT
			@typematch	= 'PurchaseInvoice'
		,	@reference	= CASE WHEN ABS(ABS(@Amount) - v.amount_open) < 0.005
								AND (@Currency = 'EUR' OR @Currency = v.currency_name)
							THEN v.vendor_bill_number END
		,	@GLCode		= @DefaultGLCodevendor_id
		FROM tb_Netsuite_vendorBill v
		WHERE v.vendor_id = @vendor_id
			AND LTRIM(RTRIM(v.vendor_bill_number)) <> ''
			AND @Description LIKE '%' + LTRIM(RTRIM(v.vendor_bill_number)) + '%'

		-- No bill number: exactly one open bill with this amount?
		IF @reference IS NULL
		BEGIN
			SELECT
				@typematch	= 'PurchaseInvoiceAmount'
			,	@reference	= MAX(v.vendor_bill_number)
			,	@GLCode		= @DefaultGLCodevendor_id
			FROM tb_Netsuite_vendorBill v
			WHERE v.vendor_id = @vendor_id
				AND ABS(ABS(@Amount) - v.amount_open) < 0.005
				AND (@Currency = 'EUR' OR @Currency = v.currency_name)
			HAVING COUNT(*) = 1
		END

		-- Matched as a purchase: it's a vendor, not a customer
		IF @typematch LIKE 'Purchase%'
			SET @customer_id = NULL
	END

	-- 6. No customer yet: sales invoice number in description or payment reference
	IF ISNULL(@typematch, '') NOT LIKE 'Purchase%' AND @customer_id IS NULL
	BEGIN
		SELECT
			@typematch		= 'IBANSalesInvoice'
		,	@GLCode			= @DefaultGLCodecustomer_id
		,	@Newcustomer	= CASE WHEN @customer_id IS NULL THEN 1 ELSE 0 END
		,	@customer_id	= c.customer_id
		,	@reference		= CASE WHEN ABS(@Amount - c.amount_open) < 0.005 THEN c.invoice_number END
		FROM tb_Netsuite_Invoice c
		WHERE LTRIM(RTRIM(c.invoice_number)) <> ''
			AND (	@Description LIKE '%' + LTRIM(RTRIM(c.invoice_number)) + '%'
				OR	@betalingskenmerk LIKE '%' + LTRIM(RTRIM(c.invoice_number)) + '%')
	END

	-- 7. Customer found: find the open invoice(s)
	IF @customer_id IS NOT NULL
	BEGIN
		-- Invoice number in description or payment reference
		SELECT
			@typematch	= 'SalesInvoice'
		,	@GLCode		= @DefaultGLCodecustomer_id
		,	@reference	= CASE WHEN ABS(@Amount - c.amount_open) < 0.005
								AND (@Currency = 'EUR' OR @Currency = c.currency_name)
							THEN c.invoice_number END
		FROM tb_Netsuite_Invoice c
		WHERE c.customer_id = @customer_id
			AND LTRIM(RTRIM(c.invoice_number)) <> ''
			AND (	@Description LIKE '%' + LTRIM(RTRIM(c.invoice_number)) + '%'
				OR	@betalingskenmerk LIKE '%' + LTRIM(RTRIM(c.invoice_number)) + '%')

		-- Exactly one open invoice with this amount?
		IF @reference IS NULL
		BEGIN
			SELECT
				@typematch	= 'SalesinvoiceAmount'
			,	@reference	= MAX(c.invoice_number)
			FROM tb_Netsuite_Invoice c
			WHERE c.customer_id = @customer_id
				AND ABS(@Amount - c.amount_open) < 0.005
				AND (@Currency = 'EUR' OR @Currency = c.currency_name)
			HAVING COUNT(*) = 1
		END

		-- Invoices named in the description that add up (oldest first) to the amount
		IF @reference IS NULL
		BEGIN
			;WITH s AS (
				SELECT
					ROW_NUMBER() OVER (ORDER BY ISNULL(t.due_date, '2099-01-01'), t.invoice_number) AS RowNumber
				,	t.invoice_number
				,	SUM(t.amount_open) OVER (ORDER BY ISNULL(t.due_date, '2099-01-01'), t.invoice_number) AS Amount_openCum
				FROM tb_Netsuite_Invoice t
				WHERE t.customer_id = @customer_id
					AND LTRIM(RTRIM(t.invoice_number)) <> ''
					AND (	@Description LIKE '%' + LTRIM(RTRIM(t.invoice_number)) + '%'
						OR	@betalingskenmerk LIKE '%' + LTRIM(RTRIM(t.invoice_number)) + '%')
			)
			SELECT TOP 1
				@typematch		= 'SalesinvoiceListDescription'
			,	@ReferenceXML	= (SELECT t.invoice_number FROM s t WHERE t.RowNumber <= s.RowNumber FOR XML PATH(''), ROOT('Invoices'))
			FROM s
			WHERE ABS(s.Amount_openCum - @Amount) < 0.005
		END

		-- All open invoices that add up (oldest first) to the amount
		IF @reference IS NULL AND @ReferenceXML IS NULL
		BEGIN
			;WITH s AS (
				SELECT
					ROW_NUMBER() OVER (ORDER BY ISNULL(t.due_date, '2099-01-01'), t.invoice_number) AS RowNumber
				,	t.invoice_number
				,	SUM(t.amount_open) OVER (ORDER BY ISNULL(t.due_date, '2099-01-01'), t.invoice_number) AS Amount_openCum
				FROM tb_Netsuite_Invoice t
				WHERE t.customer_id = @customer_id
			)
			SELECT TOP 1
				@typematch		= 'SalesinvoiceListSum'
			,	@ReferenceXML	= (SELECT t.invoice_number FROM s t WHERE t.RowNumber <= s.RowNumber FOR XML PATH(''), ROOT('Invoices'))
			FROM s
			WHERE ABS(s.Amount_openCum - @Amount) < 0.005
		END

		IF @reference IS NOT NULL OR @ReferenceXML IS NOT NULL
			SET @GLCode = @DefaultGLCodecustomer_id

		-- Matched as a sale: it's a customer, not a vendor
		IF @typematch LIKE 'Sales%'
			SET @vendor_id = NULL
	END

	-- 8. Still both a vendor and a customer: the sign of the amount decides
	IF @vendor_id IS NOT NULL AND @customer_id IS NOT NULL
	BEGIN
		IF @Amount < 0
		BEGIN
			SET @customer_id = NULL
			SET @GLCode = @DefaultGLCodevendor_id
		END
		ELSE
		BEGIN
			SET @vendor_id = NULL
			SET @GLCode = @DefaultGLCodecustomer_id
		END
	END

	-- 9. Fallback GL code
	IF @GLCode IS NULL AND @customer_id IS NOT NULL
		SET @GLCode = @DefaultGLCodecustomer_id

	IF @GLCode IS NULL AND @vendor_id IS NOT NULL
		SET @GLCode = @DefaultGLCodevendor_id

	IF @GLCode IS NULL
		SELECT @GLCode = glcode
		FROM vw_Bank_Journal
		WHERE CompanyID = @CompanyID
			AND Journal = @Journal

	INSERT INTO @retreport
	(
		GLCode, vendor_id, customer_id, Costcenter, CostUnit, Reference, typematch,
		NewCustomer, VatCode, ReferenceXML, WorkflowNumber, WorkflowID
	)
	VALUES
	(
		@GLCode, @vendor_id, @customer_id, @costCenter, @CostUnit, @reference, @typematch,
		@Newcustomer, @vatcode, @ReferenceXML, @WorkflowNumber, @WorkflowID
	)

	RETURN
END
GO
