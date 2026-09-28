-- Test vendor payment for the TO task: GGG pays 1,000.00 of bill 77777777 (id 37393)
DECLARE @vp uniqueidentifier = NEWID();

INSERT INTO dbo.tb_Netsuite_VendorPayment
    (BPA_EntryID, BPA_Origin, BPA_Direction, BPA_Status, BPA_Action, BPA_Reference, BPA_Syscreator,
     id, externalId, tranDate, memo, exchangeRate, toBePrinted, toBeEmailed,
     entityId, subsidiaryId, accountId, apAcctId, currencyId)
VALUES
    (@vp, N'TEST', N'TO', 0, N'I', N'BPA-TEST-VP-0003', N'BPA-TEST',
     N'', N'BPA-TEST-VP-0003', N'2026-09-28', N'BPA TO test - GGG partial payment', N'1.0', 0, 0,
     N'5733', N'89',
     N'3427',  -- bank: Rabobank 0103 2754 60 GGG Euro (111001601)
     N'111',   -- AP: 200000001 ACCOUNTS PAYABLE : Trade payables
     N'4');

INSERT INTO dbo.tb_Netsuite_VendorPayment_Apply
    (BPA_EntryID, BPA_ParentID, BPA_Origin, BPA_Direction, BPA_Status, BPA_Action, BPA_Reference, BPA_Syscreator,
     doc_id, apply, amount)
VALUES
    (NEWID(), @vp, N'TEST', N'TO', 0, N'I', N'BPA-TEST-VP-0003', N'BPA-TEST',
     N'37393', 1, 1000.00);

-- Check
SELECT p.BPA_EntryID, p.externalId, p.entityId, p.subsidiaryId, p.accountId, p.apAcctId, p.currencyId,
       a.doc_id, a.amount, p.BPA_Status, p.BPA_ReturnedID, p.BPA_Error
FROM dbo.tb_Netsuite_VendorPayment p
JOIN dbo.tb_Netsuite_VendorPayment_Apply a ON a.BPA_ParentID = p.BPA_EntryID
WHERE p.externalId = N'BPA-TEST-VP-0003';
