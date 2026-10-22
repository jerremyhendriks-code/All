/*
    Test: one journal entry through the whole bank chain, booked by workflow rule 1
    (GGG, NL76RABO0103275460, money out, description "Kosten" -> 600002015 Other Management fees, NetSuite id 3301).

        tb_Rabobank_Transaction --sp_Bank_Transaction_Rabobank_Copy--> tb_Bank_Transactions
            --sp_Bank_Netsuite_FinancialEntry_Create_V2 (fn_Bank_Match_V2: typematch MATCH)--> tb_Netsuite_JournalEntry
            --BPA TO task--> NetSuite

    The other party is our own account (like Rabobank's own costs), so no relation is found by IBAN and
    only the rule decides. Every run a new entryReference (BPATEST-JE-<run>), so it can be run again.
*/
USE [BPAStaging]
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

-- ===== Fill in =====
DECLARE @OwnIBAN    varchar(34)    = 'NL76RABO0103275460';	-- GGG (89), the account of workflow rule 1
DECLARE @TestAmount decimal(18, 2) = 0.05;					-- money out
-- ===================

DECLARE @run varchar(14) = FORMAT(GETDATE(), 'yyyyMMddHHmmss');
DECLARE @Description nvarchar(255) = N'Kosten BPA test';

INSERT INTO tb_Rabobank_Transaction
(
    BPA_Origin, BPA_Direction, BPA_Status, BPA_Syscreator,
    entryReference, bookingDate, valueDate, raboBookingDateTime,
    transactionAmount_value, transactionAmount_currency,
    debtorAccount_iban, debtorName, creditorAccount_iban, creditorName,
    remittanceInformationUnstructured
)
VALUES
    (@OwnIBAN, 'FROMUPDATE', 0, N'BPA-TEST',
     'BPATEST-JE-' + @run, CAST(GETDATE() AS date), CAST(GETDATE() AS date), GETUTCDATE(),
     -@TestAmount, 'EUR',
     @OwnIBAN, N'Ellomay', @OwnIBAN, N'Rabobank',
     @Description);

-- Rabobank -> tb_Bank_Transactions
EXEC sp_Bank_Transaction_Rabobank_Copy @OwnIBAN;

-- What fn_Bank_Match_V2 makes of it: expected typematch MATCH, GLCode 3301, WorkflowNumber 1
SELECT CASE WHEN m.typematch = 'MATCH' THEN 'PASS' ELSE 'FAIL' END AS Result,
       t.BPA_EntryID, t.BPA_Company, t.BPA_Reference, t.Amount, t.IBAN, t.Description,
       m.typematch, m.GLCode, m.vendor_id, m.customer_id, m.WorkflowNumber, m.WorkflowID,
       'EXEC sp_Bank_Netsuite_FinancialEntry_Create_V2 ''' + t.BPA_Company + ''', @BPA_EntryID = '''
       + CAST(t.BPA_EntryID AS varchar(36)) + ''', @Synchronise = 0, @Preview = 1;' AS engine_preview
FROM tb_Bank_Transactions t
OUTER APPLY dbo.fn_Bank_Match_V2('BANK', t.BPA_EntryID, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) m
WHERE t.BPA_Origin = @OwnIBAN AND t.BPA_Reference = 'BPATEST-JE-' + @run;
GO

/*
-- ---------- Cleanup: unsent test journal entries ----------
BEGIN TRANSACTION;
DELETE l FROM tb_Netsuite_JournalEntry_Line l
    JOIN tb_Netsuite_JournalEntry h ON h.BPA_EntryID = l.BPA_ParentID
    WHERE h.externalId LIKE 'BANK-%-BPATEST-JE-%' AND h.BPA_Status = 0;
DELETE FROM tb_Netsuite_JournalEntry WHERE externalId LIKE 'BANK-%-BPATEST-JE-%' AND BPA_Status = 0;
DELETE FROM tb_Bank_Transactions    WHERE BPA_Reference LIKE 'BPATEST-JE-%' AND BPA_Status = 0;
DELETE FROM tb_Rabobank_Transaction WHERE entryReference LIKE 'BPATEST-JE-%'
    AND NOT EXISTS (SELECT 1 FROM tb_Bank_Transactions t WHERE t.BPA_Reference = tb_Rabobank_Transaction.entryReference);
COMMIT TRANSACTION;
*/
