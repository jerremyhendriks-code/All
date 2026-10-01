# Ellomay – BPA FROM tasks for openstaande posten

Open items (openstaande posten) come from four NetSuite transaction types:
vendorBill, invoice, creditMemo and vendorCredit. Each one is pulled with a FROM
task in the BPA NetSuite connector tool and loaded into `tb_Netsuite_*` staging
tables.

The schemas the connector produces are kept in `schemas/netsuite/`. The staging
tables are based on those schemas, not on NetSuite documentation.

| Object       | Schema checked | Staging tables |
|--------------|----------------|----------------|
| vendorBill   | yes            | `tb_Netsuite_VendorBill` (exists), `tb_Netsuite_VendorBill_Item`, `tb_Netsuite_VendorBill_Expense` |
| invoice      | not yet        | |
| creditMemo   | not yet        | |
| vendorCredit | not yet        | |

## How the connector returns data

Checked against `schemas/netsuite/vendorBill.xsd`:

- It uses the REST record API: reference fields are objects with `id` and `refName`,
  and sublists are collections (`totalResults`, `count`, `hasMore`, `offset`,
  `items[]`).
- Every value is typed as `xs:string`. `tc:OriginalType` holds the real type
  (`number`, `integer`, `boolean`, `string`). Booleans come through as
  `True`/`False`.
- Some references are expanded into the full record. In the vendorBill header,
  `entity` has 133 fields and `account` has 41. Staging keeps only `id` and
  `refName`.

## vendorBill

Header: 38 standard fields, 253 `custbody_*` fields, plus the references `entity`,
`subsidiary`, `currency`, `account`, `terms`, `approvalStatus` and the
collection `accountingBookDetail`.

Sublists, each in its own child table, keyed on `vendorBillId` + `line`:

| Sublist          | Fields                         | Child table                      |
|------------------|--------------------------------|----------------------------------|
| `item.items[]`   | 33 standard + 86 `custcol_*`, refs `item`, `taxCode` | `tb_Netsuite_VendorBill_Item`    |
| `expense.items[]`| 16 standard + 86 `custcol_*`, refs `account`, `taxCode`, `department` | `tb_Netsuite_VendorBill_Expense` |

The `custcol_*` fields come from localisation bundles (IL, IT nexil, ES SII,
withholding tax) and are not stored.

### Findings that affect open items

- **No open amount on the header.** The schema has `total`, `userTotal`,
  `taxTotal` and `discountAmount`, but no `amountRemaining`, `amountPaid` or
  `status`. A partly paid bill can't be told apart from an unpaid one using this
  record alone.
- **`documentStatus` is the only status field.** In the sample it is `A`, which is
  Open for a vendor bill. Paid in full is `B`. Pending approval and rejected are
  separate values; `approvalStatus` (id 2 = Approved) covers approval separately.
- **Missing header fields:** `postingPeriod`, `class`, `department` and `location`
  are not in the header schema. Check whether the connector can add them.
- **Line dimensions:** expense lines have `department` but no `class` or
  `location`. Item lines have none of the three.

The open amount could be derived from `total` minus what was applied by vendor
payments (`tb_Netsuite_VendorPayment`) and vendor credits. Alternatively the
connector may offer a search or SuiteQL operation that returns `amountRemaining`.
To be decided once all four schemas have been checked.
