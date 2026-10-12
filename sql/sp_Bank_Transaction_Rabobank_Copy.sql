USE [BPAStaging]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

--[sp_Bank_Transaction_Rabobank_Copy] 'NL16RABO0341522120'

/*
    Copies Rabobank transactions to tb_Bank_Transactions.

    IBAN / BIC / Customername are the other party of the transaction:
    money coming in (creditor = our own account, BPA_Origin) -> the debtor,
    money going out -> the creditor.
    This used to compare with vw_Bank_BankAccounts.Bankaccount, which was always NULL,
    so incoming payments got our own IBAN instead of the payer's.
*/
ALTER procedure [dbo].[sp_Bank_Transaction_Rabobank_Copy](@BPA_Origin varchar(50)) AS

---- Pak hier het eerste entrynumber uit de lijst en zet deze door.
with s as (
select ROW_NUMBER() over (partition by Rabo.BPA_Origin,Rabo.entryReference order by Rabo.BPA_EntryID ) Rownumber
, Rabo.* from tb_Rabobank_Transaction Rabo
left join tb_Rabobank_Transaction RaboFrom on RaboFrom.BPA_Direction='FROM' and  RaboFrom.BPA_Origin=Rabo.BPA_Origin and RaboFrom.entryReference=Rabo.entryReference
where RaboFrom.BPA_EntryID is null
and Rabo.BPA_Direction='FROMUPDATE'
and Rabo.BPA_Status=0
and Rabo.BPA_Origin=@BPA_Origin
)
UPDATE s SET BPA_Direction='FROM' FROM s WHERE Rownumber=1

-- Al bestand? Dan skippen
UPDATE Rabo set BPA_Direction='FROMSKIPPED',BPA_Status=0
from tb_Rabobank_Transaction Rabo
inner join tb_Rabobank_Transaction RaboFrom on RaboFrom.BPA_Direction='FROM' and  RaboFrom.BPA_Origin=Rabo.BPA_Origin and RaboFrom.entryReference=Rabo.entryReference
where Rabo.BPA_Direction='FROMUPDATE'
and Rabo.BPA_Status=0
and Rabo.BPA_Origin=@BPA_Origin




Insert into tb_Bank_Transactions(
BPA_Origin
,BPA_Direction
,BPA_Company
,BPA_Orig_Entryid
,BPA_Reference
,BPA_Reference_Description
,IBAN
,BIC
,Bankname
,Customername
,Description
,Betalingskenmerk
,Kenmerk
,Machtiging
,Incassant
,TypeTransaction
,Amount
,Currency
,Bookdate
,EntryDate
,balanceAfterMutation
,TransactionDatetime
,Mutationcode
)
select
Rabo.BPA_Origin
,Rabo.BPA_Direction
, BPA_Company=bank.Company
, Rabo.BPA_EntryID
, Rabo.entryReference
, 'Rabo.entryReference'
, [IBAN]=  case when isnull(Rabo.creditorAccount_iban,'')=Rabo.BPA_Origin then
			isnull(Rabo.debtorAccount_iban ,debtorAccount_bban)
				else Rabo.creditorAccount_iban end
, [BIC]=case when isnull(Rabo.creditorAccount_iban,'')=Rabo.BPA_Origin then Rabo.debtorAgent else Rabo.creditorAgent end
, [Bankname]=NULL
, [Customername]=case when isnull(Rabo.creditorAccount_iban,'')=Rabo.BPA_Origin then Rabo.debtorName else Rabo.creditorName end
, [Description]=coalesce(Rabo.remittanceInformationUnstructured,Rabo.remittanceInformationstructured,creditorName,debtorName,initiatingpartyname)
, [Betalingskenmerk]=Rabo.paymentInformationIdentification
, [Kenmerk]=Rabo.endToEndId
, [Machtiging]=Rabo.mandateId
, [Incassant]=null --m.Incassant
, [TypeTransaction]=null --m.TypeTransaction
, Amount=Rabo.transactionAmount_value
, Currency=Rabo.transactionAmount_currency
, Bookdate=CAST(cast(raboBookingDateTime as datetime) AT TIME ZONE 'UTC' AT TIME ZONE 'W. Europe Standard Time' AS date)
, Entrydate=rabo.ValueDate
, Rabo.balanceAfterBooking_balanceAmount_value
, Rabo.raboBookingDateTime
, Rabo.bankTransactionCode


from tb_Rabobank_Transaction Rabo

--cross apply dbo.fn_ABN_AnalyseLines(Rabo.BPA_EntryID) m
left join vw_Bank_BankAccounts bank on bank.Bankaccount=Rabo.BPA_Origin collate database_default
left join tb_Bank_Transactions BankTransactions on BankTransactions.BPA_Origin=Rabo.BPA_Origin
	and BankTransactions.BPA_Reference=Rabo.entryReference
where
Rabo.BPA_Direction='FROM'
and Rabo.BPA_Status=0
and Rabo.BPA_Origin=@BPA_Origin
and BankTransactions.BPA_EntryID is null
order by Rabo.BPA_EntryID

update Rabo set BPA_Status=1
from tb_Rabobank_Transaction Rabo
Inner join tb_Bank_Transactions BankTransactions on BankTransactions.BPA_Origin=Rabo.BPA_Origin and BankTransactions.BPA_Orig_Entryid=Rabo.BPA_EntryID
where Rabo.BPA_Status=0
GO
