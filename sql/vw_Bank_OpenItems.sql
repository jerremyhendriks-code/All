/*
    Views on the snapshot tables of sp_Bank_Synchronise_Company_V2, for the bank engine
    (fn_Bank_Match_V2 and sp_Bank_Netsuite_FinancialEntry_Create_V2).

    They use the column names of the NetSuite FROM tables (tb_Netsuite_vendorBill, tb_Netsuite_Invoice,
    tb_Netsuite_Bank_account_details), so the engine reads the clean snapshot instead of every load:
    only open documents from the latest load, one row per document, amounts as decimal(19,2).

        vw_Bank_Open_VendorBill   open vendor bills
        vw_Bank_Open_Invoice      open invoices
        vw_Bank_Relation_IBAN     IBAN -> vendor / customer

    Run sp_Bank_Synchronise_Company_V2 first; the engine SP does that itself (@Synchronise = 1).
*/
USE [BPAStaging]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER VIEW dbo.vw_Bank_Open_VendorBill
AS
SELECT
	o.Subsidiary        AS subsidiary_id
,	o.DocumentID        AS vendor_bill_id
,	o.DocumentNumber    AS vendor_bill_number
,	o.EntityID          AS vendor_id
,	o.EntityName        AS vendor_name
,	o.DocumentDate      AS bill_date
,	o.DueDate           AS due_date
,	o.Amount            AS bill_total
,	o.AmountOpen        AS amount_open
,	o.CurrencyID        AS currency_id
,	o.CurrencyName      AS currency_name
,	o.StatusName        AS status_name
FROM dbo.tb_Bank_Synch_OpenItems o
WHERE o.DocType = 'VENDORBILL';
GO

CREATE OR ALTER VIEW dbo.vw_Bank_Open_Invoice
AS
SELECT
	o.Subsidiary        AS subsidiary_id
,	o.DocumentID        AS invoice_id
,	o.DocumentNumber    AS invoice_number
,	o.EntityID          AS customer_id
,	o.EntityName        AS customer_name
,	o.DocumentDate      AS invoice_date
,	o.DueDate           AS due_date
,	o.Amount            AS invoice_total
,	o.AmountOpen        AS amount_open
,	o.CurrencyID        AS currency_id
,	o.CurrencyName      AS currency_name
,	o.StatusName        AS status_name
FROM dbo.tb_Bank_Synch_OpenItems o
WHERE o.DocType = 'INVOICE';
GO

CREATE OR ALTER VIEW dbo.vw_Bank_Relation_IBAN
AS
SELECT
	r.IBAN                                                          AS custrecord_2663_entity_iban
,	CASE WHEN r.EntityType = 'VENDOR'   THEN r.EntityID END         AS Vendorid
,	CASE WHEN r.EntityType = 'CUSTOMER' THEN r.EntityID END         AS CustomerID
,	r.EntityName
,	r.Source
FROM dbo.tb_Bank_Synch_RelationIBAN r;
GO
