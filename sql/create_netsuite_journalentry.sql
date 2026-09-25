/*
    Create the tables for the BPA "journalEntry" Search output:
    - dbo.tb_Netsuite_JournalEntry       one row per journal (header fields)
    - dbo.tb_Netsuite_JournalEntry_Line  one row per journal line (line/items), linked to its header
      through BPA_ParentID = tb_Netsuite_JournalEntry.BPA_EntryID; journalEntry_id also holds the
      NetSuite id of the journal.

    Same conventions as create_netsuite_customerpayment.sql: standard BPA_* control block,
    clustered primary key on BPA_EntryID, non-unique index on the NetSuite id, referenced
    records flattened to <prefix>_<field>.

    Each table is created only if it doesn't exist yet.
*/
SET NOCOUNT ON;

IF OBJECT_ID(N'dbo.tb_Netsuite_JournalEntry', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.[tb_Netsuite_JournalEntry] (
        -- BPA control fields (standard block, same as the other tb_Netsuite_* tables)
        [BPA_Origin]                                       nvarchar(50)          NULL,
        [BPA_Direction]                                    nvarchar(50)          NULL,
        [BPA_Company]                                      nvarchar(50)          NULL,
        [BPA_EntryID]                                      uniqueidentifier      NOT NULL CONSTRAINT [DF_tb_Netsuite_JournalEntry_EntryID] DEFAULT (newsequentialid()),
        [BPA_ParentID]                                     uniqueidentifier      NULL,
        [BPA_Status]                                       int                   NULL CONSTRAINT [DF_tb_Netsuite_JournalEntry_Status] DEFAULT ((0)),
        [BPA_Reference]                                    nvarchar(50)          NULL,
        [BPA_Reference_Description]                        nvarchar(100)         NULL,
        [BPA_Reference2]                                   nvarchar(50)          NULL,
        [BPA_Reference2_Description]                       nvarchar(100)         NULL,
        [BPA_Action]                                       nvarchar(1)           NULL,
        [BPA_ReturnedID]                                   nvarchar(50)          NULL,
        [BPA_Syscreated]                                   datetime              NULL CONSTRAINT [DF_tb_Netsuite_JournalEntry_Syscreated] DEFAULT (getdate()),
        [BPA_Sysmodified]                                  datetime              NULL CONSTRAINT [DF_tb_Netsuite_JournalEntry_Sysmodified] DEFAULT (getdate()),
        [BPA_Syscreator]                                   nvarchar(50)          NULL,
        [BPA_Error]                                        nvarchar(max)         NULL,
        [BPA_Error_Extended]                               nvarchar(max)         NULL,
        [BPA_Description]                                  nvarchar(255)         NULL,
        [BPA_Failcount]                                    int                   NULL CONSTRAINT [DF_tb_Netsuite_JournalEntry_Failcount] DEFAULT ((0)),
        [BPA_Orig_Entryid]                                 uniqueidentifier      NULL,
        [BPA_TaskInstanceID]                               int                   NULL,
        [BPA_TaskID]                                       int                   NULL,

        -- Standard fields
        [id]                                               nvarchar(100),
        [tranId]                                           nvarchar(100),
        [externalId]                                       nvarchar(100),
        [refName]                                          nvarchar(400),
        [tranDate]                                         date,
        [createdDate]                                      datetimeoffset(0),
        [lastModifiedDate]                                 datetimeoffset(0),
        [memo]                                             nvarchar(4000),
        [exchangeRate]                                     decimal(28,10),
        [approved]                                         bit,
        [isReversal]                                       bit,
        [reversalDate]                                     date,
        [reversalDefer]                                    bit,
        [void]                                             bit,

        -- Referenced records (flattened: <object>/<field> -> <prefix>_<field>)
        [approvalStatus_id]                                nvarchar(100),        -- approvalStatus/id
        [approvalStatus_refName]                           nvarchar(400),        -- approvalStatus/refName
        [subsidiary_id]                                    nvarchar(100),        -- subsidiary/id
        [subsidiary_refName]                               nvarchar(400),        -- subsidiary/refName
        [currency_id]                                      nvarchar(100),        -- currency/id
        [currency_name]                                    nvarchar(400),        -- currency/name
        [postingPeriod_id]                                 nvarchar(100),        -- postingPeriod/id
        [postingPeriod_refName]                            nvarchar(400),        -- postingPeriod/refName
        [line_totalResults]                                int,                  -- line/totalResults

        CONSTRAINT [PK_tb_Netsuite_JournalEntry] PRIMARY KEY CLUSTERED ([BPA_EntryID])
    );

    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_JournalEntry_id] ON dbo.[tb_Netsuite_JournalEntry] ([id]);
    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_JournalEntry_BPA_Status]
        ON dbo.[tb_Netsuite_JournalEntry] ([BPA_Status], [BPA_Direction]) INCLUDE ([id], [BPA_Company]);
    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_JournalEntry_tranDate] ON dbo.[tb_Netsuite_JournalEntry] ([tranDate]) INCLUDE ([tranId]);
    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_JournalEntry_lastModifiedDate] ON dbo.[tb_Netsuite_JournalEntry] ([lastModifiedDate]);

    PRINT N'Created dbo.[tb_Netsuite_JournalEntry]';
END
ELSE
    PRINT N'Skipped dbo.[tb_Netsuite_JournalEntry] (table already exists)';

IF OBJECT_ID(N'dbo.tb_Netsuite_JournalEntry_Line', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.[tb_Netsuite_JournalEntry_Line] (
        -- BPA control fields (standard block, same as the other tb_Netsuite_* tables)
        [BPA_Origin]                                       nvarchar(50)          NULL,
        [BPA_Direction]                                    nvarchar(50)          NULL,
        [BPA_Company]                                      nvarchar(50)          NULL,
        [BPA_EntryID]                                      uniqueidentifier      NOT NULL CONSTRAINT [DF_tb_Netsuite_JournalEntry_Line_EntryID] DEFAULT (newsequentialid()),
        [BPA_ParentID]                                     uniqueidentifier      NULL,
        [BPA_Status]                                       int                   NULL CONSTRAINT [DF_tb_Netsuite_JournalEntry_Line_Status] DEFAULT ((0)),
        [BPA_Reference]                                    nvarchar(50)          NULL,
        [BPA_Reference_Description]                        nvarchar(100)         NULL,
        [BPA_Reference2]                                   nvarchar(50)          NULL,
        [BPA_Reference2_Description]                       nvarchar(100)         NULL,
        [BPA_Action]                                       nvarchar(1)           NULL,
        [BPA_ReturnedID]                                   nvarchar(50)          NULL,
        [BPA_Syscreated]                                   datetime              NULL CONSTRAINT [DF_tb_Netsuite_JournalEntry_Line_Syscreated] DEFAULT (getdate()),
        [BPA_Sysmodified]                                  datetime              NULL CONSTRAINT [DF_tb_Netsuite_JournalEntry_Line_Sysmodified] DEFAULT (getdate()),
        [BPA_Syscreator]                                   nvarchar(50)          NULL,
        [BPA_Error]                                        nvarchar(max)         NULL,
        [BPA_Error_Extended]                               nvarchar(max)         NULL,
        [BPA_Description]                                  nvarchar(255)         NULL,
        [BPA_Failcount]                                    int                   NULL CONSTRAINT [DF_tb_Netsuite_JournalEntry_Line_Failcount] DEFAULT ((0)),
        [BPA_Orig_Entryid]                                 uniqueidentifier      NULL,
        [BPA_TaskInstanceID]                               int                   NULL,
        [BPA_TaskID]                                       int                   NULL,

        -- Parent: BPA_ParentID = tb_Netsuite_JournalEntry.BPA_EntryID
        [journalEntry_id]                                  nvarchar(100),        -- journalEntry/id (the parent's NetSuite id)

        -- Line fields (line/items)
        [line]                                             int,                  -- line/items/line
        [debit]                                            decimal(19,4),        -- line/items/debit
        [credit]                                           decimal(19,4),        -- line/items/credit
        [memo]                                             nvarchar(4000),       -- line/items/memo
        [eliminate]                                        bit,                  -- line/items/eliminate
        [cleared]                                          bit,                  -- line/items/cleared

        -- Referenced records on the line
        [account_id]                                       nvarchar(100),        -- line/items/account/id
        [account_acctNumber]                               nvarchar(100),        -- line/items/account/acctNumber
        [account_refName]                                  nvarchar(400),        -- line/items/account/refName
        [entity_id]                                        nvarchar(100),        -- line/items/entity/id
        [entity_refName]                                   nvarchar(400),        -- line/items/entity/refName
        [department_id]                                    nvarchar(100),        -- line/items/department/id
        [department_refName]                               nvarchar(400),        -- line/items/department/refName
        [class_id]                                         nvarchar(100),        -- line/items/class/id
        [class_refName]                                    nvarchar(400),        -- line/items/class/refName
        [location_id]                                      nvarchar(100),        -- line/items/location/id
        [location_refName]                                 nvarchar(400),        -- line/items/location/refName

        CONSTRAINT [PK_tb_Netsuite_JournalEntry_Line] PRIMARY KEY CLUSTERED ([BPA_EntryID])
    );

    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_JournalEntry_Line_BPA_ParentID] ON dbo.[tb_Netsuite_JournalEntry_Line] ([BPA_ParentID]);
    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_JournalEntry_Line_journalEntry_id] ON dbo.[tb_Netsuite_JournalEntry_Line] ([journalEntry_id], [line]);
    CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_JournalEntry_Line_account_id] ON dbo.[tb_Netsuite_JournalEntry_Line] ([account_id]) INCLUDE ([debit], [credit], [entity_id]);

    PRINT N'Created dbo.[tb_Netsuite_JournalEntry_Line]';
END
ELSE
    PRINT N'Skipped dbo.[tb_Netsuite_JournalEntry_Line] (table already exists)';
