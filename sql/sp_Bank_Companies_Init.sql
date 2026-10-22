USE [BPAStaging]
GO
/****** Object:  StoredProcedure [dbo].[sp_Bank_Companies_Init]    Script Date: 22/10/2026 11:09:08 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER   procedure [dbo].[sp_Bank_Companies_Init](@BankType nvarchar(100),@Type nvarchar(50)) as
-- NetSuite: tb_Companies.BPA_Company holds the subsidiary name (refName); the bank tables hold the
-- subsidiary id (vw_Bank_BankAccounts.Company, tb_Bank_Transactions.BPA_Company). Match on tb_Companies.subsidiary_ID.

if @Type='Financial' and @BankType='BANK'
begin
	-- Zet de status voor financiële administraties op 0 voor alle divisies waar transacties voor zijn opgehaald.
	-- En er geen administratie bezig is op dit moment.
	if not exists(select * from tb_Bank_Companies where Status_Financial=0)
		update tb
		set Status_Financial=0
		from tb_Companies tb
		inner join (select vw.Company from tb_Bank_Transactions trans (nolock)
					inner join vw_Bank_BankAccounts vw on trans.BPA_Origin=vw.Bankaccount collate database_default
					where trans.BPA_Status=0
					group by vw.Company
					) div on div.Company=cast(tb.subsidiary_ID as nvarchar(100)) collate database_default

end
if @Type='Bankmatching' and @Banktype='BANK'
begin
	-- Zoek hier alle boekingen die goed zijn ingelezen
	-- En ook een matching met meerdere facturen hebben.
	-- Ga alleen nieuwe divisies controleren als er op dit moment geen open staat (eerst alle oude afhandelen).
	-- NetSuite: not used by the bank engine (the TO tasks write the NetSuite id back), kept for the Exact flow.
	if not exists(select * from tb_Bank_Companies where Status_Bankmatching=0)
		update tb
		set Status_Bankmatching=0
		from tb_Companies tb
		inner join (select trans.BPA_Company
					from tb_Bank_Transactions trans (nolock)
					where trans.BPA_Status=1
					and trans.Matched_ReferenceXML is not null
					and trans.BPA_Sysmodified>GETDATE()-7
					group by trans.BPA_Company
					) div on div.BPA_Company=cast(tb.subsidiary_ID as nvarchar(100)) collate database_default
		where tb.Status_Bankmatching<>0
end
GO
