# Foundation Group: vendorBill FROM task (NetSuite to staging)

This page covers reading vendor bills from Foundation Group's NetSuite with the TaskCentre NetSuite connector (REST record service, `vendorBill` › **Search**). The header goes into `dbo.tb_Netsuite_VendorBill` and the expense lines go into `dbo.tb_Netsuite_VendorBill_Expense`.

| File | What |
|---|---|
| `netsuite/foundation/vendorBill_BOD_example.xml` | Example bill from the FG sandbox (record XML), the basis for this design |
| `netsuite/foundation/NetSuiteConnector_vendorBill_Foundation.xml` | Connector object design (`NetSuiteCatalogObj` vendorBill) |
| `sql/foundation/create_tb_Netsuite_VendorBill.sql` | Header and expense line staging tables |
| `tools/build_foundation_vendorbill_object.py` | Regenerates the connector object from the Ellomay export |

## Connector object design

The `vendorBill` object keeps the six standard operations (Read, Search, Add, Update, Upsert and Delete) with their arguments and paging, the same as in the Ellomay export. The FROM task only uses **Search**.

**Body fields:** 54 selected. The standard fields from the table below plus the FG custom fields. The other standard fields are still in the object with `IsSelected = false`, so you can switch them on in the designer. Ellomay's custom fields are removed.

**References** are child objects with only `id` and `refName` selected. NetSuite returns those two values on the record itself, so the connector doesn't need to expand the referenced record (no extra call per bill):

```
vendorBill
├─ entity_vendor, subsidiary_nsResource, currency, postingPeriod, account, terms,
│  approvalStatus, status, department, class, location, billCountry
├─ cseg_bit_4weeks_nsResource
├─ custbody_15529_vendor_entity_bank_nsResource, custbody_11187_pref_entity_bank_nsResource
└─ expense                 (count, hasMore, offset, totalResults, items)
   └─ items  [collection]  -> tb_Netsuite_VendorBill_Expense
      ├─ account, department, class, location
      └─ taxCode, customer, category, amortizationSched, cseg_investment_cat,
         custcol_far_trn_relatedasset, custcol_nl_wkr_category,
         custcol_nondeductible_account          (all _nsResource)
```

`item` (item lines) and `accountingBookDetail` are not selected. The FG bills use the Expenses tab. If item lines are needed later, select `item` and add a `tb_Netsuite_VendorBill_Item` table on the same pattern.

### Importing the object

Import `NetSuiteConnector_vendorBill_Foundation.xml` into the FG connector's business objects, or merge its `<anyType>` element into the FG BusinessObjects file. Then open `vendorBill` in the designer **against the FG account**. Check that the custom fields below exist there and have the same type. The connector shows a field it can't find in the account's metadata as missing.

FG custom fields whose type is taken from the BOD values rather than an existing connector definition (check these in the designer):

| Field | Type in the object | Reason |
|---|---|---|
| `custbody_stc_amount_after_discount`, `_tax_after_discount`, `_total_after_discount` | number | value `12000.00` |
| `custbody_stc_discountpercent` | number | percent field |
| `custbody_stc_daysuntilexpiry` | integer | |
| `custbody_stc_payment_transaction_id` | string | empty in the BOD |
| `cseg_bit_4weeks`, `cseg_investment_cat` | nsResource | custom segments (value `24`) |
| `custcol_far_trn_relatedasset`, `custcol_nl_wkr_category`, `custcol_nondeductible_account` | nsResource | list/record selects |

`custbody_15529_vendor_entity_bank` and `custbody_11187_pref_entity_bank` are the Electronic Bank Payments SuiteApp fields. They're kept as plain references (`nsResource`) instead of `customrecord_2663_entity_bank_details`, so the bank details record isn't expanded.

## FROM task

1. **NetSuite connector, vendorBill › Search**
   - Filter: `lastModifiedDate` `>` the last load. Take it from staging, minus a margin, in NetSuite's date format:
     ```sql
     SELECT DateFilter = FORMAT(DATEADD(day, -1, ISNULL(MAX(lastModifiedDate), '20000101')), 'dd/MM/yyyy')
     FROM dbo.tb_Netsuite_VendorBill;
     ```
     The format depends on the integration user's date preference. In the BOD it is `dd/MM/yyyy`.
   - Optionally also filter on `subsidiary` when loading per company (`BPA_Company`).
   - Internal pagination on. `expandRecords` stays unset: the search returns the full records, sublists included.
2. **Database output, header** → `dbo.tb_Netsuite_VendorBill`. Map `vendorBill` fields 1:1 by name. References: `entity/id` → `entityId`, `entity/refName` → `entityRefName`, and so on. Set `BPA_Origin = 'NetSuite'`, `BPA_Direction = 'FROM'`, `BPA_Company`, `BPA_Reference = id`, `BPA_TaskID` / `BPA_TaskInstanceID`.
3. **Database output, lines** → `dbo.tb_Netsuite_VendorBill_Expense` from `vendorBill/expense/items`. Set `vendorBillId` from the parent `vendorBill/id` and `BPA_ParentID` from the header row's `BPA_EntryID`.

Each run inserts a row per returned bill (BPA pattern: the processing step picks the rows with `BPA_Status = 0`). `IX_tb_Netsuite_VendorBill_id (id, lastModifiedDate)` finds the latest version of a bill.

## Mapping: BOD → REST field → column

The BOD is NetSuite's record XML: lowercase UI names, references as an internal id only. The connector uses the REST names, with references as `{id, refName}`.

### Header (`tb_Netsuite_VendorBill`)

| BOD | REST (connector) | Column | Type |
|---|---|---|---|
| `id` | `id` | `id` | nvarchar(100) NOT NULL |
| `externalid` | `externalId` | `externalId` | nvarchar(100) |
| `tranid` | `tranId` | `tranId` | nvarchar(255): vendor's invoice no. |
| `transactionnumber` | `transactionNumber` | `transactionNumber` | nvarchar(50): `VENDBILL37` |
| `trandate` | `tranDate` | `tranDate` | date |
| `duedate` | `dueDate` | `dueDate` | date |
| `createddate` | `createdDate` | `createdDate` | datetime2(0), UTC |
| `lastmodifieddate` | `lastModifiedDate` | `lastModifiedDate` | datetime2(0), UTC |
| `entity` / `entityname` | `entity` | `entityId` / `entityRefName` | |
| `subsidiary` | `subsidiary` | `subsidiaryId` / `subsidiaryRefName` | |
| `currency` / `currencyname` | `currency` | `currencyId` / `currencyRefName` | |
| `exchangerate` | `exchangeRate` | `exchangeRate` | decimal(28,10) |
| `account` | `account` | `accountId` / `accountRefName` | A/P account |
| `postingperiod` | `postingPeriod` | `postingPeriodId` / `postingPeriodRefName` | |
| `terms` | `terms` | `termsId` / `termsRefName` | |
| `approvalstatus` | `approvalStatus` | `approvalStatusId` / `approvalStatusRefName` | |
| `statusRef` / `status` | `status` | `statusId` / `statusRefName` | `open` / `Open` |
| `department`, `class`, `location` | same | `…Id` / `…RefName` | |
| `memo` | `memo` | `memo` | nvarchar(4000) |
| `total`, `usertotal`, `taxtotal` | `total`, `userTotal`, `taxTotal` | same | decimal(19,4) |
| `discountamount`, `discountdate` | `discountAmount`, `discountDate` | same | decimal / date |
| `paymenthold`, `received`, `tobeprinted` | `paymentHold`, `received`, `toBePrinted` | same | bit |
| `vatregnum` | `vatRegNum` | `vatRegNum` | |
| `billaddressee`, `billattention`, `billaddr1-3`, `billcity`, `billstate`, `billzip` | same, camelCase | same | |
| `billcountry` | `billCountry` | `billCountryId` / `billCountryRefName` | `GB` |
| `billaddress` | `billAddress` | `billAddress` | full address text |
| `cseg_bit_4weeks` | `cseg_bit_4weeks` | `cseg_bit_4weeksId` / `…RefName` | |
| `custbody_document_date` | same | same | date |
| `custbody_establishment_code` | same | same | |
| `custbody_15529_vendor_entity_bank` | same | `…Id` / `…RefName` | |
| `custbody_11187_pref_entity_bank` | same | `…Id` / `…RefName` | |
| `custbody_9997_is_for_ep_eft`, `custbody_11724_pay_bank_fees` | same | same | bit |
| `custbody_stc_amount_after_discount`, `_tax_after_discount`, `_total_after_discount` | same | same | decimal(19,4) |
| `custbody_stc_discountpercent`, `_daysuntilexpiry`, `_payment_transaction_id` | same | same | |

### Expense lines (`tb_Netsuite_VendorBill_Expense`)

| BOD (`expense` machine) | REST (`expense/items`) | Column |
|---|---|---|
| (parent `id`) | | `vendorBillId` NOT NULL |
| `line` | `line` | `line` int NOT NULL |
| `account` / `account_display` | `account` | `accountId` / `accountRefName` |
| `amount` | `amount` | `amount` (net) |
| `taxcode` / `taxcode_display` | `taxCode` | `taxCodeId` / `taxCodeRefName` (`VAT:S`) |
| `taxrate1` (`1.0%`) | `taxRate1` (`1.0`) | `taxRate1` decimal(9,4) |
| `tax1amt`, `grossamt` | `tax1Amt`, `grossAmt` | same |
| `memo` | `memo` | `memo` |
| `department`, `class`, `location`, `customer`, `category`, `amortizationsched` | same | `…Id` / `…RefName` |
| `isbillable` | `isBillable` | bit |
| `amortizstartdate`, `amortizationenddate`, `amortizationresidual` | same, camelCase | |
| `orderdoc`, `orderline` | `orderDoc`, `orderLine` | linked purchase order |
| `cseg_investment_cat`, `custcol_far_trn_relatedasset`, `custcol_nl_wkr_category`, `custcol_nondeductible_account` | same | `…Id` / `…RefName` |

### Left out on purpose

- **UI/session fields**: `_csrf`, `nsapi*`, `wf*`, `nl*`, `custpage_*`, `entryformquerystring`, `version` and the `machine` metadata. They aren't record data and the REST record doesn't have them.
- **Derived or display-only**: `balance`, `origtotal`, `creditlimit_origtotal`, `currencysymbol`, `currencyprecision`, `isbasecurrency`, `duedays`, `pp_s` / `pp_e`, `nexus*`, `edition`, `lineuniquekey`, `categoryexpaccount`, `historyurl`. To get the open amount of a bill, use the vendor payment apply lines or a SuiteQL `foreignamountunpaid`.
- **Localisation fields that are empty in the BOD**: `custbody_sii_*` (Spain), `custbody_4599_*` (MX/SG), `custbody_str_*` / `custcol_str_*` (Intrastat), `custbody_atlas_*`, `custbody_nexus_notc`, `custbody_report_timestamp`, `custbody_sourcesystem`, `custbody_urltoacquireorder`, `custbody_bit_zonalurl`, `custcol_assets_under_construction` and `custcol_emea_country_of_origin`. Add one to `HEADER_CUSTOM` / `EXPENSE_FIELDS` in the tool and to the table if FG needs it.
