/*
    vw_Bank_Netsuite_Links: per bank transaction handled by the bank engine
    (sp_Bank_Netsuite_FinancialEntry_Create_V2), the staged NetSuite record and a link to it in NetSuite.

        Staged       vendor payment / customer payment / journal entry (header found by BPA_Orig_Entryid)
        StagedStatus BPA_Status of the header: 0 = waits for the TO task, 1 = sent
        NetsuiteID   internal id, written back by the TO task in BPA_ReturnedID
        NetsuiteURL  link to the record; NULL until NetSuite has created it

    Set the NetSuite host once in the CTE "host" below (sandbox: <account>-sb1.app.netsuite.com).
*/
USE [BPAStaging]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER VIEW dbo.vw_Bank_Netsuite_Links
AS
WITH host AS (
	SELECT BaseURL = N'https://XXXXXXX-sb1.app.netsuite.com'		-- <== your NetSuite host
),
staged AS (
	SELECT Staged = N'Vendor payment', Page = N'vendpymt.nl', h.BPA_Orig_Entryid, h.BPA_EntryID, h.BPA_Status,
	       h.BPA_ReturnedID, h.BPA_Error, h.externalId, h.BPA_Syscreated, h.BPA_Sysmodified
	FROM dbo.tb_Netsuite_VendorPayment h
	WHERE h.BPA_Direction = 'TO'
	UNION ALL
	SELECT N'Customer payment', N'custpymt.nl', h.BPA_Orig_Entryid, h.BPA_EntryID, h.BPA_Status,
	       h.BPA_ReturnedID, h.BPA_Error, h.externalId, h.BPA_Syscreated, h.BPA_Sysmodified
	FROM dbo.tb_Netsuite_CustomerPayment h
	WHERE h.BPA_Direction = 'TO'
	UNION ALL
	SELECT N'Journal entry', N'journal.nl', h.BPA_Orig_Entryid, h.BPA_EntryID, h.BPA_Status,
	       h.BPA_ReturnedID, h.BPA_Error, h.externalId, h.BPA_Syscreated, h.BPA_Sysmodified
	FROM dbo.tb_Netsuite_JournalEntry h
	WHERE h.BPA_Direction = 'TO'
)
SELECT
	t.BPA_EntryID
,	t.BPA_Company
,	t.BPA_Origin
,	t.Bookdate
,	t.Amount
,	t.Currency
,	t.Description
,	t.Matched_typematch
,	t.Matched_WorkflowID
,	s.Staged
,	s.externalId
,	StagedStatus  = s.BPA_Status
,	NetsuiteID    = NULLIF(s.BPA_ReturnedID, '')
,	NetsuiteURL   = CASE WHEN NULLIF(s.BPA_ReturnedID, '') IS NOT NULL
	                     THEN host.BaseURL + N'/app/accounting/transactions/' + s.Page + N'?id=' + s.BPA_ReturnedID END
,	s.BPA_Error
,	StagedOn      = s.BPA_Syscreated
,	SentOn        = s.BPA_Sysmodified
,	StagedEntryID = s.BPA_EntryID
FROM dbo.tb_Bank_Transactions t
JOIN staged s ON s.BPA_Orig_Entryid = t.BPA_EntryID
CROSS JOIN host;
GO

-- Check: the journal entry from the first workflow rule
SELECT Bookdate, Amount, Description, Matched_typematch, Staged, StagedStatus, NetsuiteID, NetsuiteURL, BPA_Error
FROM dbo.vw_Bank_Netsuite_Links
WHERE BPA_EntryID = '94E4F39C-F7C6-F111-9386-00155D0A0313';
GO
