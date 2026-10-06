/*
    Staging for NetSuite vendor bills, loaded with dbo.BPA_ImportXml.

    1. Creates dbo.tb_Netsuite_VendorBill and dbo.tb_Netsuite_VendorBillLine by
       letting BPA_ImportXml import a one-row template with every field of
       suiteql/vendorbill_header.sql and suiteql/vendorbill_lines.sql, then
       deleting that row. That way every column exists from the start, also
       those NetSuite leaves out of a page when they're NULL, and the views
       below always compile. Existing BPA tables just get missing columns.
    2. Creates two views on top of the raw tables:
       - dbo.vw_Netsuite_VendorBill: the latest imported row per bill, typed.
       - dbo.vw_Netsuite_VendorBillLine: per bill, the lines imported since its
         latest header import (so lines removed in NetSuite drop out), typed.
         Requires each run to import the header pages before the line pages.

    BPA_ImportXml stores every field as nvarchar(max) and only ever inserts:
    each run adds a new row for every bill it returns. The views pick the
    latest one and convert the text (TRY_CONVERT: an unconvertible value
    becomes NULL).

    Stops with an error, changing nothing, when one of the table names exists
    but isn't a BPA table (no BPA_EntryID column), such as a hand-made
    tb_Netsuite_VendorBill with a NOT NULL [id]: BPA_ImportXml can't insert
    into that. Rename or drop that table first, or change the names here and
    in the views.

    Requires dbo.BPA_ImportXml. Safe to run more than once.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET XACT_ABORT ON;
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'dbo.tb_Netsuite_VendorBill', N'U') IS NOT NULL
   AND COL_LENGTH(N'dbo.tb_Netsuite_VendorBill', N'BPA_EntryID') IS NULL
    THROW 50201, N'dbo.tb_Netsuite_VendorBill exists but is not a BPA table (no BPA_EntryID). Rename or drop it first.', 1;

IF OBJECT_ID(N'dbo.tb_Netsuite_VendorBillLine', N'U') IS NOT NULL
   AND COL_LENGTH(N'dbo.tb_Netsuite_VendorBillLine', N'BPA_EntryID') IS NULL
    THROW 50202, N'dbo.tb_Netsuite_VendorBillLine exists but is not a BPA table (no BPA_EntryID). Rename or drop it first.', 1;

BEGIN TRANSACTION;

EXEC dbo.BPA_ImportXml
    @Xml           = N'<root><count>1</count><hasMore>false</hasMore><items Array="true"><vendor_bill_id>__template__</vendor_bill_id><bill_number></bill_number><vendor_invoice_number></vendor_invoice_number><external_id></external_id><bill_date></bill_date><due_date></due_date><vendor_id></vendor_id><vendor_name></vendor_name><memo></memo><terms_id></terms_id><terms_name></terms_name><currency_id></currency_id><currency_name></currency_name><exchange_rate></exchange_rate><bill_total></bill_total><amount_open></amount_open><subsidiary_id></subsidiary_id><subsidiary_name></subsidiary_name><department_id></department_id><department_name></department_name><class_id></class_id><class_name></class_name><location_id></location_id><location_name></location_name><ap_account_id></ap_account_id><ap_account_name></ap_account_name><posting_period_id></posting_period_id><posting_period_name></posting_period_name><status_code></status_code><status_name></status_name><approval_status_id></approval_status_id><approval_status_name></approval_status_name><is_posting></is_posting><is_voided></is_voided><created_date></created_date><last_modified></last_modified></items><offset>0</offset><totalResults>1</totalResults></root>',
    @BaseTableName = N'dbo.tb_Netsuite_VendorBill',
    @RecordPath    = N'items';

EXEC dbo.BPA_ImportXml
    @Xml           = N'<root><count>1</count><hasMore>false</hasMore><items Array="true"><vendor_bill_id>__template__</vendor_bill_id><line_id></line_id><line_number></line_number><line_type></line_type><item_id></item_id><item_name></item_name><account_id></account_id><account_name></account_name><memo></memo><quantity></quantity><rate></rate><amount></amount><base_amount></base_amount><department_id></department_id><department_name></department_name><class_id></class_id><class_name></class_name><location_id></location_id><location_name></location_name><line_entity_id></line_entity_id><line_entity_name></line_entity_name></items><offset>0</offset><totalResults>1</totalResults></root>',
    @BaseTableName = N'dbo.tb_Netsuite_VendorBillLine',
    @RecordPath    = N'items';

-- dynamic: the columns only exist from the calls above on
EXEC (N'DELETE FROM dbo.tb_Netsuite_VendorBill     WHERE vendor_bill_id = N''__template__'';
        DELETE FROM dbo.tb_Netsuite_VendorBillLine WHERE vendor_bill_id = N''__template__'';');

COMMIT TRANSACTION;
GO

CREATE OR ALTER VIEW dbo.vw_Netsuite_VendorBill
AS
/* Latest imported row per vendor bill, typed. last_imported_at tells you when
   NetSuite last returned it: an open bill that the latest run didn't return
   is no longer open in NetSuite (paid, voided or deleted). */
SELECT
    vendor_bill_id         = CONVERT(nvarchar(100), b.vendor_bill_id),
    bill_number            = b.bill_number,
    vendor_invoice_number  = b.vendor_invoice_number,
    external_id            = CONVERT(nvarchar(100), b.external_id),
    bill_date              = TRY_CONVERT(date, b.bill_date, 23),
    due_date               = TRY_CONVERT(date, b.due_date, 23),
    vendor_id              = CONVERT(nvarchar(100), b.vendor_id),
    vendor_name            = b.vendor_name,
    memo                   = b.memo,
    terms_id               = CONVERT(nvarchar(100), b.terms_id),
    terms_name             = b.terms_name,
    currency_id            = CONVERT(nvarchar(100), b.currency_id),
    currency_name          = b.currency_name,
    exchange_rate          = COALESCE(TRY_CONVERT(decimal(28,10), b.exchange_rate), TRY_CONVERT(decimal(28,10), TRY_CONVERT(float, b.exchange_rate))),
    bill_total             = COALESCE(TRY_CONVERT(decimal(19,4), b.bill_total), TRY_CONVERT(decimal(19,4), TRY_CONVERT(float, b.bill_total))),
    amount_open            = COALESCE(TRY_CONVERT(decimal(19,4), b.amount_open), TRY_CONVERT(decimal(19,4), TRY_CONVERT(float, b.amount_open))),
    subsidiary_id          = CONVERT(nvarchar(100), b.subsidiary_id),
    subsidiary_name        = b.subsidiary_name,
    department_id          = CONVERT(nvarchar(100), b.department_id),
    department_name        = b.department_name,
    class_id               = CONVERT(nvarchar(100), b.class_id),
    class_name             = b.class_name,
    location_id            = CONVERT(nvarchar(100), b.location_id),
    location_name          = b.location_name,
    ap_account_id          = CONVERT(nvarchar(100), b.ap_account_id),
    ap_account_name        = b.ap_account_name,
    posting_period_id      = CONVERT(nvarchar(100), b.posting_period_id),
    posting_period_name    = b.posting_period_name,
    status_code            = b.status_code,
    status_name            = b.status_name,
    approval_status_id     = CONVERT(nvarchar(100), b.approval_status_id),
    approval_status_name   = b.approval_status_name,
    is_posting             = CAST(CASE WHEN b.is_posting IN (N'T', N'true') THEN 1 WHEN b.is_posting IN (N'F', N'false') THEN 0 END AS bit),
    is_voided              = CAST(CASE WHEN b.is_voided IN (N'T', N'true') THEN 1 WHEN b.is_voided IN (N'F', N'false') THEN 0 END AS bit),
    created_date           = TRY_CONVERT(datetime2(0), b.created_date, 120),
    last_modified          = TRY_CONVERT(datetime2(0), b.last_modified, 120),
    last_imported_at       = b.BPA_Syscreated,
    bpa_entry_id           = b.BPA_EntryID,
    bpa_status             = b.BPA_Status
FROM (
    SELECT t.*,
           rn = ROW_NUMBER() OVER (PARTITION BY CONVERT(nvarchar(100), t.vendor_bill_id)
                                   ORDER BY t.BPA_Syscreated DESC, t.BPA_EntryID DESC)
    FROM dbo.tb_Netsuite_VendorBill t
    WHERE t.vendor_bill_id IS NOT NULL
) b
WHERE b.rn = 1;
GO

CREATE OR ALTER VIEW dbo.vw_Netsuite_VendorBillLine
AS
/* Lines of each bill imported at or after that bill's latest header import,
   latest row per line, typed. Lines removed from a bill in NetSuite aren't
   re-imported and so drop out once the bill is imported again. */
SELECT
    vendor_bill_id         = CONVERT(nvarchar(100), l.vendor_bill_id),
    line_id                = CONVERT(nvarchar(100), l.line_id),
    line_number            = TRY_CONVERT(int, l.line_number),
    line_type              = l.line_type,
    item_id                = CONVERT(nvarchar(100), l.item_id),
    item_name              = l.item_name,
    account_id             = CONVERT(nvarchar(100), l.account_id),
    account_name           = l.account_name,
    memo                   = l.memo,
    quantity               = COALESCE(TRY_CONVERT(decimal(28,10), l.quantity), TRY_CONVERT(decimal(28,10), TRY_CONVERT(float, l.quantity))),
    rate                   = COALESCE(TRY_CONVERT(decimal(28,10), l.rate), TRY_CONVERT(decimal(28,10), TRY_CONVERT(float, l.rate))),
    amount                 = COALESCE(TRY_CONVERT(decimal(19,4), l.amount), TRY_CONVERT(decimal(19,4), TRY_CONVERT(float, l.amount))),
    base_amount            = COALESCE(TRY_CONVERT(decimal(19,4), l.base_amount), TRY_CONVERT(decimal(19,4), TRY_CONVERT(float, l.base_amount))),
    department_id          = CONVERT(nvarchar(100), l.department_id),
    department_name        = l.department_name,
    class_id               = CONVERT(nvarchar(100), l.class_id),
    class_name             = l.class_name,
    location_id            = CONVERT(nvarchar(100), l.location_id),
    location_name          = l.location_name,
    line_entity_id         = CONVERT(nvarchar(100), l.line_entity_id),
    line_entity_name       = l.line_entity_name,
    last_imported_at       = l.BPA_Syscreated,
    bpa_entry_id           = l.BPA_EntryID,
    bpa_status             = l.BPA_Status
FROM (
    SELECT t.*,
           rn = ROW_NUMBER() OVER (PARTITION BY CONVERT(nvarchar(100), t.vendor_bill_id), CONVERT(nvarchar(100), t.line_id)
                                   ORDER BY t.BPA_Syscreated DESC, t.BPA_EntryID DESC)
    FROM dbo.tb_Netsuite_VendorBillLine t
    JOIN (
        SELECT vendor_bill_id   = CONVERT(nvarchar(100), vendor_bill_id),
               header_imported_at = MAX(BPA_Syscreated)
        FROM dbo.tb_Netsuite_VendorBill
        WHERE vendor_bill_id IS NOT NULL
        GROUP BY CONVERT(nvarchar(100), vendor_bill_id)
    ) h ON h.vendor_bill_id = CONVERT(nvarchar(100), t.vendor_bill_id)
    WHERE t.BPA_Syscreated >= h.header_imported_at
      AND t.line_id IS NOT NULL
) l
WHERE l.rn = 1;
GO
