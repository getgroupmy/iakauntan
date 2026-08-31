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

**One thing the SQL check gets wrong, found in the pass that closed
`payment_gateways_for`.** Grepping a function's name across `app/lib`
and `supabase/functions` misses the callers inside the database. Three
names came back unreferenced and only two were gaps: `pos_item_portions`
is called by `pos_item_availability`, which the till does reach, and no
Dart will ever mention it. Grep the migrations too, for the call shape
rather than the bare word — `create function`, `grant` and `comment on`
all name a function without calling it, and so does the paragraph in the
header explaining what it is for.

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
# The provider sweep, which cannot use `unreferenced` above.
#
# Seventeen files declare providers, not one, and running this against
# providers.dart alone hid `posOfflineProblemsProvider` -- the sales a
# till took and the server refused -- for exactly as long as the method
# sweep hid corpOpenFiling by opening only repository.dart. The same
# mistake, one layer up.
#
# But excluding every declaring file, the way `unreferenced` does, would
# then hide a provider declared in providers.dart and watched from
# chat_live.dart, which also declares one. So this counts references
# everywhere and subtracts the declaration itself.
PROVIDER = r'^final ([a-zA-Z0-9_]+Provider)\b'
declares, names = [], {}
for root, _, files in os.walk('lib/src'):
    for f in sorted(files):
        if not f.endswith('.dart'):
            continue
        path = os.path.join(root, f)
        found = re.findall(PROVIDER, open(path).read(), re.M)
        if found:
            declares.append(path)
        for n in found:
            names.setdefault(n, path)

seen = collections.Counter()
for root, _, files in os.walk('lib/src'):
    for f in files:
        if not f.endswith('.dart'):
            continue
        path = os.path.join(root, f)
        text = open(path).read()
        for n in names:
            hits = len(re.findall(r'\b' + re.escape(n) + r'\b', text))
            if path == names[n]:
                hits -= len(re.findall(r'^final ' + re.escape(n) + r'\b',
                                       text, re.M))
            seen[n] += hits

print(f'{len(declares)} files declare providers; {len(names)} providers.')
print(sorted(n for n in names if seen[n] == 0))
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

One trap in the provider sweep, and it is not the one it looks like.

A provider *seems* to be a false positive when the screen reads the
same thing through the repository directly — four of the eleven the
sweep reported at `142c05b` were that, and they were written off on
those grounds and carried forward as known-good through several passes.
Going back to check each one found the opposite. The screen calling
`repo.posRecipeLines(id)` and awaiting it is not evidence that
`posRecipeLinesProvider` is reached; it is evidence that nothing needs
it. All four were dead declarations wrapping a call somebody else was
already making, which is the *other* thing this section warns about —
"a provider you add and never watch is the same defect arriving fresh:
`depositNoteProvider` was added and removed inside one pass for exactly
that reason." Same defect, and it had been sitting in the register
labelled as an exception to itself.

So the check is not "does the screen call the method". It is "does
anything watch this provider", and if nothing does, the provider goes —
whether or not the capability behind it is reachable another way.
`contactMembershipsProvider`, `itemModifierGroupIdsProvider`,
`posRecipeLinesProvider` and `stockTransferLinesProvider` were all
deleted on those grounds.

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

- **Reference pickers**: `ref_countries`, `ref_tax_types` and
  `ref_einvoice_types` are typed by hand where they are used at all.

  **`ref_exemption_reasons` came off this list too, and it was not a
  picker that was missing — it was the field.** The tax code editor had
  a switch saying a code is exempt and nowhere to say why, so
  `tax_codes.exemption_reason` was null on every code any company ever
  created. `0015_einvoice_prepare` carries that column onto the
  e-Invoice line as `tax_exemption_reason`, which is where LHDN reads
  the ground for the claim. An exempt code now has to name one.

  **`ref_msic_codes` came off this list, and it was the worst of them.**
  Not merely typed by hand: the onboarding form declared an `_msicCode`,
  sent it to `create_organization`, and *nothing ever assigned it*, so
  every company created through that form was registered with no
  business activity at all. The company card asked for the five digits
  in a free-text box, against a table seeded in `0011` with a trigram
  index on the description put there so it could be searched by what a
  business actually does. A wrong MSIC code is a misstatement on the
  incorporation and on every annual return after it.

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

**The provider sweep, widened, now finds nothing real.** It reports
four names across all seventeen declaring files, and all four are the
known false positive — the screen reads the same thing through the
repository directly: `stockTransferLinesProvider`,
`itemModifierGroupIdsProvider`, `posRecipeLinesProvider`,
`contactMembershipsProvider`. Check each for a bare `.methodName(`
before believing any future report of them.

Widening it found one more, and it was the worst of the pass.
**`posOfflineProblemsProvider`** — declared in `offline_controller.dart`
rather than in `providers.dart`, so the narrow sweep never looked at
it. `0219` says what it holds: "Money crossed a counter for each of
these, so they are listed rather than logged and forgotten." A till
with no signal took a sale, the batch was refused when the signal came
back, and the only trace was a row nothing could read. Closed at
`941b946`.

The narrow sweep reported eleven at `142c05b`, seven of them real:

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

**Both platform-side methods turned out to be a third false positive of
the same shape as `notifyPush`.** `landingPreview` is called by
`landingPreviewProvider` and `navGrouping` by `navGroupingProvider`,
each declared in the very file that declares the method — which the
method sweep excludes. Both providers are watched: one by the landing
console, one by the shell itself. So the method sweep's blind spot is
not one odd case, it is a category: **a method whose only caller is a
provider beside it.** Check for that before believing any report.

That leaves four names, and none is a screen anybody is missing:
`callRpc` and `notifyPush` are that blind spot, `chatFileBytes` is
probably dead weight, and `acceptInvitation` needs an e-mail link that
does not exist.

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

- **The ways a company may pay** (`payment_gateways_for`). `0292` made
  `payment_gateways` readable by every signed-in user and said in the
  table's own comment why — "so that a company can be shown the ways it
  may pay" — and nothing showed them. What kept the reader from being
  called is worth writing down, because it is a shape that will happen
  again: `organizations.country_code` is alpha-3 and
  `payment_gateways.countries` is alpha-2, so a caller holding 'MYS' got
  an empty list rather than an error. A mismatch that returns nothing is
  worse than one that raises; nobody investigates an empty list.
  `0352` resolves both spellings in the database, and the settings screen
  now names what a company may pay with.

  The same migration closed the other half. `0295` added `countries`,
  `methods` and `docs_url` and seeded forty gateways with them, and
  `platform_save_payment_gateway` was never widened to take them — so a
  gateway added by hand had no coverage list, a seeded row could not be
  corrected, and the three check constraints `0295` wrote had never once
  refused a real caller. A column nobody can write is unreachable in the
  same way a function nobody calls is, and neither sweep looks for it:
  the table is read, the function is called, and the argument is missing.

- **The bank balance, and rebuilding it** (`resync_bank_balance`). It was
  called by the opening-balance importers and asserted in
  `bank_balance_resync.sql`, so it ran on every CI run — which is why
  neither sweep flagged it loudly and why it is worth writing down.
  *Exercised* is not *reachable*. Nothing a person could do in the app
  ran it.

  What made that matter is the other half: `current_balance` is a
  running total kept by twenty-three separate statements across thirteen
  migrations, and `BankAccount.currentBalance` was parsed out of every
  row and drawn nowhere. So a balance that had drifted from the ledger
  could be neither seen nor repaired. A Book balance action on the
  reconciliation screen — where somebody is already comparing a balance
  against a statement — shows the figure and offers the rebuild, and
  says whether the number moved. Saying so is the point: a repair that
  silently corrects a figure teaches nobody that something posted
  against the bank's GL account without going through the total.

- **Taking up an invitation** (`accept_invitation`), and what looking for
  its caller found. The function has had none since `0022`. The only
  invitation that ever worked was the accidental one:
  `app.handle_new_user` claims a pending row when somebody *signs up* at
  that address, so an accountant who already had an account could be
  invited to a second company, never hear about it, and watch the row
  expire in a fortnight. No e-mail carries the token and no screen
  showed it.

  Looking for the caller found the reason it was safer without one, and
  this is the sweep's best result so far, because it is not a missing
  feature — it is a hole. Reproduced on a database rather than reasoned
  about: a `viewer` reads a pending invitation's `invite_token` straight
  off `org_members`, which `org_members_select` lets any member of the
  company do; `accept_invitation` checks the token, the status and the
  expiry and never checks who is calling; so the viewer hands the token
  to anybody at all and that person — never invited, at an address
  nobody typed — becomes an `admin` on a row still addressed to somebody
  else. The unique key on `(org_id, user_id)` stops the viewer using it
  themselves, which is luck: it means the escalation needs a second
  account.

  `0353` brings the invitation onto the idiom `0070` already
  established for signing links — the token is stored as a digest and
  returned raw exactly once — and adds the check the function was
  missing: the caller must be signed in as the address the invitation
  names. `invite_member` hands the raw token back so there is something
  to give somebody, the Team screen shows it once, and Settings takes
  one.

  **The lesson for the sweep**: a function with no caller is not always
  a feature waiting to be reached. Read what it would do before reaching
  it.

- **Deleted rather than reached: `chatFileBytes`.** It downloads a chat
  attachment into memory, and every screen that shows one asks
  `chatFileUrl` for a signed link and opens it — images included. There
  was no capability behind it going unused, only a second way to do
  something already done, so it went. Not every name a sweep returns is
  a gap; some are just code nobody needs.

## A third sweep: a table nothing touches

The two above find what the *app* cannot reach. Neither finds a table
that nothing anywhere writes — the SQL check counts a table as reached
when a function names it, and the Dart sweeps never see one at all.

```python
# Run from the repository root. Every base table, against the app and
# the edge functions, and then against the bodies of the migrations
# themselves. A name has to appear in a call shape — after from, join,
# into, update, delete or references — because `create table`, `grant`
# and `comment on` all name a table without touching it, and so does the
# paragraph in a migration header explaining what it is for.
```

Three of 303 came back the first time it was run, and the difference
between them is worth keeping:

- **`inbound_email_attachments`** was a real loss, closed in `0354`. See
  below.
- **`ticket_team_members`** was a design nobody finished, closed in
  `0355`. See below.
- **`fs_disclosures`** is the narrative MBRS asks for alongside the
  figures, and filling it needs a disclosure taxonomy this repository
  does not have. Deliberately not invented: making up statutory codes
  and presenting a filing as complete is a worse failure than an empty
  table.

- **The bill somebody e-mailed you** (`inbound_email_attachments`).
  `0328` built the table, a read policy scoped to the company whose
  mailbox the message arrived at, and the `select` grant — and the
  ingest path never wrote a row. `cloudflare/email-router/worker.js`
  kept the two MIME parts it recognised and dropped every other one, so
  a supplier e-mailing a PDF invoice got the covering note filed and the
  invoice discarded.

  This is the worst shape a gap can have, and worth naming: **it looks
  like the absence of a thing rather than the failure of one**. The
  message is there, it reads as the whole of what was sent, and the only
  clue is a sentence in the body about an attachment that is not
  attached. A crash would have been kinder.

  `0354` gives it a bucket, a writer the ingest path alone can reach,
  and a reader for the app. The MIME parsing moved into a module of its
  own so it could be asserted, because every way of getting it wrong is
  quiet in the same direction: an empty attachment list is
  indistinguishable from a message that had none.

- **Who is actually on a support team** (`ticket_team_members`). `0192`
  created the table, its policies and every grant it needs, and nothing
  ever wrote a row. Worse, `ticket_teams` was reachable only to *filter*
  by and to label a row with — there was no way to create one — so every
  team in existence came from a demo seed, and routing was a label
  rather than a decision. "Assign it to somebody on Billing" had no
  answer: `assign_ticket` checked only that the person was an active
  member of the company.

  `0355` makes the list mean something and, when it is empty, decline
  to: a ticket on a team whose membership has been filled in may only be
  handed to somebody on that team, and a team with nobody on it accepts
  anybody. That degradation is `0264`'s `block_out_of_stock` reasoning —
  "a warung that has never weighed its rice would find every sale
  blocked by a number nobody maintains" — and it is the half asserted
  hardest, on both sides of the wire, because getting it wrong makes
  every ticket in every company that never opened the list unassignable.

  Two things the pass turned up on the way. A `v_t.team_id is not null`
  guard that read as obviously necessary and was not — `where team_id =
  null` is never true, so a ticket on no team already falls through the
  same way an empty team does — deleted rather than asserted around. And
  a roster ordering that no test could see, because the fixture had one
  member in it: "leads first" is only a claim when there are two.

## A fourth sweep: a decision no test can call

The three above ask what cannot be *reached*. This one asks what cannot
be *asserted*, which turns out to be a different set.

```python
# Run from app/. Every top-level function declared in lib/src, against
# every name any test mentions. Only lines with no leading whitespace,
# so class members are left out — those are reached through their widget
# and are a different question.
```

352 top-level functions, 68 named by no test. Most are `showX` dialog
openers and platform stubs, which are entry points rather than
decisions. Four were neither, and they had all been skipped for the same
structural reason: they took a `BuildContext` and returned a `Color`, so
reading the answer back needed a widget test, and none was written.

The colour was never the point. `varianceTone`, `weekTone`, `marginTone`
and `chequeTone` each state something about the business — this variance
is unfavourable, this week the bank closes short, this bundle is priced
under its own parts, this cheque should have been banked and was not —
and red is how one of them is shown. Separating the claim from its
presentation made all four assertable, and a wrong one is silent: a
favourable variance in red reads as bad news about a good month.

None of the four was wrong. That is the useful result and not a wasted
pass — `varianceColour` reading `favourable` rather than the sign of the
variance is exactly the thing `0274` wrote a column to make possible,
and until now nothing would have noticed if a later edit had "simplified"
it to `v > 0`. Something does now.


## A fifth sweep: a function nothing ever starts

The first four ask who *may* call something. This one asks who *does* —
and specifically the case where the answer was meant to be a clock.

The other four sweeps are blind to it by construction. A periodic
function is reached by nothing in `app/lib` and nothing in
`supabase/functions`, correctly, because a scheduler is neither. It has
its grants revoked from `authenticated` and `anon`, correctly, for the
same reason. It has a test file that calls it and passes. Every signal
those sweeps read says the function is fine, and it has never once run.

```sql
-- Run against a migrated database. What the scheduler can get to,
-- starting from the cron commands and walking through the bodies.
-- `supabase/tests/scheduled_work.sql` is this, as an assertion.
select jobname, schedule, command from cron.job;
```

Grep found five functions no Dart and no Deno names: `pos_item_portions`
and `corp_issued_capital` are called from inside other SQL and are fine,
`chat_expire_calls` and `prune_device_tokens` were the subject of `0147`
and are in the nightly run, and the fifth was not.

- **The SLA clock nobody wound** (`ticket_sla_sweep`). `0193` wrote it
  over business hours, public holidays and four states that do not run
  Monday to Friday. `0194` built the ticket lifecycle around it. `0195`
  calls it once while seeding a demo. `supabase/tests/ticketing.sql`
  asserts its arithmetic to the minute, and a comment in that file
  reasons about not re-alerting "every five minutes" — the author
  assumed a scheduler that was never written. Nothing in production ever
  called it.

  The deadlines themselves were right: `response_due_at` is computed
  when the ticket is raised and `ticketing.sql` proves it. What never
  happened was the moment they passed. `response_breached` stayed false
  forever, no `sla_breach` row was ever written, and a support manager
  reading the board saw nothing wrong with it while every promise on it
  had gone. `0356` schedules it every five minutes — its own job, so a
  failure in it cannot take the recurring invoices down with it, and
  five rather than nightly because `sla_targets.response_minutes` only
  has to be greater than zero and a fifteen-minute P1 is an ordinary
  line in a support contract.

  Two indexes come with it. The cron command passes no organization, so
  the sweep runs across every tenant at once and `tickets_open_deadlines`
  — leading on `org_id` — cannot serve it; two hundred and eighty-eight
  scans of the ticket table a day is not a cost worth carrying. Both new
  predicates exclude tickets already marked, so a ticket leaves the
  index the moment the sweep has dealt with it.

`supabase/tests/scheduled_work.sql` is the sweep kept. It walks out from
the `cron.job` commands through the function bodies and asserts that
each of the twelve functions whose only correct caller is a scheduler is
somewhere in what it reaches. The list of twelve is the claim, and a
periodic function added without a line in it is not covered — the same
bargain as adding a test file to `ci.yml`.

It also asserts the cadence, because "scheduled" and "scheduled often
enough" are different facts and only one of them was ever in doubt; and
that the sweep works in the shape the scheduler calls it in, with no
argument, across every tenant at once, which `ticketing.sql` never did.

## A sixth angle: a value the database allows and the app cannot say

The same shape as the fifth, one layer up. A Postgres enum is a list of
what is *permitted*; a Dart map is a list of what is *offered*. Nothing
holds the two together, and when they drift the app is the half that
loses — quietly, because an option that is not in a dropdown looks
exactly like an option that does not exist.

```python
# Every `create type app.X as enum` and every `alter type app.X add
# value` in the migrations, against the map or list the app builds its
# picker from. Mind the `after` clause: it decides the enum's order,
# and a reconstruction that appends in file order gets it wrong.
```

- **The HR manager nobody could appoint** (`app.member_role.hr_manager`).
  `0024` added it. `app.can_manage_hr` and `app.can_run_payroll` are
  *defined* by it, `0119` and `0121` route expense claims to it, and
  `0285` was written for exactly that person — "an owner running their
  own company, or an outsourced HR administrator". `memberRoles` in
  `models.dart` never gained the value, and both role dropdowns are
  built from that map, so for two years the role existed and no company
  could hand it to anybody. Payroll and leave approval were delegable in
  the database and admin-only in the app, which is the opposite of what
  a delegable role is for.

  `employee`, added by the same migration, is deliberately still not
  offered, and the reason is the opposite one: no SQL anywhere reads it.
  It is in no `has_org_role` array, no policy and no guard, and
  self-service is scoped by `app.my_employee_id` rather than by the
  role — so an `employee` may do precisely what a `viewer` may do.
  Offering both would sell a distinction the database does not make, and
  somebody would read "Employee" as narrower than "View Only" and give
  away more than they meant to. `notOffered` in
  `app/test/member_roles_test.dart` is where to delete it from when
  something enforces the difference.

`app/test/member_roles_test.dart` reconstructs the enum from the
migrations — honouring `after`, which is what puts `hr_manager` fourth
rather than last — and asserts the cover both ways, plus the order,
because the map's order is the dropdown's order and reads as descending
authority. `supabase/tests/hr_manager_role.sql` asserts the other half:
the sentence beside the new option in the invite dialog is a promise
about what the database will allow, so it is asserted as one. An HR
manager runs payroll and does not get `can_post`, `can_read_ledger`,
`can_write` or `can_admin` with it — the refusals being the half worth
having, since a role that grants too little is a complaint on the first
day and a role that quietly grants the ledger is a segregation-of-duties
failure nobody sees until an auditor asks who could post.

### The same sweep, run over the document types

`docTypes` in `app/lib/src/features/documents/doc_types.dart` is the
table one editor serves the whole sales and purchase cycle from, and it
is the same shape of hand-written list as `memberRoles`: eleven rows
against fifteen enum values across `sales_doc_type` and
`purchase_doc_type`. Three of the four missing were fully implemented in
SQL and unreachable from the app; the fourth is genuinely unfinished and
stays out.

- **`refund_note`** — LHDN e-Invoice type **04**. MyInvois recognises 01
  Invoice, 02 Credit Note, 03 Debit Note and 04 Refund Note; `0015` maps
  all four and raises on anything else, `0013` gives a refund note the
  same negative sign a credit note gets, `0096` ages it and
  `report_sst_summary` counts its output tax. A company using this could
  issue three of the four statutory documents, and nothing said which
  one was missing.
- **`purchase_debit_note`** — the supplier billing for an undercharge.
  `0013` posts it, `0096` ages it beside the bill it belongs to, and
  `report_sst_summary` counts its input tax. The missing row was a
  claimable tax credit with no way to enter it.
- **`proforma`** — posts nothing, correctly. `0081` has accepted
  `proforma → invoice` since it was written and `transferTargets` in
  Dart has listed it; with no way to raise the source, the path was
  never once walked.
- **`purchase_return`** stays out, and is the useful contrast. No
  posting path accepts it — `0013` and `0097` both list the purchase
  types they will post and it is not among them. The word does appear in
  the migrations, as a `stock_movement_type`: the goods going back,
  which is a movement rather than a document. A row for it would put an
  entry in the menu that raises a draft nothing can post, with the
  refusal arriving after the lines are typed. `notRaisable` in
  `app/test/doc_types_test.dart` is where to delete it from.

The pattern across all three sweeps of this kind is worth stating on its
own, because it is not the one the earlier passes were looking for. A
list in Dart of something the database enumerates does not fail loudly
when it falls behind; it fails as an **absence**, and an option that is
not in a menu is indistinguishable from an option that does not exist.
Nobody files a bug against a feature they have no way to know is there.
The fix is always the same shape — read the enum rather than copy it,
assert the cover in both directions, and name each deliberate exclusion
next to the reason it is one.

### And once more, over the tender kinds

`app.pos_tender_kind` lists seven ways a counter sale can be paid for.
`complete_pos_sale` recognised exactly one of them — `cash` — and
everything else fell into a single `else`. That is right for a card and
an e-wallet and a bank transfer, all of which are money that has
arrived. It is wrong for **`on_account`**, which is a promise.

- **The sale nobody paid for** (`on_account`). The sale raised its
  invoice, then wrote and posted a receipt for the whole basket, so the
  receivable the invoice had just created was cleared by a payment
  nobody had made — into the current account, because an on-account
  tender has no bank account and `post_receipt_internal` falls through
  to `1120`. A shop running accounts for regulars would show cash it
  never took, a debtors ledger that never grew, and a phantom deposit on
  every account sale in the bank reconciliation.

  This one is worth studying rather than just fixing, because it breaks
  the pattern the three sweeps above share. Those were **absences**: a
  menu entry missing, an option unofferable, a function nothing called.
  This is a **falsehood** — the sale completes, the journal balances,
  the till reconciles, and the books state a transaction that did not
  happen. An absence is invisible; a falsehood is worse, because
  everything downstream reads it as true and agrees with it.

  It is also invisible to every sweep in this document. `on_account` is
  named by the enum, reachable from the app, and covered by tests that
  pass. The only thing that finds it is asking what a value *means*, one
  value at a time, and noticing that the code has an answer for six of
  the seven. `0357` gives it the seventh.

  The one honest general lesson: a `case` or an `if/else` over an enum
  where the last branch is `else` is a place where a new value gets a
  silent default. Grep for those before trusting an enum is handled.

### A pair of enum values that only mean anything together

`app.client_txn_type` has six values and the matter screen's dropdown
offers four. `refund` and `transfer_to_office` are there; `transfer_in`
and `transfer_out` — "moved from another matter", says `0021`'s own
comment — never were. `matter_detail_screen.dart` even has a
`_isMoneyIn` that already knows `transfer_in` counts as money in, which
is where the design stopped.

- **The client's money, moved between their own matters** (`0358`). A
  client finishes a conveyance with a balance still held and starts a
  tenancy; the deposit follows them. Without this the firm's only route
  is to refund it out of the client account and take it back in — two
  bank movements to record a transfer that never left the bank, and a
  withdrawal from a client account that did not have to happen.

  What makes this one different from the missing document types is that
  **the fix could not be a dropdown entry**. A `transfer_out` on its own
  is money taken off a matter and put nowhere: posted exactly like a
  payment, reconcilable against nothing, and indistinguishable from the
  correct version until somebody adds up the client account. Two more
  menu items would have made the wrong thing the easy thing. So the
  pair is written by one function or not at all, and the enum values
  stay unofferable individually on purpose.

  `0021` built the overdraw control as a **deferrable** constraint
  trigger. That was foresight — a paired write needs both legs to land
  before the balances are checked — and this is the thing it was
  foreseeing.

Two findings came out of the mutation run rather than the reading, and
both are worth keeping:

- **A deferred trigger does not refuse in time.** Removing
  `transfer_between_matters`' own balance check made the test fail while
  `assert_client_funds` stayed completely silent, because
  `deferrable initially deferred` means it fires at commit and the test
  never commits. That is not a test artefact: any session that does
  several things before committing gets the same silence, and by the
  time the trigger speaks the caller has acted on a transfer that is
  about to be rejected. The trigger is the control; the check is the
  refusal. Neither is redundant.
- **`if/else` over an enum hides the next value.** `complete_pos_sale`
  matched `cash` and put everything else in one `else`; that is how
  `on_account` came to mean nothing for nine migrations. Before trusting
  that an enum is handled, find the `else` and the `_ =>` and ask what
  falls into them.

### The whole list, mechanically

The three passes above each found their enum by hand. The general
version is short and worth keeping, because it produced a list of seven
in one run:

```python
# Every `create type app.X as enum` and every `add value`, against the
# migrations with the declarations blanked out, and against app/lib and
# the edge functions. A value that appears in neither is a state
# nothing can ever produce.
```

    activity_type       task
    pay_frequency       semi_monthly
    attendance_status   absent, on_leave, incomplete
    clock_method        biometric
    corp_filing_status  awaiting_signature
    pos_shift_status    counting
    pos_tender_kind     voucher

Not all seven are gaps, and saying which are is the whole value of the
list. `biometric` needs hardware nobody has wired up and is honestly
unbuilt. `voucher` is a `pos_tender_types` row a shop can create today
and it behaves like a card, which is right. `semi_monthly` was the
subject of `0359` and is now constrained away rather than pretended at.
The three under `attendance_status` were the real find.

- **The day nobody clocked in** (`0360`). `clock_out` sets
  `public_holiday`, `rest_day`, `late` or `present`, and that is every
  write `attendance_records.status` has ever had. The three it could not
  produce are the three about somebody who was *not* there, and they
  fail in the two different ways this document keeps distinguishing:

  `incomplete` is a **falsehood**. A row with a clock-in and no
  clock-out keeps `status = 'present'` with `worked_minutes = 0`, so a
  register grouped by status — which is what a register is for — counts
  a forgotten punch-out as an ordinary day's attendance.

  `absent` and `on_leave` are **absences**, and the shape of an absence
  here is that there is no row at all. "Who was away yesterday" had no
  answer. It is also why the payroll's unpaid-leave arithmetic reads
  `leave_requests` directly: attendance could not tell it.

  `close_attendance_day` runs from the nightly job over yesterday.
  Nobody without a roster is marked, on the reasoning `0264` used for
  `block_out_of_stock` and `0355` for an empty ticket team: a control
  nobody maintains must not start refusing, and a red mark against every
  employee in a company that has not filled the roster in is worse than
  no mark at all.

  The mutation run earned its keep twice. It killed the roster, rest-day,
  holiday and punch-out branches, and it left `status = 'approved'`
  alive — the fixture's only leave request was already approved, so
  nothing noticed when the check was relaxed. The missing case is the
  employee who asked for the day, was refused, and did not come in
  anyway: without it, a rejected request would have excused the absence
  it was refused for.

- **The minutes while the drawer is counted** (`pos_shift_status.counting`,
  closed in `0361`). `open_pos_shift` wrote `open`, `close_pos_shift`
  wrote `closed`, in one step, and the state that exists for the minutes
  in between was never reached.

  Those minutes are the point. `close_pos_shift` works out
  `expected_cash` at the moment it is called, so anything rung up
  between the count and the close is in the expected figure and not in
  the pile of notes on the counter. The variance is then wrong by
  exactly that sale, and it is recorded against whoever counted.
  `0206`'s own comment on selling with no shift open says it — "selling
  into a drawer nobody has counted is how a variance becomes
  unattributable" — and this is the same failure a few minutes later.

  No new button. `_closeShift` calls `begin_pos_count` before asking for
  the figure rather than after, so pressing Cash up stops the till, and
  cancelling at the prompt puts it back. `resume_pos_shift` exists for
  that second half: a stopped till nobody can restart is how a shift
  gets closed early to take one customer.

  And a third mutation-run finding, the same shape as `0358`'s.
  `pos_shifts_closed_ck` already makes reopening a closed shift
  impossible, so removing that guard from `resume_pos_shift` failed
  nothing — the test only asked whether it was refused. What the guard
  adds is the sentence: without it somebody gets `violates check
  constraint "pos_shifts_closed_ck"` instead of "Open a new one to keep
  selling". The assertion now checks the words, and the mutant dies on
  the constraint's own error text, which makes the point better than
  the comment does.

The last two of the seven are recorded here as decisions rather than
closed, for the same reason `fs_disclosures` is:

- **`corp_filing_status.awaiting_signature`** needs a link that does not
  exist. Signature requests hang off `corp_documents`; a filing links
  only to a `corp_resolution`, and there is no path from one to the
  other. Worse, `ensure_corp_filing`'s `on conflict do update` resets
  anything that is not `lodged` or `approved` back to `in_preparation`,
  so the state would be clobbered the next time the deadline engine ran
  over it. Reaching it properly means designing the filing-to-document
  link and teaching that upsert which states it may not overwrite —
  a feature, not a gap to close, and inventing half of it would put a
  status on a statutory filing that the engine then silently reverses.
- **`clock_method.biometric`** needs a fingerprint reader nobody has
  wired up. It is honestly unbuilt and there is nothing to close.

And `pos_tender_kind.voucher` is not a gap at all: `pos_tender_types` is
data, a shop can create a voucher tender today, and it behaves like a
card. The enum value being unwritten in any migration is what a
data-driven table looks like from a sweep, which is worth knowing before
the next one of these produces the same false positive.

## A seventh sweep: a column one side of the wire uses and the other cannot

The enum sweeps ask which *values* of a column are unreachable. This
one asks the same question of the column itself, and it turns out to
have two distinct answers that need telling apart.

```python
# Every column of every base table, against app/lib and the edge
# functions, and against the migrations with the declaration blanked
# out. Then read the list by hand: the mechanical part cannot tell the
# two cases below apart, and the difference is the whole finding.
```

- **The engine reads it and nothing can set it.** The gap is entirely
  on the app side, the arithmetic is already right, and the fix is a
  form field. This is the valuable case.
- **Nothing reads it at all.** A column somebody declared and never
  wired up. Mostly harmless — until it is a control, at which point the
  name on the column is a promise nothing keeps.

Both showed up, and one of each was statutory:

- **The four payroll figures nothing could enter.**
  `employees.cp38_monthly` is deducted on top of PCB and remitted with
  it by `post_payroll_run`; `zakat_monthly` is passed into the PCB
  calculation as a rebate, and `statutory.sql` has asserted since it was
  written that PCB falls by the zakat paid — on data nothing could
  enter. The two `epf_voluntary_*_rate` columns are added to the
  contributions. All four were read and none appeared on any screen. A
  CP38 direction from LHDN had nowhere to go, so the arrears were not
  deducted and the return was filed short; zakat left at zero over-taxes
  a Muslim employee every month of the year.

  The voluntary rate is the one worth the module of its own, because it
  is a **unit** trap rather than a typo. The engine divides by 100, so
  two points above the statutory rate is `2`. `0.02` is refused now, in
  both directions, with the sentence saying which unit is meant —
  otherwise it contributes a two-hundredth of what was meant, looks
  plausible on every payslip, and is discovered at retirement.

- **A control nothing enforced.** `contacts.credit_hold` has been a
  column since `0003` and no SQL read it and no screen set it, sitting
  beside the whole of `0086`'s credit control doing nothing. `0362`
  makes it refuse an invoice whatever the organization's mode says,
  because a hold is somebody's instruction rather than arithmetic, and
  the asymmetry with the limit is deliberate: the limit obeys the mode,
  the hold overrides it.

- **And a state this document's own work had stranded.** `0360` made
  `incomplete` reachable and `clock_out` only ever touches *today's*
  record, so the day it marked could never be closed. `0027` had
  anticipated the correction and got as far as `is_adjusted`,
  `adjusted_by` and `adjustment_reason`, which nothing had ever written.
  `0363` writes them.

  Worth recording as a caution: closing a gap can open one, and this one
  was opened by the pass immediately before it. The check is the same
  question asked of the new state — once `incomplete` exists, what
  leaves it?

Two things the mutation runs taught, both about arithmetic that turned
out to be less shared than it looked:

- Rewiring `clock_out` through `app.recompute_attendance` turned an
  existing assertion from `present` to `late`, which was not a bug in
  either. Clocking out must not make somebody retrospectively late —
  lateness is a fact about the morning — and a correction must, because
  the arrival time is what changed. The two callers now say which they
  want, and the flag exists because the test refused to let them be the
  same.
- The local harness reads CI's SQL test list out of the workflow, and
  the guard added to that workflow introduced a second `for f in
  supabase/tests/...` loop over a glob. The non-greedy match found the
  glob first, ran nothing, and printed "all SQL assertions passed (0
  files)" in green. Only the count gave it away. It now takes the loop
  naming the most files and refuses to report success on an empty run —
  which is the failure the guard exists to catch, arriving from the
  other side of it.

- **The claim cap that was only a number** (`0364`). `claim_types`
  carries `per_claim_cap`, `monthly_cap` and `annual_cap`; the HR setup
  screen offers two of them and prints "up to RM 200" beside the type.
  No SQL had ever read any of the three.

  This is the sharpest form the second case takes. `credit_hold` did
  nothing and nothing said otherwise; here a screen shows a limit, so a
  company sets one believing claims above it will be stopped, and finds
  out by reading the ledger.

  Two things about it are worth keeping, and both came from being
  wrong first.

  The obvious place to enforce a cap is the claim becoming `submitted`.
  That alone enforces nothing, because `createClaim` inserts the claim
  row as `submitted` **and then** inserts its lines — so the trigger
  sees a claim with nothing on it and passes. The first version did
  exactly that and every test went green. The check now hangs off the
  lines as well, `after` rather than `before`, because a multi-row
  insert has to have finished for the total to be the total.

  And the mutation that removed the line trigger **survived**, on a warm
  database, because the file no longer dropped the trigger the previous
  run had created. Re-run through a full rebuild it died immediately.
  That is the same trap `create index if not exists` set earlier in this
  document: a mutation that removes a `create` has to be run against a
  database that never had it.

`requires_receipt` is left alone deliberately. The receipt is an
`attachments` row against the claim rather than the line, so "this type
needs a receipt" and "this claim has one" are questions at different
grains — one attachment on a five-line claim satisfies it, or does not,
and which is a policy decision rather than a bug to fix in passing.
`claim_types.is_mileage`, `rate_per_unit` and `unit_label` are the same
kind of unfinished: the columns for quantity × rate are on
`expense_claim_lines` already, and what is missing is a screen that
multiplies them.

- **The leave type's rules, which were only labels** (`0365`).
  `leave_types.allow_half_day` and `carry_forward_expiry_months`, both
  since `0027`, both unread. A type marked whole-days-only took half
  days and the balance moved by 0.5 with nothing said; and carried leave
  never lapsed.

  The second is the one with a figure in the accounts attached. `0058`
  wrote the carry-forward cap because "silently rolling everything
  forward is how leave liability grows unnoticed" — and a cap only
  bounds one year's roll. A company whose policy is "carry five days,
  use them by March" carried them and kept them for ever.

  `leave_balances` has one `taken_days` and not one per source, so which
  days were used cannot be read off the row. The convention that answers
  it is the ordinary one and the one that favours the employee — carried
  days go first, because they are the ones with an expiry — which makes
  what survives exactly `least(taken_days, carried_forward)`, and
  idempotent by construction.

  A fourth surviving mutant, and the third of the session to point at a
  missing fixture case rather than dead code. Removing the
  `carry_forward_expiry_months > 0` filter broke nothing, because
  `make_interval(months => null)` is null and the date comparison
  excluded the null type anyway. The case it guards is a company that
  types **nought** — meaning "no expiry", not "lapses on the first of
  January". Added, and the mutant dies.

- **A contact with a control account of its own** (`contacts`
  `receivable_account_id` and `payable_account_id`). Columns since
  `0003`, read by `0013` in four places — the invoice, the bill, the
  receipt and the payment each fall back to `1210` and `2110` only when
  the contact names nothing — and settable on no screen. The arithmetic
  was written, correct, and had never once been exercised.

  This is the first case of the seventh sweep in its purest form: the
  gap is entirely on the app side, and closing it is two dropdowns and
  a test. What made it worth doing rather than filing is that a balance
  owed by a related party is disclosed separately under MPERS, and a
  control account of its own is how that comes out of a ledger at all.

  The list a dropdown offers is the whole of the decision, so it is a
  function of its own and asserted separately: the matching subtype
  only, no group headings, nothing retired. Pointed at the bank instead,
  a customer's balance posts into cash and the aged listing — which
  reconciles against the control account — stops agreeing with the
  ledger without saying why.

- **The reminder that never arrived** (`activities.reminder_at`,
  `reminder_sent`). Columns since `0008`, written by nothing, read by
  nothing, offered on no screen. A salesperson who set a reminder to
  ring somebody back was reminded by nothing, and the column recording
  that the reminder had gone stayed false because it had.

  `0356`'s shape one table over, with the difference that
  `ticket_sla_sweep` at least existed to be scheduled — here the sweep
  had to be written as well as driven. It queues into `email_outbox`
  rather than inventing a notification table, because the outbox exists,
  is drained, carries a dedupe key, and is already how this system tells
  somebody something.

  Two decisions the tests hold. The reminder goes to `assigned_to` and
  an activity assigned to nobody is skipped rather than sent to whoever
  created it — a reminder addressed to somebody who did not ask for it
  is how people learn to ignore them. And a completed or cancelled
  activity is never reminded about: being told to make a call you made
  yesterday teaches people the reminders are wrong, and after that the
  useful ones are ignored too.

  The latency is written down rather than pretended away. Fifteen
  minutes to queue plus the outbox's own half-hourly drain means a
  reminder set for half past nine arrives some time before eleven, which
  makes this a nudge and not an alarm. Anything tighter is a decision
  about GitHub Actions minutes in `send-email.yml`, not about reminders.

- **The column that proves the others** (`bank_transactions.running_balance`).
  A column since `0006`, written by nothing. `0085`'s import reads a
  date, an amount, a description and a reference out of each statement
  row and drops the balance the bank printed beside them.

  This is the *nothing reads it at all* case, and it is the one where
  that shape does real damage — because a running balance is not another
  figure to record. It is the only figure on a statement that can be
  checked against the rest of the statement. Every other column is a
  claim; the balance is the arithmetic those claims have to satisfy.

  Two failures were live because of it, and both are silent.

  A line that never arrives. A paste that clips the last rows, an export
  that pages at fifty, a row the parser could not read: the import
  reports what it took and cannot say anything about what it did not.
  The account is short by that transaction, `complete_bank_reconciliation`
  correctly refuses to close, and the person holding the difference has
  no idea which line to go and find. `0369` walks the chain — this
  balance is the last one plus this amount — and refuses the statement
  naming the two lines it cannot bridge.

  And the opposite, caused by the fix for the first. `0085` skips a row
  identical to one already on the account so an overlapping month does
  not double its shared days. But two identical lines on one day are
  ordinary — two RM 50 cash withdrawals, two standing orders to the same
  payee — and the importer could not tell those from a re-import. It
  dropped the second one every time. The running balance separates them:
  two genuine withdrawals have two different balances after them, the
  same line imported twice has the same balance both times. So the
  balance goes into the key and both failures close at once.

  Two things the mutation run taught. Statements come both ways round,
  and a newest-first export checked forwards fails on its very first
  pair — the message would blame a missing line for what is only the
  order, which is worse than no check, so the direction is read off the
  dates and the chain is walked the way the statement runs. And the
  closing figure is a *choice* rather than a lookup: with two lines on
  the last day it is the last of them going forwards and the first of
  them going backwards. The fixture had strictly decreasing dates and
  the mutant that ignores direction survived — not dead code, a missing
  case, for the fourth time in this document.

  The closing balance is handed back and fills the statement-balance
  field. `bank_reconciliation_status` subtracts a number somebody types
  from the books, so a slip in it is a difference that is not there —
  and the hunt for it goes through the lines, which are fine.

- **A statutory rate charged on the wrong base**
  (`salary_components.is_hrdf_liable`). The most expensive find of this
  sweep, and the shape it takes is new: not a column nothing reads, but
  a column nothing reads *sitting in a row of three that everything
  reads*. `is_taxable`, `is_epf_liable`, `is_socso_liable` and
  `is_eis_liable` all reach the payslip line and all decide a wage base.
  The fourth was declared in `0028` beside them and read by nothing, and
  `0043` charged the HRD Corp levy on the EPF wage instead.

  Those are different wages by statute. The PSMB Act 2001 counts basic
  salary and fixed allowances; HRD Corp's guidance excludes overtime,
  commission, bonus and other incentives, service charge, travelling
  allowance, gratuity, and payments on retirement, retrenchment or
  termination. EPF is payable on most of them. A bonus is the ordinary
  case: one or two months' salary once a year, levied at one per cent on
  wages the Act says are not wages, while the other eleven months agree
  to the ringgit — which is exactly what kept it invisible.

  Overtime was already outside the figure, and that is the part worth
  recording. It was outside because EPF is not payable on overtime, so
  the EPF wage happened to exclude it. A correct number standing on the
  wrong statute is not a correct number; it is one waiting for the two
  statutes to disagree.

  `0370` gives `payslip_lines` the fourth flag, sums an `hrdf_wage`
  beside the other three bases, charges the levy on it, and puts the
  base on the payslip — so a company disagreeing with a HRD Corp
  statement can see whether it disagrees about the base or the rate.

  The backfill is the interesting decision. It sets `is_hrdf_liable` to
  `is_epf_liable` on every existing line — to what was done, not to what
  was right. A payslip records what was paid and what was remitted, and
  restating it would leave the stored levy disagreeing with the stored
  base: a payslip that no longer explains itself. The history now says
  plainly that the EPF wage was treated as the levy wage, which is also
  what makes the difference for a past month computable. It is the one
  part of `0370` no assertion covers, because migrations apply in order
  onto an empty database and there is no history there to backfill.

- **A control that appeared to have been applied**
  (`employees.last_working_date`, `resignation_date`,
  `termination_reason`). The worst find in this document, and it is a
  different failure from everything above it.

  The employee editor has offered Resigned, Terminated and Retired since
  it was written. `calculate_payroll_run` has never read
  `employment_status`. It picks who to pay by date — `last_working_date
  is null or >= period_start` — and nothing could set that date. So
  somebody marked a leaver Resigned, the record said Resigned, every
  list said Resigned, and the next payroll run paid them a full month's
  salary, contributed EPF and SOCSO on it, deducted and remitted PCB
  against their tax file, and the bank payment file sent the money to
  their account. Every month, until somebody noticed.

  Everything else in these sweeps is an **absence**: nothing happens,
  and an option missing from a menu is at least indistinguishable from
  one that was never built. This is a **falsehood**. The person did the
  thing the software asked of them and the software did the opposite of
  what they asked — and every screen downstream agreed with it.

  The fix that suggests itself is to make the engine read the status
  too, so either one stops the payment. `0371` does not, and the reason
  is the general one: two sources of truth for one fact is how they come
  to disagree. A leaver excluded by status with no last day cannot be
  paid the days they *did* work in their final month, which is a
  different wrong answer arriving quietly. The date stays the only thing
  the engine reads, and a trigger refuses to let the two say different
  things.

  Judging the change and not the row, deliberately, and this is the
  second use of that note. Every record ever set through the old
  dropdown is sitting in a leaving status with no date, and refusing to
  save one until the question is answered would mean nobody can correct
  a phone number on a colleague who left last year. The trigger fires
  when the departure is being declared or moved, which is the moment the
  question is answerable; a `do` block names the existing ones instead.

  And the sixth sweep gets one back. `app.employment_status` has carried
  `notice` since `0025` and the dropdown offered it beside the rest,
  which made it a thing somebody typed. Serving notice is exactly "has
  resigned, and the last working day has not arrived", so
  `record_departure` derives it — the value now means something no other
  value means.

- **A tab that could only ever be empty** (`matters.closed_date`).
  `app.matter_status` has had `closed` since `0021` and the matters
  screen has had a **Closed** segment for as long. Nothing in the system
  ever wrote that value: `createMatter` inserts with the default `open`
  and there is no update path at all. So the tab was empty, always, and
  `closed_date` had never held a date.

  In a law firm that is not cosmetic. Every file ever opened stays on the
  matter list, in the client-funds report and in the work-in-progress
  figures for the life of the practice, and the list a partner uses to
  ask "what is still live" answers "all of it".

  `0372`'s interesting part is not the closing, it is the line between a
  refusal and a warning, and the line is drawn by **whose money it is**.

  The client's stops it absolutely. The Legal Profession (Accounts)
  Rules 1990 hold that money received for a client is held for a purpose
  and paid out when the purpose is done; a matter closed with a balance
  on it is money nobody is looking at any more — off the live list, and
  the client is not chasing it either. That is the ordinary route to
  unclaimed client money, so it is refused, with the balance in the
  sentence and both ways out named: pay it, or move it with `0358`.

  The firm's own is reported. Unbilled time and disbursements come back
  in the result and the screen says so before confirming, because a
  practice writing off work on a file that came to nothing is entitled
  to, and refusing would turn an ordinary write-off into a dead end.
  Outstanding invoices are not checked at all: a finished matter with an
  unpaid bill is what a receivables ledger is for, and holding the file
  open until the client pays would empty the word "closed" of meaning.

  The mutation run found the fixture short again, for the fifth time in
  this document. Counting voided client transactions in the balance
  survived, because no fixture had one — and it matters, because
  `report_matter_summary` and `0021`'s deferred trigger both read
  `status <> 'void'`, so a closing that read different rows would make
  the screen and the refusal disagree about the same file. The fixture
  now carries both halves of that sentence: a voided receipt is not money
  held, and a draft one still is.

- **A pipeline that recorded that deals died and not why**
  (`opportunities.won_reason`, `lost_reason`, `competitor`, and
  `leads.lost_reason`). Columns since `0008`, none ever written.

  Dragging a card onto Closed Lost calls `moveOpportunity`, which is one
  `update` of `stage_id`; `0009`'s trigger then writes the status and
  stamps the close date, and that is the whole of it. The board knew a
  deal died, on what day, for how much. Not why.

  Worth being precise about why that is the expensive one. Every other
  figure on a pipeline is arithmetic anybody could redo from the
  invoices afterwards. The reason is the only thing that has to be
  captured at the moment it is known, because a week later nobody
  remembers and the salesperson has moved on. "We lost forty per cent of
  them on price" is a decision about pricing; "we lost forty of them" is
  a number.

  `0373` refuses a lost or abandoned close without a reason, and does
  not ask on a win. The asymmetry is the design: an optional field on a
  form nobody has time for is a field that stays empty, and the report
  built on it stays empty with it — while no decision is waiting on why
  somebody said yes, so winning stays the fast path.

  The sixth sweep gets another one back. `opportunities.status` has
  allowed `abandoned` since `0008` and `pipeline_stages.stage_type`
  allows only ('open','won','lost'), so the trigger that derives status
  from stage type could never produce it. Lost is a customer buying
  elsewhere — there is a competitor and a price. Abandoned went quiet, or
  the firm walked away, and a pipeline calling those the same thing
  reports a loss rate that is not true. The card still lands in the
  Closed Lost column, because a board with no column for it would have
  nowhere to put the card; the status is what separates them and what
  the report groups by.

  `report_win_loss` exists because otherwise this pass would have
  finished by adding a field with no reader, which is the failure it set
  out to fix wearing different clothes.

  Two smaller notes. Closing goes through the stage first and the status
  second, in two statements, because `0009`'s trigger writes `status`
  from the stage whenever `stage_id` changes and would overwrite a
  single combined update. And the mutation run found the fixture short
  again — nothing passed a stage to `reopen_opportunity`, so the guard
  keeping a reopened deal out of a closed column was never exercised;
  without it an open deal sits in the Closed Lost column and the board
  disagrees with the status.

- **Two dates on a document that nothing honoured**
  (`sales_documents.valid_until`, `delivery_date`). Columns since `0005`.
  `valid_until` even carries the comment `-- quotations`, which was the
  whole of what anybody ever did about it.

  A quotation is an offer, and `transfer_document` would turn a year-old
  one into a sales order and then an invoice without a word — every
  figure carried forward, every downstream total agreeing with every
  other. Nothing in the books would look wrong. The company would simply
  have done the work at last year's price. A proforma is the same shape
  with higher stakes: it is what an importer's bank reads before opening
  a letter of credit, and the validity is part of what the bank relies
  on.

  `0374` refuses the transfer and names the date, rather than warning.
  The distinction is the same one `0372` draws: honouring an expired
  quote is a decision somebody makes, and a warning is a decision nobody
  makes. `extend_document_validity` is where it gets made and recorded,
  and it refuses a date already gone — an extension into the past is a
  typo, and letting one through would put the guard back where it
  started. A quotation with *no* date is not expired: every quote raised
  before this migration has none, and refusing them all would break every
  open quote in every company on the day it applied.

  `delivery_date` is the promise, and it survived nothing — the transfer
  never carried it from the quotation to the order or from the order to
  the delivery order, so by the time anybody could act on it the promise
  was gone. It is carried forward now, and deliberately not onto an
  invoice: an invoice's delivery date is a fact about a delivery that
  happened, and copying a promise into one restates history.

  `report_late_orders` is the half that makes it worth recording, and it
  measures on the lines rather than the status — `quantity_fulfilled` is
  what the delivery orders actually took, and an order nine tenths
  shipped is late on the tenth that is not.

  A note about the harness rather than the code. Writing this file's
  assertions, `run_locally.sh` reported a test file that does not exist
  as passing: `psql -f` says `psql: error: ... No such file`, in lower
  case, and the runner grepped for `ERROR:`. So a test renamed on one
  side of `ci.yml` and not the other would have been green here while
  running nothing. That is the "0 files in green" hole from earlier, one
  layer in, and it is fixed the same way — the file has to exist, and the
  grep is case-insensitive now.

  And one about the fixture. An assertion written as
  `where id = public.transfer_document(...)` failed with "nothing left to
  transfer": the planner is free to evaluate a volatile function once per
  row it scans, and the second call is a second transfer. The call is
  hoisted into a variable, which is where a volatile function belongs.

- **A setting that named its own purpose and did nothing**
  (`pos_settings.park_expiry_hours`). A column since `0206`, with a
  comment reading "how long a parked sale survives before it is
  somebody's problem", a check constraint holding it between 1 and 720,
  and a default of 24. Nothing ever read it.

  This one is worth recording because of what it collides with. `0206`'s
  shift close counts parked sales and refuses; `0361` — written earlier
  in this same pass — made `begin_pos_count` refuse for the same reason.
  So a basket somebody opened three days ago and walked away from stops
  a cashier counting their own drawer tonight, and the only way out is a
  void, which needs the `pos_void` grant a cashier does not have. They
  ring a manager, at closing time, about a bill nobody remembers. A gap
  closed in one migration made a gap in another one bite harder, which
  is the second time this document has had to say that.

  The sweep clears only what nothing has happened to: nothing tendered,
  nothing sent to the kitchen, older than the shop's own setting. Which
  is exactly the case the column was written for — keystrokes. A
  part-paid bill is somebody's money and a cooked line is a real cost
  that `0246` deliberately made a manager's decision.

  Two small truths in how it records itself. The reason is `other` with
  a note saying what happened and how old the bill was, not
  `customer_cancelled`: nobody cancelled anything, `pos_void_summary`
  groups by reason, and one honest line beats a hundred false
  cancellations. And `voided_by` is null, because no person did this —
  putting a name on it would make the audit trail say somebody decided.

  A mutant survived and was kept anyway. Removing the "no settings row"
  guard changes nothing, because `make_interval(hours => null)` is null
  and `created_at < null` matches no rows. It stays: arriving at the
  right answer through three-valued logic is not the same as saying it,
  and the next person to touch that query should not have to discover
  that a null interval was load-bearing. Same judgement as `0361`'s
  closed-shift branch, reached the same way.

  And a caution for whoever next reproduces a function in a migration.
  This one rebuilt `run_daily_jobs` from `0360` and silently dropped what
  `0365` had added to it — `expire_carried_leave` stopped being
  scheduled. `scheduled_work.sql` caught it on the first run, which is
  what that file is for. The rule: copy from the *latest* migration that
  defines the function, and let the reachability assertions check you.

- **The same hole, one table over** (`purchase_documents.original_bill_id`).
  A column since `0006`, declared beside `parent_id` with the same intent
  as `sales_documents.original_invoice_id`, and never written. `0269`
  found and closed that hole on the sales side and said why it is worse
  than a missing feature: a credit note naming no document cannot be
  capped at what it reverses and cannot be reported against it.

  Every word of that is true here with the signs reversed, and it became
  live rather than theoretical earlier in this same pass — `0160` gave
  `purchase_credit_note` a row in the document table, so a supplier
  credit can now be raised, and it lands as a hand-typed document naming
  no bill.

  The third consequence is the statutory one. `report_sst_summary`
  counts a purchase credit note's tax as a reduction of input tax
  claimed, and which bill's input tax is not a detail: a return of goods
  bought under one tax code adjusts that claim and not another, and an
  assessment asks bill by bill.

  It deliberately does not move stock. `0269` had to return ingredients
  because selling took them out; here the goods are going back to the
  supplier and `0097`'s posting path already moves them, so a second
  movement would take them out twice. The test asserts the store falls by
  twenty once.

  Four survivors across two mutation rounds, and each one taught
  something different. A **draft** credit note against the bill must not
  reduce what is creditable — a document that may never be posted would
  otherwise block a real return, and that case exists precisely because
  `0160` made the type raisable by hand. A **debit note** pointing at the
  same bill is not a credit and must not count as one. The credit takes
  the **bill's own exchange rate**, because re-resolving it would book an
  FX gain on a return every time the ringgit moved.

  And the fourth found dead code rather than a missing case. `0269`
  deletes the half-built note before raising "nothing left to credit",
  and that line does nothing: the raise unwinds the whole call and the
  insert goes with it. There is no path out of that branch that does not
  raise. `0376` leaves the delete out and says so, so the next reader
  does not copy it back in thinking it was load bearing — and the
  assertion is written as the outcome ("the refusal leaves no half-built
  note"), which holds either way.

- **A statutory event made through a form field**
  (`corp_entities.former_names`, `registered_office_changed_on`,
  `constitution_adopted_on`). Columns since `0061`, none ever written.

  `0063` had already done the hard part: it knows a change of registered
  office is s.46(3) and fourteen days, that a change of name is s.28 and
  fourteen days, and `corp_open_filing` freezes a computed obligation
  into a row somebody can work on. What was missing was the *event*. The
  entity editor writes `name` and `registered_office` as ordinary text
  boxes, so a company could be renamed by typing over it and no clock
  started.

  Losing the former name is the sharper half, and the reason is s.28(4):
  for **twelve months** from a change of name, the former name must
  appear beside the new one on every document the company issues. Typing
  over the field loses the old name *and* the date twelve months would
  be counted from, so every document after it is defective and nothing
  in the record can say so.

  The design decision worth recording is the **two doors**. A company
  changing its name and a secretary fixing a typo look identical to a
  form and are nothing alike on a file: one is an event with a deadline
  and a twelve-month obligation, the other is the record catching up
  with what was always true. Each gets its own function, the trigger
  refuses anything else, and `0038`'s audit trail then shows which door
  was used — which is precisely what an inspection asks. The registered
  office is guarded the same way even though it is the softer case,
  because one rule for the sharp case and another for the soft one is a
  rule nobody can remember.

  A mechanism note. `correct_company_name` writes the name without the
  date, which is exactly what the trigger refuses, so it announces
  itself with a transaction-local `set_config` that it clears on the
  next line. The clearing is the point and it is asserted: leaving the
  marker standing would let the next bare update in the same transaction
  ride through on it, which in an RPC that does two things is a rename
  nobody authorised.

  `adopt_constitution` needed a filing type `0063` does not have —
  s.32(1) allows adoption by special resolution and s.32(3) requires the
  copy lodged within **thirty** days, not the fourteen most of the
  others use. Asserted as its own number for that reason.

- **A request that could only be signed** (`corp_signatures.decline_reason`,
  and `app.signature_status.declined`). The enum has had the value since
  `0069` and the word appears nowhere else — not in the migrations, the
  app or the edge functions.

  So a director who will not sign a resolution has no way to say so, and
  the line stays `pending`: identical, to the secretary chasing it, to a
  director who has not opened the email. That is the worst of the
  readings, because the two call for opposite actions — send a reminder,
  or redo the resolution. Withdrawal existed and is not the same thing:
  withdrawing is the company taking the request back, declining is the
  signatory refusing it, and a file that cannot tell those apart cannot
  show that a director dissented.

  Offered through both doors signing has, including `0070`'s scoped
  link — somebody reading the document on a link who cannot say no will
  simply not reply. Which meant adding a name to `statutory.sql`'s anon
  allowlist, and that check did its job: the full suite failed on
  "nothing new is exposed to anon" before the entry was written. The
  allowlist demands a justification in prose, which is the right price
  for a function a stranger can call.

- **A statutory lodgement recorded by an update statement**
  (`corp_filings.lodged_by`, `fee_paid`). Columns since `0062`, never
  written, and the app marked a lodgement with a bare `update` of three
  fields — so the only check it had, that the date is not in the future,
  lived in Dart. A rule enforced only in Dart is not enforced.

  `lodged_by` is whose filing it was, which a practice with four people
  and a hundred companies needs the day one turns out to be wrong.
  `fee_paid` is the SSM fee the practice paid for the client and
  recharges: unrecorded, it is never billed, and a fee nobody wrote down
  is a fee nobody invoices.

  A trap worth recording for the next test. The guard measures the
  company's day — `now() at time zone 'Asia/Kuala_Lumpur'` — and the
  first version of the assertion used the server's `current_date`.
  Postgres runs in UTC here and Malaysia is UTC+8, so for eight hours of
  every day those are different dates, and the test passed all morning
  and failed all evening. A test of a Malaysian business rule has to
  keep Malaysian time.

- **Two left where they are, and why.** `organizations.trial_ends_at`
  and the `trial_days` platform setting are the vestige of a business
  model this system does not have. Nothing enters the `trial` status —
  the column defaults to `active` — and where `trial` appears it is
  treated identically to `active`. The platform monetises through
  prepaid credit and module entitlements, not a subscription with an
  expiry, so writing a trial clock would mean inventing the commercial
  policy that goes with it: what happens on the last day, who is
  suspended, and on whose authority. That is not a gap to close from
  inside the code. `payment_terms.discount_percent` and `discount_days`
  are the settlement discount — "2/10 net 30" — and are a real feature
  rather than a defect: taking one changes the taxable value and needs a
  credit note under SST, so it is a piece of work with a statutory shape,
  not a wire to reconnect. Both are listed here so the next sweep does
  not rediscover them as findings.

- **And one left deliberately unwritten.** `bank_transactions.value_date`
  is the day funds become good, which differs from the transaction date
  on a cheque deposit. `0369` records the balance beside it and not this,
  because nothing would read it: the ledger dates the receipt, the
  matcher measures nearness to the transaction date, and the statement
  balance already reflects the bank's own treatment. Recording a column
  to no consequence is the failure this sweep exists to find, not a
  smaller version of the fix. The place to delete this paragraph is the
  day something needs it.

  `einvoice_documents.rejection_reason` and `retry_count` are the same
  judgement reached the same way. The rejection path in `status.ts`
  already stores LHDN's `validationSteps` in `validation_errors`, and
  the screen unpacks the nested shape LHDN actually returns and lists
  them — so a third column holding a prose summary of the same thing is
  a second place for it to be wrong. `retry_count` is superseded by a
  manual resubmit, which is the right control for a filing: an automatic
  retry of a document LHDN rejected on its contents submits the same
  wrong document again.

## What the second write does

A `before insert or update` trigger that judges the **row** rather than
the **change** is a trap, and it is invisible in every test that writes
a row once.

`0365`'s half-day rule had it. A leave request is updated several times
after it is filed — approved, rejected, cancelled, its dates corrected —
and every one of those fires the trigger, which sees a row that already
says half a day. So a company that files half days and *then* marks the
type whole-days-only would find the requests in flight could no longer
be approved or even cancelled: refused by a rule about something nobody
was changing, with no way out but editing the policy back. Any
tightening of any policy expressed this way applies retrospectively to
rows filed under the old one, which is not what changing a setting
means. `0367` makes it judge the change.

Worth running over the others written in the same pass, because the
answer differs and the reasoning is the point:

- `enforce_claim_caps` on the claim: guarded on the transition into
  `submitted`, so an approval — which sets `approved` — returns
  immediately. An approval must never re-litigate a cap the company has
  already accepted.
- `enforce_claim_caps` on the lines: fires whenever the parent is
  `submitted`, which is correct. Editing a line of a claim still
  awaiting a decision is exactly what the cap should judge, and an
  approved claim's lines are outside it because the parent is no longer
  `submitted`.
- `enforce_credit_limit`: acts only on `gl_entry_id` going non-null, so
  everything after posting is untouched.
- `pay_periods_whole_month`: a check constraint re-evaluated on every
  write, which is harmless because a conforming row stays conforming —
  closing a period does not move its dates.

The question to ask of each is not "does this refuse what it should"
but "what happens on the second write to a row that already fails it".

## The one a row policy cannot express

The seventh sweep looks for a column one side of the wire uses and the
other cannot. The appraisal block — twelve columns, the largest declared
and unbuilt thing left — turned out to be that and something worse
underneath it, and the shape is worth writing down because there will be
others.

`0038` grants the person being appraised UPDATE on their own appraisal
row:

    -- Appraisals: mine, my reports', or all of them if HR.
    create policy appraisals_update on public.appraisals
      for update to authenticated
      using (app.can_manage_hr(org_id)
             or employee_id = app.my_employee_id(org_id)
             or reviewer_id = app.my_employee_id(org_id))

The comment reads like a rule about who may do what. It is a rule about
which **rows** are visible to an UPDATE, and it has no opinion about
columns — there is no column-level grant behind it. So the subject could
write their own `manager_rating`, their own `manager_comments`, their own
`final_rating`, set `promotion_recommended`, put a number in
`recommended_bonus`, and mark the row `completed`.

That is a **falsehood** in the sense `0371` names: not a feature missing,
but a control that appears to have been applied. A document whose entire
purpose is that two people said two things separately, either of whom
could have written both. Every appraisal in the system was evidence of
nothing and looked exactly like evidence.

**The rule a policy cannot state is a rule about the change.** `0379`
writes it as a trigger that asks which columns moved and whether the
person moving them owns that half — the same question as `0367`'s, from
the other direction. Three things fell out of writing it that way:

- **Reopening is recognised, not flagged.** HR may take a submission
  stamp off; HR may not write in the half. Both are UPDATEs to the same
  columns, and what separates them is the *shape of the change* — a
  stamp cleared and not a word touched. Deriving it from `old` and `new`
  rather than from a `set_config` marker means a direct UPDATE that
  looks like a reopen is one, and one that also rewrites the words is
  refused as what it actually is. The mutation run found this: with the
  "and not a word touched" clause removed, everything still passed,
  because no fixture had tried to do both at once.
- **Being the subject beats every other part.** An HR manager is HR on
  everybody's appraisal except their own. Ordering it the other way
  would mean the one person who could write their own manager rating is
  the person who administers the process.
- **A named reviewer is the reviewer.** The reporting line stands in
  only where nobody is named. Letting it apply always makes a skip-level
  manager a second reviewer, which is two manager reviews with one
  overwriting the other. This too was a surviving mutant first: the
  fixture never had a reviewer who was not also the manager.

### And the screen does not work it out again

The obvious way to draw the right buttons is to compute the same rule in
Dart. Two implementations of one permission rule disagree eventually, and
the copy that is wrong is the one a person actually reads. So `0379` adds
`my_appraisal_parts`, which answers from `app.appraisal_part_of` — the
same function the trigger judges changes by — and
`features/hr/appraisal_part.dart` only parses the answer. What that file
does compute is the *next step*, which is a fact about the state of the
appraisal rather than about permission: given a part and how far the
appraisal has got, there is exactly one thing it is waiting for.

### A deadline that only sends emails is not a deadline

`self_review_due` and `manager_review_due` were columns nothing had read,
which made a cycle with deadlines and a cycle without indistinguishable.
The first is now load-bearing rather than decorative: the manager's half
is refused until the employee submits theirs, **or** until the day the
employee's was due — a review nobody wrote cannot stop the one somebody
did. The second is what `report_appraisals_due` measures.

`rating_scale_max` is the third. A 7 stored perfectly in a cycle scored
out of 5, and a 4 out of 5 and a 4 out of 10 are different judgements
that looked identical in every list.

### Where to look next

Any `for update` policy whose `using` clause names more than one kind of
person is a candidate for the same reading. The policy decides which rows
that person may touch; if the columns on the row belong to *different*
people, the policy has not said so and cannot. `appraisal_goals_all` had
it too and is fixed in the same migration.

## Two columns that record who

`corp_officers.alternate_for` and `corp_persons.id_verified_by` are the
same finding twice. Each is the half of a statutory record that names a
person, and each sat beside a column that was faithfully written — so
the register said *that* something happened and never *who*.

- The officer sheet offered "Acting as an alternate" as a tick box, and
  the role enum carried `alternate_director`. Neither says whose place
  the alternate acts in. Under s.208 an alternate votes **instead of**
  their principal, not as well as them, so whether a board had a quorum
  — the question a resolution's validity turns on — cannot be answered
  from the register at all.
- The person editor recorded `id_document_type` and `id_verified_on`,
  and nothing ever wrote `id_verified_by`. Customer due diligence is a
  record of an act by a person: this document, seen by this individual,
  on this day. A date with no name is an assertion that somebody, at
  some point, was satisfied. `0378`'s `lodged_by` was the same shape and
  is fixed the same way — the column is stamped from the session by the
  function that does the thing, and the date cannot be written without
  it.

Three things fell out of `0380`:

- **`is_alternate` stops being typed.** It and `role =
  'alternate_director'` were two ways of saying one thing, set
  independently by one screen, and `0188`'s seed set neither. It is now
  derived from `alternate_for`, which leaves room for the case the
  boolean existed for and the enum cannot express — a deputy secretary —
  while making the two impossible to contradict.
- **`on delete set null` is not a cessation rule.** It is about a row
  being deleted, and an officer who resigns is dated rather than
  deleted, so the register went on showing somebody standing in for a
  director who left in March. The cascade is written as one event: the
  alternate ceases with the principal, moves when the principal's date
  is corrected, and comes back if the principal is reinstated — but only
  where the cessation was the principal's doing, which the borrowed
  reason on the row is what distinguishes. A stand-in who resigned on
  their own account, on the very same day, is left alone. Both of those
  were surviving mutants before they were fixtures.
- **The picker asks the database who is eligible.** Filtering the
  already-loaded officer list in Dart would be a second implementation
  of the guard's own rule; `corp_principals_for_alternate` is the same
  list the guard accepts.

One mutant is kept alive deliberately, and the reasoning is the same
judgement `0375` records: the cascade's "judge the change, not the row"
early return stops a write, and is unobservable only because
`app.write_audit_log` already drops an update whose diff is empty.
Arriving at a correct audit trail through a second guard downstream is
not the same as not touching rows nobody asked to change.

## The record that was typed in twice

`applicants.hired_employee_id` carried, since `0036`, the comment
describing exactly what nothing did:

    -- Set when the applicant becomes an employee, so the two records
    -- stay linked and the hire is traceable back to its requisition.

`hired` was the last label on the pipeline. `moveApplicant` wrote a
status and a history row; somebody then opened the employee editor and
typed the name, the phone number, the NRIC and the salary in again, from
the record sitting beside them.

The retyping is the visible cost and the smallest one. What was actually
lost is every question the recruiting data exists to answer: which
requisition this person came from, what the offer was against what they
expected, how long it took, and who introduced them.

Four more columns in the same cluster, each of which now stops
something:

- **`notice_period_days`** is what the candidate owes somebody else. A
  start date inside it is a date they cannot make, and finding that out
  after the offer has gone is how a start slips a month. Refused, with
  a required reason as the way through — notice does get bought out,
  and a refusal with none is how somebody puts the wrong date in to get
  past the screen.
- **`headcount`** had been *displayed* since the screen was written —
  "3 position(s)" — and nothing counted against it. A requisition for
  one could be filled four times with the register still saying it was
  open.
- **`closed_date`** and the `filled` status are the other half: the
  requisition closes on the day its places were taken rather than
  whenever somebody remembers.
- **`referred_by`** is a reference to an employee that nothing wrote,
  which made a referral scheme unpayable from the data.

`report_referral_hires` returns both counts, hires and candidates,
because a list of hires alone cannot tell somebody who introduced six
people and had none taken on from somebody who introduced nobody — and
the first is the person a scheme exists to keep.

**One column left deliberately unwritten.** `applicants.resume_path` is
a text column holding a storage path, and attachments have had a home
since `0046`: a bucket, a row, a lifecycle and a policy. A second place
for a file to be missing from is not an improvement. The place to delete
this paragraph is the day the applicant screen grows an attachments
section, which is where a CV belongs.

## Two records of the same money that could not be compared

`fixed_assets.purchase_document_id` and `fixed_assets.supplier_id` have
been columns since `0084`. Neither is on the asset editor, in the Dart
model, or written by anything.

The cost of that is not a missing field on a form. The asset register and
the fixed asset accounts in the general ledger are two records of the
same money, and **the reconciliation between them is the one an auditor
opens with**. Without knowing which asset came from which bill it cannot
be done at all.

The failure it lets through is quiet by construction. A bill line coded
to Plant and equipment puts 12,500 in 1510. Somebody opens the asset
editor and types 12,000 — the difference being a delivery line, or the
tax, or a slip. The balance sheet shows 12,500, the register adds to
12,000, depreciation runs on the smaller figure for five years, and
nothing anywhere says so.

`0382` inverts the entry: `capitalise_bill_line` makes the asset **out
of** the line. The cost is the line's own net amount, the acquisition
date is the bill's, the supplier is the bill's supplier, and the asset's
`asset_account_id` is the account the line was actually posted to. The
register and the ledger agree because they come from the same row,
rather than because two people chose the same account twice.

Three refusals, and each names a different kind of wrong:

- **A line capitalised twice.** One line is one lot of money; a second
  asset from it is the same cost depreciated twice, and a balance sheet
  over-stated by exactly the figure nobody is looking for. The rule is
  a partial unique index rather than a check in the function, so a
  deleted asset frees the line again.
- **An unposted bill.** An asset whose cost is not in the ledger can
  never be reconciled to it.
- **A line coded somewhere else.** A line charged to Repairs and
  maintenance and then put in the register is the two records
  disagreeing on purpose. The refusal names the account, because the
  fix is to correct the coding on the bill and that is a different
  screen.

Nothing is posted. Creating an asset never has — the register is a
memorandum record and the bill's own posting already put the money in
the asset account — and a capitalisation that posted again would double
the asset.

`report_uncapitalised_purchases` is the same reconciliation from the
ledger's end: posted bill lines coded to a fixed asset account with
nothing in the register claiming them. It is a question the data could
not previously answer in either direction.

### The mutation run's two lessons here

Both survivors were fixtures asking for a value the row would have held
anyway. `line_subtotal` and `line_total` are the same number on an
untaxed line, so "the cost is the net, not the gross" asserted nothing
until a taxed bill existed — and getting that wrong capitalises
recoverable input tax, over-stating the asset by the amount the company
is getting back. And two permission tests were passing because the call
under them was refused by `fixed_assets_method_needs_its_figure` before
the permission was ever reached; a refusal test has to make a call that
would otherwise succeed.

## A rule that could not be asked

`matters.opposing_party` has been a column since `0021` and nothing
wrote it. That is not a missing field: it is the column a **conflict
check** reads, and without it the question had no answer in the data at
all.

Rule 3 of the Legal Profession (Practice and Etiquette) Rules 1978 stops
an advocate and solicitor acting against a client's interest, and the
commonest way a firm walks into one is not subtlety — it is a second
partner opening a file, on a Tuesday, against a company the firm already
acts for. Every matter recorded who the client was. Not one recorded who
was on the other side.

`0383`'s check runs **both** directions, because a conflict has two
shapes and checking one is checking neither:

- the proposed opposing party is somebody the firm acts for now;
- the proposed client is somebody the firm has acted against.

Two decisions worth writing down:

- **The way through is required, not offered.** A conflict can be waived
  by informed consent in some circumstances and cannot in others, and
  that judgement is a solicitor's. A refusal with no way through would
  be worse than none: somebody would leave `opposing_party` empty to
  open the file, and the column would go back to being what it was. So
  the file opens with a written reason, which is what the Bar Council
  looks at afterwards. Whitespace is not a reason, and the mutation run
  is what made that a fixture.
- **The name match is generous on purpose.** `app.conflict_key` folds
  case, punctuation, and the entity suffixes people vary — Sdn Bhd,
  Berhad, Bhd — and the ampersand-versus-"and" that splits one firm's
  name into two. A check that misses one is worth nothing; being asked
  about the wrong ABC costs ten seconds, and that is the failure it errs
  towards.

The regex for those suffixes had to match **whole words** rather than
"whitespace then the word": "Holdings Berhad" is two suffixes sharing
one separator, and a pattern that eats the separator strips the first
and then cannot see the second. The test caught it on the first run.

### The parameter that could not change an answer

`check_matter_conflict` was written with an "exclude this matter"
parameter, for re-checking a file that already exists. Working through
the fixture showed it can never fire: the first arm asks whether any
file's *client* is the proposed opponent and the second whether any
file's *opponent* is the proposed client, so a matter's own pairing is
the one thing it cannot match. It was removed rather than left in —
a parameter that cannot change an answer is one somebody will
eventually rely on.

### The other two columns

`fee_earner` is who does the work, as against the responsible solicitor
who supervises it. Time is recorded against a matter by whoever is
signed in, so without one nothing says whose file it is when they are on
leave. An open matter now needs one — judged on the change, so files
opened before the rule stay editable — and five existing fixtures had to
name one, which is the rule doing its job rather than a cost of it.

`agreed_fee` is what a fixed-fee client was told the matter would cost.
Billing past it is **reported, not refused**: fees get renegotiated and
a disbursement is not a fee. Unbilled time counts, because the question
is what the client will be asked for; time already on a bill does not
count twice; a voided invoice never billed; and a matter with an agreed
fee of nought is a firm that agreed to act for nothing, which is its own
decision and not something to report back to it.

## Two figures for one deal

`opportunities.quotation_id` has carried its own instructions since
`0008`:

    -- Set when the deal is converted into a quotation/invoice

Nothing set it. The pipeline and the sales ledger were two accounts of
the same deal with nothing joining them: a deal was marked won, somebody
raised a quotation from the contact screen, and the only thing tying
them together was that both happened on the same afternoon.

The forecast is what goes wrong, and it goes wrong silently.
`opportunities.amount` is typed early and round — sixty thousand,
because that is the size of the job. The quotation that goes out weeks
later says 48,250, because by then somebody has priced it. The weighted
pipeline, the forecast and every "how does the quarter look" answer come
off the first figure; the invoice, the ledger and the cash come off the
second. Nothing compared them, so a pipeline could be twelve thousand
out on one deal and the two facts never meet — the deal closes, the
invoice is right, and the forecast was wrong.

`quote_opportunity` raises the document **from** the deal, so both start
as one number. `report_pipeline_quote_mismatch` finds the ones that have
since drifted, which is ordinary — a quote gets revised — and is exactly
what a sales manager wants told.

### A rule two migrations apart

`0374` made `valid_until` mean something: a lapsed quotation will not
transfer to an order, because the price was an offer and the offer ran
out. A deal marked **won** against a lapsed quotation is the same
mistake one screen earlier — the pipeline says the customer accepted,
and what they accepted cannot be turned into anything. `0384`'s guard is
that rule reaching back up the workflow, and its message names
`extend_document_validity`, which is `0374`'s way through.

It deliberately does **not** refuse a won deal with no quotation at all.
Plenty of business is won on a phone call and invoiced directly, and a
CRM that will not record that is a CRM people keep outside the system.

### AFTER, not BEFORE

The guard is an AFTER trigger, and the reason is worth keeping. `0009`'s
`track_stage` is a BEFORE trigger that derives `status` from the stage a
deal was moved into, and `close_opportunity` closes a deal by moving its
stage. A BEFORE trigger on the same row runs before or after that one
depending on nothing but their names — `opportunities_won_quote_ck`
sorts ahead of `track_stage`, so it saw a status that had not been
worked out yet and let every lapsed quotation through. An AFTER trigger
sees the row as it will be stored, whatever else ran.

This is the third time in this document that trigger ordering has been
the bug rather than the rule. The general form: **a BEFORE trigger
cannot read a column another BEFORE trigger derives.** If the rule is
about the final state of the row, it belongs in AFTER.

## The discount that cleared an invoice and no ledger

`payment_allocations.discount_amount` has been a column since `0005`.
`payment_terms.discount_percent` and `discount_days` have been columns
since `0003`, and `0012` seeds eight payment terms — NET7 through NET90
— that are the shell of a settlement discount scheme nothing ever built.

That is the absence. Underneath it is the worst falsehood this document
has recorded, and it is worth stating precisely, because it is invisible
in every screen.

`app.apply_allocation` clears the invoice by the cash **and** the
discount:

    select coalesce(sum(amount + discount_amount), 0) into v_paid

`app.post_receipt_internal` credits the receivable by the cash alone. So
an allocation carrying a discount marks the invoice `completed` with a
balance of nothing, takes it off the aged receivables — and leaves the
**receivable control account in the general ledger** overstated by
exactly the discount, permanently, with no document anywhere that
mentions it. The subsidiary ledger says the customer owes nothing; the
trial balance says they owe two hundred ringgit; and nobody can find the
difference because it has no name.

Nothing wrote the column, so the damage has not happened. That is luck,
not design: the two halves have disagreed since `0005` and any screen
that used the column as intended would have caused it.

**The fix is where it cannot be got round.** An allocation may not carry
a discount unless it names the journal that posted it —
`discount_entry_id`, and a trigger. `allocate_with_discount` posts Dr
Sales Returns and Discounts (4300), Cr Receivable, and writes the
allocation naming that journal. The two records now clear together or
not at all.

### The tax is deliberately untouched

Under the Sales Tax Act 2018 and the Service Tax Act 2018 the tax
charged is the tax on the invoice; a discount taken afterwards changes
the taxable value only if a credit note is issued, which is a separate
document with its own e-Invoice consequences. Silently reducing the
output tax at settlement would understate what the company has already
told LHDN it charged. So the discount is posted against revenue at its
gross amount and the tax account is not touched — and the test asserts
that no tax line appears in the discount journal, because "we chose not
to" and "we forgot" look identical a year later.

### The picker with no consequence

`payment_terms.days` and `term_type` were the same shape of nothing: a
document's `due_date` was typed, so choosing NET30 changed neither when
the invoice fell due nor when it appeared on the ageing.
`app.due_date_from_terms` derives it — end-of-month terms actually
falling at the month end, cash on delivery falling on the day whatever
the days column says.

Derived **only when absent**. A due date somebody typed is a date they
negotiated, and overwriting it with the standard terms would be the
software correcting a customer agreement it knows nothing about.

### Two more masked-refusal fixtures

Twice more the mutation run found a test accepting any refusal where
something further in refused for its own reasons: the table's `amount >
0` check standing in for the function's own guard, and `create_gl_entry`
refusing an outsider before `can_post` was reached. Both now assert the
message. The general rule, now three times over: **a refusal test has to
name which guard spoke**, or it passes with that guard deleted — and in
this case it would have passed after a discount journal had already been
posted for an allocation that never landed.
