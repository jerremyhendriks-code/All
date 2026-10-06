# NetSuite vendor bills → staging

Loads vendor bill headers and lines from NetSuite (SuiteQL over REST, via the TaskCentre
Web Service Connector) into SQL Server staging tables with the generic `dbo.BPA_ImportXml`.

| File | What |
|---|---|
| `suiteql/vendorbill_header.sql` | SuiteQL: one row per bill |
| `suiteql/vendorbill_lines.sql` | SuiteQL: expense, item and tax lines |
| `xsd/netsuite_vendorbill_header.xsd`, `xsd/netsuite_vendorbill_lines.xsd` | Response schemas for the Web Service Connector |
| `sql/usp_Netsuite_VendorBill_ImportXml.sql` | Imports one page (the connector's XML string), headers or lines, through `BPA_ImportXml` |
| `sql/netsuite_vendorbill_bpa_setup.sql` | Creates `tb_Netsuite_VendorBill` / `tb_Netsuite_VendorBillLine` through `BPA_ImportXml`, plus the views `vw_Netsuite_VendorBill` / `vw_Netsuite_VendorBillLine` |
| `tests/netsuite_vendorbill/test_bpa_import.sql` | End-to-end test; run in a scratch database that has `BPA_ImportXml` (it empties both tables) |

## Install

Run `sql/netsuite_vendorbill_bpa_setup.sql`, then `sql/usp_Netsuite_VendorBill_ImportXml.sql`, in `BPAStaging`.

`BPA_ImportXml` can't insert into a hand-made table with `NOT NULL` columns it doesn't fill
(like a `tb_Netsuite_VendorBill` with a `NOT NULL [id]`). It also turns existing typed columns
into `nvarchar(max)`, and fails on typed columns that are in an index. The setup script
therefore stops, without changing anything, if either table name already exists as a
non-BPA table. Rename or drop that table first.

## TaskCentre task

1. **`{{since}}` for both queries:**
   ```sql
   SELECT since = CONVERT(char(19), ISNULL(DATEADD(day, -1, MAX(last_modified)), '19000101'), 120)
   FROM dbo.vw_Netsuite_VendorBill;
   ```
2. **Header loop**, offset starting at 0:
   - Web Service Connector: `POST https://<account>.suitetalk.api.netsuite.com/services/rest/query/v1/suiteql?limit=1000&offset=<offset>`,
     header `Prefer: transient`, body `{"q": "<vendorbill_header.sql with {{since}} filled in>"}`,
     response schema `netsuite_vendorbill_header.xsd`.
   - Database step:
     ```sql
     EXEC dbo.usp_Netsuite_VendorBill_ImportXml @XmlText = N'<connector XML output>', @RecordType = N'header';
     ```
     It returns `record_type, rows_imported, lines_linked, has_more, next_offset`:
     repeat with `offset = next_offset` while `has_more = 1`.
3. **Line loop**, after the header loop: same, with `vendorbill_lines.sql`,
   `netsuite_vendorbill_lines.xsd`, the same `since`, and `@RecordType = N'lines'`.

### What `usp_Netsuite_VendorBill_ImportXml` does

- Takes the XML as text, with or without the `<?xml?>` declaration and with or without
  the `WebSvcCon` namespace or a wrapper around `<root>`.
- Recognises headers and lines by their fields (lines have `line_id`). `@RecordType` is
  optional; when given, a page of the other kind is refused (error 50305).
- Skips a page without `<items>` (`count = 0`). Calling `BPA_ImportXml` directly on such a
  page would import `<links>` as records (a junk row plus `rel` / `href` columns).
- Refuses a page with an item without `vendor_bill_id`, or a line without `line_id`.
- Calls `BPA_ImportXml` with `@RecordPath = 'items'`, `@BPA_Origin = 'NetSuite'` and
  `@BPA_ReferenceField = 'vendor_bill_id'`, so `BPA_Reference` holds the bill id.
- Sets each imported line's `BPA_ParentID` to the `BPA_EntryID` of the latest imported header
  row of its bill. That's why the header loop must run first.
- All or nothing per page: on any error, nothing from that page stays in staging.

**Passing the string.** If the database step supports parameters, bind the connector output to
`@XmlText`. If it can only build the SQL text, double every `'` in the XML first (memos
contain apostrophes) and keep the `N` prefix so non-ASCII characters (`Müller`) survive.

## Raw tables and views

- **Raw tables** (`tb_Netsuite_VendorBill`, `tb_Netsuite_VendorBillLine`) have the
  BPA columns plus one `nvarchar(max)` column per SuiteQL field and an `@Array` column (from
  the connector's `Array="true"`). Every import inserts new rows; nothing is updated or
  deleted. Each run therefore adds a row for every open bill. `BPA_Reference` holds the
  NetSuite bill id. A line row's `BPA_ParentID` points at the header row it was imported
  with.
- **`vw_Netsuite_VendorBill`**: the latest imported row per bill, typed (dates, decimals,
  bits, ids as `nvarchar(100)`), plus `last_imported_at`, `bpa_entry_id`, `bpa_status`.
- **`vw_Netsuite_VendorBillLine`**: for each bill, the lines imported at or after that bill's
  latest header import, latest row per line, typed. Lines removed from a bill in NetSuite
  aren't returned again, so they drop out of the view at the next import of that bill.

The views convert with `TRY_CONVERT`, so a value that doesn't convert becomes NULL rather
than an error. The raw column keeps the original text.

**Bills that are no longer open.** The queries return every open bill plus every bill
modified since `since`. A bill that gets paid without being modified stops being returned and
keeps its last (open) state in the view. You can recognise it by `last_imported_at` being
older than the start of the latest run.

**Growth.** The raw tables grow by roughly the number of open bills per run. Clean up rows
that are no longer the latest per bill once the BPA flow has processed them, e.g. by
`BPA_Status` and age.

## Things to check against your NetSuite account

The queries use standard SuiteQL fields, but accounts differ (features, permissions, SuiteTax).
Run each query once in a SuiteQL tool first; if a field errors, remove it from the query and
from the setup script's template and views.

- **`tranid` vs `transactionnumber`.** On vendor bills `tranid` is the *Reference No.* (the
  vendor's invoice number) and `transactionnumber` is NetSuite's own number. The original
  query mapped `tranid` to the bill number and `otherrefnum` (usually empty on bills) to the
  vendor invoice number; this version swaps that. Verify on a few bills.
- `ap_account_id` uses the mainline's `expenseaccount`, which holds the A/P account on bills.
- Line `account_id` / `base_amount` come from the primary accounting book's GL impact, so
  they're empty for bills that don't post yet (pending approval), apart from expense lines.
- Line amount signs: compare `SUM(amount)` per bill with `bill_total` after the first load.
- Custom fields (`custbody_...`, `custcol_...`): add them to the query. `BPA_ImportXml` adds
  the column by itself; add them to the views if you want them typed there.
