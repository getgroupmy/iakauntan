# What the database can do that nobody can reach

## The check

Every base table and every `public` function granted to `authenticated`,
counted against the Dart in `app/lib` and the Deno in
`supabase/functions`. Reproduce it with:

```sql
select 'table', table_name, null from information_schema.tables
 where table_schema = 'public' and table_type = 'BASE TABLE'
union all
select 'rpc', p.proname, pg_get_function_identity_arguments(p.oid)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.prokind = 'f'
   and has_function_privilege('authenticated', p.oid, 'execute');
```

then grep each name across both source trees.

Two traps in doing it naively, both hit on the first pass:

- **Searching only for `'quoted_name'` misses PostgREST embeds.** A table
  reached as `select('*, contacts(name, code)')` never appears in quotes.
  Search for the bare word as well.
- **A repository method that takes a table name as an argument hides
  every table it is called with.** `setupRows(table, …)` is one; here the
  call sites pass literals, so nothing was hidden, but the next such
  method might not.

A name appearing only inside a comment is not a reference. `create_gl_entry`
was exactly that case.

## Closed

- **The manual journal** (was gap 1). `post_manual_journal` in `0089`,
  reached from the Journals screen. `create_gl_entry` itself is no
  longer granted to `authenticated`: it takes the journal's source,
  source table and source id as arguments, so holding it let any
  signed-in user post an entry claiming to have come from a payroll run.
- **Posting an approved expense claim** (was gap 2). A Post action on
  the claims screen, and a switch on the claim itself so the choice
  between payroll reimbursement and posting by hand is made deliberately
  — `pay_with_payroll` defaulted to true and nothing ever set it, so
  every claim took the payroll route by accident and `post_expense_claim`
  would have refused all of them. Giving the function its first caller
  also gave it its first test, which found that proportional allocation
  rounded each share independently: three equal shares of an approved
  100.00 came to 99.99 against a credit of 100.00, and the journal was
  refused. Fixed in `0090`.
- **Public holidays and leave entitlement bands** (were gaps 1 and 2 of
  the second pass).
  Two tabs on the HR setup screen, plus `add_fixed_public_holidays` for
  the four Malaysian holidays that fall on a fixed date in every state
  and `apply_statutory_leave_bands` for the Employment Act 1955 floors.
  Both in `0091`.
- **The statutory rate tables** (was gap 3). Read-only for
  organizations, which is the design and not an omission — these tables
  have no `org_id`, so a rate edited by one company is every company's
  payroll. Publishing lives in the platform console behind
  `app.is_platform_admin()`.
- **Item prices** (was gap 4). A Prices action on each item, writing the
  named prices and quantity breaks `item_price` already resolves — plus
  an editor for `price_levels` themselves, which turned out to be
  readable and creatable by nothing, so the screen above it would have
  had nothing to price against.
- **Contact people and delivery addresses** (was gap 5). Two sections on
  a saved contact. `0092` adds the partial unique indexes that make
  "the default address" mean one row rather than whichever the query
  returns first.
- **CRM leads.** A leads screen, and `convert_lead` in `0093` — which
  creates the customer, carries the named person across as their main
  contact, opens an opportunity in the pipeline's first *open* stage,
  and stamps the lead, all in one transaction. Three writes from the
  client can half succeed and put the same company in the book twice.
  The lead is kept rather than consumed: `converted_contact_id` is how
  "where did this customer come from" gets answered a year later.
- **Talent and onboarding.** Interview rounds against a candidate;
  onboarding templates and their items, with `start_onboarding` turning
  day offsets into dated tasks; a checklist screen where ticking the
  last mandatory box closes the list; appraisal goals under an
  appraisal; and dependants, documents and shift assignments on the
  employee record. The first of those matters more than it looks — a
  dependant carries a tax relief claim, so PCB was understated for
  anybody who had one and no way to say so.

- **The stock card.** `report_stock_card` in `0155`, reached from a Stock
  card action on every stock-tracked item. `stock_movements` could be
  written and never read, so "the shelf says 44 and the screen says 47"
  had no answer anywhere in the app; 0152 had made it sharper by adding
  opening balances, so a company's stock now began with a movement
  nobody could look at.

  The running balance is computed with a window rather than read from
  `stock_movements.balance_quantity`, which the trigger already
  maintains — those columns are per *warehouse*, so a card spanning all
  of them would show a balance that jumps between locations and belongs
  to none. Two implementations of the same arithmetic is only safe if
  they are held against each other, so `supabase/tests/stock_card.sql`
  asserts they agree at every movement for a single warehouse, and that
  they differ across two.

  Getting that assertion to pass found the real thing: the trigger's
  order is `movement_no`, not `created_at`. A bill that receives stock
  and a delivery that ships it inside one transaction carry the same
  timestamp to the microsecond, and production already holds such a
  pair — ordered by `created_at` the card disagreed with the stored
  balance on two of four movements.

  The screen also compares its own closing quantity against
  `items.quantity_on_hand` and says so when they differ, but only on an
  unnarrowed card: filtered by date or warehouse the comparison is
  meaningless, and a warning that fires on every filtered card is a
  warning nobody reads.

- **The depreciation schedule.** `report_depreciation_history` and
  `report_asset_movements` in `0156`, reached from the fixed asset
  register: a schedule action in the app bar, and a history action on
  every asset including disposed ones. `depreciation_runs` and
  `depreciation_entries` were written by the run and never read, so the
  note an auditor asks for by name could not be produced — which `0084`'s
  own header had said on the day it landed.

  Going to build it is what found the reason it mattered.
  `dispose_fixed_asset` brings an asset's depreciation up to the date it
  leaves, and then relieved accumulated depreciation of the whole of it
  without ever charging the catch-up to expense. A van costing 12,000
  depreciated to March and sold in June left a 600 debit stranded in
  1590, charged six months of ownership as three, and overstated profit
  by exactly the stranded amount. Every disposal that did not happen to
  fall on a run date did this. The catch-up is now charged and recorded
  as an entry of its own against the disposal's journal, so the asset's
  history is whole and the note's charge ties to the entries behind it.

  The same function posted gains to 4920 and losses to 6500, which in
  the seeded chart are Foreign Exchange Gain and Foreign Exchange Loss.
  Disposals now have 4930 and 6510, created on demand the way `0150`
  creates 3900. No organization had a fixed asset yet, so there was
  nothing to repair.

  The note asserts two movement identities — cost and accumulated
  depreciation each carried forward from brought forward, additions and
  disposals — with the closing figures derived independently of the
  movements meant to reconcile to them. The accumulated identity only
  holds because the disposal now records what it relieves; it is the
  test that would have caught the bug, written after the fact.

## Correct: the database owns these

Not gaps. Written by triggers or SECURITY DEFINER functions, or read
through an RPC that *is* called:

`stock_movements`, `stock_levels`, `number_sequences`,
`opportunity_stage_history`, `payroll_ytd`, `platform_admins`,
`audit_logs` (via `audit_trail`), `corp_signatures`,
`corp_signature_requests`, `corp_signing_links`, `corp_filing_types` (all
via the `corp_*` RPCs), `einvoice_lines`, `einvoice_logs`,
`einvoice_submissions`, `tin_validations` (all from the edge functions).

## Gaps, worst first

### 1. Smaller, but real

- **`item_categories`** — no editor.
- **Reconciliation history.** `bank_reconciliations` rows are written and
  never listed.
- **`corp_resolutions`** — the register itself, as opposed to the
  generated documents.
- **`corp_issued_capital`, `resync_bank_balance`** — RPCs with no caller.
- **Reference pickers**: `ref_countries`, `ref_msic_codes`,
  `ref_tax_types`, `ref_einvoice_types`, `ref_exemption_reasons` are
  typed by hand where they are used at all.

## Why this keeps happening

Of the eleven capabilities built in the sessions before this check, nine
were already in the schema with nothing able to reach them. Schema lands
ahead of behaviour in this codebase, consistently, and the gap is
invisible to every other check: the migrations apply, the tests pass,
the analyzer is clean, and the screens that exist all work.

Run this check before planning a block of work, not after.
