/*
    Tracamyl: fill the link table between DCRM products and Exact ES items.

    A product is linked to the Exact item with the same code (productnumber = ItemCode)
    in the same company. Only 'FROM' records are used on both sides.
    Adds links that don't exist yet; existing links are left alone, so it's safe to
    run as often as you like.
*/
CREATE OR ALTER PROCEDURE dbo.usp_Fill_Link_ExactES_Items_DCRM_Product
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.tb_Link_ExactES_Items_DCRM_Product (DCRM_ProductID, ExactES_ItemCode, BPA_Company)
    SELECT DISTINCT d.productid, e.ItemCode, e.BPA_Company
    FROM dbo.tb_DCRM_Product d
    INNER JOIN dbo.tb_ExactES_Items e
        ON  e.ItemCode    = d.productnumber
        AND e.BPA_Company = d.BPA_Company
    WHERE d.BPA_Direction = 'FROM'
      AND e.BPA_Direction = 'FROM'
      AND NOT EXISTS (SELECT 1
                      FROM dbo.tb_Link_ExactES_Items_DCRM_Product l
                      WHERE l.DCRM_ProductID = d.productid);
END
