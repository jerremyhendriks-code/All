USE [BPAStaging]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
/*
    sp_Bank_Netsuite_Synchronise_Company

    NetSuite version of sp_Bank_Synchronise_Company (Exact Globe); that one stays as it is.
    Same call, but @BPA_Company is the NetSuite subsidiary ID (Company in vw_Bank_BankAccounts,
    BPA_Company in tb_Bank_Transactions), not an Exact administration.

        EXEC sp_Bank_Netsuite_Synchronise_Company '89', 'OPEN';
        EXEC sp_Bank_Netsuite_Synchronise_Company '89', 'BANKMATCHING';

    What changed, per part of the Exact version:

    Exact (per administration database)               NetSuite
    ------------------------------------------------  -------------------------------------------------
    OPEN  open creditor items                          tb_Bank_Synch_Netsuite_VendorBill_Open
          (vw_Bank_Synch_Creditor_Outstanding_<adm>)     from tb_Netsuite_VendorBill
    OPEN  open debtor items                            tb_Bank_Synch_Netsuite_Invoice_Open
          (vw_Bank_Synch_Debtor_Outstanding_<adm>)       from tb_Netsuite_Invoice
    OPEN  relation IBANs (bnkacc / cicmpy)             not copied: fn_Bank_Match_V2 reads
                                                         tb_Netsuite_Bank_account_details directly
    OPEN  payment batches (vw_Bank_Synch_Batchpayments) dropped: no batch payments in NetSuite staging
    BANKMATCHING  bank entries booked in gbkmut         tb_Bank_Synch_Netsuite_BankMatching: bank
          (freefield2 = BPA_EntryID)                     transactions whose NetSuite record (vendor payment,
                                                         customer payment, journal entry) has a NetSuite id

    No dynamic SQL and no WorkflowPlatform lookup any more: all subsidiaries are in the same
    tb_Netsuite_* tables, filtered on subsidiary_id. CompanyID stays NULL (as in vw_Bank_BankAccounts).

    OPEN: per subsidiary, one row per open bill / invoice:
        - the latest loaded row per document (tb_Netsuite_* keep every load: ORDER BY BPA_Syscreated),
          so an old load with an old open amount no longer matches;
        - amount_open = open amount in NetSuite minus what is already in a NetSuite payment that is
          not sent yet (BPA_Direction 'TO', BPA_Status 0), so a bank transaction can't match a document
          that another bank transaction is already paying;
        - only documents still open after that, with a number (empty numbers match every description).
      Column names are those of tb_Netsuite_VendorBill / tb_Netsuite_Invoice, so fn_Bank_Match_V2
      reads these tables instead without other changes. Delete + insert in one transaction: an error
      leaves the previous snapshot as it was.

    BANKMATCHING: adds every processed bank transaction (BPA_Status 1) whose NetSuite record now has
      a NetSuite id, once. Then reports the processed transactions still waiting for NetSuite.
*/

-- Snapshot tables (created once)
IF OBJECT_ID(N'dbo.tb_Bank_Synch_Netsuite_VendorBill_Open', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.tb_Bank_Synch_Netsuite_VendorBill_Open
    (
        Company              nvarchar(100)  NOT NULL     -- subsidiary ID
    ,   vendor_bill_id       nvarchar(100)  NOT NULL
    ,   vendor_bill_number   nvarchar(100)  NOT NULL
    ,   vendor_id            nvarchar(100)  NULL
    ,   vendor_name          nvarchar(255)  NULL
    ,   subsidiary_id        nvarchar(100)  NULL
    ,   currency_id          nvarchar(100)  NULL
    ,   currency_name        nvarchar(50)   NULL
    ,   invoice_date         date           NULL
    ,   due_date             date           NULL
    ,   invoice_total        decimal(18, 2) NULL
    ,   amount_open_netsuite decimal(18, 2) NULL         -- open in NetSuite (latest load)
    ,   amount_pending       decimal(18, 2) NOT NULL     -- in unsent vendor payments
    ,   amount_open          decimal(18, 2) NOT NULL     -- still to pay: what the matching uses
    ,   Synchronised         datetime       NOT NULL
    ,   CONSTRAINT PK_tb_Bank_Synch_Netsuite_VendorBill_Open PRIMARY KEY CLUSTERED (Company, vendor_bill_id)
    );
    CREATE NONCLUSTERED INDEX IX_tb_Bank_Synch_Netsuite_VendorBill_Open_vendor
        ON dbo.tb_Bank_Synch_Netsuite_VendorBill_Open (vendor_id, vendor_bill_number);
    PRINT N'Created  dbo.tb_Bank_Synch_Netsuite_VendorBill_Open';
END
GO

IF OBJECT_ID(N'dbo.tb_Bank_Synch_Netsuite_Invoice_Open', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.tb_Bank_Synch_Netsuite_Invoice_Open
    (
        Company              nvarchar(100)  NOT NULL     -- subsidiary ID
    ,   invoice_id           nvarchar(100)  NOT NULL
    ,   invoice_number       nvarchar(100)  NOT NULL
    ,   customer_id          nvarchar(100)  NULL
    ,   customer_name        nvarchar(255)  NULL
    ,   subsidiary_id        nvarchar(100)  NULL
    ,   currency_id          nvarchar(100)  NULL
    ,   currency_name        nvarchar(50)   NULL
    ,   invoice_date         date           NULL
    ,   due_date             date           NULL
    ,   invoice_total        decimal(18, 2) NULL
    ,   amount_open_netsuite decimal(18, 2) NULL         -- open in NetSuite (latest load)
    ,   amount_pending       decimal(18, 2) NOT NULL     -- in unsent customer payments
    ,   amount_open          decimal(18, 2) NOT NULL     -- still to receive: what the matching uses
    ,   Synchronised         datetime       NOT NULL
    ,   CONSTRAINT PK_tb_Bank_Synch_Netsuite_Invoice_Open PRIMARY KEY CLUSTERED (Company, invoice_id)
    );
    CREATE NONCLUSTERED INDEX IX_tb_Bank_Synch_Netsuite_Invoice_Open_customer
        ON dbo.tb_Bank_Synch_Netsuite_Invoice_Open (customer_id, invoice_number);
    PRINT N'Created  dbo.tb_Bank_Synch_Netsuite_Invoice_Open';
END
GO

IF OBJECT_ID(N'dbo.tb_Bank_Synch_Netsuite_BankMatching', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.tb_Bank_Synch_Netsuite_BankMatching
    (
        BPA_EntryID          uniqueidentifier NOT NULL   -- tb_Bank_Transactions
    ,   Company              nvarchar(100)    NOT NULL
    ,   RecordType           varchar(20)      NOT NULL   -- VENDORPAYMENT / CUSTOMERPAYMENT / JOURNALENTRY
    ,   NetsuiteEntryID      uniqueidentifier NOT NULL   -- BPA_EntryID of the NetSuite header (= BPA_ReturnedID)
    ,   NetsuiteID           nvarchar(100)    NOT NULL   -- NetSuite internal id
    ,   ExternalID           nvarchar(255)    NULL
    ,   Synchronised         datetime         NOT NULL
    ,   CONSTRAINT PK_tb_Bank_Synch_Netsuite_BankMatching PRIMARY KEY CLUSTERED (BPA_EntryID)
    );
    PRINT N'Created  dbo.tb_Bank_Synch_Netsuite_BankMatching';
END
GO

CREATE OR ALTER PROCEDURE [dbo].[sp_Bank_Netsuite_Synchronise_Company]
(
    @BPA_Company varchar(50)    -- NetSuite subsidiary ID
,   @Type        varchar(20)    -- OPEN / BANKMATCHING
)
AS
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Now datetime = GETDATE();

IF @Type NOT IN ('OPEN', 'BANKMATCHING')
    THROW 50001, N'@Type must be OPEN or BANKMATCHING.', 1;

IF @Type = 'OPEN'
BEGIN
    BEGIN TRANSACTION;

    -- Open vendor bills
    DELETE FROM dbo.tb_Bank_Synch_Netsuite_VendorBill_Open WHERE Company = @BPA_Company;

    WITH bill AS (
        SELECT
            CAST(v.vendor_bill_id AS nvarchar(100))                 AS vendor_bill_id
        ,   LTRIM(RTRIM(CAST(v.vendor_bill_number AS nvarchar(100)))) AS vendor_bill_number
        ,   CAST(v.vendor_id AS nvarchar(100))                      AS vendor_id
        ,   CAST(v.vendor_name AS nvarchar(255))                    AS vendor_name
        ,   CAST(v.subsidiary_id AS nvarchar(100))                  AS subsidiary_id
        ,   CAST(v.currency_id AS nvarchar(100))                    AS currency_id
        ,   CAST(v.currency_name AS nvarchar(50))                   AS currency_name
        ,   TRY_CAST(v.invoice_date AS date)                        AS invoice_date
        ,   TRY_CAST(v.due_date AS date)                            AS due_date
        ,   TRY_CAST(v.invoice_total AS decimal(18, 2))             AS invoice_total
        ,   TRY_CAST(v.amount_open AS decimal(18, 2))               AS amount_open
        ,   ROW_NUMBER() OVER (PARTITION BY v.vendor_bill_id
                               ORDER BY v.BPA_Syscreated DESC, v.BPA_EntryID DESC) AS rn
        FROM dbo.tb_Netsuite_VendorBill v
        WHERE ISNULL(v.BPA_Direction, '') <> 'TO'
          AND v.vendor_bill_id IS NOT NULL
    ),
    pending AS (
        SELECT CAST(a.doc_id AS nvarchar(100)) AS doc_id, SUM(TRY_CAST(a.amount AS decimal(18, 2))) AS amount
        FROM dbo.tb_Netsuite_VendorPayment_Apply a
        JOIN dbo.tb_Netsuite_VendorPayment h ON h.BPA_EntryID = a.BPA_ParentID
        WHERE h.BPA_Direction = 'TO'
          AND h.BPA_Status = 0
        GROUP BY CAST(a.doc_id AS nvarchar(100))
    )
    INSERT INTO dbo.tb_Bank_Synch_Netsuite_VendorBill_Open
    (
        Company, vendor_bill_id, vendor_bill_number, vendor_id, vendor_name, subsidiary_id,
        currency_id, currency_name, invoice_date, due_date, invoice_total,
        amount_open_netsuite, amount_pending, amount_open, Synchronised
    )
    SELECT
        @BPA_Company, b.vendor_bill_id, b.vendor_bill_number, b.vendor_id, b.vendor_name, b.subsidiary_id,
        b.currency_id, b.currency_name, b.invoice_date, b.due_date, b.invoice_total,
        b.amount_open, ISNULL(p.amount, 0), b.amount_open - ISNULL(p.amount, 0), @Now
    FROM bill b
    LEFT JOIN pending p ON p.doc_id = b.vendor_bill_id
    WHERE b.rn = 1
      AND b.subsidiary_id = @BPA_Company
      AND b.vendor_bill_number <> ''
      AND b.amount_open - ISNULL(p.amount, 0) > 0;

    -- Open customer invoices
    DELETE FROM dbo.tb_Bank_Synch_Netsuite_Invoice_Open WHERE Company = @BPA_Company;

    WITH inv AS (
        SELECT
            CAST(i.invoice_id AS nvarchar(100))                     AS invoice_id
        ,   LTRIM(RTRIM(CAST(i.invoice_number AS nvarchar(100))))   AS invoice_number
        ,   CAST(i.customer_id AS nvarchar(100))                    AS customer_id
        ,   CAST(i.customer_name AS nvarchar(255))                  AS customer_name
        ,   CAST(i.subsidiary_id AS nvarchar(100))                  AS subsidiary_id
        ,   CAST(i.currency_id AS nvarchar(100))                    AS currency_id
        ,   CAST(i.currency_name AS nvarchar(50))                   AS currency_name
        ,   TRY_CAST(i.invoice_date AS date)                        AS invoice_date
        ,   TRY_CAST(i.due_date AS date)                            AS due_date
        ,   TRY_CAST(i.invoice_total AS decimal(18, 2))             AS invoice_total
        ,   TRY_CAST(i.amount_open AS decimal(18, 2))               AS amount_open
        ,   ROW_NUMBER() OVER (PARTITION BY i.invoice_id
                               ORDER BY i.BPA_Syscreated DESC, i.BPA_EntryID DESC) AS rn
        FROM dbo.tb_Netsuite_Invoice i
        WHERE ISNULL(i.BPA_Direction, '') <> 'TO'
          AND i.invoice_id IS NOT NULL
    ),
    pending AS (
        SELECT CAST(a.docId AS nvarchar(100)) AS doc_id, SUM(TRY_CAST(a.amount AS decimal(18, 2))) AS amount
        FROM dbo.tb_Netsuite_CustomerPayment_Apply a
        JOIN dbo.tb_Netsuite_CustomerPayment h ON h.BPA_EntryID = a.BPA_ParentID
        WHERE h.BPA_Direction = 'TO'
          AND h.BPA_Status = 0
        GROUP BY CAST(a.docId AS nvarchar(100))
    )
    INSERT INTO dbo.tb_Bank_Synch_Netsuite_Invoice_Open
    (
        Company, invoice_id, invoice_number, customer_id, customer_name, subsidiary_id,
        currency_id, currency_name, invoice_date, due_date, invoice_total,
        amount_open_netsuite, amount_pending, amount_open, Synchronised
    )
    SELECT
        @BPA_Company, i.invoice_id, i.invoice_number, i.customer_id, i.customer_name, i.subsidiary_id,
        i.currency_id, i.currency_name, i.invoice_date, i.due_date, i.invoice_total,
        i.amount_open, ISNULL(p.amount, 0), i.amount_open - ISNULL(p.amount, 0), @Now
    FROM inv i
    LEFT JOIN pending p ON p.doc_id = i.invoice_id
    WHERE i.rn = 1
      AND i.subsidiary_id = @BPA_Company
      AND i.invoice_number <> ''
      AND i.amount_open - ISNULL(p.amount, 0) > 0;

    COMMIT TRANSACTION;

    SELECT
        @BPA_Company AS Company
    ,   (SELECT COUNT(*) FROM dbo.tb_Bank_Synch_Netsuite_VendorBill_Open WHERE Company = @BPA_Company) AS open_vendor_bills
    ,   (SELECT COUNT(*) FROM dbo.tb_Bank_Synch_Netsuite_Invoice_Open    WHERE Company = @BPA_Company) AS open_invoices;
END

IF @Type = 'BANKMATCHING'
BEGIN
    -- Processed bank transactions whose NetSuite record has been created in NetSuite (id filled)
    INSERT INTO dbo.tb_Bank_Synch_Netsuite_BankMatching
        (BPA_EntryID, Company, RecordType, NetsuiteEntryID, NetsuiteID, ExternalID, Synchronised)
    SELECT t.BPA_EntryID, @BPA_Company, r.RecordType, r.BPA_EntryID, r.id, r.externalId, @Now
    FROM dbo.tb_Bank_Transactions t
    CROSS APPLY (
        SELECT 'VENDORPAYMENT' AS RecordType, h.BPA_EntryID, CAST(h.id AS nvarchar(100)) AS id, CAST(h.externalId AS nvarchar(255)) AS externalId
        FROM dbo.tb_Netsuite_VendorPayment h WHERE h.BPA_EntryID = t.BPA_ReturnedID
        UNION ALL
        SELECT 'CUSTOMERPAYMENT', h.BPA_EntryID, CAST(h.id AS nvarchar(100)), CAST(h.externalId AS nvarchar(255))
        FROM dbo.tb_Netsuite_CustomerPayment h WHERE h.BPA_EntryID = t.BPA_ReturnedID
        UNION ALL
        SELECT 'JOURNALENTRY', h.BPA_EntryID, CAST(h.id AS nvarchar(100)), CAST(h.externalId AS nvarchar(255))
        FROM dbo.tb_Netsuite_JournalEntry h WHERE h.BPA_EntryID = t.BPA_ReturnedID
    ) r
    WHERE t.BPA_Status = 1
      AND t.BPA_Company = @BPA_Company
      AND ISNULL(r.id, '') <> ''
      AND NOT EXISTS (SELECT 1 FROM dbo.tb_Bank_Synch_Netsuite_BankMatching m WHERE m.BPA_EntryID = t.BPA_EntryID);

    SELECT @@ROWCOUNT AS booked_in_netsuite_added;

    -- Processed, but no NetSuite id yet: not sent, or NetSuite refused it
    SELECT
        t.BPA_EntryID, t.Bookdate, t.Amount, t.Currency, t.Description, t.Matched_typematch,
        t.BPA_ReturnedID AS NetsuiteEntryID,
        COALESCE(vp.BPA_Status, cp.BPA_Status, je.BPA_Status) AS NetsuiteRecord_BPA_Status,
        CASE WHEN vp.BPA_EntryID IS NOT NULL THEN 'VENDORPAYMENT'
             WHEN cp.BPA_EntryID IS NOT NULL THEN 'CUSTOMERPAYMENT'
             WHEN je.BPA_EntryID IS NOT NULL THEN 'JOURNALENTRY'
             ELSE 'NOT FOUND' END AS RecordType
    FROM dbo.tb_Bank_Transactions t
    LEFT JOIN dbo.tb_Netsuite_VendorPayment   vp ON vp.BPA_EntryID = t.BPA_ReturnedID
    LEFT JOIN dbo.tb_Netsuite_CustomerPayment cp ON cp.BPA_EntryID = t.BPA_ReturnedID
    LEFT JOIN dbo.tb_Netsuite_JournalEntry    je ON je.BPA_EntryID = t.BPA_ReturnedID
    WHERE t.BPA_Status = 1
      AND t.BPA_Company = @BPA_Company
      AND NOT EXISTS (SELECT 1 FROM dbo.tb_Bank_Synch_Netsuite_BankMatching m WHERE m.BPA_EntryID = t.BPA_EntryID)
    ORDER BY t.Bookdate, t.BPA_EntryID;
END
GO
