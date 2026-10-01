/*
    Rebuild dbo.tb_Netsuite_VendorBill so it matches the vendorBill connector schema
    (schemas/netsuite/vendorBill.xsd). Replaces the earlier ALTER script.

    - Same layout as the other tb_Netsuite_* tables: the BPA_* control fields first,
      primary key on [BPA_EntryID] (newsequentialid), then the payload fields.
    - Payload fields: every standard header field in the schema, in schema order.
      Left out:
        * SupplementaryReference (internal BPA connector property)
        * custbody_* (253 fields, all from localisation bundles: IL, IT nexil, ES SII,
          withholding tax)
        * accountingBookDetail (only used with multi-book accounting; empty in the
          sample)
    - Reference fields (entity, subsidiary, currency, account, terms, approvalStatus)
      are stored as <name>Id + <name>RefName. The rest of the expanded record
      (e.g. the 133 entity fields) belongs in its own tb_Netsuite_* table.
    - postingPeriodId/RefName and customFormId/RefName from the old table are dropped:
      the schema doesn't contain them.
    - Lines are in tb_Netsuite_VendorBill_Item and tb_Netsuite_VendorBill_Expense,
      linked through BPA_ParentID = BPA_EntryID of this table.

    The existing table is kept as dbo.tb_Netsuite_VendorBill_bak (its constraints get
    a _bak suffix) so nothing is lost; drop it once the new table is loading
    correctly. Stops without changes if tb_Netsuite_VendorBill_bak already exists.
    Runs in a single transaction: any error rolls everything back.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
BEGIN TRANSACTION;

DECLARE @old sysname, @new sysname, @sql nvarchar(max);

IF OBJECT_ID(N'dbo.tb_Netsuite_VendorBill', N'U') IS NOT NULL
BEGIN
    IF OBJECT_ID(N'dbo.tb_Netsuite_VendorBill_bak', N'U') IS NOT NULL
        THROW 50001, N'dbo.tb_Netsuite_VendorBill_bak already exists; drop or rename it first.', 1;

    EXEC sys.sp_rename @objname = N'dbo.tb_Netsuite_VendorBill', @newname = N'tb_Netsuite_VendorBill_bak', @objtype = N'OBJECT';
    PRINT N'Renamed  dbo.tb_Netsuite_VendorBill -> tb_Netsuite_VendorBill_bak';

    -- Constraint names are unique per schema, so free them up for the new table
    DECLARE con CURSOR LOCAL FAST_FORWARD FOR
        SELECT name
        FROM sys.objects
        WHERE parent_object_id = OBJECT_ID(N'dbo.tb_Netsuite_VendorBill_bak')
          AND type IN ('PK', 'UQ', 'D', 'C', 'F');
    OPEN con;
    FETCH NEXT FROM con INTO @old;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @new = LEFT(@old, 124) + N'_bak';
        SET @sql = N'dbo.' + QUOTENAME(@old);
        EXEC sys.sp_rename @objname = @sql, @newname = @new, @objtype = N'OBJECT';
        PRINT N'Renamed  ' + @old + N' -> ' + @new;
        FETCH NEXT FROM con INTO @old;
    END
    CLOSE con;
    DEALLOCATE con;
END

CREATE TABLE dbo.tb_Netsuite_VendorBill (
    BPA_Origin                  nvarchar(50)   NULL,
    BPA_Direction               nvarchar(50)   NULL,
    BPA_Company                 nvarchar(50)   NULL,
    BPA_EntryID                 uniqueidentifier NOT NULL CONSTRAINT DF_tb_Netsuite_VendorBill_EntryID DEFAULT (newsequentialid()),
    BPA_ParentID                uniqueidentifier NULL,
    BPA_Status                  int            NULL CONSTRAINT DF_tb_Netsuite_VendorBill_Status DEFAULT ((0)),
    BPA_Reference               nvarchar(50)   NULL,
    BPA_Reference_Description   nvarchar(100)  NULL,
    BPA_Reference2              nvarchar(50)   NULL,
    BPA_Reference2_Description  nvarchar(100)  NULL,
    BPA_Action                  nvarchar(1)    NULL,
    BPA_ReturnedID              nvarchar(50)   NULL,
    BPA_Syscreated              datetime       NULL CONSTRAINT DF_tb_Netsuite_VendorBill_Syscreated DEFAULT (getdate()),
    BPA_Sysmodified             datetime       NULL CONSTRAINT DF_tb_Netsuite_VendorBill_Sysmodified DEFAULT (getdate()),
    BPA_Syscreator              nvarchar(50)   NULL,
    BPA_Error                   nvarchar(max)  NULL,
    BPA_Error_Extended          nvarchar(max)  NULL,
    BPA_Description             nvarchar(255)  NULL,
    BPA_Failcount               int            NULL CONSTRAINT DF_tb_Netsuite_VendorBill_Failcount DEFAULT ((0)),
    BPA_Orig_Entryid            uniqueidentifier NULL,
    BPA_TaskInstanceID          int            NULL,
    BPA_TaskID                  int            NULL,
    billAddr1                   nvarchar(255)  NULL,
    billAddr2                   nvarchar(255)  NULL,
    billAddr3                   nvarchar(255)  NULL,
    billAddress                 nvarchar(1000) NULL,
    billAddressee               nvarchar(255)  NULL,
    billAttention               nvarchar(255)  NULL,
    billCity                    nvarchar(255)  NULL,
    billingAddress_text         nvarchar(1000) NULL,
    billOverride                nvarchar(1000) NULL,
    billPhone                   nvarchar(100)  NULL,
    billState                   nvarchar(255)  NULL,
    billZip                     nvarchar(100)  NULL,
    createdDate                 datetime2(3)   NULL,
    discountAmount              decimal(19,4)  NULL,
    discountDate                date           NULL,
    documentStatus              nvarchar(50)   NULL,
    dueDate                     date           NULL,
    endDate                     date           NULL,
    exchangeRate                decimal(28,10) NULL,
    externalId                  nvarchar(100)  NULL,
    id                          nvarchar(100)  NOT NULL,
    lastModifiedDate            datetime2(3)   NULL,
    memo                        nvarchar(4000) NULL,
    paymentHold                 bit            NULL,
    prevDate                    date           NULL,
    received                    bit            NULL,
    refName                     nvarchar(255)  NULL,
    startDate                   date           NULL,
    tax2Total                   decimal(19,4)  NULL,
    taxTotal                    decimal(19,4)  NULL,
    toBePrinted                 bit            NULL,
    total                       decimal(19,4)  NULL,
    tranDate                    date           NULL,
    tranId                      nvarchar(255)  NULL,
    transactionNumber           nvarchar(255)  NULL,
    userTotal                   decimal(19,4)  NULL,
    vatRegNum                   nvarchar(255)  NULL,
    entityId                    nvarchar(255)  NULL,
    entityRefName               nvarchar(255)  NULL,
    subsidiaryId                nvarchar(255)  NULL,
    subsidiaryRefName           nvarchar(255)  NULL,
    currencyId                  nvarchar(255)  NULL,
    currencyRefName             nvarchar(255)  NULL,
    accountId                   nvarchar(255)  NULL,
    accountRefName              nvarchar(255)  NULL,
    termsId                     nvarchar(255)  NULL,
    termsRefName                nvarchar(255)  NULL,
    approvalStatusId            nvarchar(255)  NULL,
    approvalStatusRefName       nvarchar(255)  NULL,
    CONSTRAINT PK_tb_Netsuite_VendorBill PRIMARY KEY CLUSTERED (BPA_EntryID)
);
PRINT N'Created  dbo.tb_Netsuite_VendorBill';

COMMIT TRANSACTION;
