/*
    Tables for bank transaction matching (Rabobank -> NetSuite).

    - tb_Bank_TransactionMatch                  What happened to each bank transaction: one row per paid
                                                invoice / vendor bill, or one journal entry row.
    - tb_Netsuite_CustomerPaymentCreate (+ _Apply)   customerPayments to create in NetSuite.
    - tb_Netsuite_VendorPaymentCreate   (+ _Apply)   vendorPayments to create in NetSuite.
    - tb_Netsuite_JournalEntryCreate    (+ _Line)    journalEntries to create in NetSuite.

    The NetSuite output tables use the standard BPA columns. Lines point to their header
    through BPA_ParentID = header BPA_EntryID. BPA_Status 0 = waiting to be sent.
    external_id is 'RABO-<IBAN>-<entryReference>' so NetSuite rejects a second copy.
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

-- Header: one customerPayment per matched incoming bank transaction.
CREATE TABLE [dbo].[tb_Netsuite_CustomerPaymentCreate](
	[BPA_EntryID] [uniqueidentifier] NOT NULL,
	[BPA_Origin] [nvarchar](50) NULL,
	[BPA_Direction] [nvarchar](50) NULL,
	[BPA_Company] [nvarchar](50) NULL,
	[BPA_ParentID] [uniqueidentifier] NULL,
	[BPA_Status] [int] NULL,
	[BPA_Reference] [nvarchar](50) NULL,
	[BPA_Reference_Description] [nvarchar](100) NULL,
	[BPA_Reference2] [nvarchar](50) NULL,
	[BPA_Reference2_Description] [nvarchar](100) NULL,
	[BPA_Action] [nvarchar](1) NULL,
	[BPA_ReturnedID] [nvarchar](50) NULL,
	[BPA_Syscreated] [datetime] NULL,
	[BPA_Sysmodified] [datetime] NULL,
	[BPA_Syscreator] [nvarchar](50) NULL,
	[BPA_Error] [varchar](max) NULL,
	[BPA_Error_Extended] [varchar](max) NULL,
	[BPA_Description] [varchar](100) NULL,
	[BPA_Failcount] [int] NULL,
	[BPA_Orig_Entryid] [uniqueidentifier] NULL,
	[BPA_TaskInstanceID] [int] NULL,
	[BPA_TaskID] [int] NULL,
	[external_id] [nvarchar](255) NULL,
	[customer_id] [nvarchar](100) NULL,
	[subsidiary_id] [nvarchar](100) NULL,
	[account_id] [nvarchar](100) NULL,
	[currency_id] [nvarchar](100) NULL,
	[tran_date] [date] NULL,
	[payment_amount] [decimal](18, 2) NULL,
	[memo] [nvarchar](999) NULL,
 CONSTRAINT [PK_tb_Netsuite_CustomerPaymentCreate] PRIMARY KEY CLUSTERED 
(
	[BPA_EntryID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO

ALTER TABLE [dbo].[tb_Netsuite_CustomerPaymentCreate] ADD  CONSTRAINT [DF_tb_Netsuite_CustomerPaymentCreate_BPA_EntryID]  DEFAULT (newsequentialid()) FOR [BPA_EntryID]
GO

ALTER TABLE [dbo].[tb_Netsuite_CustomerPaymentCreate] ADD  CONSTRAINT [DF_tb_Netsuite_CustomerPaymentCreate_BPA_Status]  DEFAULT ((0)) FOR [BPA_Status]
GO

ALTER TABLE [dbo].[tb_Netsuite_CustomerPaymentCreate] ADD  CONSTRAINT [DF_tb_Netsuite_CustomerPaymentCreate_BPA_Syscreated]  DEFAULT (getdate()) FOR [BPA_Syscreated]
GO

ALTER TABLE [dbo].[tb_Netsuite_CustomerPaymentCreate] ADD  CONSTRAINT [DF_tb_Netsuite_CustomerPaymentCreate_BPA_Sysmodified]  DEFAULT (getdate()) FOR [BPA_Sysmodified]
GO

ALTER TABLE [dbo].[tb_Netsuite_CustomerPaymentCreate] ADD  CONSTRAINT [DF_tb_Netsuite_CustomerPaymentCreate_BPA_Failcount]  DEFAULT ((0)) FOR [BPA_Failcount]
GO

-- Apply lines: invoices paid by the customerPayment (BPA_ParentID = header BPA_EntryID).
CREATE TABLE [dbo].[tb_Netsuite_CustomerPaymentCreate_Apply](
	[BPA_EntryID] [uniqueidentifier] NOT NULL,
	[BPA_Origin] [nvarchar](50) NULL,
	[BPA_Direction] [nvarchar](50) NULL,
	[BPA_Company] [nvarchar](50) NULL,
	[BPA_ParentID] [uniqueidentifier] NULL,
	[BPA_Status] [int] NULL,
	[BPA_Reference] [nvarchar](50) NULL,
	[BPA_Reference_Description] [nvarchar](100) NULL,
	[BPA_Reference2] [nvarchar](50) NULL,
	[BPA_Reference2_Description] [nvarchar](100) NULL,
	[BPA_Action] [nvarchar](1) NULL,
	[BPA_ReturnedID] [nvarchar](50) NULL,
	[BPA_Syscreated] [datetime] NULL,
	[BPA_Sysmodified] [datetime] NULL,
	[BPA_Syscreator] [nvarchar](50) NULL,
	[BPA_Error] [varchar](max) NULL,
	[BPA_Error_Extended] [varchar](max) NULL,
	[BPA_Description] [varchar](100) NULL,
	[BPA_Failcount] [int] NULL,
	[BPA_Orig_Entryid] [uniqueidentifier] NULL,
	[BPA_TaskInstanceID] [int] NULL,
	[BPA_TaskID] [int] NULL,
	[invoice_id] [nvarchar](100) NULL,
	[invoice_number] [nvarchar](100) NULL,
	[amount] [decimal](18, 2) NULL,
 CONSTRAINT [PK_tb_Netsuite_CustomerPaymentCreate_Apply] PRIMARY KEY CLUSTERED 
(
	[BPA_EntryID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO

ALTER TABLE [dbo].[tb_Netsuite_CustomerPaymentCreate_Apply] ADD  CONSTRAINT [DF_tb_Netsuite_CustomerPaymentCreate_Apply_BPA_EntryID]  DEFAULT (newsequentialid()) FOR [BPA_EntryID]
GO

ALTER TABLE [dbo].[tb_Netsuite_CustomerPaymentCreate_Apply] ADD  CONSTRAINT [DF_tb_Netsuite_CustomerPaymentCreate_Apply_BPA_Status]  DEFAULT ((0)) FOR [BPA_Status]
GO

ALTER TABLE [dbo].[tb_Netsuite_CustomerPaymentCreate_Apply] ADD  CONSTRAINT [DF_tb_Netsuite_CustomerPaymentCreate_Apply_BPA_Syscreated]  DEFAULT (getdate()) FOR [BPA_Syscreated]
GO

ALTER TABLE [dbo].[tb_Netsuite_CustomerPaymentCreate_Apply] ADD  CONSTRAINT [DF_tb_Netsuite_CustomerPaymentCreate_Apply_BPA_Sysmodified]  DEFAULT (getdate()) FOR [BPA_Sysmodified]
GO

ALTER TABLE [dbo].[tb_Netsuite_CustomerPaymentCreate_Apply] ADD  CONSTRAINT [DF_tb_Netsuite_CustomerPaymentCreate_Apply_BPA_Failcount]  DEFAULT ((0)) FOR [BPA_Failcount]
GO

CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_CustomerPaymentCreate_Apply_BPA_ParentID] ON [dbo].[tb_Netsuite_CustomerPaymentCreate_Apply] ([BPA_ParentID] ASC) ON [PRIMARY]
GO

-- Header: one vendorPayment per matched outgoing bank transaction.
CREATE TABLE [dbo].[tb_Netsuite_VendorPaymentCreate](
	[BPA_EntryID] [uniqueidentifier] NOT NULL,
	[BPA_Origin] [nvarchar](50) NULL,
	[BPA_Direction] [nvarchar](50) NULL,
	[BPA_Company] [nvarchar](50) NULL,
	[BPA_ParentID] [uniqueidentifier] NULL,
	[BPA_Status] [int] NULL,
	[BPA_Reference] [nvarchar](50) NULL,
	[BPA_Reference_Description] [nvarchar](100) NULL,
	[BPA_Reference2] [nvarchar](50) NULL,
	[BPA_Reference2_Description] [nvarchar](100) NULL,
	[BPA_Action] [nvarchar](1) NULL,
	[BPA_ReturnedID] [nvarchar](50) NULL,
	[BPA_Syscreated] [datetime] NULL,
	[BPA_Sysmodified] [datetime] NULL,
	[BPA_Syscreator] [nvarchar](50) NULL,
	[BPA_Error] [varchar](max) NULL,
	[BPA_Error_Extended] [varchar](max) NULL,
	[BPA_Description] [varchar](100) NULL,
	[BPA_Failcount] [int] NULL,
	[BPA_Orig_Entryid] [uniqueidentifier] NULL,
	[BPA_TaskInstanceID] [int] NULL,
	[BPA_TaskID] [int] NULL,
	[external_id] [nvarchar](255) NULL,
	[vendor_id] [nvarchar](100) NULL,
	[subsidiary_id] [nvarchar](100) NULL,
	[account_id] [nvarchar](100) NULL,
	[currency_id] [nvarchar](100) NULL,
	[tran_date] [date] NULL,
	[payment_amount] [decimal](18, 2) NULL,
	[memo] [nvarchar](999) NULL,
 CONSTRAINT [PK_tb_Netsuite_VendorPaymentCreate] PRIMARY KEY CLUSTERED 
(
	[BPA_EntryID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO

ALTER TABLE [dbo].[tb_Netsuite_VendorPaymentCreate] ADD  CONSTRAINT [DF_tb_Netsuite_VendorPaymentCreate_BPA_EntryID]  DEFAULT (newsequentialid()) FOR [BPA_EntryID]
GO

ALTER TABLE [dbo].[tb_Netsuite_VendorPaymentCreate] ADD  CONSTRAINT [DF_tb_Netsuite_VendorPaymentCreate_BPA_Status]  DEFAULT ((0)) FOR [BPA_Status]
GO

ALTER TABLE [dbo].[tb_Netsuite_VendorPaymentCreate] ADD  CONSTRAINT [DF_tb_Netsuite_VendorPaymentCreate_BPA_Syscreated]  DEFAULT (getdate()) FOR [BPA_Syscreated]
GO

ALTER TABLE [dbo].[tb_Netsuite_VendorPaymentCreate] ADD  CONSTRAINT [DF_tb_Netsuite_VendorPaymentCreate_BPA_Sysmodified]  DEFAULT (getdate()) FOR [BPA_Sysmodified]
GO

ALTER TABLE [dbo].[tb_Netsuite_VendorPaymentCreate] ADD  CONSTRAINT [DF_tb_Netsuite_VendorPaymentCreate_BPA_Failcount]  DEFAULT ((0)) FOR [BPA_Failcount]
GO

-- Apply lines: vendor bills paid by the vendorPayment (BPA_ParentID = header BPA_EntryID).
CREATE TABLE [dbo].[tb_Netsuite_VendorPaymentCreate_Apply](
	[BPA_EntryID] [uniqueidentifier] NOT NULL,
	[BPA_Origin] [nvarchar](50) NULL,
	[BPA_Direction] [nvarchar](50) NULL,
	[BPA_Company] [nvarchar](50) NULL,
	[BPA_ParentID] [uniqueidentifier] NULL,
	[BPA_Status] [int] NULL,
	[BPA_Reference] [nvarchar](50) NULL,
	[BPA_Reference_Description] [nvarchar](100) NULL,
	[BPA_Reference2] [nvarchar](50) NULL,
	[BPA_Reference2_Description] [nvarchar](100) NULL,
	[BPA_Action] [nvarchar](1) NULL,
	[BPA_ReturnedID] [nvarchar](50) NULL,
	[BPA_Syscreated] [datetime] NULL,
	[BPA_Sysmodified] [datetime] NULL,
	[BPA_Syscreator] [nvarchar](50) NULL,
	[BPA_Error] [varchar](max) NULL,
	[BPA_Error_Extended] [varchar](max) NULL,
	[BPA_Description] [varchar](100) NULL,
	[BPA_Failcount] [int] NULL,
	[BPA_Orig_Entryid] [uniqueidentifier] NULL,
	[BPA_TaskInstanceID] [int] NULL,
	[BPA_TaskID] [int] NULL,
	[vendor_bill_id] [nvarchar](100) NULL,
	[vendor_bill_number] [nvarchar](100) NULL,
	[amount] [decimal](18, 2) NULL,
 CONSTRAINT [PK_tb_Netsuite_VendorPaymentCreate_Apply] PRIMARY KEY CLUSTERED 
(
	[BPA_EntryID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO

ALTER TABLE [dbo].[tb_Netsuite_VendorPaymentCreate_Apply] ADD  CONSTRAINT [DF_tb_Netsuite_VendorPaymentCreate_Apply_BPA_EntryID]  DEFAULT (newsequentialid()) FOR [BPA_EntryID]
GO

ALTER TABLE [dbo].[tb_Netsuite_VendorPaymentCreate_Apply] ADD  CONSTRAINT [DF_tb_Netsuite_VendorPaymentCreate_Apply_BPA_Status]  DEFAULT ((0)) FOR [BPA_Status]
GO

ALTER TABLE [dbo].[tb_Netsuite_VendorPaymentCreate_Apply] ADD  CONSTRAINT [DF_tb_Netsuite_VendorPaymentCreate_Apply_BPA_Syscreated]  DEFAULT (getdate()) FOR [BPA_Syscreated]
GO

ALTER TABLE [dbo].[tb_Netsuite_VendorPaymentCreate_Apply] ADD  CONSTRAINT [DF_tb_Netsuite_VendorPaymentCreate_Apply_BPA_Sysmodified]  DEFAULT (getdate()) FOR [BPA_Sysmodified]
GO

ALTER TABLE [dbo].[tb_Netsuite_VendorPaymentCreate_Apply] ADD  CONSTRAINT [DF_tb_Netsuite_VendorPaymentCreate_Apply_BPA_Failcount]  DEFAULT ((0)) FOR [BPA_Failcount]
GO

CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_VendorPaymentCreate_Apply_BPA_ParentID] ON [dbo].[tb_Netsuite_VendorPaymentCreate_Apply] ([BPA_ParentID] ASC) ON [PRIMARY]
GO

-- Header: one journalEntry per unmatched bank transaction.
CREATE TABLE [dbo].[tb_Netsuite_JournalEntryCreate](
	[BPA_EntryID] [uniqueidentifier] NOT NULL,
	[BPA_Origin] [nvarchar](50) NULL,
	[BPA_Direction] [nvarchar](50) NULL,
	[BPA_Company] [nvarchar](50) NULL,
	[BPA_ParentID] [uniqueidentifier] NULL,
	[BPA_Status] [int] NULL,
	[BPA_Reference] [nvarchar](50) NULL,
	[BPA_Reference_Description] [nvarchar](100) NULL,
	[BPA_Reference2] [nvarchar](50) NULL,
	[BPA_Reference2_Description] [nvarchar](100) NULL,
	[BPA_Action] [nvarchar](1) NULL,
	[BPA_ReturnedID] [nvarchar](50) NULL,
	[BPA_Syscreated] [datetime] NULL,
	[BPA_Sysmodified] [datetime] NULL,
	[BPA_Syscreator] [nvarchar](50) NULL,
	[BPA_Error] [varchar](max) NULL,
	[BPA_Error_Extended] [varchar](max) NULL,
	[BPA_Description] [varchar](100) NULL,
	[BPA_Failcount] [int] NULL,
	[BPA_Orig_Entryid] [uniqueidentifier] NULL,
	[BPA_TaskInstanceID] [int] NULL,
	[BPA_TaskID] [int] NULL,
	[external_id] [nvarchar](255) NULL,
	[subsidiary_id] [nvarchar](100) NULL,
	[currency_id] [nvarchar](100) NULL,
	[tran_date] [date] NULL,
	[memo] [nvarchar](999) NULL,
 CONSTRAINT [PK_tb_Netsuite_JournalEntryCreate] PRIMARY KEY CLUSTERED 
(
	[BPA_EntryID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO

ALTER TABLE [dbo].[tb_Netsuite_JournalEntryCreate] ADD  CONSTRAINT [DF_tb_Netsuite_JournalEntryCreate_BPA_EntryID]  DEFAULT (newsequentialid()) FOR [BPA_EntryID]
GO

ALTER TABLE [dbo].[tb_Netsuite_JournalEntryCreate] ADD  CONSTRAINT [DF_tb_Netsuite_JournalEntryCreate_BPA_Status]  DEFAULT ((0)) FOR [BPA_Status]
GO

ALTER TABLE [dbo].[tb_Netsuite_JournalEntryCreate] ADD  CONSTRAINT [DF_tb_Netsuite_JournalEntryCreate_BPA_Syscreated]  DEFAULT (getdate()) FOR [BPA_Syscreated]
GO

ALTER TABLE [dbo].[tb_Netsuite_JournalEntryCreate] ADD  CONSTRAINT [DF_tb_Netsuite_JournalEntryCreate_BPA_Sysmodified]  DEFAULT (getdate()) FOR [BPA_Sysmodified]
GO

ALTER TABLE [dbo].[tb_Netsuite_JournalEntryCreate] ADD  CONSTRAINT [DF_tb_Netsuite_JournalEntryCreate_BPA_Failcount]  DEFAULT ((0)) FOR [BPA_Failcount]
GO

-- Lines: bank account and suspense account (BPA_ParentID = header BPA_EntryID).
CREATE TABLE [dbo].[tb_Netsuite_JournalEntryCreate_Line](
	[BPA_EntryID] [uniqueidentifier] NOT NULL,
	[BPA_Origin] [nvarchar](50) NULL,
	[BPA_Direction] [nvarchar](50) NULL,
	[BPA_Company] [nvarchar](50) NULL,
	[BPA_ParentID] [uniqueidentifier] NULL,
	[BPA_Status] [int] NULL,
	[BPA_Reference] [nvarchar](50) NULL,
	[BPA_Reference_Description] [nvarchar](100) NULL,
	[BPA_Reference2] [nvarchar](50) NULL,
	[BPA_Reference2_Description] [nvarchar](100) NULL,
	[BPA_Action] [nvarchar](1) NULL,
	[BPA_ReturnedID] [nvarchar](50) NULL,
	[BPA_Syscreated] [datetime] NULL,
	[BPA_Sysmodified] [datetime] NULL,
	[BPA_Syscreator] [nvarchar](50) NULL,
	[BPA_Error] [varchar](max) NULL,
	[BPA_Error_Extended] [varchar](max) NULL,
	[BPA_Description] [varchar](100) NULL,
	[BPA_Failcount] [int] NULL,
	[BPA_Orig_Entryid] [uniqueidentifier] NULL,
	[BPA_TaskInstanceID] [int] NULL,
	[BPA_TaskID] [int] NULL,
	[line_no] [int] NULL,
	[account_id] [nvarchar](100) NULL,
	[debit] [decimal](18, 2) NULL,
	[credit] [decimal](18, 2) NULL,
	[memo] [nvarchar](999) NULL,
 CONSTRAINT [PK_tb_Netsuite_JournalEntryCreate_Line] PRIMARY KEY CLUSTERED 
(
	[BPA_EntryID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO

ALTER TABLE [dbo].[tb_Netsuite_JournalEntryCreate_Line] ADD  CONSTRAINT [DF_tb_Netsuite_JournalEntryCreate_Line_BPA_EntryID]  DEFAULT (newsequentialid()) FOR [BPA_EntryID]
GO

ALTER TABLE [dbo].[tb_Netsuite_JournalEntryCreate_Line] ADD  CONSTRAINT [DF_tb_Netsuite_JournalEntryCreate_Line_BPA_Status]  DEFAULT ((0)) FOR [BPA_Status]
GO

ALTER TABLE [dbo].[tb_Netsuite_JournalEntryCreate_Line] ADD  CONSTRAINT [DF_tb_Netsuite_JournalEntryCreate_Line_BPA_Syscreated]  DEFAULT (getdate()) FOR [BPA_Syscreated]
GO

ALTER TABLE [dbo].[tb_Netsuite_JournalEntryCreate_Line] ADD  CONSTRAINT [DF_tb_Netsuite_JournalEntryCreate_Line_BPA_Sysmodified]  DEFAULT (getdate()) FOR [BPA_Sysmodified]
GO

ALTER TABLE [dbo].[tb_Netsuite_JournalEntryCreate_Line] ADD  CONSTRAINT [DF_tb_Netsuite_JournalEntryCreate_Line_BPA_Failcount]  DEFAULT ((0)) FOR [BPA_Failcount]
GO

CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_JournalEntryCreate_Line_BPA_ParentID] ON [dbo].[tb_Netsuite_JournalEntryCreate_Line] ([BPA_ParentID] ASC) ON [PRIMARY]
GO
