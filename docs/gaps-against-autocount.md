# Gaps against AutoCount Cloud

## Where this came from

`my.autocountcloud.com` is blocked by the network egress proxy in the
environment this was researched in, so **the page was not read.** The
AutoCount feature list below comes from search-engine summaries of
AutoCount's own marketing pages (`autocountsoft.com`,
`autocountsystem.com`) and reseller sites. Treat it as the shape of their
offering, not as a specification — plan comparisons and module names
should be confirmed against a live plan page before anything is promised
to a customer.

Everything about **iAkauntan** below was read from the live schema and
the Dart source, and is accurate as at migration `0077`.

## The finding that matters most

Not a missing feature. **Four capabilities are already in the database
and cannot be reached from the app.** They were built and then never
wired up:

| Capability | In the schema | References in `app/lib` |
| --- | --- | --- |
| Multi-currency | `ref_currencies`, `exchange_rates`, `currency` + `exchange_rate` on every document and journal | **0** |
| Project / department dimensions | `gl_lines.project_code`, `gl_lines.department_code` | **0** |
| Price levels | `price_levels`, `item_prices` | **0** |
| FX revaluation | `journal_source` has an `fx_revaluation` value | no function exists |

The multi-currency case is the clearest. `document_editor.dart` holds
`String _currency = 'MYR'`, reads it back from a saved document, and
writes it on save — but **no widget ever changes it.** The plumbing runs
from the client to the ledger and the tap that would start the water is
missing. A foreign-currency invoice cannot be raised, and no revaluation
function exists to restate the balances if one could be.

This is the same pattern this project has hit repeatedly — the fiscal
year RPC with no caller, `reverse_gl_entry` with no caller, the leave and
recurring-journal schema with no runner. It is worth saying plainly
because it changes the advice: **the cheapest way to close the gap
against AutoCount is to finish what is already half-built, not to start
anything new.**

## Genuinely missing

Nothing in the schema, nothing in the app.

| Missing | What it is for | Who actually needs it |
| --- | --- | --- |
| **Multi-UOM** | Buy in cartons, hold in boxes, sell in pieces, with conversion factors | Trading and distribution. Very common in Malaysian SME wholesale |
| **Serial / batch tracking** | Which physical unit went to which customer; expiry by batch | Electronics, pharmaceutical, automotive parts, anything with warranty or shelf life |
| **Item assembly / BOM** | Build a finished item from components, moving cost with it | Light manufacturing, kitting |
| **POS** | Retail counter, cash drawer, receipt printer | Retail. AutoCount sells this as a separate product |
| **Customisable report layouts** | A designer for financial statement formats | Firms with a house format for client accounts |
| **Landed cost** | Freight, duty and insurance apportioned into item cost | Importers |

Already recorded in the README's *Not built yet* list and not repeated
here: bank statement import, statutory export files (CP39, EA, Borang E),
e-mail delivery, Goods Received and Purchase Request screens.

## Where iAkauntan is ahead

Worth knowing, because it decides who this is sold to. AutoCount sells
these as separate products or not at all:

- **HR and payroll in the same system** — EPF, SOCSO, EIS, PCB, HRD Corp,
  leave, claims, attendance, and a bank payment file, all posting to the
  same ledger. AutoCount's HRMS is a separate purchase.
- **Corporate secretarial** — statutory registers, CA 2016 deadlines
  computed from incorporation and financial year end, document generation
  and a signature workflow with scoped links for people who are not
  staff.
- **e-Invoice as part of the document lifecycle** rather than a bolt-on
  module with its own price.

## Advice

### 1. Finish the four half-built things first

In this order, by commercial value:

**Multi-currency.** The largest gap with the smallest remaining work,
because the storage and the posting path already exist. Needed by any
client who exports, imports, or invoices Singapore. What is left: a
currency selector on the document, a rate lookup at document date, the
realised gain/loss posting on settlement, and an `fx_revaluation`
function for period end. Without the last one the balances are wrong
after any rate movement, so it is not optional.

**Project and department dimensions.** `gl_lines` already carries both
codes. What is left: a `projects` table, pickers on the document and
journal screens, and — the part that gives it value — a P&L filtered by
project. Sells to professional services, construction and anyone doing
job costing.

**Price levels.** Least urgent, smallest job: a price level on the
contact, and the line editor reading `item_prices` before falling back to
`items.unit_price`.

### 2. Then multi-UOM and serial/batch, but only if the target is trading

These are real work, not wiring — multi-UOM interacts with weighted
average costing, and serial tracking changes what a stock movement *is*.
Build them when a distribution client is actually in front of you, not to
match a feature grid.

### 3. Deliberately do not build

- **POS.** A different product with different hardware, and AutoCount
  treats it as one too.
- **A report layout designer.** Large, and the demand behind it is
  usually "I need this report in my format" — which good fixed reports
  plus the PDF and CSV exports already answer for most firms.

### 4. Read this next to the migration plan

`docs/migrating-from-autocount.md` and this document are the same problem
seen from two sides. **A gap here is a client who cannot move.** A
company on AutoCount Pro using multi-currency or serial numbers cannot be
migrated into iAkauntan today at any level of effort, because there is
nowhere to put the data.

So the gap list doubles as a migration eligibility list:

| Client profile | Can they move today? |
| --- | --- |
| Services company, MYR only, no stock | Yes |
| Trading company, MYR, simple stock | Yes |
| Any company invoicing in foreign currency | **No** — until multi-currency is finished |
| Distribution with cartons/pieces | **No** — until multi-UOM |
| Electronics, pharma, anything serialised | **No** — until serial tracking |
| Retail with a counter | No, and by choice |

That ordering — currency, then dimensions, then UOM, then serials — is
the order in which it widens the set of businesses that can leave
AutoCount, which is a better reason to build than parity for its own
sake.
