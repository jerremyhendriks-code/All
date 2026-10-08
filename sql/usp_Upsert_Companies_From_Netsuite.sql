/*
    Sync NetSuite subsidiaries from the staging table into tb_companies.

    - Updates companies whose NetSuite id already exists in tb_companies
      (only rows where at least one value actually changed).
    - Inserts subsidiaries whose NetSuite id is not in tb_companies yet.
    - Runs in a single transaction: any error rolls everything back.

    Column mapping (adjust to your actual column names):
        tb_Netsuite_Subsidiaries   ->  tb_companies
        ------------------------       ------------
        id                         ->  NetsuiteId      (match key)
        name                       ->  CompanyName
        legalname                  ->  LegalName
        country                    ->  Country
        currency                   ->  Currency
        isinactive ('T'/'F')       ->  IsActive        (bit, inverted)
                                       CreatedAt / ModifiedAt are set here
*/
CREATE OR ALTER PROCEDURE dbo.usp_Upsert_Companies_From_Netsuite
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @now datetime2(0) = SYSDATETIME();

    BEGIN TRANSACTION;

    -- 1. Update existing companies that changed
    UPDATE c
    SET    c.CompanyName = s.name,
           c.LegalName   = s.legalname,
           c.Country     = s.country,
           c.Currency    = s.currency,
           c.IsActive    = CASE WHEN s.isinactive = 'T' THEN 0 ELSE 1 END,
           c.ModifiedAt  = @now
    FROM   dbo.tb_companies c
    JOIN   dbo.tb_Netsuite_Subsidiaries s ON s.id = c.NetsuiteId
    WHERE  EXISTS (SELECT s.name, s.legalname, s.country, s.currency,
                          CASE WHEN s.isinactive = 'T' THEN 0 ELSE 1 END
                   EXCEPT
                   SELECT c.CompanyName, c.LegalName, c.Country, c.Currency, c.IsActive);  -- NULL-safe compare

    DECLARE @updated int = @@ROWCOUNT;

    -- 2. Insert new companies
    INSERT INTO dbo.tb_companies (NetsuiteId, CompanyName, LegalName, Country, Currency, IsActive, CreatedAt, ModifiedAt)
    SELECT s.id, s.name, s.legalname, s.country, s.currency,
           CASE WHEN s.isinactive = 'T' THEN 0 ELSE 1 END,
           @now, @now
    FROM   dbo.tb_Netsuite_Subsidiaries s
    WHERE  NOT EXISTS (SELECT 1 FROM dbo.tb_companies c WHERE c.NetsuiteId = s.id);

    DECLARE @inserted int = @@ROWCOUNT;

    COMMIT TRANSACTION;

    SELECT @inserted AS inserted_rows, @updated AS updated_rows;
END
GO
