"""
Generate tb_Netsuite_* staging tables from BPA NetSuite connector schemas.

Usage:
    python3 tools/generate_netsuite_tables.py schemas/netsuite/*.xsd

Writes one script per object to sql/netsuite/create_<object>.sql, containing the
header table plus one child table per sublist (a collection with items[]).

Rules (as agreed for tb_Netsuite_VendorBill):
- BPA_* control fields first, primary key on BPA_EntryID (newsequentialid), named
  DF_<table>_<field> defaults. Child rows link to the parent through BPA_ParentID.
- Standard fields in schema order. Types come from tc:OriginalType: number ->
  decimal, integer -> int, boolean -> bit, string -> nvarchar; date and timestamp
  fields are recognised by name.
- References are flattened to <name>Id + <name>RefName. A reference without an id
  (e.g. an address subrecord) has all its simple fields flattened to <name><Field>.
- Left out: SupplementaryReference (connector property), custom fields
  (custbody_, custcol_, custentity_, custrecord_, ...) except custrecord_* on
  custom records, accountingBookDetail, and collections without items[] (they
  carry no data, only paging counters).
"""
import os
import re
import sys
import xml.etree.ElementTree as ET

XS = '{http://www.w3.org/2001/XMLSchema}'
TC = '{http://www.orbis-software.com/ns/tcschemaextensions}'
COLLECTION_FIELDS = {'count', 'hasMore', 'offset', 'totalResults'}
SKIPPED_COLLECTIONS = {'accountingBookDetail'}
TABLE_NAMES = {'customrecord_2663_entity_bank_details': 'EntityBankDetails'}

TIMESTAMP_FIELDS = {'createdDate', 'lastModifiedDate', 'dateCreated', 'created',
                    'lastmodified', 'lineCreatedDate', 'lineLastModifiedDate'}
LONG_TEXT = re.compile(r'(memo|message|comments|description|address|_text|override|options|trackingNumbers)$', re.I)
CUSTOM_FIELD = re.compile(r'^cust(body|col|entity|record|event|item|itemnumber)_')
PRECISE_NUMBER = re.compile(r'(rate\d*|quantity\w*|qty|latitude|longitude)$', re.I)

BPA_COLUMNS = [
    ('BPA_Origin', 'nvarchar(50)', None),
    ('BPA_Direction', 'nvarchar(50)', None),
    ('BPA_Company', 'nvarchar(50)', None),
    ('BPA_EntryID', 'uniqueidentifier', ('EntryID', '(newsequentialid())')),
    ('BPA_ParentID', 'uniqueidentifier', None),
    ('BPA_Status', 'int', ('Status', '((0))')),
    ('BPA_Reference', 'nvarchar(50)', None),
    ('BPA_Reference_Description', 'nvarchar(100)', None),
    ('BPA_Reference2', 'nvarchar(50)', None),
    ('BPA_Reference2_Description', 'nvarchar(100)', None),
    ('BPA_Action', 'nvarchar(1)', None),
    ('BPA_ReturnedID', 'nvarchar(50)', None),
    ('BPA_Syscreated', 'datetime', ('Syscreated', '(getdate())')),
    ('BPA_Sysmodified', 'datetime', ('Sysmodified', '(getdate())')),
    ('BPA_Syscreator', 'nvarchar(50)', None),
    ('BPA_Error', 'nvarchar(max)', None),
    ('BPA_Error_Extended', 'nvarchar(max)', None),
    ('BPA_Description', 'nvarchar(255)', None),
    ('BPA_Failcount', 'int', ('Failcount', '((0))')),
    ('BPA_Orig_Entryid', 'uniqueidentifier', None),
    ('BPA_TaskInstanceID', 'int', None),
    ('BPA_TaskID', 'int', None),
]


def kids(e):
    return e.findall(f'{XS}complexType/{XS}sequence/{XS}element')


def pascal(name):
    return ''.join(p[:1].upper() + p[1:] for p in re.split(r'_+', name) if p)


def sql_type(name, original):
    if original == 'boolean':
        return 'bit'
    if original == 'integer':
        return 'int'
    if original == 'number':
        return 'decimal(28,10)' if PRECISE_NUMBER.search(name) else 'decimal(19,4)'
    if name in TIMESTAMP_FIELDS:
        return 'datetime2(3)'
    if name.endswith('Date'):
        return 'date'
    if LONG_TEXT.search(name):
        return 'nvarchar(4000)'
    return 'nvarchar(255)'


class Table:
    def __init__(self, name, source, is_child):
        self.name, self.source, self.is_child = name, source, is_child
        self.columns, self.skipped = [], []

    def add(self, col, typ, nullable=True):
        if any(c[0].lower() == col.lower() for c in self.columns):
            raise SystemExit(f'{self.name}: duplicate column {col}')
        self.columns.append((col, typ, nullable))


def is_collection(el):
    return bool({k.get('name') for k in kids(el)} & COLLECTION_FIELDS)


def build(el, table, tables, keep_custom, top_level):
    for k in kids(el):
        name = k.get('name')
        sub = kids(k)
        custom = bool(CUSTOM_FIELD.match(name)) and not (keep_custom and name.startswith('custrecord_'))
        if name == 'SupplementaryReference':
            continue
        if custom:
            table.skipped.append(name)
            continue
        if not sub:
            typ = sql_type(name, k.get(TC + 'OriginalType'))
            if top_level and name == 'id':
                table.add('id', 'nvarchar(100)', nullable=False)
            else:
                table.add(name, typ)
            continue
        if is_collection(k):
            items = [s for s in sub if s.get('name') == 'items']
            if name in SKIPPED_COLLECTIONS or not items:
                table.skipped.append(name + ('' if items else ' (no items)'))
                continue
            child = Table(f'{table.name}_{pascal(name)}', f'{table.source}.{name}.items[]', True)
            tables.append(child)
            build(items[0], child, tables, keep_custom, False)
            continue
        fields = {s.get('name'): s for s in sub if not kids(s)}
        if 'id' in fields:
            table.add(name + 'Id', 'nvarchar(255)')
            if 'refName' in fields:
                table.add(name + 'RefName', 'nvarchar(255)')
        else:
            for fname, f in fields.items():
                if CUSTOM_FIELD.match(fname):
                    continue
                table.add(name + fname[:1].upper() + fname[1:], sql_type(fname, f.get(TC + 'OriginalType')))


def render_table(t):
    lines = []
    width = max(len(c[0]) for c in BPA_COLUMNS + t.columns)
    for col, typ, suffix_default in BPA_COLUMNS:
        null = 'NOT NULL' if col == 'BPA_EntryID' else 'NULL'
        default = ''
        if suffix_default:
            default = f' CONSTRAINT DF_{t.name}_{suffix_default[0]} DEFAULT {suffix_default[1]}'
        lines.append(f'    {col:<{width}} {typ:<16} {null}{default},')
    for col, typ, nullable in t.columns:
        lines.append(f'    {col:<{width}} {typ:<16} {"NULL" if nullable else "NOT NULL"},')
    lines.append(f'    CONSTRAINT PK_{t.name} PRIMARY KEY CLUSTERED (BPA_EntryID)')
    out = [f"EXEC #rebuild N'{t.name}';", f'CREATE TABLE dbo.{t.name} (', *lines, ');']
    if t.is_child:
        out.append(f'CREATE NONCLUSTERED INDEX IX_{t.name}_ParentID ON dbo.{t.name} (BPA_ParentID);')
    out.append(f"PRINT N'Created  dbo.{t.name}';")
    return '\n'.join(out)


REBUILD_PROC = """IF OBJECT_ID(N'tempdb..#rebuild') IS NOT NULL DROP PROCEDURE #rebuild;
GO
-- Renames an existing table to <table>_bak (constraints get a _bak suffix too),
-- so the new definition can be created without losing data.
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
END
GO"""


def generate(path):
    root = ET.parse(path).getroot()
    top = root.find(f'{XS}element/{XS}complexType/{XS}sequence/{XS}element')
    obj = top.get('name')
    keep_custom = obj.startswith('customrecord')
    header = Table('tb_Netsuite_' + TABLE_NAMES.get(obj, pascal(obj)), obj, False)
    tables = [header]
    build(top, header, tables, keep_custom, True)

    doc = [f'/*',
           f'    Staging tables for the NetSuite {obj} object, generated by',
           f'    tools/generate_netsuite_tables.py from schemas/netsuite/{os.path.basename(path)}.',
           f'    Do not edit by hand: change the schema or the generator and regenerate.',
           f'']
    for t in tables:
        doc.append(f'    dbo.{t.name:<40} {t.source}' + ('   (BPA_ParentID -> parent BPA_EntryID)' if t.is_child else ''))
    doc.append('')
    for t in tables:
        if t.skipped:
            customs = [s for s in t.skipped if CUSTOM_FIELD.match(s)]
            others = [s for s in t.skipped if not CUSTOM_FIELD.match(s)]
            parts = ([f'{len(customs)} custom fields'] if customs else []) + others
            doc.append(f'    Left out of {t.name}: ' + ', '.join(parts))
    doc += ['',
            '    Existing tables are renamed to <table>_bak (constraints included) before the',
            '    new ones are created; drop the _bak tables once loading works. Stops without',
            '    changes if a _bak table already exists. Runs in a single transaction.',
            '*/',
            'SET XACT_ABORT ON;',
            'SET NOCOUNT ON;',
            REBUILD_PROC,
            'BEGIN TRANSACTION;',
            '']
    body = '\n\n'.join(render_table(t) for t in tables)
    tail = '\n\nCOMMIT TRANSACTION;\nGO\nDROP PROCEDURE #rebuild;\nGO\n'
    out = os.path.join('sql', 'netsuite', f'create_{obj}.sql')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(doc) + '\n' + body + tail)
    print(f'{out}: ' + ', '.join(f'{t.name} ({len(t.columns)} cols)' for t in tables))


if __name__ == '__main__':
    for p in sys.argv[1:]:
        generate(p)
