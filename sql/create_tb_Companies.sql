/*
    Create tb_Companies, including the NetSuite link columns used by
    usp_Upsert_Companies_From_Netsuite:
    - subsidiary_ID  NetSuite subsidiary id (nvarchar(100), like the widened tb_Netsuite_Subsidiary.[id]).
    - last_Modified  NetSuite lastModifiedDate, stored as delivered.
    Constraint names match the original table.
*/
USE [BPAStaging]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [dbo].[tb_Companies](
	[BPA_EntryID] [uniqueidentifier] NOT NULL,
	[BPA_Origin] [nvarchar](50) NULL,
	[BPA_Status] [int] NULL,
	[BPA_Company] [nvarchar](50) NULL,
	[BPA_Company_BPAConnection] [nvarchar](100) NULL,
	[BPA_Company_Description] [nvarchar](255) NULL,
	[BPA_Syscreated] [datetime] NULL,
	[BPA_Sysmodified] [datetime] NULL,
	[subsidiary_ID] [nvarchar](100) NULL,
	[last_Modified] [nvarchar](50) NULL,
 CONSTRAINT [PK_Table_BPA_EntryID] PRIMARY KEY CLUSTERED
(
	[BPA_EntryID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [dbo].[tb_Companies] ADD  CONSTRAINT [DF_tb_Companies_BPA_EntryID]  DEFAULT (newsequentialid()) FOR [BPA_EntryID]
GO

ALTER TABLE [dbo].[tb_Companies] ADD  CONSTRAINT [DF_tb_Companies_BPA_Status]  DEFAULT ((0)) FOR [BPA_Status]
GO

ALTER TABLE [dbo].[tb_Companies] ADD  CONSTRAINT [DF_tb_Companies_BPA_Syscreated]  DEFAULT (getdate()) FOR [BPA_Syscreated]
GO

ALTER TABLE [dbo].[tb_Companies] ADD  CONSTRAINT [DF_tb_Companies_BPA_Sysmodified]  DEFAULT (getdate()) FOR [BPA_Sysmodified]
GO

-- A subsidiary can only be linked to one company
CREATE UNIQUE NONCLUSTERED INDEX [UX_tb_Companies_subsidiary_ID] ON [dbo].[tb_Companies]
(
	[subsidiary_ID] ASC
)
WHERE [subsidiary_ID] IS NOT NULL
ON [PRIMARY]
GO
