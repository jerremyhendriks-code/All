/*
    NetSuite SuiteQL - vendor bill lines (expense, item and tax lines).
    Feeds dbo.usp_Netsuite_VendorBillLine_Load via the Web Service Connector.

    Use the same {{since}} value as vendorbill_header.sql so lines and headers
    cover the same bills.

    Notes
    - account_id comes from the primary accounting book's GL impact
      (transactionaccountingline). Bills that don't post yet (pending approval)
      have no GL impact, so it falls back to the line's expense account; item
      lines on such bills then have no account.
    - Amounts are in the bill currency (foreignamount) and, where the bill
      posts, in base currency (base_amount, primary book).
    - line_type: 'expense' (Expenses tab), 'item' (Items tab), 'tax' (tax lines).
    - Keep ORDER BY: paging with offset relies on a stable order.
*/
SELECT
    tl.transaction                                      AS vendor_bill_id,
    tl.id                                               AS line_id,
    tl.linesequencenumber                               AS line_number,
    CASE
        WHEN tl.taxline = 'T'    THEN 'tax'
        WHEN tl.item IS NOT NULL THEN 'item'
        ELSE 'expense'
    END                                                 AS line_type,
    tl.item                                             AS item_id,
    BUILTIN.DF(tl.item)                                 AS item_name,
    NVL(tal.account, tl.expenseaccount)                 AS account_id,
    BUILTIN.DF(NVL(tal.account, tl.expenseaccount))     AS account_name,
    tl.memo                                             AS memo,
    tl.quantity                                         AS quantity,
    tl.rate                                             AS rate,
    tl.foreignamount                                    AS amount,
    tal.amount                                          AS base_amount,
    tl.department                                       AS department_id,
    BUILTIN.DF(tl.department)                           AS department_name,
    tl.class                                            AS class_id,
    BUILTIN.DF(tl.class)                                AS class_name,
    tl.location                                         AS location_id,
    BUILTIN.DF(tl.location)                             AS location_name,
    tl.entity                                           AS line_entity_id,
    BUILTIN.DF(tl.entity)                               AS line_entity_name
FROM transaction t
JOIN transactionline tl
    ON tl.transaction = t.id
   AND tl.mainline = 'F'
LEFT JOIN transactionaccountingline tal
    ON tal.transaction = tl.transaction
   AND tal.transactionline = tl.id
LEFT JOIN accountingbook ab
    ON ab.id = tal.accountingbook
WHERE t.recordtype = 'vendorbill'
  AND (tal.transaction IS NULL OR ab.isprimary = 'T')
  AND (   NVL(t.foreignamountunpaid, 0) > 0
       OR t.lastmodifieddate >= TO_DATE('{{since}}', 'YYYY-MM-DD HH24:MI:SS'))
ORDER BY tl.transaction, tl.id
