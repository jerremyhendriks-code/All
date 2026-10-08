/*
    Add the NetSuite link columns to tb_Companies:
    - subsidiary_ID  NetSuite subsidiary id (match key for usp_Upsert_Companies_From_Netsuite).
                     nvarchar(100) to match the widened tb_Netsuite_Subsidiary.[id].
    - last_Modified  NetSuite lastModifiedDate, stored as delivered (nvarchar, like the staging table).
    Plus a filtered unique index so a subsidiary can only be linked to one company.

    Safe to run more than once.
*/
USE [BPAStaging];
GO

IF COL_LENGTH(N'dbo.tb_Companies', N'subsidiary_ID') IS NULL
    ALTER TABLE dbo.tb_Companies ADD subsidiary_ID nvarchar(100) NULL;
GO

IF COL_LENGTH(N'dbo.tb_Companies', N'last_Modified') IS NULL
    ALTER TABLE dbo.tb_Companies ADD last_Modified nvarchar(50) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID(N'dbo.tb_Companies') AND name = N'UX_tb_Companies_subsidiary_ID')
    CREATE UNIQUE NONCLUSTERED INDEX UX_tb_Companies_subsidiary_ID
        ON dbo.tb_Companies (subsidiary_ID)
        WHERE subsidiary_ID IS NOT NULL;
GO
