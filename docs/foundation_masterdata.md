# Foundation Group: NetSuite master data tables

This page covers the staging tables for the master data FROM tasks (NetSuite connector, REST record service): vendor, classification, department, location, currency, term, sales tax item (tax code), account and subsidiary.

| File | What |
|---|---|
| `sql/foundation/create_netsuite_masterdata_children.sql` | **Child tables only.** These go next to your existing header tables. A table that already exists is skipped. |
| `sql/foundation/create_netsuite_masterdata.sql` | Reference design: every header and child table. It renames existing tables to `_bak`, so use it to compare, not to run over your tables. |
| `tools/netsuite_masterdata.py` | The spec that both scripts are generated from, plus `validate` and `check-ddl` |
| `docs/foundation_masterdata_validation.md` | Validation report, column by column |
| `netsuite/foundation/*_BOD_example.xml` | FG example records: vendor, account, salesTaxItem (and vendorBill) |

## Child / line tables

Each child row links to its parent with `BPA_ParentID` = parent `BPA_EntryID`. It also holds the parent's NetSuite id in `<record>Id`.

| Child table | From | Why |
|---|---|---|
| `tb_NetSuite_Account_Subsidiary` | `account/subsidiary/items` | In REST, `subsidiary` on an account is a multi-select (a collection, not one value). The BOD shows `subsidiary = 1` only because it's the UI's first value. |
| `tb_NetSuite_Classification_Subsidiary` | `classification/subsidiary/items` | Same: multi-select |
| `tb_NetSuite_Department_Subsidiary` | `department/subsidiary/items` | Same: multi-select |
| `tb_NetSuite_Location_Subsidiary` | `location/subsidiary/items` | Same: multi-select (collection in the REST metadata) |
| `tb_NetSuite_Vendor_AddressBook` | `vendor/addressBook/items` + `addressBookAddress` | The vendor's addresses. REST has no `billaddr1`-style fields on the vendor (the BOD's `bill*` fields are UI fields). Set `expandSubResources` so the connector returns the address subrecord. |

Single-value references (the vendor's `subsidiary`, `currency`, `terms` and so on) don't need a child table. They are `<field>Id` + `<field>RefName` columns on the header.

**Not added, on purpose:**

- **Vendor subsidiaries.** A vendor shared by several subsidiaries isn't a sublist on the vendor in REST. It's a separate record, `vendorSubsidiaryRelationship`. FG has about 35 subsidiaries, so if vendors are shared, read that record as its own FROM task (one row per vendor × subsidiary).
- **Vendor `currencyList`.** The BOD's `currency` machine holds per-currency balances only, and the connector export has no element definition to validate against.
- **Subsidiary `nexus`, account `localizations`, term installments.** No FG use found.

## How to get to each record in NetSuite

**BOD (record XML):** open any record in the NetSuite UI, add `&xml=T` to the end of the URL in the address bar, and press Enter. If the URL has no `?` yet, add `?xml=T` instead. NetSuite then shows that record as XML, like the examples you sent.

| Record | Menu | Typical record URL |
|---|---|---|
| Vendor | Lists › Relationships › Vendors | `/app/common/entity/vendor.nl?id=…` |
| Class | Setup › Company › Classes | `/app/common/otherlists/classtype.nl?id=…` |
| Department | Setup › Company › Departments | `/app/common/otherlists/departmenttype.nl?id=…` |
| Location | Setup › Company › Locations | `/app/common/otherlists/locationtype.nl?id=…` |
| Subsidiary | Setup › Company › Subsidiaries | `/app/common/otherlists/subsidiarytype.nl?id=…` |
| Currency | Lists › Accounting › Currencies | `/app/common/multicurrency/currency.nl?id=…` |
| Term | Setup › Accounting › Accounting Lists, filter **Type = Term** | open a term from that list |
| Account | Lists › Accounting › Accounts | `/app/accounting/account/account.nl?id=…` |
| Tax code (salesTaxItem) | Setup › Tax › Tax Codes | `/app/common/item/taxitem.nl?id=…` |

The menu names can differ slightly with your role and features. Setup › **Records Catalog** lists every record type with its fields and their SuiteQL names.

**REST metadata (the final check):** the BOD shows the UI field names. The connector uses the REST names and types, which come from the metadata catalog. Fetch it once per record with the same credentials as the connector, for example in Postman:

```
GET https://1226620-sb1.suitetalk.api.netsuite.com/services/rest/record/v1/metadata-catalog/vendor
Accept: application/schema+json
```

Do the same for `classification`, `department`, `location`, `currency`, `term`, `salesTaxItem`, `account` and `subsidiary`. Save each response as `<record>.json` in one folder. For production, replace the host with the production account id.

## Sales tax item: likely not available through REST

Oracle's help says REST web services don't support **legacy tax**, and that you need SuiteTax for taxation through REST. FG runs legacy tax: UK edition, `taxrate1` on the bill lines, and a `rate` field on the tax code, which only exists without SuiteTax. So `metadata-catalog/salesTaxItem` will probably return nothing or an error for FG. Try it first. If it fails, read the tax codes with **SuiteQL** instead. That's the REST query service, through the Web Service Connector, the same way as on branch `claude/laughing-hamilton-4eyfc8`:

```sql
SELECT * FROM salestaxitem WHERE ROWNUM <= 1
```

Check the table and field names in Setup › Records Catalog (record *Tax Item*), then select into `tb_Netsuite_SalesTaxItem` with the aliases below. The column names are the camelCase form of the BOD fields.

## Validation status

Run it like this (the connector export and the FROM schemas used as REST evidence are on other branches):

```bash
git show origin/claude/elegant-clarke-ysmfjh:netsuite/NetSuiteConnector_BusinessObjects_Ellomay.xml > /tmp/export.xml
mkdir -p /tmp/xsd && for r in vendor account department location; do
  git show origin/claude/admiring-lamport-qhed1y:schemas/netsuite/$r.xsd > /tmp/xsd/$r.xsd; done
python3 tools/netsuite_masterdata.py validate --export /tmp/export.xml --xsd-dir /tmp/xsd \
    --catalog-dir <folder with the FG metadata-catalog json files> \
    --report docs/foundation_masterdata_validation.md
```

Each column is checked against:

- **REST:** the field exists with a type that fits the column (string → nvarchar/date/datetime2, number → decimal, integer → int, boolean → bit, object/record → `Id`/`RefName`, collection → child table). The sources are the NetSuite connector export and the FROM schemas. Standard fields are the same in every account on the same release; custom fields only count when they're in those definitions.
- **FG BOD:** the field exists in FG's account, and its value fits the type (`T`/`F` → bit, numbers → decimal/int).
- **FG catalog:** the same as REST, but from FG's own metadata. This is the step that makes it 100%.

Every BOD field that holds a value must either be stored or be listed with a reason. UI and session fields (`nsapi*`, `wf*`, `nl*`, `custpage_*`, `_csrf` and so on) are skipped. A reason that says "not in the REST record" is checked against the metadata. The check already caught one wrong reason: account `balance` is in REST and is now stored.

Status now (details in `docs/foundation_masterdata_validation.md`):

| Table | Status |
|---|---|
| Vendor, Vendor_AddressBook, Classification, Department, Location, Currency, Account, Subsidiary, and their child tables | Every column confirmed by REST metadata; vendor and account also against the FG BOD. FG custom fields only where their type is in the connector definitions. |
| Term | **Not confirmed.** Field names come from Oracle's documentation of the REST term record; there is no metadata or BOD yet. |
| SalesTaxItem | Confirmed against the FG BOD only (62 of 67 columns have a value; `externalId`, `effectiveFrom`, `validUntil`, `parent` and `defaultTaxCode` are empty in the example). REST names unconfirmed; see above. |

FG custom fields that are in the BODs but **not** in the tables yet, because their type isn't confirmed (add them after the catalog check):

- vendor: `custentity_2663_eft_file_format`, `custentity_9572_vendor_entitybank_sub`, `custentity_9572_vendor_entitybank_format`, `custentity_emea_company_reg_num`, `custentity_urltoacquireorder`, `custentity_bit_ispnext_vend_id`
- account: `custrecord_summary`, `custrecord_legacy_account_name`, `custrecord_legacy_account_type`, `custrecord_nl_wkr_category_account`, `cseg_investment_cat`. Also `custrecord_fam_account_showinfixedasset`, which is a multi-select: it needs a child table, not a column.

## Comparing with your existing tables

```bash
python3 tools/netsuite_masterdata.py check-ddl <your CREATE TABLE scripts>.sql
```

Per table it lists the columns missing from yours, the columns in yours that aren't in the spec, and type differences (for example `float -> decimal`, `nvarchar -> bit`). In SSMS: right-click the tables › Script Table as › CREATE To › File.
