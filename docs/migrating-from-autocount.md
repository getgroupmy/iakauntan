# Migrating from AutoCount Cloud

## What this document is, and what it is not

A plan for receiving a company's books from AutoCount Cloud Accounting,
written against **verified facts about iAkauntan** and **second-hand
information about AutoCount's API**.

That asymmetry matters, so it is stated first:

> **I could not read AutoCount's API documentation.** The environment this
> was researched in blocks `accounting-api.autocountcloud.com`,
> `agilex.my` and `forum.pabbly.com` at the network egress proxy.
> Everything in *"What the API appears to expose"* below is drawn from
> search-engine summaries of those pages. It is good enough to plan
> against and **not good enough to build against.** Before anyone writes
> a line of importer code, someone with network access must open
> <https://accounting-api.autocountcloud.com/swagger/index.html> and
> confirm the resource list, the exact field names, the enum values and
> the auth flow.

Everything about iAkauntan's own schema below was read directly from the
hosted database and is accurate as at migration `0077`.

## "100% integration" is the wrong target

It is worth being blunt about this, because it changes what gets built.

No API-based migration copies everything. AutoCount holds settings,
report layouts, user permissions, attachments, audit trails and years of
document history that either have no equivalent here or are not exposed
over any interface. Chasing "every field" produces an importer that is
enormous, unfinishable, and *still* leaves the accountant unsure whether
the numbers are right.

What can be 100% — and what a client actually needs to be 100% — is a
short list of assertions at the cutover date:

| Must agree exactly | Why |
| --- | --- |
| Trial balance, every account | If this is out, everything downstream is |
| AR ageing, invoice by invoice | The business chases these; a wrong balance is a wrong dunning letter |
| AP ageing, bill by bill | Same, in reverse, and it is how suppliers get paid twice |
| Stock quantity **and value** per item | Quantity alone hides a costing difference that lands in COGS |
| SST output and input balances | Because the next SST-02 is filed from them |

"100% integration" should mean **those five reconcile to the sen, and the
importer proves it before anything is posted.** Everything else —
historical quotations, closed purchase orders, dead contacts — is
convenience, and convenience should not gate a cutover.

## What the API appears to expose

Second-hand; verify against Swagger.

**Authentication.** An API Key created in the Cloud Accounting web app
under *Settings → API Keys*, yielding a Key ID and an API Key, with
per-method permissions (default: all). Some sources also mention a Client
ID and Secret. The exact header names and whether a token exchange is
involved are unconfirmed.

| Resource | Operations reported |
| --- | --- |
| Account | listing |
| Area | listing |
| Company profile | read |
| Debtor (customer) | list, get, create, modify, delete |
| Creditor (supplier) | list, get, create, modify, delete |
| Invoice | list (date filtered), get, create, update, delete, **knock-off detail**, void |
| Credit note | reported, detail unknown |
| Journal entry | listing, listing by date |
| Payment voucher / Receipt voucher | list (date filtered), get, create, update, delete |

Three things follow from that list, if it is accurate:

1. **Read-only GL is not a problem.** A migration only ever *reads* from
   AutoCount. Journal entries being listable is sufficient. (It would be
   a problem for ongoing two-way sync — a different feature, see below.)
2. **Inventory is missing from it.** No stock, item or costing endpoints
   surfaced. If that holds, stock on hand and valuation must come from
   AutoCount's own export files rather than the API. Since stock value is
   one of the five things that must reconcile, **this is the largest
   single unknown** and the first thing to check in Swagger.
3. **Chart of accounts and tax codes look read-only or absent.** Fine for
   migration *into* iAkauntan; we only need to read them.

**"Knock-off"** is AutoCount's term for allocating a payment against
specific invoices. It maps exactly onto our `payment_allocations`, and
retrieving it is what makes a correct AR ageing possible — without the
allocations you know a customer owes RM 50,000 but not which five
invoices make it up.

## Where each concept lands here

Verified against the live schema.

| AutoCount | iAkauntan table | Natural key |
| --- | --- | --- |
| Account | `accounts` | `(org_id, code)` |
| Debtor | `contacts` (`contact_type = 'customer'`) | `(org_id, code)` |
| Creditor | `contacts` (`contact_type = 'supplier'`) | `(org_id, code)` |
| Stock item | `items` | `(org_id, code)` |
| Invoice | `sales_documents` (`doc_type = 'invoice'`) + `sales_document_lines` | `(org_id, doc_type, doc_no)` |
| Credit note | `sales_documents` (`doc_type = 'credit_note'`) | same |
| Bill | `purchase_documents` (`doc_type = 'bill'`) + lines | `(org_id, doc_type, doc_no)` |
| Receipt voucher | `receipts` + `payment_allocations` | `(org_id, receipt_no)` |
| Payment voucher | `purchase_payments` + `payment_allocations` | `(org_id, payment_no)` |
| Journal entry | `gl_entries` + `gl_lines` | `(org_id, entry_no)` |
| Stock balance | `stock_movements`, `stock_levels` | — |
| Opening balances | `accounts.opening_balance`, or a `gl_entries` row with `source = 'opening_balance'` | — |

The document types line up better than expected: our `sales_doc_type`
already covers quotation, sales order, delivery order, invoice, credit
note, debit note, refund note and proforma, and `journal_source` already
has an `opening_balance` value, so a migration has somewhere honest to
put its opening entry rather than disguising it as a manual journal.

## Three obstacles on our side

These are ours to fix, and they are the real work.

### 1. ~~Nothing records where a row came from~~ — built, `0610`

> There is **no `external_id`, `legacy_id`, `source_system` or
> `import_batch_id` column anywhere in the schema.** I checked every
> table.

That was true and is no longer. `0610` adds `import_source`,
`import_ref`, `import_batch_id` and `imported_at` to every table an
import can write to — the nineteen named in `app.import_target_tables()`,
in the order this document's dependency list writes them — with a partial
unique index on `(org_id, import_source, import_ref)` and a check that
the pair is present or absent together.

**Not `source_system` / `source_id`, which is what this document
proposed.** `gl_entries.source_id` and `stock_movements.source_id` have
meant something else since `0013` — which document the row came from
inside this system — and `add column if not exists` does nothing against
a column that is already there, so the pair constraint read the existing
column and refused every journal the product writes. Five assertion files
said so on the first run.

Alongside them: `import_batches` (one run, with its status and what it
found) and `import_rows` (what was pulled, as raw JSON, before anybody
interpreted it — stage one of the three below), plus
`start_import_batch`, `finish_import_batch`, `import_batch_summary` and
`rollback_import_batch`.

The rollback refuses rather than cascades. Once somebody has raised an
invoice against an imported customer, deleting the import is not undoing
it, and a posted batch is refused outright — that has reached the ledger
and is reversed with a journal, like every other document in this
product.

`supabase/tests/import_provenance.sql` has 27 assertions, and the one it
exists for is the re-run: import the same thing twice and get one row,
while a different row that happens to share a code stays a different row.

What remains of this obstacle is nothing. Stages two and three below —
reconcile and post — are still unbuilt, and they now have somewhere to
stand.

<details>
<summary>The original finding</summary>

Without provenance:

- an import cannot be re-run — a second attempt either duplicates
  everything or collides on the natural key, and there is no way to tell
  "already imported" from "coincidentally same code";
- nothing can be reconciled back to AutoCount later, when the accountant
  asks why one balance differs;
- a failed import cannot be rolled back cleanly, only unpicked by hand.

**This is the first change to make**, before any importer exists: a
`source_system` / `source_id` / `imported_at` triple on every table that
can receive migrated data, with a unique index on
`(org_id, source_system, source_id)`. It costs one migration and makes
the whole exercise re-runnable, which is what turns a migration from an
event into a process you can rehearse.

</details>

### 2. Every posting must land inside a fiscal period

`create_gl_entry` refuses a date that no fiscal year covers — this was
deliberate, and it is documented in the README:

```
No fiscal period covers 2027-01-15. Create the fiscal year before posting to it.
```

So an import of historical documents must **create the fiscal years
first**, covering every year it intends to touch. And because closing a
period is meant to stop postings, a migration has to run before year-end
sign-off, or reopen and re-close deliberately. Order of operations is
part of the design, not an implementation detail.

### 3. The seeded chart of accounts will collide

`accounts` is unique on `(org_id, code)`, and creating an organization
seeds an MPERS-aligned chart. Importing AutoCount's chart into a seeded
organization will collide on any code that exists in both — and silently
*merge* into an account with a different meaning if the codes happen to
match but the names do not.

Two defensible answers, and the choice should be explicit:

- **Import into an empty organization**: add a "create company without
  the default chart" path, and bring AutoCount's chart wholesale. Best
  fidelity; the client's account codes are the ones their accountant
  knows.
- **Map onto the seeded chart**: a mapping table the client confirms
  before posting. More work, but leaves them on a chart the rest of the
  product (default tax codes, report groupings) already understands.

The first is usually right for a migration. The second is right for a
client who wants to move *to* our conventions.

## Proposed shape: stage, reconcile, then post

The importer should never write directly into the ledger from a live API
call. Three stages:

1. **Stage.** Pull every resource into `import_batches` / `import_rows`
   as raw JSON, keyed by AutoCount's own identifiers. Nothing is
   interpreted yet. This makes the pull repeatable and the payloads
   auditable when a number is later disputed.
2. **Reconcile, as a dry run.** Map staged rows onto our model and
   produce a report *before* posting anything: trial balance per account
   against AutoCount's, AR and AP ageing per contact, stock value per
   item. **The migration does not proceed while any of the five
   assertions differs.** This is the feature that earns the word
   "guaranteed" — not the pulling, which is the easy half.
3. **Post.** Only once the dry run reconciles, in dependency order:
   fiscal years → chart of accounts → tax codes → contacts → items →
   opening balances → open documents → allocations.

## What to migrate: a recommendation

Bring **master data, open AR/AP documents, and an opening trial balance
at the cutover date.** Not years of transaction history.

That is not laziness. Historical documents that cannot be reconciled are
a liability rather than an asset — they make the new system look wrong
when it is not — and under Malaysian law the client must retain the old
records for seven years regardless, so the history has a home already.
Offer full history as an option for clients who want it, behind the same
reconciliation gate, and price it as the work it is.

## Migration is not integration

Worth separating, because the request mentioned both:

- **Migration** is one-way and one-time: read from AutoCount, land here,
  reconcile, switch over. Everything above is about this.
- **Integration** is ongoing and two-way, and is a different product
  decision — it needs write access to their API, conflict rules for
  records edited in both systems, and an answer to which system owns the
  ledger. The reported read-only journal endpoints would matter here.

A client asking to "migrate off AutoCount" wants the first. A client
running both wants the second, and should be asked which system is the
book of record before anything is built.

## What is needed to turn this into code

1. The Swagger document, or an API key against a sandbox company —
   without it, field names and enums are guesswork.
2. A sample export from a real AutoCount company (anonymised), including
   its trial balance and AR/AP ageing at a date, so the reconciliation
   report can be tested against numbers somebody has already agreed.
3. A decision on the chart of accounts question in obstacle 3.

The provenance columns (obstacle 1) can be built now and are worth
building regardless: any import from anywhere needs them.
