/*
    Foundation Group - staging for the NetSuite vendorBill FROM task
    (NetSuite connector, vendorBill Search; object design in
    netsuite/foundation/NetSuiteConnector_vendorBill_Foundation.xml).

    dbo.tb_Netsuite_VendorBill            one row per bill per run
    dbo.tb_Netsuite_VendorBill_Expense    vendorBill/expense/items   one row per expense line
                                          BPA_ParentID = tb_Netsuite_VendorBill.BPA_EntryID
                                          vendorBillId = the bill's NetSuite id

    Column names are the NetSuite REST field names. A reference field
    (entity, subsidiary, account, department, custom select fields, ...) is stored
    as <field>Id + <field>RefName; the connector reads those two values from the
    record itself, without expanding the referenced record. See
    docs/foundation_vendorbill.md for the mapping from the BOD field names.

    Dates come from NetSuite as 'YYYY-MM-DD'; createdDate and lastModifiedDate as
    'YYYY-MM-DDThh:mm:ssZ' (UTC) and are stored in UTC.

    Item lines (vendorBill/item) are not loaded: the Foundation Group bills use
    the Expenses tab.

    Existing tables are renamed to <table>_bak (constraints included) before the
    new ones are created; drop the _bak tables once loading works. Stops without
    changes if a _bak table already exists. Runs in a single transaction.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
IF OBJECT_ID(N'tempdb..#rebuild') IS NOT NULL DROP PROCEDURE #rebuild;
GO
-- Renames an existing table to <table>_bak (constraints get a _bak suffix too),
-- so the new definition can be created without losing data.
CREATE PROCEDURE #rebuild @table sysname AS
BEGIN
    DECLARE @bak sysname = @table + N'_bak', @old sysname, @new sysname, @obj nvarchar(300), @msg nvarchar(400);
    IF OBJECT_ID(N'dbo.' + QUOTENAME(@table), N'U') IS NULL RETURN;
    IF OBJECT_ID(N'dbo.' + QUOTENAME(@bak), N'U') IS NOT NULL
    BEGIN
        SET @msg = N'dbo.' + @bak + N' already exists; drop or rename it first.';
        THROW 50001, @msg, 1;
    END
    SET @obj = N'dbo.' + QUOTENAME(@table);
    EXEC sys.sp_rename @objname = @obj, @newname = @bak, @objtype = N'OBJECT';
    PRINT N'Renamed  dbo.' + @table + N' -> ' + @bak;
    DECLARE con CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.objects
        WHERE parent_object_id = OBJECT_ID(N'dbo.' + QUOTENAME(@bak)) AND type IN ('PK', 'UQ', 'D', 'C', 'F');
    OPEN con;
    FETCH NEXT FROM con INTO @old;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @new = LEFT(@old, 124) + N'_bak';
        SET @obj = N'dbo.' + QUOTENAME(@old);
        EXEC sys.sp_rename @objname = @obj, @newname = @new, @objtype = N'OBJECT';
        FETCH NEXT FROM con INTO @old;
    END
    CLOSE con;
    DEALLOCATE con;
    -- index names are per table, but keep them recognisable
    DECLARE ix CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.indexes
        WHERE object_id = OBJECT_ID(N'dbo.' + QUOTENAME(@bak)) AND is_primary_key = 0
          AND is_unique_constraint = 0 AND name IS NOT NULL;
    OPEN ix;
    FETCH NEXT FROM ix INTO @old;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @new = LEFT(@old, 124) + N'_bak';
        SET @obj = N'dbo.' + QUOTENAME(@bak) + N'.' + QUOTENAME(@old);
        EXEC sys.sp_rename @objname = @obj, @newname = @new, @objtype = N'INDEX';
        FETCH NEXT FROM ix INTO @old;
    END
    CLOSE ix;
    DEALLOCATE ix;
END
GO
BEGIN TRANSACTION;

-- ---------------------------------------------------------------------------
-- Header
-- ---------------------------------------------------------------------------
EXEC #rebuild N'tb_Netsuite_VendorBill';
CREATE TABLE dbo.tb_Netsuite_VendorBill (
    -- BPA control fields (standard block, same as the other tb_Netsuite_* tables)
    BPA_Origin                          nvarchar(50)     NULL,
    BPA_Direction                       nvarchar(50)     NULL,
    BPA_Company                         nvarchar(50)     NULL,
    BPA_EntryID                         uniqueidentifier NOT NULL CONSTRAINT DF_tb_Netsuite_VendorBill_EntryID DEFAULT (newsequentialid()),
    BPA_ParentID                        uniqueidentifier NULL,
    BPA_Status                          int              NULL CONSTRAINT DF_tb_Netsuite_VendorBill_Status DEFAULT ((0)),
    BPA_Reference                       nvarchar(50)     NULL,
    BPA_Reference_Description           nvarchar(100)    NULL,
    BPA_Reference2                      nvarchar(50)     NULL,
    BPA_Reference2_Description          nvarchar(100)    NULL,
    BPA_Action                          nvarchar(1)      NULL,
    BPA_ReturnedID                      nvarchar(50)     NULL,
    BPA_Syscreated                      datetime         NULL CONSTRAINT DF_tb_Netsuite_VendorBill_Syscreated DEFAULT (getdate()),
    BPA_Sysmodified                     datetime         NULL CONSTRAINT DF_tb_Netsuite_VendorBill_Sysmodified DEFAULT (getdate()),
    BPA_Syscreator                      nvarchar(50)     NULL,
    BPA_Error                           nvarchar(max)    NULL,
    BPA_Error_Extended                  nvarchar(max)    NULL,
    BPA_Description                     nvarchar(255)    NULL,
    BPA_Failcount                       int              NULL CONSTRAINT DF_tb_Netsuite_VendorBill_Failcount DEFAULT ((0)),
    BPA_Orig_Entryid                    uniqueidentifier NULL,
    BPA_TaskInstanceID                  int              NULL,
    BPA_TaskID                          int              NULL,

    -- Identification                                          BOD field
    id                                  nvarchar(100)    NOT NULL,  -- id
    externalId                          nvarchar(100)    NULL,      -- externalid
    tranId                              nvarchar(255)    NULL,      -- tranid: the vendor's invoice number (Reference No.)
    transactionNumber                   nvarchar(50)     NULL,      -- transactionnumber: NetSuite's own number (VENDBILL37)
    tranDate                            date             NULL,      -- trandate
    dueDate                             date             NULL,      -- duedate
    createdDate                         datetime2(0)     NULL,      -- createddate (UTC)
    lastModifiedDate                    datetime2(0)     NULL,      -- lastmodifieddate (UTC)

    -- References
    entityId                            nvarchar(100)    NULL,      -- entity
    entityRefName                       nvarchar(400)    NULL,      -- entityname
    subsidiaryId                        nvarchar(100)    NULL,      -- subsidiary
    subsidiaryRefName                   nvarchar(400)    NULL,
    currencyId                          nvarchar(100)    NULL,      -- currency
    currencyRefName                     nvarchar(100)    NULL,      -- currencyname
    accountId                           nvarchar(100)    NULL,      -- account: the A/P account
    accountRefName                      nvarchar(400)    NULL,
    postingPeriodId                     nvarchar(100)    NULL,      -- postingperiod
    postingPeriodRefName                nvarchar(100)    NULL,
    termsId                             nvarchar(100)    NULL,      -- terms
    termsRefName                        nvarchar(100)    NULL,
    approvalStatusId                    nvarchar(100)    NULL,      -- approvalstatus
    approvalStatusRefName               nvarchar(100)    NULL,
    statusId                            nvarchar(100)    NULL,      -- statusRef (open, paidInFull, ...)
    statusRefName                       nvarchar(100)    NULL,      -- status (Open, Paid In Full, ...)
    departmentId                        nvarchar(100)    NULL,      -- department
    departmentRefName                   nvarchar(400)    NULL,
    classId                             nvarchar(100)    NULL,      -- class
    classRefName                        nvarchar(400)    NULL,
    locationId                          nvarchar(100)    NULL,      -- location
    locationRefName                     nvarchar(400)    NULL,

    -- Amounts (bill currency)
    exchangeRate                        decimal(28,10)   NULL,      -- exchangerate
    total                               decimal(19,4)    NULL,      -- total
    userTotal                           decimal(19,4)    NULL,      -- usertotal
    taxTotal                            decimal(19,4)    NULL,      -- taxtotal
    discountAmount                      decimal(19,4)    NULL,      -- discountamount
    discountDate                        date             NULL,      -- discountdate

    -- Other body fields
    memo                                nvarchar(4000)   NULL,      -- memo
    paymentHold                         bit              NULL,      -- paymenthold
    received                            bit              NULL,      -- received
    toBePrinted                         bit              NULL,      -- tobeprinted
    vatRegNum                           nvarchar(100)    NULL,      -- vatregnum

    -- Billing address
    billAddressee                       nvarchar(255)    NULL,      -- billaddressee
    billAttention                       nvarchar(255)    NULL,      -- billattention
    billAddr1                           nvarchar(255)    NULL,      -- billaddr1
    billAddr2                           nvarchar(255)    NULL,      -- billaddr2
    billAddr3                           nvarchar(255)    NULL,      -- billaddr3
    billCity                            nvarchar(100)    NULL,      -- billcity
    billState                           nvarchar(100)    NULL,      -- billstate
    billZip                             nvarchar(50)     NULL,      -- billzip
    billCountryId                       nvarchar(10)     NULL,      -- billcountry (GB, NL, BE)
    billCountryRefName                  nvarchar(100)    NULL,
    billAddress                         nvarchar(1000)   NULL,      -- billaddress (full text)

    -- Foundation Group custom fields
    cseg_bit_4weeksId                   nvarchar(100)    NULL,      -- cseg_bit_4weeks (custom segment)
    cseg_bit_4weeksRefName              nvarchar(400)    NULL,
    custbody_document_date              date             NULL,
    custbody_establishment_code         nvarchar(100)    NULL,
    custbody_15529_vendor_entity_bankId       nvarchar(100) NULL,   -- vendor bank details used for payment
    custbody_15529_vendor_entity_bankRefName  nvarchar(400) NULL,
    custbody_11187_pref_entity_bankId         nvarchar(100) NULL,
    custbody_11187_pref_entity_bankRefName    nvarchar(400) NULL,
    custbody_9997_is_for_ep_eft         bit              NULL,
    custbody_11724_pay_bank_fees        bit              NULL,
    custbody_stc_amount_after_discount  decimal(19,4)    NULL,
    custbody_stc_tax_after_discount     decimal(19,4)    NULL,
    custbody_stc_total_after_discount   decimal(19,4)    NULL,
    custbody_stc_discountpercent        decimal(9,4)     NULL,
    custbody_stc_daysuntilexpiry        int              NULL,
    custbody_stc_payment_transaction_id nvarchar(100)    NULL,

    CONSTRAINT PK_tb_Netsuite_VendorBill PRIMARY KEY CLUSTERED (BPA_EntryID)
);
CREATE NONCLUSTERED INDEX IX_tb_Netsuite_VendorBill_id
    ON dbo.tb_Netsuite_VendorBill (id, lastModifiedDate);
CREATE NONCLUSTERED INDEX IX_tb_Netsuite_VendorBill_BPA_Status
    ON dbo.tb_Netsuite_VendorBill (BPA_Status, BPA_Direction) INCLUDE (id, BPA_Company);
CREATE NONCLUSTERED INDEX IX_tb_Netsuite_VendorBill_subsidiaryId
    ON dbo.tb_Netsuite_VendorBill (subsidiaryId, lastModifiedDate);
PRINT N'Created  dbo.tb_Netsuite_VendorBill';

-- ---------------------------------------------------------------------------
-- Expense lines: vendorBill/expense/items
-- ---------------------------------------------------------------------------
EXEC #rebuild N'tb_Netsuite_VendorBill_Expense';
CREATE TABLE dbo.tb_Netsuite_VendorBill_Expense (
    -- BPA control fields (standard block, same as the other tb_Netsuite_* tables)
    BPA_Origin                          nvarchar(50)     NULL,
    BPA_Direction                       nvarchar(50)     NULL,
    BPA_Company                         nvarchar(50)     NULL,
    BPA_EntryID                         uniqueidentifier NOT NULL CONSTRAINT DF_tb_Netsuite_VendorBill_Expense_EntryID DEFAULT (newsequentialid()),
    BPA_ParentID                        uniqueidentifier NULL,
    BPA_Status                          int              NULL CONSTRAINT DF_tb_Netsuite_VendorBill_Expense_Status DEFAULT ((0)),
    BPA_Reference                       nvarchar(50)     NULL,
    BPA_Reference_Description           nvarchar(100)    NULL,
    BPA_Reference2                      nvarchar(50)     NULL,
    BPA_Reference2_Description          nvarchar(100)    NULL,
    BPA_Action                          nvarchar(1)      NULL,
    BPA_ReturnedID                      nvarchar(50)     NULL,
    BPA_Syscreated                      datetime         NULL CONSTRAINT DF_tb_Netsuite_VendorBill_Expense_Syscreated DEFAULT (getdate()),
    BPA_Sysmodified                     datetime         NULL CONSTRAINT DF_tb_Netsuite_VendorBill_Expense_Sysmodified DEFAULT (getdate()),
    BPA_Syscreator                      nvarchar(50)     NULL,
    BPA_Error                           nvarchar(max)    NULL,
    BPA_Error_Extended                  nvarchar(max)    NULL,
    BPA_Description                     nvarchar(255)    NULL,
    BPA_Failcount                       int              NULL CONSTRAINT DF_tb_Netsuite_VendorBill_Expense_Failcount DEFAULT ((0)),
    BPA_Orig_Entryid                    uniqueidentifier NULL,
    BPA_TaskInstanceID                  int              NULL,
    BPA_TaskID                          int              NULL,

    -- Parent: BPA_ParentID = tb_Netsuite_VendorBill.BPA_EntryID
    vendorBillId                        nvarchar(100)    NOT NULL,  -- vendorBill/id (the parent's NetSuite id)

    -- Line                                                    BOD field (expense machine)
    line                                int              NOT NULL,  -- line
    accountId                           nvarchar(100)    NULL,      -- account
    accountRefName                      nvarchar(400)    NULL,      -- account_display ("251170 Property, Plant & ...")
    amount                              decimal(19,4)    NULL,      -- amount (net)
    taxCodeId                           nvarchar(100)    NULL,      -- taxcode
    taxCodeRefName                      nvarchar(100)    NULL,      -- taxcode_display (VAT:S)
    taxRate1                            decimal(9,4)     NULL,      -- taxrate1 (1.0% -> 1.0)
    tax1Amt                             decimal(19,4)    NULL,      -- tax1amt
    grossAmt                            decimal(19,4)    NULL,      -- grossamt
    memo                                nvarchar(4000)   NULL,      -- memo
    departmentId                        nvarchar(100)    NULL,      -- department
    departmentRefName                   nvarchar(400)    NULL,
    classId                             nvarchar(100)    NULL,      -- class
    classRefName                        nvarchar(400)    NULL,
    locationId                          nvarchar(100)    NULL,      -- location
    locationRefName                     nvarchar(400)    NULL,
    customerId                          nvarchar(100)    NULL,      -- customer
    customerRefName                     nvarchar(400)    NULL,
    isBillable                          bit              NULL,      -- isbillable
    categoryId                          nvarchar(100)    NULL,      -- category
    categoryRefName                     nvarchar(400)    NULL,
    amortizationSchedId                 nvarchar(100)    NULL,      -- amortizationsched
    amortizationSchedRefName            nvarchar(400)    NULL,
    amortizStartDate                    date             NULL,      -- amortizstartdate
    amortizationEndDate                 date             NULL,      -- amortizationenddate
    amortizationResidual                nvarchar(100)    NULL,      -- amortizationresidual
    orderDoc                            nvarchar(100)    NULL,      -- orderdoc (linked purchase order)
    orderLine                           nvarchar(50)     NULL,      -- orderline

    -- Foundation Group custom line fields
    cseg_investment_catId               nvarchar(100)    NULL,      -- cseg_investment_cat (custom segment)
    cseg_investment_catRefName          nvarchar(400)    NULL,
    custcol_far_trn_relatedassetId      nvarchar(100)    NULL,      -- Fixed Assets: related asset
    custcol_far_trn_relatedassetRefName nvarchar(400)    NULL,
    custcol_nl_wkr_categoryId           nvarchar(100)    NULL,      -- NL work-related costs (WKR) category
    custcol_nl_wkr_categoryRefName      nvarchar(400)    NULL,
    custcol_nondeductible_accountId     nvarchar(100)    NULL,
    custcol_nondeductible_accountRefName nvarchar(400)   NULL,

    CONSTRAINT PK_tb_Netsuite_VendorBill_Expense PRIMARY KEY CLUSTERED (BPA_EntryID)
);
CREATE NONCLUSTERED INDEX IX_tb_Netsuite_VendorBill_Expense_BPA_ParentID
    ON dbo.tb_Netsuite_VendorBill_Expense (BPA_ParentID);
CREATE NONCLUSTERED INDEX IX_tb_Netsuite_VendorBill_Expense_vendorBillId
    ON dbo.tb_Netsuite_VendorBill_Expense (vendorBillId, line);
CREATE NONCLUSTERED INDEX IX_tb_Netsuite_VendorBill_Expense_BPA_Status
    ON dbo.tb_Netsuite_VendorBill_Expense (BPA_Status, BPA_Direction) INCLUDE (vendorBillId, BPA_Company);
PRINT N'Created  dbo.tb_Netsuite_VendorBill_Expense';

COMMIT TRANSACTION;
GO
DROP PROCEDURE #rebuild;
GO
