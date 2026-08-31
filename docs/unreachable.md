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

**A second sweep, added in the pass at `142c05b`, and worth more than
the first.** The SQL check above finds what the *database* can do and
nobody calls. It cannot see the layer where most of this actually
hides: a repository method or a Riverpod provider that wraps a function
the check counts as reached, and is itself called by nothing. Run both:

```python
# Run from app/. Both sweeps are the same shape: collect the names some
# files declare, then count references to each one everywhere else.
import re, os, collections

DATA = 'lib/src/data'
# Every repository file, not just repository.dart. Writing this against
# repository.dart alone missed corp_repository.dart, ocr_repository.dart
# and two more — and `corpOpenFiling`, the whole statutory filing
# lifecycle, was sitting in one of them.
REPOS = [os.path.join(DATA, f) for f in os.listdir(DATA)
         if f.endswith('.dart') and f not in ('models.dart', 'corp_models.dart')]
METHOD = (r'\n  (?:Future<[^>]*>|Future|Stream<[^>]*>|void|String|bool|num|'
          r'double|int|List<[^>]*>|Map<[^>]*>)\??\s+([a-z][A-Za-z0-9_]*)\s*\(')

def unreferenced(declaring, pattern, call_shape):
    names = {}
    for d in declaring:
        for n in re.findall(pattern, open(d).read(), re.M):
            names.setdefault(n, d)
    seen = collections.Counter()
    for root, _, files in os.walk('lib/src'):
        for f in files:
            path = os.path.join(root, f)
            if not f.endswith('.dart') or path in declaring:
                continue
            text = open(path).read()
            for n in names:
                seen[n] += len(re.findall(call_shape(n), text))
    out = collections.defaultdict(list)
    for n, d in names.items():
        if seen[n] == 0:
            out[d].append(n)
    return {d: sorted(v) for d, v in sorted(out.items())}

print(unreferenced(REPOS, METHOD,
                   lambda n: r'\b' + re.escape(n) + r'\s*\('))
print(unreferenced(['lib/src/core/providers.dart'],
                   r'^final ([a-zA-Z0-9_]+Provider)\b',
                   lambda n: r'\b' + re.escape(n) + r'\b'))
```

The two have to be read together, not separately. `creditLedger` lives
in `ocr_repository.dart` and *is* called — by `creditLedgerProvider`,
which nothing watches. The method sweep alone clears it; the provider
sweep alone does not say what it is. Neither sweep on its own would
have found it.

Seventeen of the nineteen gaps closed in that pass were invisible to
the SQL check and obvious to this one. `bankTransfersProvider` is the type
specimen: it read the transfer register, and its only reference
anywhere was an `invalidate` in the dialog that creates a transfer — so
the RPC behind it counted as reached while a transfer, once made, left
the app entirely.

Two traps in the provider sweep. A provider is a false positive when
the screen reads the same thing through the repository directly —
four of the eleven it reports at `142c05b` are that, so check each one
for a bare `.methodName(` before believing it. And a provider *you*
add and never watch is the same defect arriving fresh:
`depositNoteProvider` was added and removed inside one pass for
exactly that reason.

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

- **The reconciliation register.** `report_bank_reconciliations` in
  `0157`, reached from a history action on the reconciliation screen.
  `bank_reconciliations` rows were written and never listed.

  Listing them showed why that mattered. `complete_bank_reconciliation`
  refused a difference — 0085 was careful about that — but nothing
  stopped it running twice, or running at a date behind one already
  closed. One statement line, matched once, produced three completed
  reconciliations, two of which stamped no lines at all: the stamping is
  `where reconciliation_id is null`, so a repeat finds nothing left to
  claim, and the difference check passes trivially because everything was
  already reconciled. A register reading as three months of diligence and
  being one is worse than no register, because an auditor ticking against
  a phantom row is being misled by the system rather than by a person.

  A reconciliation now has to carry on from the last one, and
  `reopen_bank_reconciliation` is what makes refusing safe: without a way
  back, one wrong date closes an account permanently. It accepts only the
  most recent one on its account, releases the lines it closed over
  without unmatching them, and deletes the row — 0085's own comment says
  a completed reconciliation that can still be edited underneath is not a
  record of anything, and a reopened one is exactly that.

  The register reports how many lines each reconciliation closed over,
  which is what tells a real one from a phantom, and the screen names any
  it finds — a database written before 0157 may hold some.

- **`corp_issued_capital` and `resync_bank_balance`** were listed here as
  RPCs with no caller. They have both had one for some time:
  `corp_issued_capital` from the document generator in `0065`, and
  `resync_bank_balance` from the opening-balance import in `0151`. The
  entry was stale rather than the code.

### The pass at `142c05b`

Nineteen commits, seventeen of them found by the provider and
repository sweeps rather than by the SQL check. Grouped by what a user
could not do.

**Nobody could record the thing the module is for.**

- **An hour.** `0164` widened `time_entries` off matters and onto
  projects for a reason it wrote down — the table "is welded to law
  firms... a consultant, an engineer, an architect or an agency —
  everyone else who sells hours — cannot record a minute". The widening
  landed and the form did not. The only way in stayed the matter tab on
  the legal screen, so a firm without the legal module had a Timesheets
  screen with three tabs, an empty state inviting people to record
  hours, and nothing that could write one. Everything downstream —
  billing a project, billing a matter, utilisation, the rate card —
  waited on rows nobody could make.
- **Whose dish it is.** `items.stall_id` is stamped onto every POS sale
  line and `pos_stall_takings` counts only lines that carry one.
  `setItemStall` had no caller, so every line was stamped null and the
  food court's Settling tab was empty for every tenant that ever used
  it. The stalls, the commission percentage and the settlement runs
  were all built and could not produce a ringgit between them.
- **How big a carton is.** `ref_uom_factors` leaves the packaging codes
  out on purpose — "a box is only as big as whatever is in it" — and
  `item_uom_packs` is where a shop says so. Nothing could write one, so
  `app.uom_qty` fell through to a reference factor that deliberately
  does not exist for a packaging code.
- **A budget line.** The budget grid's own empty state told people to
  "fill it from last year and then change the lines that matter", and
  the grid was read-only. The only budget anybody could have was last
  year's actuals times a percentage.

**Nobody could take something back.**

- **An invoice, a deposit, a transfer, a draft.** Four undos in the
  schema with no caller between them. `void_sales_document`,
  `void_deposit`, `void_bank_transfer` and the soft delete behind
  `deleteDocument`. The only remedy for any of them was a manual
  journal against a document that stayed on the ledger looking real.
- **A stock transfer, a recurring template.** `cancel_stock_transfer`
  takes only a draft and had no caller, so a draft typed by mistake sat
  on the list forever. `update_recurring_template` re-points a schedule
  at a newer document — the only way a schedule can follow a price rise,
  since it holds a copy rather than a link — and had no caller either,
  so the remedy was to delete the schedule and lose its run history.
- **A voucher, a delivery.** `remove_pos_sale_promotion` and
  `clear_pos_delivery`, neither called. A code typed against the wrong
  bill stayed on it until tender; an address taken for what turned out
  to be a collection could be corrected but never removed, so the ride
  stayed on the total.
- **The LHDN credentials.** `clear_einvoice_credentials` had no caller,
  so a client id and secret could be overwritten and never removed. A
  company leaving, or changing intermediary, had no way to take them
  out, and the secret stayed server-side indefinitely.

**Nobody could see what the system already knew.**

- **The transfer register.** `bankTransfersProvider` read it and
  nothing watched it. A transfer, once made, was not listed, not
  printable and not voidable.
- **What a landed cost run is made of.** `landedCostChargesProvider`
  and `landedCostTargetsProvider`, both unwatched. The run showed what
  it would put onto the stock and never which freight, which duty, to
  which account, over which bills — and `upsert_landed_cost_run` amends
  a draft in place, a path nothing called, so correcting a mistyped
  figure meant re-entering everything.
- **Why the forecast moved an invoice.** `customer_payment_lags` was
  written for exactly that — "so somebody can see why the forecast moved
  an invoice and argue with it" — and `lagLabel` was written to phrase
  it. Neither had a caller, while the toggle in the app bar went on
  claiming the forecast used how late each customer actually pays.
- **The day's deliveries.** `pos_delivery_day` had no provider at all
  and `posDriverRunsProvider` was watched by nothing. A shop recorded
  every driver, run, fee and delivery time and could report none of it.
- **The 86 list.** Stopping and resuming a dish were reachable from a
  long press; `pos_stopped_items` was not, so the list existed only as
  greyed tiles scattered through a menu and nobody could see who had
  taken a dish off.
- **The attendance month.** `attendanceProvider` reads it and nothing
  watched it. My HR showed today and only today, so an employee could
  not check the month before payroll ran on it and nobody in HR could
  answer who had been late.
- **Who holds a ticket.** `assign_ticket` and `escalate_ticket`, in
  `0194` since the lifecycle landed, neither called. A ticket sat in
  whatever queue routing put it in, `escalation_level` never left zero,
  and the header did not say who owned it.

**Two statutory ones, which are the ones that would have hurt.**

- **How the chart maps to MBRS.** `fs_account_map` holds the deviations
  from `app.fs_default_element`, and `fsAccountMap`, `setFsAccountMap`
  and `mbrsElements` all had no caller. A standard chart needs no
  deviation, which is why it went unnoticed — but a company that
  repurposed an account, or created one without a subtype, had its
  figures land wherever the default decided, and the numbers lodged
  with SSM would be wrong with no remedy in the product. The default
  mapping is now mirrored in Dart so the screen can show what an
  account will do, and `mbrs.sql` asserts all twenty-six of its arms —
  nothing asserted one before — plus that every element it produces
  exists in `mbrs_elements`, since the override's foreign key would
  otherwise refuse what the default happily emits.
- **What a set of accounts says.** `fs_filings` carries the auditor,
  the firm number, the signatory, the report date, the opinion, the
  going-concern emphasis, the PD 3/2018 headcount and the directors'
  dates. `createFsFiling` sets three of them, once, and
  `updateFsFiling` had no caller — so the rest could never be entered
  at all, and the exemption card answered "cannot tell" forever because
  the headcount could not be supplied after the filing was made.

- **A statutory filing's own life.** `corp_upcoming_filings` computes
  every deadline the Companies Act imposes and leaves `filing_id` null
  until somebody opens one. `corpOpenFiling` and `corpMarkLodged` had
  no caller, so `corp_filings` could never leave the state the
  computation put it in: a practice could not say it was working on an
  Annual Return, or record that one was lodged on a date with an SSM
  reference, and the screen went on showing filed deadlines as overdue
  for as long as the company existed. Found only after the method sweep
  was widened past `repository.dart` — it lives in
  `corp_repository.dart`, which the first version of the check never
  opened.

**Applying a deposit** (`apply_deposit`) rounds the set out: a deposit
could be given back or kept and never set against the invoice it was
taken for, which is the ordinary outcome, so the liability stood
against an invoice reading as unpaid.

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

Re-run at `6207faa`, against 286 migrations: 401 functions granted to
`authenticated`, three of them named nowhere in `app/lib` or
`supabase/functions`, and two of those three are false positives worth
writing down so the next pass does not chase them again.

- **`decide_claim_step`** is reached through `decide_expense_claim`,
  which is a two-line wrapper the claims screen calls.
- **`resync_bank_balance`** is called by `import_opening_balances`
  server-side. It is granted to `authenticated` and no client calls it,
  which is a surface question rather than a missing screen.

### 1. Smaller, but real

- **Reference pickers**: `ref_countries`, `ref_msic_codes`,
  `ref_tax_types`, `ref_einvoice_types`, `ref_exemption_reasons` are
  typed by hand where they are used at all.

Two entries came off this list at `832dc9e`, and one was wrong to be on
it in the first place:

- **`item_categories`** is closed. It had been in `0003` — the first
  migration in the repository — self-referencing through `parent_id`
  and wired to `items.category_id`, and nothing in the app could read
  it, write it or show it. `Item.categoryId` was on the model and in
  `toJson` the whole time; no field ever set it. Worse than a missing
  editor: `0215`'s kitchen router routes *a whole category* to a
  counter, so its first arm had nothing to route.
- **`corp_resolutions`** is closed. Three tables carry a
  `resolution_id` — `corp_filings`, `corp_share_events`,
  `corp_documents` — and none of them could ever be pointed at
  anything, because no resolution could be recorded.
- **`pos_item_portions`** was a false positive and should not have been
  listed. It has three callers, all of them SQL: `pos_item_availability`
  (which the recipes screen does read), `pos_can_sell`, and the till's
  own guard. It is a building block, not a screen that is missing.
  Written down so the next pass does not chase it.

### 2. What the sweeps still find at `832dc9e`

Nine repository methods with no caller, one of them a false positive:

- **`callRpc`** is the helper every repository file calls RPCs through.
  It is referenced hundreds of times *inside* the files the sweep
  excludes, which is exactly what it is for.
- **`acceptInvitation`** is the *token* path into a company, and it is
  not the only one. `app.handle_new_user` claims a pending invitation
  the moment somebody signs up at the invited address, which is how
  every member has actually joined, so this is a missing e-mail link
  rather than a missing screen. Building the screen without the link
  would give nobody anything to paste.
- **`chatEndCall`, `chatFileBytes`, `chatMarkDelivered`, `notifyPush`,
  `reportDenied`** were listed together as "plumbing behind features
  that work by other routes", with a note that each needed reading
  before being called a gap or dead weight. Read. They were five
  different things:

  - **`notifyPush` is a false positive**, and a new shape of one. It is
    called twice — from `chatSendMessage` and from the attachment
    upload — and both callers are *inside `repository.dart`*, which the
    sweep excludes as a declaring file. `callRpc` is the same blind
    spot at a scale nobody could miss; this one is small enough to
    miss. **Check a reported method for callers within its own file
    before believing it.**
  - **`reportDenied` was the most serious gap in this register.** `0235`
    built a security log whose `denied` kind exists precisely because
    "a refusal cannot record itself" — the exception unwinds the
    transaction the record would be written in — so the client has to
    report it back. Nothing did. Every refusal the server made was
    invisible to the log built to hold them. Closed by reporting from
    `runWithFeedback`'s catch, which is the one place every refusal in
    this app already passes through.
  - **`chatMarkDelivered` was a promise the screen made.** `chat_screen`
    draws three receipt states — one tick sent, two grey delivered, two
    blue read — and nothing ever marked delivered, so a message went
    from one tick straight to two blue. The middle state exists to tell
    a colleague whose phone is off from one who has read it and not
    replied, and it could never appear. Closed from the conversation
    list, which is what fetched the messages and so is what knows they
    arrived.
  - **`chatEndCall` was real, and is closed.** Join, decline and leave
    all reached the screen and ending did not, so whoever called a
    meeting could only walk out of it. `chat_end_call` refuses everybody
    but the person who started the call, so the button is only offered
    to them — absent rather than greyed out, like the screen-share
    button beside it.
  - **`chatFileBytes`** is probably dead weight. `chatFileUrl` returns a
    short-lived signed URL and is what the attachment viewer uses;
    downloading the bytes into the app would only be for writing a file
    to a device, which nothing here does. Left rather than deleted, and
    named here so the next pass does not re-derive it.
- **`setRegisterDefaultChannel`** has nowhere to live: registers are
  picked all over the app and administered nowhere. It needs a register
  settings screen, which is the actual gap.
- **`landingPreview`** and **`navGrouping`**, in the landing and
  platform-catalogue repositories. Platform-side rather than tenant-side
  and not read since the sweep first reached those files.

**The provider sweep now finds nothing real.** Re-run after this pass
it reports four names, and all four are the known false positive — the
screen reads the same thing through the repository directly:
`stockTransferLinesProvider`, `itemModifierGroupIdsProvider`,
`posRecipeLinesProvider`, `contactMembershipsProvider`. Check each for
a bare `.methodName(` before believing any future report of them.

It reported eleven at `142c05b`, seven of them real:

- **`creditLedger`** — the OCR credit ledger. Scanning charges are
  taken and the ledger behind them cannot be read.
- **`depositsHeldFor`** — what a party has on deposit, which is the
  figure somebody wants *before* raising the invoice the deposit was
  taken for. The apply sheet reaches the deposit from the other end.
- **`chatUnread`**, **`itemConversionOutputs`**, **`posQueueDay`**,
  **`posRecipeRequirement`**, **`posServiceProviders`**.

`attendance` was an eighth until this pass, and is now the attendance
month.

**All seven are now closed**, at `f9aabfb` through `f37c8ea`. In order:

- **`creditLedger`** → "Where it went" on the credit balance
  (`c27dfb6`).
- **`depositsHeldFor`** → a deposit banner beside the credit banner in
  the document editor, so the figure is there before the invoice goes
  out rather than after (`5cd9816`).
- **`posRecipeRequirement`** → the "Why" beside the countdown, which
  the repository already described as "the list that explains why the
  countdown says four" (`f9aabfb`).
- **`itemConversionOutputs`** → the conversions list could say a
  chicken becomes "3 things" and never which three
  (`1d94086`). `supabase/tests/stock_transfers.sql` asserts the order
  the cost shares come back in "because the screen edits them in
  place"; the screen did not exist.
- **`posQueueDay`** → `0257` argues that the paper by the door was
  worth replacing because it "does not exist at all by Monday, so
  nobody ever learns whether Saturday's wait is twenty minutes or
  fifty". The function that answers it was watched by nothing
  (`d692db0`).
- **`posServiceProviders`** → the sharpest of the seven, and the reason
  this sweep is worth running. `book_appointment` asks
  `app.pos_provider_is_open`, which is an `exists` over
  `pos_provider_hours`. A provider with no rows there is open at **no**
  time. Nothing could write those rows — the table had no reader and no
  writer at all — so every booking a new salon tried to make was
  refused, by name: "Siti does not work then, or is away." Closed at
  `2c03404`, with the week, the time off and the people themselves.
- **`chatUnread`** → the provider's own doc comment says "for the badge
  on the rail". There was no badge, on the rail or anywhere else
  (`f37c8ea`).

Two of those seven were the same defect as the three named at the foot
of this file: not merely unreachable, but *contradicted by what the
screen said*. `chatUnread` documented a badge that did not exist, and
`pos_provider_is_open`'s refusal named a member of staff for a fact
nobody had ever been able to enter.

**The method sweep caught one of mine, in this pass, while I was
writing this section.** `deleteCorpResolution` went into
`corp_repository.dart` with the rest of the minute book and no button
ever called it — the same defect arriving fresh, from the same hand
that was documenting it. That is what the warning about
`depositNoteProvider` above is describing, and it is worth saying that
it caught the person who wrote the warning. Closed at `a7baa66`, with
a removal that says what it takes with it: a resolution once passed is
a matter of record, and anything generated from it stays and quietly
stops naming what authorised it.

Both lists were produced by the sweeps at the top of this file. Run
them again before believing this section: it is the part that goes
stale first, and the entry above about `corp_issued_capital` is what
that looks like when it does.

## Why this keeps happening

Of the eleven capabilities built in the sessions before this check, nine
were already in the schema with nothing able to reach them. Schema lands
ahead of behaviour in this codebase, consistently, and the gap is
invisible to every other check: the migrations apply, the tests pass,
the analyzer is clean, and the screens that exist all work.

The pass at `142c05b` says the same thing louder. Nineteen commits,
seventeen of them closing something the database had been able to do
for months. The pass that followed it, `5cd9816` to `832dc9e`, closed
seven more, and one of them had been sitting in the schema since
`0003` — the first migration this repository ever had.

Not one was found by a failing test, a failing analyzer or a red CI
run, because none of those can see it — a function nobody calls
is indistinguishable from a function nobody needs, to every automated
check this repository has.

Five of them were worse than unreachable, and those are the ones to
learn from: the screen said the thing it could not do. The budget grid
told people to "change the lines that matter" and had no editor. The
cash forecast's app bar claimed it used how late each customer actually
pays and could not show a single figure. The Timesheets screen invited
people to record hours against a project and had no way to write one.
The chat provider's own doc comment described a badge on the rail, and
there was no badge. And the worst of them was not a screen at all:
`book_appointment` refused every booking a new salon made, and blamed a
named member of staff — "Siti does not work then, or is away" — for
hours nobody had any way to enter.

A promise a screen cannot keep is not a gap in the schema's reach — it
is the product telling a user something untrue, and it will not turn up
in a migration review. When the untrue thing is a refusal that names a
person, it is not even recoverable by the user: there is nothing they
can do differently.

Run this check before planning a block of work, not after.
