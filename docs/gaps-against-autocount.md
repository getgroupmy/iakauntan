# Gaps against AutoCount Accounting 2.0

## What was read, and what was not

`wiki.autocountsoft.com`, `autocountsoft.com` and `my.autocountcloud.com`
are all blocked by the network egress proxy in this environment — every
one returns `403` on the CONNECT tunnel. **The wiki pages themselves were
not read.** The AutoCount side of this document comes from search-engine
indexes of those same pages (help-file menu listings, module pages,
knowledge-base articles). Treat it as an accurate shape of their
functional surface and a poor guide to their exact field names. Before
anything here is promised to a customer, confirm it against the live
pages from a machine that can reach them.

The **iAkauntan** side is not from summaries. Every claim below was
verified two ways:

- the live schema, queried directly (`information_schema`, `pg_proc`,
  `pg_enum`, `cron.job`) on project `ewwcgtnniwqndrzukksm`;
- a reference count of each table name in `app/lib`, which is what
  separates "the database can do this" from "a user can do this".

That second check is the one that matters, and it is why this revision
says something different from the last one.

> **Closed since this was written.** Document transfer landed in
> migrations `0081`–`0082` with a dialog on every document that has a
> next step. The section below is kept because it is the argument for
> why it was built first, and because the shape of the problem — screens
> that imply a capability the software does not have — is the one worth
> recognising again.

## The finding that mattered most

**The sales and purchase cycles were a chain in AutoCount and a set of
dead ends here.**

In AutoCount, a quotation is transferred to a sales order, the order to a
delivery order, the delivery order to an invoice — partially or in full,
with the quantities carried and the balance tracked. The same on the
purchase side: purchase order → goods received → bill. That transfer is
not a convenience feature; it *is* the sales module. It is what stops
somebody retyping an order, and it is what makes "what have we ordered
but not yet received" answerable.

iAkauntan has the storage for it and none of the behaviour:

| Column | Purpose | References in `app/lib` |
| --- | --- | --- |
| `sales_documents.parent_id` | the document this was transferred from | **0** |
| `sales_documents.fulfilment_status` | how much of it has been delivered | **0** |
| `purchase_document_lines.quantity_received` | received against this order line | **0** |
| `purchase_document_lines.quantity_billed` | billed against this order line | **0** |
| `sales_documents.original_invoice_id` | what a credit note credits | **0** |

There is no `transfer` function anywhere in the database and no
transfer action anywhere in the app. The Quotations, Sales Orders,
Delivery Orders, Purchase Orders and Goods Received screens all exist and
all terminate: you can create the document, and then you must retype it
as the next one. Every quantity in the two `quantity_*` columns above is
still zero in the live data, because nothing has ever written to them.

This is worse than a missing feature, because the screens imply the
capability. A user who raises a quotation reasonably expects to convert
it, finds no way to, and concludes the software is unfinished — which,
here, is the correct conclusion.

## Built in the database, unreachable from the app

Thirteen tables have **zero** references in `app/lib`. Some of those are
correct — `stock_movements`, `stock_levels` and `number_sequences` are
written by SECURITY DEFINER functions and never touched by the client by
design. The rest are capabilities nobody can reach:

| Capability | Tables in the schema | Callable? |
| --- | --- | --- |
| ~~Bank reconciliation~~ | `bank_reconciliations`, `bank_transactions` | Done — `0085` |
| ~~Multi-location stock~~ | `warehouses`, `stock_levels.warehouse_id` | Done — `0087` |
| ~~Stock adjustment / stock take~~ | `stock_adjustments`, `stock_adjustment_lines` | Done — `0087` |
| ~~Recurring journals~~ | `recurring_journals` | Done — `0088` |
| ~~Price levels~~ | `price_levels`, `item_prices` | Done — `0088` |
| ~~Project / department dimensions~~ | `gl_lines.project_code`, `.department_code` | Done — `0088`: a `projects` table, a picker on the document, and a P&L per job |
| **Sales agent** | `sales_documents.salesperson_id` | No UI, so no commission or agent report is possible |
| **Item categories** | `item_categories` | No UI |

Five document types are in the `sales_doc_type` / `purchase_doc_type`
enums with no screen: `proforma`, `refund_note`, `purchase_request`,
`purchase_debit_note`, and — the one that will be missed —
`purchase_return`.

## Revision, August 2026 — what has closed and what has not

The AutoCount side of this document still could not be read. Every
AutoCount domain is blocked by the network egress proxy in this
environment, including `accounting.autocountcloud.com`,
`help.accounting.autocountcloud.com`, `autocountsystem.com` and
`autocountsoft.com`. What follows about their product is from
search-engine snippets of those pages. **Confirm it from a machine that
can reach them before promising anything to a customer.**

The iAkauntan side is queried, not remembered: table and enum names from
`information_schema` and `pg_enum` on a database built from these
migrations, and a reference count in `app/lib` for anything claimed to
be reachable.

### Closed since the last revision

| Was missing | Now |
| --- | --- |
| Multi-location | `warehouses` plus `stock_transfers` (`0265`), with goods in transit through 1320 and a receiving discrepancy |
| Serial and batch tracking | `0106`, extended by `0267` and `0269` to every movement source — recipes, transfers, conversions, credit notes |
| Stock assembly / BOM | `0133` manufacturing, plus `0265` conversions and `0264` recipes |
| Sales agent | `salespeople`, reached from the document editor and the shell |
| Document approval workflow | `approval_rules`, `approval_steps`, `approval_requests` |
| What a credit note credits | `0269`. `original_invoice_id` had **0** references when this document was first written and still had 0 in August 2026; `credit_sales_invoice` is the first thing ever to write it |

### Half done, and the half that is missing matters

**Multi-UOM.** `ref_uom_factors`, `item_uom_packs` and `app.uom_qty`
landed in `0264`, and `0265`–`0267` use them for recipes, transfers and
conversions. **Every caller is in the POS and stock code.** No sales or
purchase document converts: `post_sales_document` moves `l.quantity`
raw and never reads `l.uom_code`.

That is not currently wrong, because `line_draft.dart` copies the item's
own base unit onto every line and there is no unit picker — so the two
always agree. It becomes wrong the moment a picker is added, which is
exactly what "sell in cartons, stock in pieces" needs. The conversion
machinery exists; wiring it into the two document cycles is the
remaining work, and it must be done in the same commit as the picker.

**Item bundles.** `item_type` has had `bundle` since `0003`. It appears
in that check constraint and in `0103`'s import validator, and **nowhere
else** — no explosion, no pricing, no screen. This is the same
dead-end shape the document-transfer finding was about: an enum value
that implies a capability nobody built.

### Still nothing at all

No table, no column, no function — verified by querying for them:

| Missing | Who it stops |
| --- | --- |
| **Budgets** and budget-vs-actual | Anyone with a board |
| **AR/AP contra** | Trading, where a customer is also a supplier |
| **Customer/supplier deposits** | Trading and projects. AutoCount has a Deposit Note document type; there is no equivalent here, and `receipts.unapplied_amount` is not a deposit flow |
| **Landed cost** | Importers |
| **Post-dated cheque register** | Traditional trading. `receipts.cheque_date` exists and there is no maturity handling |
| **Cash flow forecast** | Everyone. The `forecast_*` tables are inventory replenishment and have nothing to do with cash |
| **Bank feed** | AutoCount Cloud syncs Maybank SME and UOB Business directly. This has CSV import into bank reconciliation, which is a different promise |

### Where the comparison stops being useful

AutoCount Cloud's headline additions over their own desktop product —
OCR document capture and direct e-Invoice submission — are both built
here, the OCR since `0085` and e-Invoice since `0015`. The remaining
overlap is ordinary bookkeeping depth, and the list above is all of it.

## Not in the schema at all

These have no table, no column and no function. They are genuine
build-from-nothing work:

| Missing | Why it matters | Who needs it |
| --- | --- | --- |
| ~~Fixed asset register and depreciation~~ | Done — `0084`. Capital allowances remain a separate exercise; this is the accounting charge | Everyone |
| **Budgets** | AutoCount has Budget Maintenance and budget-vs-actual reporting; iAkauntan has no budget anywhere | Anyone with a board |
| **AR/AP contra** | Offsetting a customer who is also a supplier. Common in Malaysian trading, and today it must be faked with a journal | Trading |
| ~~Credit control~~ | Done — `0086`. Off, warn or block, per company | Anyone extending credit |
| **Customer/supplier deposits** | `receipts.unapplied_amount` holds an advance, but there is no deposit entry, no forfeit, no application flow | Trading, projects |
| **Cash flow forecast** | AutoCount's Advanced Financial Report module leads on this; iAkauntan has no forward view at all | Everyone |
| **Multi-UOM** | `items` has a single `uom_code`. No conversion, so cartons and pieces cannot coexist | Distribution |
| **Serial and batch tracking** | Nothing. No serialised business can migrate | Electronics, pharma |
| **Stock assembly / BOM** | `stock_movement_type` has `assembly_in` and `assembly_out` and there is no assembly table to produce them | Light manufacturing |
| **Landed cost** | No apportionment of freight and duty onto item cost | Importers |
| **Post-dated cheques** | `receipts.cheque_date` exists; no PDC register, no maturity handling | Traditional trading |
| **Document approval workflow** | AutoCount sells this as a plug-in; iAkauntan has role gates but no per-document approval step | Larger SMEs |

## What iAkauntan has that AutoCount does not

Worth stating, because the gap list on its own reads as a deficit and the
product is not one:

- **LHDN e-Invoice built in**, including consolidation, submission,
  status polling and the TIN checks — not a bolt-on.
- **Payroll with the statutory engine asserted in CI** — EPF, SOCSO,
  EIS, PCB, HRD Corp, with tests that fail if a number moves.
- **Corporate secretarial**: registers, resolutions, SSM deadlines,
  signature workflow and scoped signing links for people outside the
  company.
- **CRM** — leads, pipeline, opportunities.
- **Multi-tenant SaaS with RLS**, module entitlements and a platform
  console. AutoCount 2.0 is per-installation desktop software.
- **Legal firm client accounts** with the client-money separation that
  practice requires.

The overlap is the accounting core. Everything above is where the
product is ahead, and none of it is what a migrating AutoCount user will
test first.

## The order to build in

Ranked by how many businesses each unblocks, not by size:

1. ~~**Document transfer.**~~ Done — `0081` and `0082`.
2. ~~**FX revaluation at period end.**~~ Done — `0083`, with a preview
   and a post button beside the fiscal years in Settings. Foreign
   **bank** balances are still outside it; see the migration for why.
3. ~~**Fixed assets and depreciation.**~~ Done — `0084`, with a register,
   straight-line and reducing-balance depreciation, and disposal.
4. ~~**Bank reconciliation.**~~ Done — `0085`, with CSV import,
   suggested matches and a reconciliation that refuses to close while it
   is out.
5. ~~**Credit control.**~~ Done — `0086`, off/warn/block per company.
6. ~~**Stock adjustment and warehouses.**~~ Done — `0087`.
7. ~~**Price levels, project/department dimensions, recurring journal
   UI.**~~ Done — `0088`.
8. **Multi-UOM, then serial/batch, then assembly.** Only if trading and
   light manufacturing are the target. These are real projects.

## Migration eligibility

A gap here is a client who cannot move:

| Client profile | Can they move today? |
| --- | --- |
| Services company, MYR only, no stock | Yes |
| Trading company, MYR, simple stock | Yes |
| Company invoicing in foreign currency | Yes |
| Anyone with fixed assets to depreciate | Yes |
| Anyone reconciling a bank account monthly | Yes |
| Distribution with cartons and pieces | No — until multi-UOM |
| Electronics, pharma, anything serialised | No — until serial tracking |
| Light manufacturing with a BOM | No — until assembly |
| Retail with a counter | No, and by choice |

The middle three rows are the change from the last revision of this
document. They are not exotic requirements; they are ordinary
bookkeeping, and each one is a company that cannot leave AutoCount.
