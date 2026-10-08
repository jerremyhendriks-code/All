"""
Foundation Group - NetSuite master data staging tables: definition, SQL and validation.

One spec (TABLES below) drives both the CREATE script and the validation, so the
two can't drift apart.

    python3 tools/netsuite_masterdata.py sql full     > sql/foundation/create_netsuite_masterdata.sql
    python3 tools/netsuite_masterdata.py sql children > sql/foundation/create_netsuite_masterdata_children.sql
    python3 tools/netsuite_masterdata.py check-ddl <your CREATE TABLE scripts>
    python3 tools/netsuite_masterdata.py validate --export <Ellomay connector export xml>
            [--xsd-dir <connector FROM-task schemas>]
            [--bod-dir netsuite/foundation] [--catalog-dir <dir with <record>.json>]
            [--report docs/foundation_masterdata_validation.md]

Validation, per column:
  REST  the field and its type exist in the NetSuite connector's REST metadata
        (the Ellomay BusinessObjects export: standard fields are the same in every
        account on the same NetSuite release).
  BOD   the field exists in Foundation Group's account (example record XML) and
        its value fits the column type.
  CAT   the field and its type exist in Foundation Group's own REST metadata
        (GET /services/rest/record/v1/metadata-catalog/<record>, saved as
        <catalog-dir>/<record>.json). This is the final check for every column.
And per BOD: every field that holds a value is either stored in a column or
listed in BOD_SKIP / UI_FIELDS with a reason. Exit code 1 on any error.
"""
import argparse
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

# --------------------------------------------------------------------------- spec
# A column: (column, rest_field, part, sql_type, note)
#   part: None = scalar, 'id' / 'refName' = part of a reference ({id, refName})


def col(field, sql, note='', column=None):
    return (column or field, field, None, sql, note)


def ref(field, note='', id_len=100, name_len=400):
    return [(field + 'Id', field, 'id', f'nvarchar({id_len})', note),
            (field + 'RefName', field, 'refName', f'nvarchar({name_len})', '')]


ID = col('id', 'nvarchar(100) NOT NULL')
EXTERNAL_ID = col('externalId', 'nvarchar(100)')
LAST_MODIFIED = col('lastModifiedDate', 'datetime2(0)', 'UTC')
IS_INACTIVE = col('isInactive', 'bit')

# Child tables. 'refs': a multi-select field ({items: [{id, refName}]}), one row
# per selected value. 'lines': a sublist ({items: [...]}), one row per line;
# fields of a subrecord on the line are written as <subrecord>.<field>.
SUBSIDIARY_CHILD = {
    'suffix': 'Subsidiary', 'field': 'subsidiary', 'kind': 'refs',
    'columns': ref('subsidiary'), 'index': 'subsidiaryId',
}
VENDOR_ADDRESSBOOK = {
    'suffix': 'AddressBook', 'field': 'addressBook', 'kind': 'lines', 'index': 'addressBookId',
    # item definitions: the vendor FROM schema, plus the customer address book in the
    # export (same addressBook element; it also defines country)
    'xsd_items': 'addressBook/items', 'export_items': ['customer/addressBook/items'],
    'evidence': 'line fields: vendor FROM schema (vendor.xsd); countryId / countryRefName: the '
                'customer address book in the connector export (same address subrecord; the '
                'vendor schema has no country selected). Confirm with the FG metadata-catalog.',
    'columns': [
        col('id', 'int NOT NULL', 'address book line id', column='addressBookId'),
        col('label', 'nvarchar(255)'),
        col('defaultBilling', 'bit'),
        col('defaultShipping', 'bit'),
        col('addressBookAddress_text', 'nvarchar(1000)', 'full address as text'),
        col('addressBookAddress.addressee', 'nvarchar(255)', column='addressee'),
        col('addressBookAddress.attention', 'nvarchar(255)', column='attention'),
        col('addressBookAddress.addr1', 'nvarchar(255)', column='addr1'),
        col('addressBookAddress.addr2', 'nvarchar(255)', column='addr2'),
        col('addressBookAddress.addr3', 'nvarchar(255)', column='addr3'),
        col('addressBookAddress.city', 'nvarchar(100)', column='city'),
        col('addressBookAddress.state', 'nvarchar(100)', column='state'),
        col('addressBookAddress.zip', 'nvarchar(50)', column='zip'),
        ('countryId', 'addressBookAddress.country', 'id', 'nvarchar(10)', 'GB, NL, BE, ...'),
        ('countryRefName', 'addressBookAddress.country', 'refName', 'nvarchar(100)', ''),
        col('addressBookAddress.addrPhone', 'nvarchar(50)', column='addrPhone'),
        col('addressBookAddress.override', 'bit', column='override'),
    ],
}

TABLES = [
    {
        'table': 'tb_NetSuite_Vendor', 'record': 'vendor', 'source': 'REST',
        'export_path': ['vendorBill/entity_vendor', 'vendorPayment/entity_vendor'], 'bod': 'vendor_BOD_example.xml',
        'columns': [
            ID, EXTERNAL_ID,
            col('entityId', 'nvarchar(255)', 'vendor number / name in lists'),
            col('companyName', 'nvarchar(255)'),
            col('legalName', 'nvarchar(255)'),
            col('isPerson', 'bit', 'BOD isindividual: Company / Individual'),
            col('salutation', 'nvarchar(50)'),
            col('firstName', 'nvarchar(100)'),
            col('middleName', 'nvarchar(100)'),
            col('lastName', 'nvarchar(100)'),
            col('title', 'nvarchar(100)'),
            col('printOnCheckAs', 'nvarchar(255)'),
            col('email', 'nvarchar(255)'),
            col('altEmail', 'nvarchar(255)'),
            col('phone', 'nvarchar(50)'),
            col('altPhone', 'nvarchar(50)'),
            col('mobilePhone', 'nvarchar(50)'),
            col('homePhone', 'nvarchar(50)'),
            col('fax', 'nvarchar(50)'),
            col('url', 'nvarchar(400)'),
            col('comments', 'nvarchar(4000)'),
            col('defaultAddress', 'nvarchar(1000)', 'default billing address as text'),
            col('accountNumber', 'nvarchar(100)', 'our account number at the vendor'),
            col('vatRegNumber', 'nvarchar(50)'),
            col('taxIdNum', 'nvarchar(50)'),
            col('creditLimit', 'decimal(19,4)'),
            col('balance', 'decimal(19,4)', 'snapshot at load time'),
            col('balancePrimary', 'decimal(19,4)', 'snapshot at load time, primary currency'),
            col('is1099Eligible', 'bit'),
            col('isJobResourceVend', 'bit'),
            col('isAutogeneratedRepresentingEntity', 'bit', 'intercompany vendor created for a subsidiary'),
            IS_INACTIVE,
            col('emailTransactions', 'bit'),
            col('printTransactions', 'bit'),
            col('faxTransactions', 'bit'),
            col('subsidiaryEdition', 'nvarchar(10)', 'UK, NL, ...'),
            col('dateCreated', 'datetime2(0)', 'UTC'),
            LAST_MODIFIED,
            *ref('subsidiary', 'primary subsidiary'),
            *ref('representingSubsidiary'),
            *ref('category'),
            *ref('currency', 'primary currency'),
            *ref('terms'),
            *ref('expenseAccount', 'default expense account'),
            *ref('payablesAccount', 'default A/P account'),
            *ref('defaultVendorPaymentAccount'),
            *ref('taxItem', 'default tax code'),
            *ref('emailPreference', id_len=50, name_len=100),
            # Foundation Group custom fields (SuiteApps; type from the connector schema)
            col('custentity_2663_payment_method', 'bit', 'Electronic Bank Payments: pays by EFT'),
            col('custentity_11724_pay_bank_fees', 'bit'),
            col('custentity_2663_email_address_notif', 'nvarchar(400)', 'EFT notification e-mail'),
            col('custentity_tax_reg_no', 'nvarchar(100)'),
        ],
        'children': [VENDOR_ADDRESSBOOK],
    },
    {
        'table': 'tb_NetSuite_Classification', 'record': 'classification', 'source': 'REST',
        'export_path': 'classification',
        'columns': [
            ID, EXTERNAL_ID,
            col('name', 'nvarchar(255)'),
            col('fullName', 'nvarchar(1000)', 'Parent : Child'),
            *ref('parent'),
            col('includeChildren', 'bit', 'also valid for child subsidiaries'),
            IS_INACTIVE, LAST_MODIFIED,
        ],
        'children': [SUBSIDIARY_CHILD],
    },
    {
        'table': 'tb_NetSuite_Department', 'record': 'department', 'source': 'REST',
        'export_path': 'inventoryItem/department',
        'columns': [
            ID, EXTERNAL_ID,
            col('name', 'nvarchar(255)'),
            col('fullName', 'nvarchar(1000)', 'Parent : Child'),
            *ref('parent'),
            col('includeChildren', 'bit', 'also valid for child subsidiaries'),
            IS_INACTIVE, LAST_MODIFIED,
        ],
        'children': [SUBSIDIARY_CHILD],
    },
    {
        'table': 'tb_NetSuite_Location', 'record': 'location', 'source': 'REST',
        'export_path': 'invoice/location',
        'columns': [
            ID, EXTERNAL_ID,
            col('name', 'nvarchar(255)'),
            col('fullName', 'nvarchar(1000)', 'Parent : Child'),
            *ref('parent'),
            *ref('locationType', id_len=50, name_len=100),
            col('makeInventoryAvailable', 'bit'),
            *ref('timeZone', id_len=100, name_len=200),
            col('tranPrefix', 'nvarchar(50)'),
            col('latitude', 'decimal(12,8)'),
            col('longitude', 'decimal(12,8)'),
            IS_INACTIVE, LAST_MODIFIED,
        ],
        'children': [SUBSIDIARY_CHILD],
    },
    {
        'table': 'tb_NetSuite_Currency', 'record': 'currency', 'source': 'REST',
        'export_path': 'account/currency',
        'columns': [
            ID, EXTERNAL_ID,
            col('name', 'nvarchar(100)', 'GBP, EUR, ...'),
            col('symbol', 'nvarchar(10)', 'ISO code'),
            col('displaySymbol', 'nvarchar(10)'),
            col('isBaseCurrency', 'bit'),
            col('exchangeRate', 'decimal(28,10)', 'default rate against the base currency'),
            col('currencyPrecision', 'int'),
            col('includeInFxRateUpdates', 'bit'),
            col('overrideCurrencyFormat', 'bit'),
            *ref('symbolPlacement', id_len=50, name_len=100),
            *ref('locale', id_len=50, name_len=100),
            col('formatSample', 'nvarchar(100)'),
            IS_INACTIVE, LAST_MODIFIED,
        ],
    },
    {
        'table': 'tb_NetSuite_Term', 'record': 'term', 'source': 'DOC',
        'columns': [
            ID, EXTERNAL_ID,
            col('name', 'nvarchar(255)', 'Net 30, ...'),
            col('dateDriven', 'bit', '0 = standard term, 1 = date driven'),
            col('daysUntilNetDue', 'int', 'standard'),
            col('discountPercent', 'decimal(9,4)', 'standard'),
            col('daysUntilExpiry', 'int', 'standard: discount days'),
            col('dayOfMonthNetDue', 'int', 'date driven'),
            col('dueNextMonthIfWithinDays', 'int', 'date driven'),
            col('discountPercentDateDriven', 'decimal(9,4)', 'date driven'),
            col('dayDiscountExpires', 'int', 'date driven'),
            IS_INACTIVE,
        ],
    },
    {
        'table': 'tb_Netsuite_SalesTaxItem', 'record': 'salesTaxItem', 'source': 'BOD',
        'bod': 'salesTaxItem_BOD_example.xml',
        'columns': [
            ID, EXTERNAL_ID,
            col('itemId', 'nvarchar(100)', 'tax code: E-BE, S-GB, ...'),
            col('description', 'nvarchar(1000)'),
            col('rate', 'decimal(9,4)', '0.00% -> 0.0000'),
            col('effectiveFrom', 'date'),
            col('validUntil', 'date'),
            col('available', 'nvarchar(20)', 'BOTH / SALE / PURCHASE'),
            col('exempt', 'bit'),
            col('export', 'bit'),
            col('service', 'bit'),
            col('reverseCharge', 'bit'),
            col('ecCode', 'bit', 'EC (intra-EU) code'),
            col('isDefault', 'bit'),
            col('excludeFromTaxReports', 'bit'),
            col('includeChildren', 'bit'),
            IS_INACTIVE,
            *ref('nexusCountry', 'country of the tax nexus', id_len=10, name_len=100),
            *ref('subsidiary'),
            *ref('parent'),
            *ref('taxType'),
            *ref('taxAgency', 'vendor the tax is paid to'),
            *ref('purchaseAccount', 'BOD acct1 = name'),
            *ref('saleAccount', 'BOD acct2 = name'),
            *ref('defaultTaxCode'),
            # Tax Reporting Framework (SuiteApp 4110) characteristics
            col('custrecord_4110_category', 'nvarchar(50)', 'tax category code (S0, ...)'),
            col('custrecord_4110_non_deductible', 'bit'),
            col('custrecord_4110_reverse_charge_alt', 'bit'),
            col('custrecord_4110_import', 'bit'),
            col('custrecord_4110_reduced_rate', 'bit'),
            col('custrecord_4110_super_reduced', 'bit'),
            col('custrecord_4110_non_taxable', 'bit'),
            col('custrecord_4110_non_recoverable', 'bit'),
            col('custrecord_4110_partial_credit', 'bit'),
            col('custrecord_4110_no_tax_credit', 'bit'),
            col('custrecord_4110_capital_goods', 'bit'),
            col('custrecord_4110_duty', 'bit'),
            col('custrecord_4110_electronic', 'bit'),
            col('custrecord_4110_government', 'bit'),
            col('custrecord_4110_non_operation', 'bit'),
            col('custrecord_4110_non_resident', 'bit'),
            col('custrecord_4110_other_tax_evidence', 'bit'),
            col('custrecord_4110_outside_customs', 'bit'),
            col('custrecord_4110_paid', 'bit'),
            col('custrecord_4110_purchaser_issued', 'bit'),
            col('custrecord_4110_special_territory', 'bit'),
            col('custrecord_4110_surcharge', 'bit'),
            col('custrecord_4110_suspended', 'bit'),
            col('custrecord_4110_triplicate', 'bit'),
            col('custrecord_4110_unknown_tax_credit', 'bit'),
            col('custrecord_4110_cash_register', 'bit'),
            col('custrecord_4110_duplicate', 'bit'),
            col('custrecord_4110_no_tax_invoice', 'bit'),
            col('custrecord_100_percent_non_deductable', 'bit'),
            col('custrecord_deemed_supply', 'bit'),
            col('custrecord_for_digital_services', 'bit'),
            col('custrecord_is_direct_cost_service', 'bit'),
            col('custrecord_post_notional_tax_amount', 'bit'),
            col('custrecord_gcc_state', 'bit'),
        ],
    },
    {
        'table': 'tb_NetSuite_Account', 'record': 'account', 'source': 'REST',
        'export_path': ['account', 'vendorBill/account'], 'bod': 'account_BOD_example.xml',
        'columns': [
            ID, EXTERNAL_ID,
            col('acctNumber', 'nvarchar(60)'),
            col('acctName', 'nvarchar(255)'),
            col('fullName', 'nvarchar(1000)', 'number + name with parents'),
            col('displayNameWithHierarchy', 'nvarchar(1000)'),
            col('description', 'nvarchar(1000)'),
            *ref('acctType', 'AcctRec, Expense, ...', id_len=50, name_len=100),
            *ref('sSpecAcct', 'special account type', id_len=50, name_len=100),
            *ref('parent'),
            *ref('currency', 'bank / credit card accounts'),
            *ref('generalRate', 'CURRENT / HISTORICAL / AVERAGE', id_len=50, name_len=100),
            *ref('cashFlowRate', 'CURRENT / HISTORICAL / AVERAGE', id_len=50, name_len=100),
            col('isSummary', 'bit'),
            col('inventory', 'bit'),
            col('revalue', 'bit'),
            col('eliminate', 'bit'),
            col('reconcileWithMatching', 'bit'),
            col('balance', 'decimal(19,4)', 'snapshot at load time'),
            col('includeChildren', 'bit', 'also valid for child subsidiaries'),
            *ref('department', 'restrict to'),
            *ref('class', 'restrict to'),
            *ref('location', 'restrict to'),
            IS_INACTIVE, LAST_MODIFIED,
            # Foundation Group custom fields (type from the connector schema)
            col('custrecord_acct_bank_account_number', 'nvarchar(100)'),
        ],
        'children': [SUBSIDIARY_CHILD],
    },
    {
        'table': 'tb_NetSuite_Subsidiary', 'record': 'subsidiary', 'source': 'REST',
        'export_path': 'invoice/subsidiary',
        'columns': [
            ID, EXTERNAL_ID,
            col('name', 'nvarchar(255)'),
            col('fullName', 'nvarchar(1000)', 'Parent : Child'),
            col('legalName', 'nvarchar(255)'),
            *ref('parent'),
            col('isElimination', 'bit'),
            *ref('country', id_len=10, name_len=100),
            col('state', 'nvarchar(100)'),
            *ref('currency', 'base currency'),
            *ref('edition', 'UK, NL, BE, ...', id_len=10, name_len=100),
            col('federalIdNumber', 'nvarchar(50)', 'VAT / tax registration number'),
            col('email', 'nvarchar(255)'),
            col('fax', 'nvarchar(50)'),
            col('url', 'nvarchar(400)'),
            col('tranPrefix', 'nvarchar(50)'),
            *ref('fiscalCalendar'),
            *ref('representingVendor', 'intercompany vendor'),
            *ref('representingCustomer', 'intercompany customer'),
            IS_INACTIVE, LAST_MODIFIED,
        ],
    },
]

# BOD fields that are UI / session state, never record data
UI_FIELDS = {
    '_eml_nkey_', '_multibtnstate_', 'selectedtab', 'nsbrowserenv', 'type', 'whence', 'customwhence',
    'entryformquerystring', '_csrf', 'wfinstances', 'baserecordtype', 'version', 'ntype', 'nameorig',
    'submitnext_t', 'submitnext_y', 'sessioncountry', 'shipping_country', 'freeformstatepref',
    'polymorphcontainscreditlimit', 'invalidemaildiv', 'emailval', 'itemtype', 'edition',
}
UI_PREFIXES = ('nsapi', 'wf', 'nl', 'custpage_', 'orig', 'has')

# BOD fields with a value that are not stored, with the reason
BOD_SKIP = {
    'vendor': {
        'entitytitle': 'display copy of entityId',
        'isindividual': 'UI radio for isPerson (stored)',
        'currid': 'UI copy of the record id',
        'otherrelationships': 'UI: other entity types of the same company',
        'emailpreference': None,  # stored as emailPreferenceId (object) - see ref
        'balanceprimarycurrency': 'currency label of balancePrimary',
        'creditlimitcurrency': 'currency label of creditLimit',
        'prepaymentbalance': 'not in the REST vendor record',
        'prepaymentbalancecurrency': 'currency label',
        'unbilledorders': 'not in the REST vendor record',
        'unbilledordersprimary': 'not in the REST vendor record',
        'unbilledordersprimarycurrency': 'currency label',
        'globalsubscriptionstatus': 'marketing subscription status',
        'unsubscribe': 'marketing subscription flag',
        'custentity_bit_ispnext_vend_overview_rep': 'HTML link generated by a script',
    },
    'salesTaxItem': {
        'acct1': 'display name of purchaseAccount (stored as purchaseAccountRefName)',
        'acct2': 'display name of saleAccount (stored as saleAccountRefName)',
    },
    'account': {
        'accttype2': 'UI copy of accttype',
        'excludefrompaybillspage': 'not in the REST account record',
        'custrecord_has_mx_localization': 'Mexico localisation flag, not used by FG',
        'custrecord_summary': 'type not confirmed by REST metadata: add after the catalog check',
    },
}

BPA_COLUMNS = [
    ('BPA_Origin', 'nvarchar(50)', None), ('BPA_Direction', 'nvarchar(50)', None),
    ('BPA_Company', 'nvarchar(50)', None),
    ('BPA_EntryID', 'uniqueidentifier NOT NULL', ('EntryID', '(newsequentialid())')),
    ('BPA_ParentID', 'uniqueidentifier', None),
    ('BPA_Status', 'int', ('Status', '((0))')),
    ('BPA_Reference', 'nvarchar(50)', None), ('BPA_Reference_Description', 'nvarchar(100)', None),
    ('BPA_Reference2', 'nvarchar(50)', None), ('BPA_Reference2_Description', 'nvarchar(100)', None),
    ('BPA_Action', 'nvarchar(1)', None), ('BPA_ReturnedID', 'nvarchar(50)', None),
    ('BPA_Syscreated', 'datetime', ('Syscreated', '(getdate())')),
    ('BPA_Sysmodified', 'datetime', ('Sysmodified', '(getdate())')),
    ('BPA_Syscreator', 'nvarchar(50)', None),
    ('BPA_Error', 'nvarchar(max)', None), ('BPA_Error_Extended', 'nvarchar(max)', None),
    ('BPA_Description', 'nvarchar(255)', None),
    ('BPA_Failcount', 'int', ('Failcount', '((0))')),
    ('BPA_Orig_Entryid', 'uniqueidentifier', None),
    ('BPA_TaskInstanceID', 'int', None), ('BPA_TaskID', 'int', None),
]

# --------------------------------------------------------------------------- SQL

REBUILD_PROC = """\
SET XACT_ABORT ON;
SET NOCOUNT ON;
IF OBJECT_ID(N'tempdb..#rebuild') IS NOT NULL DROP PROCEDURE #rebuild;
GO
-- Renames an existing table to <table>_bak (constraints and indexes get a _bak
-- suffix too), so the new definition can be created without losing data.
CREATE PROCEDURE #rebuild @table sysname AS
BEGIN
    DECLARE @bak sysname = @table + N'_bak', @old sysname, @new sysname, @obj nvarchar(300), @msg nvarchar(400);
    IF OBJECT_ID(N'dbo.' + QUOTENAME(@table), N'U') IS NULL RETURN;
    IF OBJECT_ID(N'dbo.' + QUOTENAME(@bak), N'U') IS NOT NULL
    BEGIN
        SET @msg = N'dbo.' + @bak + N' already exists; drop or rename it first.';
        THROW 50001, @msg, 1;
    END
    SET @obj = N'dbo.' + QUOTENAME(@table);
    EXEC sys.sp_rename @objname = @obj, @newname = @bak, @objtype = N'OBJECT';
    PRINT N'Renamed  dbo.' + @table + N' -> ' + @bak;
    DECLARE con CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.objects
        WHERE parent_object_id = OBJECT_ID(N'dbo.' + QUOTENAME(@bak)) AND type IN ('PK', 'UQ', 'D', 'C', 'F');
    OPEN con;
    FETCH NEXT FROM con INTO @old;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @new = LEFT(@old, 124) + N'_bak';
        SET @obj = N'dbo.' + QUOTENAME(@old);
        EXEC sys.sp_rename @objname = @obj, @newname = @new, @objtype = N'OBJECT';
        FETCH NEXT FROM con INTO @old;
    END
    CLOSE con;
    DEALLOCATE con;
    DECLARE ix CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.indexes
        WHERE object_id = OBJECT_ID(N'dbo.' + QUOTENAME(@bak)) AND is_primary_key = 0
          AND is_unique_constraint = 0 AND name IS NOT NULL;
    OPEN ix;
    FETCH NEXT FROM ix INTO @old;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @new = LEFT(@old, 124) + N'_bak';
        SET @obj = N'dbo.' + QUOTENAME(@bak) + N'.' + QUOTENAME(@old);
        EXEC sys.sp_rename @objname = @obj, @newname = @new, @objtype = N'INDEX';
        FETCH NEXT FROM ix INTO @old;
    END
    CLOSE ix;
    DEALLOCATE ix;
END
GO
"""




def column_lines(table, columns, width):
    out = []
    for name, _f, _p, typ, note in columns:
        line = f'    {name:<{width}}{typ if "NOT NULL" in typ else typ + " NULL"},'
        out.append(f'{line:<{width + 32}}-- {note}' if note else line)
    return out


def create_table(table, columns, mode, parent=None):
    """mode 'rebuild': rename an existing table to _bak first; 'ifmissing': skip if it exists."""
    parent_cols = []
    if parent:
        parent_cols = [(parent['id_col'], None, None, 'nvarchar(100) NOT NULL',
                        f"{parent['record']}/id (the parent's NetSuite id)")]
    width = max(len(c[0]) for c in BPA_COLUMNS + columns + parent_cols) + 2
    ind = '' if mode == 'rebuild' else '    '
    out = [f"EXEC #rebuild N'{table}';"] if mode == 'rebuild' else [
        f"IF OBJECT_ID(N'dbo.{table}', N'U') IS NULL", 'BEGIN']
    out += [f'{ind}CREATE TABLE dbo.{table} (',
            f'{ind}    -- BPA control fields (standard block, same as the other tb_Netsuite_* tables)']
    for name, typ, default in BPA_COLUMNS:
        line = f'{ind}    {name:<{width}}{typ}' + ('' if 'NOT NULL' in typ else ' NULL')
        if default:
            line += f' CONSTRAINT DF_{table}_{default[0]} DEFAULT {default[1]}'
        out.append(line + ',')
    if parent:
        out += ['', f"{ind}    -- Parent: BPA_ParentID = {parent['table']}.BPA_EntryID"]
        out += [ind + l for l in column_lines(table, parent_cols, width)]
    out += ['', f'{ind}    -- NetSuite fields (REST names; a reference is <field>Id + <field>RefName)']
    out += [ind + l for l in column_lines(table, columns, width)]
    out += [f'{ind}    CONSTRAINT PK_{table} PRIMARY KEY CLUSTERED (BPA_EntryID)', f'{ind});']
    return out, ind


def table_sql(t, mode):
    table, lines = t['table'], []
    lines += [f'-- {"-" * 75}', f"-- {t['record']}", f'-- {"-" * 75}']
    body, ind = create_table(table, t['columns'], mode)
    lines += body
    lines.append(f'{ind}CREATE NONCLUSTERED INDEX IX_{table}_id ON dbo.{table} (id)'
                 + (' INCLUDE (lastModifiedDate);' if LAST_MODIFIED in t['columns'] else ';'))
    lines.append(f'{ind}CREATE NONCLUSTERED INDEX IX_{table}_BPA_Status ON dbo.{table} (BPA_Status, BPA_Direction) INCLUDE (id, BPA_Company);')
    lines.append(f"{ind}PRINT N'Created  dbo.{table}';")
    if mode != 'rebuild':
        lines += ['END', 'ELSE', f"    PRINT N'Skipped  dbo.{table} (already exists)';"]
    return lines + ['']


def child_sql(t, ch, mode):
    child = f"{t['table']}_{ch['suffix']}"
    parent = {'table': t['table'], 'record': t['record'], 'id_col': t['record'] + 'Id'}
    what = 'one row per selected subsidiary' if ch['kind'] == 'refs' else 'one row per line'
    lines = [f"-- {t['record']}/{ch['field']}/items -> dbo.{child}: {what}"]
    body, ind = create_table(child, ch['columns'], mode, parent)
    lines += body
    lines.append(f'{ind}CREATE NONCLUSTERED INDEX IX_{child}_BPA_ParentID ON dbo.{child} (BPA_ParentID);')
    lines.append(f"{ind}CREATE NONCLUSTERED INDEX IX_{child}_{parent['id_col']} ON dbo.{child} ({parent['id_col']}, {ch['index']});")
    lines.append(f"{ind}PRINT N'Created  dbo.{child}';")
    if mode != 'rebuild':
        lines += ['END', 'ELSE', f"    PRINT N'Skipped  dbo.{child} (already exists)';"]
    return lines + ['']


COMMON_NOTES = [
    '    Column names are the NetSuite REST field names. A reference field is stored',
    '    as <field>Id + <field>RefName (the values on the record itself; the',
    '    connector does not need to expand the referenced record). Timestamps',
    "    (lastModifiedDate, dateCreated) come as 'YYYY-MM-DDThh:mm:ssZ' and are UTC.",
    '    A child row links to its parent through BPA_ParentID = parent BPA_EntryID,',
    "    and holds the parent's NetSuite id in <record>Id.",
]


def sql_script(which):
    lines = ['/*']
    if which == 'full':
        lines += ['    Foundation Group - staging tables for NetSuite master data (FROM tasks,',
                  '    NetSuite connector): every table, header and child. Reference design:',
                  '    compare your own tables with it (tools/netsuite_masterdata.py check-ddl).', '']
    else:
        lines += ['    Foundation Group - child tables for NetSuite master data (FROM tasks,',
                  '    NetSuite connector). Adds only the child tables, next to the existing',
                  '    header tables; a table that already exists is skipped.', '']
    for t in TABLES:
        if which == 'full':
            lines.append(f"    dbo.{t['table']:<38}{t['record']}")
        for ch in t.get('children', []):
            lines.append(f"    dbo.{t['table'] + '_' + ch['suffix']:<38}{t['record']}/{ch['field']}/items")
    lines += [''] + COMMON_NOTES + ['']
    if which == 'full':
        lines += ['    Existing tables are renamed to <table>_bak (constraints and indexes included)',
                  '    before the new ones are created; drop the _bak tables once loading works.',
                  '    Stops without changes if a _bak table already exists.']
    lines += ['    Runs in a single transaction.', '',
              '    Generated by tools/netsuite_masterdata.py: change the spec there and',
              '    regenerate. See docs/foundation_masterdata.md.', '*/']
    if which == 'full':
        lines += [REBUILD_PROC]
    else:
        lines += ['SET XACT_ABORT ON;', 'SET NOCOUNT ON;', 'GO']
    lines += ['BEGIN TRANSACTION;', '']
    for t in TABLES:
        if which == 'full':
            lines += table_sql(t, 'rebuild')
        for ch in t.get('children', []):
            lines += child_sql(t, ch, 'rebuild' if which == 'full' else 'ifmissing')
    lines += ['COMMIT TRANSACTION;', 'GO']
    if which == 'full':
        lines += ['DROP PROCEDURE #rebuild;', 'GO']
    return '\n'.join(lines) + '\n'

# --------------------------------------------------------------------------- validation


SQL_FOR_REST = {
    # REST type -> SQL types a scalar column may have
    'string': ('nvarchar', 'date', 'datetime2'),
    'number': ('decimal',),
    'integer': ('int',),
    'boolean': ('bit',),
}
DATE_FIELDS = re.compile(r'(date|created|from|until)$', re.I)
XS = '{http://www.w3.org/2001/XMLSchema}'
TC = '{http://www.orbis-software.com/ns/tcschemaextensions}'


def sql_base(typ):
    return re.match(r'\w+', typ).group(0).lower()


def fields_of(node, with_children=True):
    """Fields of a connector object node; fields of its child objects as <child>.<field>."""
    fields = {}
    for f in (node.find('Fields') if node.find('Fields') is not None else []):
        fields[f.findtext('FieldName')] = (f.findtext('TypeName'), f.findtext('IsCollection') == 'true')
    cs = node.find('ChildStructures')
    if with_children and cs is not None:
        for c in cs:
            for k, v in fields_of(c, False).items():
                fields.setdefault(f"{c.findtext('ListItemName')}.{k}", v)
    return fields


def load_export(path):
    objs = {o.findtext('Name'): o for o in ET.parse(path).getroot()}

    def node(p):
        parts = p.split('/')
        o = objs[parts[0]]
        for part in parts[1:]:
            o = [c for c in o.find('ChildStructures') if c.findtext('Name') == part][0]
        return o

    def get(paths):
        # the same record appears in several places; merge them (first one wins)
        fields = {}
        for p in ([paths] if isinstance(paths, str) else paths):
            for k, v in fields_of(node(p)).items():
                fields.setdefault(k, v)
        return fields
    return get


def xsd_fields(el, prefix='', depth=1):
    fields = {}
    seq = el.find(f'{XS}complexType/{XS}sequence')
    for e in (seq.findall(f'{XS}element') if seq is not None else []):
        name = prefix + e.get('name')
        if e.find(f'{XS}complexType') is not None:
            fields[name] = ('object', e.get('maxOccurs') == 'unbounded')
            if depth > 0:
                fields.update(xsd_fields(e, name + '.', depth - 1))
        else:
            fields[name] = (e.get(f'{TC}OriginalType'), False)
    return fields


def load_xsd(path, sub=None):
    """Fields of a connector FROM-task output schema (tc:OriginalType); sub = path below the record."""
    el = ET.parse(path).getroot().find(f'{XS}element/{XS}complexType/{XS}sequence/{XS}element')
    for part in (sub.split('/') if sub else []):
        el = [e for e in el.find(f'{XS}complexType/{XS}sequence').findall(f'{XS}element')
              if e.get('name') == part][0]
    return xsd_fields(el)


def load_catalog(path, record):
    doc = json.load(open(path, encoding='utf-8'))
    props = doc.get('properties')
    if props is None:
        schemas = doc.get('components', {}).get('schemas', {})
        key = next((k for k in schemas if k.lower() == record.lower()), None)
        props = schemas[key]['properties'] if key else {}
    out = {}
    for name, p in props.items():
        target = p.get('$ref', '') or ''.join(x.get('$ref', '') for x in p.get('allOf', []))
        if target or p.get('type') == 'object':
            out[name] = ('collection' if target.lower().endswith('collection') else 'object', 'ref')
        else:
            out[name] = (p.get('type'), p.get('format'))
    return out


def check_column(column, field, part, sql, source, kind):
    """None if the column fits the source's definition of the field, else the problem."""
    if field not in source:
        return 'MISSING'
    typ, extra = source[field]
    typ = typ or ''
    if kind == 'refs':
        return None if (extra is True or 'collection' in typ.lower()) else f'not a collection ({typ})'
    if part:
        return None if typ not in SQL_FOR_REST else f'scalar {typ}, not a reference'
    if extra in ('date', 'date-time'):           # catalog formats
        want = 'date' if extra == 'date' else 'datetime2'
        return None if sql_base(sql) == want else f'{sql_base(sql)}, catalog format {extra}'
    allowed = SQL_FOR_REST.get(typ)
    if allowed is None:
        return f'{typ} is not a scalar'
    if sql_base(sql) not in allowed:
        return f'{sql_base(sql)} does not fit {typ}'
    if typ == 'string' and sql_base(sql) in ('date', 'datetime2') and not DATE_FIELDS.search(field):
        return f'{sql_base(sql)} on a string field that is not a date'
    return None


def bod_values(path):
    rec = ET.parse(path).getroot().find('record')
    return {e.tag: (e.text or '').strip() for e in rec if e.tag != 'machine'}


def bod_type_error(sql, value):
    base = sql_base(sql)
    if base == 'bit' and value not in ('T', 'F'):
        return f'value {value!r} is not T/F'
    if base in ('decimal', 'int') and not re.fullmatch(r'-?[\d,]*\.?\d*%?', value):
        return f'value {value!r} is not numeric'
    return None


def validate(args):
    errors, report, summary = [], [], []
    export = load_export(args.export) if args.export else None
    for t in TABLES:
        rec = t['record']
        rest = export(t['export_path']) if export and t.get('export_path') else {}
        xsd_path = os.path.join(args.xsd_dir, rec + '.xsd') if args.xsd_dir else None
        has_xsd = bool(xsd_path and os.path.exists(xsd_path))
        if has_xsd:
            for k, v in load_xsd(xsd_path).items():
                rest.setdefault(k, v)
        cat_path = os.path.join(args.catalog_dir, rec + '.json') if args.catalog_dir else None
        cat = load_catalog(cat_path, rec) if cat_path and os.path.exists(cat_path) else None
        bod = bod_values(os.path.join(args.bod_dir, t['bod'])) if t.get('bod') else None

        groups = [(t['table'], None, t['columns'], rest)]
        for ch in t.get('children', []):
            if ch['kind'] == 'refs':
                src = rest
            else:
                src = export(ch['export_items']) if export and ch.get('export_items') else {}
                if has_xsd and ch.get('xsd_items'):
                    for k, v in load_xsd(xsd_path, ch['xsd_items']).items():
                        src.setdefault(k, v)
            groups.append((f"{t['table']}_{ch['suffix']}", ch, ch['columns'], src))

        report += ['', f"## {t['table']} ({rec})", '',
                   f"Design source: {t['source']}. REST metadata: "
                   + ('connector export' + (' + FROM schema' if has_xsd else '') if rest else '**none**')
                   + '. FG metadata-catalog: ' + ('checked' if cat else 'not supplied')
                   + '. FG BOD: ' + ('checked' if bod else 'none') + '.']
        for table, ch, columns, src in groups:
            kind = ch['kind'] if ch else None
            confirmed = 0
            report += ['', f'### {table}' + (f" ({rec}/{ch['field']}/items)" if ch else ''), '']
            if ch and ch.get('evidence'):
                report += [f"Evidence: {ch['evidence']}", '']
            report += [
                       '| Column | SQL type | REST | FG BOD | FG catalog |', '|---|---|---|---|---|']
            for column, field, part, sql, _note in columns:
                key = ch['field'] if kind == 'refs' else field
                cells = []
                for name, source in (('REST', src), ('catalog', cat)):
                    if not source or (name == 'catalog' and ch and kind == 'lines'):
                        cells.append('-')
                        continue
                    err = check_column(column, key, part, sql, source, kind)
                    cells.append('ok' if not err else f'**{err}**')
                    if err:
                        errors.append(f'{table}.{column}: {name} {err}')
                if cells[0] == 'ok' or cells[1] == 'ok':
                    confirmed += 1
                if bod is None or ch:
                    bod_cell = '-'
                elif field.lower() in bod:
                    value = bod[field.lower()]
                    err = bod_type_error(sql, value) if value and not part else None
                    bod_cell = (f'`{value[:30]}`' if value else 'present') if not err else f'**{err}**'
                    if err:
                        errors.append(f'{table}.{column}: BOD {err}')
                    if not rest and not cat:
                        confirmed += 1 if value else 0
                else:
                    bod_cell = 'not in BOD'
                report.append(f'| {column} | {sql} | {cells[0]} | {bod_cell} | {cells[1]} |')
            summary.append((table, confirmed, len(columns), bool(src), bool(cat)))

        if bod is not None:
            stored = {f.lower() for _c, f, *_r in t['columns']} | {
                ch['field'].lower() for ch in t.get('children', [])}
            skip = BOD_SKIP.get(rec, {})
            skipped = []
            for name, value in sorted(bod.items()):
                if not value or name in stored or name in UI_FIELDS or name.startswith(UI_PREFIXES):
                    continue
                in_rest = next((k for k in rest if k.lower() == name), None)
                if skip.get(name):
                    note = f' (REST field `{in_rest}`)' if in_rest else ''
                    skipped.append(f'- `{name}` = `{value[:40]}`: {skip[name]}{note}')
                    if in_rest and 'not in the REST' in skip[name]:
                        errors.append(f"{t['table']}: BOD_SKIP says {name} is not in REST, but REST has {in_rest}")
                else:
                    skipped.append(f'- **UNEXPLAINED** `{name}` = `{value[:40]}`')
                    errors.append(f"{t['table']}: BOD field {name} has a value but is not stored or explained")
            report += ['', 'BOD fields with a value that are not stored:', ''] + (skipped or ['- none'])

    head = ['# Foundation Group master data tables: validation report', '',
            'Generated by `tools/netsuite_masterdata.py validate`. Errors: '
            + (str(len(errors)) if errors else 'none') + '.', '',
            '| Table | Columns confirmed | REST metadata | FG catalog |', '|---|---|---|---|']
    head += [f'| {tb} | {c} / {n} | {"yes" if r else "**no**"} | {"yes" if k else "not supplied"} |'
             for tb, c, n, r, k in summary]
    head += ['', 'A column counts as confirmed when the REST metadata (connector export, FROM schema '
             'or FG metadata-catalog) has the field with a matching type, or - for a record without '
             'REST metadata - when the FG BOD holds a value of the matching type.']
    if errors:
        head += ['', '## Errors', ''] + [f'- {e}' for e in errors]
    print('\n'.join(errors) if errors else 'validation passed: no errors', file=sys.stderr)
    for tb, c, n, r, k in summary:
        if c < n:
            print(f'  {tb}: {c} of {n} columns confirmed', file=sys.stderr)
    if args.report:
        with open(args.report, 'w', encoding='utf-8') as fh:
            fh.write('\n'.join(head + report) + '\n')
    return 1 if errors else 0

# --------------------------------------------------------------------------- check-ddl


def parse_ddl(text):
    """{table: {column: type}} from CREATE TABLE statements (any schema, brackets or not)."""
    text = re.sub(r'--[^\n]*', '', text)
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    tables = {}
    for m in re.finditer(r'CREATE\s+TABLE\s+(?:\[?\w+\]?\.)?\[?(\w+)\]?\s*\(', text, re.I):
        depth, i = 1, m.end()
        while depth and i < len(text):
            depth += {'(': 1, ')': -1}.get(text[i], 0)
            i += 1
        body, cols, part, depth = text[m.end():i - 1], [], '', 0
        for chr_ in body + ',':
            if chr_ == ',' and depth == 0:
                cols.append(part.strip())
                part = ''
                continue
            depth += {'(': 1, ')': -1}.get(chr_, 0)
            part += chr_
        defs = {}
        for c in cols:
            cm = re.match(r'\[?(\w+)\]?\s+\[?(\w+)\]?', c)
            if cm and cm.group(1).upper() not in ('CONSTRAINT', 'PRIMARY', 'UNIQUE', 'INDEX', 'FOREIGN', 'CHECK'):
                defs[cm.group(1)] = cm.group(2).lower()
        tables[m.group(1)] = defs
    return tables


def check_ddl(args):
    spec = {}
    for t in TABLES:
        spec[t['table'].lower()] = (t['table'], t['columns'], None)
        for ch in t.get('children', []):
            spec[f"{t['table']}_{ch['suffix']}".lower()] = (
                f"{t['table']}_{ch['suffix']}", ch['columns'], t['record'] + 'Id')
    found = {}
    for path in args.files:
        found.update(parse_ddl(open(path, encoding='utf-8-sig').read()))
    out = []
    for name, cols in found.items():
        if name.lower() not in spec:
            continue
        table, columns, pid = spec[name.lower()]
        have = {c.lower(): (c, typ) for c, typ in cols.items()}
        want = {c[0].lower(): c for c in columns}
        if pid:
            want[pid.lower()] = (pid, None, None, 'nvarchar(100)', '')
        missing = [want[c][0] for c in want if c not in have]
        extra = [have[c][0] for c in have if c not in want and not c.startswith('bpa_')]
        types = [f'{want[c][0]} ({have[c][1]} -> {sql_base(want[c][3])})' for c in want
                 if c in have and have[c][1] != sql_base(want[c][3])]
        out += ['', f'## {name}', '',
                f'- missing in your table: {", ".join(missing) or "none"}',
                f'- in your table, not in the spec (check against the REST metadata): {", ".join(extra) or "none"}',
                f'- different type (yours -> spec): {", ".join(types) or "none"}']
    not_found = [v[0] for k, v in spec.items() if k not in {n.lower() for n in found}]
    out += ['', f'Spec tables not in your scripts: {", ".join(not_found) or "none"}']
    print('\n'.join(out).lstrip())
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('sql')
    s.add_argument('which', choices=['full', 'children'], nargs='?', default='full')
    v = sub.add_parser('validate')
    v.add_argument('--export', help='NetSuite connector BusinessObjects export (REST metadata)')
    v.add_argument('--xsd-dir', help='folder with connector FROM-task schemas <record>.xsd (extra REST evidence)')
    v.add_argument('--bod-dir', default='netsuite/foundation')
    v.add_argument('--catalog-dir', help='folder with <record>.json from the metadata-catalog')
    v.add_argument('--report')
    c = sub.add_parser('check-ddl', help='compare your own CREATE TABLE scripts with the spec')
    c.add_argument('files', nargs='+')
    args = ap.parse_args()
    if args.cmd == 'sql':
        sys.stdout.write(sql_script(args.which))
        return 0
    if args.cmd == 'check-ddl':
        return check_ddl(args)
    return validate(args)


if __name__ == '__main__':
    sys.exit(main())
