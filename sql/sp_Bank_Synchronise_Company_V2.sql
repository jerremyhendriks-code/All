/*
    sp_Bank_Synchronise_Company_V2: NetSuite version of sp_Bank_Synchronise_Company.

    The Exact version copied open items and relation bank accounts from each company's own
    Exact database with dynamic SQL. For NetSuite the BPA FROM tasks already load them into
    BPAStaging, so this SP only builds a clean snapshot of them:

        tb_Netsuite_vendorBill            -> tb_Bank_Synch_OpenItems     (DocType 'VENDORBILL')
        tb_Netsuite_Invoice               -> tb_Bank_Synch_OpenItems     (DocType 'INVOICE')
        tb_Netsuite_Bank_account_details  -> tb_Bank_Synch_RelationIBAN  (Source 'BANKDETAILS')
        tb_Netsuite_vendorBill.vendor_iban-> tb_Bank_Synch_RelationIBAN  (Source 'VENDORBILL')

    Snapshot rules for open items:
        - The FROM tables keep every load, so per document we take the latest row (BPA_Syscreated).
        - A document whose latest row is more than @MaxAgeHours older than the latest load of its
          subsidiary is no longer in the NetSuite load (paid or closed) and is left out.
        - Only documents with an open amount > 0. Error rows of the FROM task (no document id) are skipped.
        - Amounts become decimal(19,2), so the bank engine can compare to the cent.

    Not taken over from the Exact version:
        - BANKMATCHING: the TO tasks write the NetSuite id back (BPA_ReturnedID), no read-back needed.
        - BankBatches: no NetSuite source yet (Electronic Bank Payments batches can come later).

    The old tb_Bank_Synch_* tables are left alone: fn_Bank_Match (Exact) still refers to them.

    Usage:
        EXEC dbo.sp_Bank_Synchronise_Company_V2;                        -- all subsidiaries
        EXEC dbo.sp_Bank_Synchronise_Company_V2 @Subsidiary = '89';     -- one subsidiary
*/
USE [BPAStaging]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

------------------------------------------------------------
-- Snapshot tables
------------------------------------------------------------
IF OBJECT_ID('dbo.tb_Bank_Synch_OpenItems', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.tb_Bank_Synch_OpenItems
    (
        Subsidiary          nvarchar(100)   NOT NULL,
        DocType             varchar(10)     NOT NULL,   -- VENDORBILL / INVOICE
        DocumentID          nvarchar(100)   NOT NULL,   -- NetSuite internal id (apply doc id)
        DocumentNumber      nvarchar(255)   NULL,       -- bill number / invoice number (tranid)
        EntityID            nvarchar(100)   NULL,       -- vendor id / customer id
        EntityName          nvarchar(255)   NULL,
        DocumentDate        date            NULL,
        DueDate             date            NULL,
        Amount              decimal(19,2)   NULL,
        AmountOpen          decimal(19,2)   NOT NULL,
        CurrencyID          nvarchar(50)    NULL,
        CurrencyName        nvarchar(255)   NULL,
        StatusName          nvarchar(255)   NULL,
        PostingPeriodName   nvarchar(255)   NULL,
        Memo                nvarchar(1000)  NULL,
        Source_EntryID      uniqueidentifier NULL,      -- BPA_EntryID of the FROM row used
        Source_Syscreated   datetime        NULL,
        Synchronised        datetime        NOT NULL CONSTRAINT DF_tb_Bank_Synch_OpenItems_Synchronised DEFAULT (GETDATE()),
        CONSTRAINT PK_tb_Bank_Synch_OpenItems PRIMARY KEY (DocType, DocumentID)
    );

    CREATE INDEX IX_tb_Bank_Synch_OpenItems_Entity
        ON dbo.tb_Bank_Synch_OpenItems (Subsidiary, DocType, EntityID)
        INCLUDE (DocumentNumber, AmountOpen, CurrencyName);
END
GO

IF OBJECT_ID('dbo.tb_Bank_Synch_RelationIBAN', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.tb_Bank_Synch_RelationIBAN
    (
        IBAN                nvarchar(50)    NOT NULL,   -- upper case, no spaces
        EntityType          varchar(10)     NOT NULL,   -- VENDOR / CUSTOMER
        EntityID            nvarchar(100)   NOT NULL,
        EntityName          nvarchar(400)   NULL,
        Source              varchar(20)     NOT NULL,   -- BANKDETAILS / VENDORBILL
        Source_ID           nvarchar(100)   NULL,       -- bank details record id / vendor bill id
        Synchronised        datetime        NOT NULL CONSTRAINT DF_tb_Bank_Synch_RelationIBAN_Synchronised DEFAULT (GETDATE())
    );

    CREATE INDEX IX_tb_Bank_Synch_RelationIBAN_IBAN
        ON dbo.tb_Bank_Synch_RelationIBAN (IBAN)
        INCLUDE (EntityType, EntityID);
END
GO

------------------------------------------------------------
-- sp_Bank_Synchronise_Company_V2
------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_Bank_Synchronise_Company_V2
(
    @Subsidiary  nvarchar(100) = NULL,  -- NULL = all subsidiaries
    @MaxAgeHours int           = 36     -- older than the latest load by more than this = no longer open
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- ---------- Open items: latest row per document ----------
    IF OBJECT_ID('tempdb..#items') IS NOT NULL DROP TABLE #items;

    WITH bills AS
    (
        SELECT
            CAST(v.subsidiary_id AS nvarchar(100))                     AS Subsidiary
        ,   CAST(v.vendor_bill_id AS nvarchar(100))                    AS DocumentID
        ,   LTRIM(RTRIM(v.vendor_bill_number))                         AS DocumentNumber
        ,   CAST(v.vendor_id AS nvarchar(100))                         AS EntityID
        ,   v.vendor_name                                              AS EntityName
        ,   COALESCE(CAST(v.bill_date AS date),
                     TRY_CONVERT(date, LEFT(LTRIM(v.invoice_date), 10), 23),
                     TRY_CONVERT(date, LEFT(LTRIM(v.invoice_date), 10), 103)) AS DocumentDate
        ,   COALESCE(TRY_CONVERT(date, LEFT(LTRIM(v.due_date), 10), 23),
                     TRY_CONVERT(date, LEFT(LTRIM(v.due_date), 10), 103))     AS DueDate
        ,   CAST(ROUND(COALESCE(v.bill_total, v.invoice_total), 2) AS decimal(19,2)) AS Amount
        ,   TRY_CONVERT(decimal(19,2), LTRIM(RTRIM(v.amount_open)))   AS AmountOpen
        ,   CAST(v.currency_id AS nvarchar(50))                        AS CurrencyID
        ,   v.currency_name                                            AS CurrencyName
        ,   v.status_name                                              AS StatusName
        ,   v.posting_period_name                                      AS PostingPeriodName
        ,   LEFT(v.memo, 1000)                                         AS Memo
        ,   v.BPA_EntryID                                              AS Source_EntryID
        ,   v.BPA_Syscreated                                           AS Source_Syscreated
        ,   ROW_NUMBER() OVER (PARTITION BY v.vendor_bill_id
                               ORDER BY v.BPA_Syscreated DESC, v.BPA_Sysmodified DESC) AS rn
        ,   MAX(v.BPA_Syscreated) OVER (PARTITION BY v.subsidiary_id)  AS LastLoad
        FROM dbo.tb_Netsuite_vendorBill v
        WHERE v.vendor_bill_id IS NOT NULL
          AND (@Subsidiary IS NULL OR CAST(v.subsidiary_id AS nvarchar(100)) = @Subsidiary)
    ),
    invoices AS
    (
        SELECT
            CAST(i.subsidiary_id AS nvarchar(100))                     AS Subsidiary
        ,   CAST(i.invoice_id AS nvarchar(100))                        AS DocumentID
        ,   LTRIM(RTRIM(i.invoice_number))                             AS DocumentNumber
        ,   CAST(i.customer_id AS nvarchar(100))                       AS EntityID
        ,   i.customer_name                                            AS EntityName
        ,   COALESCE(TRY_CONVERT(date, LEFT(LTRIM(i.invoice_date), 10), 23),
                     TRY_CONVERT(date, LEFT(LTRIM(i.invoice_date), 10), 103)) AS DocumentDate
        ,   COALESCE(TRY_CONVERT(date, LEFT(LTRIM(i.due_date), 10), 23),
                     TRY_CONVERT(date, LEFT(LTRIM(i.due_date), 10), 103))     AS DueDate
        ,   CAST(ROUND(i.invoice_total, 2) AS decimal(19,2))           AS Amount
        ,   CAST(ROUND(i.amount_open, 2) AS decimal(19,2))             AS AmountOpen
        ,   CAST(i.currency_id AS nvarchar(50))                        AS CurrencyID
        ,   i.currency_name                                            AS CurrencyName
        ,   i.status_name                                              AS StatusName
        ,   i.posting_period_name                                      AS PostingPeriodName
        ,   LEFT(i.memo, 1000)                                         AS Memo
        ,   i.BPA_EntryID                                              AS Source_EntryID
        ,   i.BPA_Syscreated                                           AS Source_Syscreated
        ,   ROW_NUMBER() OVER (PARTITION BY i.invoice_id
                               ORDER BY i.BPA_Syscreated DESC, i.BPA_Sysmodified DESC) AS rn
        ,   MAX(i.BPA_Syscreated) OVER (PARTITION BY i.subsidiary_id)  AS LastLoad
        FROM dbo.tb_Netsuite_Invoice i
        WHERE NULLIF(LTRIM(RTRIM(i.invoice_id)), N'') IS NOT NULL
          AND (@Subsidiary IS NULL OR CAST(i.subsidiary_id AS nvarchar(100)) = @Subsidiary)
    )
    SELECT 'VENDORBILL' AS DocType, b.*
    INTO #items
    FROM bills b
    WHERE b.rn = 1
    UNION ALL
    SELECT 'INVOICE', i.*
    FROM invoices i
    WHERE i.rn = 1;

    -- ---------- Relation IBANs ----------
    IF OBJECT_ID('tempdb..#ibans') IS NOT NULL DROP TABLE #ibans;

    SELECT IBAN, EntityType, EntityID, EntityName, Source, Source_ID
    INTO #ibans
    FROM
    (
        -- Bank details records (Electronic Bank Payments), latest load per record
        SELECT
            UPPER(REPLACE(d.custrecord_2663_entity_iban, N' ', N''))   AS IBAN
        ,   CASE WHEN NULLIF(d.vendorid, N'') IS NOT NULL THEN 'VENDOR' ELSE 'CUSTOMER' END AS EntityType
        ,   COALESCE(NULLIF(d.vendorid, N''), NULLIF(d.customerid, N'')) AS EntityID
        ,   COALESCE(NULLIF(d.vendorrefname, N''), d.customerrefname)  AS EntityName
        ,   'BANKDETAILS'                                              AS Source
        ,   d.id                                                       AS Source_ID
        ,   ROW_NUMBER() OVER (PARTITION BY d.id ORDER BY d.BPA_Syscreated DESC) AS rn
        ,   d.isInactive
        FROM dbo.tb_Netsuite_Bank_account_details d
        WHERE NULLIF(d.custrecord_2663_entity_iban, N'') IS NOT NULL
          AND COALESCE(NULLIF(d.vendorid, N''), NULLIF(d.customerid, N'')) IS NOT NULL

        UNION ALL

        -- IBAN on the vendor bill, for vendors without a bank details record
        SELECT DISTINCT
            UPPER(REPLACE(v.vendor_iban, N' ', N''))
        ,   'VENDOR'
        ,   CAST(v.vendor_id AS nvarchar(100))
        ,   v.vendor_name
        ,   'VENDORBILL'
        ,   NULL
        ,   1
        ,   CAST(0 AS bit)
        FROM dbo.tb_Netsuite_vendorBill v
        WHERE NULLIF(v.vendor_iban, N'') IS NOT NULL
          AND v.vendor_id IS NOT NULL
    ) x
    WHERE x.rn = 1
      AND ISNULL(x.isInactive, 0) = 0
      AND LEN(x.IBAN) >= 15;

    -- Vendor bill IBANs only where the bank details don't already give that IBAN for that vendor
    DELETE vb
    FROM #ibans vb
    WHERE vb.Source = 'VENDORBILL'
      AND EXISTS (SELECT 1 FROM #ibans bd
                  WHERE bd.Source = 'BANKDETAILS'
                    AND bd.IBAN = vb.IBAN
                    AND bd.EntityType = 'VENDOR'
                    AND bd.EntityID = vb.EntityID);

    -- ---------- Replace the snapshot in one go ----------
    BEGIN TRANSACTION;

    DELETE FROM dbo.tb_Bank_Synch_OpenItems
    WHERE @Subsidiary IS NULL OR Subsidiary = @Subsidiary;

    INSERT INTO dbo.tb_Bank_Synch_OpenItems
    (
        Subsidiary, DocType, DocumentID, DocumentNumber, EntityID, EntityName,
        DocumentDate, DueDate, Amount, AmountOpen, CurrencyID, CurrencyName,
        StatusName, PostingPeriodName, Memo, Source_EntryID, Source_Syscreated
    )
    SELECT
        Subsidiary, DocType, DocumentID, DocumentNumber, EntityID, EntityName,
        DocumentDate, DueDate, Amount, AmountOpen, CurrencyID, CurrencyName,
        StatusName, PostingPeriodName, Memo, Source_EntryID, Source_Syscreated
    FROM #items
    WHERE Subsidiary IS NOT NULL
      AND AmountOpen > 0
      AND Source_Syscreated >= DATEADD(HOUR, -@MaxAgeHours, LastLoad);

    -- Relation IBANs are per entity, not per subsidiary: always the full set
    DELETE FROM dbo.tb_Bank_Synch_RelationIBAN;

    INSERT INTO dbo.tb_Bank_Synch_RelationIBAN (IBAN, EntityType, EntityID, EntityName, Source, Source_ID)
    SELECT DISTINCT IBAN, EntityType, EntityID, EntityName, Source, Source_ID
    FROM #ibans;

    COMMIT TRANSACTION;

    -- ---------- Report ----------
    SELECT
        DocType
    ,   Subsidiary
    ,   COUNT(*)                                                                    AS documents_in_staging
    ,   SUM(CASE WHEN AmountOpen > 0
                  AND Source_Syscreated >= DATEADD(HOUR, -@MaxAgeHours, LastLoad) THEN 1 ELSE 0 END) AS open_synchronised
    ,   SUM(CASE WHEN AmountOpen IS NULL THEN 1 ELSE 0 END)                         AS amount_open_unreadable
    ,   SUM(CASE WHEN AmountOpen <= 0 THEN 1 ELSE 0 END)                            AS not_open
    ,   SUM(CASE WHEN Source_Syscreated < DATEADD(HOUR, -@MaxAgeHours, LastLoad) THEN 1 ELSE 0 END) AS no_longer_in_load
    ,   MAX(LastLoad)                                                               AS last_load
    FROM #items
    GROUP BY DocType, Subsidiary
    ORDER BY DocType, Subsidiary;

    SELECT Source, EntityType, COUNT(*) AS ibans, COUNT(DISTINCT IBAN) AS distinct_ibans
    FROM dbo.tb_Bank_Synch_RelationIBAN
    GROUP BY Source, EntityType
    ORDER BY Source, EntityType;
END
GO
