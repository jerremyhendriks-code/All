/*
    Create dbo.tb_Netsuite_CustomerPayment for the BPA "customerPayment" Search output.

    Column mapping from the BPA schema:
    - Top-level fields keep their NetSuite name. Types follow tc:OriginalType:
      boolean -> bit, integer -> int, number -> decimal, string -> nvarchar.
      Standard date and amount fields get proper date / datetimeoffset / decimal(19,4)
      types; custom (custbody_*) string fields stay nvarchar because the schema doesn't
      say which of them hold dates.
    - Referenced records (account, subsidiary, currency, customer, ...) are flattened to
      <prefix>_<field>, keeping only the fields needed here. The full records belong in
      their own tb_Netsuite_* tables, joined on <prefix>_id.
    - SupplementaryReference (a BPA-internal property) is not stored.

    Does nothing if the table already exists.
*/
SET NOCOUNT ON;

IF OBJECT_ID(N'dbo.tb_Netsuite_CustomerPayment', N'U') IS NOT NULL
BEGIN
    PRINT N'Skipped dbo.[tb_Netsuite_CustomerPayment] (table already exists)';
    RETURN;
END

CREATE TABLE dbo.[tb_Netsuite_CustomerPayment] (
    -- Standard fields
    [id]                                               nvarchar(100) NOT NULL,
    [tranId]                                           nvarchar(100),
    [transactionNumber]                                nvarchar(100),
    [externalId]                                       nvarchar(100),
    [refName]                                          nvarchar(400),
    [tranDate]                                         date,
    [createdDate]                                      datetimeoffset(0),
    [lastModifiedDate]                                 datetimeoffset(0),
    [payment]                                          decimal(19,4),
    [total]                                            decimal(19,4),
    [applied]                                          decimal(19,4),
    [unapplied]                                        decimal(19,4),
    [pending]                                          decimal(19,4),
    [balance]                                          decimal(19,4),
    [exchangeRate]                                     decimal(28,10),
    [paymentInstrumentLimit]                           decimal(19,4),
    [checkNumber]                                      nvarchar(100),
    [memo]                                             nvarchar(4000),
    [originator]                                       nvarchar(100),
    [autoApply]                                        bit,
    [cleared]                                          bit,
    [clearedDate]                                      date,
    [prevDate]                                         date,
    [toBeEmailed]                                      bit,

    -- Referenced records (flattened: <object>/<field> -> <prefix>_<field>)
    [customer_id]                                      nvarchar(100),        -- customer_customer/id
    [customer_entityId]                                nvarchar(400),        -- customer_customer/entityId
    [customer_companyName]                             nvarchar(400),        -- customer_customer/companyName
    [customer_refName]                                 nvarchar(400),        -- customer_customer/refName
    [subsidiary_id]                                    nvarchar(100),        -- subsidiary/id
    [subsidiary_refName]                               nvarchar(400),        -- subsidiary/refName
    [currency_id]                                      nvarchar(100),        -- currency/id
    [currency_refName]                                 nvarchar(400),        -- currency/refName
    [currency_symbol]                                  nvarchar(10),         -- currency/symbol
    [account_id]                                       nvarchar(100),        -- account/id
    [account_acctNumber]                               nvarchar(100),        -- account/acctNumber
    [account_refName]                                  nvarchar(400),        -- account/refName
    [arAcct_id]                                        nvarchar(100),        -- arAcct/id
    [arAcct_acctNumber]                                nvarchar(100),        -- arAcct/acctNumber
    [arAcct_refName]                                   nvarchar(400),        -- arAcct/refName
    [entityBank_id]                                    nvarchar(100),        -- custbody_11187_pref_entity_bank/id
    [entityBank_refName]                               nvarchar(400),        -- custbody_11187_pref_entity_bank/refName
    [entityBank_acct_name]                             nvarchar(400),        -- custbody_11187_pref_entity_bank/custrecord_2663_entity_acct_name
    [entityBank_iban]                                  nvarchar(50),         -- custbody_11187_pref_entity_bank/custrecord_2663_entity_iban
    [entityBank_bic]                                   nvarchar(20),         -- custbody_11187_pref_entity_bank/custrecord_2663_entity_bic
    [entityBank_bank_name]                             nvarchar(400),        -- custbody_11187_pref_entity_bank/custrecord_2663_entity_bank_name
    [entityBank_country_code]                          nvarchar(10),         -- custbody_11187_pref_entity_bank/custrecord_2663_entity_country_code
    [entityBank_reference]                             nvarchar(100),        -- custbody_11187_pref_entity_bank/custrecord_2663_reference
    [entityBank_date_ref_mandate]                      nvarchar(50),         -- custbody_11187_pref_entity_bank/custrecord_2663_date_ref_mandate
    [ilTransactionState_id]                            nvarchar(100),        -- custbody_il_transaction_state/id
    [ilTransactionState_refName]                       nvarchar(400),        -- custbody_il_transaction_state/refName
    [apply_totalResults]                               int,                  -- apply/totalResults

    -- Electronic Bank Payments SuiteApp (2663 / 9997 / 11187 / 11724 / 15699)
    [custbody_9997_is_for_ep_dd]                       bit,
    [custbody_9997_is_for_ep_eft]                      bit,
    [custbody_15699_exclude_from_ep_process]           bit,
    [custbody_2663_reference_num]                      nvarchar(400),
    [custbody_11187_pref_ebd_details]                  nvarchar(max),
    [custbody_11724_bank_fee]                          decimal(28,10),
    [custbody_11724_pay_bank_fees]                     bit,
    [custbody_9997_autocash_assertion_field]           bit,

    -- Other custom body fields (localisation SuiteApps: IL, Nexil, SII, FAM, PH, ...)
    [custbody_4110_customregnum]                       nvarchar(400),
    [custbody_4599_sg_import_permit_num]               nvarchar(400),
    [custbody_4601_appliesto]                          nvarchar(400),
    [custbody_4601_entitytype]                         nvarchar(400),
    [custbody_4601_total_amt]                          decimal(28,10),
    [custbody_4601_transactions]                       nvarchar(max),
    [custbody_4601_wtax_withheld]                      decimal(28,10),
    [custbody_ac_migrated]                             bit,
    [custbody_adjustment_journal]                      bit,
    [custbody_cash_register]                           bit,
    [custbody_counterparty_vat]                        nvarchar(400),
    [custbody_country_of_origin]                       nvarchar(400),
    [custbody_date_of_taxable_supply]                  nvarchar(400),
    [custbody_doc_num_summ_invoice]                    nvarchar(400),
    [custbody_document_date]                           nvarchar(400),
    [custbody_dokka_url]                               nvarchar(max),
    [custbody_el_migrated]                             bit,
    [custbody_establishment_code]                      nvarchar(400),
    [custbody_extra_total_qty]                         int,
    [custbody_fam_jrn_is_reversal]                     bit,
    [custbody_fam_jrn_reversal_date]                   nvarchar(400),
    [custbody_fam_lp_annualrate]                       decimal(28,10),
    [custbody_fam_lp_assetdesc]                        nvarchar(400),
    [custbody_fam_lp_contractnum]                      nvarchar(400),
    [custbody_fam_lp_enddate]                          nvarchar(400),
    [custbody_fam_lp_financelease]                     bit,
    [custbody_fam_lp_ismidlife]                        bit,
    [custbody_fam_lp_priorrecognizedperiods]           int,
    [custbody_fam_lp_startdate]                        nvarchar(400),
    [custbody_fam_lp_term]                             int,
    [custbody_fam_lp_totalinterest]                    decimal(28,10),
    [custbody_fam_lp_totalleaseliab]                   decimal(28,10),
    [custbody_fam_lp_totalleasepayment]                decimal(28,10),
    [custbody_fam_lp_totalnpv]                         decimal(28,10),
    [custbody_fam_lp_totalprincipal]                   decimal(28,10),
    [custbody_fam_specdeprjrn_limit]                   decimal(28,10),
    [custbody_fam_specdeprjrn_rate]                    decimal(28,10),
    [custbody_fam_specdeprjrn_shortage]                decimal(28,10),
    [custbody_fam_specdeprjrn_term1]                   nvarchar(400),
    [custbody_fam_specdeprjrn_term2]                   nvarchar(400),
    [custbody_il_addr1_vn]                             nvarchar(max),
    [custbody_il_addr2_vn]                             nvarchar(max),
    [custbody_il_bank_account_num]                     nvarchar(400),
    [custbody_il_bank_address]                         nvarchar(max),
    [custbody_il_bank_branch_name]                     nvarchar(400),
    [custbody_il_bank_branch_number]                   nvarchar(400),
    [custbody_il_bank_code]                            nvarchar(400),
    [custbody_il_bank_name]                            nvarchar(400),
    [custbody_il_bank_transfer_comments]               nvarchar(max),
    [custbody_il_bank_wht_amount]                      decimal(28,10),
    [custbody_il_city_vn]                              nvarchar(400),
    [custbody_il_country_vn]                           nvarchar(400),
    [custbody_il_currency_locale]                      nvarchar(400),
    [custbody_il_currency_sym_char]                    nvarchar(400),
    [custbody_il_currency_sym_iso]                     nvarchar(400),
    [custbody_il_currency_sym_plcmnt]                  nvarchar(400),
    [custbody_il_eft_name]                             nvarchar(400),
    [custbody_il_entity_billaddress]                   nvarchar(max),
    [custbody_il_entity_fax]                           nvarchar(400),
    [custbody_il_entity_mobile]                        nvarchar(400),
    [custbody_il_entity_phone]                         nvarchar(400),
    [custbody_il_entity_vatregnumber]                  nvarchar(400),
    [custbody_il_exchangerate]                         decimal(28,10),
    [custbody_il_exchangerate_ovrrde]                  bit,
    [custbody_il_force_fld_updts]                      nvarchar(400),
    [custbody_il_gb_aba_num]                           nvarchar(400),
    [custbody_il_gb_bank_acc_name]                     nvarchar(400),
    [custbody_il_gb_bank_acc_num]                      nvarchar(400),
    [custbody_il_gb_bank_address]                      nvarchar(max),
    [custbody_il_gb_bank_name]                         nvarchar(400),
    [custbody_il_gb_iban]                              nvarchar(400),
    [custbody_il_gb_swift_code]                        nvarchar(400),
    [custbody_il_ils_tax_amount]                       decimal(28,10),
    [custbody_il_include_in_wht]                       bit,
    [custbody_il_inv_quantity_for_vat]                 int,
    [custbody_il_irs_alltmnt_appr]                     nvarchar(400),
    [custbody_il_irs_alltmnt_enfrc]                    bit,
    [custbody_il_irs_alltmnt_num]                      nvarchar(400),
    [custbody_il_ita_approved]                         bit,
    [custbody_il_location_address]                     nvarchar(max),
    [custbody_il_maturity_date]                        nvarchar(400),
    [custbody_il_new_check_layout]                     bit,
    [custbody_il_receipt_number]                       nvarchar(400),
    [custbody_il_self_vat_amount]                      decimal(28,10),
    [custbody_il_shipping_num]                         nvarchar(400),
    [custbody_il_state_vn]                             nvarchar(400),
    [custbody_il_subsidiary_addr]                      nvarchar(max),
    [custbody_il_subsidiary_logo]                      nvarchar(max),
    [custbody_il_vat_import_date]                      nvarchar(400),
    [custbody_il_vat_import_number]                    int,
    [custbody_il_vat_ps_doc_num]                       nvarchar(400),
    [custbody_il_vatregnumber]                         nvarchar(400),
    [custbody_il_wht_totalamount]                      decimal(28,10),
    [custbody_il_zipcode_vn]                           nvarchar(400),
    [custbody_itr_doc_number]                          nvarchar(400),
    [custbody_itr_nexus]                               nvarchar(400),
    [custbody_my_import_declaration_num]               nvarchar(400),
    [custbody_nexil_acc_invoice]                       bit,
    [custbody_nexil_cbi_collection_date]               nvarchar(400),
    [custbody_nexil_company_name]                      nvarchar(400),
    [custbody_nexil_competenza_iva_id]                 nvarchar(400),
    [custbody_nexil_competenza_iva_text]               nvarchar(400),
    [custbody_nexil_configuration]                     nvarchar(400),
    [custbody_nexil_customer_deposit_fatt]             bit,
    [custbody_nexil_customize_install_not_s]           bit,
    [custbody_nexil_customize_installments]            bit,
    [custbody_nexil_cut_off_day]                       int,
    [custbody_nexil_data_ric_sdi_id]                   nvarchar(max),
    [custbody_nexil_debit_memo]                        bit,
    [custbody_nexil_disable_custom_rec_calc]           bit,
    [custbody_nexil_dl_skipdunning]                    bit,
    [custbody_nexil_doc_number]                        nvarchar(400),
    [custbody_nexil_due_dates_obj]                     nvarchar(max),
    [custbody_nexil_eb_tax_amount]                     decimal(28,10),
    [custbody_nexil_eb_total]                          decimal(28,10),
    [custbody_nexil_eleinv_art73]                      bit,
    [custbody_nexil_eleinv_billableitem]               bit,
    [custbody_nexil_eleinv_deposit]                    bit,
    [custbody_nexil_eleinv_discountheader]             nvarchar(max),
    [custbody_nexil_eleinv_discountitem]               bit,
    [custbody_nexil_eleinv_enable]                     bit,
    [custbody_nexil_eleinv_items]                      bit,
    [custbody_nexil_eleinv_shippinginfo]               nvarchar(max),
    [custbody_nexil_end_of_month]                      bit,
    [custbody_nexil_ep_cig]                            nvarchar(400),
    [custbody_nexil_ep_cod_comm_conv]                  nvarchar(400),
    [custbody_nexil_ep_cup]                            nvarchar(400),
    [custbody_nexil_exclude_from_decl]                 bit,
    [custbody_nexil_exclude_from_intrastat]            bit,
    [custbody_nexil_exclude_tr_cr_comp]                bit,
    [custbody_nexil_eyc_inserted]                      bit,
    [custbody_nexil_fe_transm_status_date]             nvarchar(400),
    [custbody_nexil_fiscal_code]                       nvarchar(400),
    [custbody_nexil_generated_for_netting]             bit,
    [custbody_nexil_installments_reference]            nvarchar(400),
    [custbody_nexil_intlet_unallocated]                decimal(28,10),
    [custbody_nexil_is_individual]                     bit,
    [custbody_nexil_isconsolidated]                    bit,
    [custbody_nexil_iva_cavallo_id]                    nvarchar(400),
    [custbody_nexil_iva_cavallo_text]                  nvarchar(400),
    [custbody_nexil_management]                        bit,
    [custbody_nexil_net_weight_kg]                     decimal(28,10),
    [custbody_nexil_next_month]                        bit,
    [custbody_nexil_no_of_packages]                    int,
    [custbody_nexil_numb_forcerenum]                   bit,
    [custbody_nexil_numb_is_manual]                    bit,
    [custbody_nexil_numb_is_periodic]                  bit,
    [custbody_nexil_numb_prog]                         int,
    [custbody_nexil_numb_seq_check]                    bit,
    [custbody_nexil_numb_skipnumb]                     bit,
    [custbody_nexil_numb_vendorbillrefdate]            nvarchar(400),
    [custbody_nexil_numb_vendorbillrefnum]             nvarchar(400),
    [custbody_nexil_operation_with_invoice]            bit,
    [custbody_nexil_otc_isinvoiced]                    bit,
    [custbody_nexil_payed_documents]                   nvarchar(max),
    [custbody_nexil_prepmngmnt_cus_dep_data]           nvarchar(max),
    [custbody_nexil_refdate]                           nvarchar(400),
    [custbody_nexil_sc_isscsubjected]                  bit,
    [custbody_nexil_shipping_date]                     nvarchar(400),
    [custbody_nexil_shipping_time]                     nvarchar(400),
    [custbody_nexil_vat_reg_number]                    nvarchar(400),
    [custbody_nexil_vendor_bill_ei_ref_num]            nvarchar(400),
    [custbody_nexil_virtual_stamp]                     decimal(28,10),
    [custbody_nexil_weight_kg]                         decimal(28,10),
    [custbody_nexil_wh_total_amt]                      decimal(28,10),
    [custbody_nexil_whtaxamount]                       decimal(28,10),
    [custbody_nexil_yourref]                           nvarchar(400),
    [custbody_nondeductible_processed]                 bit,
    [custbody_ph4014_wtax_applied]                     bit,
    [custbody_ph4014_wtax_bamt]                        decimal(28,10),
    [custbody_ph4014_wtax_code]                        nvarchar(400),
    [custbody_ph4014_wtax_cpay_pacct]                  nvarchar(400),
    [custbody_ph4014_wtax_rate]                        decimal(28,10),
    [custbody_ph4014_wtax_reversal_flag]               bit,
    [custbody_ph4014_wtax_wamt]                        decimal(28,10),
    [custbody_pos_spesometro]                          bit,
    [custbody_refno_originvoice]                       nvarchar(400),
    [custbody_report_timestamp]                        nvarchar(400),
    [custbody_sii_accounting_date]                     nvarchar(400),
    [custbody_sii_article_61d]                         bit,
    [custbody_sii_article_72_73]                       bit,
    [custbody_sii_code]                                nvarchar(400),
    [custbody_sii_code_issued_inv]                     nvarchar(400),
    [custbody_sii_external_reference]                  nvarchar(400),
    [custbody_sii_invoice_date]                        nvarchar(400),
    [custbody_sii_is_third_party]                      bit,
    [custbody_sii_land_register]                       nvarchar(400),
    [custbody_sii_not_reported_in_time]                bit,
    [custbody_sii_operation_date]                      nvarchar(400),
    [custbody_sii_ref_no]                              nvarchar(400),
    [custbody_sii_registration_msg]                    nvarchar(max),
    [custbody_stc_amount_after_discount]               decimal(28,10),
    [custbody_stc_daysuntilexpiry]                     int,
    [custbody_stc_discountpercent]                     decimal(28,10),
    [custbody_stc_payment_transaction_id]              nvarchar(400),
    [custbody_stc_tax_after_discount]                  decimal(28,10),
    [custbody_stc_total_after_discount]                decimal(28,10),
    [custbody_wht_je_apply_as]                         nvarchar(400),
    [custbody_wtax_base_url]                           nvarchar(max),
    [custbody_x_560_alta_tension]                      nvarchar(400),
    [custbody_x_560_base_imponible]                    decimal(28,10),
    [custbody_x_560_base_liquidable]                   decimal(28,10),
    [custbody_x_560_cantidad]                          decimal(28,10),
    [custbody_x_560_cie_destinatario]                  nvarchar(400),
    [custbody_x_560_contrato_fa]                       nvarchar(400),
    [custbody_x_560_cp]                                nvarchar(400),
    [custbody_x_560_cups]                              nvarchar(400),
    [custbody_x_560_ie]                                decimal(28,10),
    [custbody_x_560_minimo_euros]                      decimal(28,10),
    [custbody_x_560_motivo_regulacion]                 nvarchar(400),
    [custbody_x_560_porce_reduccion]                   nvarchar(400),
    [custbody_x_560_regimen_fiscal]                    nvarchar(400),
    [custbody_x_560_tipo_impositivo]                   decimal(28,10),
    [custbody_x_581_base_imponible]                    nvarchar(400),
    [custbody_x_581_cantidad]                          decimal(28,10),
    [custbody_x_581_cp]                                nvarchar(400),
    [custbody_x_581_cuota_integra]                     decimal(28,10),
    [custbody_x_581_deduccion_importe]                 decimal(28,10),
    [custbody_x_581_tipo_impositivo]                   decimal(28,10),
    [custbody_x_int_puerto_aeropuerto]                 nvarchar(400),
    [custbody_x_sii_add_bienes_inmuebles]              bit,
    [custbody_x_sii_base_imponible_coste]              decimal(28,10),
    [custbody_x_sii_bienes_inmuebles_obj]              nvarchar(max),
    [custbody_x_sii_canarias]                          bit,
    [custbody_x_sii_codigoerrorregistro]               nvarchar(max),
    [custbody_x_sii_deduc_periodo_posterior]           bit,
    [custbody_x_sii_descripcionerrorregistr]           nvarchar(max),
    [custbody_x_sii_dua]                               nvarchar(400),
    [custbody_x_sii_ejer_periodo_deduccion]            nvarchar(400),
    [custbody_x_sii_emitidaporterceros]                bit,
    [custbody_x_sii_emitidaporterceros_numf]           nvarchar(400),
    [custbody_x_sii_excludefromexport]                 bit,
    [custbody_x_sii_fecha_alt_liquidacion]             nvarchar(400),
    [custbody_x_sii_fecha_operacion]                   nvarchar(400),
    [custbody_x_sii_fechacontab]                       nvarchar(400),
    [custbody_x_sii_fechadua]                          nvarchar(400),
    [custbody_x_sii_fechaemision]                      nvarchar(400),
    [custbody_x_sii_num_reg_acuerdofact]               nvarchar(400),
    [custbody_x_sii_rpggee_rdme_competencia]           bit,
    [custbody_x_sii_varios_destinatarios]              bit,
    [custbody_xbasedoc]                                decimal(28,10),
    [custbody_xivadoc]                                 decimal(28,10),
    [custbody_xnumfacfin]                              nvarchar(400),
    [custbody_xnumfacini]                              nvarchar(400),
    [custbody_xtotaldoc]                               decimal(28,10),

    CONSTRAINT [PK_tb_Netsuite_CustomerPayment] PRIMARY KEY CLUSTERED ([id])
);

CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_CustomerPayment_tranDate]
    ON dbo.[tb_Netsuite_CustomerPayment] ([tranDate]) INCLUDE ([tranId], [customer_id], [payment]);

CREATE NONCLUSTERED INDEX [IX_tb_Netsuite_CustomerPayment_lastModifiedDate]
    ON dbo.[tb_Netsuite_CustomerPayment] ([lastModifiedDate]);

PRINT N'Created dbo.[tb_Netsuite_CustomerPayment]';
