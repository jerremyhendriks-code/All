USE [BPAStaging]
GO
/****** Object:  StoredProcedure [dbo].[usp_Upsert_Companies_From_Netsuite]    Script Date: 22/10/2026 11:14:16 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER   PROCEDURE [dbo].[usp_Upsert_Companies_From_Netsuite]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @updated int, @inserted int;

    -- Latest staging row per subsidiary
    -- BPA_Company = subsidiary id (as in tb_Bank_Transactions / vw_Bank_BankAccounts), the name goes in the description
    SELECT s.id, CAST(s.id AS nvarchar(50)) AS company, s.full_name, s.lastModifiedDate
    INTO   #src
    FROM  (SELECT *, ROW_NUMBER() OVER (PARTITION BY id
                                        ORDER BY BPA_Syscreated DESC, BPA_EntryID DESC) AS rn
           FROM dbo.tb_Netsuite_Subsidiary) s
    WHERE  s.rn = 1
    and is_inactive = 0;
    BEGIN TRANSACTION;

    -- 1. Update existing companies that changed
    UPDATE c
    SET    c.BPA_Company             = s.company,
           c.BPA_Company_Description = s.full_name,
           c.last_Modified           = s.lastModifiedDate,
           c.BPA_Sysmodified         = GETDATE(),
           c.BPA_Status = 0
    FROM   dbo.tb_Companies c
    JOIN   #src s ON s.id = c.subsidiary_ID
    WHERE  EXISTS (SELECT s.company, s.full_name, s.lastModifiedDate
                   EXCEPT
                   SELECT c.BPA_Company, c.BPA_Company_Description, c.last_Modified);

    SET @updated = @@ROWCOUNT;

    -- 2. Insert new companies
    INSERT INTO dbo.tb_Companies (BPA_Origin, BPA_Company, BPA_Company_Description, subsidiary_ID, last_Modified,BPA_Status)
    SELECT N'Netsuite', s.company, s.full_name, s.id, s.lastModifiedDate,0
    FROM   #src s
    WHERE  NOT EXISTS (SELECT 1 FROM dbo.tb_Companies c WHERE c.subsidiary_ID = s.id);

    SET @inserted = @@ROWCOUNT;

    COMMIT TRANSACTION;

    SELECT @inserted AS inserted_rows, @updated AS updated_rows;
END
GO
