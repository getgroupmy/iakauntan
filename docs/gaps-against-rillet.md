# Gaps against Rillet

## What was read, and what was not

This document was written from
[`api-evangelist/rillet`](https://github.com/api-evangelist/rillet),
cloned at `bd7a38a` — 150 files, 30 OpenAPI documents, and a set of
sidecar descriptions (`mcp/`, `llms/`, `skills/`, `agentic-access/`,
`errors/`, `conventions/`, `scopes/`, `conformance/`, `well-known/`).

**Three things about that source have to be said before anything is
believed.**

*It is not Rillet's repository.* Its own README opens with "This is not
our API." It is a third-party profile maintained by API Evangelist,
assembled from publicly reachable material. Rillet has not reviewed it.

*Rillet's own sources could not be reached from here.* Both
`https://rillet.com/` and `https://docs.api.rillet.com/` return `000`
through the egress proxy in this environment — no response at all. So,
exactly as with `gaps-against-autocount.md`, **the primary source was not
read.** Nothing here has been checked against Rillet.

*Much of it is derived rather than published.* The sidecar files carry
their own provenance, and it is uneven. `conventions/`, `errors/` and
`mcp/` say `method: searched` — assembled from documentation pages.
`agentic-access/` says `method: generated` and describes itself as
"classified heuristically from the OpenAPI". Only the OpenAPI documents
themselves look like re-published Rillet artifacts. The profile's own
README calls it "a lead awaiting the enrichment pipeline".

Treat the **shape** of Rillet's surface as reliable and every **exact
field name, limit and header** as unverified. Nothing in this document
should be quoted to a customer.

The **iAkauntan** side is verified, the same way the other two gap
documents verify it: by reading the migrations in this repository, not a
summary of them. Where a claim is "we do not have this", it means no
migration defines it — checked by name across all 306.

## What Rillet is, and why most of it does not apply

Rillet is an ERP for subscription businesses. Its centre of gravity is
`/contracts`, `/contract-items/{id}/usage`, `/charges`,
`/reports/arr-waterfall` — contracts with amendments, usage tiers,
minimum commitments, and the revenue those produce over time.

iAkauntan sells to Malaysian SMEs: a shop with a till, a firm with a
payroll, a practice with SSM deadlines. The overlap in the ledger is
near total — accounts, journal entries, invoices, bills, payments,
credit memos, trial balance, balance sheet, income statement, cash flow
— and iAkauntan already has all of it. The divergence is everything
above the ledger.

So this document is short on functional envy and long on one structural
observation.

## The structural gap: iAkauntan has no API

This is the finding. Rillet's repository is, in effect, a worked example
of publishing an ERP's API, and iAkauntan publishes nothing:

| Artifact | Rillet | iAkauntan |
|---|---|---|
| OpenAPI description | 30 documents | none |
| `llms.txt` | yes | none |
| MCP server | official, OAuth 2.0 + PKCE | none |
| `.well-known/` discovery | yes | none |
| Documented error format | RFC 9457 `problem+json` | none |
| Idempotency on writes | `Idempotency-Key`, 24h | **none — see below** |
| Pagination contract | keyset, `next_cursor`, 2h TTL | none |
| API versioning | `X-Rillet-API-Version` header | none |

iAkauntan is not, however, starting from nothing. **469 functions are
defined in `public`**, around 81 of them writes (`create_*`, `post_*`,
`approve_*`, `settle_*`, `void_*`). Supabase already exposes every one
of them over PostgREST. There is already an API; it is simply
undescribed, unversioned and untested from outside.

That is the cheap, high-value work, and it is mostly mechanical:
generate an OpenAPI description from `pg_proc` and the RLS-visible
tables, and write an `llms.txt`. It documents what exists rather than
building anything new, and it can be regenerated in CI so it cannot
drift — the same discipline `scripts/check_embeds.py` already applies to
the client's queries.

### The one that is a real defect, not a gap

**There is no idempotency key anywhere in the schema.** Checked by name:
no `idempotency_key` column, no `p_idempotency` parameter, nothing. The
word appears in eleven migrations and every occurrence is prose — functions
that happen to be idempotent because they check state first, such as
`post_document` refusing a document that already carries a
`gl_entry_id`.

Inside the Flutter client that has been survivable: one client, and it
controls its own retries. It stops being survivable the moment anything
else can call `post_journal_entry` — an integration, a scheduler, an
agent. A dropped response on a retried POST posts the journal twice, and
the ledger is append-only by design, so the second one is a correction
somebody has to make by hand.

Rillet's answer is the conventional one: `Idempotency-Key` on POST,
24-hour retention, the saved response replayed rather than the work
re-done. For this codebase that belongs in SQL, not in a gateway,
because that is where the writes are.

**This is worth doing whether or not an API is ever published**, which
is why it is called out separately from everything above.

### Agent access, and one thing not to copy

Rillet's `agentic-access/` classifies all 110 operations by
action-class, consequence (`read` / `write` / `physical`) and token TTL.
The idea is sound and iAkauntan already has the raw material for it —
`app.can_*` guards, module entitlements, and per-module access types
that already say `none` / `read` / `write`.

The file also reports `human_in_the_loop_required: 0` across all 110
operations, including the ones that pay bills. Remember that this file
is *generated heuristically by a third party* and may say nothing about
Rillet's actual product. As a default for iAkauntan it would be wrong:
posting to a ledger, approving a payroll run and lodging with SSM are
exactly the operations that should require a person.

## Functional gaps that are real

> **Since this was written, two of these have been closed.** Idempotency
> keys landed in `0307`–`0308` and revenue recognition in `0309`–`0311`,
> with the editor UI for service periods. The analysis below is left as
> it was written, because what it argued is why they were built; the
> "What has been built since" section at the end says where each stands.

**Revenue recognition. iAkauntan has none.** No `deferred_revenue`, no
recognition schedules, no `revenue_recognition` anything. `0097` gives
recurring documents, which raise an invoice on a schedule — that is
*billing*, and billing is not recognition. A company billing a year up
front should carry deferred revenue and release it monthly; today
iAkauntan would take the whole invoice to revenue on the invoice date.

Under MFRS 15 that is wrong for any customer with a contract spanning
periods — which includes maintenance contracts, annual licences and
retainers, not only SaaS. **This is the one functional gap here worth
taking seriously**, and it is a sizeable piece of work: a schedule
table, a period-end release run, and its own assertions.

**Contracts and usage billing.** None. Amendments, tiered usage,
minimum commitments. Only worth building if iAkauntan sells to
subscription businesses — a product decision, not an accounting one.

**ARR / MRR waterfall.** None, and correctly so. It is a SaaS investor
metric, not something a Malaysian SME asks its accountant for.

## What looks like a gap and is not

Checked, and already present:

- **Subsidiaries** — group reporting, intercompany billing and
  consolidation all exist.
- **Custom fields** — `custom_fields jsonb` on the master tables.
- **Credit memos and vendor credits** — `credit_note` and `debit_note`
  are both document types, so both directions are covered.
- **Period close** — `fiscal_periods` in `0003`, with posting refused
  outside an open period since `0053`.
- **Reports** — `report_balance_sheet`, `report_cash_flow`,
  `report_changes_in_equity`, trial balance, AR and AP ageing.
- **Reimbursements** — expense claims, with an approval chain Rillet's
  flat `/reimbursements` does not appear to have.

## Recommendation

In order, cheapest first:

1. **Idempotency keys on the write RPCs.** A real defect, worth fixing
   regardless of any API plan.
2. **Describe the surface that already exists** — OpenAPI generated
   from `pg_proc`, plus `llms.txt`, regenerated in CI.
3. **Decide on revenue recognition.** An accounting hole with a real
   MFRS 15 argument behind it, and a substantial build.
4. **Contracts, usage billing and ARR** — only on a decision to sell to
   subscription businesses.

An MCP server is deliberately not on this list. It is the fashionable
item and the least useful until (1) and (2) exist, because an agent
calling undescribed, non-idempotent write functions is the worst
version of this.

## What has been built since

**1. Idempotency keys — done.** `0307` adds `public.idempotency_keys`,
`app.idempotency_begin/end` and a fingerprint of the arguments, and
wraps `post_manual_journal`, `create_contra`, `create_deposit` and
`record_pdc` as overloads that take a key. `0308` sweeps keys older
than a day from `app.run_daily_jobs`. A retry with the same key returns
the first call's answer; the same key with different arguments is
refused rather than quietly answered.

**3. Revenue recognition — done.** `0309` puts `service_start` and
`service_end` on `sales_document_lines`. A line that carries them
credits deferred revenue rather than revenue when the document posts,
and `public.revenue_schedule_periods` holds the month-by-month release,
allocated on a running total so the periods sum to the invoice exactly.
`public.recognise_revenue(p_org_id, p_upto)` posts what is due.

`0310` closes the hole a credit note left: a credit note posts with
sign −1, which now cancels the schedule it credits instead of leaving
it releasing revenue for a contract nobody is delivering.

`0311` carries the period through `transfer_document`, so a period
agreed on a quotation reaches the invoice that actually defers it.

The editor shows a service-period strip under any sales line that could
carry one, and `0312` plus a deferred revenue card in settings show what
each month is about to release and post it — so both halves are reachable
by somebody who is not writing SQL. `0313` adds the third thing an
accountant needs, a Deferred Revenue report: what is sitting in 2127 at a
date, which invoice lines it belongs to, and whether the schedule and the
account agree. The card renders nothing at all until
a company has deferred something, which is what keeps it off the screens
of the shops that never will. The wording and the month count are
asserted in
`app/test/service_period_test.dart`; the carry-through in
`supabase/tests/transfer.sql`; the arithmetic in
`supabase/tests/revenue_recognition.sql`.

**2 and 4 are untouched.** The API surface is still undescribed, and
contracts and usage billing are still a product decision nobody has
made.
