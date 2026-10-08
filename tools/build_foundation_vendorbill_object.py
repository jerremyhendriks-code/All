"""Build the Foundation Group vendorBill NetSuite connector object.

Takes the vendorBill object of the Ellomay connector export as the template
(netsuite/NetSuiteConnector_BusinessObjects_Ellomay.xml, branch
claude/elegant-clarke-ysmfjh) and writes a single-object BusinessObjects file:
Ellomay custom fields removed, Foundation Group fields from the BOD added, the
expense sublist added and references reduced to id + refName.

usage: build_foundation_vendorbill_object.py <ellomay export xml> <output xml>
"""
import copy
import sys
import xml.etree.ElementTree as ET

XSI = 'http://www.w3.org/2001/XMLSchema-instance'
ET.register_namespace('p2', XSI)

src = ET.parse(sys.argv[1]).getroot()
obj = {o.findtext('Name'): o for o in src}
vb = copy.deepcopy(obj['vendorBill'])

# ---------------------------------------------------------------- field lists
HEADER_SELECTED = [
    'id', 'externalId', 'tranId', 'transactionNumber', 'tranDate', 'dueDate',
    'createdDate', 'lastModifiedDate', 'entity', 'subsidiary', 'currency',
    'exchangeRate', 'account', 'postingPeriod', 'terms', 'approvalStatus', 'status',
    'memo', 'total', 'userTotal', 'taxTotal', 'discountAmount', 'discountDate',
    'department', 'class', 'location', 'paymentHold', 'received', 'toBePrinted',
    'vatRegNum', 'billAddressee', 'billAttention', 'billAddr1', 'billAddr2',
    'billAddr3', 'billCity', 'billState', 'billZip', 'billCountry', 'billAddress',
    'expense', 'item',
]
# Foundation Group custom body fields (from the vendorbill BOD).
# name -> type; 'nsResource' = select / list / record reference
HEADER_CUSTOM = {
    'cseg_bit_4weeks': 'nsResource',
    'custbody_document_date': 'string',
    'custbody_establishment_code': 'string',
    'custbody_15529_vendor_entity_bank': 'nsResource',
    'custbody_11187_pref_entity_bank': 'nsResource',
    'custbody_9997_is_for_ep_eft': 'boolean',
    'custbody_11724_pay_bank_fees': 'boolean',
    'custbody_stc_amount_after_discount': 'number',
    'custbody_stc_tax_after_discount': 'number',
    'custbody_stc_total_after_discount': 'number',
    'custbody_stc_discountpercent': 'number',
    'custbody_stc_daysuntilexpiry': 'integer',
    'custbody_stc_payment_transaction_id': 'string',
}
# expense/items fields: name -> (type, complex, collection, selected)
EXPENSE_FIELDS = {
    'account': ('account', True, False, True),
    'amortizationEndDate': ('string', False, False, True),
    'amortizationResidual': ('string', False, False, True),
    'amortizationSched': ('nsResource', True, False, True),
    'amortizStartDate': ('string', False, False, True),
    'amount': ('number', False, False, True),
    'category': ('nsResource', True, False, True),
    'class': ('classification', True, False, True),
    'customer': ('nsResource', True, False, True),
    'department': ('department', True, False, True),
    'grossAmt': ('number', False, False, True),
    'isBillable': ('boolean', False, False, True),
    'line': ('integer', False, False, True),
    'links': ('nsLink', True, True, False),
    'location': ('location', True, False, True),
    'memo': ('string', False, False, True),
    'orderDoc': ('string', False, False, True),
    'orderLine': ('string', False, False, True),
    'refName': ('string', False, False, False),
    'tax1Amt': ('number', False, False, True),
    'taxCode': ('nsResource', True, False, True),
    'taxRate1': ('number', False, False, True),
    'cseg_investment_cat': ('nsResource', True, False, True),
    'custcol_far_trn_relatedasset': ('nsResource', True, False, True),
    'custcol_nl_wkr_category': ('nsResource', True, False, True),
    'custcol_nondeductible_account': ('nsResource', True, False, True),
}
# item/items fields (Ellomay vendorBill FROM schema + FG item sublist; FG has no location on item lines)
ITEM_FIELDS = {
    'amortizationEndDate': ('string', False, False, True),
    'amortizationResidual': ('string', False, False, True),
    'amortizStartDate': ('string', False, False, True),
    'amount': ('number', False, False, True),
    'class': ('classification', True, False, True),
    'customer': ('nsResource', True, False, True),
    'department': ('department', True, False, True),
    'description': ('string', False, False, True),
    'grossAmt': ('number', False, False, True),
    'isBillable': ('boolean', False, False, True),
    'item': ('nsResource', True, False, True),
    'line': ('integer', False, False, True),
    'links': ('nsLink', True, True, False),
    'orderLine': ('integer', False, False, True),
    'quantity': ('number', False, False, True),
    'rate': ('number', False, False, True),
    'refName': ('string', False, False, False),
    'tax1Amt': ('number', False, False, True),
    'taxCode': ('nsResource', True, False, True),
    'taxRate1': ('number', False, False, True),
    'uniqueKey': ('integer', False, False, True),
    'units': ('string', False, False, True),
    'vendorName': ('string', False, False, True),
}
CUSTOM_PREFIXES = ('custbody', 'custcol', 'custentity', 'custrecord', 'custitem', 'custevent', 'cseg')
REF_FIELDS = {'id', 'refName'}   # only select what the REST response holds without expanding

# ---------------------------------------------------------------- helpers
def el(tag, text=None):
    e = ET.Element(tag)
    if text is not None:
        e.text = text
    return e

def togglable(name, typ, complex_, collection=False, selected=True, nullable=None):
    f = el('NetSuiteTogglableField')
    if nullable is None:
        nullable = not complex_
    for tag, val in [('Args', None), ('FieldName', name), ('DisplayName', name), ('TypeName', typ),
                     ('IsNullable', str(nullable).lower()), ('IsRequired', 'false'),
                     ('IsComplexType', str(complex_).lower()), ('ParamType', 'Querystring'),
                     ('Methods', None), ('OneOfs', None), ('IsCollection', str(collection).lower()),
                     ('SupportsPagination', 'false'), ('IsInternalPaginationField', 'false'),
                     ('UpdateOnNull', 'false'), ('ListItemName', name),
                     ('IsSelected', str(selected).lower()), ('IsHidden', 'false')]:
        f.append(el(tag, val))
    return f

def op_field(tf):
    """NetSuiteField (operation detail) from a NetSuiteTogglableField."""
    f = el('NetSuiteField')
    for tag in ('FieldName', 'DisplayName', 'TypeName', 'IsNullable', 'IsComplexType',
                'IsCollection', 'SupportsPagination', 'ListItemName'):
        f.append(el(tag, tf.findtext(tag)))
    return f

def drop_custom(c):
    """Remove another account's custom fields from a copied child object."""
    fl = c.find('Fields')
    for f in list(fl):
        if f.findtext('FieldName').startswith(CUSTOM_PREFIXES):
            fl.remove(f)
    return c

def set_selected(fields, keep):
    for f in fields:
        f.find('IsSelected').text = 'true' if f.findtext('FieldName') in keep else 'false'

def child(name, list_item, parent, fields, child_type='', collection=False, children=()):
    c = ET.Element('BaseDesignerStructure', {f'{{{XSI}}}type': 'NetSuiteChildObject'})
    c.append(el('Name', name))
    cs = el('ChildStructures')
    for ch in children:
        cs.append(ch)
    c.append(cs)
    for tag, val in [('ListItemName', list_item), ('ParentObjectName', parent),
                     ('ChildObjectName', list_item), ('IsCollection', str(collection).lower()),
                     ('SupportsPagination', 'false'), ('Args', None)]:
        c.append(el(tag, val))
    fl = el('Fields')
    for f in fields:
        fl.append(f)
    c.append(fl)
    c.append(el('ChildObjectType', child_type or None))
    return c

def ns_resource(field, parent):
    """Reference child holding the plain {id, refName} the REST record returns."""
    tmpl = [c for c in obj['vendorBill'].find('ChildStructures') if c.findtext('Name') == 'subsidiary_nsResource'][0]
    fields = copy.deepcopy(list(tmpl.find('Fields')))
    set_selected(fields, REF_FIELDS)
    return child(f'{field}_nsResource', field, parent, fields, 'nsResource')

def record_ref(template, parent):
    """Full-record reference child (department, account, ...) with only id/refName selected."""
    c = drop_custom(copy.deepcopy(template))
    c.find('ParentObjectName').text = parent
    set_selected(c.find('Fields'), REF_FIELDS)
    return c

def find_child(o, name):
    return [c for c in o.find('ChildStructures') if c.findtext('Name') == name][0]

# ---------------------------------------------------------------- top-level fields
ell_fields = {f.findtext('FieldName'): f for f in vb.find('Fields')}
std = [f for n, f in ell_fields.items() if not n.startswith(CUSTOM_PREFIXES)]
missing = set(HEADER_SELECTED) - {f.findtext('FieldName') for f in std}
assert not missing, missing
fields = []
for f in std:
    f = copy.deepcopy(f)
    f.find('IsSelected').text = 'true' if f.findtext('FieldName') in HEADER_SELECTED else 'false'
    fields.append(f)
for name, typ in HEADER_CUSTOM.items():
    if name in ell_fields and ell_fields[name].findtext('TypeName') == typ:
        f = copy.deepcopy(ell_fields[name])          # same SuiteApp field as in Ellomay
        f.find('IsSelected').text = 'true'
    else:
        f = togglable(name, typ, typ == 'nsResource', nullable=(typ not in ('nsResource', 'boolean')))
    fields.append(f)
fields.sort(key=lambda f: f.findtext('FieldName').lower())

top = vb.find('Fields')
for f in list(top):
    top.remove(f)
for f in fields:
    top.append(f)

# operations: same field set (NetSuiteField form)
for op in vb.find('OperationDetails'):
    ofl = op.find('Fields')
    for f in list(ofl):
        ofl.remove(f)
    for f in fields:
        ofl.append(op_field(f))

# ---------------------------------------------------------------- child structures
ell_children = {c.findtext('Name'): c for c in obj['vendorBill'].find('ChildStructures')}
inv_items = find_child(find_child(obj['invoice'], 'item'), 'items')
je_items = find_child(find_child(obj['journalEntry'], 'line'), 'items')

REF_TEMPLATES = {
    'account': find_child(je_items, 'account'),
    'department': find_child(inv_items, 'department'),
    'class': find_child(inv_items, 'class'),
    'location': find_child(inv_items, 'location'),
}


def sublist(name, spec):
    """<name> wrapper (count, hasMore, offset, totalResults) -> items collection -> references."""
    item_fields = [togglable(n, t, cx, coll, sel)
                   for n, (t, cx, coll, sel) in sorted(spec.items(), key=lambda kv: kv[0].lower())]
    refs = [record_ref(REF_TEMPLATES[n], 'items') for n in REF_TEMPLATES if n in spec]
    refs += [ns_resource(n, 'items') for n, (t, *_rest) in spec.items() if t == 'nsResource']
    items = child('items', 'items', name, item_fields, collection=True, children=refs)
    wrapper_fields = copy.deepcopy(list(find_child(obj['journalEntry'], 'line').find('Fields')))
    for f in wrapper_fields:
        if f.findtext('FieldName') == 'items':
            f.find('TypeName').text = f'vendorBill-{name}Element'
    set_selected(wrapper_fields, {'count', 'hasMore', 'items', 'offset', 'totalResults'})
    return child(name, name, 'vendorBill', wrapper_fields, children=[items]), item_fields, refs


expense, exp_item_fields, exp_children = sublist('expense', EXPENSE_FIELDS)
item, itm_item_fields, itm_children = sublist('item', ITEM_FIELDS)

entity = drop_custom(copy.deepcopy(ell_children['entity_vendor']))
set_selected(entity.find('Fields'), REF_FIELDS)

def object_ref(name):          # 'object'-typed fields (approvalStatus, status, billCountry)
    c = copy.deepcopy(ell_children['approvalStatus'])
    c.find('Name').text = c.find('ListItemName').text = c.find('ChildObjectName').text = name
    return c

new_children = [
    entity,
    record_ref(ell_children['subsidiary_nsResource'], 'vendorBill'),
    record_ref(ell_children['currency'], 'vendorBill'),
    record_ref(ell_children['postingPeriod'], 'vendorBill'),
    record_ref(ell_children['account'], 'vendorBill'),
    record_ref(ell_children['terms'], 'vendorBill'),
    record_ref(ell_children['approvalStatus'], 'vendorBill'),
    object_ref('status'),
    record_ref(ell_children['department'], 'vendorBill'),
    record_ref(ell_children['class'], 'vendorBill'),
    record_ref(ell_children['location'], 'vendorBill'),
    object_ref('billCountry'),
] + [ns_resource(n, 'vendorBill') for n, t in HEADER_CUSTOM.items() if t == 'nsResource'] + [expense, item]

cs = vb.find('ChildStructures')
for c in list(cs):
    cs.remove(c)
for c in new_children:
    cs.append(c)

# ---------------------------------------------------------------- write
out = ET.Element('ArrayOfAnyType')
vb.attrib.clear()
vb.set(f'{{{XSI}}}type', 'NetSuiteCatalogObj')
out.append(vb)
ET.indent(out, space='  ')
ET.ElementTree(out).write(sys.argv[2], encoding='utf-8', xml_declaration=False)

sel = [f.findtext('FieldName') for f in fields if f.findtext('IsSelected') == 'true']
print(f'top-level fields: {len(fields)} ({len(sel)} selected)')
print(f'operations: {[op.findtext("OperationName") for op in vb.find("OperationDetails")]}')
print(f'children: {[c.findtext("Name") for c in cs]}')
print(f'expense items: {len(exp_item_fields)} fields, children {[c.findtext("Name") for c in exp_children]}')
print(f'item items: {len(itm_item_fields)} fields, children {[c.findtext("Name") for c in itm_children]}')
