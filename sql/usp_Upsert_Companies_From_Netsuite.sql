/*
    Sync NetSuite subsidiaries from tb_Netsuite_Subsidiary into tb_Companies.
    Requires alter_tb_Companies_add_subsidiary_columns.sql (subsidiary_ID, last_Modified).

    - The staging table can hold the same subsidiary more than once (one row per load);
      only the most recently loaded row per [id] is used.
    - Updates companies whose subsidiary_ID already exists, only when something changed.
    - Inserts subsidiaries that aren't in tb_Companies yet.
    - Runs in a single transaction: any error rolls everything back.

    Column mapping:
        tb_Netsuite_Subsidiary   ->  tb_Companies
        ----------------------       ------------
        id                       ->  subsidiary_ID            (match key)
        name                     ->  BPA_Company              (truncated to 50)
        full_name                ->  BPA_Company_Description
        lastModifiedDate         ->  last_Modified
        'Netsuite'               ->  BPA_Origin
        GETDATE()                ->  BPA_Sysmodified          (on update)
    BPA_EntryID, BPA_Status, BPA_Syscreated and BPA_Sysmodified use their defaults on insert.
    BPA_Company_BPAConnection is not touched.
*/
USE [BPAStaging];
GO

CREATE OR ALTER PROCEDURE dbo.usp_Upsert_Companies_From_Netsuite
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @updated int, @inserted int;

    -- Latest staging row per subsidiary
    SELECT s.id,
           LEFT(s.name, 50) AS name,
           s.full_name,
           s.lastModifiedDate
    INTO   #src
    FROM  (SELECT *,
                  ROW_NUMBER() OVER (PARTITION BY id
                                     ORDER BY BPA_Syscreated DESC, BPA_EntryID DESC) AS rn
           FROM dbo.tb_Netsuite_Subsidiary) s
    WHERE  s.rn = 1;

    BEGIN TRANSACTION;

    -- 1. Update existing companies that changed
    UPDATE c
    SET    c.BPA_Company             = s.name,
           c.BPA_Company_Description = s.full_name,
           c.last_Modified           = s.lastModifiedDate,
           c.BPA_Sysmodified         = GETDATE()
    FROM   dbo.tb_Companies c
    JOIN   #src s ON s.id = c.subsidiary_ID
    WHERE  EXISTS (SELECT s.name, s.full_name, s.lastModifiedDate
                   EXCEPT
                   SELECT c.BPA_Company, c.BPA_Company_Description, c.last_Modified);  -- NULL-safe compare

    SET @updated = @@ROWCOUNT;

    -- 2. Insert new companies
    INSERT INTO dbo.tb_Companies (BPA_Origin, BPA_Company, BPA_Company_Description, subsidiary_ID, last_Modified)
    SELECT N'Netsuite', s.name, s.full_name, s.id, s.lastModifiedDate
    FROM   #src s
    WHERE  NOT EXISTS (SELECT 1 FROM dbo.tb_Companies c WHERE c.subsidiary_ID = s.id);

    SET @inserted = @@ROWCOUNT;

    COMMIT TRANSACTION;

    SELECT @inserted AS inserted_rows, @updated AS updated_rows;
END
GO
