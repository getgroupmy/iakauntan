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

**This table is now entirely closed**, and the paragraph that stood
here is kept because it says what the sweep was: thirteen tables had
**zero** references in `app/lib` when it was run. Some of those were
correct — `stock_movements`, `stock_levels` and `number_sequences` are
written by SECURITY DEFINER functions and never touched by the client
by design — and the rest were capabilities nobody could reach. Every
one of them is struck through below, and the last two were struck by
*checking* rather than by building:

| Capability | Tables in the schema | Callable? |
| --- | --- | --- |
| ~~Bank reconciliation~~ | `bank_reconciliations`, `bank_transactions` | Done — `0085` |
| ~~Multi-location stock~~ | `warehouses`, `stock_levels.warehouse_id` | Done — `0087` |
| ~~Stock adjustment / stock take~~ | `stock_adjustments`, `stock_adjustment_lines` | Done — `0087` |
| ~~Recurring journals~~ | `recurring_journals` | Done — `0088` |
| ~~Price levels~~ | `price_levels`, `item_prices` | Done — `0088` |
| ~~Project / department dimensions~~ | `gl_lines.project_code`, `.department_code` | Done — `0088`: a `projects` table, a picker on the document, and a P&L per job |
| ~~Sales agent~~ | `sales_documents.salesperson_id` | Done — `salespeople`, reached from the document editor and the shell. The revision below already said so; this row did not, and a table that disagrees with the section under it is worse than either |
| ~~Item categories~~ | `item_categories` | Done — `item_categories.dart` and `item_categories_dialog.dart`, reached from the items screen |

**The five document types were four, and are now one.** `docTypes` in
`app/lib/src/features/documents/doc_types.dart` carries fourteen
entries, including `proforma`, `refund_note`, `purchase_request` and
`purchase_debit_note`; the router builds each address from that table,
so each has a screen.

The one left is **`purchase_return`**, and the line above calling it
"the one that will be missed" was wrong. Returning goods to a supplier
is not missing — it is done by a **purchase credit note**, which has a
screen, posts, and creates the stock movement whose type is literally
`purchase_return`. That is the `v_sign = -1` branch of
`post_purchase_document_internal`, and it is where the name in the
movement enum comes from.

So `app.purchase_doc_type.purchase_return` is a leftover: a numbering
prefix (`PRT-`) and nothing else. Nothing can post one —
`post_purchase_document_internal` refuses any type but `bill`,
`purchase_credit_note` and `purchase_debit_note`, by name and with a
sentence — so it cannot mis-post; it simply cannot be used. Building a
screen for it would be a second way to do what the credit note already
does, and the two would disagree about which one the supplier's
statement should match.

Each of these was checked by reading the code, not the claim. This
document was wrong about four of them, which is the failure mode it
shares with README's own list — `docs/unreachable.md` has the sweeps
that catch it.

**And this particular failure now has a gate.**
`scripts/check_document_types.py` runs on every push: every member of
`app.sales_doc_type` and `app.purchase_doc_type` has a `DocTypeMeta`
entry, or is named in the script with the reason it has none. It
refuses the other direction too — a screen for a document type the
database has no value for, which would be an insert refused by a check
constraint's message rather than a sentence — and it refuses an
exemption that has rotted either way: one for a type that no longer
exists, or one for a type that has a screen now and was left behind.
`purchase_return` is its single entry, and the number should go down.

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
| Multi-UOM in the document cycles | `0270`. `sales_document_lines.base_quantity` and the purchase equivalent, written by `app.calc_document_line`, and read by both posting functions for the movement and the cost. The unit picker landed in the same commit |
| Landed cost | `0271`. A run spreads freight, duty and insurance across the goods lines of posted bills by value or by count, adds the money to stock through a movement that carries value and no quantity, and takes it back off the account each charge was coded to. What was already sold keeps its share in the profit and loss, because the sale that carried it is posted |
| AR/AP contra | `0272`. A contra note settles outstanding invoices against outstanding bills for the same party through `payment_allocations`, so both subsidiary ledgers move and keep agreeing with their control accounts. Same contact, or two contacts carrying the same TIN |
| Customer and supplier deposits | `0273`. A deposit note holds money before there is a document for it: a customer's is a liability in 2125, a supplier's an asset in 1235, drawn down through `payment_allocations` as invoices and bills appear, then refunded or forfeited. An unapplied receipt used to credit Accounts Receivable, which showed a depositing customer as a debtor in credit and never showed the money as owed to anybody |
| Budgets and budget-vs-actual | `0274`. Per account per period against a fiscal year, optionally for one department, built from a previous year's actuals plus an uplift, and reported with the variance and whether it is favourable — which is not the same as whether it is positive |
| Post-dated cheque register | `0275`. A cheque dated in the future takes the document off the aged listing and sits in 1140 (or 2115 for one we wrote) until it clears, so the bank balance never counts money that cannot be drawn. Deposit, clear, bounce and hand-back, with a maturity list that surfaces the one nobody banked |
| Cash flow forecast | `0276`. Thirteen weeks by default from what the bank holds now, drawing on open invoices shifted by the lag each customer has actually taken, bills on their due date, post-dated cheques on theirs, recurring documents across the horizon, unpaid payroll, and the things only a person knows. `cash_runs_out_on` is the single number |
| Item bundles | `0277`. A bundle is a `pos_recipes` row sold off an invoice rather than a till: selling one explodes it, takes the parts off the shelf at their own weighted average and books that as the cost of sale, and a credit note puts them back at what they left at |

### Half done, and the half that is missing matters

Nothing. `0277` closed the last of these — `item_type = 'bundle'` had
sat in a check constraint for two hundred and seventy migrations with
no explosion, no pricing and no screen behind it.

### Still nothing at all

No table, no column, no function — verified by querying for them:

| Missing | Who it stops |
| --- | --- |
| **Bank feed — one connector** | See below. `0567` built everything around it; what is missing is the code that talks to a bank |

#### The bank feed, after `0567`

The table above said "no table, no column, no function". That is no
longer true, and what is left is narrower than it was.

`import_bank_transactions` was already feed-ready and nobody wrote it
that way on purpose: it refuses a line whose running balance does not
follow the one before it, and it skips a line already stored — keyed on
date, amount, description, reference **and** balance, with the balance
in the key so two identical withdrawals on one day both import while
the same line pasted twice does not. That is exactly the property a
feed needs and a CSV upload does not: a person chooses a range and
uploads it once, a feed re-delivers overlapping windows forever, and an
import without that key doubles every transaction in the overlap —
silently, and found at reconciliation.

`0567` adds what goes around it. `bank_feeds` holds the connection and
its credential, guarded the way `0107` and `0412` guard an LHDN private
key and an acquirer secret: RLS on with no policies, every privilege
revoked, written through a definer function behind `can_admin`, read
back only as "is one set". `bank_feed_runs` records every pull, because
the failure mode of a feed is silence rather than a wrong figure — a
token expires, the pulls stop, and the gap is found at month end.

**What is deliberately not written is a connector.** There is no
Maybank or UOB API access in the environment this was built in, no
credentials and no sandbox. A connector written against a guessed
response shape would be worse than none: it would look finished, and
the first thing anybody knew would be a statement imported wrongly.

So the remaining work is one edge function per bank: read `bank_feeds`,
fetch, hand the rows to `import_bank_transactions`, and call
`record_bank_feed_run` either way. Everything it needs is in place and
asserted in `supabase/tests/bank_feed.sql`.

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
| ~~Budgets~~ | Done — `0274`, per account per period, with the variance report and a build-from-last-year | Anyone with a board |
| ~~AR/AP contra~~ | Done — `0272`. A journal between the control accounts was the only way before it, and a journal leaves both aged listings wrong | Trading |
| ~~Credit control~~ | Done — `0086`. Off, warn or block, per company | Anyone extending credit |
| ~~Customer/supplier deposits~~ | Done — `0273`, with the application, refund and forfeit flows, and the balance sheet presentation an unapplied receipt never had | Trading, projects |
| ~~Cash flow forecast~~ | Done — `0276`, and it measures how late each customer actually pays rather than trusting the terms | Everyone |
| ~~Multi-UOM~~ | Done — `0264` for the conversion, `0270` for the document cycles. A line is written in any unit its dimension reaches or any pack the shop has set; the money is per that unit and the stock converts to the item's own | Distribution |
| ~~Serial and batch tracking~~ | Done — `0106`, extended by `0267` and `0269` to every movement source | Electronics, pharma |
| ~~Stock assembly / BOM~~ | Done — `0133` manufacturing, `0265` conversions, `0264` recipes | Light manufacturing |
| ~~Landed cost~~ | Done — `0271`, by value or by count, onto the stock that is still there | Importers |
| ~~Post-dated cheques~~ | Done — `0275`. `receipts.cheque_date` had never been read by anything; the register is its own document now | Traditional trading |
| ~~Document approval workflow~~ | Done — `0167`. `approval_rules`, `approval_steps` and `approval_requests`, with `approval_state` read by the document editor on every load. This row said "no table, no column, no function" while the closed table three sections above already named all three; corrected at `6207faa` after querying for them | Larger SMEs |

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
8. ~~**Multi-UOM, then serial/batch, then assembly.**~~ Done — `0264`
   and `0270` for units, `0106` and `0267` for serial and batch, `0133`
   and `0265` for assembly.

## Migration eligibility

A gap here is a client who cannot move:

| Client profile | Can they move today? |
| --- | --- |
| Services company, MYR only, no stock | Yes |
| Trading company, MYR, simple stock | Yes |
| Company invoicing in foreign currency | Yes |
| Anyone with fixed assets to depreciate | Yes |
| Anyone reconciling a bank account monthly | Yes |
| Distribution with cartons and pieces | Yes — `0270` |
| Electronics, pharma, anything serialised | Yes — `0106`, `0267` |
| Light manufacturing with a BOM | Yes — `0133`, `0265` |
| Retail with a counter | Yes — the POS, which AutoCount sells separately |

Every row in this table said yes for the first time in `0270`. The three
that changed — units, serial and batch, assembly — were the ones the
first revision of this document called real projects, and they were.
What is left is in "Still nothing at all" above: a bank feed. None of them
stops a migration; each of them is a thing somebody has to keep doing by
hand afterwards.
