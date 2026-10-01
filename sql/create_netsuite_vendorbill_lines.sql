/*
    Child tables for the vendorBill sublists, as returned by the BPA NetSuite connector
    (schema: schemas/netsuite/vendorBill.xsd).

        vendorBill.item.items[]    -> tb_Netsuite_VendorBill_Item
        vendorBill.expense.items[] -> tb_Netsuite_VendorBill_Expense

    - [vendorBillId] is vendorBill.id; together with [line] it is the primary key.
    - Reference fields (item, account, department, taxCode) are stored as <name>Id +
      <name>RefName. The rest of the expanded record (e.g. the 41 account fields) is
      left out; that data belongs in its own tb_Netsuite_* table.
    - Custom line fields (custcol_*) are left out. In this schema they all come from
      localisation bundles (IL, IT nexil, ES SII, withholding tax) and aren't needed
      for open items.
    - The connector returns every value as a string. Booleans arrive as 'True'/'False',
      which SQL Server converts to bit.
    - [loadDate] is filled by SQL Server when BPA inserts the row.

    Safe to run more than once: existing tables are left as they are.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
BEGIN TRANSACTION;

IF OBJECT_ID(N'dbo.tb_Netsuite_VendorBill_Item', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.tb_Netsuite_VendorBill_Item (
        vendorBillId          nvarchar(100)  NOT NULL,
        line                  int            NOT NULL,
        uniqueKey             bigint         NULL,
        itemId                nvarchar(100)  NULL,
        itemRefName           nvarchar(250)  NULL,
        description           nvarchar(4000) NULL,
        vendorName            nvarchar(250)  NULL,
        quantity              decimal(28,10) NULL,
        units                 nvarchar(100)  NULL,
        rate                  decimal(28,10) NULL,
        amount                decimal(19,4)  NULL,
        grossAmt              decimal(19,4)  NULL,
        baseGrossAmt          decimal(19,4)  NULL,
        tax1Amt               decimal(19,4)  NULL,
        taxRate1              decimal(9,4)   NULL,
        taxRate2              decimal(9,4)   NULL,
        taxCodeId             nvarchar(100)  NULL,
        taxCodeRefName        nvarchar(250)  NULL,
        isBillable            bit            NULL,
        isClosed              bit            NULL,
        isOpen                bit            NULL,
        isTaxable             bit            NULL,
        linked                bit            NULL,
        marginal              bit            NULL,
        deferRevRec           bit            NULL,
        orderLine             int            NULL,
        scheduleType          nvarchar(100)  NULL,
        amortizationType      nvarchar(100)  NULL,
        amortizStartDate      date           NULL,
        amortizationEndDate   date           NULL,
        amortizationResidual  nvarchar(100)  NULL,
        loadDate              datetime2(0)   NOT NULL CONSTRAINT DF_tb_Netsuite_VendorBill_Item_loadDate DEFAULT SYSDATETIME(),
        CONSTRAINT PK_tb_Netsuite_VendorBill_Item PRIMARY KEY CLUSTERED (vendorBillId, line)
    );
    PRINT N'Created dbo.tb_Netsuite_VendorBill_Item';
END
ELSE
    PRINT N'Skipped dbo.tb_Netsuite_VendorBill_Item (already exists)';

IF OBJECT_ID(N'dbo.tb_Netsuite_VendorBill_Expense', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.tb_Netsuite_VendorBill_Expense (
        vendorBillId          nvarchar(100)  NOT NULL,
        line                  int            NOT NULL,
        accountId             nvarchar(100)  NULL,
        accountRefName        nvarchar(250)  NULL,
        departmentId          nvarchar(100)  NULL,
        departmentRefName     nvarchar(250)  NULL,
        memo                  nvarchar(4000) NULL,
        amount                decimal(19,4)  NULL,
        grossAmt              decimal(19,4)  NULL,
        baseGrossAmt          decimal(19,4)  NULL,
        tax1Amt               decimal(19,4)  NULL,
        taxRate1              decimal(9,4)   NULL,
        taxRate2              decimal(9,4)   NULL,
        taxCodeId             nvarchar(100)  NULL,
        taxCodeRefName        nvarchar(250)  NULL,
        orderDoc              nvarchar(100)  NULL,
        orderLine             nvarchar(100)  NULL,
        scheduleType          nvarchar(100)  NULL,
        amortizationType      nvarchar(100)  NULL,
        amortizStartDate      date           NULL,
        amortizationEndDate   date           NULL,
        amortizationResidual  nvarchar(100)  NULL,
        loadDate              datetime2(0)   NOT NULL CONSTRAINT DF_tb_Netsuite_VendorBill_Expense_loadDate DEFAULT SYSDATETIME(),
        CONSTRAINT PK_tb_Netsuite_VendorBill_Expense PRIMARY KEY CLUSTERED (vendorBillId, line)
    );
    PRINT N'Created dbo.tb_Netsuite_VendorBill_Expense';
END
ELSE
    PRINT N'Skipped dbo.tb_Netsuite_VendorBill_Expense (already exists)';

COMMIT TRANSACTION;
