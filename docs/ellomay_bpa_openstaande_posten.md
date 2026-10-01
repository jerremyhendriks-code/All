# Ellomay – BPA FROM tasks for openstaande posten

Open items (openstaande posten) are collected from four NetSuite transaction types.
Each type gets its own FROM task in the BPA NetSuite connector tool and its own
staging table:

| Side             | NetSuite record | Staging table              | Open amount field  |
|------------------|-----------------|----------------------------|--------------------|
| Debiteuren (AR)  | Invoice         | `tb_Netsuite_Invoice`      | `amountRemaining`  |
| Debiteuren (AR)  | Credit Memo     | `tb_Netsuite_CreditMemo`   | `unapplied`        |
| Crediteuren (AP) | Vendor Bill     | `tb_Netsuite_VendorBill`   | (existing table)   |
| Crediteuren (AP) | Vendor Credit   | `tb_Netsuite_VendorCredit` | `unApplied`        |

The new tables are created by `sql/create_netsuite_openstaande_posten.sql`.

## Search criteria per FROM task

Filter on status so only items that are still open come back. The connector uses
NetSuite's SOAP (SuiteTalk) API, so the status values are the SOAP enum values. The
connector screen may show them with a different label, such as "Invoice:Open".

| Record        | Status filter (anyOf)                    | Not open (excluded)                       |
|---------------|------------------------------------------|-------------------------------------------|
| Invoice       | `_invoiceOpen`                           | `_invoicePaidInFull`, `_invoicePendingApproval`, `_invoiceRejected`, `_invoiceVoided` |
| Credit Memo   | `_creditMemoOpen`                        | `_creditMemoFullyApplied`, `_creditMemoVoided` |
| Vendor Bill   | `_vendorBillOpen`                        | `_vendorBillPaidInFull`, `_vendorBillPendingApproval`, `_vendorBillRejected`, `_vendorBillCancelled` |
| Vendor Credit | `_vendorCreditOpen`                      | `_vendorCreditFullyApplied`               |

To check: decide whether Ellomay also counts **Pending Approval** bills or
invoices as open. They are excluded above because they don't post to the AP/AR
ledger yet.

If Ellomay uses OneWorld and only some subsidiaries are in scope, also filter on
`subsidiary`.

## Field mapping (FROM task → staging table)

The column layout is the same for all three new tables.

| Column              | Invoice            | Credit Memo        | Vendor Credit      |
|---------------------|--------------------|--------------------|--------------------|
| `id`                | `internalId`       | `internalId`       | `internalId`       |
| `tranId`            | `tranId`           | `tranId`           | `tranId`           |
| `status`            | `status`           | `status`           | `status` (if offered) |
| `entityId` / `entityName`         | `entity` (internalId / name) | `entity` | `entity` |
| `subsidiaryId` / `subsidiaryName` | `subsidiary`       | `subsidiary`       | `subsidiary`       |
| `accountId` / `accountName`       | `account` (A/R)    | `account` (A/R)    | `account` (A/P)    |
| `postingPeriodId` / `postingPeriodName` | `postingPeriod` | `postingPeriod` | `postingPeriod` |
| `currencyId` / `currencyName`     | `currency`         | `currency`         | `currency`         |
| `exchangeRate`      | `exchangeRate`     | `exchangeRate`     | `exchangeRate`     |
| `tranDate`          | `tranDate`         | `tranDate`         | `tranDate`         |
| `dueDate`           | `dueDate`          | — (leave empty)    | — (leave empty)    |
| `otherRefNum`       | `otherRefNum`      | `otherRefNum`      | — (leave empty)    |
| `memo`              | `memo`             | `memo`             | `memo`             |
| `total`             | `total`            | `total`            | `userTotal`        |
| `openAmount`        | `amountRemaining`  | `unapplied`        | `unApplied`        |
| `lastModifiedDate`  | `lastModifiedDate` | `lastModifiedDate` | `lastModifiedDate` |
| `loadDate`          | (not mapped, set by SQL Server) | ← | ← |

Reference fields (`entity`, `subsidiary`, `account`, `postingPeriod`, `currency`)
return an internalId and a name. Map both.

Amounts are in transaction currency. To report in EUR, multiply by `exchangeRate`
(an approximation; it ignores revaluation).

## Loading

The tables hold a snapshot of what is open right now. Per run:

1. Empty the staging table (`TRUNCATE TABLE dbo.tb_Netsuite_…`).
2. Run the FROM task with the status filter above.
3. Insert the rows into the staging table.

Without step 1, items that were paid or applied since the last run stay in the
table, because they no longer come back from the search.

## Still open

- `tb_Netsuite_VendorBill` already exists. Check that it has an open amount column
  and that its FROM task filters on `_vendorBillOpen`. NetSuite's Vendor Bill
  record has no `amountRemaining` field, so the open amount may have to come from a
  search column (`amountRemaining` in the transaction search results) or from
  `userTotal` minus payments.
- Once the four tables are loaded, they can be combined into one view of open
  items, with the sign set per side (invoice +, credit memo −; bill +, vendor credit −).
