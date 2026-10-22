USE [BPAStaging]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
------------------------------------------------------------
-- Snapshot tables (once)
------------------------------------------------------------
IF OBJECT_ID('dbo.tb_Bank_Synch_OpenItems', 'U') IS NULL
BEGIN
	CREATE TABLE dbo.tb_Bank_Synch_OpenItems
	(
		Subsidiary          nvarchar(100)    NOT NULL,
		DocType             varchar(10)      NOT NULL,	-- VENDORBILL / INVOICE
		DocumentID          nvarchar(100)    NOT NULL,	-- NetSuite internal id (apply doc id)
		DocumentNumber      nvarchar(255)    NULL,		-- bill number / invoice number (tranid)
		EntityID            nvarchar(100)    NULL,		-- vendor id / customer id
		EntityName          nvarchar(255)    NULL,
		DocumentDate        date             NULL,
		DueDate             date             NULL,
		Amount              decimal(19,2)    NULL,
		AmountOpen          decimal(19,2)    NOT NULL,
		CurrencyID          nvarchar(50)     NULL,
		CurrencyName        nvarchar(255)    NULL,
		StatusName          nvarchar(255)    NULL,
		PostingPeriodName   nvarchar(255)    NULL,
		Memo                nvarchar(1000)   NULL,
		Source_EntryID      uniqueidentifier NULL,		-- BPA_EntryID of the FROM row used
		Source_Syscreated   datetime         NULL,
		Synchronised        datetime         NOT NULL CONSTRAINT DF_tb_Bank_Synch_OpenItems_Synchronised DEFAULT (GETDATE()),
		CONSTRAINT PK_tb_Bank_Synch_OpenItems PRIMARY KEY (DocType, DocumentID)
	);

	CREATE INDEX IX_tb_Bank_Synch_OpenItems_Entity
		ON dbo.tb_Bank_Synch_OpenItems (Subsidiary, DocType, EntityID)
		INCLUDE (DocumentNumber, AmountOpen, CurrencyName);
END
GO

-- Paid by the bank engine since the FROM load (already taken off AmountOpen); NetSuite's open amount = AmountOpen + this
IF COL_LENGTH('dbo.tb_Bank_Synch_OpenItems', 'AmountPaidByBank') IS NULL
	ALTER TABLE dbo.tb_Bank_Synch_OpenItems ADD AmountPaidByBank decimal(19,2) NULL;
GO

IF OBJECT_ID('dbo.tb_Bank_Synch_RelationIBAN', 'U') IS NULL
BEGIN
	CREATE TABLE dbo.tb_Bank_Synch_RelationIBAN
	(
		IBAN                nvarchar(50)     NOT NULL,	-- upper case, no spaces
		EntityType          varchar(10)      NOT NULL,	-- VENDOR / CUSTOMER
		EntityID            nvarchar(100)    NOT NULL,
		EntityName          nvarchar(400)    NULL,
		Source              varchar(20)      NOT NULL,	-- BANKDETAILS / VENDORBILL
		Source_ID           nvarchar(100)    NULL,		-- bank details record id
		Synchronised        datetime         NOT NULL CONSTRAINT DF_tb_Bank_Synch_RelationIBAN_Synchronised DEFAULT (GETDATE())
	);

	CREATE INDEX IX_tb_Bank_Synch_RelationIBAN_IBAN
		ON dbo.tb_Bank_Synch_RelationIBAN (IBAN)
		INCLUDE (EntityType, EntityID);
END
GO

------------------------------------------------------------
-- sp_Bank_Synchronise_Company_V2
------------------------------------------------------------
--[sp_Bank_Synchronise_Company_V2] '89','OPEN'

CREATE OR ALTER PROCEDURE [dbo].[sp_Bank_Synchronise_Company_V2](@BPA_Company as varchar(20), @Type varchar(20) = 'OPEN') AS
-- NetSuite version of sp_Bank_Synchronise_Company (which stays as it is, for Exact).
-- Synchronises the open vendor bills and invoices of one subsidiary (@BPA_Company = NetSuite subsidiary id)
-- and the IBANs of all vendors / customers, from the NetSuite FROM tables in BPAStaging:
--
--     tb_Netsuite_vendorBill            -> tb_Bank_Synch_OpenItems    (DocType 'VENDORBILL')
--     tb_Netsuite_Invoice               -> tb_Bank_Synch_OpenItems    (DocType 'INVOICE')
--     tb_Netsuite_Bank_account_details  -> tb_Bank_Synch_RelationIBAN (Source 'BANKDETAILS')
--     tb_Netsuite_vendorBill.vendor_iban-> tb_Bank_Synch_RelationIBAN (Source 'VENDORBILL')
--
-- Differences with the Exact version:
--  - No dynamic SQL: the FROM tasks already load NetSuite into BPAStaging; a filter on the subsidiary is enough.
--    (subsidiary_id, not BPA_Company: the FROM tasks don't fill BPA_Company.)
--  - The FROM tables keep every load: per document the latest row (BPA_Syscreated). A document whose latest
--    row is more than @MaxAgeHours older than the latest load of the subsidiary isn't in NetSuite's load anymore
--    (paid / closed) and is left out. Test documents (BPA_Origin 'TEST') are always kept and aren't a load.
--  - Paid by the bank engine since the load: vendor / customer payments sent to NetSuite (TO, BPA_Status 1,
--    NetSuite id in BPA_ReturnedID) after the document's row was loaded are taken off the open amount
--    (AmountPaidByBank), so a document is never paid twice before the next FROM load.
--  - BANKMATCHING (read back what Exact booked) isn't needed: the TO tasks write the NetSuite id back
--    in BPA_ReturnedID. BankBatches: no NetSuite source yet.
--  - Everything in one transaction, so the engine never reads a half-filled snapshot.

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @MaxAgeHours int = 36		-- older than the latest load by more than this = no longer open
DECLARE @LastLoadBills datetime, @LastLoadInvoices datetime

if @Type='OPEN'
begin
	-- Latest load of this subsidiary (test rows aren't a load)
	select @LastLoadBills = max(v.BPA_Syscreated)
	from tb_Netsuite_vendorBill v
	where cast(v.subsidiary_id as nvarchar(100)) = @BPA_Company and isnull(v.BPA_Origin, '') <> N'TEST'

	select @LastLoadInvoices = max(i.BPA_Syscreated)
	from tb_Netsuite_Invoice i
	where cast(i.subsidiary_id as nvarchar(100)) = @BPA_Company and isnull(i.BPA_Origin, '') <> N'TEST'

	BEGIN TRANSACTION

	delete from tb_Bank_Synch_OpenItems where Subsidiary = @BPA_Company

	-- Synchroniseer openstaande inkoopfacturen (vendor bills): latest row per bill
	insert into tb_Bank_Synch_OpenItems
	(Subsidiary, DocType, DocumentID, DocumentNumber, EntityID, EntityName, DocumentDate, DueDate, Amount, AmountOpen,
	 CurrencyID, CurrencyName, StatusName, PostingPeriodName, Memo, Source_EntryID, Source_Syscreated)
	select
		@BPA_Company
	,	'VENDORBILL'
	,	cast(v.vendor_bill_id as nvarchar(100))
	,	ltrim(rtrim(v.vendor_bill_number))
	,	cast(v.vendor_id as nvarchar(100))
	,	v.vendor_name
	,	coalesce(cast(v.bill_date as date),
				 try_convert(date, left(ltrim(v.invoice_date), 10), 23),
				 try_convert(date, left(ltrim(v.invoice_date), 10), 103))
	,	coalesce(try_convert(date, left(ltrim(v.due_date), 10), 23),
				 try_convert(date, left(ltrim(v.due_date), 10), 103))
	,	cast(round(coalesce(v.bill_total, v.invoice_total), 2) as decimal(19,2))
	,	try_convert(decimal(19,2), ltrim(rtrim(v.amount_open)))
	,	cast(v.currency_id as nvarchar(50))
	,	v.currency_name
	,	v.status_name
	,	v.posting_period_name
	,	left(v.memo, 1000)
	,	v.BPA_EntryID
	,	v.BPA_Syscreated
	from tb_Netsuite_vendorBill v
	where cast(v.subsidiary_id as nvarchar(100)) = @BPA_Company
		and v.vendor_bill_id is not null
		and v.BPA_EntryID = (select top 1 v2.BPA_EntryID from tb_Netsuite_vendorBill v2
							 where v2.vendor_bill_id = v.vendor_bill_id
							 order by v2.BPA_Syscreated desc, v2.BPA_Sysmodified desc)
		and try_convert(decimal(19,2), ltrim(rtrim(v.amount_open))) > 0
		and (v.BPA_Origin = N'TEST' or v.BPA_Syscreated >= dateadd(hour, -@MaxAgeHours, @LastLoadBills))

	-- Synchroniseer openstaande verkoopfacturen (invoices): latest row per invoice
	insert into tb_Bank_Synch_OpenItems
	(Subsidiary, DocType, DocumentID, DocumentNumber, EntityID, EntityName, DocumentDate, DueDate, Amount, AmountOpen,
	 CurrencyID, CurrencyName, StatusName, PostingPeriodName, Memo, Source_EntryID, Source_Syscreated)
	select
		@BPA_Company
	,	'INVOICE'
	,	cast(i.invoice_id as nvarchar(100))
	,	ltrim(rtrim(i.invoice_number))
	,	cast(i.customer_id as nvarchar(100))
	,	i.customer_name
	,	coalesce(try_convert(date, left(ltrim(i.invoice_date), 10), 23),
				 try_convert(date, left(ltrim(i.invoice_date), 10), 103))
	,	coalesce(try_convert(date, left(ltrim(i.due_date), 10), 23),
				 try_convert(date, left(ltrim(i.due_date), 10), 103))
	,	cast(round(i.invoice_total, 2) as decimal(19,2))
	,	cast(round(i.amount_open, 2) as decimal(19,2))
	,	cast(i.currency_id as nvarchar(50))
	,	i.currency_name
	,	i.status_name
	,	i.posting_period_name
	,	left(i.memo, 1000)
	,	i.BPA_EntryID
	,	i.BPA_Syscreated
	from tb_Netsuite_Invoice i
	where cast(i.subsidiary_id as nvarchar(100)) = @BPA_Company
		and nullif(ltrim(rtrim(i.invoice_id)), N'') is not null
		and i.BPA_EntryID = (select top 1 i2.BPA_EntryID from tb_Netsuite_Invoice i2
							 where i2.invoice_id = i.invoice_id
							 order by i2.BPA_Syscreated desc, i2.BPA_Sysmodified desc)
		and i.amount_open > 0
		and (i.BPA_Origin = N'TEST' or i.BPA_Syscreated >= dateadd(hour, -@MaxAgeHours, @LastLoadInvoices))

	-- Betaald door de bank engine na de load: van het openstaande bedrag af (the FROM table doesn't know it yet)
	update o
	set AmountPaidByBank = p.Paid
	,	AmountOpen       = o.AmountOpen - p.Paid
	from tb_Bank_Synch_OpenItems o
	cross apply (select sum(x.amount) as Paid
				 from (select try_convert(decimal(19,2), a.amount) as amount, h.BPA_Sysmodified as Sent
					   from tb_Netsuite_VendorPayment_Apply a
					   join tb_Netsuite_VendorPayment h on h.BPA_EntryID = a.BPA_ParentID
					   where o.DocType = 'VENDORBILL' and a.doc_id = o.DocumentID
						 and h.BPA_Direction = 'TO' and h.BPA_Status = 1 and nullif(h.BPA_ReturnedID, N'') is not null
					   union all
					   select try_convert(decimal(19,2), a.amount), h.BPA_Sysmodified
					   from tb_Netsuite_CustomerPayment_Apply a
					   join tb_Netsuite_CustomerPayment h on h.BPA_EntryID = a.BPA_ParentID
					   where o.DocType = 'INVOICE' and a.docId = o.DocumentID
						 and h.BPA_Direction = 'TO' and h.BPA_Status = 1 and nullif(h.BPA_ReturnedID, N'') is not null
					  ) x
				 where isnull(x.Sent, getdate()) > o.Source_Syscreated) p		-- sent after this row was loaded
	where o.Subsidiary = @BPA_Company
		and p.Paid is not null

	-- Fully paid by the bank engine: not open anymore
	delete from tb_Bank_Synch_OpenItems where Subsidiary = @BPA_Company and AmountOpen <= 0


	-- Synchroniseer relaties / IBAN: per vendor / customer, not per subsidiary, so always the full set
	delete from tb_Bank_Synch_RelationIBAN

	-- Bank details records (Electronic Bank Payments): latest row per record, active
	insert into tb_Bank_Synch_RelationIBAN (IBAN, EntityType, EntityID, EntityName, Source, Source_ID)
	select distinct
		upper(replace(d.custrecord_2663_entity_iban, N' ', N''))
	,	case when nullif(d.vendorid, N'') is not null then 'VENDOR' else 'CUSTOMER' end
	,	coalesce(nullif(d.vendorid, N''), nullif(d.customerid, N''))
	,	coalesce(nullif(d.vendorrefname, N''), d.customerrefname)
	,	'BANKDETAILS'
	,	d.id
	from tb_Netsuite_Bank_account_details d
	where nullif(d.custrecord_2663_entity_iban, N'') is not null
		and coalesce(nullif(d.vendorid, N''), nullif(d.customerid, N'')) is not null
		and len(replace(d.custrecord_2663_entity_iban, N' ', N'')) >= 15
		and isnull(d.isInactive, 0) = 0
		and d.BPA_EntryID = (select top 1 d2.BPA_EntryID from tb_Netsuite_Bank_account_details d2
							 where d2.id = d.id
							 order by d2.BPA_Syscreated desc)

	-- IBAN on the vendor bill, for vendors whose bank details don't already give that IBAN
	insert into tb_Bank_Synch_RelationIBAN (IBAN, EntityType, EntityID, EntityName, Source, Source_ID)
	select distinct
		upper(replace(v.vendor_iban, N' ', N''))
	,	'VENDOR'
	,	cast(v.vendor_id as nvarchar(100))
	,	v.vendor_name
	,	'VENDORBILL'
	,	null
	from tb_Netsuite_vendorBill v
	where nullif(v.vendor_iban, N'') is not null
		and v.vendor_id is not null
		and len(replace(v.vendor_iban, N' ', N'')) >= 15
		and not exists (select 1 from tb_Bank_Synch_RelationIBAN r
						where r.Source = 'BANKDETAILS' and r.EntityType = 'VENDOR'
						  and r.IBAN = upper(replace(v.vendor_iban, N' ', N''))
						  and r.EntityID = cast(v.vendor_id as nvarchar(100)))

	COMMIT TRANSACTION
end
GO

-- Check: the snapshot of one subsidiary
--EXEC sp_Bank_Synchronise_Company_V2 '89', 'OPEN';
--SELECT DocType, COUNT(*) AS documents, SUM(AmountOpen) AS open_total, SUM(AmountPaidByBank) AS paid_by_bank_since_load
--FROM tb_Bank_Synch_OpenItems WHERE Subsidiary = '89' GROUP BY DocType;
