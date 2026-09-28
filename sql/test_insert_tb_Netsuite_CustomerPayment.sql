/*
    Test data for the BPA Platform TO task: customer payments into NetSuite.

    Inserts three customer payments into tb_Netsuite_CustomerPayment with their
    child rows in tb_Netsuite_CustomerPayment_Apply, linked through
    BPA_ParentID = parent BPA_EntryID.

      BPA-TEST-CP-0001  one invoice, paid in full
      BPA-TEST-CP-0002  two invoices, the second one partially
      BPA-TEST-CP-0003  second subsidiary / currency, one invoice plus an
                        unapplied remainder (payment > applied)

    No credit memo test: tb_Netsuite_CustomerPayment_Credit has no column for the
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
DECLARE @sub1_id          nvarchar(100) = N'REPLACE_subsidiary_1_id',
        @sub1_customer_id nvarchar(100) = N'REPLACE_customer_1_id',
        @sub1_bank_id     nvarchar(100) = N'REPLACE_bank_account_1_id',
        @sub1_aracct_id   nvarchar(100) = N'REPLACE_ar_account_1_id',
        @sub1_curr_id     nvarchar(100) = N'REPLACE_currency_1_id',
        @inv_a_id         nvarchar(100) = N'REPLACE_open_invoice_A_id',  -- 1,500.00 open
        @inv_b_id         nvarchar(100) = N'REPLACE_open_invoice_B_id',  --   600.00 open
        @inv_c_id         nvarchar(100) = N'REPLACE_open_invoice_C_id';  --   900.00 open, 400.00 paid

-- Subsidiary 2 (payment 0003), preferably with another base currency
DECLARE @sub2_id          nvarchar(100) = N'REPLACE_subsidiary_2_id',
        @sub2_customer_id nvarchar(100) = N'REPLACE_customer_2_id',
        @sub2_bank_id     nvarchar(100) = N'REPLACE_bank_account_2_id',
        @sub2_aracct_id   nvarchar(100) = N'REPLACE_ar_account_2_id',
        @sub2_curr_id     nvarchar(100) = N'REPLACE_currency_2_id',
        @sub2_rate        decimal(28, 10) = 1.0,
        @inv_d_id         nvarchar(100) = N'REPLACE_open_invoice_D_id';  -- 1,000.00 open

IF EXISTS (SELECT 1 FROM (VALUES (@sub1_id), (@sub1_customer_id), (@sub1_bank_id), (@sub1_aracct_id),
                                 (@sub1_curr_id), (@inv_a_id), (@inv_b_id), (@inv_c_id),
                                 (@sub2_id), (@sub2_customer_id), (@sub2_bank_id), (@sub2_aracct_id),
                                 (@sub2_curr_id), (@inv_d_id)) v(val)
           WHERE val LIKE N'REPLACE[_]%')
    THROW 50001, N'Fill in the NetSuite internal ids (REPLACE_ values) before running this script.', 1;

DECLARE @cp1 uniqueidentifier = NEWID(),
        @cp2 uniqueidentifier = NEWID(),
        @cp3 uniqueidentifier = NEWID(),
        @now datetime         = GETDATE();

BEGIN TRANSACTION;

-- Parents ------------------------------------------------------------------
-- [id] is only known after NetSuite creates the payment, so it is left NULL.
INSERT INTO dbo.tb_Netsuite_CustomerPayment
    (BPA_EntryID, BPA_Origin, BPA_Direction, BPA_Company, BPA_Status, BPA_Action,
     BPA_Reference, BPA_Reference_Description, BPA_Syscreated, BPA_Sysmodified, BPA_Syscreator, BPA_Failcount,
     externalId, tranDate, memo, payment, exchangeRate, autoApply, toBeEmailed,
     customer_id, subsidiary_id, account_id, arAcct_id, currency_id)
VALUES
    (@cp1, @origin, @direction, @company, @status, @action,
     N'BPA-TEST-CP-0001', N'One invoice, paid in full', @now, @now, @creator, 0,
     N'BPA-TEST-CP-0001', '2026-09-28', N'BPA TO test - one invoice paid in full', 1500.00, 1.0, 0, 0,
     @sub1_customer_id, @sub1_id, @sub1_bank_id, @sub1_aracct_id, @sub1_curr_id),

    (@cp2, @origin, @direction, @company, @status, @action,
     N'BPA-TEST-CP-0002', N'Two invoices, second one partially', @now, @now, @creator, 0,
     N'BPA-TEST-CP-0002', '2026-09-28', N'BPA TO test - two invoices, one partial', 1000.00, 1.0, 0, 0,
     @sub1_customer_id, @sub1_id, @sub1_bank_id, @sub1_aracct_id, @sub1_curr_id),

    (@cp3, @origin, @direction, @company, @status, @action,
     N'BPA-TEST-CP-0003', N'Second subsidiary, 250.00 left unapplied', @now, @now, @creator, 0,
     N'BPA-TEST-CP-0003', '2026-09-28', N'BPA TO test - second subsidiary with unapplied amount', 1250.00, @sub2_rate, 0, 0,
     @sub2_customer_id, @sub2_id, @sub2_bank_id, @sub2_aracct_id, @sub2_curr_id);

-- Apply lines (invoices paid) ------------------------------------------------
INSERT INTO dbo.tb_Netsuite_CustomerPayment_Apply
    (BPA_EntryID, BPA_ParentID, BPA_Origin, BPA_Direction, BPA_Company, BPA_Status, BPA_Action,
     BPA_Reference, BPA_Syscreated, BPA_Sysmodified, BPA_Syscreator, BPA_Failcount,
     doc_id, apply, amount)
VALUES
    (NEWID(), @cp1, @origin, @direction, @company, @status, @action,
     N'BPA-TEST-CP-0001', @now, @now, @creator, 0,
     @inv_a_id, 1, 1500.00),

    (NEWID(), @cp2, @origin, @direction, @company, @status, @action,
     N'BPA-TEST-CP-0002', @now, @now, @creator, 0,
     @inv_b_id, 1, 600.00),
    (NEWID(), @cp2, @origin, @direction, @company, @status, @action,
     N'BPA-TEST-CP-0002', @now, @now, @creator, 0,
     @inv_c_id, 1, 400.00),

    (NEWID(), @cp3, @origin, @direction, @company, @status, @action,
     N'BPA-TEST-CP-0003', @now, @now, @creator, 0,
     @inv_d_id, 1, 1000.00);

COMMIT TRANSACTION;

-- Check: payment vs applied per payment --------------------------------------
SELECT p.externalId, p.subsidiary_id, p.currency_id, p.payment,
       (SELECT COUNT(*)      FROM dbo.tb_Netsuite_CustomerPayment_Apply a WHERE a.BPA_ParentID = p.BPA_EntryID) AS apply_rows,
       (SELECT SUM(a.amount) FROM dbo.tb_Netsuite_CustomerPayment_Apply a WHERE a.BPA_ParentID = p.BPA_EntryID) AS apply_amount,
       p.BPA_Status, p.BPA_ReturnedID, p.BPA_Error
FROM dbo.tb_Netsuite_CustomerPayment p
WHERE p.externalId LIKE N'BPA-TEST-CP-%'
ORDER BY p.externalId;

/* Cleanup --------------------------------------------------------------------
BEGIN TRANSACTION;
DELETE a FROM dbo.tb_Netsuite_CustomerPayment_Apply a
    JOIN dbo.tb_Netsuite_CustomerPayment p ON p.BPA_EntryID = a.BPA_ParentID
    WHERE p.externalId LIKE N'BPA-TEST-CP-%';
DELETE FROM dbo.tb_Netsuite_CustomerPayment
    WHERE externalId LIKE N'BPA-TEST-CP-%';
COMMIT TRANSACTION;
*/
