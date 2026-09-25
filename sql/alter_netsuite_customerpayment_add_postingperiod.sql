/*
    Add the posting period columns to an existing dbo.tb_Netsuite_CustomerPayment
    (tables created from create_netsuite_customerpayment.sql before they were added).

    BPA mapping: customerPayment/postingPeriod/id      -> postingPeriod_id
                 customerPayment/postingPeriod/refName -> postingPeriod_refName

    Safe to run more than once: each column is only added if it's missing.
*/
SET NOCOUNT ON;

IF OBJECT_ID(N'dbo.tb_Netsuite_CustomerPayment', N'U') IS NULL
BEGIN
    PRINT N'Skipped: dbo.[tb_Netsuite_CustomerPayment] does not exist (create_netsuite_customerpayment.sql already includes these columns)';
    RETURN;
END

IF COL_LENGTH(N'dbo.tb_Netsuite_CustomerPayment', N'postingPeriod_id') IS NULL
BEGIN
    ALTER TABLE dbo.[tb_Netsuite_CustomerPayment] ADD [postingPeriod_id] nvarchar(100) NULL;
    PRINT N'Added dbo.[tb_Netsuite_CustomerPayment].[postingPeriod_id]';
END

IF COL_LENGTH(N'dbo.tb_Netsuite_CustomerPayment', N'postingPeriod_refName') IS NULL
BEGIN
    ALTER TABLE dbo.[tb_Netsuite_CustomerPayment] ADD [postingPeriod_refName] nvarchar(400) NULL;
    PRINT N'Added dbo.[tb_Netsuite_CustomerPayment].[postingPeriod_refName]';
END
