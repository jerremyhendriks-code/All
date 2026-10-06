# NetSuite vendor bills → staging

Loads vendor bill headers and lines from NetSuite (SuiteQL over REST, via the TaskCentre
Web Service Connector) into SQL Server staging tables with stored procedures, without the
SQL Connector tool.

| File | What |
|---|---|
| `suiteql/vendorbill_header.sql` | SuiteQL: one row per bill |
| `suiteql/vendorbill_lines.sql` | SuiteQL: expense, item and tax lines |
| `xsd/netsuite_vendorbill_header.xsd`, `xsd/netsuite_vendorbill_lines.xsd` | Response schemas for the Web Service Connector |
| `sql/netsuite_vendorbill_staging_tables.sql` | Creates `tb_Netsuite_VendorBill` / `tb_Netsuite_VendorBillLine`, or adds missing columns to existing ones |
| `sql/usp_Netsuite_VendorBill_Load.sql` | Loads one page of headers |
| `sql/usp_Netsuite_VendorBillLine_Load.sql` | Loads one page of lines |
| `sql/usp_Netsuite_VendorBill_Run.sql` | `BeginRun` (run start + `{{since}}`) and `Finalize` (removed lines, stale bills) |
| `tests/netsuite_vendorbill/test_vendorbill_load.sql` | End-to-end test; run in a scratch database |

## Install

Run in this order: `netsuite_vendorbill_staging_tables.sql`, then the three `usp_` scripts.
If the table script prints `Check ...` lines, an existing column has a different type than
the procedures expect. The load still works where SQL Server can convert implicitly, but
change those columns when convenient.

## TaskCentre task

1. **Database query:** `EXEC dbo.usp_Netsuite_VendorBill_BeginRun;` → store
   `run_started_at` and `since` in variables. (`@full_load = 1` for a full reload.)
2. **Header loop**, offset starting at 0:
   - Web Service Connector: `POST https://<account>.suitetalk.api.netsuite.com/services/rest/query/v1/suiteql?limit=1000&offset=<offset>`,
     header `Prefer: transient`, body `{"q": "<vendorbill_header.sql with {{since}} replaced>"}`,
     response schema `netsuite_vendorbill_header.xsd`.
   - Database query: `EXEC dbo.usp_Netsuite_VendorBill_Load @xml_text = <connector XML output>;`
     It returns `rows_in_page, rows_inserted, rows_updated, has_more, next_offset`:
     repeat with `offset = next_offset` while `has_more = 1`.
3. **Line loop:** same, with `vendorbill_lines.sql`, `netsuite_vendorbill_lines.xsd` and
   `usp_Netsuite_VendorBillLine_Load`, using the same `since`.
4. **Only if every page loaded without error:**
   `EXEC dbo.usp_Netsuite_VendorBill_Finalize @run_started_at = <run_started_at>;`

Passing the XML: bind it as a parameter if the step supports parameters. If it can only
build the SQL text, double every `'` in the XML first (memos contain apostrophes) and use
`@xml_text = N'...'`. The procedure accepts the XML with or without the `<?xml?>`
declaration and with or without the `WebSvcCon` namespace.

## Behaviour

- **Upsert, per page, all or nothing.** A missing or duplicate id, or a value that doesn't
  convert (date, number, T/F), fails the page with an error naming the bill and field;
  nothing from that page is written.
- **Omitted = NULL.** SuiteQL leaves NULL columns out of the JSON, so a field missing from
  an item clears that column on update.
- **Which bills.** Every open bill plus every bill modified since `since` (latest
  `last_modified` in staging minus one day). The old query took open bills only, so a bill
  that got paid simply stopped coming back and stayed "open" in staging forever.
- **`is_stale = 1`**: the bill is open in staging but the latest run didn't return it, so in
  NetSuite it's no longer open (paid, voided or deleted) and the other values may be out of
  date. A later run that returns it again clears the flag.
- **Removed lines.** `Finalize` deletes lines of bills that were reloaded in this run but
  whose line didn't come back.
- **Paging.** SuiteQL returns at most 1000 rows per page. Both queries `ORDER BY` an id, which
  offset paging needs to be stable.

## Things to check against your NetSuite account

The queries use standard SuiteQL fields, but accounts differ (features, permissions, SuiteTax).
Run each query once in a SuiteQL tool first; if a field errors, remove it there and in the XSD
(the procedures ignore elements they don't use, and missing ones become NULL).

- **`tranid` vs `transactionnumber`.** On vendor bills `tranid` is the *Reference No.* (the
  vendor's invoice number) and `transactionnumber` is NetSuite's own number. Yesterday's query
  mapped `tranid` to the bill number and `otherrefnum` (usually empty on bills) to the vendor
  invoice number; this version swaps that. Verify on a few bills.
- `ap_account_id` uses the mainline's `expenseaccount`, which holds the A/P account on bills.
- Line `account_id` / `base_amount` come from the primary accounting book's GL impact, so
  they're empty for bills that don't post yet (pending approval), apart from expense lines.
- Line amount signs: compare `SUM(amount)` per bill with `bill_total` after the first load.
- Custom fields (`custbody_...`, `custcol_...`): add them to the query, the XSD, the table
  column list and the procedure; the existing columns show the pattern.
