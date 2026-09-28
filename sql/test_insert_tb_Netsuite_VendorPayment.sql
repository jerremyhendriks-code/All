/*
    Test data for the BPA Platform TO task: vendor payments into NetSuite.

    Inserts up to three vendor payments into tb_Netsuite_VendorPayment with
    their child rows in tb_Netsuite_VendorPayment_Apply, linked through
    BPA_ParentID = parent BPA_EntryID.

      BPA-TEST-VP-0001  Ellomay Capital (ILS), one bill, paid in full
      BPA-TEST-VP-0002  Ellomay Capital (ILS), two bills, the second one partially
      BPA-TEST-VP-0003  GGG (EUR), existing bill 77777777, paid partially so it
                        stays open for the next test run

    A test is only inserted once all of its ids are filled in; tests that still
    have a REPLACE_ value are skipped with a message.

    No vendor credit test: tb_Netsuite_VendorPayment_Credit has no column for the
    credit document (doc id), so a credit to apply cannot be specified yet.

    Before running, check the BPA_* control values against how the TO task
    selects its rows. Remove the test rows again with the cleanup block at the
    bottom.
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
-- Ellomay Capital (payments 0001 and 0002), bills from payloads/netsuite/vendorBill_A..C
DECLARE @sub1_id         nvarchar(100) = N'10',
        @sub1_vendor_id  nvarchar(100) = N'4127',  -- 20810 OR TEC NET LTD
        @sub1_bank_id    nvarchar(100) = N'REPLACE_bank_account_1_id',
        @sub1_apacct_id  nvarchar(100) = N'460',
        @sub1_curr_id    nvarchar(100) = N'5',     -- ILS
        @bill_a_id       nvarchar(100) = N'REPLACE_id_of_BPA-TEST-VB-A',  -- 1,250.00 open
        @bill_b_id       nvarchar(100) = N'REPLACE_id_of_BPA-TEST-VB-B',  --   800.00 open
        @bill_c_id       nvarchar(100) = N'REPLACE_id_of_BPA-TEST-VB-C';  --   500.00 open, 200.00 paid

-- GGG (payment 0003)
DECLARE @sub2_id         nvarchar(100) = N'89',    -- GGG
        @sub2_vendor_id  nvarchar(100) = N'5733',  -- 21705 Lucas Westra B.V.
        @sub2_bank_id    nvarchar(100) = N'REPLACE_bank_account_2_id',
        @sub2_apacct_id  nvarchar(100) = NULL,     -- no AP field on the form: NetSuite default
        @sub2_curr_id    nvarchar(100) = N'4',     -- EUR, base currency of GGG
        @sub2_rate       nvarchar(50)  = N'1.0',
        @bill_d_id       nvarchar(100) = N'37393'; -- bill 77777777, 8,888.00 open, 1,000.00 paid

DECLARE @run1 bit = CASE WHEN EXISTS (SELECT 1 FROM (VALUES (@sub1_id), (@sub1_vendor_id), (@sub1_bank_id),
                                                            (@sub1_apacct_id), (@sub1_curr_id), (@bill_a_id)) v(val)
                                      WHERE val LIKE N'REPLACE[_]%') THEN 0 ELSE 1 END,
        @run2 bit = CASE WHEN EXISTS (SELECT 1 FROM (VALUES (@sub1_id), (@sub1_vendor_id), (@sub1_bank_id),
                                                            (@sub1_apacct_id), (@sub1_curr_id), (@bill_b_id), (@bill_c_id)) v(val)
                                      WHERE val LIKE N'REPLACE[_]%') THEN 0 ELSE 1 END,
        @run3 bit = CASE WHEN EXISTS (SELECT 1 FROM (VALUES (@sub2_id), (@sub2_vendor_id), (@sub2_bank_id),
                                                            (@sub2_apacct_id), (@sub2_curr_id), (@bill_d_id)) v(val)
                                      WHERE val LIKE N'REPLACE[_]%') THEN 0 ELSE 1 END;

IF @run1 = 0 PRINT N'Skipped BPA-TEST-VP-0001 (REPLACE_ values left)';
IF @run2 = 0 PRINT N'Skipped BPA-TEST-VP-0002 (REPLACE_ values left)';
IF @run3 = 0 PRINT N'Skipped BPA-TEST-VP-0003 (REPLACE_ values left)';

DECLARE @vp1 uniqueidentifier = NEWID(),
        @vp2 uniqueidentifier = NEWID(),
        @vp3 uniqueidentifier = NEWID(),
        @now datetime         = GETDATE();

BEGIN TRANSACTION;

-- [id] is NOT NULL but only known after NetSuite creates the payment, so it is left empty.

-- BPA-TEST-VP-0001 -------------------------------------------------------------
IF @run1 = 1
BEGIN
    INSERT INTO dbo.tb_Netsuite_VendorPayment
        (BPA_EntryID, BPA_Origin, BPA_Direction, BPA_Company, BPA_Status, BPA_Action,
         BPA_Reference, BPA_Reference_Description, BPA_Syscreated, BPA_Sysmodified, BPA_Syscreator, BPA_Failcount,
         id, externalId, tranDate, memo, exchangeRate, toBePrinted, toBeEmailed,
         entityId, subsidiaryId, accountId, apAcctId, currencyId)
    VALUES
        (@vp1, @origin, @direction, @company, @status, @action,
         N'BPA-TEST-VP-0001', N'One bill, paid in full', @now, @now, @creator, 0,
         N'', N'BPA-TEST-VP-0001', N'2026-09-28', N'BPA TO test - one bill paid in full', NULL, 0, 0,
         @sub1_vendor_id, @sub1_id, @sub1_bank_id, @sub1_apacct_id, @sub1_curr_id);

    INSERT INTO dbo.tb_Netsuite_VendorPayment_Apply
        (BPA_EntryID, BPA_ParentID, BPA_Origin, BPA_Direction, BPA_Company, BPA_Status, BPA_Action,
         BPA_Reference, BPA_Syscreated, BPA_Sysmodified, BPA_Syscreator, BPA_Failcount,
         doc_id, apply, amount)
    VALUES
        (NEWID(), @vp1, @origin, @direction, @company, @status, @action,
         N'BPA-TEST-VP-0001', @now, @now, @creator, 0,
         @bill_a_id, 1, 1250.00);
END

-- BPA-TEST-VP-0002 -------------------------------------------------------------
IF @run2 = 1
BEGIN
    INSERT INTO dbo.tb_Netsuite_VendorPayment
        (BPA_EntryID, BPA_Origin, BPA_Direction, BPA_Company, BPA_Status, BPA_Action,
         BPA_Reference, BPA_Reference_Description, BPA_Syscreated, BPA_Sysmodified, BPA_Syscreator, BPA_Failcount,
         id, externalId, tranDate, memo, exchangeRate, toBePrinted, toBeEmailed,
         entityId, subsidiaryId, accountId, apAcctId, currencyId)
    VALUES
        (@vp2, @origin, @direction, @company, @status, @action,
         N'BPA-TEST-VP-0002', N'Two bills, second one partially', @now, @now, @creator, 0,
         N'', N'BPA-TEST-VP-0002', N'2026-09-28', N'BPA TO test - two bills, one partial', NULL, 0, 0,
         @sub1_vendor_id, @sub1_id, @sub1_bank_id, @sub1_apacct_id, @sub1_curr_id);

    INSERT INTO dbo.tb_Netsuite_VendorPayment_Apply
        (BPA_EntryID, BPA_ParentID, BPA_Origin, BPA_Direction, BPA_Company, BPA_Status, BPA_Action,
         BPA_Reference, BPA_Syscreated, BPA_Sysmodified, BPA_Syscreator, BPA_Failcount,
         doc_id, apply, amount)
    VALUES
        (NEWID(), @vp2, @origin, @direction, @company, @status, @action,
         N'BPA-TEST-VP-0002', @now, @now, @creator, 0,
         @bill_b_id, 1, 800.00),
        (NEWID(), @vp2, @origin, @direction, @company, @status, @action,
         N'BPA-TEST-VP-0002', @now, @now, @creator, 0,
         @bill_c_id, 1, 200.00);
END

-- BPA-TEST-VP-0003 -------------------------------------------------------------
IF @run3 = 1
BEGIN
    INSERT INTO dbo.tb_Netsuite_VendorPayment
        (BPA_EntryID, BPA_Origin, BPA_Direction, BPA_Company, BPA_Status, BPA_Action,
         BPA_Reference, BPA_Reference_Description, BPA_Syscreated, BPA_Sysmodified, BPA_Syscreator, BPA_Failcount,
         id, externalId, tranDate, memo, exchangeRate, toBePrinted, toBeEmailed,
         entityId, subsidiaryId, accountId, apAcctId, currencyId)
    VALUES
        (@vp3, @origin, @direction, @company, @status, @action,
         N'BPA-TEST-VP-0003', N'GGG, existing bill paid partially', @now, @now, @creator, 0,
         N'', N'BPA-TEST-VP-0003', N'2026-09-28', N'BPA TO test - GGG partial payment', @sub2_rate, 0, 0,
         @sub2_vendor_id, @sub2_id, @sub2_bank_id, @sub2_apacct_id, @sub2_curr_id);

    INSERT INTO dbo.tb_Netsuite_VendorPayment_Apply
        (BPA_EntryID, BPA_ParentID, BPA_Origin, BPA_Direction, BPA_Company, BPA_Status, BPA_Action,
         BPA_Reference, BPA_Syscreated, BPA_Sysmodified, BPA_Syscreator, BPA_Failcount,
         doc_id, apply, amount)
    VALUES
        (NEWID(), @vp3, @origin, @direction, @company, @status, @action,
         N'BPA-TEST-VP-0003', @now, @now, @creator, 0,
         @bill_d_id, 1, 1000.00);
END

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
