/*
    Test data for the BPA Platform TO task: vendor payments into NetSuite.

    Inserts three vendor payments into tb_Netsuite_VendorPayment with their
    child rows in tb_Netsuite_VendorPayment_Apply, linked through
    BPA_ParentID = parent BPA_EntryID.

      BPA-TEST-VP-0001  one bill, paid in full
      BPA-TEST-VP-0002  two bills, the second one partially
      BPA-TEST-VP-0003  second subsidiary / currency, one bill

    No vendor credit test: tb_Netsuite_VendorPayment_Credit has no column for the
    credit document (doc id), so a credit to apply cannot be specified yet.

    Before running:
    - Fill in the sandbox internal ids below; the script stops while any
      REPLACE_ value is left.
    - Check the BPA_* control values against how the TO task selects its rows.

    Remove the test rows again with the cleanup block at the bottom.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

-- BPA control values -------------------------------------------------------
DECLARE @origin    nvarchar(50) = N'TEST',
        @direction nvarchar(50) = N'TO',
        @company   nvarchar(50) = N'Ellomay',
        @action    nvarchar(1)  = N'I',
        @status    int          = 0,
        @creator   nvarchar(50) = N'BPA-TEST';

-- NetSuite sandbox internal ids --------------------------------------------
-- Subsidiary 1 (payments 0001 and 0002)
DECLARE @sub1_id         nvarchar(100) = N'10',
        @sub1_vendor_id  nvarchar(100) = N'4127',
        @sub1_bank_id    nvarchar(100) = N'REPLACE_bank_account_1_id',
        @sub1_apacct_id  nvarchar(100) = N'REPLACE_ap_account_1_id',
        @sub1_curr_id    nvarchar(100) = N'5',
        @bill_a_id       nvarchar(100) = N'REPLACE_id_of_BPA-TEST-VB-A',  -- 1,250.00 open
        @bill_b_id       nvarchar(100) = N'REPLACE_id_of_BPA-TEST-VB-B',  --   800.00 open
        @bill_c_id       nvarchar(100) = N'REPLACE_id_of_BPA-TEST-VB-C';  --   500.00 open, 200.00 paid

-- Subsidiary 2 (payment 0003), preferably with another base currency
DECLARE @sub2_id         nvarchar(100) = N'REPLACE_subsidiary_2_id',
        @sub2_vendor_id  nvarchar(100) = N'REPLACE_vendor_2_id',
        @sub2_bank_id    nvarchar(100) = N'REPLACE_bank_account_2_id',
        @sub2_apacct_id  nvarchar(100) = N'REPLACE_ap_account_2_id',
        @sub2_curr_id    nvarchar(100) = N'REPLACE_currency_2_id',
        @sub2_rate       nvarchar(50)  = N'1.0',
        @bill_d_id       nvarchar(100) = N'REPLACE_id_of_BPA-TEST-VB-D';  -- 1,000.00 open

IF EXISTS (SELECT 1 FROM (VALUES (@sub1_id), (@sub1_vendor_id), (@sub1_bank_id), (@sub1_apacct_id),
                                 (@sub1_curr_id), (@bill_a_id), (@bill_b_id), (@bill_c_id),
                                 (@sub2_id), (@sub2_vendor_id), (@sub2_bank_id), (@sub2_apacct_id),
                                 (@sub2_curr_id), (@bill_d_id)) v(val)
           WHERE val LIKE N'REPLACE[_]%')
    THROW 50001, N'Fill in the NetSuite internal ids (REPLACE_ values) before running this script.', 1;

DECLARE @vp1 uniqueidentifier = NEWID(),
        @vp2 uniqueidentifier = NEWID(),
        @vp3 uniqueidentifier = NEWID(),
        @now datetime         = GETDATE();

BEGIN TRANSACTION;

-- Parents ------------------------------------------------------------------
-- [id] is NOT NULL but only known after NetSuite creates the payment, so it is left empty.
INSERT INTO dbo.tb_Netsuite_VendorPayment
    (BPA_EntryID, BPA_Origin, BPA_Direction, BPA_Company, BPA_Status, BPA_Action,
     BPA_Reference, BPA_Reference_Description, BPA_Syscreated, BPA_Sysmodified, BPA_Syscreator, BPA_Failcount,
     id, externalId, tranDate, memo, exchangeRate, toBePrinted, toBeEmailed,
     entityId, subsidiaryId, accountId, apAcctId, currencyId)
VALUES
    (@vp1, @origin, @direction, @company, @status, @action,
     N'BPA-TEST-VP-0001', N'One bill, paid in full', @now, @now, @creator, 0,
     N'', N'BPA-TEST-VP-0001', N'2026-09-28', N'BPA TO test - one bill paid in full', NULL, 0, 0,
     @sub1_vendor_id, @sub1_id, @sub1_bank_id, @sub1_apacct_id, @sub1_curr_id),

    (@vp2, @origin, @direction, @company, @status, @action,
     N'BPA-TEST-VP-0002', N'Two bills, second one partially', @now, @now, @creator, 0,
     N'', N'BPA-TEST-VP-0002', N'2026-09-28', N'BPA TO test - two bills, one partial', NULL, 0, 0,
     @sub1_vendor_id, @sub1_id, @sub1_bank_id, @sub1_apacct_id, @sub1_curr_id),

    (@vp3, @origin, @direction, @company, @status, @action,
     N'BPA-TEST-VP-0003', N'Second subsidiary, one bill', @now, @now, @creator, 0,
     N'', N'BPA-TEST-VP-0003', N'2026-09-28', N'BPA TO test - second subsidiary', @sub2_rate, 0, 0,
     @sub2_vendor_id, @sub2_id, @sub2_bank_id, @sub2_apacct_id, @sub2_curr_id);

-- Apply lines (bills paid) ---------------------------------------------------
INSERT INTO dbo.tb_Netsuite_VendorPayment_Apply
    (BPA_EntryID, BPA_ParentID, BPA_Origin, BPA_Direction, BPA_Company, BPA_Status, BPA_Action,
     BPA_Reference, BPA_Syscreated, BPA_Sysmodified, BPA_Syscreator, BPA_Failcount,
     doc_id, apply, amount)
VALUES
    (NEWID(), @vp1, @origin, @direction, @company, @status, @action,
     N'BPA-TEST-VP-0001', @now, @now, @creator, 0,
     @bill_a_id, 1, 1250.00),

    (NEWID(), @vp2, @origin, @direction, @company, @status, @action,
     N'BPA-TEST-VP-0002', @now, @now, @creator, 0,
     @bill_b_id, 1, 800.00),
    (NEWID(), @vp2, @origin, @direction, @company, @status, @action,
     N'BPA-TEST-VP-0002', @now, @now, @creator, 0,
     @bill_c_id, 1, 200.00),

    (NEWID(), @vp3, @origin, @direction, @company, @status, @action,
     N'BPA-TEST-VP-0003', @now, @now, @creator, 0,
     @bill_d_id, 1, 1000.00);

COMMIT TRANSACTION;

-- Check ----------------------------------------------------------------------
SELECT p.externalId, p.subsidiaryId, p.currencyId,
       (SELECT COUNT(*) FROM dbo.tb_Netsuite_VendorPayment_Apply  a WHERE a.BPA_ParentID = p.BPA_EntryID) AS apply_rows,
       (SELECT SUM(a.amount) FROM dbo.tb_Netsuite_VendorPayment_Apply a WHERE a.BPA_ParentID = p.BPA_EntryID) AS apply_amount,
       p.BPA_Status, p.BPA_ReturnedID, p.BPA_Error
FROM dbo.tb_Netsuite_VendorPayment p
WHERE p.externalId LIKE N'BPA-TEST-VP-%'
ORDER BY p.externalId;

/* Cleanup --------------------------------------------------------------------
BEGIN TRANSACTION;
DELETE a FROM dbo.tb_Netsuite_VendorPayment_Apply a
    JOIN dbo.tb_Netsuite_VendorPayment p ON p.BPA_EntryID = a.BPA_ParentID
    WHERE p.externalId LIKE N'BPA-TEST-VP-%';
DELETE FROM dbo.tb_Netsuite_VendorPayment
    WHERE externalId LIKE N'BPA-TEST-VP-%';
COMMIT TRANSACTION;
*/
