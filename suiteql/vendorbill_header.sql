/*
    NetSuite SuiteQL - vendor bill headers (one row per bill).
    Feeds dbo.usp_Netsuite_VendorBill_Load via the Web Service Connector.

    Filter: every bill that is still open, plus every bill modified since the
    last run. Replace {{since}} with 'YYYY-MM-DD HH24:MI:SS' (e.g. the max
    last_modified already in staging minus one day). Use '1900-01-01 00:00:00'
    for a full initial load.

    Notes
    - SuiteQL leaves NULL columns out of the JSON, so every element is optional
      on the XML side.
    - tranid on a vendor bill is the "Reference No." the vendor printed on the
      invoice; transactionnumber is NetSuite's own auto-number (VENDBILL123).
      The old query had these the other way round and used otherrefnum, which
      is normally empty on bills.
    - Add custom body fields (custbody_...) at the end as needed. Keep the
      aliases lowercase: they become the XML element names.
    - Keep ORDER BY t.id: paging with offset relies on a stable order.
*/
SELECT
    t.id                                                AS vendor_bill_id,
    t.transactionnumber                                 AS bill_number,
    t.tranid                                            AS vendor_invoice_number,
    t.externalid                                        AS external_id,
    TO_CHAR(t.trandate, 'YYYY-MM-DD')                   AS bill_date,
    TO_CHAR(t.duedate, 'YYYY-MM-DD')                    AS due_date,
    t.entity                                            AS vendor_id,
    BUILTIN.DF(t.entity)                                AS vendor_name,
    t.memo                                              AS memo,
    t.terms                                             AS terms_id,
    BUILTIN.DF(t.terms)                                 AS terms_name,
    t.currency                                          AS currency_id,
    BUILTIN.DF(t.currency)                              AS currency_name,
    t.exchangerate                                      AS exchange_rate,
    t.foreigntotal                                      AS bill_total,
    t.foreignamountunpaid                               AS amount_open,
    tl.subsidiary                                       AS subsidiary_id,
    BUILTIN.DF(tl.subsidiary)                           AS subsidiary_name,
    tl.department                                       AS department_id,
    BUILTIN.DF(tl.department)                           AS department_name,
    tl.class                                            AS class_id,
    BUILTIN.DF(tl.class)                                AS class_name,
    tl.location                                         AS location_id,
    BUILTIN.DF(tl.location)                             AS location_name,
    tl.expenseaccount                                   AS ap_account_id,
    BUILTIN.DF(tl.expenseaccount)                       AS ap_account_name,
    t.postingperiod                                     AS posting_period_id,
    BUILTIN.DF(t.postingperiod)                         AS posting_period_name,
    t.status                                            AS status_code,
    BUILTIN.DF(t.status)                                AS status_name,
    t.approvalstatus                                    AS approval_status_id,
    BUILTIN.DF(t.approvalstatus)                        AS approval_status_name,
    t.posting                                           AS is_posting,
    t.voided                                            AS is_voided,
    TO_CHAR(t.createddate, 'YYYY-MM-DD HH24:MI:SS')     AS created_date,
    TO_CHAR(t.lastmodifieddate, 'YYYY-MM-DD HH24:MI:SS') AS last_modified
FROM transaction t
JOIN transactionline tl
    ON tl.transaction = t.id
   AND tl.mainline = 'T'
WHERE t.recordtype = 'vendorbill'
  AND (   NVL(t.foreignamountunpaid, 0) > 0
       OR t.lastmodifieddate >= TO_DATE('{{since}}', 'YYYY-MM-DD HH24:MI:SS'))
ORDER BY t.id
