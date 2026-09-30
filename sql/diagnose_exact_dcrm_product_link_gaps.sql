/*
    Why do Exact items that match a DCRM product (same code, same company) have no
    row in tb_Link_ExactES_Items_DCRM_Product?

    Takes the rows returned by the "missing link" query and puts each one in a
    reason bucket, so we can see how many are really unsynced and how many are
    caused by data problems or by the query itself.

    Read-only. Before running, check the columns marked -- ADJUST: the Exact item
    key, the Exact column in the link table, and the DCRM state column.

    Buckets (first match wins, in this order):
      1  EXACT_ITEM_LINKED_TO_OTHER_PRODUCT  the Exact item has a link row, but to a
                                              different DCRM product (product recreated
                                              in DCRM, or duplicate product numbers)
      2  LINK_EXISTS_OTHER_COMPANY            a link row for this productid exists, but
                                              with another/NULL BPA_Company
      3  SIBLING_PRODUCT_LINKED               another DCRM product with the same number
                                              in the same company is linked
      4  DUPLICATE_PRODUCTNUMBER              productnumber is not unique per company
      5  DUPLICATE_ITEMCODE                   ItemCode is not unique per company
      6  WHITESPACE_OR_HIDDEN_CHARS           leading/trailing spaces, tab, CR, LF or
                                              non-breaking space in either code
      7  CASE_DIFFERENCE                      codes only match case-insensitively
      8  DCRM_PRODUCT_INACTIVE                product is not active in DCRM
      9  EXACT_ITEM_NOT_ACTIVE                Exact Condition is not the "active" value
      10 GENUINELY_UNLINKED                   none of the above
*/
SET NOCOUNT ON;

IF OBJECT_ID(N'tempdb..#gap') IS NOT NULL DROP TABLE #gap;

-- Same rows as the original query, plus the keys needed to classify them.
-- No NOLOCK: dirty reads during a running sync can add or drop rows.
SELECT
    exactItem.ID              AS ExactItemID,        -- ADJUST: Exact item key column
    exactItem.ItemCode,
    exactItem.Condition,
    exactItem.BPA_Company,
    dcrmProduct.productid     AS DCRM_ProductID,
    dcrmProduct.productnumber,
    dcrmProduct.statecode     AS DCRM_StateCode      -- ADJUST: DCRM state column
INTO #gap
FROM dbo.tb_ExactES_Items AS exactItem
INNER JOIN dbo.tb_DCRM_Product AS dcrmProduct
    ON  dcrmProduct.productnumber = exactItem.ItemCode
    AND dcrmProduct.BPA_Company   = exactItem.BPA_Company
LEFT JOIN dbo.tb_Link_ExactES_Items_DCRM_Product AS link
    ON  link.BPA_Company    = exactItem.BPA_Company
    AND link.DCRM_ProductID = dcrmProduct.productid
WHERE link.DCRM_ProductID IS NULL;

-- 0. Is the ~6k inflated by join fan-out?
SELECT
    COUNT(*)                                             AS result_rows,
    COUNT(DISTINCT DCRM_ProductID)                       AS distinct_dcrm_products,
    COUNT(DISTINCT CONCAT(BPA_Company, N'|', ItemCode))  AS distinct_itemcodes_per_company
FROM #gap;

-- Classify each row.
IF OBJECT_ID(N'tempdb..#classified') IS NOT NULL DROP TABLE #classified;

SELECT
    g.*,
    CASE
        WHEN EXISTS (SELECT 1
                     FROM dbo.tb_Link_ExactES_Items_DCRM_Product AS l
                     WHERE l.ExactES_ItemID = g.ExactItemID          -- ADJUST: Exact column in link table
                       AND l.DCRM_ProductID <> g.DCRM_ProductID)
            THEN N'01 EXACT_ITEM_LINKED_TO_OTHER_PRODUCT'
        WHEN EXISTS (SELECT 1
                     FROM dbo.tb_Link_ExactES_Items_DCRM_Product AS l
                     WHERE l.DCRM_ProductID = g.DCRM_ProductID
                       AND (l.BPA_Company <> g.BPA_Company OR l.BPA_Company IS NULL))
            THEN N'02 LINK_EXISTS_OTHER_COMPANY'
        WHEN EXISTS (SELECT 1
                     FROM dbo.tb_DCRM_Product AS p
                     INNER JOIN dbo.tb_Link_ExactES_Items_DCRM_Product AS l
                         ON  l.DCRM_ProductID = p.productid
                         AND l.BPA_Company    = p.BPA_Company
                     WHERE p.BPA_Company   = g.BPA_Company
                       AND p.productnumber = g.productnumber
                       AND p.productid    <> g.DCRM_ProductID)
            THEN N'03 SIBLING_PRODUCT_LINKED'
        WHEN (SELECT COUNT(*) FROM dbo.tb_DCRM_Product AS p
              WHERE p.BPA_Company = g.BPA_Company AND p.productnumber = g.productnumber) > 1
            THEN N'04 DUPLICATE_PRODUCTNUMBER'
        WHEN (SELECT COUNT(*) FROM dbo.tb_ExactES_Items AS e
              WHERE e.BPA_Company = g.BPA_Company AND e.ItemCode = g.ItemCode) > 1
            THEN N'05 DUPLICATE_ITEMCODE'
        -- "=" ignores trailing spaces, so the SQL join matches while the sync
        -- (C#/API, exact string compare) may not. DATALENGTH does see them.
        WHEN DATALENGTH(g.ItemCode)      <> DATALENGTH(LTRIM(RTRIM(g.ItemCode)))
          OR DATALENGTH(g.productnumber) <> DATALENGTH(LTRIM(RTRIM(g.productnumber)))
          OR g.ItemCode      LIKE N'%[' + NCHAR(9) + NCHAR(10) + NCHAR(13) + NCHAR(160) + N']%'
          OR g.productnumber LIKE N'%[' + NCHAR(9) + NCHAR(10) + NCHAR(13) + NCHAR(160) + N']%'
          OR DATALENGTH(g.ItemCode) <> DATALENGTH(g.productnumber)
            THEN N'06 WHITESPACE_OR_HIDDEN_CHARS'
        WHEN g.ItemCode COLLATE Latin1_General_BIN2 <> g.productnumber COLLATE Latin1_General_BIN2
            THEN N'07 CASE_DIFFERENCE'
        WHEN g.DCRM_StateCode <> 0                                      -- ADJUST: 0 = Active in DCRM
            THEN N'08 DCRM_PRODUCT_INACTIVE'
        WHEN g.Condition IS NULL OR g.Condition <> N'A'                 -- ADJUST: Exact "active" condition value
            THEN N'09 EXACT_ITEM_NOT_ACTIVE'
        ELSE N'10 GENUINELY_UNLINKED'
    END AS Reason
INTO #classified
FROM #gap AS g;

-- Summary: how many rows per reason, per company.
SELECT Reason, BPA_Company, COUNT(*) AS rows_, COUNT(DISTINCT DCRM_ProductID) AS products
FROM #classified
GROUP BY Reason, BPA_Company
ORDER BY Reason, BPA_Company;

-- Distribution of Exact Condition values in the gap (to set the ADJUST value above).
SELECT Condition, COUNT(*) AS rows_
FROM #gap
GROUP BY Condition
ORDER BY rows_ DESC;

-- Detail, with the raw bytes so hidden characters are visible.
SELECT
    Reason, BPA_Company, ItemCode, productnumber, Condition, DCRM_StateCode,
    ExactItemID, DCRM_ProductID,
    CAST(ItemCode      AS varbinary(200)) AS ItemCode_bytes,
    CAST(productnumber AS varbinary(200)) AS productnumber_bytes
FROM #classified
ORDER BY Reason, BPA_Company, ItemCode;
