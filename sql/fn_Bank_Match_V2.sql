USE [BPAStaging]
GO
/****** Object:  UserDefinedFunction [dbo].[fn_Bank_Match_V2]    Script Date: 13/10/2026 14:27:47 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
/*
    fn_Bank_Match_V2: copy of fn_Bank_Match (which stays as it is, as a backup) with
    changes for the bank engine (sp_Bank_Netsuite_FinancialEntry_Create_V2), marked "-- BANK ENGINE:":
    1. Money out without a vendor from the IBAN: find the vendor by a vendor bill number in the
       description (only when exactly one vendor has a bill with a number in the description).
    2. Vendor bills: the bank amount of a payment is negative, amount_open is positive, so compare
       ABS(@amount) with amount_open (to the cent).
    3. PurchaseInvoice returns the vendor_bill_number as Reference (was vendor_bill_id), the same as
       PurchaseInvoiceAmount, so the engine can look the bill up.
    4. vendor_id / customer_id nvarchar(100) (was 6: longer NetSuite IDs were cut off silently) and
       Reference nvarchar(60) (was 20: a longer document number stopped the whole matching run).
    5. A document number only counts when it has at least @MinNumberLength (4) characters, so numbers
       like '1' or an empty number don't match every description.
    6. A document number only counts as a whole word in the description / payment reference: no letter
       or digit directly before or after it ('1293' doesn't match '10011293', 'INV-1293 ' does match).
    7. Only bills / invoices of the bank account's own subsidiary (Company in vw_Bank_BankAccounts).
    8. A customer found by IBAN is kept (two leftover "set @customer_id=null" lines threw it away).
    9. Reads the snapshot of sp_Bank_Synchronise_Company_V2 (vw_Bank_Open_VendorBill, vw_Bank_Open_Invoice,
       vw_Bank_Relation_IBAN) instead of every load in the NetSuite FROM tables: only open documents
       of the latest load, one row per document. Amounts are compared to the cent (was exact float =).
   10. Workflow rules on again (vw_Bank_Matching / fn_Bank_Match_Rules, see vw_Bank_Matching.sql), filtered on the
       bank account's subsidiary (was CompanyID, which isn't filled for NetSuite):
         IBANWF      relation from a rule on the counterparty IBAN
         CUSTOMERWF  relation from a rule on description / amount / reference
         MATCH       GL account, relation, VAT code, department (Costcenter) and class (CostUnit) from the most
                     specific fitting rule, when the transaction isn't matched to a document
       GLCode / Costcenter / CostUnit / VatCode are NetSuite ids, nvarchar(100) (were Exact codes, 9-10 chars).
*/
CREATE OR ALTER FUNCTION [dbo].[fn_Bank_Match_V2]
	(

--declare
@BPA_Type varchar(10)
,	@BPA_EntryID uniqueidentifier
,	@BankAccount varchar(50)
,	@IBAN varchar(33)
,	@Amount float
,	@Currency varchar(20)
,   @Description varchar(255)
,	@kenmerk varchar(255)
,	@incassant VARCHAR(255)
,	@betalingskenmerk VARCHAR(255)
,	@Machtiging VARCHAR(255)
,	@Mutationcode varchar(5)
	)
--declare @retreport TABLE
Returns @retreport TABLE
(
		GLCode nvarchar(100),			-- BANK ENGINE: was char(9); NetSuite account id
		vendor_id nvarchar(100),		-- BANK ENGINE: was nvarchar(6)
		customer_id nvarchar(100),		-- BANK ENGINE: was nvarchar(6)
		Costcenter nvarchar(100),		-- BANK ENGINE: was varchar(10); NetSuite department id
		CostUnit nvarchar(100),			-- BANK ENGINE: was nvarchar(10); NetSuite class id
		Reference nvarchar(60),			-- BANK ENGINE: was nvarchar(20)
		typematch nvarchar(50),
		--IBAN nvarchar(34),
		--BIC nvarchar(20),
		--Bankname nvarchar(100),
		NewCustomer int,
		VatCode nvarchar(100),			-- BANK ENGINE: was nvarchar(10)
		ReferenceXML xml,
		WorkflowNumber int,
		WorkflowID uniqueidentifier

		--Foreign_Description varchar(255),
		--Original_Amount float,
		--Paid_Amount float,
		--GLCode_PaidDifference nvarchar(9)
	)
BEGIN
--set @BPA_Type='BANK'
--set @BPA_EntryID='7D8EE1D3-C1C3-F111-9386-00155D0A0313'
IF @BPA_Type='BANK' and @BPA_EntryID is not null
BEGIN
	-- Laad hier gegevens voor matching uit ABN transactie tabel
	SELECT
		@BankAccount	=g.BPA_Origin
	,	@IBAN			=g.IBAN
	,	@Amount			=g.Amount
	,	@Currency		=g.Currency
	,   @Description	=g.Description
	,	@kenmerk		=g.Kenmerk
	,	@incassant		=g.Incassant
	,	@betalingskenmerk=g.Betalingskenmerk
	,	@Machtiging		=g.Machtiging
	,	@Mutationcode	=g.Mutationcode
	FROM tb_Bank_Transactions g
	WHERE BPA_EntryID=@BPA_EntryID

	--set @IBAN='NL20ABNA0881342394'
	--set @Description='221A'
	--set @Amount=1609.25
END


--IF @BPA_Type='ABN' and @BPA_EntryID is not null
--BEGIN
--	-- Laad hier gegevens voor matching uit ABN transactie tabel
--	SELECT
--		@BankAccount	=g.BPA_Origin
--	,	@IBAN			=g.Matched_IBAN
--	,	@Amount			=g.amount
--	,	@Currency		=g.currency
--	,   @Description	=g.Matched_Description
--	,	@kenmerk		=g.Matched_Kenmerk
--	,	@incassant		=g.Matched_Incassant
--	,	@betalingskenmerk=g.Matched_Betalingskenmerk
--	,	@Machtiging		=g.Matched_Machtiging
--	,	@Mutationcode	=g.mutationcode
--	FROM tb_ABN_Gettransactions g
--	WHERE BPA_EntryID=@BPA_EntryID
--END

--IF @BPA_Type='RABO' and @BPA_EntryID is not null
--BEGIN
--	-- Laad hier gegevens voor matching uit ABN transactie tabel
--	SELECT
--		@BankAccount	=g.BPA_Origin
--	,	@IBAN			=isnull(g.vendor_idAccount_iban,g.customer_idAccount_iban)
--	,	@Amount			=g.transactionAmount_value
--	,	@Currency		=g.transactionAmount_currency
--	,   @Description	=g.remittanceInformationUnstructured
--	,	@Machtiging		=g.mandateId
--	,	@kenmerk		=g.endToEndId
--	--,	@Mutationcode	=g.mutationcode
--	FROM tb_RABO_Transactions g
--	WHERE BPA_EntryID=@BPA_EntryID
--END



-- Deze functie zoek eerst de extra velden binnen de bank omschrijving
-- Daarna wordt ahv regels de matching bepaald:
--1. Zoek debiteur of crediteur ahv gesynchroniseerde bankrekeneningen (Exact / ERP)
--2. Geen relatie gevonden: Zoek debiteur of crediteur ahv workflow regels (debiteur- en/of crediteurrekening)
--3. Crediteur gevonden: Zoek openstaande post voor crediteur erbij
--4. Debiteur gevonden:
--		Zoek openstaande post voor debiteur erbij
--		Niet gevonden: Zoek ahv bedrag of er 1 factuur matched
--		Niet gevonden: Zoek ahv omschrijving of totaalbedrag of er meerdere facturen matchen
--5. Zoek ahv workflow regels of er een match is
--6. Geen match: Zoek ahv factuur of er een match is met een debiteur
--7. Geen match: Maak met gekoppelde glcode aan.

	DECLARE
		@CompanyID uniqueidentifier
		,@Company nvarchar(50)
		,@counterPartyAccountNumber nvarchar(20)
		,@counterPartyName nvarchar(100)
	--	,@amount float
	--	,@currency nvarchar(10)
		,@TypeTransaction nvarchar(50)
		,@WorkflowNumber int
		,@WorkflowID uniqueidentifier

DECLARE 	@Journal nvarchar(20),
			@DefaultGLCodevendor_id as nvarchar(100),		-- BANK ENGINE: was nvarchar(9)
			@DefaultGLCodecustomer_id as nvarchar(100),	-- BANK ENGINE: was nvarchar(9)
			@ReferenceXML xml,
			@GLCode_PaidDifference as nvarchar(9)

DECLARE @costCenter nvarchar(100),		-- BANK ENGINE: was nvarchar(20)
		@CostUnit nvarchar(100),		-- BANK ENGINE: was nvarchar(20)
		@vatcode nvarchar(100)			-- BANK ENGINE: was nvarchar(10)

DECLARE @Newcustomer bit=0
DECLARE @typematch as varchar(50)
DECLARE @vendor_id as varchar(100)		-- BANK ENGINE: was varchar(6)
DECLARE @customer_id as varchar(100)	-- BANK ENGINE: was varchar(6)
Declare @marge as float
declare @GLCode nvarchar(100)			-- BANK ENGINE: was varchar(9)
declare @reference varchar(60)
DECLARE @MinNumberLength int = 4		-- BANK ENGINE: shorter document numbers are not looked for in the description
-- BANK ENGINE: description / payment reference with a space on both sides, so a document number can be
-- matched as a whole: no letter or digit directly before or after it ('1293' doesn't match '10011293')
DECLARE @DescMatch    nvarchar(300) = N' ' + ISNULL(@description, N'') + N' '
DECLARE @KenmerkMatch nvarchar(300) = N' ' + ISNULL(@betalingskenmerk, N'') + N' '
	-- Haal hier de default waardes op voor deze bankrekening.
	SELECT
		@Journal=Journal
		,@DefaultGLCodevendor_id=DefaultGLCodeCreditor
		,@DefaultGLCodecustomer_id=DefaultGLCodeDebtor
	--	,@CompanyID=CompanyID
		,@Company=Company
--		,@GLCode_PaidDifference=GLCode_PaidDifference  -- TI
	FROM
		vw_Bank_BankAccounts
	WHERE
		Bankaccount = @BankAccount
--select * 		FROM
--		vw_abn_bankaccounts


	-- Kijk hier of er voor dezre bankrekening 1 debiteur of crediteur is.


	SELECT TOP (1000)

		@typematch = 'IBAN'
			, @vendor_id = CASE WHEN count(distinct b.Vendorid)=1
									THEN max(b.Vendorid)
							  -- WHEN count(distinct case when b.DefaultBankAccount=1 then  b.Crdnr end)=1
									--THEN max(distinct case when b.DefaultBankAccount=1 then  b.Crdnr end)
						  END
			, @customer_id =	  CASE	WHEN count(distinct b.CustomerID)=1
									THEN max(b.CustomerID)
								--WHEN count(distinct case when b.DefaultBankAccount=1 then  b.Debnr end)=1
								--	THEN max(distinct case when b.DefaultBankAccount=1 then  b.Debnr end)
						  END
	FROM dbo.vw_Bank_Relation_IBAN b		-- BANK ENGINE: snapshot (was tb_Netsuite_Bank_account_details)
	WHERE
		--b.CompanyID=@CompanyID
		--and
		b.custrecord_2663_entity_iban = UPPER(REPLACE(@IBAN, ' ', ''))		-- BANK ENGINE: snapshot IBANs are upper case without spaces

	having
		(
			COUNT(DISTINCT b.Vendorid)=1
			or
			COUNT(DISTINCT b.CustomerID)=1
			--or
			--count(distinct case when b.DefaultBankAccount=1 then  b.Debnr end)=1
			--or
			--count(distinct case when b.DefaultBankAccount=1 then  b.Crdnr end)=1
		)




	-- BANK ENGINE: workflow rule on the counterparty IBAN ("Submit and approve bankaccount"): IBAN -> relation.
	-- Only rules whose GL code is an AP / AR account (CredDebCode C / D), and only when exactly one relation fits.
	IF @vendor_id IS NULL OR @customer_id IS NULL
	BEGIN
		SELECT
			 @typematch      = 'IBANWF'
			,@vendor_id      = ISNULL(@vendor_id,   CASE WHEN COUNT(DISTINCT m.vendor_id)   = 1 THEN MAX(m.vendor_id)   END)
			,@customer_id    = ISNULL(@customer_id, CASE WHEN COUNT(DISTINCT m.customer_id) = 1 THEN MAX(m.customer_id) END)
			,@WorkflowNumber = MIN(m.WorkflowNumber)
		FROM
			dbo.vw_Bank_Matching m
		WHERE
			m.Company = @Company
			AND m.BankAccount = UPPER(REPLACE(@BankAccount, ' ', ''))
			AND m.BankaccountRelation = UPPER(REPLACE(@IBAN, ' ', ''))
			AND (m.vendor_id IS NOT NULL OR m.customer_id IS NOT NULL)
			AND ISNULL(m.CredDebCode, '') IN ('C', 'D')		-- alleen debiteur- en/of crediteurrekeningen
		HAVING
			COUNT(DISTINCT m.vendor_id) = 1
			OR COUNT(DISTINCT m.customer_id) = 1

		IF @typematch = 'IBANWF'
			SELECT @WorkflowID = m.WorkflowID
			FROM dbo.vw_Bank_Matching m
			WHERE m.WorkflowNumber = @WorkflowNumber
	END






	IF @customer_id is null or 1=1 -- Altijd kijken of er ahv invoicenummer klant herkend kan worden. Soms is IBAN gematched aan verkeerde relatie.
	BEGIN
		-- Hier is nog niets gevonden, probeer nog op factuurnummer bij openstaande posten.
		SELECT @typematch = 'IBANInvoice'
				, @GLCode = @DefaultGLCodecustomer_id--  ISNULL(OffSetLedgerAccountNumber, @DefaultGLCodecustomer_id)
				, @Newcustomer=case when @customer_id is null then 1 else 0 end
				, @customer_id = i.customer_id

			FROM
				dbo.vw_Bank_Open_Invoice i		-- BANK ENGINE: snapshot (was tb_Netsuite_Invoice)
			WHERE
				--CompanyID=@CompanyID
				--AND
				LEN(LTRIM(RTRIM(i.invoice_number))) >= @MinNumberLength		-- BANK ENGINE
				AND (@Company IS NULL OR CAST(i.subsidiary_id AS nvarchar(100)) = @Company)		-- BANK ENGINE: same subsidiary as the bank account
				AND
				@DescMatch like '%[^0-9A-Za-z]' + REPLACE(REPLACE(REPLACE(ltrim(rtrim(i.invoice_number)), '[', '[[]'), '_', '[_]'), '%', '[%]') + '[^0-9A-Za-z]%'
	END


	--set @vendor_id=null
	-- BANK ENGINE: workflow rule on description / amount / reference etc. ("Submit and recognize relation"):
	-- relation from the rule. Only rules whose GL code is an AP / AR account, only when exactly one relation fits.
	IF @vendor_id IS NULL OR @customer_id IS NULL
	BEGIN
		SELECT
			 @typematch      = 'CUSTOMERWF'
			,@vendor_id      = ISNULL(@vendor_id,   CASE WHEN COUNT(DISTINCT m.vendor_id)   = 1 THEN MAX(m.vendor_id)   END)
			,@customer_id    = ISNULL(@customer_id, CASE WHEN COUNT(DISTINCT m.customer_id) = 1 THEN MAX(m.customer_id) END)
			,@WorkflowNumber = MIN(m.WorkflowNumber)
		FROM
			dbo.fn_Bank_Match_Rules(@Company, @BankAccount, @IBAN, @Amount, @Description, @kenmerk,
									@betalingskenmerk, @Machtiging, @incassant, @Mutationcode) m
		WHERE
			(m.vendor_id IS NOT NULL OR m.customer_id IS NOT NULL)
			AND ISNULL(m.CredDebCode, '') IN ('C', 'D')		-- alleen debiteur- en/of crediteurrekeningen
		HAVING
			COUNT(DISTINCT m.vendor_id) = 1
			OR COUNT(DISTINCT m.customer_id) = 1

		IF @typematch = 'CUSTOMERWF'
			SELECT @WorkflowID = m.WorkflowID
			FROM dbo.vw_Bank_Matching m
			WHERE m.WorkflowNumber = @WorkflowNumber
	END

	-- BANK ENGINE: geld eruit en nog geen crediteur via IBAN: zoek de crediteur ahv een inkoopfactuurnummer
	-- in de omschrijving (alleen als precies 1 crediteur zo'n factuur heeft).
	IF @vendor_id IS NULL AND @amount < 0
	BEGIN
		SELECT
			@vendor_id = CASE WHEN COUNT(DISTINCT v.vendor_id) = 1 THEN MAX(v.vendor_id) END
		FROM
			dbo.vw_Bank_Open_VendorBill v		-- BANK ENGINE: snapshot (was tb_Netsuite_vendorBill)
		WHERE
			LEN(LTRIM(RTRIM(v.vendor_bill_number))) >= @MinNumberLength
			AND (@Company IS NULL OR CAST(v.subsidiary_id AS nvarchar(100)) = @Company)		-- BANK ENGINE: same subsidiary as the bank account
			AND @DescMatch like '%[^0-9A-Za-z]' + REPLACE(REPLACE(REPLACE(ltrim(rtrim(v.vendor_bill_number)), '[', '[[]'), '_', '[_]'), '%', '[%]') + '[^0-9A-Za-z]%'
	END

	-- Indien er een crediteur is gevonden, zoek dan ook de inkoopfactuur erbij.
	IF @vendor_id IS NOT NULL
	BEGIN


		-- BANK ENGINE: ABS(@amount) (betaling is negatief, amount_open positief), op de cent,
		--              en Reference = vendor_bill_number (was vendor_bill_id)
		select
			@typematch = 'PurchaseInvoice'
			, @Reference = CASE WHEN ABS(ABS(@amount) - v.amount_open) < 0.005 and @currency='EUR' THEN v.vendor_bill_number
							WHEN ABS(ABS(@amount) - v.amount_open) < 0.005 and @currency=v.currency_name THEN v.vendor_bill_number
							ELSE null END
			, @GLCode = @DefaultGLCodevendor_id--ISNULL(OffSetLedgerAccountNumber, @DefaultGLCodevendor_id)
		from
			dbo.vw_Bank_Open_VendorBill v		-- BANK ENGINE: snapshot (was tb_Netsuite_vendorBill)
		where
			1=1--CompanyID=@CompanyID
			AND vendor_id = @vendor_id
			AND LEN(LTRIM(RTRIM(v.vendor_bill_number))) >= @MinNumberLength		-- BANK ENGINE
			AND (@Company IS NULL OR CAST(v.subsidiary_id AS nvarchar(100)) = @Company)		-- BANK ENGINE: same subsidiary as the bank account
			AND @DescMatch like '%[^0-9A-Za-z]' + REPLACE(REPLACE(REPLACE(ltrim(rtrim(v.vendor_bill_number)), '[', '[[]'), '_', '[_]'), '%', '[%]') + '[^0-9A-Za-z]%'



		-- Geen inkoopfactuur gevonden, kijk hier of er één factuur met dit bedrag openstaat.
		IF @reference IS NULL
		BEGIN
			-- BANK ENGINE: ABS(@amount), op de cent
			SELECT
				@typematch = 'PurchaseInvoiceAmount'
				, @Reference = MAX(CASE
										WHEN ABS(ABS(@amount) - v.amount_open) < 0.005 and @Currency='EUR'	then v.vendor_bill_number
										WHEN ABS(ABS(@amount) - v.amount_open) < 0.005 and @Currency=v.currency_name THEN v.vendor_bill_number
										ELSE null
									END)
				, @GLCode = @DefaultGLCodevendor_id --MAX(ISNULL(OffSetLedgerAccountNumber, @DefaultGLCodevendor_id))
			FROM
				dbo.vw_Bank_Open_VendorBill v		-- BANK ENGINE: snapshot (was tb_Netsuite_vendorBill)
			WHERE
				v.vendor_id = @vendor_id
				AND (@Company IS NULL OR CAST(v.subsidiary_id AS nvarchar(100)) = @Company)		-- BANK ENGINE: same subsidiary as the bank account
				and (	(ABS(ABS(@amount) - v.amount_open) < 0.005 and @currency='EUR')
						or
						(ABS(ABS(@amount) - v.amount_open) < 0.005 and @currency=v.currency_name)
					)
			GROUP BY
				v.vendor_id
			HAVING
				COUNT(*) = 1
		END

		-- Kijken of dit nodig is???
		--if @reference is null
		--begin
		--	set @vendor_id=null
		--end

		-- Als er een match is op referentie, dan is het een crediteur en geen debiteur (mocht deze als beide herkend zijn).
		if @typematch like 'Purchase%' and @customer_id is not null
		begin
			set @customer_id=null
		end

	END



	-- Probeer hier debiteur te herkennen ahv factuurnummer
	IF isnull(@typematch,'') not like 'Purchase%'
	  and @customer_id IS NULL
	BEGIN

		-- Hier is nog niets gevonden, probeer nog op factuurnummer bij openstaande posten.
		SELECT @typematch = 'IBANSalesInvoice'
				, @GLCode = @DefaultGLCodecustomer_id --ISNULL(OffSetLedgerAccountNumber, @DefaultGLCodecustomer_id)
				, @Newcustomer=case when @customer_id is null then 1 else 0 end
				, @customer_id = c.customer_id
				, @Reference =CASE WHEN ABS(@amount - c.amount_open) < 0.005 THEN c.invoice_number ELSE null END
			FROM
				dbo.vw_Bank_Open_Invoice c		-- BANK ENGINE: snapshot (was tb_Netsuite_Invoice)
			WHERE
				1=1 --and CompanyID=@CompanyID
				AND	@customer_id is null
				AND LEN(LTRIM(RTRIM(c.invoice_number))) >= @MinNumberLength		-- BANK ENGINE
				AND (@Company IS NULL OR CAST(c.subsidiary_id AS nvarchar(100)) = @Company)		-- BANK ENGINE: same subsidiary as the bank account
				AND
				(	@DescMatch like '%[^0-9A-Za-z]' + REPLACE(REPLACE(REPLACE(ltrim(rtrim(c.invoice_number)), '[', '[[]'), '_', '[_]'), '%', '[%]') + '[^0-9A-Za-z]%'
						OR
					@KenmerkMatch like '%[^0-9A-Za-z]' + REPLACE(REPLACE(REPLACE(ltrim(rtrim(c.invoice_number)), '[', '[[]'), '_', '[_]'), '%', '[%]') + '[^0-9A-Za-z]%'
				)
	end

	--set @customer_id='119099'
	-- Debiteur bekend?
	IF @customer_id is not null
	BEGIN



		-- Probeer op openstaande post te matchen.
		SELECT
			@typematch = 'SalesInvoice'
			, @GLCode = @DefaultGLCodecustomer_id --ISNULL(OffSetLedgerAccountNumber, @DefaultGLCodecustomer_id)
			, @Newcustomer=case when @customer_id is null then 1 else 0 end
			, @customer_id = c.customer_id
			, @Reference =CASE WHEN ABS(@amount - c.amount_open) < 0.005 and @currency='EUR' THEN c.invoice_number
							   WHEN ABS(@amount - c.amount_open) < 0.005 and @currency=c.currency_name THEN c.invoice_number
							   --when @Original_Amount=amount_open and @currency=currency then invoice_number

							ELSE null END
		FROM
			dbo.vw_Bank_Open_Invoice c		-- BANK ENGINE: snapshot (was tb_Netsuite_Invoice)
		WHERE
			1=1 --CompanyID=@CompanyID
			AND	c.customer_id = @customer_id
			AND LEN(LTRIM(RTRIM(c.invoice_number))) >= @MinNumberLength		-- BANK ENGINE
			AND (@Company IS NULL OR CAST(c.subsidiary_id AS nvarchar(100)) = @Company)		-- BANK ENGINE: same subsidiary as the bank account
			AND ( @DescMatch like '%[^0-9A-Za-z]' + REPLACE(REPLACE(REPLACE(ltrim(rtrim(c.invoice_number)), '[', '[[]'), '_', '[_]'), '%', '[%]') + '[^0-9A-Za-z]%'
					OR
				 @KenmerkMatch like '%[^0-9A-Za-z]' + REPLACE(REPLACE(REPLACE(ltrim(rtrim(c.invoice_number)), '[', '[[]'), '_', '[_]'), '%', '[%]') + '[^0-9A-Za-z]%'
				)

		--set @marge=0
		--select @marge=Marge from vw_Bank_BankAccounts_Marge where BankAccount=@BankAccount and @amount between AmountFrom and AmountTo

		--if @reference is null and @marge<>0
		--begin
		--	-- Kijk hier of de factuur met marge voldoet aan de criteria. In dat geval deze later alsnog matchen.
		--	SELECT
		--	@typematch = 'SalesInvoiceMarge'
		--	, @GLCode = ISNULL(OffSetLedgerAccountNumber, @DefaultGLCodecustomer_id)
		--	, @Newcustomer=case when @customer_id is null then 1 else 0 end
		--	, @customer_id = customer_id
		--	, @Reference =
		--			CASE WHEN ABS(@amount-amount_open)<=@marge and @currency='EUR' THEN invoice_number
		--					   WHEN ABS(@amount-amount_openCurrency)<=@marge and @currency=Currency THEN invoice_number
		--					ELSE null END
		--	FROM
		--		tb_Bank_Synch_customer_id_amount_open
		--	WHERE
		--		CompanyID=@CompanyID
		--		AND	customer_id = @customer_id
		--		AND @description like '%' + ltrim(rtrim(invoice_number)) + '%'
		--		and CASE WHEN ABS(@amount-amount_open)<=@marge and @currency='EUR' THEN invoice_number
		--					   WHEN ABS(@amount-amount_openCurrency)<=@marge and @currency=Currency THEN invoice_number
		--					ELSE null END is not null
		--end



		-- Geen openstaande post gevonden, probeer het met een totaal bedrag
		IF  @reference is NULL
		BEGIN
			-- Probeer hier te kijken of er 1 post openstaat en overeenkomt met bedrag.
				SELECT @typematch='SalesinvoiceAmount'
						,@reference=max(c.invoice_number)
				FROM
						dbo.vw_Bank_Open_Invoice c		-- BANK ENGINE: snapshot (was tb_Netsuite_Invoice)
				WHERE
						c.customer_id=@customer_id
						AND (@Company IS NULL OR CAST(c.subsidiary_id AS nvarchar(100)) = @Company)		-- BANK ENGINE: same subsidiary as the bank account
						AND (
								(ABS(c.amount_open - @amount) < 0.005 and @currency='EUR')
								OR
								(ABS(c.amount_open - @amount) < 0.005 and @currency=c.currency_name)
									--OR
									--(amount_open=@Original_Amount and @currency=currency)
								)
				HAVING
						COUNT(*)=1

		END

		-- Hier proberen we of de facturen herkend worden ahv omschrijving
		IF 	@reference IS NULL
		BEGIN

			-- Zoek hier ahv Omschrijving en betalingskenmerk / Factuurnummer of er een match is. Bedrag = cumulatieve gesorteerd op duedate en factuurnummer.
			;WITH s AS (
		SELECT ROW_NUMBER() OVER (ORDER BY isnull(t.due_date,'2099-01-01'),t.invoice_number ASC) AS RowNumber,
						t.customer_id,
						t.invoice_number,
						t.due_date
						,case when @currency=t.currency_name and @currency<>'EUR' then t.amount_open
							else t.amount_open end amount_open
						,sum(case when @currency=t.currency_name and @currency<>'EUR' then t.amount_open
							else t.amount_open end) over (order by isnull(t.due_date,'2099-01-01'),t.invoice_number ) as Amount_openCum
					FROM
						dbo.vw_Bank_Open_Invoice  t		-- BANK ENGINE: snapshot (was tb_Netsuite_Invoice)
					WHERE
						1=1 --CompanyID=@CompanyID
						AND	t.customer_id = @customer_id
						AND LEN(LTRIM(RTRIM(t.invoice_number))) >= @MinNumberLength		-- BANK ENGINE
						AND (@Company IS NULL OR CAST(t.subsidiary_id AS nvarchar(100)) = @Company)		-- BANK ENGINE: same subsidiary as the bank account
						AND
						(	@DescMatch like '%[^0-9A-Za-z]' + REPLACE(REPLACE(REPLACE(ltrim(rtrim(t.invoice_number)), '[', '[[]'), '_', '[_]'), '%', '[%]') + '[^0-9A-Za-z]%'
							OR
							@KenmerkMatch like '%[^0-9A-Za-z]' + REPLACE(REPLACE(REPLACE(ltrim(rtrim(t.invoice_number)), '[', '[[]'), '_', '[_]'), '%', '[%]') + '[^0-9A-Za-z]%'
						)
					)
			SELECT TOP 1  @typematch='SalesinvoiceListDescription'
					 ,@ReferenceXML=(SELECT t.invoice_number FROM s t WHERE t.RowNumber<=s.RowNumber FOR XML PATH(''),ROOT('Invoices'))
			FROM s WHERE ABS(Amount_openCum - @amount) < 0.005;

		END

		-- Hier proberen we of de oudste facturen opgeteld het totaalbedrag is.
		IF 	@reference is null AND
			@referenceXML is null
		BEGIN

			-- Zoek hier ahv cumulatieve waardes de lijst van openstaande facturen erbij. Bedrag = cumulatieve gesorteerd op duedate en factuurnummer.
			;WITH s AS (
					SELECT ROW_NUMBER() OVER (ORDER BY isnull(t.due_date,'2099-01-01'),t.invoice_number ASC) AS RowNumber,
						t.customer_id,
						t.invoice_number,
						t.due_date
						,case when @currency=t.currency_name and @currency<>'EUR' then t.amount_open
							else t.amount_open end as amount_open
						,sum(case when @currency=t.currency_name and @currency<>'EUR' then t.amount_open
							else t.amount_open end) over (order by isnull(t.due_date,'2099-01-01'),t.invoice_number ) as amount_openCum
					FROM
						dbo.vw_Bank_Open_Invoice  t		-- BANK ENGINE: snapshot (was tb_Netsuite_Invoice)
					WHERE
						1=1 --t.CompanyID=@CompanyID
						AND	t.customer_id = @customer_id
						AND (@Company IS NULL OR CAST(t.subsidiary_id AS nvarchar(100)) = @Company)		-- BANK ENGINE: same subsidiary as the bank account
				)

				SELECT TOP 1  @typematch='SalesinvoiceListSum'
							 ,@ReferenceXML=(SELECT t.invoice_number FROM s t WHERE t.RowNumber<=s.RowNumber FOR XML PATH(''),ROOT('Invoices'))
							FROM s WHERE ABS(amount_openCum - @amount) < 0.005;


		END

		-- Als er een referentie is gevonden: Haal glcode erbij.
		IF @Reference is not null or @ReferenceXML is not null
		BEGIN
			SET @glcode=@DefaultGLCodecustomer_id
			--isnull((select max(t.OffSetLedgerAccountNumber) from tb_Bank_Synch_customer_id_amount_open t
			--						where CompanyID=@CompanyID
			--						AND	t.customer_id=@customer_id)
			--					,@DefaultGLCodecustomer_id)
		END

		-- Is er een match op sales gevonden en ook een crediteur bekend: Set vendor_id=leeg
		if @typematch like 'Sales%' and @vendor_id is not null
			set @vendor_id=null
	END

	-- Als er zowel een crediteur als debiteur gekoppeld is aan een relatie en geen matching op referentie, kijk dan naar bedrag of het een debiteur is of crediteur
	if (@vendor_id is not null and @typematch not like 'Purchase%') and (@customer_id is not null and @typematch not like 'Sales%' )
	begin
		if @amount<0
		begin
			set @customer_id=null
			set @GLCode=@defaultglcodevendor_id
		end
		else
		begin
			set @vendor_id=null
			set @GLCode=@defaultglcodecustomer_id
		end
	end


	-- BANK ENGINE: workflow rules ("Submit and approve"). Recognised only by IBAN (no document matched) and a rule
	-- fits: the rule decides. typematch 'MATCH': GL code (NetSuite account id), relation, VAT code, cost centre
	-- (department) and cost unit (class) from the most specific fitting rule; the engine books a journal entry
	-- on that GL account. A relation already known stays when the rule has none.
	IF (@typematch IN ('IBANWF', 'IBAN', 'IBANSalesInvoice', 'CUSTOMERWF') OR (@typematch = 'SalesInvoice' AND @reference IS NULL))
		AND @reference IS NULL AND @ReferenceXML IS NULL		-- no document matched
		AND EXISTS (SELECT 1
					FROM dbo.fn_Bank_Match_Rules(@Company, @BankAccount, @IBAN, @Amount, @Description, @kenmerk,
												 @betalingskenmerk, @Machtiging, @incassant, @Mutationcode) m
					WHERE m.GLcode IS NOT NULL
					  AND ISNULL(m.CredDebCode, '') NOT IN ('C', 'D'))
	BEGIN
		SET @typematch = NULL
	END

	IF @typematch IS NULL
	BEGIN
		SELECT TOP (1)
			@glcode         = m.GLcode,
			@typematch      = 'MATCH',
			@vatcode        = m.VATcode,
			@vendor_id      = COALESCE(m.vendor_id, @vendor_id),
			@customer_id    = COALESCE(m.customer_id, @customer_id),
			@costunit       = m.CostUnit,
			@costCenter     = m.CostCenter,
			@WorkflowNumber = m.WorkflowNumber,
			@WorkflowID     = m.WorkflowID
		FROM
			dbo.fn_Bank_Match_Rules(@Company, @BankAccount, @IBAN, @Amount, @Description, @kenmerk,
									@betalingskenmerk, @Machtiging, @incassant, @Mutationcode) m
		WHERE
			m.GLcode IS NOT NULL
			AND ISNULL(m.CredDebCode, '') NOT IN ('C', 'D')	-- relation rules (AP / AR) are IBANWF / CUSTOMERWF above
		ORDER BY
			m.Specificity DESC, m.WorkflowNumber DESC

		-- A relation from the rule can't be both: the direction of the money decides
		IF @typematch = 'MATCH' AND @vendor_id IS NOT NULL AND @customer_id IS NOT NULL
		BEGIN
			IF @amount < 0 SET @customer_id = NULL ELSE SET @vendor_id = NULL
		END
	END

	IF @typematch is null
	BEGIN
		-- Hier is nog niets gevonden, probeer nog op factuurnummer bij openstaande posten.
		SELECT @typematch = 'SalesInvoice'
				, @GLCode = @DefaultGLCodecustomer_id --ISNULL(OffSetLedgerAccountNumber, @DefaultGLCodecustomer_id)
				, @Newcustomer=case when @customer_id is null then 1 else 0 end
				, @customer_id = customer_id
				, @Reference =CASE WHEN ABS(@amount - amount_open) < 0.005 THEN invoice_number ELSE null END
			FROM
				dbo.vw_Bank_Open_Invoice c		-- BANK ENGINE: snapshot (was tb_Netsuite_Invoice)
			WHERE
				1=1 --CompanyID=@CompanyID
				AND	@customer_id is null
				AND LEN(LTRIM(RTRIM(invoice_number))) >= @MinNumberLength		-- BANK ENGINE
				AND (@Company IS NULL OR CAST(subsidiary_id AS nvarchar(100)) = @Company)		-- BANK ENGINE: same subsidiary as the bank account
				AND	@DescMatch like '%[^0-9A-Za-z]' + REPLACE(REPLACE(REPLACE(ltrim(rtrim(invoice_number)), '[', '[[]'), '_', '[_]'), '%', '[%]') + '[^0-9A-Za-z]%'
	END


	-- INDIEN NIET GEVONDEN => DEFAULT REKENING NIET TOEGEWEZEN
	IF @GLCode is null
	BEGIN
		if @customer_id is not null
					SET @glcode=@DefaultGLCodecustomer_id
					--isnull((select max(t.OffSetLedgerAccountNumber) from tb_Bank_Synch_customer_id_amount_open t
					--				where CompanyID=@CompanyID
					--				AND	t.customer_id=@customer_id)
					--			,@DefaultGLCodecustomer_id)

		IF @GLCode is null
		SELECT
				@glcode=glcode
			FROM
				vw_Bank_Journal
			WHERE
					CompanyID=@CompanyID
				AND
					Journal=@journal

	END









	INSERT INTO @retreport

		(
			GLCode,
			vendor_id,
			customer_id,
			Costcenter,
			CostUnit,
			Reference,
			typematch,
			NewCustomer,
			VatCode,
			ReferenceXML,
			WorkflowNumber,
			WorkflowID

		)
		VALUES
		(
			@GLCode,
			@vendor_id,
			@customer_id,
			@Costcenter,
			@CostUnit,
			@Reference,
			@typematch,
			@NewCustomer,
			@vatcode,
			@ReferenceXML,
			@WorkflowNumber,
			@WorkflowID

		)
--	select * from @retreport
	RETURN
END
GO
