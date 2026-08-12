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
below is exactly that case.

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

### 1. There is no way to post a manual journal

`create_gl_entry` is granted to `authenticated` and called from nowhere.
The three mentions in `app/lib` are all inside comments describing it.

So there is no accrual, no prepayment, no adjusting entry, no correction
of an opening balance, and no way to record anything the automated paths
do not produce. Every other posting route in the system exists; the one
a bookkeeper reaches for when something does not fit does not. For an
accounting system this is the largest single gap on this list.

### 2. An approved expense claim never reaches the ledger

`post_expense_claim` exists and posts correctly. `decide_expense_claim`
approves a claim and **does not call it** — checked against the function
body, not assumed — and neither does the app.

An approved claim is therefore approved and then nothing happens: the
expense is never recognised and the employee is never credited. Nobody
has hit it yet only because there are no claims in the live data.

### 3. Public holidays cannot be entered

`public_holidays` is empty and unreachable. Leave day counts and the
rest-day / public-holiday classification in attendance both read it, so
every public holiday is currently an ordinary working day.

### 4. Leave entitlement bands cannot be entered

`leave_entitlement_bands` is empty and unreachable. These are the
Employment Act s.19 minimums by length of service — the thing annual
leave entitlement is calculated from.

### 5. The statutory rate tables cannot be seen or corrected

`statutory_rates` (11 rows) and `statutory_schedules` (5 of them
`is_verified = false`) have no screen. `README.md` says these seeded
figures must be replaced with the gazetted KWSP and PERKESO tables
before filing real returns, and there is no way to do it from the app.

### 6. Item prices cannot be set

`item_prices` is unreachable, so only the level-wide percentage on
`price_levels` can be used. The resolver added in `0088` reads named
prices and quantity breaks that nothing can write. Half-finished, and
mine.

### 7. Contact persons and delivery addresses

`contact_persons` and `contact_addresses` are both empty and
unreachable, while `sales_documents.contact_person_id` and
`shipping_address_id` are carried through the transfer path and read by
the e-Invoice preparation.

### 8. CRM leads

`leads` has a table, RLS and no screen. The CRM is pipeline and
opportunities only, so the top of the funnel is missing.

### 9. Talent and onboarding

`interviews`, `onboarding_templates`, `onboarding_checklists`,
`onboarding_tasks`, `onboarding_template_items`, `appraisal_goals`,
`employee_dependants`, `employee_documents`, `employee_shifts` — all
unreachable. Appraisals and applicants have screens; the tables around
them do not.

### 10. Smaller, but real

- **Stock card.** `stock_movements` cannot be inspected per item, so
  "why is this figure what it is" has no answer in the app.
- **Reconciliation history.** `bank_reconciliations` rows are written and
  never listed.
- **Depreciation schedule.** `depreciation_runs` and
  `depreciation_entries` are written by the run and never read, so the
  per-asset history the auditor asks for is not printable.
- **`corp_resolutions`** — the register itself, as opposed to the
  generated documents.
- **`item_categories`** — no editor.
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
