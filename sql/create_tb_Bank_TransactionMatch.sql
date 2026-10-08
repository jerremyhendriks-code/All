/*
    Log for bank transaction matching (Rabobank -> NetSuite): what happened to each bank
    transaction, one row per paid invoice / vendor bill or one journal entry row.
    usp_Bank_Match_Rabobank skips transactions and documents that are already in here.

    The NetSuite records themselves go to the existing tb_Netsuite_customerPayment /
    vendorPayment / journalEntry tables (and their child tables).
*/
USE [BPAStaging]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [dbo].[tb_Bank_TransactionMatch](
	[match_id] [int] IDENTITY(1,1) NOT NULL,
	[bank_iban] [varchar](100) NOT NULL,
	[entry_reference] [varchar](100) NOT NULL,
	[bank_entry_id] [uniqueidentifier] NOT NULL,
	[booking_date] [date] NULL,
	[transaction_amount] [decimal](18, 2) NOT NULL,
	[match_type] [varchar](20) NOT NULL,
	[match_rule] [varchar](50) NOT NULL,
	[document_id] [nvarchar](100) NULL,
	[document_number] [nvarchar](100) NULL,
	[entity_id] [nvarchar](100) NULL,
	[applied_amount] [decimal](18, 2) NULL,
	[output_entry_id] [uniqueidentifier] NOT NULL,
	[created_at] [datetime] NOT NULL CONSTRAINT [DF_tb_Bank_TransactionMatch_created_at] DEFAULT (getdate()),
 CONSTRAINT [PK_tb_Bank_TransactionMatch] PRIMARY KEY CLUSTERED ([match_id] ASC),
 CONSTRAINT [CK_tb_Bank_TransactionMatch_match_type] CHECK ([match_type] IN ('CUSTOMERPAYMENT', 'VENDORPAYMENT', 'JOURNALENTRY'))
) ON [PRIMARY]
GO

-- One row per bank transaction and document; a journal entry (document_id NULL) only once per transaction
CREATE UNIQUE NONCLUSTERED INDEX [UX_tb_Bank_TransactionMatch_transaction_document] ON [dbo].[tb_Bank_TransactionMatch]
(
	[bank_iban] ASC,
	[entry_reference] ASC,
	[document_id] ASC
) ON [PRIMARY]
GO

-- An invoice or vendor bill can only be paid once
CREATE UNIQUE NONCLUSTERED INDEX [UX_tb_Bank_TransactionMatch_document] ON [dbo].[tb_Bank_TransactionMatch]
(
	[match_type] ASC,
	[document_id] ASC
)
WHERE [document_id] IS NOT NULL
ON [PRIMARY]
GO

