/*
    Staging tables for the Ellomay "openstaande posten" (open items) BPA FROM tasks.

    Open items come from four NetSuite transaction types:
        Debiteuren (AR):  Invoice        -> tb_Netsuite_Invoice
                          Credit Memo    -> tb_Netsuite_CreditMemo
        Crediteuren (AP): Vendor Bill    -> tb_Netsuite_VendorBill   (already exists, not touched here)
                          Vendor Credit  -> tb_Netsuite_VendorCredit

    All three tables share the same column layout so they can be unioned into one
    open-items overview together with tb_Netsuite_VendorBill.

    - [id] is the NetSuite internalId, nvarchar(100) like the other tb_Netsuite_* tables.
    - [openAmount] is the amount still open, in transaction currency:
          Invoice       -> amountRemaining
          Credit Memo   -> unapplied
          Vendor Credit -> unApplied
      Amounts are stored as NetSuite returns them (positive); the sign per
      debiteur/crediteur side is applied when combining the tables.
    - [loadDate] is filled by SQL Server when BPA inserts the row.

    The tables hold a snapshot of what is open right now: the BPA job should empty
    them before each load, otherwise items that were paid / applied since the
    previous run stay behind.

    Safe to run more than once: existing tables are left as they are.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
BEGIN TRANSACTION;

IF OBJECT_ID(N'dbo.tb_Netsuite_Invoice', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.tb_Netsuite_Invoice (
        id                 nvarchar(100)  NOT NULL,
        tranId             nvarchar(100)  NULL,
        status             nvarchar(100)  NULL,
        entityId           nvarchar(100)  NULL,
        entityName         nvarchar(250)  NULL,
        subsidiaryId       nvarchar(100)  NULL,
        subsidiaryName     nvarchar(250)  NULL,
        accountId          nvarchar(100)  NULL,
        accountName        nvarchar(250)  NULL,
        postingPeriodId    nvarchar(100)  NULL,
        postingPeriodName  nvarchar(100)  NULL,
        currencyId         nvarchar(100)  NULL,
        currencyName       nvarchar(100)  NULL,
        exchangeRate       decimal(28,10) NULL,
        tranDate           date           NULL,
        dueDate            date           NULL,
        otherRefNum        nvarchar(100)  NULL,
        memo               nvarchar(4000) NULL,
        total              decimal(19,4)  NULL,
        openAmount         decimal(19,4)  NULL,
        lastModifiedDate   datetime2(0)   NULL,
        loadDate           datetime2(0)   NOT NULL CONSTRAINT DF_tb_Netsuite_Invoice_loadDate DEFAULT SYSDATETIME(),
        CONSTRAINT PK_tb_Netsuite_Invoice PRIMARY KEY CLUSTERED (id)
    );
    PRINT N'Created dbo.tb_Netsuite_Invoice';
END
ELSE
    PRINT N'Skipped dbo.tb_Netsuite_Invoice (already exists)';

IF OBJECT_ID(N'dbo.tb_Netsuite_CreditMemo', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.tb_Netsuite_CreditMemo (
        id                 nvarchar(100)  NOT NULL,
        tranId             nvarchar(100)  NULL,
        status             nvarchar(100)  NULL,
        entityId           nvarchar(100)  NULL,
        entityName         nvarchar(250)  NULL,
        subsidiaryId       nvarchar(100)  NULL,
        subsidiaryName     nvarchar(250)  NULL,
        accountId          nvarchar(100)  NULL,
        accountName        nvarchar(250)  NULL,
        postingPeriodId    nvarchar(100)  NULL,
        postingPeriodName  nvarchar(100)  NULL,
        currencyId         nvarchar(100)  NULL,
        currencyName       nvarchar(100)  NULL,
        exchangeRate       decimal(28,10) NULL,
        tranDate           date           NULL,
        dueDate            date           NULL,
        otherRefNum        nvarchar(100)  NULL,
        memo               nvarchar(4000) NULL,
        total              decimal(19,4)  NULL,
        openAmount         decimal(19,4)  NULL,
        lastModifiedDate   datetime2(0)   NULL,
        loadDate           datetime2(0)   NOT NULL CONSTRAINT DF_tb_Netsuite_CreditMemo_loadDate DEFAULT SYSDATETIME(),
        CONSTRAINT PK_tb_Netsuite_CreditMemo PRIMARY KEY CLUSTERED (id)
    );
    PRINT N'Created dbo.tb_Netsuite_CreditMemo';
END
ELSE
    PRINT N'Skipped dbo.tb_Netsuite_CreditMemo (already exists)';

IF OBJECT_ID(N'dbo.tb_Netsuite_VendorCredit', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.tb_Netsuite_VendorCredit (
        id                 nvarchar(100)  NOT NULL,
        tranId             nvarchar(100)  NULL,
        status             nvarchar(100)  NULL,
        entityId           nvarchar(100)  NULL,
        entityName         nvarchar(250)  NULL,
        subsidiaryId       nvarchar(100)  NULL,
        subsidiaryName     nvarchar(250)  NULL,
        accountId          nvarchar(100)  NULL,
        accountName        nvarchar(250)  NULL,
        postingPeriodId    nvarchar(100)  NULL,
        postingPeriodName  nvarchar(100)  NULL,
        currencyId         nvarchar(100)  NULL,
        currencyName       nvarchar(100)  NULL,
        exchangeRate       decimal(28,10) NULL,
        tranDate           date           NULL,
        dueDate            date           NULL,
        otherRefNum        nvarchar(100)  NULL,
        memo               nvarchar(4000) NULL,
        total              decimal(19,4)  NULL,
        openAmount         decimal(19,4)  NULL,
        lastModifiedDate   datetime2(0)   NULL,
        loadDate           datetime2(0)   NOT NULL CONSTRAINT DF_tb_Netsuite_VendorCredit_loadDate DEFAULT SYSDATETIME(),
        CONSTRAINT PK_tb_Netsuite_VendorCredit PRIMARY KEY CLUSTERED (id)
    );
    PRINT N'Created dbo.tb_Netsuite_VendorCredit';
END
ELSE
    PRINT N'Skipped dbo.tb_Netsuite_VendorCredit (already exists)';

COMMIT TRANSACTION;
