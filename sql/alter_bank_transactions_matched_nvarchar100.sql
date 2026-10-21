/*
    Widen the Matched_* columns of tb_Bank_Transactions for NetSuite.

    The columns were sized for Exact (char(6) relation numbers, char(9) GL codes). For NetSuite
    they hold internal ids (vendor, customer, account, department, class, tax code) and document
    numbers, so they become nvarchar(100), the same size as the ids in the NetSuite tables.

        Matched_GLCode      char(9)       -> nvarchar(100)   NetSuite account id
        Matched_Creditor    nvarchar(6)   -> nvarchar(100)   NetSuite vendor id
        Matched_Debtor      nvarchar(6)   -> nvarchar(100)   NetSuite customer id
        Matched_Costcenter  varchar(10)   -> nvarchar(100)   NetSuite class / department id
        Matched_CostUnit    nvarchar(10)  -> nvarchar(100)   NetSuite department / class id
        Matched_Reference   nvarchar(20)  -> nvarchar(100)   bill / invoice number
        Matched_VatCode     nvarchar(10)  -> nvarchar(100)   NetSuite tax code id

    Unchanged: Matched_typematch nvarchar(50), Matched_ReferenceXML xml, Matched_NewCustomer int,
    Matched_WorkflowID uniqueidentifier.

    Stops without changes if an index or statistic uses one of these columns (ALTER COLUMN would fail).
    Runs in one transaction. Also trims the trailing spaces char(9) left in Matched_GLCode.
*/
USE [BPAStaging]
GO
SET XACT_ABORT ON;
SET NOCOUNT ON;

DECLARE @cols TABLE (name sysname PRIMARY KEY);
INSERT INTO @cols (name) VALUES
    (N'Matched_GLCode'), (N'Matched_Creditor'), (N'Matched_Debtor'),
    (N'Matched_Costcenter'), (N'Matched_CostUnit'), (N'Matched_Reference'), (N'Matched_VatCode');

DECLARE @blocking nvarchar(max) =
(
    SELECT STRING_AGG(CAST(x.what AS nvarchar(max)), N', ')
    FROM
    (
        SELECT N'index ' + i.name + N' (' + c.name + N')' AS what
        FROM sys.index_columns ic
        JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
        JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        WHERE ic.object_id = OBJECT_ID(N'dbo.tb_Bank_Transactions')
          AND c.name IN (SELECT name FROM @cols)
        UNION
        SELECT N'statistic ' + s.name + N' (' + c.name + N')'
        FROM sys.stats_columns sc
        JOIN sys.stats s   ON s.object_id = sc.object_id AND s.stats_id = sc.stats_id
        JOIN sys.columns c ON c.object_id = sc.object_id AND c.column_id = sc.column_id
        WHERE sc.object_id = OBJECT_ID(N'dbo.tb_Bank_Transactions')
          AND c.name IN (SELECT name FROM @cols)
          AND s.user_created = 1
    ) x
);

IF @blocking IS NOT NULL
BEGIN
    DECLARE @msg nvarchar(2048) = N'Drop these first, then run again: ' + @blocking;
    THROW 50001, @msg, 1;
END

BEGIN TRANSACTION;

ALTER TABLE dbo.tb_Bank_Transactions ALTER COLUMN Matched_GLCode     nvarchar(100) NULL;
ALTER TABLE dbo.tb_Bank_Transactions ALTER COLUMN Matched_Creditor   nvarchar(100) NULL;
ALTER TABLE dbo.tb_Bank_Transactions ALTER COLUMN Matched_Debtor     nvarchar(100) NULL;
ALTER TABLE dbo.tb_Bank_Transactions ALTER COLUMN Matched_Costcenter nvarchar(100) NULL;
ALTER TABLE dbo.tb_Bank_Transactions ALTER COLUMN Matched_CostUnit   nvarchar(100) NULL;
ALTER TABLE dbo.tb_Bank_Transactions ALTER COLUMN Matched_Reference  nvarchar(100) NULL;
ALTER TABLE dbo.tb_Bank_Transactions ALTER COLUMN Matched_VatCode    nvarchar(100) NULL;

COMMIT TRANSACTION;
GO

-- char(9) padded the GL codes with spaces; nvarchar keeps them, so trim once
UPDATE dbo.tb_Bank_Transactions
SET Matched_GLCode = NULLIF(RTRIM(Matched_GLCode), N'')
WHERE Matched_GLCode IS NOT NULL
  AND Matched_GLCode <> RTRIM(Matched_GLCode);
GO

-- Check
SELECT c.name AS column_name, t.name AS data_type, c.max_length / 2 AS max_chars, c.is_nullable
FROM sys.columns c
JOIN sys.types t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID(N'dbo.tb_Bank_Transactions')
  AND c.name LIKE N'Matched[_]%'
ORDER BY c.column_id;
GO
