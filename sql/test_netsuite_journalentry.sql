/*
    Build a test journalEntry payload for NetSuite from the reference data we
    already picked up from NetSuite (tb_Netsuite_Subsidiary, tb_Netsuite_Currency,
    tb_Netsuite_Account). Read-only: nothing is inserted or changed.

    1. Run step 1 to look up a subsidiary and two accounts.
    2. Put their ids in the variables in step 2. Use two accounts that are valid for
       that subsidiary and aren't AR/AP (those need an entity on the line).
    3. Run step 2. It checks the ids exist, then returns the JSON body for
       POST /services/rest/record/v1/journalEntry (one debit line, one credit
       line, same amount).

    Re-sending the same @externalId updates that entry in NetSuite instead of
    creating a second one, so change it for each new test entry.
*/
SET NOCOUNT ON;

-- Step 1: pick ids
SELECT TOP (50) * FROM dbo.tb_Netsuite_Subsidiary;
SELECT TOP (50) * FROM dbo.tb_Netsuite_Currency;
SELECT TOP (200) * FROM dbo.tb_Netsuite_Account;

-- Step 2: build the payload
DECLARE @externalId    nvarchar(100)  = N'TEST-JE-0001',
        @subsidiary    nvarchar(100)  = N'<subsidiary id>',
        @currency      nvarchar(100)  = NULL,  -- NULL = subsidiary base currency
        @tranDate      date           = CAST(GETDATE() AS date),
        @debitAccount  nvarchar(100)  = N'<account id>',
        @creditAccount nvarchar(100)  = N'<account id>',
        @amount        decimal(18, 2) = 1.00;

DECLARE @msg nvarchar(2048);

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
IF @amount IS NULL OR @amount <= 0
    THROW 50001, N'@amount must be greater than 0.', 1;

-- NULL fields are left out of the JSON, as NetSuite expects
SELECT @externalId                                                        AS externalId,
       JSON_QUERY(N'{"id":"' + STRING_ESCAPE(@subsidiary, 'json') + N'"}') AS subsidiary,
       @tranDate                                                          AS tranDate,
       JSON_QUERY(CASE WHEN @currency IS NOT NULL
                       THEN N'{"id":"' + STRING_ESCAPE(@currency, 'json') + N'"}' END) AS currency,
       N'Integration test ' + @externalId                                 AS memo,
       JSON_QUERY((
           SELECT JSON_QUERY(N'{"id":"' + STRING_ESCAPE(l.account, 'json') + N'"}') AS account,
                  l.debit,
                  l.credit,
                  l.memo
           FROM (VALUES (1, @debitAccount,  @amount, CAST(NULL AS decimal(18, 2)), N'Integration test debit'),
                        (2, @creditAccount, NULL,    @amount,                      N'Integration test credit')
                ) AS l (lineNumber, account, debit, credit, memo)
           ORDER BY l.lineNumber
           FOR JSON PATH))                                                AS [line.items]
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
