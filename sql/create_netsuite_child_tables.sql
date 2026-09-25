/*
    Child tables for the sublists in the BPA NetSuite Search output:

      tb_Netsuite_CustomerPayment_Apply    customerPayment  apply/items   (applied invoices, + doc)
      tb_Netsuite_CustomerPayment_Credit   customerPayment  credit/items  (applied credits)
      tb_Netsuite_VendorPayment_Apply      vendorPayment    apply/items   (applied bills, + doc)
      tb_Netsuite_VendorPayment_Credit     vendorPayment    credit/items  (applied credits)
      tb_Netsuite_JournalEntry_Line        journalEntry     line/items    (+ account, department,
                                                                           class, location, entity)

    Each child row carries the standard BPA_* control block and links to its parent row
    through BPA_ParentID = <parent>.BPA_EntryID; <parent>_id also holds the parent's
    NetSuite id. Columns follow the schema's field names and tc:OriginalType; referenced
    records on a line are flattened to <object>_<field> (id / refName, plus acctNumber or
    externalId where useful).

    The apply/credit sublists return every open document, not only the paid ones:
    store or filter on [apply] = 1 for the lines actually applied.

    Each table is created only if it doesn't exist yet.
*/
SET NOCOUNT ON;

-- tb_Netsuite_CustomerPayment_Apply: one row per apply/items entry
IF OBJECT_ID(N'dbo.tb_Netsuite_CustomerPayment_Apply', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.[tb_Netsuite_CustomerPayment_Apply] (
        -- BPA control fields (standard block, same as the other tb_Netsuite_* tables)
        [BPA_Origin]                                       nvarchar(50)          NULL,
        [BPA_Direction]                                    nvarchar(50)          NULL,
        [BPA_Company]                                      nvarchar(50)          NULL,
        [BPA_EntryID]                                      uniqueidentifier      NOT NULL CONSTRAINT [DF_tb_Netsuite_CustomerPayment_Apply_EntryID] DEFAULT (newsequentialid()),
        [BPA_ParentID]                                     uniqueidentifier      NULL,
        [BPA_Status]                                       int                   NULL CONSTRAINT [DF_tb_Netsuite_CustomerPayment_Apply_Status] DEFAULT ((0)),
        [BPA_Reference]                                    nvarchar(50)          NULL,
        [BPA_Reference_Description]                        nvarchar(100)         NULL,
        [BPA_Reference2]                                   nvarchar(50)          NULL,
        [BPA_Reference2_Description]                       nvarchar(100)         NULL,
        [BPA_Action]                                       nvarchar(1)           NULL,
        [BPA_ReturnedID]                                   nvarchar(50)          NULL,
        [BPA_Syscreated]                                   datetime              NULL CONSTRAINT [DF_tb_Netsuite_CustomerPayment_Apply_Syscreated] DEFAULT (getdate()),
        [BPA_Sysmodified]                                  datetime              NULL CONSTRAINT [DF_tb_Netsuite_CustomerPayment_Apply_Sysmodified] DEFAULT (getdate()),
        [BPA_Syscreator]                                   nvarchar(50)          NULL,
        [BPA_Error]                                        nvarchar(max)         NULL,
        [BPA_Error_Extended]                               nvarchar(max)         NULL,
        [BPA_Description]                                  nvarchar(255)         NULL,
        [BPA_Failcount]                                    int                   NULL CONSTRAINT [DF_tb_Netsuite_CustomerPayment_Apply_Failcount] DEFAULT ((0)),
        [BPA_Orig_Entryid]                                 uniqueidentifier      NULL,
        [BPA_TaskInstanceID]                               int                   NULL,
        [BPA_TaskID]                                       int                   NULL,

        -- Parent: BPA_ParentID = tb_Netsuite_CustomerPayment.BPA_EntryID
        [customerPayment_id]                               nvarchar(100),        -- customerPayment/id (the parent's NetSuite id)

        -- Line fields (apply/items)
        [amount]                                           decimal(19,4),
        [apply]                                            bit,
        [applyDate]                                        date,
        [createdFrom]                                      nvarchar(400),
        [currency]                                         nvarchar(100),
        [disc]                                             decimal(19,4),
        [discAmt]                                          decimal(19,4),
        [due]                                              decimal(19,4),
        [line]                                             int,
        [refName]                                          nvarchar(400),
        [refNum]                                           nvarchar(100),
        [total]                                            decimal(19,4),
        [type]                                             nvarchar(100),

        -- Referenced records on the line (flattened: <object>/<field> -> <object>_<field>)
        [doc_id]                                           nvarchar(100),        -- apply/items/doc/id
        [doc_externalId]                                   nvarchar(100),        -- apply/items/doc/externalId
        [doc_refName]                                      nvarchar(400),        -- apply/items/doc/refName

        CONSTRAINT [PK_tb_Netsuite_CustomerPayment_Apply] PRIMARY KEY CLUSTERED ([BPA_EntryID])
    );

    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_CustomerPayment_Apply_BPA_ParentID] ON dbo.[tb_Netsuite_CustomerPayment_Apply] ([BPA_ParentID]);
    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_CustomerPayment_Apply_customerPayment_id] ON dbo.[tb_Netsuite_CustomerPayment_Apply] ([customerPayment_id], [line]);
    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_CustomerPayment_Apply_BPA_Status]
        ON dbo.[tb_Netsuite_CustomerPayment_Apply] ([BPA_Status], [BPA_Direction]) INCLUDE ([customerPayment_id], [BPA_Company]);
    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_CustomerPayment_Apply_doc_id] ON dbo.[tb_Netsuite_CustomerPayment_Apply] ([doc_id]) INCLUDE ([customerPayment_id], [amount]);

    PRINT N'Created dbo.[tb_Netsuite_CustomerPayment_Apply]';
END
ELSE
    PRINT N'Skipped dbo.[tb_Netsuite_CustomerPayment_Apply] (table already exists)';

-- tb_Netsuite_CustomerPayment_Credit: one row per credit/items entry
IF OBJECT_ID(N'dbo.tb_Netsuite_CustomerPayment_Credit', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.[tb_Netsuite_CustomerPayment_Credit] (
        -- BPA control fields (standard block, same as the other tb_Netsuite_* tables)
        [BPA_Origin]                                       nvarchar(50)          NULL,
        [BPA_Direction]                                    nvarchar(50)          NULL,
        [BPA_Company]                                      nvarchar(50)          NULL,
        [BPA_EntryID]                                      uniqueidentifier      NOT NULL CONSTRAINT [DF_tb_Netsuite_CustomerPayment_Credit_EntryID] DEFAULT (newsequentialid()),
        [BPA_ParentID]                                     uniqueidentifier      NULL,
        [BPA_Status]                                       int                   NULL CONSTRAINT [DF_tb_Netsuite_CustomerPayment_Credit_Status] DEFAULT ((0)),
        [BPA_Reference]                                    nvarchar(50)          NULL,
        [BPA_Reference_Description]                        nvarchar(100)         NULL,
        [BPA_Reference2]                                   nvarchar(50)          NULL,
        [BPA_Reference2_Description]                       nvarchar(100)         NULL,
        [BPA_Action]                                       nvarchar(1)           NULL,
        [BPA_ReturnedID]                                   nvarchar(50)          NULL,
        [BPA_Syscreated]                                   datetime              NULL CONSTRAINT [DF_tb_Netsuite_CustomerPayment_Credit_Syscreated] DEFAULT (getdate()),
        [BPA_Sysmodified]                                  datetime              NULL CONSTRAINT [DF_tb_Netsuite_CustomerPayment_Credit_Sysmodified] DEFAULT (getdate()),
        [BPA_Syscreator]                                   nvarchar(50)          NULL,
        [BPA_Error]                                        nvarchar(max)         NULL,
        [BPA_Error_Extended]                               nvarchar(max)         NULL,
        [BPA_Description]                                  nvarchar(255)         NULL,
        [BPA_Failcount]                                    int                   NULL CONSTRAINT [DF_tb_Netsuite_CustomerPayment_Credit_Failcount] DEFAULT ((0)),
        [BPA_Orig_Entryid]                                 uniqueidentifier      NULL,
        [BPA_TaskInstanceID]                               int                   NULL,
        [BPA_TaskID]                                       int                   NULL,

        -- Parent: BPA_ParentID = tb_Netsuite_CustomerPayment.BPA_EntryID
        [customerPayment_id]                               nvarchar(100),        -- customerPayment/id (the parent's NetSuite id)

        -- Line fields (credit/items)
        [amount]                                           decimal(19,4),
        [appliedTo]                                        nvarchar(400),
        [apply]                                            bit,
        [createdFrom]                                      nvarchar(400),
        [creditDate]                                       date,
        [currency]                                         nvarchar(100),
        [due]                                              decimal(19,4),
        [line]                                             int,
        [refName]                                          nvarchar(400),
        [refNum]                                           nvarchar(100),
        [total]                                            decimal(19,4),
        [type]                                             nvarchar(100),

        CONSTRAINT [PK_tb_Netsuite_CustomerPayment_Credit] PRIMARY KEY CLUSTERED ([BPA_EntryID])
    );

    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_CustomerPayment_Credit_BPA_ParentID] ON dbo.[tb_Netsuite_CustomerPayment_Credit] ([BPA_ParentID]);
    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_CustomerPayment_Credit_customerPayment_id] ON dbo.[tb_Netsuite_CustomerPayment_Credit] ([customerPayment_id], [line]);
    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_CustomerPayment_Credit_BPA_Status]
        ON dbo.[tb_Netsuite_CustomerPayment_Credit] ([BPA_Status], [BPA_Direction]) INCLUDE ([customerPayment_id], [BPA_Company]);

    PRINT N'Created dbo.[tb_Netsuite_CustomerPayment_Credit]';
END
ELSE
    PRINT N'Skipped dbo.[tb_Netsuite_CustomerPayment_Credit] (table already exists)';

-- tb_Netsuite_VendorPayment_Apply: one row per apply/items entry
IF OBJECT_ID(N'dbo.tb_Netsuite_VendorPayment_Apply', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.[tb_Netsuite_VendorPayment_Apply] (
        -- BPA control fields (standard block, same as the other tb_Netsuite_* tables)
        [BPA_Origin]                                       nvarchar(50)          NULL,
        [BPA_Direction]                                    nvarchar(50)          NULL,
        [BPA_Company]                                      nvarchar(50)          NULL,
        [BPA_EntryID]                                      uniqueidentifier      NOT NULL CONSTRAINT [DF_tb_Netsuite_VendorPayment_Apply_EntryID] DEFAULT (newsequentialid()),
        [BPA_ParentID]                                     uniqueidentifier      NULL,
        [BPA_Status]                                       int                   NULL CONSTRAINT [DF_tb_Netsuite_VendorPayment_Apply_Status] DEFAULT ((0)),
        [BPA_Reference]                                    nvarchar(50)          NULL,
        [BPA_Reference_Description]                        nvarchar(100)         NULL,
        [BPA_Reference2]                                   nvarchar(50)          NULL,
        [BPA_Reference2_Description]                       nvarchar(100)         NULL,
        [BPA_Action]                                       nvarchar(1)           NULL,
        [BPA_ReturnedID]                                   nvarchar(50)          NULL,
        [BPA_Syscreated]                                   datetime              NULL CONSTRAINT [DF_tb_Netsuite_VendorPayment_Apply_Syscreated] DEFAULT (getdate()),
        [BPA_Sysmodified]                                  datetime              NULL CONSTRAINT [DF_tb_Netsuite_VendorPayment_Apply_Sysmodified] DEFAULT (getdate()),
        [BPA_Syscreator]                                   nvarchar(50)          NULL,
        [BPA_Error]                                        nvarchar(max)         NULL,
        [BPA_Error_Extended]                               nvarchar(max)         NULL,
        [BPA_Description]                                  nvarchar(255)         NULL,
        [BPA_Failcount]                                    int                   NULL CONSTRAINT [DF_tb_Netsuite_VendorPayment_Apply_Failcount] DEFAULT ((0)),
        [BPA_Orig_Entryid]                                 uniqueidentifier      NULL,
        [BPA_TaskInstanceID]                               int                   NULL,
        [BPA_TaskID]                                       int                   NULL,

        -- Parent: BPA_ParentID = tb_Netsuite_VendorPayment.BPA_EntryID
        [vendorPayment_id]                                 nvarchar(100),        -- vendorPayment/id (the parent's NetSuite id)

        -- Line fields (apply/items)
        [amount]                                           decimal(19,4),
        [apply]                                            bit,
        [applyDate]                                        date,
        [createdFrom]                                      nvarchar(400),
        [currency]                                         nvarchar(100),
        [disc]                                             decimal(19,4),
        [discAmt]                                          decimal(19,4),
        [due]                                              decimal(19,4),
        [line]                                             int,
        [refName]                                          nvarchar(400),
        [refNum]                                           nvarchar(100),
        [total]                                            decimal(19,4),
        [type]                                             nvarchar(100),

        -- Referenced records on the line (flattened: <object>/<field> -> <object>_<field>)
        [doc_id]                                           nvarchar(100),        -- apply/items/doc/id
        [doc_externalId]                                   nvarchar(100),        -- apply/items/doc/externalId
        [doc_refName]                                      nvarchar(400),        -- apply/items/doc/refName

        CONSTRAINT [PK_tb_Netsuite_VendorPayment_Apply] PRIMARY KEY CLUSTERED ([BPA_EntryID])
    );

    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_VendorPayment_Apply_BPA_ParentID] ON dbo.[tb_Netsuite_VendorPayment_Apply] ([BPA_ParentID]);
    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_VendorPayment_Apply_vendorPayment_id] ON dbo.[tb_Netsuite_VendorPayment_Apply] ([vendorPayment_id], [line]);
    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_VendorPayment_Apply_BPA_Status]
        ON dbo.[tb_Netsuite_VendorPayment_Apply] ([BPA_Status], [BPA_Direction]) INCLUDE ([vendorPayment_id], [BPA_Company]);
    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_VendorPayment_Apply_doc_id] ON dbo.[tb_Netsuite_VendorPayment_Apply] ([doc_id]) INCLUDE ([vendorPayment_id], [amount]);

    PRINT N'Created dbo.[tb_Netsuite_VendorPayment_Apply]';
END
ELSE
    PRINT N'Skipped dbo.[tb_Netsuite_VendorPayment_Apply] (table already exists)';

-- tb_Netsuite_VendorPayment_Credit: one row per credit/items entry
IF OBJECT_ID(N'dbo.tb_Netsuite_VendorPayment_Credit', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.[tb_Netsuite_VendorPayment_Credit] (
        -- BPA control fields (standard block, same as the other tb_Netsuite_* tables)
        [BPA_Origin]                                       nvarchar(50)          NULL,
        [BPA_Direction]                                    nvarchar(50)          NULL,
        [BPA_Company]                                      nvarchar(50)          NULL,
        [BPA_EntryID]                                      uniqueidentifier      NOT NULL CONSTRAINT [DF_tb_Netsuite_VendorPayment_Credit_EntryID] DEFAULT (newsequentialid()),
        [BPA_ParentID]                                     uniqueidentifier      NULL,
        [BPA_Status]                                       int                   NULL CONSTRAINT [DF_tb_Netsuite_VendorPayment_Credit_Status] DEFAULT ((0)),
        [BPA_Reference]                                    nvarchar(50)          NULL,
        [BPA_Reference_Description]                        nvarchar(100)         NULL,
        [BPA_Reference2]                                   nvarchar(50)          NULL,
        [BPA_Reference2_Description]                       nvarchar(100)         NULL,
        [BPA_Action]                                       nvarchar(1)           NULL,
        [BPA_ReturnedID]                                   nvarchar(50)          NULL,
        [BPA_Syscreated]                                   datetime              NULL CONSTRAINT [DF_tb_Netsuite_VendorPayment_Credit_Syscreated] DEFAULT (getdate()),
        [BPA_Sysmodified]                                  datetime              NULL CONSTRAINT [DF_tb_Netsuite_VendorPayment_Credit_Sysmodified] DEFAULT (getdate()),
        [BPA_Syscreator]                                   nvarchar(50)          NULL,
        [BPA_Error]                                        nvarchar(max)         NULL,
        [BPA_Error_Extended]                               nvarchar(max)         NULL,
        [BPA_Description]                                  nvarchar(255)         NULL,
        [BPA_Failcount]                                    int                   NULL CONSTRAINT [DF_tb_Netsuite_VendorPayment_Credit_Failcount] DEFAULT ((0)),
        [BPA_Orig_Entryid]                                 uniqueidentifier      NULL,
        [BPA_TaskInstanceID]                               int                   NULL,
        [BPA_TaskID]                                       int                   NULL,

        -- Parent: BPA_ParentID = tb_Netsuite_VendorPayment.BPA_EntryID
        [vendorPayment_id]                                 nvarchar(100),        -- vendorPayment/id (the parent's NetSuite id)

        -- Line fields (credit/items)
        [amount]                                           decimal(19,4),
        [appliedTo]                                        nvarchar(400),
        [apply]                                            bit,
        [createdFrom]                                      nvarchar(400),
        [creditDate]                                       date,
        [currency]                                         nvarchar(100),
        [due]                                              decimal(19,4),
        [line]                                             int,
        [refName]                                          nvarchar(400),
        [refNum]                                           nvarchar(100),
        [total]                                            decimal(19,4),
        [type]                                             nvarchar(100),

        CONSTRAINT [PK_tb_Netsuite_VendorPayment_Credit] PRIMARY KEY CLUSTERED ([BPA_EntryID])
    );

    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_VendorPayment_Credit_BPA_ParentID] ON dbo.[tb_Netsuite_VendorPayment_Credit] ([BPA_ParentID]);
    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_VendorPayment_Credit_vendorPayment_id] ON dbo.[tb_Netsuite_VendorPayment_Credit] ([vendorPayment_id], [line]);
    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_VendorPayment_Credit_BPA_Status]
        ON dbo.[tb_Netsuite_VendorPayment_Credit] ([BPA_Status], [BPA_Direction]) INCLUDE ([vendorPayment_id], [BPA_Company]);

    PRINT N'Created dbo.[tb_Netsuite_VendorPayment_Credit]';
END
ELSE
    PRINT N'Skipped dbo.[tb_Netsuite_VendorPayment_Credit] (table already exists)';

-- tb_Netsuite_JournalEntry_Line: one row per line/items entry
IF OBJECT_ID(N'dbo.tb_Netsuite_JournalEntry_Line', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.[tb_Netsuite_JournalEntry_Line] (
        -- BPA control fields (standard block, same as the other tb_Netsuite_* tables)
        [BPA_Origin]                                       nvarchar(50)          NULL,
        [BPA_Direction]                                    nvarchar(50)          NULL,
        [BPA_Company]                                      nvarchar(50)          NULL,
        [BPA_EntryID]                                      uniqueidentifier      NOT NULL CONSTRAINT [DF_tb_Netsuite_JournalEntry_Line_EntryID] DEFAULT (newsequentialid()),
        [BPA_ParentID]                                     uniqueidentifier      NULL,
        [BPA_Status]                                       int                   NULL CONSTRAINT [DF_tb_Netsuite_JournalEntry_Line_Status] DEFAULT ((0)),
        [BPA_Reference]                                    nvarchar(50)          NULL,
        [BPA_Reference_Description]                        nvarchar(100)         NULL,
        [BPA_Reference2]                                   nvarchar(50)          NULL,
        [BPA_Reference2_Description]                       nvarchar(100)         NULL,
        [BPA_Action]                                       nvarchar(1)           NULL,
        [BPA_ReturnedID]                                   nvarchar(50)          NULL,
        [BPA_Syscreated]                                   datetime              NULL CONSTRAINT [DF_tb_Netsuite_JournalEntry_Line_Syscreated] DEFAULT (getdate()),
        [BPA_Sysmodified]                                  datetime              NULL CONSTRAINT [DF_tb_Netsuite_JournalEntry_Line_Sysmodified] DEFAULT (getdate()),
        [BPA_Syscreator]                                   nvarchar(50)          NULL,
        [BPA_Error]                                        nvarchar(max)         NULL,
        [BPA_Error_Extended]                               nvarchar(max)         NULL,
        [BPA_Description]                                  nvarchar(255)         NULL,
        [BPA_Failcount]                                    int                   NULL CONSTRAINT [DF_tb_Netsuite_JournalEntry_Line_Failcount] DEFAULT ((0)),
        [BPA_Orig_Entryid]                                 uniqueidentifier      NULL,
        [BPA_TaskInstanceID]                               int                   NULL,
        [BPA_TaskID]                                       int                   NULL,

        -- Parent: BPA_ParentID = tb_Netsuite_JournalEntry.BPA_EntryID
        [journalEntry_id]                                  nvarchar(100),        -- journalEntry/id (the parent's NetSuite id)

        -- Line fields (line/items)
        [amortizationType]                                 nvarchar(400),
        [baseGrossAmt]                                     decimal(19,4),
        [cleared]                                          bit,
        [clearedDate]                                      date,
        [credit]                                           decimal(19,4),
        [debit]                                            decimal(19,4),
        [eliminate]                                        bit,
        [endDate]                                          date,
        [grossAmt]                                         decimal(19,4),
        [line]                                             int,
        [lineCreatedDate]                                  datetimeoffset(0),
        [lineLastModifiedDate]                             datetimeoffset(0),
        [memo]                                             nvarchar(4000),
        [refName]                                          nvarchar(400),
        [residual]                                         decimal(19,4),
        [startDate]                                        date,
        [tax1Amt]                                          decimal(19,4),
        [taxRate1]                                         decimal(28,10),

        -- Referenced records on the line (flattened: <object>/<field> -> <object>_<field>)
        [account_id]                                       nvarchar(100),        -- line/items/account/id
        [account_acctNumber]                               nvarchar(100),        -- line/items/account/acctNumber
        [account_refName]                                  nvarchar(400),        -- line/items/account/refName
        [department_id]                                    nvarchar(100),        -- line/items/department/id
        [department_refName]                               nvarchar(400),        -- line/items/department/refName
        [class_id]                                         nvarchar(100),        -- line/items/class/id
        [class_refName]                                    nvarchar(400),        -- line/items/class/refName
        [location_id]                                      nvarchar(100),        -- line/items/location/id
        [location_refName]                                 nvarchar(400),        -- line/items/location/refName
        [entity_id]                                        nvarchar(100),        -- line/items/entity/id
        [entity_externalId]                                nvarchar(100),        -- line/items/entity/externalId
        [entity_refName]                                   nvarchar(400),        -- line/items/entity/refName

        -- Custom line fields
        [custcol_15529_eft_enabled]                        bit,
        [custcol_2663_companyname]                         nvarchar(400),
        [custcol_2663_firstname]                           nvarchar(400),
        [custcol_2663_isperson]                            bit,
        [custcol_2663_lastname]                            nvarchar(400),
        [custcol_4601_witaxamount]                         decimal(28,10),
        [custcol_4601_witaxamount_je]                      decimal(28,10),
        [custcol_4601_witaxamt_exp]                        decimal(28,10),
        [custcol_4601_witaxapplies]                        bit,
        [custcol_4601_witaxbamt_exp]                       decimal(28,10),
        [custcol_4601_witaxbaseamount]                     decimal(28,10),
        [custcol_4601_witaxbaseamount_je]                  decimal(28,10),
        [custcol_4601_witaxline]                           nvarchar(400),
        [custcol_4601_witaxline_exp]                       nvarchar(400),
        [custcol_4601_witaxline_je]                        nvarchar(400),
        [custcol_4601_witaxrate]                           decimal(28,10),
        [custcol_4601_witaxrate_exp]                       decimal(28,10),
        [custcol_4601_witaxrate_je]                        decimal(28,10),
        [custcol_5892_eutriangulation]                     bit,
        [custcol_adjustment_field]                         nvarchar(400),
        [custcol_counterparty_vat]                         nvarchar(400),
        [custcol_country_of_origin_code]                   nvarchar(400),
        [custcol_country_of_origin_name]                   nvarchar(400),
        [custcol_establishment_code]                       nvarchar(400),
        [custcol_il_amount]                                decimal(28,10),
        [custcol_il_amount_txtran]                         decimal(28,10),
        [custcol_il_bank_account_number]                   nvarchar(400),
        [custcol_il_bank_code]                             nvarchar(400),
        [custcol_il_of_bonded_flag]                        bit,
        [custcol_il_taxamount]                             decimal(28,10),
        [custcol_il_taxamount_txtran]                      decimal(28,10),
        [custcol_il_unittype]                              nvarchar(400),
        [custcol_il_wht_amount]                            decimal(28,10),
        [custcol_il_wht_rate]                              decimal(28,10),
        [custcol_nexil_bill_qta_line_itemrcpt]             decimal(28,10),
        [custcol_nexil_billing_additional_cost]            decimal(28,10),
        [custcol_nexil_building_country]                   nvarchar(400),
        [custcol_nexil_cash_acc_amount]                    decimal(28,10),
        [custcol_nexil_cash_acc_und_amount]                decimal(28,10),
        [custcol_nexil_cash_acc_und_tax]                   decimal(28,10),
        [custcol_nexil_cogb_relatedprevperiod]             bit,
        [custcol_nexil_cu_isflatrate]                      bit,
        [custcol_nexil_custombill_net_amt]                 decimal(28,10),
        [custcol_nexil_deductible]                         bit,
        [custcol_nexil_eleinv_isdiscountitem]              bit,
        [custcol_nexil_if_connected_list]                  nvarchar(max),
        [custcol_nexil_itm_rcpt_number]                    nvarchar(400),
        [custcol_nexil_itm_rcpt_number_html]               nvarchar(max),
        [custcol_nexil_otc_closedline]                     bit,
        [custcol_nexil_otc_ddtref]                         nvarchar(400),
        [custcol_nexil_otc_qtytofulfill]                   decimal(28,10),
        [custcol_nexil_otc_shipto]                         nvarchar(max),
        [custcol_nexil_otc_shiptoid]                       nvarchar(400),
        [custcol_nexil_otc_useinfulfill]                   bit,
        [custcol_nexil_prepayment_invoices]                nvarchar(max),
        [custcol_nexil_province_of_origin]                 nvarchar(400),
        [custcol_nexil_refdate]                            nvarchar(400),
        [custcol_nexil_related_transaction_dat]            nvarchar(400),
        [custcol_nexil_revchrage_added]                    bit,
        [custcol_nexil_sc_isexempttosc]                    bit,
        [custcol_nexil_sc_isgrossamt]                      bit,
        [custcol_nexil_sc_isnotsubjectedtosc]              bit,
        [custcol_nexil_statistic_value]                    decimal(28,10),
        [custcol_nexil_valuecode]                          nvarchar(400),
        [custcol_nexil_weight]                             decimal(28,10),
        [custcol_nexil_weight_unit]                        nvarchar(400),
        [custcol_nexil_witaxamount]                        decimal(28,10),
        [custcol_nexil_witaxapplies]                       bit,
        [custcol_nexil_yourref]                            nvarchar(400),
        [custcol_ph4014_src_tranintid]                     nvarchar(400),
        [custcol_sii_annual_prorate]                       decimal(28,10),
        [custcol_sii_service_date]                         nvarchar(400),
        [custcol_statistical_value]                        decimal(28,10),
        [custcol_statistical_value_base_curr]              decimal(28,10),
        [custcol_wht_src_companyname]                      nvarchar(400),
        [custcol_wht_src_firstname]                        nvarchar(400),
        [custcol_wht_src_isperson]                         bit,
        [custcol_wht_src_lastname]                         nvarchar(400),
        [custcol_wht_src_middlename]                       nvarchar(400),
        [custcol_wht_src_vat_reg_no]                       nvarchar(400),
        [custcol_x_cpempleado]                             nvarchar(400),
        [custcol_x_dniempleado]                            nvarchar(400),
        [custcol_x_irpf193]                                decimal(28,10),
        [custcol_x_le_apellidoempleado]                    nvarchar(400),
        [custcol_x_le_nombreempleado]                      nvarchar(400),
        [custcol_xbaseirpf]                                decimal(28,10),

        CONSTRAINT [PK_tb_Netsuite_JournalEntry_Line] PRIMARY KEY CLUSTERED ([BPA_EntryID])
    );

    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_JournalEntry_Line_BPA_ParentID] ON dbo.[tb_Netsuite_JournalEntry_Line] ([BPA_ParentID]);
    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_JournalEntry_Line_journalEntry_id] ON dbo.[tb_Netsuite_JournalEntry_Line] ([journalEntry_id], [line]);
    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_JournalEntry_Line_BPA_Status]
        ON dbo.[tb_Netsuite_JournalEntry_Line] ([BPA_Status], [BPA_Direction]) INCLUDE ([journalEntry_id], [BPA_Company]);
    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_JournalEntry_Line_account_id] ON dbo.[tb_Netsuite_JournalEntry_Line] ([account_id]) INCLUDE ([debit], [credit], [entity_id]);

    PRINT N'Created dbo.[tb_Netsuite_JournalEntry_Line]';
END
ELSE
    PRINT N'Skipped dbo.[tb_Netsuite_JournalEntry_Line] (table already exists)';
