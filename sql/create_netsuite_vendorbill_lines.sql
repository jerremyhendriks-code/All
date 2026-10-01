/*
    Child tables for the vendorBill sublists, as returned by the BPA NetSuite connector
    (schema: schemas/netsuite/vendorBill.xsd).

        vendorBill.item.items[]    -> tb_Netsuite_VendorBill_Item
        vendorBill.expense.items[] -> tb_Netsuite_VendorBill_Expense

    - Same layout as the other tb_Netsuite_* tables: the BPA_* control fields first,
      primary key on [BPA_EntryID] (newsequentialid), then the payload fields.
    - [BPA_ParentID] holds the [BPA_EntryID] of the tb_Netsuite_VendorBill row the
      line belongs to.
    - Reference fields (item, account, department, taxCode) are stored as
      <name>_id + <name>_refName. The rest of the expanded record (e.g. the 41
      account fields) is left out; that data belongs in its own tb_Netsuite_* table.
    - Custom line fields (custcol_*) are left out. In this schema they all come from
      localisation bundles (IL, IT nexil, ES SII, withholding tax) and aren't needed
      for open items.
    - The connector returns every value as a string. Booleans arrive as 'True'/'False',
      which SQL Server converts to bit.

    Safe to run more than once: existing tables are left as they are.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
BEGIN TRANSACTION;

IF OBJECT_ID(N'dbo.tb_Netsuite_VendorBill_Item', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.tb_Netsuite_VendorBill_Item (
        BPA_Origin                  nvarchar(50)   NULL,
        BPA_Direction               nvarchar(50)   NULL,
        BPA_Company                 nvarchar(50)   NULL,
        BPA_EntryID                 uniqueidentifier NOT NULL CONSTRAINT DF_tb_Netsuite_VendorBill_Item_EntryID DEFAULT (newsequentialid()),
        BPA_ParentID                uniqueidentifier NULL,
        BPA_Status                  int            NULL CONSTRAINT DF_tb_Netsuite_VendorBill_Item_Status DEFAULT ((0)),
        BPA_Reference               nvarchar(50)   NULL,
        BPA_Reference_Description   nvarchar(100)  NULL,
        BPA_Reference2              nvarchar(50)   NULL,
        BPA_Reference2_Description  nvarchar(100)  NULL,
        BPA_Action                  nvarchar(1)    NULL,
        BPA_ReturnedID              nvarchar(50)   NULL,
        BPA_Syscreated              datetime       NULL CONSTRAINT DF_tb_Netsuite_VendorBill_Item_Syscreated DEFAULT (getdate()),
        BPA_Sysmodified             datetime       NULL CONSTRAINT DF_tb_Netsuite_VendorBill_Item_Sysmodified DEFAULT (getdate()),
        BPA_Syscreator              nvarchar(50)   NULL,
        BPA_Error                   nvarchar(max)  NULL,
        BPA_Error_Extended          nvarchar(max)  NULL,
        BPA_Description             nvarchar(255)  NULL,
        BPA_Failcount               int            NULL CONSTRAINT DF_tb_Netsuite_VendorBill_Item_Failcount DEFAULT ((0)),
        BPA_Orig_Entryid            uniqueidentifier NULL,
        BPA_TaskInstanceID          int            NULL,
        BPA_TaskID                  int            NULL,
        line                        int            NULL,
        uniqueKey                   bigint         NULL,
        description                 nvarchar(4000) NULL,
        vendorName                  nvarchar(200)  NULL,
        quantity                    decimal(28,10) NULL,
        units                       nvarchar(100)  NULL,
        rate                        decimal(28,10) NULL,
        amount                      decimal(19,4)  NULL,
        grossAmt                    decimal(19,4)  NULL,
        baseGrossAmt                decimal(19,4)  NULL,
        tax1Amt                     decimal(19,4)  NULL,
        taxRate1                    decimal(9,4)   NULL,
        taxRate2                    decimal(9,4)   NULL,
        isBillable                  bit            NULL,
        isClosed                    bit            NULL,
        isOpen                      bit            NULL,
        isTaxable                   bit            NULL,
        linked                      bit            NULL,
        marginal                    bit            NULL,
        deferRevRec                 bit            NULL,
        orderLine                   int            NULL,
        scheduleType                nvarchar(100)  NULL,
        amortizationType            nvarchar(100)  NULL,
        amortizStartDate            date           NULL,
        amortizationEndDate         date           NULL,
        amortizationResidual        nvarchar(100)  NULL,
        item_id                     nvarchar(50)   NULL,
        item_refName                nvarchar(200)  NULL,
        taxCode_id                  nvarchar(50)   NULL,
        taxCode_refName             nvarchar(200)  NULL,
        CONSTRAINT PK_tb_Netsuite_VendorBill_Item PRIMARY KEY CLUSTERED (BPA_EntryID)
    );
    CREATE NONCLUSTERED INDEX IX_tb_Netsuite_VendorBill_Item_ParentID
        ON dbo.tb_Netsuite_VendorBill_Item (BPA_ParentID);
    PRINT N'Created dbo.tb_Netsuite_VendorBill_Item';
END
ELSE
    PRINT N'Skipped dbo.tb_Netsuite_VendorBill_Item (already exists)';

IF OBJECT_ID(N'dbo.tb_Netsuite_VendorBill_Expense', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.tb_Netsuite_VendorBill_Expense (
        BPA_Origin                  nvarchar(50)   NULL,
        BPA_Direction               nvarchar(50)   NULL,
        BPA_Company                 nvarchar(50)   NULL,
        BPA_EntryID                 uniqueidentifier NOT NULL CONSTRAINT DF_tb_Netsuite_VendorBill_Expense_EntryID DEFAULT (newsequentialid()),
        BPA_ParentID                uniqueidentifier NULL,
        BPA_Status                  int            NULL CONSTRAINT DF_tb_Netsuite_VendorBill_Expense_Status DEFAULT ((0)),
        BPA_Reference               nvarchar(50)   NULL,
        BPA_Reference_Description   nvarchar(100)  NULL,
        BPA_Reference2              nvarchar(50)   NULL,
        BPA_Reference2_Description  nvarchar(100)  NULL,
        BPA_Action                  nvarchar(1)    NULL,
        BPA_ReturnedID              nvarchar(50)   NULL,
        BPA_Syscreated              datetime       NULL CONSTRAINT DF_tb_Netsuite_VendorBill_Expense_Syscreated DEFAULT (getdate()),
        BPA_Sysmodified             datetime       NULL CONSTRAINT DF_tb_Netsuite_VendorBill_Expense_Sysmodified DEFAULT (getdate()),
        BPA_Syscreator              nvarchar(50)   NULL,
        BPA_Error                   nvarchar(max)  NULL,
        BPA_Error_Extended          nvarchar(max)  NULL,
        BPA_Description             nvarchar(255)  NULL,
        BPA_Failcount               int            NULL CONSTRAINT DF_tb_Netsuite_VendorBill_Expense_Failcount DEFAULT ((0)),
        BPA_Orig_Entryid            uniqueidentifier NULL,
        BPA_TaskInstanceID          int            NULL,
        BPA_TaskID                  int            NULL,
        line                        int            NULL,
        memo                        nvarchar(4000) NULL,
        amount                      decimal(19,4)  NULL,
        grossAmt                    decimal(19,4)  NULL,
        baseGrossAmt                decimal(19,4)  NULL,
        tax1Amt                     decimal(19,4)  NULL,
        taxRate1                    decimal(9,4)   NULL,
        taxRate2                    decimal(9,4)   NULL,
        orderDoc                    nvarchar(100)  NULL,
        orderLine                   nvarchar(100)  NULL,
        scheduleType                nvarchar(100)  NULL,
        amortizationType            nvarchar(100)  NULL,
        amortizStartDate            date           NULL,
        amortizationEndDate         date           NULL,
        amortizationResidual        nvarchar(100)  NULL,
        account_id                  nvarchar(50)   NULL,
        account_refName             nvarchar(200)  NULL,
        department_id               nvarchar(50)   NULL,
        department_refName          nvarchar(200)  NULL,
        taxCode_id                  nvarchar(50)   NULL,
        taxCode_refName             nvarchar(200)  NULL,
        CONSTRAINT PK_tb_Netsuite_VendorBill_Expense PRIMARY KEY CLUSTERED (BPA_EntryID)
    );
    CREATE NONCLUSTERED INDEX IX_tb_Netsuite_VendorBill_Expense_ParentID
        ON dbo.tb_Netsuite_VendorBill_Expense (BPA_ParentID);
    PRINT N'Created dbo.tb_Netsuite_VendorBill_Expense';
END
ELSE
    PRINT N'Skipped dbo.tb_Netsuite_VendorBill_Expense (already exists)';

COMMIT TRANSACTION;
