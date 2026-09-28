/*
    Create dbo.tb_Netsuite_Bank_account_details for the BPA
    "customrecord_2663_entity_bank_details" Search output (Electronic Bank Payments
    entity bank details), picked up by the NetSuite reference data FROM task.

    Column mapping from the BPA schema:
    - Fields keep their NetSuite name. Types follow tc:OriginalType:
      boolean -> bit, integer -> int, string -> nvarchar.
    - [created] / [lastmodified] are standard record timestamps and get
      datetimeoffset(0), like createdDate / lastModifiedDate on the other tables.
      The custom (custrecord_2663_*) date fields stay nvarchar because the schema
      types them as string.
    - SupplementaryReference (a BPA-internal property) is not stored.

    BPA control fields: the standard BPA_* block with the usual defaults. Each row is a
    BPA entry, so the clustered primary key is BPA_EntryID (newsequentialid) and [id]
    (the NetSuite internal id) gets a non-unique index.

    Does nothing if the table already exists.
*/
SET NOCOUNT ON;

IF OBJECT_ID(N'dbo.tb_Netsuite_Bank_account_details', N'U') IS NOT NULL
BEGIN
    PRINT N'Skipped dbo.[tb_Netsuite_Bank_account_details] (table already exists)';
    RETURN;
END

CREATE TABLE dbo.[tb_Netsuite_Bank_account_details] (
    -- BPA control fields (standard block, same as the other tb_Netsuite_* tables)
    [BPA_Origin]                                       nvarchar(50)          NULL,
    [BPA_Direction]                                    nvarchar(50)          NULL,
    [BPA_Company]                                      nvarchar(50)          NULL,
    [BPA_EntryID]                                      uniqueidentifier      NOT NULL CONSTRAINT [DF_tb_Netsuite_Bank_account_details_EntryID] DEFAULT (newsequentialid()),
    [BPA_ParentID]                                     uniqueidentifier      NULL,
    [BPA_Status]                                       int                   NULL CONSTRAINT [DF_tb_Netsuite_Bank_account_details_Status] DEFAULT ((0)),
    [BPA_Reference]                                    nvarchar(50)          NULL,
    [BPA_Reference_Description]                        nvarchar(100)         NULL,
    [BPA_Reference2]                                   nvarchar(50)          NULL,
    [BPA_Reference2_Description]                       nvarchar(100)         NULL,
    [BPA_Action]                                       nvarchar(1)           NULL,
    [BPA_ReturnedID]                                   nvarchar(50)          NULL,
    [BPA_Syscreated]                                   datetime              NULL CONSTRAINT [DF_tb_Netsuite_Bank_account_details_Syscreated] DEFAULT (getdate()),
    [BPA_Sysmodified]                                  datetime              NULL CONSTRAINT [DF_tb_Netsuite_Bank_account_details_Sysmodified] DEFAULT (getdate()),
    [BPA_Syscreator]                                   nvarchar(50)          NULL,
    [BPA_Error]                                        nvarchar(max)         NULL,
    [BPA_Error_Extended]                               nvarchar(max)         NULL,
    [BPA_Description]                                  nvarchar(255)         NULL,
    [BPA_Failcount]                                    int                   NULL CONSTRAINT [DF_tb_Netsuite_Bank_account_details_Failcount] DEFAULT ((0)),
    [BPA_Orig_Entryid]                                 uniqueidentifier      NULL,
    [BPA_TaskInstanceID]                               int                   NULL,
    [BPA_TaskID]                                       int                   NULL,

    -- Standard fields
    [id]                                               nvarchar(100),
    [externalId]                                       nvarchar(100),
    [recordId]                                         int,
    [scriptId]                                         nvarchar(100),
    [name]                                             nvarchar(400),
    [refName]                                          nvarchar(400),
    [abbreviation]                                     nvarchar(100),
    [isInactive]                                       bit,
    [created]                                          datetimeoffset(0),
    [lastmodified]                                     datetimeoffset(0),

    -- Bank account
    [custrecord_2663_entity_acct_name]                 nvarchar(400),
    [custrecord_2663_entity_acct_no]                   nvarchar(100),
    [custrecord_2663_entity_acct_suffix]               nvarchar(100),
    [custrecord_15152_is_acc_num_encrypted]            bit,
    [custrecord_2663_entity_iban]                      nvarchar(100),
    [custrecord_2663_entity_iban_check]                nvarchar(100),
    [custrecord_2663_entity_bban]                      nvarchar(100),
    [custrecord_2663_entity_bic]                       nvarchar(100),
    [custrecord_2663_entity_swift]                     nvarchar(100),
    [custrecord_2663_entity_bank_code]                 nvarchar(100),
    [custrecord_2663_entity_bank_no]                   nvarchar(100),
    [custrecord_2663_entity_bank_name]                 nvarchar(400),
    [custrecord_2663_entity_branch_no]                 nvarchar(100),
    [custrecord_2663_entity_branch_name]               nvarchar(400),
    [custrecord_2663_entity_country_code]              nvarchar(100),
    [custrecord_2663_entity_country_check]             nvarchar(100),

    -- Bank address
    [custrecord_2663_entity_address1]                  nvarchar(400),
    [custrecord_2663_entity_address2]                  nvarchar(400),
    [custrecord_2663_entity_address3]                  nvarchar(400),
    [custrecord_2663_entity_city]                      nvarchar(400),
    [custrecord_2663_entity_state]                     nvarchar(400),
    [custrecord_2663_entity_zip]                       nvarchar(100),

    -- Payment / direct debit settings
    [custrecord_2663_entity_company_id]                nvarchar(100),
    [custrecord_2663_entity_issuer_num]                nvarchar(100),
    [custrecord_2663_entity_processor_code]            nvarchar(100),
    [custrecord_2663_entity_payment_desc]              nvarchar(4000),
    [custrecord_2663_entity_signature]                 nvarchar(4000),
    [custrecord_2663_customer_code]                    nvarchar(100),
    [custrecord_2663_reference]                        nvarchar(400),
    [custrecord_2663_date_ref_mandate]                 nvarchar(400),
    [custrecord_2663_first_pay_date]                   nvarchar(400),
    [custrecord_2663_final_pay_date]                   nvarchar(400),
    [custrecord_2663_num_payments]                     int,
    [custrecord_2663_edi]                              bit,
    [custrecord_2663_edi_value]                        nvarchar(400),
    [custrecord_2663_baby_bonus]                       bit,
    [custrecord_2663_child_id]                         nvarchar(100),

    CONSTRAINT [PK_tb_Netsuite_Bank_account_details] PRIMARY KEY CLUSTERED ([BPA_EntryID])
);

-- Not unique: the same NetSuite record can be queued more than once (per direction / re-pick)
CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_Bank_account_details_id]
    ON dbo.[tb_Netsuite_Bank_account_details] ([id]);

CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_Bank_account_details_BPA_Status]
    ON dbo.[tb_Netsuite_Bank_account_details] ([BPA_Status], [BPA_Direction]) INCLUDE ([id], [BPA_Company]);

CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_Bank_account_details_lastmodified]
    ON dbo.[tb_Netsuite_Bank_account_details] ([lastmodified]);

PRINT N'Created dbo.[tb_Netsuite_Bank_account_details]';
