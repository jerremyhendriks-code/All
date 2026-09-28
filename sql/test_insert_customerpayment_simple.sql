-- Test customer payment for the TO task: Metka Egn Italy S.R.L. (Italy 2) pays 100.00 of one open EUR invoice.
-- Values taken from existing payment PAYIT250020 (custpymt id 38700).
DECLARE @cp uniqueidentifier = NEWID();

INSERT INTO dbo.tb_Netsuite_CustomerPayment
    (BPA_EntryID, BPA_Origin, BPA_Direction, BPA_Status, BPA_Action, BPA_Reference, BPA_Syscreator,
     externalId, tranDate, memo, payment, exchangeRate,
     customer_id, subsidiary_id, account_id, arAcct_id, currency_id)
VALUES
    (@cp, N'TEST', N'TO', 0, N'I', N'BPA-TEST-CP-0003', N'BPA-TEST',
     N'BPA-TEST-CP-0003', '2026-09-28', N'BPA TO test - partial customer payment', 100.00, 1.0,
     N'4044',                            -- 10079 Metka Egn Italy S.R.L.
     N'45',                              -- Italy 2 (Ellomay Solar Italy Two SRL)
     N'122',                             -- Undeposited Funds
     N'119',                             -- 121000001 ACCOUNTS RECEIVABLES : Accounts Receivable
     N'4');                              -- EUR

INSERT INTO dbo.tb_Netsuite_CustomerPayment_Apply
    (BPA_EntryID, BPA_ParentID, BPA_Origin, BPA_Direction, BPA_Status, BPA_Action, BPA_Reference, BPA_Syscreator,
     doc_id, apply, amount)
VALUES
    (NEWID(), @cp, N'TEST', N'TO', 0, N'I', N'BPA-TEST-CP-0003', N'BPA-TEST',
     N'17544', 1, 100.00);   -- INVIT250020, 2,680.11 open

-- Check
SELECT p.BPA_EntryID, p.externalId, p.customer_id, p.subsidiary_id, p.account_id, p.arAcct_id, p.currency_id,
       p.payment, a.doc_id, a.amount, p.BPA_Status, p.BPA_ReturnedID, p.BPA_Error
FROM dbo.tb_Netsuite_CustomerPayment p
JOIN dbo.tb_Netsuite_CustomerPayment_Apply a ON a.BPA_ParentID = p.BPA_EntryID
WHERE p.externalId = N'BPA-TEST-CP-0003';

/* Cleanup
DELETE a FROM dbo.tb_Netsuite_CustomerPayment_Apply a
JOIN dbo.tb_Netsuite_CustomerPayment p ON p.BPA_EntryID = a.BPA_ParentID
WHERE p.externalId = N'BPA-TEST-CP-0003';
DELETE FROM dbo.tb_Netsuite_CustomerPayment WHERE externalId = N'BPA-TEST-CP-0003';
*/
