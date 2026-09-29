/*
    Insert one balanced test journal entry for the journalEntry TO task, then show
    the JSON payload it should produce for NetSuite.

    Run create_netsuite_journalentry_tables.sql first.

    Before running, set the variables below to real NetSuite internal ids from
    Ellomay's environment: a subsidiary, and two accounts that are valid for that
    subsidiary and don't require an entity (so not AR/AP accounts).

    Re-runnable: replaces the test entry as long as it hasn't been sent yet
    ([id] still NULL). After a successful send it stops with an error, so a new
    run can't silently overwrite an entry that exists in NetSuite; change
    @externalId to make another one.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

DECLARE @externalId    nvarchar(100) = N'TEST-JE-0001',
        @subsidiary    nvarchar(100) = N'<subsidiary id>',
        @currency      nvarchar(100) = NULL,  -- NULL = subsidiary base currency
        @tranDate      date          = CAST(GETDATE() AS date),
        @debitAccount  nvarchar(100) = N'<account id>',
        @creditAccount nvarchar(100) = N'<account id>',
        @amount        decimal(18, 2) = 1.00;

DECLARE @msg nvarchar(2048);

-- Check the ids exist in the reference tables before writing anything
IF NOT EXISTS (SELECT 1 FROM dbo.tb_Netsuite_Subsidiary WHERE id = @subsidiary)
BEGIN
    SET @msg = N'Subsidiary ' + @subsidiary + N' not found in tb_Netsuite_Subsidiary.';
    THROW 50001, @msg, 1;
END
IF @currency IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.tb_Netsuite_Currency WHERE id = @currency)
BEGIN
    SET @msg = N'Currency ' + @currency + N' not found in tb_Netsuite_Currency.';
    THROW 50001, @msg, 1;
END
IF NOT EXISTS (SELECT 1 FROM dbo.tb_Netsuite_Account WHERE id = @debitAccount)
BEGIN
    SET @msg = N'Debit account ' + @debitAccount + N' not found in tb_Netsuite_Account.';
    THROW 50001, @msg, 1;
END
IF NOT EXISTS (SELECT 1 FROM dbo.tb_Netsuite_Account WHERE id = @creditAccount)
BEGIN
    SET @msg = N'Credit account ' + @creditAccount + N' not found in tb_Netsuite_Account.';
    THROW 50001, @msg, 1;
END
IF @debitAccount = @creditAccount
    THROW 50001, N'Use two different accounts for the debit and credit line.', 1;
IF EXISTS (SELECT 1 FROM dbo.tb_Netsuite_JournalEntry WHERE externalId = @externalId AND id IS NOT NULL)
BEGIN
    SET @msg = N'Journal entry ' + @externalId + N' was already sent to NetSuite; change @externalId.';
    THROW 50001, @msg, 1;
END

BEGIN TRANSACTION;

DELETE FROM dbo.tb_Netsuite_JournalEntry WHERE externalId = @externalId;  -- lines cascade

INSERT INTO dbo.tb_Netsuite_JournalEntry (externalId, subsidiary, tranDate, currency, memo)
VALUES (@externalId, @subsidiary, @tranDate, @currency, N'Integration test ' + @externalId);

INSERT INTO dbo.tb_Netsuite_JournalEntryLine (externalId, lineNumber, account, debit, credit, memo)
VALUES (@externalId, 1, @debitAccount,  @amount, NULL,    N'Integration test debit'),
       (@externalId, 2, @creditAccount, NULL,    @amount, N'Integration test credit');

COMMIT TRANSACTION;

-- Balance check: difference must be 0.00
SELECT externalId,
       COUNT(*)                                 AS lines,
       SUM(ISNULL(debit, 0))                    AS total_debit,
       SUM(ISNULL(credit, 0))                   AS total_credit,
       SUM(ISNULL(debit, 0) - ISNULL(credit, 0)) AS difference
FROM dbo.tb_Netsuite_JournalEntryLine
WHERE externalId = @externalId
GROUP BY externalId;

-- Payload preview for POST /services/rest/record/v1/journalEntry
-- (NULL fields are left out, as NetSuite expects)
SELECT h.externalId,
       JSON_QUERY(N'{"id":"' + STRING_ESCAPE(h.subsidiary, 'json') + N'"}') AS subsidiary,
       h.tranDate,
       JSON_QUERY(CASE WHEN h.currency IS NOT NULL
                       THEN N'{"id":"' + STRING_ESCAPE(h.currency, 'json') + N'"}' END) AS currency,
       h.memo,
       JSON_QUERY((
           SELECT JSON_QUERY(N'{"id":"' + STRING_ESCAPE(l.account, 'json') + N'"}') AS account,
                  l.debit,
                  l.credit,
                  JSON_QUERY(CASE WHEN l.entity IS NOT NULL
                                  THEN N'{"id":"' + STRING_ESCAPE(l.entity, 'json') + N'"}' END) AS entity,
                  JSON_QUERY(CASE WHEN l.department IS NOT NULL
                                  THEN N'{"id":"' + STRING_ESCAPE(l.department, 'json') + N'"}' END) AS department,
                  JSON_QUERY(CASE WHEN l.[class] IS NOT NULL
                                  THEN N'{"id":"' + STRING_ESCAPE(l.[class], 'json') + N'"}' END) AS [class],
                  JSON_QUERY(CASE WHEN l.location IS NOT NULL
                                  THEN N'{"id":"' + STRING_ESCAPE(l.location, 'json') + N'"}' END) AS location,
                  l.memo
           FROM dbo.tb_Netsuite_JournalEntryLine l
           WHERE l.externalId = h.externalId
           ORDER BY l.lineNumber
           FOR JSON PATH)) AS [line.items]
FROM dbo.tb_Netsuite_JournalEntry h
WHERE h.externalId = @externalId
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
