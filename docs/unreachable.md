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

## The guard I kept forgetting to run

`scripts/check_embeds.py` failed CI on the 0384 push, and nothing local
had caught it: a PostgREST embed lives inside a string literal, so the
Dart analyzer cannot see it, the widget tests do not talk to a database,
and the SQL tests do not know what the client asks for. Its own header
says it reached a live site twice before it existed.

`0384` added `sales_documents(doc_no)` to the opportunities select.
`opportunities.quotation_id` points at `sales_documents` **and**
`sales_documents.opportunity_id` points back, so PostgREST can join the
two either way round and refuses the whole request rather than guessing
— taking out the pipeline screen. Naming the constraint fixes it:
`sales_documents!opportunities_quotation_id_fkey(doc_no)`.

The lesson is procedural, so it is written down here rather than learned
again. **Any commit that adds or edits a `.select()` with an embed must
run the checker before pushing**, against the same throwaway Postgres
`run_locally.sh` leaves behind:

    ./supabase/tests/run_locally.sh --keep
    python3 scripts/check_embeds.py \
      "postgres://postgres@/postgres?host=/var/tmp&port=5599"

It answers in a second and prints the file and line. There are ninety-
seven pairs of tables in this schema that can be joined more than one
way; the odds of a new embed landing on one are not small.

## The other side of the discount, and the mutant left in the database

`0385`'s own header describes both sides of a settlement discount — Dr
4300 Cr Receivable when a customer takes one, Dr Payable Cr Other Income
when the company takes one from a supplier — and built only the first.
That is a worse artefact than a migration claiming less, because the
next person reads the prose and not the body. `0386` builds the second:
`allocate_payment_with_discount`, with the same four refusals as the
sales side so the two cannot drift apart.

The account is the decision worth recording. The discount a company
takes for paying early is credited to **4900 Other Income**, not against
**5100 Purchases**. It is earned by paying sooner, not by buying more
cheaply; putting it against Purchases would move it into cost of sales
and restate a cost the stock valuation is built on. The test asserts
that nothing lands against 5100 for it.

`recordSettlement` in the client wrote its allocations straight into
`payment_allocations` and then posted — the one path that could carry a
discount with no journal behind it. `0385`'s `discount_entry_id` guard
refuses that now, so the dialog routes **every** allocation, discounted
or not, through these two functions. One path means the discount cannot
be written by a route that forgets the ledger.

### A failure that was mine, not the code's

The first full-suite run after 0386 reported `FAIL: an expired supplier
discount was taken`, and the guard was plainly there in the file. It was
in the file and not in the database: I had run the suite with `--keep`,
which skips `bootstrap` and `migrate` and reuses the cluster the
previous mutation run left behind — still carrying its last mutant, `if
false then` where the expiry check belongs.

`--keep` is for the embed checker, which needs a database that already
exists, and for re-running one test file while iterating. **A run whose
result you intend to act on must not use it**, and a mutation run must
be followed by a clean rebuild before the suite is believed again. The
useful part: the deployed body is the truth, and `select prosrc from
pg_proc` settles in one query whether the database is running the code
you are reading.

## The quit rent that was paid by typing a date

`property_statutory_charges` has carried `bill_document_id` since
`0162` — its own comment reads "the supplier bill it was paid through,
if it went through the books" — and nothing has ever written it. `0387`
found the reason that matters: the column beside it, `paid_on`, was
offered by the sheet as a plain date picker.

So a managing agent records the quit rent on a site under the National
Land Code, or the half-yearly assessment the council levies under the
Local Government Act 1976. It sits in `property_statutory_due` until
somebody types a date into "paid on", and then it is gone from the
report. No bill, no supplier, no payment, and the ledger has never heard
of the charge at all. Not an absence — a falsehood, of the same shape as
`0371`'s leaver, `0379`'s appraisal and `0385`'s discount: a control
that appears to have been applied.

Three moves fix it, and only the third is new.

`bill_statutory_charge` makes the bill **out of** the charge, the way
`0382` makes an asset out of a bill line: the charge's own amount, its
own due date, and the site, period and land-office account number
written into the line description, so the two records cannot later
disagree about what was owed. It posts, and it links.

`paid_on` stops being typed the moment a bill stands behind it. It is
derived from the bill's settlement — the date of the last thing that
cleared it, not the date somebody keyed the allocation, because which
period a statutory charge falls into is decided by when it was paid.
And it moves in both directions: a bill reopened takes the paid date
back with it, and detaching the bill clears it, which is what makes
`on delete set null` on the foreign key survivable at all.

The third is the concession, and it is the interesting one. A charge
with **no** bill may still be marked paid, because it honestly happens
— the owner pays the assessment at the counter and posts in the receipt
— but it must name the receipt. Refusing that case outright would have
pushed people into fabricating a bill to get the charge off the due
list, which is a worse falsehood than the one being removed. The rule is
not "never" but "say what is behind it".

### Two places that compute the same thing is one place too many

The first draft had the `AFTER` trigger on `purchase_documents` set
`paid_on` itself, and the `BEFORE` trigger on the charge derive it too.
The mutation run could not kill breaking the first: whatever the AFTER
trigger writes, the BEFORE trigger on the charge overwrites with the
right answer on the way in. The mutant was equivalent because the code
was redundant. The AFTER trigger now only touches the rows whose derived
date has moved, and the derivation lives in exactly one place — at which
point the same mutation kills.

The survivor that was kept is the other one: narrowing the push to
`bill_document_id = new.id`. Widening it to every charge still gives the
right answer, because each row re-derives from its own bill; what it
costs is a row lock on every statutory charge in reach each time any
bill in the company is paid. Kept for the reason `0380` keeps its own —
correct and slow is still a defect, even when no assertion can see it.

## The permit that expired and nobody was looking

`0025` created `employee_documents` with an index on
`(org_id, expires_date)` and a comment directly above it saying what the
index is for: *"Work permits and professional certificates expire; this
is what a 'expiring in the next 60 days' list reads."*

There is no such list. There never has been. The index has been sitting
in every deployment waiting for a report nobody wrote, and the only way
to find a permit about to lapse was to open each employee's record in
turn — so a company with sixty staff finds out at a gate, or when
Immigration asks.

This is a new shape for the ledger of findings here: not an absence and
not a falsehood, but **a stated intention with nothing behind it**. The
comment names the report. The index is tuned for it. Anyone reading the
schema would conclude the feature exists.

Whose problem the gap is decides how the report is written. Employing a
person whose Pass has expired is an offence by the **employer** under
s.55B of the Immigration Act 1959/63, charged per employee — the person
whose permit lapsed is not the one prosecuted. So the report does not
sort by date. It classifies: an expired permit on an expatriate or
foreign worker is an `offence` and sorts above everything; an unexpired
one is a `permit`; everything else is a `renewal`. A first-aid
certificate that lapsed a fortnight ago and a work pass that lapsed
yesterday are not the same row, and a list that orders them by date says
they are.

Three smaller things fell out of reading the table.

`doc_type` was unconstrained text while the dialog offered five fixed
kinds — so a second writer producing `"Permit"` or `"wp"` would silently
fall out of any report that groups by kind. `expires_date >= issued_date`
was enforced in the dialog and nowhere else, which in this project means
not enforced. And `uploaded_by` had never been written: which of four HR
administrators filed the copy is exactly the question asked when the
copy turns out to be of the wrong document. It is now derived on insert
and **frozen on update** — a column that quietly follows the last editor
answers a different question from the one it is named for.

### The renewal is what decides whether the list is read

Renewing a permit meant adding a row. The expired one stayed, so the
expiring list would fill with documents replaced years ago — and a list
that is mostly noise is a list nobody opens, which is precisely how the
one entry that mattered goes unread. `supersedes_id` and
`renew_employee_document` make a renewal say what it replaces; the
report shows only what nothing supersedes.

Two mutants worth recording from the twenty:

**A refusal that was true for the wrong reason.** Removing the "no such
document" check did fail the suite — but with `not permitted to renew`,
because the call fell through to `can_manage_hr(null)`. A person reading
that message goes looking for a role they already have. The test now
catches both SQLSTATEs and asserts the sentence, so the mutant fails on
*which guard spoke* rather than on the fact that something did. That is
the fourth time this session the same lesson has come round.

**A guard tested only through the front door.** The function refuses
renewing an already-renewed document with a readable message, and the
partial unique index refuses it structurally. Every fixture went through
the function, so making the index non-unique changed nothing any
assertion could see — while a row written straight through PostgREST
would have created two successors and left "which is current" with two
answers. The fixture now writes one directly.

## The project budget nobody could overrun

`projects.budget_amount` has been a column since `0088` and the word
appears nowhere else in the repository — not in another migration, not
in the client, not in a report.

The reason turned out to be one step further back. Nothing writes *any*
column of `projects`. Four screens read the table, and the timesheet
screen's own empty state says "No projects yet — a project is what hours
are recorded against and what they are billed to" while offering no way
to make one. A project had to be inserted by hand, by somebody with a
database connection. `budget_amount` was not an unused column; it was
the visible end of a table with no front door.

The report reads **cost from the ledger**, not from the documents. A bill
line tagged to the project, an approved expense claim and a journal
somebody posted by hand all land in `gl_lines` with a `project_code`;
reading the documents instead would have counted the ones this module
knows about and silently missed the rest. Unbilled time is counted
separately and added to neither side — it is revenue not yet raised, and
putting it in cost or in revenue flatters one of them.

Closing a job is `0176`'s refusal one table over: a project does not
close over billable hours nobody invoiced. The reasoning transfers
exactly — a closed project drops out of every picker, so those hours can
never afterwards be selected, invoiced, or found without going looking,
and they were marked billable, which is to say somebody meant to charge
for them. Writing the time off is offered as a deliberate answer rather
than discovered by being refused, and it marks the entries non-billable
rather than deleting them: the hours were worked, and the utilisation
report counts what people did, not what was charged.

### Two ways this file's own tooling lied to me

**A volatile function in a `where` clause runs per row.** The fixture for
"an unposted journal does not count" was written as

    update public.gl_entries set status = 'draft'
     where id = pg_temp.pb_post_returning(v_org, 'JOB-1', '5100', 9999);

which posted the journal once for every row `gl_entries` was scanned —
four times — and then drafted whichever one it matched last. The cost
assertion failed with a number that made no sense until the call was
lifted into a variable.

**`--keep` ran the suite against a mutant.** Three times this session I
ran `run_locally.sh --keep` on a cluster a mutation run had left behind,
read a failure that was not in the code, and spent minutes on it. The
guard I kept writing in prose is now in the script: `migrate` stamps the
data directory with an md5 of every migration file, and `--keep` refuses
when the stamp does not match what is on disk. `--keep` still does its
two legitimate jobs — the embed checker needs an existing database, and
re-running one file while iterating should not cost two minutes — but it
can no longer report on a schema that exists nowhere except in that
cluster. A note in a document did not stop me doing it; a refusal does.

## The customer who could not reply to their own ticket

`0192` built `ticket_comments` with two author columns and a check
constraint saying exactly one must be filled:

    constraint ticket_comments_one_author check (
      (author_user_id is not null)::int
      + (author_contact_id is not null)::int = 1)

`author_contact_id` had never been written. `add_ticket_comment` always
sets `author_user_id` to `auth.uid()` and there is no other writer, so
the requester half of every conversation in the helpdesk was
unreachable: staff talked to each other on the ticket and the customer
who raised it could not say a word. `app.ticket_channel` carries `email`
and `web` for the same reason and with the same result.

The mechanism was already built twice — `0070` for a director signing a
resolution, `0094` for a customer reading an invoice — so it is reused
rather than rewritten: a long random token, only the hash stored, one
live link at a time, an expiry, and the open recorded because that is
the only evidence the link reached anybody.

Three rules make it correct rather than merely possible.

**An internal note never leaves the building.** `is_internal` defaults to
true and `0192`'s own comment calls it "the single most dangerous boolean
in a helpdesk". The reader filters on it, and a requester's reply is
`false` unconditionally rather than by default — a customer's message
landing as an internal note would be invisible to the person who sent it.

**A customer's message is not the company's first response.**
`add_ticket_comment` stops the first-response clock on the first visible
comment. Had the requester's own reply done that, the SLA report would
show a target met that nobody met: the same falsehood shape as `0385`'s
discount and `0387`'s paid date, a control that appears to have been
applied. It is written past deliberately and the test asserts the
absence.

**A reply takes the ticket off the customer's hands.** `pending` pauses
the SLA clock, which is right while the company waits for an answer and
wrong the moment the answer arrives. The reply goes through the same
transition machinery a member uses, so the paused minutes and the
deadline move identically; on a resolved or closed ticket it reopens,
which is what `reopened_count` counts.

### The guard that duplicated itself

`transition_ticket` carries the paused-minutes arithmetic and the
permission check in one body. The requester's path needs the arithmetic
and cannot pass the check. Copying the body would have been the fast
answer and is how two copies come to disagree about how long a ticket
was paused, so the arithmetic moved into
`app.transition_ticket_internal` and `transition_ticket` was re-issued
as the guard and a call. Worth saying because the first draft of the
migration *claimed* that in prose while leaving the old body in place —
the exact fault `0386`'s header was written about.

### A revoke the local harness cannot see

`revoke all on public.ticket_share_links from anon` is load-bearing in
production, where Supabase's default privileges grant `anon` every table
privilege on a new public table. `_local_stack.sql` does not install
those defaults, so locally `anon` has no grant, the revoke is a no-op,
and deleting it is a mutant no assertion here can kill. It is asserted in
`statutory.sql` anyway — the check holds where it matters and costs
nothing where it does not — and recorded here because that file's own
header warns this is where the stubs stop being the real thing.

Nineteen mutants; seventeen killed on the first pass, two needed
assertions that were missing (the resolution note the requester is shown,
and the link table's own row policy), and one is the unkillable revoke
above.

## The consolidated e-Invoice that has never once been raised

This one was not found by reading. It was found because the clock rolled
past midnight into 1 September 2026 in the middle of a mutation run, and
two tests that had passed all session started failing:

    ERROR: invalid input value for enum doc_status: "paid"

`app.roll_einvoice_consolidation` has compared
`d.status in ('posted', 'partial', 'paid')` since `0058`, and
`app.doc_status` has no `paid` — its settled state is `completed`. The
function raises `22P02` before it reads a row, and has done since the
day it was written.

Fixing that let execution reach the next statement, which was also
broken: the insert supplies `due_date`, and a later migration made that
column `generated always as (period_end + 7) stored`. Postgres refuses a
non-default value in a generated column. **Two fatal faults, in a
function nothing has ever successfully run.**

Under the LHDN e-Invoice guideline a business must issue a consolidated
e-Invoice for the month's sales to buyers who did not ask for one, within
seven calendar days of the month end. This function is the only thing in
the system that gathers those sales. It has gathered none.

### Why nothing caught it

`run_daily_jobs` calls it only when `extract(day from p_on) = 1`, and
every test in this repository called `run_daily_jobs` with the **real
current date**. The branch was therefore tested on whichever day the
suite happened to run, and across hundreds of runs that was never the
first of a month.

So the rule, now written into `supabase/tests/monthly_jobs.sql`'s own
header: **a job with a calendar branch is tested on the date that takes
the branch, pinned, not on today.** Every call in that file names its
own date.

### The defect that was worse than either typo

The loop in `run_daily_jobs` wraps each per-organization step in an
exception handler — and `0375` wrote the reason in the comment above the
till sweep:

> a shop whose till sweep fails must not stop the leave year and the
> consolidation for everybody else

The two steps that comment names were the two still unwrapped. The
isolation had been given to the branches that run daily and withheld
from the branches that run once a month, which is exactly the wrong way
round: a fault in a daily branch is found the next morning, and a fault
in a January branch is found in a year. One organization on the e-Invoice
module aborted the whole run for every organization after it in the loop
— and on 1 January that includes their leave year.

### And what the mutation run added

Dropping `completed` from the status list survived the first pass,
because every fixture invoice was merely `posted`. That is the case the
consolidation exists for: a walk-in customer pays cash at the counter and
asks for no invoice, so the sale is settled the moment it is made.
Without a settled-invoice fixture the assertion would have passed while
excluding every counter sale and consolidating only the few nobody had
paid.

## The statutory order of the accounts

`fs_filings` carries three dates that are one sequence in the Companies
Act 2016 — approved (s.251), circulated (s.258), lodged (s.259) — and
nothing enforced that each happened before the next. The first two are
plain date pickers on the filing form and `fs_lodge` wrote the third
without looking at either.

`fs_deadlines` is what that costs. Its own comment says the s.259 clock
"runs from the act, not from the entitlement". Give it a circulation date
that precedes the approval it is supposed to be of, or a lodgement with
no circulation at all, and it computes a deadline from something that did
not happen and reports the filing compliant.

`corp_entity_id` had never been written either, so a corporate
secretarial practice preparing a client's accounts could not tie them to
the entity whose deadlines `0063` already tracks — the deadline board and
the accounts for the same company were two systems that had not been
introduced.

The guard judges the whole row rather than only the change, unlike most
here, and deliberately: three dates that describe one sequence are wrong
together, whichever of them the current edit touched.

Two fixtures elsewhere had to change, and both were the rule working:
`mbrs.sql` circulated accounts nobody had approved, and this file's own
first draft froze audited accounts with no auditor named.

### The sweep 0392 argued for

`0392` was found by the calendar, not by reading, so the first thing
after it was to ask what else of that shape is in here. Two questions,
both bounded:

**Which functions branch on the calendar?** Nine use `extract(day…)` or
`extract(month…)`, and eight of them are arithmetic — computing a
financial year end, an age in months, the last day of a period. Only
`run_daily_jobs` branched on *today*, and that is the one that was
broken.

**Which scheduled commands does no test ever run?** Four jobs are in
`cron.job`; `app.queue_all_activity_reminders` was called by nothing in
the suite. Run by hand it is clean and already isolated per organization
— no defect — but a function whose only caller is `pg_cron` is a
function whose first failure is discovered in production, a month later,
by nobody.

So the guard is derived from the schedule rather than from a list: the
new block in `scheduled_work.sql` reads `cron.job` and executes every
command in it, collecting failures rather than stopping at the first.
A job added later is covered without anybody remembering to add it — and
the job this would have caught was precisely one nobody thought to add
to a list.

It is a smoke test and says so in its own comment: it asserts each
command *completes*, not that it did the right thing. What each computes
is asserted in its own file. What is caught here is the class that fails
on the first statement, which is the class that actually happened. It
was verified by putting `0392`'s fault back — a bad enum literal inside
a cron'd function, call chain intact — and watching the block fail.

The one thing it cannot do is take a calendar branch: it runs each
command as today, and `0392` hid behind `if extract(day from p_on) = 1`.
That is what `monthly_jobs.sql` pins dates for, and why the two files
say so to each other.

## Who filed it

`attachments.uploaded_by` has been a column since `0008` and nothing has
ever written it — `attachments_repository.dart` inserts the org, the
entity, the file name, the storage path, the mime type and the size, and
leaves that one out. The same defect `0388` fixed on
`employee_documents`, one table over, and `attachments` is the general
store every entity in the system hangs files off, so it is where the
answer matters most and where it was missing.

The interesting part is not the fix but what to do with the second copy.
`0388` had written the rule as a trigger of its own three weeks of
migrations earlier. Writing it again here would be two copies of a
three-line rule, and two copies is how two copies come to disagree — so
`0393` generalises it into `app.set_filed_by()` and re-points `0388`'s
trigger at it. `app.employee_document_filed_by` is left defined rather
than dropped: migrations are append-only, and somebody reading the
history should find what `0388` says it created.

The mutation that mattered was removing the re-pointed trigger rather
than the new one. It killed against `employee_documents.sql` — which is
the assertion worth having, because the risk in consolidating two rules
into one is not that the new table misses out but that the old one
silently loses behaviour it already had.

Null on insert stays possible on purpose. A row written by a scheduler
or an edge function has no `auth.uid()`, and a not-null constraint would
refuse the write rather than record the truth, which is that nobody in
particular filed it. A caller that names somebody is believed — an
import knows who filed the original better than `auth.uid()` does.

## The vacancy nobody could open

`hiring_manager_id`, `requirements` and `target_start_date` on
`job_requisitions` have never been written, and the reason is the one
`0389` found on `projects`: nothing writes *any* column.
`Repo.requisitions()` selects the table, the talent screen lists what it
finds, and there is no insert and no update anywhere in the client. A
vacancy had to be typed straight into the table.

`0381` built the far end and could only assume this one — it hires an
applicant against a requisition, counts places against `headcount`, and
closes the requisition when the last place is taken. All of that worked
on rows nobody could create.

The rule with teeth is the hiring manager. It is who the applicants
belong to: the person an interview is arranged with, the person who
decides, and — once `0381` hires somebody — the manager the new employee
reports to. A vacancy advertised with nobody owning it collects
applications that sit in a queue no one is reading, which is the same
failure as `0192`'s ticket queue with no team and `0383`'s matter with
no fee earner. Drafts are exempt, because a draft is somebody working
out whether the role is wanted at all.

And the dates follow the status rather than sitting beside it.
`opened_date` and `closed_date` are plain date columns a form could have
set independently of the status next to them — the shape `0387` found on
a paid date and `0391` on a set of accounts. Here they are written by
`open_requisition` and `close_requisition` and never offered to be
typed, which is why the editor sends neither them nor the status.

Two mutants earned their fixtures. Guarding only `open` and not
`on_hold` survived: a vacancy parked while somebody decides is still
advertised and still collecting applications, and `on delete set null`
on that foreign key means its manager can vanish from under it. And
opening a requisition from a status that should not allow it survived
until a cancelled one was tried — reopening a cancelled vacancy is
raising a new one, because the old has a closing date and a reason and
writing over them loses both.

The fixture that had to change was `0381`'s own: its helper opened a
requisition with nobody owning it. It now makes the manager it needs.

## The number to call while they are away

`leave_requests.contact_while_away` has been a column since `0027`,
never written by anything and never read. That is a smaller find than
the last few, and the interesting part is why it needed SQL when two
columns beside it did not.

Three columns came out of the same sweep. `employees.emergency_contact_*`
and `positions.job_description` are written straight into their tables
by the client under the ordinary RLS policies, so the whole of their
fix is a form field — a phone number has no arithmetic, and writing a
trigger to justify a migration would be inventing rules. Both got a
form field and no migration, and that is the sweep working: knowing
which gaps are *not* worth SQL is part of its value.

This one is different, and not cosmetically. The only write path into
`leave_requests` is `submit_leave_request`, a SECURITY DEFINER function
whose parameter list is the whole interface. No form could reach the
column however it was built. A gap in a SECURITY DEFINER signature is a
schema fault wearing a UI fault's clothes, and the way to tell the two
apart is to look at *how the row is written* before deciding what layer
to fix it in.

Once reached, the column turned out to be unusual in a second way. It
is the one field on a leave request that cannot be right at the moment
it is submitted: where somebody is changes, and the number given a
fortnight before departure is a hotel they have since left. `0038`'s
update policy freezes the row once it leaves draft — correct for the
dates, since an employee who could edit those after approval could take
three weeks against an approval for three days — and it freezes this
one too, against the only person who knows the new number. So the fix
is a function for that single field rather than a widened policy: a
policy permissive enough to let the employee change the contact would
let them change the dates.

`submit_leave_request` was dropped and recreated rather than gaining a
default, for the reason `0351`'s header sets out. The mutation run
proved it rather than asserting it: leaving the nine-argument version
in place alongside the ten-argument one makes the tests' own six-
argument call fail with "function public.submit_leave_request(...) is
not unique" — `42725`, at run time, and in no test that does not think
to count the functions. `leave_requests.sql` now counts them.

Two mutants were instructive. Dropping `and r.status = 'approved'` from
the report survived at first, because the assertion that nobody is away
was being made by a caller who could not see anything anyway — an
assertion passing vacuously is worth more attention than one failing,
because nothing announces it. The fix was not to the mutant but to the
report: it had been scoped to HR and managers while its own header
claimed to return what `0038`'s select policy allows, and that policy
allows an employee their own request. Matching the code to the claim
made the assertion mean something and killed the mutant.

The other is the order of the guards in `update_leave_contact`. The
permission check runs before the status checks, so a manager who may
decide the request but is not the person on leave is refused for being
the wrong person, and is not told in passing what state the request is
in. That ordering is asserted, because reversing it answers a question
the caller was not entitled to ask.

## The idempotency key that was built and never sent

The sweep that found `contact_while_away` generalises. A SECURITY
DEFINER function's parameter list *is* its interface, so a parameter no
caller ever supplies is the same defect as a column nothing writes. Ask
the database for every client-callable function's parameter names, ask
the client for every `'p_…'` string literal it contains, and subtract:
fifteen functions have a parameter nothing anywhere passes.

The worst of them is `p_idempotency_key`, on `post_manual_journal`,
`create_contra`, `create_deposit` and `record_pdc`.

`0307` built the whole mechanism — the key table with its per-org
uniqueness, the fingerprint check, a 24-hour sweep on the daily
scheduler, revoked grants, and `idempotency.sql` in CI. Its header is
careful and correct about PostgREST overload resolution, and it contains
this sentence: "breaking the existing client, which sends no key." The
client was never changed. So the mechanism has been complete, tested and
entirely inert since, and a double tap on Post — or a retry after a
request that timed out on the way back — has posted twice the whole
time.

This is `0388`'s shape again, a stated intention with nothing behind it,
and one step worse: `0388` had a comment and an index, and this has a
comment, an index, a table, a test and a scheduled job.

### The half that is easy to get wrong

The wrapper has **no defaults on any parameter**, not just on the key.
That follows from how it is written and nobody had said it out loud. A
caller that names the key but omits one merely-optional argument does
not get an error and does not get a warning: PostgREST resolves the body
against the *original*, which does have defaults, does the work, and
returns an id. The screen is right, the ledger is right, and the
guarantee is gone. `postManualJournal` omitted `p_reference` whenever
the box was blank, so it would have been unprotected on exactly the
entries people type fastest.

### Sending *a* key is not enough

Three rules make a key correct, and each of them is a way to get it
wrong:

- **Retained across a failure.** A fresh key per attempt protects
  nothing, which is the whole point of the mechanism.
- **Retired on success.** Two identical petty cash entries on one day is
  an ordinary thing to do, and a key held past its success collapses the
  second into the first and hands back the first entry's id.
- **Re-minted when the payload changes.** `0307` refuses a key reused
  for different arguments with `22023`, so a failure the person fixes by
  editing the form would come back as an error they cannot act on.

The client compares payloads on the parameter map's own `toString`,
which is stable because these maps are built from literals in a fixed
order. It does not have to be canonical: the server computes the
authoritative fingerprint, so the worst a disagreement can do is produce
a refusal, never a wrong post. Keys live in memory, so a page reload
loses one — a reload is a fresh attempt from the person's point of view,
and that is the honest limit of a client-held key rather than something
to work around.

### The guard

`scripts/check_idempotent_calls.py`, next to `check_embeds.py` in CI and
for the same reason: this is the only place the two halves meet. The
analyzer sees a map of string literals, the SQL tests know the wrapper
works but not who calls it, and the widget tests do not talk to a
database. It asks the database which functions have a key overload, then
checks that every `callRpcOnce` names a real one, names *every* one of
its parameters, and that no protected function is also reachable through
plain `callRpc` — one path, per `0386`.

Run against the repository as it stood before the fix, it reports all
four as having protection that is not in force. That is the finding,
stated by the thing that will now keep it stated.

## A version this build cannot sign

The same RPC-parameter sweep put `set_einvoice_credentials` next on the
list: five certificate parameters — `p_cert_pem`,
`p_cert_private_key_pem`, `p_cert_serial_number`, `p_cert_issuer_name`,
`p_cert_expires_at` — that nothing has ever passed.

The obvious conclusion was wrong and it is worth recording why. The
XAdES signature those columns exist for is **not** an undiscovered gap:
`0015`'s own comment on the columns says they are "PKCS#12 material for
the XAdES signature required by version 1.1", and `README.md` says
plainly that documents are submitted as version 1.0 unsigned, that 1.1
needs a certificate from a Malaysian certificate authority, and that the
signing step is not implemented. Checking before claiming a find is the
whole of the difference between this and the previous two entries.

The defect is next to it. Nothing enforces the scope the README
describes. `prepare_einvoice` resolves the version as

    coalesce(v_org.settings ->> 'einvoice_version', '1.0')

and `ubl.ts` puts whatever comes out into `listVersionID`. Between those
two points there is no validation at all. `organizations.settings` is
free-form jsonb and `0010`'s update policy covers the whole row, so any
admin may write it — `banana` would go to LHDN as the version of a tax
document, and `1.1` would go as a claim that the document carries a
signature it does not have. That is worse than a refusal: a refusal is a
message somebody reads, and this is a filing with a false statement of
what it is.

And the column's default was `'1.1'` from `0007`, on a build that can
only produce 1.0. The reason nobody noticed is that `prepare_einvoice`
is the only insert path and it always names the column — but
`einvoice_statutory.sql`'s own fixture never did, so every e-Invoice row
the test suite has ever made was stamped as the signed version. The
default did bite. It bit in the fixtures, where nobody looked.

`0396` puts what the build can produce into one immutable predicate and
has both a check constraint and a `before insert or update` trigger read
it, so they cannot disagree. Whoever implements the signature changes
that one function and nothing else.

### An unkillable mutant that is not redundant code

Dropping the check constraint leaves every assertion in the file
passing: the trigger covers every path a test can take, so no behaviour
distinguishes them. That looks like `0387`'s rule — an equivalent mutant
means redundant code — and it is not the same case. In `0387` two
triggers *derived* the same value and could drift apart, so consolidating
them removed a real risk. Here both read one predicate and cannot drift.
What the constraint adds is not enforcement but declaration: it is what
a schema dump shows, and it makes removing the rule a deliberate act
rather than a side effect of dropping a trigger.

So the resolution is neither to delete it nor to pretend the mutant died:
the existence of both is asserted directly, the way `statutory.sql` and
`table_grants.sql` assert grants and policies. When behaviour cannot see
a control, assert the control.

## The leave request for minus twenty days

The next item on the RPC-parameter sweep was `submit_leave_request`'s
`p_is_half_day` and `p_half_day_period`, which `0027` modelled
deliberately ("half days are common enough to model directly rather than
as hours") and no caller has ever passed. Looking at why led somewhere
larger.

`submit_leave_request` takes the number of days from its caller and
never relates it to the dates it was given. Measured on the harness, an
employee with fourteen days of annual leave filing one request for
themselves, needing nobody:

    submit_leave_request(org, annual, tomorrow, tomorrow, -20)

    before        entitled 14.00  taken   0.00  pending   0.00  available 14
    after submit                                pending -20.00  available 34
    after approve                 taken -20.00  pending   0.00  available 34

Twenty days of annual leave, out of nothing. The hold is applied as
`pending_days + p_total_days`, so a negative subtracts;
`decide_leave_request` then moves it into `taken_days`, where it stays.
Every step below is a correct addition of a number nobody checked, and
the manager approving it sees an ordinary one-day request — the days are
on the balance, not on the screen they clicked. Unused annual leave is
commonly paid out on termination, so this is not only an HR figure.

The other direction has no bound at all on unpaid leave, where the
entitlement check is skipped deliberately and correctly: a one-day
request may claim 300 days, and that figure is what
`calculate_payroll_run` multiplies by `basic_salary /
working_days_per_month` and takes off gross pay, the EPF wage, the SOCSO
and EIS wages and taxable income.

It does *not* run the other way, and it is worth saying so rather than
overstating the find: the payslip line is written only `if
v_unpaid_amt > 0`, so a negative figure writes no line and pays nobody
extra. It is still stored in the payslip's own `unpaid_leave_days` and
`unpaid_leave_amount` columns, which is a payslip disagreeing with its
own lines.

### The bound that can be checked, and the one that cannot

The upper bound needs nothing but the dates: fourteen calendar days is
at most fourteen days of leave. The lower bound needs the work calendar
— ten days over Chinese New Year may honestly be three days of leave —
and `work_shifts` and `public_holidays` both exist and neither is
consulted. `0397` enforces the upper bound and states that the lower one
is missing, rather than inventing a working week that would be wrong for
every company that does not keep it.

### Two rules that had never met

`0365` added `enforce_half_day_rule`: a leave type may forbid half days
and a request marked as one is refused if it does. The rule works — set
the flag directly and it fires. Nothing had ever set the flag, so it
guarded a door nobody could open. `0397` writes the arithmetic both ways
round: a half day is 0.5 days on one date, *and* 0.5 days is a half day.
Without the second, a caller reaches past `0365` by claiming half a day
and leaving the flag off, which is exactly what every caller did.

### A redundant branch, kept and made killable

Two mutants survived the first run: removing the `total_days <= 0` check
entirely, and narrowing it to `= 0`. Both survive because `total_days <
0.5` already refuses a negative — with the wrong sentence, telling
somebody who filed -20 that the shortest leave is half a day.

`0387`'s rule says an equivalent mutant means redundant code, and
deleting the branch was one honest option. The other is to make the test
tell the two apart, which is what a distinct message is *for*: the
assertions now check which sentence came back, not only the sqlstate.
Both mutants die. A branch that exists only to say something better is
worth keeping precisely when something notices it has stopped saying it.

## The business activity that was the letters NA

`organizations.business_activity` is the sweep's fifteenth unpassed
parameter and the last one worth a migration. `create_organization`
takes `p_business_activity`, the onboarding form does not send it, and
`updateCompanyDetails` writes `msic_code` while omitting this column
beside it. Nothing has ever written it.

`prepare_einvoice` snapshots it onto every document, and `ubl.ts` does
this:

    party.IndustryClassificationCode = v(msicCode, {
      name: businessActivity || "NA",
    });

So every e-Invoice, from every organization, has told LHDN that what the
business does is `NA`.

### The answer was already in the database

`ref_msic_codes` has held `(code, description)` since `0002`, and the
MSIC code is picked from exactly that list. `IndustryClassificationCode`
carries the code and its `name` is the description *of that code*. They
are one fact.

Which is why `0398` adds no text box. A free-text `business_activity`
beside a picked `msic_code` is two places to say one thing, and the
second is how the two come to disagree — `0393`'s argument for
`app.set_filed_by()`. An organization that has its own wording keeps it;
one that has not is not asked to retype what it chose from a list a
moment earlier.

It is filled in on insert rather than resolved at send time because an
e-Invoice is a snapshot and `prepare_einvoice` is careful to make one:
it copies the supplier's name, TIN, address and SST number so a document
filed in March still says what the company was in March. Resolving the
description at send time would rewrite filed history whenever the
reference list was corrected.

### Two mutants that found unbacked claims

The header said "a caller that supplies one is believed". Making the
trigger overwrite unconditionally survived, because no test supplied
one — a claim in prose with nothing behind it, which is the exact fault
`0390`'s first draft had and `0388` is named after. Asserted now.

Then narrowing the guard from "blank or null" to "null" also survived,
and that one is not cosmetic: `prepare_einvoice` inserts the
organization's column straight through, so an organization holding `''`
would put `''` on the document, and `ubl.ts` renders `''` as `NA`. The
`btrim` is what stops the original defect returning by a side door, and
now something says so.

### And the ones deliberately left

Of the fifteen, most are feature gaps rather than defects and it is
worth naming them so the sweep is not re-run over them. `email_document`
takes `p_share_days integer default 30` and nothing passes it, which
means every share link lives thirty days — a sensible default nobody can
override, not a link that never expires. `run_inventory_forecast`'s
`p_as_of`, `log_document_download`'s `p_format`, `platform_save_module`'s
`p_is_core` and `chat_typing_ping`'s `p_seconds` are the same shape:
defaults that are right, and a parameter for choosing otherwise that no
screen offers. `clock_in`/`clock_out`'s `p_device` and `p_terminal` and
`create_ticket`'s `p_requester_user_id` are provenance fields with no
arithmetic attached, in the same class as the emergency-contact columns
`0395` gave a form field and no migration.

## Three sweeps that found nothing

The four migrations above came out of one sweep, so the next three were
run in the same spirit and are recorded here because they found no
defect. A sweep with no result is worth writing down twice over: it
stops the next person repeating it, and the false positives say why a
checker for it would not be worth having.

**Every map key the client reads against every name the database
returns.** 1378 distinct `row['key']` subscripts in `app/lib`, checked
against every column, every function parameter, every `returns table`
column, every table name and every key built by a `jsonb_build_object`
in a deployed function body. 31 survived, and all 31 are legitimate:
edge-function JSON payloads (`ice_servers`, `extraction`, `suggestions`),
PostgREST embed *aliases* whose name differs from the table
(`approver:employees!fk`, `decider`, `requester`, `from_account`), and
PostgREST aggregate embeds — `property_units(count)` returns a
one-element list whose `count` is not a column anywhere.

No CI guard came of it, deliberately. Those three legitimate sources are
indistinguishable from a typo without attributing each key to the call
that produced it, and a checker that cries wolf on correct code is worse
than none — `check_embeds.py` and `check_idempotent_calls.py` earn their
place by having no false positives at all.

**What the client sends each edge function against what that function
reads.** Ten functions on disk, seven invoked from the app; the three
that are never invoked are inbound webhooks and a scheduled job, which
is correct. One apparent finding: the client sends `org_id` to
`myinvois` and `supabase/functions/myinvois/index.ts` reads only
`body.action`. It is a false positive, and instructive — `_shared/
context.ts` reads `body.org_id`, requires it, and validates membership
through the *caller's own* client so that a forged one is refused. A
checker that does not follow the shared helper reports correct code as
broken.

**Every SECURITY DEFINER function granted to `authenticated` that
carries no visible guard.** Written first as a list of guard names, which
was wrong: it accused `chat_add_participant` and the three appraisal
functions, all of which guard through helpers not on the list
(`app.is_chat_participant`, `app.chat_enabled`, `app.chat_can_join`,
`app.appraisal_part`). Rewritten as "calls no `app.*` function and does
not mention `auth.uid()`" it leaves four: `fs_balance_check`,
`cash_runs_out_on` and `decide_expense_claim` are thin wrappers whose
callees — `fs_prepare`, `report_cash_forecast`, `decide_claim_step` —
each guard, which was checked rather than assumed; and `site_pages`
returns the sign-in page's own text and is granted to `anon` on purpose.

The lesson from the third is the one worth keeping. A guard sweep
written as a list of known guard names measures the list, not the code.
Asking instead whether a function consults *anything* about who is
calling is the question that has an answer.

## The ledger had a door beside the door

`post_manual_journal` fixes the journal's source, checks the accounts,
checks that debits equal credits and checks the period. Its own comment
says why: "the client has no business asserting where a ledger entry
came from … so nothing here is trusted."

`gl_entries` and `gl_lines` were `INSERT`able by `authenticated`, under
a policy that checked one thing — `app.can_post(org_id)`. No period. No
balance. No accounts. PostgREST publishes every table the grants allow,
so the second door was an HTTP request wide.

Measured as an `accountant`, with a period closed: an entry dated inside
the closed period went straight in; a line of 1,000,000 debit with no
credit went in after it; `post_manual_journal`, given the same closed
period, refused it. The front door was never wrong — it was avoidable.

### The measurement that proved nothing

The first run of that experiment was worthless and it is worth saying
why. `pg_temp.sign_in_as` sets `request.jwt.claims` and does **not**
change the session role, so a test that only signs in still runs as the
table owner — exempt from RLS, needing no grants. Every insert
"succeeded" for a reason that had nothing to do with the policies.

The tell was that the back door stayed open after the grant was revoked.
A fix that changes nothing means the thing being measured was not the
thing that mattered. `access_types.sql` already had the right idiom —
`set local role authenticated` — and the new test asserts
`current_user = 'authenticated'` before anything else, so the file
cannot quietly go back to proving nothing.

### `0239` kept the grant on purpose, for a reason that was false

`0239` revoked update, delete and truncate from the ledger and asserted
what was left, calling the INSERT check "the positive control" — a good
instinct, since revoking everything would satisfy a no-excess-privilege
check by leaving nothing. But `app.create_gl_entry_internal`,
`create_gl_entry` and `post_manual_journal` are all SECURITY DEFINER and
all owned by the role that owns `gl_entries`, so posting runs as the
owner and never consults the `authenticated` grant.

Measured rather than argued: with INSERT revoked and both policies
dropped, `post_manual_journal` called *as `authenticated`* still posts
and still writes both lines, and the direct insert returns `42501`. The
grant cost the whole of period control and bought nothing. A positive
control has to exercise the thing, not check that a privilege exists —
so the new test posts, and would fail if posting broke.

### The assertion earned its place on the first run

`0399` was written with a `do $$` block that re-checks the grants after
setting them, on the reasoning that nothing stops a later `grant all`
undoing a revoke. It refused the first time it met the hosted project:

    FAIL 0399: a client role holds DELETE, SELECT, UPDATE on the ledger,
    expected SELECT

Asked precisely, the hosted project held `INSERT, SELECT` for
`authenticated` on both tables — as intended — and `DELETE, INSERT,
SELECT, UPDATE` for **`anon`** on both. `0238` revoked update and delete
*from `authenticated`* and never named `anon`; `0239` revoked truncate,
references and trigger from both. So `anon`'s write privileges were
never taken away there, and a freshly migrated local stack does not have
them, because Supabase's default privileges differ between a new hosted
project and a `supabase start`.

**Excess privilege, not an open door, and the distinction matters.** RLS
is enabled on both tables on the hosted project and the only policies on
either are insert and select — there is no update policy and no delete
policy, so both are denied to every non-owner role whatever the grant
says, and the insert policy demands `app.can_post(org_id)`, false for a
caller with no `auth.uid()`. Checked against the project, not assumed.

What it did mean is that the ledger's protection rested on RLS alone
where it was meant to rest on RLS *and* the absence of a grant — and
that nothing in this repository could see the difference. The local
stack is built from these files, so it cannot disagree with them. Only
something that runs against the real project can, and the only thing
that does is a migration. That is the argument for asserting state
inside a migration and not only in a test, and it is stronger than the
one `0399` was written with.

So `0399` now revokes insert, update and delete from both roles on both
tables rather than only insert: revoking an absent privilege is a no-op,
so naming all of them converges the two environments instead of
describing either. The test names each role and privilege separately,
because the aggregate message said "DELETE, SELECT, UPDATE" and it took
a second query to learn all three belonged to `anon`.

### Left alone, deliberately

An accountant can also flip a period from `closed` back to `open`:
`fiscal_periods_update` is `using (app.can_post(org_id))` over the whole
row. Reopening a period to book an adjustment before the accounts are
finalised is ordinary practice, and *who* may do it is a decision for
the company rather than one to make on its behalf inside a migration
about something else. Recorded here so the decision is available rather
than merely missing.

The related worry does not arise: `gl_entries_fiscal_period_id_fkey` is
`no action`, so a period with entries cannot be deleted from under them.
Checked, not assumed.

### And one thing found on the way that turned out to be nothing

While writing the test above, a freshly posted entry read
`total_debit = 0.00` against lines summing to 100.00, on both
`post_manual_journal` and `create_gl_entry`. The commit that added `0399`
recorded that as an open contradiction to resolve. **It is not a defect,
and this paragraph corrects that.**

`assert_balanced` on `gl_lines` is a DEFERRABLE INITIALLY DEFERRED
constraint trigger, so it runs at COMMIT, and `app.assert_gl_balanced`
is what maintains the entry's totals from its lines. Every probe here
runs inside `begin … rollback`, so commit never arrives, the deferred
trigger never fires, and the totals sit at zero.

`0238` says this already, in as many words:

> A rolled-back probe never reaches commit, so the deferred trigger
> never fires and the totals sit at zero — which looks identical to the
> bug. `SET CONSTRAINTS ALL IMMEDIATE` forces it.

Forcing it: `total_debit = 100.00`, `total_credit = 100.00`. The totals
are maintained correctly and `ledger_append_only.sql` asserts exactly
that, which is why it passes and why there was never a second path.

Worth leaving written down, because the trap caught someone who had read
`0238` an hour earlier and quoted a different part of it in the same
sitting. A rolled-back harness cannot see anything a deferred trigger
does, and "the value is zero" is indistinguishable from "nothing set the
value" unless you force the constraints. The rule that follows: before
reporting that a column is not maintained, run `set constraints all
immediate` and look again.

## No hand may reach a posted payslip

`0399` came from asking what a client role can do directly to a table
whose rules live in functions. Asked of every table, that question is
too coarse to be useful: 202 tables carry a client write grant, 118 of
them are never written by the app, and most of those are ordinary CRUD
or features not built yet. Revoking 118 grants on a hunch is not a fix,
it is a gamble.

So the same question was asked where the stakes are highest and the
shape is identical to the ledger's — payroll. `payslips`,
`payslip_lines` and `payroll_ytd` are written by `calculate_payroll_run`
and nothing else; every writer is SECURITY DEFINER; the client only
reads them.

But unlike the ledger, the write policy is *named and deliberate* —
`payslips_write`, created by `0038` — so "the same shape" was not
evidence of "the same defect". That needed measuring, and the thing
worth measuring was the one `0238` had already identified for the
ledger: whether a hand can reach a record that has been reported.

As an `hr_manager` over PostgREST, on a run whose status is `posted`:

    update payslip_lines set amount = 1     -- 550.00 -> 1.00, accepted
    update payslips set epf_employee = 1,
                        pcb = 0             -- accepted
    delete from payslip_lines               -- accepted
    audit rows written by all of that       -- 0

`payslip_lines` carries no triggers at all — not `set_updated_at`, not
`audit_changes`. The EPF, SOCSO, EIS and PCB figures of a posted run
could be rewritten by hand and nothing recorded that they were, while
those figures are what the EPF, SOCSO and LHDN submissions and `0035`'s
bank file are built from, and while `post_payroll_run`'s journal is
already in a ledger `0238` made append-only. The payslip could be made
to disagree with an entry that cannot be corrected to match it.

`CLAUDE.md` says anything touching EPF, SOCSO, EIS or PCB needs a test
that would fail if the number moved. `payroll_run.sql` and
`statutory.sql` assert those numbers thoroughly — at the moment the
engine computes them. An assertion about a calculation says nothing
about a figure a hand changed afterwards.

### Frozen at posted, and not before

Deliberately narrow: `draft`, `calculated` and `approved` stay fully
editable, because correcting a payroll before posting is the ordinary
business of running one, and `calculate_payroll_run` rebuilds the
payslips from scratch on every recalculation anyway. `void` stays
editable too — voiding is how a run is undone, and undoing should be
visible rather than overwritten.

It breaks nothing, and that was checked rather than assumed:
`calculate_payroll_run` refuses outright unless the run is `draft` or
`calculated`, and `post_payroll_run` writes only to `payroll_runs`.

A trigger rather than a narrowed policy, for two reasons. `0038`'s
policy is one line of a pattern applied across a dozen HR tables, with
the comment above it explaining only the *select* side — it was the
default that fell out of a sweep, not a decision about hand-editing
statutory figures. And a `using` clause gives a bare `42501` with
nothing to read, where the trigger names the run, its state, and what to
do instead.

Six mutants, all killed, and three of them are about the boundary rather
than the rule: leaving `paid` editable, freezing `approved` as well, and
freezing `void` as well are each caught by the loop that walks every one
of the six statuses and asserts which side of the line it falls on. A
rule that depends on a status wants a test that tries every status.

### Still open, and named so it can be decided

`payroll_ytd` is not frozen. It carries the year-to-date figures PCB is
computed against, so editing it changes future months rather than a
filed one, and "posted" does not apply to it cleanly — it is per
employee and year, not per run. Freezing it needs a rule about what a
year-to-date correction *is*, which is a decision rather than a defect.

Neither table gained an audit trigger. Recording a pre-posting
correction is worth doing and is a different change from refusing a
post-posting one; bundling them would have made this migration about two
things.

## The role that is nobody could write everything

The `anon` grants `0399` tripped over on the ledger were not confined to
the ledger. Asked of the whole hosted schema:

    anon holds INSERT, UPDATE or DELETE on   251 relations in public
    of which RLS is enabled on               250
    the one without is v_stock_valuation, a view
    policies anywhere naming anon or public for a write ....... 0

Zero. Not one policy in the schema admits `anon` to write anything, so
every one of those 251 grants is a privilege RLS refuses on every row of
every table, every time.

The relation without RLS was worth a second look, because "RLS disabled"
is also what a real exposure looks like. `v_stock_valuation` is a view —
views carry no RLS of their own — and it is `security_invoker = on`, so
it runs with the caller's rights and the RLS underneath applies. No
exposure. Checked against the project rather than assumed.

### Why remove a privilege RLS already refuses

`0240` removed TRUNCATE, REFERENCES and TRIGGER from both client roles
while noting they were unreachable through PostgREST, on the argument
that "anything holding a connection string gets the privilege, not the
API's opinion of it".

These three are the opposite case. PostgREST emits POST, PATCH and
DELETE all day, so RLS is the only thing in front of them — which puts
the whole of `anon`'s inability to write this database on every policy
being right, forever, across 250 tables. That is a great deal to ask of
one layer when the second costs nothing. `anon` is the role for a caller
who has not signed in, and there is no table here such a caller should
write.

`0401` takes the three from `anon` on every relation in `public` and
narrows the default privileges so the next table created does not hand
them back. `authenticated` is untouched and asserted to be untouched:
the application writes as `authenticated` constantly, and narrowing that
is a table-by-table question — `0399` and `0400` are two of those
answers — not a sweep.

### The positive control that was wrong first

The first draft asserted that `anon` could still `SELECT` the
`site_pages` table, and it failed on a local stack. `anon` never reads
that table: it calls `public.site_pages()`, a SECURITY DEFINER function
of the same name that reads the table as its owner.

That mistake is the argument for the migration restated. The anonymous
surface of this application is **nine functions** —
`site_pages`, `landing_page`, `open_shared_document`,
`open_shared_ticket`, `reply_to_shared_ticket`, `public_pos_menu`,
`place_public_pos_order`, `corp_sign_with_link`, `corp_decline_with_link`
— every one of them `prosecdef`, each writing as its owner. None of them
consults a grant held by `anon`, which is exactly why taking those
grants away reaches none of them. So the control is the surface itself:
all nine still executable by `anon`, asserted in the migration and again
in `table_grants.sql`.

## 0402 — the invoice that could be posted twice

`0238` made the ledger append-only, `0399` shut the door beside it and
`0400` did the same for the payslip. The sales invoice is the biggest of
the four and nobody had applied it there.

Measured as an `accountant` under `set local role authenticated`, on one
posted RM1,000 invoice: the line repriced to RM1.00 and the header
recomputed to RM10.00 to match; the header rewritten directly to RM5.00
under a different number; the lines deleted; the document itself deleted
with its journal left standing; and — the one that costs money rather
than merely confusing the books — `gl_entry_id` set back to null,
`post_sales_document` called again, and a second journal raised. Two
entries, RM2,000 of revenue and receivable, for one RM1,000 sale.

`post_sales_document_internal`'s only defence against a second posting
is `if v_doc.gl_entry_id is not null`, which is a fact stored in a column
the client may write.

### The rule already existed, in Dart

`document_editor.dart` has always had `bool get _isPosted => _glEntryId
!= null;` and `final editable = !_isPosted && …` — the same predicate,
by the same reasoning, one layer up. Nothing in the client needed
changing. It was right; it was only alone, and PostgREST publishes both
tables to anyone holding a session.

### Named columns, both ways round

A blunt freeze would have broken the application on the day it applied.
`apply_allocation` moves `paid_amount`, `balance_amount` and `status` on
every payment; the MyInvois submission writes `einvoice_status` after
posting; `void_sales_document` writes `status` and `internal_notes`; and
`refresh_sales_progress` writes `fulfilment_status` on the header and
the progress counters on the *lines* of a posted document. So the
migration freezes a named list — the figures and identifiers the journal
was built from — and lets the rest go on moving.

A deny-list is only as good as its list, so
`posted_document_is_frozen.sql` walks all four tables and requires every
column to be in the frozen set or in an explicitly named writable set. A
column added later is in neither and fails, which is the point.

### contact_id, which came back off the list

It was frozen in the first draft — `post_sales_document_internal` writes
it onto the receivable line, so moving it leaves the document and the
sub-ledger naming different people. Running the suite refused a real
path for it, which is the argument for running the suite rather than
trusting the reasoning: a counter sale posts against the outlet's
walk-in contact, and `request_einvoice_for_sale` puts the customer's
name on it afterwards when they ask for an e-Invoice. `0210` wrote that
deliberately with LHDN's rules attached.

So `contact_id` is writable and the disagreement is closed at the other
end instead: `request_einvoice_for_sale` now moves the receivable line's
`contact_id` with the document's, in the same transaction, as the owner.
Nothing else about the journal moves — not the amount, the account, the
date or the entry.

### What only the line rule reaches

Every write to a line runs `recalc_totals`, which rewrites the header —
so a line change that moves money is refused by the *header* rule
whether the line rule exists or not. Mutation testing said so: switching
the line rule off entirely left "a posted invoice's line cannot be
repriced" passing, which meant the assertion was measuring the wrong
trigger. Three of the first eight mutants survived for this reason.

The questions only the line rule can answer are the columns no total
depends on — `description`, `item_id`, `account_id`, `warehouse_id`,
`cost_amount`, `0309`'s `service_start`/`service_end`, and the
`project_code` / `department_code` dimensions the journal line carries —
and a line worth nothing, whose arrival or departure moves no total at
all. The fixture keeps a nil-value line for exactly that.

### Named as decisions, not defects

* **`deleted_at` is still writable on a posted document.** Soft-deleting
  a posted invoice hides it from every report while the ledger keeps its
  journal. `void_sales_document` is the supported way to undo a posting
  and it is what the client offers; whether a soft delete should be
  refused as well is a decision, not an oversight.
* **A data backfill will now hit this trigger.** `0270` ran
  `update public.sales_document_lines set …` at migration time, as the
  owner, and a trigger fires for the owner too. Nothing retroactive
  breaks — `0270` ran long before `0402` — but the next migration that
  wants to reshape a column on these tables will have to say so.

## 0403 — the column that says "this was already posted"

`0402`'s sharpest find was not an amount. It was that clearing
`gl_entry_id` let the same invoice be posted a second time, because
`post_sales_document_internal`'s entire defence against a double posting
is `if v_doc.gl_entry_id is not null` — a fact stored in a column the
client may write.

Asked of the catalogue rather than remembered: **eleven** posting
routines guard the same way, and every table they read it from grants
UPDATE to `authenticated`. Measured on `expenses`, chosen because it is
not a document: an RM100 expense posted, the column cleared by hand,
`post_expense` called again — two entries, RM200 charged to the profit
and loss for RM100 of petrol. So it was never a fact about invoices.

`0403` is one narrow rule on twenty tables: `gl_entry_id`, once set, may
not be given a different value or taken away. Setting it for the first
time is untouched, because that is what posting is — every posting
routine writes `null -> <entry>` and nothing else, so none of them can
trip it. Everything else on a posted row goes on moving; `0402` is what
a full freeze looks like, and it took a named column list per table to
write safely, which is why it covers two tables and this covers twenty.

The triggers are built from the catalogue rather than a list, and
`posted_link_is_immutable.sql` asks the catalogue the same question, so
a table created next year with the column and no trigger fails.

### bank_transactions, excluded on purpose

There the column means "which journal this statement line was matched
to", not "the journal I posted as". `unmatch_bank_transaction` clears it
as an ordinary correction, and freezing it would break reconciliation —
the column would have been frozen on the strength of its name rather
than its meaning. The exclusion is asserted by actually unmatching a
bank line, not by reading a list of trigger names, because a list of
trigger names measures the list.

### The probe that was killed by a foreign key

The "pointed at a different journal" assertion first used an all-zeros
uuid. With the rule switched off it died on
`expenses_gl_entry_id_fkey` and passed while proving nothing. `0399`
made the same mistake and left the same note. The fixture now posts a
second expense so there is a real journal belonging to something else to
point at.

### The overlap with 0402, checked

`0402` already froze `gl_entry_id` among its named columns on the two
document tables, so those two are covered twice. Taking it out of
`0402`'s list with `0403` in place still fails
`posted_document_is_frozen.sql`: Postgres runs triggers in name order,
`refuse_posted_change` before `refuse_reposting`, so on those two tables
the caller gets `0402`'s document-specific answer and the assertion
reads the message. Not an equivalent mutant, and not dead code. On the
other eighteen tables `0403` is the only rule there is.

## 0404 — the wage that fell between two bands

`app.calc_statutory` looks up the band a wage falls in and, finding
none, returned zero **and the schedule's own `is_verified`**. So a
statutory table checked against the gazette but missing a band produced
a zero contribution reported as a verified figure — and
`payslip_pdf.dart` prints its warning off exactly that flag, so the one
payslip that most needed a warning was the one that got none.

Nothing in the seeded data has a hole: every category ends in an
open-ended band. What creates one is the thing this schema was built to
have happen. `0026` seeded from published percentages and marked every
schedule unverified, with `README.md` saying they must be transcribed
from the authority's gazetted table before anything is filed — and the
KWSP Third Schedule *is* a table, a finite list of bands with a top row.
A person transcribing it is a person typing a `wage_to` on the last
band.

SOCSO and EIS are worse, because the ceiling is already modelled
properly as `wage_ceiling`. A transcriber has two plausible ways to
write the same rule and only one is right: `wage_to = 6000` looks
identical to `wage_ceiling = 6000` on the page and means "nobody above
RM6,000 contributes" rather than "contributions stop counting above
RM6,000".

`0404` adds `app.assert_statutory_bands`, called by
`platform_publish_statutory_schedule` in the transaction that inserts
the rates: every category must start at zero, run without gaps or
overlaps, and end open. And `calc_statutory` still returns zero for a
wage no band covers, but no longer calls it verified.

### The suite refused the first draft, and it was right to

The first draft made `calc_statutory` raise instead of returning zero.
Running the suite found that `statutory_schedules.sql` asserts the
zero-fallback deliberately — "it contributes nothing rather than
guessing at the nearest band" — which is a decision somebody took and
wrote down, and it holds: guessing at a statutory figure is worse than
declining to produce one, and the schedule consulted is recorded either
way. The problem was never the amount. It was the third value.

What that fixture also showed is the harm sitting in the repository as
an expectation: it published three bands of the PERKESO Third Schedule
**with `is_verified = true`**, then asserted that a wage of RM4,000 —
squarely in a gap — contributes nothing. Under `0404` that table can no
longer be published at all, so the fixture now inserts its partial bands
directly, which is honest about what it is, and asserts the refusal
separately.

### A warning that was firing on the wrong payslip

The same function returned `false` for the verified flag whenever the
wage was zero, lumping "there is no schedule" together with "this
employee was on unpaid leave all month". The second is not an
unverified payslip, and printing "the statutory figures on this payslip
have not been verified" on a document that goes to a person is a false
alarm. Split.

### The gap branch that no assertion reached

Mutation testing: allowing a gap between bands survived every assertion
in `statutory_schedules.sql`, because the fixture's gap is caught first
by the "must start at zero" rule. Three more probes were added — a step
missing from the middle, two bands over the same wage, and a band after
the one that runs to the top — so each branch is refused for its own
reason.

## A fourth sweep, which found nothing and is now a test

**Can a member of one company read another company's rows?** Thirty-odd
assertion files exercise RLS for the feature each of them is about.
Nothing asked the question in general, and it is the worst failure this
product could have and the least likely to be noticed, because a leak
looks like data.

Asked of `pg_policy` first, and that answered nothing useful. Nine
policies on org-scoped tables never mention `org_id`, and all nine are
correct: `false` on `approval_requests` and `approval_steps`, which are
reached only through SECURITY DEFINER functions; `user_id = auth.uid()`
on `chat_participants`, which is narrower; `app.is_chat_participant(...)`,
which scopes through a helper; and `app.is_platform_admin()` on
`org_mailboxes`, `org_modules` and `org_subdomains`, where seeing across
companies is the point.

So it was asked by reading rows instead, as `authenticated`, with the
JWT of somebody who is a member of one company and not the other.
`no_tenant_sees_another.sql` is in CI. No leak: nothing of the other
company is visible in any of the 16 tables it actually has rows in —
including `gl_entries`, `gl_lines`, `sales_documents`, `employees`,
`org_members` and 232 rows of `audit_logs`.

### The two things that stop it going vacuous

"No rows of the other company are visible" is also true of an empty
table, and a sweep over 250 empty tables would pass forever. `0395`
shipped an assertion with that fault and it survived its own mutant. So
the tables are counted twice — as the owner, to find which ones the
other company has rows in, and then as the member — only that set is
asserted, its size is reported, and a floor under it fails the file if
the fixture stops populating. Removing the fixture's inserts drops it to
6 and the floor fires.

And the company doing the looking deliberately owns almost nothing, with
a positive control that it can see its own chart of accounts. Every
count would also be zero if the member could see nothing at all —
commenting out the `set local role authenticated` makes the file fail on
`current_user`, not pass silently.

### The mutant that survived, and why that is the finding

Making `audit_logs`' select policy `using (true)` fails the file at once
— "audit_logs (232 of 232)". Making `contacts`' select policy
`using (true)` does nothing, because `contacts` carries a second policy:
`module_gate_select` is *restrictive* and scopes by
`app.can_read_module(org_id, 'contacts')`, and restrictive policies AND.

That is not a weakness of the sweep; it is the thing the sweep exists to
see. A module-gated table is scoped twice. `audit_logs` is scoped once,
and one is all it takes for a single wrong policy to hand a competitor
the lot.

## A fifth sweep, which found nothing and became a guard

The fourth sweep asked whether one company can read another's rows
*through* RLS. This one asks the other side: **an edge function holding
`SUPABASE_SERVICE_ROLE_KEY` is outside RLS entirely.** Every policy in
this schema, every `app.can_*` guard and the whole of
`no_tenant_sees_another.sql` are downstream of a client the function
builds for itself, and a function that builds only the service-role one
and then trusts `body.org_id` writes wherever the body says.

Seven of the ten functions hold the service role. All seven are correct,
by four different routes — which is exactly why a checker written
against one of them would have failed the other three:

- **`_shared/context.ts`** — `myinvois`. Reads `body.org_id`, requires
  it, and validates membership through the caller's own client.
- **An inline caller-scoped client calling a guarded function** — `ocr`
  builds a client from the anon key and the request's own
  `Authorization` header and calls `ocr_begin` through it;
  `ocr_begin` is SECURITY DEFINER and opens with
  `if not app.can_write(p_org_id)`. A forged `org_id` is refused there,
  before the service-role client is built.
- **A caller-scoped read whose RLS decides the work set** —
  `send-email` reads `email_outbox` through the caller's client, so
  `app.is_org_member(org_id)` decides what may be sent;
  `billplz-checkout` reads `platform_invoices` the same way, with its
  own comment saying "a forged invoice id belonging to another company
  returns nothing rather than its amount"; `send-push` resolves the
  sender the same way.
- **No user caller at all** — `billplz-callback` and `receive-email` are
  inbound webhooks authenticated by a signature and a shared secret,
  and `fetch-rates` is a scheduled job. Demanding an `Authorization`
  header of any of them would be asking the wrong question.

### Why this one earned a checker and the other four did not

`docs/unreachable.md` already says why three sweeps produced no CI
guard: their false positives were indistinguishable from correct code.
This one is different. The invariant is mechanical — a file that reads
`SUPABASE_SERVICE_ROLE_KEY` either also builds a client from the
request's `Authorization` header, or is on a named list with a written
reason — and it has no false positives today across all ten functions.

`scripts/check_edge_authorization.py` is in CI, next to
`check_embeds.py` and `check_idempotent_calls.py`. Three mutants killed:
removing `send-email`'s anon-key client, adding a brand-new function
that holds only the service key and inserts on `body.org_id`, and
leaving a name in the exemption list that no longer matches a function —
because an exemption nothing uses is one waiting to be inherited by
something else.

The exemption list is the whole of the judgement in the file. Adding a
name to it is saying "this one has no session to check", and that should
be a sentence somebody has to write.

## 0405 — one badly named file closed the whole bucket

Every storage policy reads the organization out of the first segment of
an object's path. Eleven do it with `app.uuid_or_null(...)`, which
returns null for anything that is not a uuid. Four — the three chat
policies from `0138` and the mail one from `0354` — do it with a hard
cast, `(nullif(split_part(name,'/',1), ''))::uuid`. `nullif` handles an
*empty* first segment and nothing else, and **a policy predicate that
raises does not deny a row, it fails the statement**.

Measured, as a member listing their own company's files: one attachment
visible; then one row named `inbox/...` inserted the way a service-role
writer would leave it; then the same query by the same member came back
`22P02 invalid input syntax for type uuid: "inbox"`. Not a leak —
nobody sees anything they should not. One badly named object makes the
bucket unreadable for **every** user of it, because the policy is
evaluated per row and one row that raises aborts the statement. Their
own attachments, behind an error naming a path they have never heard of.

### Reachable only with a second bug, which is why it is a blast radius

Nothing writes such a path today: `mail_files.ts` builds
`${orgId}/${emailId}/${index}-${name}` from an org id it looked up, and
a client cannot insert a bad row through the front door because the
*write* policy carries the same cast and raises before the row lands.

The reason to close it anyway is who the writers are. They are edge
functions holding the service role, outside RLS entirely — and the
sweep recorded above found seven of them. One wrong path from any one,
today or in a later change, takes out a whole bucket for every company
on the platform rather than failing on its own row. That is a lot of
consequence resting on a string being well-formed when the schema
already has the function that makes it not matter, and uses it
everywhere else.

### Only ever narrows

`app.uuid_or_null` returns null for a non-uuid, and all three helpers
refuse a null — measured, not assumed: `is_chat_participant(null)`,
`has_module(null, 'mailbox')` and `is_org_member(null)` are all false.
So a badly named row becomes invisible instead of fatal, and every path
that is a uuid evaluates exactly as before.

Three mutants killed by `bucket_survives_a_bad_path.sql`: restoring the
cast on the mail policy, restoring it on the chat policy, and — the one
that matters — dropping the org scoping from the mail policy altogether,
which makes the member see the foreign row and proves the fix narrowed
rather than widened.

Both the migration and the test ask the catalogue for any policy whose
expression still contains `::uuid`, rather than naming the four, so a
fifth written next year fails.

## 0406 — three document numbers nothing kept unique

`app.next_document_number_internal` takes a row lock —
`select ... for update` — and holds it for the rest of the transaction,
so two callers asking at the same moment serialise and cannot be handed
the same number. The function is right. This is not about the function.

It is about what happens when something writes one of these columns
without going through it, and `contact_numbering.sql` already says that
is not hypothetical: *"the CSV importer writes whatever the file said …
it is what a live organization did the first time a supplier was created
from a scanned bill."* What saved `contacts` was
`contacts_org_id_code_key`. The duplicate was refused loudly by a
constraint, and `0116` was written to re-sync the counter. On a table
with no such index the same importer, the same seed, the same scanned
bill writes the duplicate and says nothing.

Asked of the catalogue: of the numbers this application issues, twenty
are covered by a unique index over `(org_id, …)` and three were not —
`stock_movements.movement_no`, `rent_runs.run_no` and
`strata_charge_runs.run_no`, all `text not null`, all generated.

Counted on the hosted project before writing the migration, because a
unique index that cannot be built is a deployment that breaks: 44 stock
movements, 149 ledger entries, 24 receipts, 0 duplicates anywhere. So
nothing was repaired. What changed is where the guarantee lives.

### Most `_no` columns should not be unique, which is why this is a list

The sweep's first output was mostly noise, and it is worth recording so
nobody re-runs it:

- **Somebody else's numbers** — `registration_no`, `passport_no`,
  `licence_no`, `bank_account_no`, `supplier_doc_no`. Two suppliers may
  both send an invoice numbered `INV-1`, and a unique index there would
  refuse the second one.
- **Line numbers** — unique within a parent, and constrained there.
- **`pos_sales.order_no`** — the number called across the room, which
  restarts daily per outlet exactly as `0220` intended: "short enough to
  read across a room, which is the whole job it has". An index there
  would be wrong, not missing. `app.next_kiosk_order_no` is a single
  upsert taking the row lock, and `0220`'s comment explains why it is
  one statement rather than a read then a write.

So the rule is not "every `_no` is unique". It is a named list of the
numbers this application *issues*, asserted in `contact_numbering.sql`
rather than only in the migration, because a migration records what was
true when it ran and an index dropped by `0450` should fail something.

Three mutants killed: dropping the new `stock_movements` index, dropping
the pre-existing `gl_entries` constraint, and — the one that keeps the
list honest — adding a unique index to `pos_sales.order_no`, which fails
the assertion that the numbers which must repeat still can.

## 0407 — four functions a stranger could start

`0095` found this exact shape, fixed two instances, and recorded what
caught them: *"`supabase/tests/statutory.sql` asserts that no SECURITY
DEFINER function outside a three-name allowlist is executable by `anon`.
It caught both of these, which is the entire reason it exists."*

That assertion names `anon`, and only `anon`. Nobody had asked the same
question of `authenticated` — the role anybody gets by signing up.

Measured under `set local role authenticated`, as a member of one
company with `app.is_org_member(theirs)` false:

    app.roll_leave_year(<the other company>, 2026)   -- accepted
    app.run_recurring_journals(current_date)         -- accepted,
        for every tenant on the platform, on a date the caller chose

Asked of the catalogue rather than of those two: four SECURITY DEFINER
functions in `app` write and were executable by a client role, and not
one carried a guard — those two plus `seed_chart_of_accounts` and
`seed_org_modules`. The last is the one to look at twice: `0127` and
`0129` built module entitlements to decide what a company has paid for,
and that function writes the table for whatever organization id it is
handed.

### Excess privilege, not an open door

Said plainly, because `0399` had to correct itself on exactly this
point. PostgREST publishes `public` and does not publish `app`, and no
`public` wrapper names any of the four — checked against the catalogue.
A caller speaking to the API cannot reach them.

What is left is `0240`'s argument: "anything holding a connection string
gets the privilege, not the API's opinion of it." And the grant was not
a leftover default — the ACL read `authenticated=X/postgres`, which is
somebody having written the grant.

### The rule takes no view on guards, on purpose

An earlier draft asked "does it carry a guard", which means matching the
*names* of guards — and a sweep written as a list of guard names
measures the list, not the code, which is the fault `0395` shipped. So
the rule is mechanical: a function in `app` that writes and runs as its
definer is not something a client role executes, guarded or not. The
exemption list is empty and is the whole of the judgement.

`app_writers_are_not_a_client_surface.sql` is in CI. It asserts the four
refusals behaviourally, keeps two positive controls (a client role must
still call the RLS predicates, or every policy in the schema stops
working; and the scheduler and org creation must still reach all four,
which they do because a definer function calling another runs as the
definer), and asks the catalogue the general question with a floor under
it — 92 definer writers exist, so "none is open" is not true by there
being none.

Four mutants killed: each of three functions granted back to
`authenticated`, and a fourth writer with no behavioural probe granted
back, which the catalogue rule catches on its own.

## 0408 — the relief ceiling that was only a helper text

Two defects in the same screen, found by asking a question nobody had
asked the client before: does every column name it sends exist?

### The screen that had never once worked

`reliefTypes` filled the dropdown of reliefs an employee may declare on
a TP1. It asked PostgREST for

    statutory_schedules?schedule_type=eq.pcb

and there is no `schedule_type` column — a schedule's body is `body`, an
`app.statutory_body` enum. PostgREST answers 42703 and refuses the whole
request. The provider read it as `valueOrNull ?? const []`, so the
failure became an empty list without a word, and

    onPressed: types.isEmpty ? null : () => _edit(...)

left the Add button greyed out. Not a broken screen — a screen that
looked finished and did nothing, for the whole life of the feature.

The corroboration is in the data: `employee_tax_reliefs` holds not one
row on the hosted project, in any organization. That is what a feature
nobody could ever use looks like from the database.

Tapping an existing relief was worse than disabled. The dialog builds
its dropdown from the same empty list and hands `DropdownButtonFormField`
a non-null value with no matching item, which Flutter asserts on. There
was no data to reach it with, so it had never been reached.

`reliefTypes` is `public.declarable_reliefs(p_tax_year)` now — an RPC
rather than a query, because the client had also been picking the
schedule itself with a second copy of the rule that left out
`effective_to`, and the ceiling below is enforced against a schedule
chosen by a third. One rule, in one place, so the list offered is the
list allowed. The screen also says why the button is off when it is off:
loading, nothing published for the year, or the list failed — three
states that used to look identical from the outside.

### And the ceiling nothing enforced

`calc_pcb` subtracts every row of `employee_tax_reliefs` from projected
income without looking at the code:

    select coalesce(sum(etr.amount), 0) into v_manual
      from public.employee_tax_reliefs etr
     where etr.employee_id = p_employee_id and etr.tax_year = v_year;

So the amount is the whole of the arithmetic. `tax_reliefs.max_amount`
carries LHDN's ceiling — RM3,000 on life insurance, RM2,500 on
lifestyle, RM8,000 on medical expenses for parents, RM7,000 on education
fees — and was read in exactly one place: a helper line under the amount
box reading "LHDN allows up to RM3,000.00". `employee_tax_reliefs`
carried no check at all: not the ceiling, not a floor of zero, and not
that `relief_code` names a relief that exists.

PCB is money the employer withholds and remits. Under-withholding is the
employer's exposure.

`app.check_declared_relief()` now refuses four things, and the third is
the one that is not about a typed figure at all:

  * a negative amount, which would raise the tax rather than lower it;
  * a code the year's PCB schedule does not have;
  * a code the schedule marks `is_automatic` or something other than
    `applies_to = 'manual'`. `calc_pcb` already works the individual
    allowance, EPF, SOCSO and EIS, the spouse and the children out of
    the record the company holds, and then adds this table on top. A row
    saying `individual` claims RM9,000 that has already been given, and
    neither half can see the other;
  * an amount above `max_amount` where one is set.

The schedule it judges by is the one in force on 31 December of the tax
year — the same one `calc_pcb` reaches for on that year's last pay date.
A year with no published PCB table stands aside, which is `0404`'s
answer to the same question and is asserted so it stays a decision.

`declared_reliefs.sql` is in CI: 22 assertions, seven mutants killed,
each by its own assertion. Two of them are the point rather than the
refusals — every code the screen offers is one the trigger accepts, and
a relief declared inside its ceiling still moves the tax (RM3,512.50 to
RM3,460.40 on RM20,000 a month, with RM2,500 of lifestyle declared).

### The guard

`scripts/check_query_columns.py` reads every column the schema has, then
every `.from('table')` chain in the app, and refuses any column name
that table does not carry: in a `.select()` list, as the first argument
of a filter or ordering, as a key of an `.insert()`, `.update()` or
`.upsert()` map, and as an upsert's `onConflict`, which has to name a
unique index's columns exactly or Postgres answers 42P10. 986
references, and after this fix every one of them is real.

It reads both halves of the application. The Flutter client is the one
that broke; the edge functions ask PostgREST the same questions in the
same string literals, hold the service role while doing it, and are
further from anybody noticing — a MyInvois submission or an inbound
email that stops working fails on a schedule rather than in front of a
user. They differ only in which quote a string literal takes, so the
readers are built per quote rather than written twice, and each source
carries its own floor: the client is large enough to hide the edge
functions falling out of the count entirely. 171 of the 1,157 references
are theirs, and every one resolves.

While that was written the edge functions' `.rpc()` calls were swept by
hand as well — every name resolves in `public`, and every argument
object is a subset of a real signature. Left as a measurement rather
than built into a script whose charter is columns; a mutated parameter
name was reported by the probe, so the finding is that there is nothing
to find rather than that nothing was looked for.

The three that are not the read path were a sweep of their own and found
nothing — 297 written keys and every `onConflict` resolving to a real
unique index. They are in the guard anyway, because the reason to have
it is the next rename rather than this one. Both were checked by
mutation rather than assumed: a bogus key and an `onConflict` short of
one column are each reported. The first draft of the key reader also
reported a `voice` column on `chat_messages`, reading its own ternary
branch in `'kind': voice ? 'voice' : 'file'` as a second key; a key is
now only a literal that follows the opening brace or a comma.

It is `check_embeds.py` one level down and for the same reason that file
gives: the name is inside a string literal, so the analyzer cannot see
it, the widget tests have no database, and the SQL assertions do not
know what the client asks for. Written first with a lookbehind to keep
`client.storage.from('logos')` out, which missed every one of them —
those chains are formatted with `.from(` on the line after `storage`, so
what precedes the dot is a newline and eight spaces.

## 0409 — the one figure on the payslip that skips calc_statutory

`payslips.schedules_verified` is what the banner on the payslip screen
and the line on the PDF are drawn from: whether every statutory table
this payslip's figures came from has been checked against what the body
published. `calculate_payroll_run` built it from four:

    v_verified := coalesce(v_epf_ver, true) and coalesce(v_soc_ver, true)
              and coalesce(v_eis_ver, true) and coalesce(v_pcb_ver, true);

There are five. The HRD Corp levy takes its rate straight off
`statutory_rates`, joining the schedule and not reading
`s.is_verified` — the one statutory figure that does not come through
`app.calc_statutory`, and so the one whose verification had no way in.

**Latent rather than live, and worth saying so.** Every schedule on this
project is `is_verified = false`, the levy's included, so every payslip
touching any of the four is already unverified and the levy's silence
changes nothing today. What it costs is the moment somebody does the
right thing: the four are checked against the KWSP and PERKESO schedules
and the LHDN tables, HRD Corp publishes separately and is the obvious
one to be verified last, and in that window a payslip says its figures
came from verified tables while the levy on it came from one nobody has
checked.

The second half is `0404`'s shape exactly. A company with
`payroll_settings.hrdf_category` set and no HRDF schedule in force for
the pay date gets `select ... into` finding nothing, `v_hrdf_rate` null,
and a levy of **zero** — silently, on a company that has told the system
it is liable. The zero stands: an absent schedule means there is no
arithmetic to be wrong about, which is what `0404` settled and `0408`
followed. What changes is that the payslip stops calling it verified.

The levy's verification counts only where the levy was consulted — the
employee is `hrdf_eligible` and the company has set a category — on the
same terms as the other four, each of which leaves its own flag `true`
when its calculation does not run.

Six assertions appended to `hrdf_levy.sql`, which is already in CI. The
fixture verifies the four deliberately, because with nothing verified
the question cannot be asked at all. Four mutants killed:

  * reading the rate without `is_verified` — the defect itself — fails
    "so the payslip does not claim its figures came from verified
    tables";
  * dropping the eligibility gate fails "keeps the verification the four
    bodies earned";
  * never folding the flag in is refused by the migration's own
    assertion, before any test runs;
  * treating a missing table as verified fails "says so rather than
    calling the zero verified".

A fifth mutant found dead code in the fix rather than in the schema. The
first draft wrote `if not found then v_hrdf_ver := false` after the
lookup, and removing it changed nothing: `select into` already leaves
the target null and the `coalesce(v_hrdf_ver, false)` below already says
it. A branch no mutation can kill is a branch that is not doing
anything, so it is gone and the reason is in the comment that replaced
it.

## 0410 and 0411 — ten per cent for the table, and eight on top of that

Not a defect found by sweeping. A gap the register named and nobody had
gone back to: "compound tax is still absent, `is_compound` appears
nowhere in the migrations, the client or the edge functions". Both
halves of that sentence were true, and the second half is why the first
one stayed open — `is_compound` is the wrong thing to look for in
Malaysia.

There is exactly one place a Malaysian bill compounds, and every
restaurant in the country prints it:

    Subtotal              100.00
    Service charge 10%     10.00
    Service tax 8%          8.80
    Total                 118.80

The 8.80 is on 110.00, not on 100.00. And this schema had no service
charge at all — not on `pos_outlets`, not on `pos_sales`, not on
`sales_documents`, grepped across every migration rather than
remembered. A restaurant using this point of sale could not produce a
correct bill, and the whole food and beverage module — the floor plan,
the modifiers, the split bills, the kitchen display, the counters — was
built on a total that was ten per cent plus the tax on it short.

### Where the compound comes from without taxing anything twice

Tax here is per line and summed, so the lines already carry service tax
on the food. Taxing the charge at the same rate gives

    rate x food + rate x charge = rate x (food + charge)

which is the figure the Act asks for, reached with no second tax pass.
`pos_service_charge.sql` asserts that identity as arithmetic rather than
as the number 8.80, so a rate change keeps the assertion honest.

### The decisions, said out loud

The percentage is on the **outlet**, not the organization: a takeaway
counter and a dining room in the same company charge differently, and
the test has one of each. The tax code is **named** rather than
inherited from the food, because an outlet that is not registered for
service tax adds a charge with nothing on top — null means exactly that,
and there is an assertion whose whole job is stopping the null being
read as "use whatever the food used". The charge posts to **4250**, new
in `0410` beside `4200 Service Income`, not into `4100`: it is what the
service staff are paid out of, and a restaurant that cannot see it apart
from food sales cannot tell what it took at the table from what it took
for the table. `0013` set that precedent by giving the courier charge
`4900`.

The receipt prints it **above the tax line, with the percentage on it**,
and deliberately not behind `show_tax_summary`: a shop may choose not to
print a tax breakdown, and it may not choose to add ten per cent to a
bill without saying so.

### What the existing guards did

`0402`'s frozen deny-list refused the new column before any of this
worked — `posted_document_is_frozen.sql` walks both document tables and
demands every column be either frozen or explicitly named as writable,
and `service_charge_amount` was neither. That is the guard working, and
it is why the column could not be added quietly.

`0411`'s own closing assertion caught the setter having been left
**unreachable**: `0165`'s event trigger strips PUBLIC and anon from
every new function, and nothing had granted it to `authenticated`. A
function nobody can call is the exact shape this document is about, and
it was caught inside the migration that created it rather than by a
screen failing later.

### Mutants

Eight, and one of them changed the code rather than confirming it.

  * the charge left untaxed — the compound lost — fails "eighty sen
    rides the service charge";
  * the charge missing from the sale total fails the 118.80;
  * posting it to `4100` instead of `4250` fails the ledger assertion;
  * a fixed ten per cent for every outlet fails "a takeaway carries no
    service charge";
  * the receipt block removed fails "the receipt names the service
    charge";
  * another company's tax code accepted fails the cross-tenant probe.

The charge dropped from the invoice was killed by the ledger's own
balance constraint before the assertion about it ran — a real kill, and
a weaker one than it looks, so it is recorded as what it was rather than
as the assertion earning its place.

And the percentage bound **survived**, because the column carries a
check constraint that refuses 150 as well; a test that asked only "was
it refused" could not tell the two apart. What the function's guard adds
is a sentence a person can act on, so the assertion now reads the
message. Under the mutant it fails with the constraint's own text —
`violates check constraint "pos_outlets_service_charge_percent_check"` —
which is the failure explaining itself.

## 0412 — a tenant's own gateway credentials, and a deliberate exception

`payment_gateways` carries forty-odd Malaysian and regional acquirers,
`billplz-checkout` and `billplz-callback` are deployed, and
`gateway_payments.sql` asserts the money. All of it settles
**`platform_invoices`** — iAkauntan billing its own subscribers. The
table's primary key is `code` alone; there is no `org_id` on it and
there was never meant to be.

`docs/gaps-against-akaunting.md` names the three things a tenant
collecting from its own customer still needs: per-organization
credentials, a pay route on the shared invoice link, and a receipt
posted when the callback confirms. `0412` is the first, and it is the
one that has to be right before the other two are worth writing,
because it is where a tenant's acquirer secret lives.

It is `0107`'s shape, deliberately and down to the detail. RLS enabled
with **no policies at all**, every privilege revoked from `anon` and
`authenticated`, writes through a SECURITY DEFINER function guarded by
`app.can_admin`, and a status function that answers "is one set"
without ever handing the secret back. Two barriers, so a migration that
disabled RLS, a restore that dropped it, or a toggle in a dashboard
would not on its own make an acquirer key readable by anyone holding
the publishable key that ships in the web bundle.

`(org_id, gateway_code, mode)` is the key, because `0107` learned that
an environment stored as a column on a row an organization only has one
of makes "prove it in sandbox, then go live" a one-way door. And the
null-secret merge happens **before** the insert rather than in the `on
conflict` arm, because `api_key` is NOT NULL and Postgres validates the
proposed row before it looks for a conflict — the obvious
`coalesce(excluded.api_key, ...)` never runs. `0107`'s test caught that
on its first run; this one asserts it directly.

`tenant_gateway_credentials.sql` is in CI: 35 assertions, five mutants
killed. Two of them die on the migration's own assertions rather than
in the test — leaving the client grants in place, and the status
function returning the key under the collection's innocent-looking
name — which is the right place for a barrier to be asserted, beside
where it is set. The test's own version of the second is behavioural
and stronger than a column-name check: it takes the whole returned row
as JSON and refuses to find the stored key anywhere in it.

### The exception, and why it is one

**Nothing charges anybody yet.** There is no checkout call and no
callback for a tenant's invoice, so this table has no screen and is
reachable only by the two functions above. That is a column nothing can
set from the outside, which is the shape this whole document is about,
and it is deliberate: a settings screen inviting a shop to paste its
live Billplz key into a system that will never call Billplz would be a
worse outcome than an empty table. The migration says so in its own
header rather than leaving a reader to work it out.

The next slice is the one that makes it reachable — a pay route on the
shared invoice link and a receipt posted when the callback confirms —
and the screen belongs with that, not before it.

## 0413 — the customer can pay the invoice they were sent

`0412`'s exception, closed one step: the database can now take a
payment. What it still cannot do is call an acquirer, and that is said
here as plainly as `0412` said its own.

The shape is `platform_payments`', because that one has been settling
iAkauntan's own subscription invoices and got it right: one row per
`(gateway_code, provider_ref)` so a retry finds the payment it already
settled; five named outcomes rather than a boolean that cannot tell a
forged reference from a short payment; `unknown` returned quietly,
because an answer that distinguishes a wrong guess from a right one is
an oracle for guessing references; and a short payment **recorded and
refused**, never rounded up into a settled invoice.

What a tenant's payment has that the platform's does not is a ledger
behind it. A confirmed payment posts a receipt through
`app.post_receipt_internal`, allocated against the invoice, so the money
comes off the receivable and lands in the nominated bank account by the
same door a receipt keyed in by hand uses. The migration asserts that
nothing in it writes `gl_entries` directly — `0399` closed that door and
this did not reopen it.

Three decisions worth having in writing:

  * **The amount comes from the document.** `begin_shared_payment` takes
    no amount, and the migration asserts its signature has none. A
    checkout for a figure the caller chose is how an invoice gets
    settled for a ringgit.
  * **A gateway with nowhere to bank is not offered.** A button that
    leads to a failure is worse than a button that is not there, and the
    moment a customer has already paid is the wrong time to discover the
    receipt cannot post.
  * **Never more than is owed.** Two people paying the same link, or a
    bank transfer that landed while the acquirer was still thinking,
    must not leave the invoice in credit through this door. The test has
    that case: the payment is recorded as paid and takes no receipt of
    its own.

### Two things the test caught that would have shipped

**Recreating `open_shared_document` took the share link away from every
customer holding one.** `0165`'s event trigger strips PUBLIC and `anon`
from a function as it is created, so a `create or replace` of a function
`anon` executes silently revokes it. The test noticed because its last
section runs under `set local role anon` — the role a customer actually
has — rather than as the owner. There is now a re-grant, placed after
the recreation, and an assertion beside it.

**The service charge was missing from the shared invoice.** `0410` added
`service_charge_amount` and `0411` prints it on a receipt; the shared
document still listed subtotal, tax, shipping and rounding, so a
customer reading their own invoice found figures that did not add up to
its total. `check_query_columns.py` cannot see this one — it is a column
missing from a SQL function, not a name the client got wrong.

### And a third the existing guards caught

`statutory.sql` keeps an allowlist of the SECURITY DEFINER functions
`anon` may execute, and says of itself that "adding a name here should
feel like a decision". Granting `shared_payment_options` to `anon` made
the whole suite red until the name was added with a written reason for
it — which is the allowlist working exactly as its own comment
describes. It is ten functions now, not nine, and the entry says what
the stranger needs, what the function reaches, and that its two
siblings are deliberately not beside it.

### Mutants

Eight, all killed. The short-payment branch, the retry guard, the cap at
what is owed, the stripped signature, the unbanked gateway still being
offered, the quiet `unknown`, and — on the migration's own assertions —
the missing grant on the share link.

The eighth is the one worth recording. **The cross-tenant probe survived
its first mutant**, because it was written as "take whatever
`where org_id <> v_org` finds, and skip if that is nothing" — and in a
fixture with one company in it, that is nothing. It passed by not
running. The other company and its bank account are created in the
fixture now, and the same mutant dies. A probe that measures whether it
had anything to probe is not a probe, which is the same fault `0395`
shipped in a different shape.

## 0414 and the two edge functions — the acquirer, and the shop's own key

`0412` and `0413` both said in their own headers that nothing charged
anybody. This is the part that does, and the part that makes the two
before it reachable: `pay-invoice` creates the bill at the tenant's own
acquirer, `pay-invoice-callback` verifies the confirmation, a Pay button
appears on the shared invoice link, and a settings card lets a shop
enter its credentials and nominate where the takings land.

### The key a callback is verified against is the shop's

`billplz-callback` verifies against `BILLPLZ_XSIGNATURE_KEY`, one Edge
Function secret, because the platform has one Billplz account. A
tenant's bills do not work that way: every organization has its own
account and its own X Signature key, so the key depends on *which*
confirmation this is — and the only thing identifying that before
verification is the reference in an unverified body.

`app.shared_payment_signature_key` looks it up, and the reasoning is
written down because it looks worse than it is. **Finding a row decides
nothing.** The reference selects which key to check against; the
signature is still the credential and is still checked before a single
field is believed. A caller who guesses a reference gets exactly as far
as one who does not.

What they must not learn is which of the two happened, so a reference
nobody has heard of, a shop with no key configured, and a signature that
did not verify are **answered identically** — 401, with which one it was
in the log. Answering them differently makes the endpoint an oracle for
guessing references, which is the same reason `settle_shared_payment`
returns `unknown` quietly rather than raising.

### Two functions with no session, and what stands in for one

`scripts/check_edge_authorization.py` refuses any function that holds
the service role without building a client from the caller's own
Authorization header, unless it is in `NO_CALLER` with a written reason.
Both new ones are, and the reasons are the point:

  * `pay-invoice-callback` — an acquirer's servers hold no session with
    us. A confirmation that could only arrive with a JWT would never
    arrive.
  * `pay-invoice` — the payer is a customer, not a user. They have no
    account and never will; that is what `open_shared_document` is for.
    The share token is the credential and it is checked in SQL by
    `app.shared_payment_intent`, not in TypeScript.

### What the screen will not do

It never displays a key. `org_payment_gateway_status` answers
`has_api_key` and `has_signature_key`, and the card shows "Key stored"
— a screen that could redisplay a secret is a screen that could leak
one, and there is no reason to read one back. An empty key box on save
means "leave the stored one alone", which is what makes correcting a
collection id safe rather than destructive.

### And the honest limit

**Nothing here has been run against an acquirer.** There is no Billplz
sandbox in this environment, so what is verified is everything either
side of the HTTP: the token check, the intent, the pending row, the
signature verification (whose assertions live in
`_shared/billplz_test.ts` and run in CI), the five settlement outcomes,
the receipt and the ledger. The call itself is
`createBillplzBill` — the same helper `billplz-checkout` has been using
against real bills — with the tenant's key rather than the platform's.

That is a real difference from "payments work", and it is written here
rather than left to be assumed from a green CI run.

## 0415 — LHDN was told 113 for a bill of 123

The first defect in this document that was introduced by this document.
`0410` is four migrations old and it is mine.

`prepare_einvoice` copies six figures onto the MyInvois header, and they
are not independent:

    excl_tax - discount + charges + tax + rounding = payable

`app.recalc_sales_totals` maintains that identity on the document. The
mapping has to preserve it, and `total_charges` was `shipping_amount`
alone. `0410` added a second charge — the service charge a Malaysian
bill carries — put it in the total and into the ledger, and did not put
it in `total_charges`.

Measured on a RM100 restaurant bill with RM5 delivery and a RM10 service
charge at eight per cent:

    doc:    sub 100.00  tax 8.00  ship 5.00  svc 10.00  total 123.00
    e-inv:  excl 100.00  charges 5.00  tax 8.00  payable 123.00
    told:   113.00        billed: 123.00

Ten ringgit in a hundred, on every bill a restaurant sends. MyInvois
validates the arithmetic on what it is given, so the near outcome is a
rejected submission and the worse one is an accepted document that
understates the charge.

### Why nothing caught it

Nothing had ever asserted the six reconcile. `total_charges`,
`total_excl_tax` and `payable_amount` appeared in **no test in this
repository** — grepped, not recalled. The mapping had been trusted since
it was written, so the day a seventh column joined the total there was
nothing to notice.

`einvoice_totals_reconcile.sql` is that assertion, written as the
identity rather than as six expected numbers, so the next charge added
to a document fails it too. It also asserts each column separately,
because the identity alone is satisfied by putting the service charge in
the tax column — a document that balances while misreporting the tax.

### What this cost, said properly

One column not looked for in the four places a document's money is
copied to. Two of the four were caught by tests written in the same
session — the shared invoice link in `0413`, and this — and the other
two (`recalc_sales_totals`, `post_sales_document_internal`) were part of
`0410` itself. A change that adds a column to a money table is a change
that has to be followed everywhere the row is *read*, and `0410`'s own
header did not say so.

### Mutants

Seven, and the split matters. Three died on the migration's own source
assertion before the test ran — which sounds good and is not, because it
means the assertion was doing all the work. So three more were built to
survive that check and exercise the test: the charge kept in the
expression and multiplied out (fails the reconciliation with exactly the
original `-10.00`), the discount dropped from the header (fails it at
`+7.50`, a column the test was not written for and catches anyway), and
the charge moved into the tax column so the identity still holds — which
fails "the charges are the delivery and the service charge" and is the
reason those three per-column assertions are there at all.

A seventh was a duplicate of the fourth, written by mistake and counted
here as one rather than two.

---

## The monthly bill that billed less than the document it was made from

The same column, one place further on, and this one is worse because it
recurs.

`app.snapshot_document` freezes a document into the template
`app.raise_recurring_document` replays every month. Its two halves do
the same job in opposite directions, and the lines half says why:

> Everything on the line except what belongs to the document it came
> off. **Listing what to keep instead would quietly drop any column
> added after today.**

That comment is on the lines. The header lists what to keep — the thing
the comment warns against — and it had already dropped three columns.

### Measured

A property manager sets up one monthly bill: RM300 maintenance, RM12
delivery, a RM45 service charge, on the Kuala Lumpur branch.

```
template  ship 12.00  service charge 45.00  branch set   total 381.00
raised    ship 12.00  service charge  0.00  branch null  total 336.00
```

RM45 short, every month, on every parcel, and the invoice lands outside
its branch. A monthly service charge billed to every owner is not an
edge case here — it is the entire business of a strata management
company, and one of the seeded demo tenants is one.

### The three, and when each was lost

| column | added by | relative to `0097` |
|---|---|---|
| `service_charge_amount` | `0410` | 313 migrations after |
| `branch_id` | `0131` | 34 after, and missing on the buying side too |
| `matter_id` | `0021` | before — never carried rather than dropped |

`matter_id` is the one that does not change the money. A firm's monthly
retainer raised without its matter bills the right amount into the wrong
ledger, so the arithmetic assertion would never have found it. It has an
assertion of its own.

### What is not fixed

Schedules already stored keep the header they were snapshotted with.
`recurring_documents` holds no reference to the document a template came
from — `last_document_id` is the last invoice *raised*, which is itself
missing the columns — so there is nothing to re-derive them from. Saving
the template again picks them up. The replay coalesces a missing key
rather than failing, so those schedules go on billing exactly what they
billed yesterday. That is stated in `0416`'s header too, because a fix
that silently does not reach existing rows is worse than one that says
where it stops.

### What stops the fourth column

`recurring_template_carries_the_document.sql` requires **every** column
of both document tables to be either in the snapshot or in a list
written down in the test as not replayed, with the reason. A column
added to either table and not decided about turns it red, naming the
column and what to do. It checks the other direction as well, so the
list cannot rot into names of columns that no longer exist while
claiming to have decided about them.

The whitelist is kept rather than inverted. A header carries forty-odd
columns and most of them are identity, numbering, computed totals and
lifecycle that must never be replayed; subtracting would be the more
dangerous direction here, and a new *computed* column would then be
wrongly carried. What was missing was never the blacklist. It was
anything at all that noticed.

### Mutants

Seven. Four killed for their own reason: the service charge dropped from
the snapshot (381.00 against 336.00, the production defect exactly),
`branch_id` dropped from the sales replay (the branch assertion),
`matter_id` dropped (the retainer assertion), and the exclusion list
naming a column the table no longer has.

Two more are the ones the file exists for — a new money column added to
`sales_documents`, and another to `purchase_documents` — both caught by
the enumeration, each naming the column it found.

Two weaker kills, reported as what they were. Dropping `branch_id` from
the replay's column list alone died on a Postgres "INSERT has more
expressions than target columns", not on an assertion; it was rebuilt to
drop the value line too, which then failed properly. And renaming a
listed column died in an unrelated trigger before reaching the rot
check, which is why that check was mutated directly instead.

---

## The invoice that charged more than the quotation it came from

`public.transfer_document` turns a quotation into an order, an order
into an invoice, a purchase order into a bill. It copies a whitelist of
header columns, and the whitelist had never had a money column on it.

### Measured

A quotation for RM1000 of goods, RM50 delivery, and RM100 off the whole
job because the customer asked:

```
quoted     sub 1000.00  discount 100.00  delivery 50.00  total 1030.00
invoiced   sub 1000.00  discount   0.00  delivery  0.00  total 1080.00
```

The customer is billed **fifty ringgit more than the price they agreed
to**. Both directions are wrong at once: the discount they negotiated is
gone from the invoice, and the delivery the company was owed went with
it, so the figure is not even wrong in the company's favour
consistently. Quote → invoice is the most ordinary workflow in the
product.

### The rule was already written, one level down

The line loop inside this same function has carried it since it was
written:

> A cash discount is proportional to what is being taken, not carried
> whole onto a partial transfer.

```sql
case when r.quantity = 0 then 0
     else round(r.discount_amount * v_want / r.quantity, 2) end
```

The header amounts were never given the same treatment. `0417` gives
them it. The share is measured on **line value** rather than quantity —
two lines at different prices are not two equal halves of a delivery
charge — and taken against the *source's* total rather than against what
is left of it, which is what makes two half-transfers add back to one
whole. `branch_id` carries whole on both sides: half a bill can go on
one invoice, half a branch cannot.

### The second bug inside the first

Writing the header amounts after the line loop put them on the row and
not in the total. `app.recalc_sales_totals` is a trigger on the *lines*,
so a header amount written after the last line is never folded in — the
first attempt at this fix produced an invoice carrying `shipping 50.00`
and a total that still said 1080.00.

Fixed by touching a line so the one function that owns the arithmetic
runs over the finished header, rather than either alternative: computing
the share before the header insert would mean writing the `v_want`
expression a second time where the two copies can drift apart silently,
and setting `total_amount` by hand would put this function in the
business of arithmetic that belongs elsewhere, on a draft somebody is
still going to edit.

### Not fixed

Documents already transferred keep the figures they have. Rewriting a
posted document's total from a migration is not something this schema
does — `0238` and `0410`'s frozen list both say so.

### Mutants

Five, all killed for their own reason.

| mutant | died as |
|---|---|
| the header amounts not carried (the defect as found) | 1080.00 against 1030.00 |
| carried whole onto a partial transfer | 50.00 against 25.00 |
| the recalculating touch removed | 1080.00 against 1030.00, with the amounts on the row |
| `branch_id` dropped again | the branch assertion |
| zero-subtotal source answers "none" instead of "all" | the free sample billed 0.00 delivery |

The second is the one worth having. It is the plausible implementation —
copy the amounts across — and it is exactly what the line-level comment
warns against, one level up.

---

## The eighty sen a restaurant charged and never declared

The most serious of the run, because the wrong figure goes to Royal
Malaysian Customs.

`0410` gave a Malaysian bill its service charge and taxed it. The tax is
charged, it is printed, and `post_sales_document` puts it into output
tax at 2130 with everything else. `report_sst_summary` — which *is* the
SST-02 return — sums `tax_amount` off the document **lines**, and the
charge is not a line. It is a percentage of all of them, so its tax was
on the header.

### Measured

The worked example from `pos_service_charge.sql`: RM100 of food, ten per
cent for the table, eight per cent service tax on the hundred and ten.

```
the document says output tax   8.80
the SST-02 return says         8.00
under-declared to Customs      0.80
```

Eighty sen in every hundred ringgit — about a twelfth of a restaurant's
whole service tax liability — left off a statutory return every taxable
period, while the company's own ledger carries the right figure. The two
disagreeing is the only reason anybody would ever have found it, and
nothing was comparing them.

### Why it could not simply be added up

The return is filed **by tax type**: one row per code, taxable value and
tax. A figure folded into `tax_amount` with no tax code attached cannot
be put in a column of that return. `sales_documents` recorded the charge
but not what it had been charged under — only
`pos_outlets.service_charge_tax_code_id` knew, two joins away and only
for a sale that came from a till.

So `0418` puts `service_charge_tax` and `service_charge_tax_code_id` on
the document, `complete_pos_sale` writes them, and the return reads the
header. Both join the frozen list: a figure a return declares must not
be editable after posting, or the return stops agreeing with the ledger.

### The assertion is against the ledger, not against 8.80

`sst_return_declares_what_was_charged.sql` asserts that the return's
output tax equals **the credit to 2130 those postings raised**, and
equals the sum of `tax_amount` on the documents in the period. A number
in a test is a number somebody has to remember to change; the tie to the
ledger is what an auditor would check and what was actually broken. It
also asserts the taxable value (320.00 on three dinners, two of them
eaten in) — because the tax identity alone is satisfied by declaring the
right tax against the wrong value, which would say the rate is not eight
per cent.

### Two guards caught this before CI did

Adding the columns turned `posted_document_is_frozen.sql` red — `0402`
requires every column on a document that posts to the ledger to be
classified as frozen or still-moving — and turned
`recurring_template_carries_the_document.sql` red, the guard written
**earlier the same session**, demanding the new columns be carried or
declined in writing. They are declined: they are derived at the till
from the outlet's rate, and a schedule replaying them would assert a tax
nobody charged.

That is the whole point of both files, and it is the first time in this
run that the mechanism caught the column rather than a person
remembering to look.

### Not changed here — and a correction to what `0418` says about it

`0418`'s own header says a service charge typed onto an ordinary sales
document "is still not taxed", and calls that a real gap needing a rate
on the document and a screen to set it on. **That overstates it, and the
migration text cannot be edited once applied, so the correction lives
here.**

The header *field* is only ever set by a till, and that much is true.
But a company that types its invoices has never needed it: the charge
goes on as a line, pointed at 4250, and that is not a second-class
version of the till's answer — measured on the same worked example, it
is the same answer.

```
             typed as a line      rung up on the till
total             118.80                 118.80
tax                 8.80                   8.80
4250 revenue       10.00                  10.00
4100 sales        100.00                 100.00
2130 output tax     8.80                   8.80
SST-02 declares     8.80                   8.80
```

So the difference is that one route asks for an amount and the other
for a percentage. That is a convenience, not a correctness gap, and it
does not justify restating `recalc_sales_totals` — the most load-bearing
function in this schema — to add a second owner of the header total.

The equivalence is now asserted at the foot of `pos_service_charge.sql`
rather than described here, because the claim is the whole reason no
feature was built. If the two routes ever stop agreeing, that file goes
red and this advice is wrong.

### Mutants

Five, all killed.

| mutant | died as |
|---|---|
| the return sums lines only (the defect as found) | 24.00 against the ledger's 25.60 |
| `complete_pos_sale` stops recording the tax code | 24.00 — the join drops the row |
| `complete_pos_sale` stops recording the tax amount | 24.00 |
| the charge declared with no taxable value | 300.00 against 320.00 |
| the two columns off the frozen list | a posted document let its tax be edited |

The first three fail the same assertion for three genuinely different
reasons, which is the right behaviour for an identity against the
ledger: it does not care how the number got wrong.

## The Malaysian clock, in both layers

`vacancies.sql` went red at 02:02 in Kuala Lumpur and green again by
morning. Not a flaky test: `report_open_vacancies` read `current_date`,
which on Supabase is today in UTC — eight hours behind Malaysia. Between
midnight and eight every morning, the database and the country disagree
about what day it is.

### Measured

Sixty-one functions read the session clock: eighteen `STABLE`, and
forty-three `VOLATILE` ones that decide what day a sale happened on,
what day money moved, what day work was done. Four more could not be
found by reading text at all — they cast a `timestamptz` to `date`,
which needs the column's type to see.

`app.today()` is now the only answer, and `app.malaysian_day()` the only
cast. The rule is asserted at apply time and in
`supabase/tests/malaysian_clock.sql`, whose property test compares
`Pacific/Kiritimati` (UTC+14) against `Etc/GMT+12`: never the same date
at any instant, so a session-clock implementation always differs and a
pinned one never does. No "green all morning, red all afternoon".

### One assertion that had to be corrected

The first draft claimed reverting `next_document_number_internal` would
fail an invoice-numbering assertion. Measured: it survives, because two
zones share a `YYYYMM` except near a month end. Both the migration and
the test say so now.

## A sweep from the database's side

The seven sweeps in this file all start from what Dart declares. Running
it the other way — 552 granted `SECURITY DEFINER` functions against
every mention in `app/lib` and `supabase/functions` — found four nobody
names. Two were real: `corp_display_name`, which puts the former name on
a document for the twelve months s.28(4) requires, and `fs_set_entity`.
Two were never findings. Recorded so the direction is not re-run.

## The demo register, and what closing it found

`demo_rebuild.sql` asserted that every module a demo tenant has bought
has something in it. Eleven module-and-tenant pairs were enabled and
empty, and the register was reshaped from module codes to tenant-module
pairs so partial progress could be recorded at all.

Closing it took ten migrations and is finished: the register is now
seven `einvoice` lines, every one deliberate, because
`demo_credentials_locked` withholds LHDN credentials on purpose and a
submission row would be a lie about a connection nobody made.

The seeding is not the interesting part. Three things it turned up are.

**Where an entitlement comes from decides the answer.**
`app.seed_org_modules` turns on `einvoice`, `purchases`, `inventory` and
`crm` for *every* organization in this product — they are what the plan
includes. Turning one off for a demo tenant would show a prospect
something a real sign-up does not get, so those are demos to write.
Modules handed out by `app.demo_modules` in the rebuild *are* a demo
choice and can be turned off — but only after checking that some other
demo tenant still has the module, because the same file asserts every
active module is enabled somewhere. `approvals` came off Amanah and
Harta on that reasoning; `manufacturing` could not come off Sinar for
exactly that reason and was seeded instead.

**A cached balance nobody had reason to doubt.**
`app.demo_sync_bank_balance` summed every bank-mapped ledger account
across a tenant and wrote that one number onto *every* `bank_accounts`
row. Correct while no demo tenant had more than one account — true until
a law firm was given an office account and a client account.

```
what the client account holds is what the ledger says it holds
  expected 3200.00, got -400.00
```

A client account misstated by the seed: the screen a solicitor opens to
answer rule 11's "how much am I holding for this client" would have
shown the firm's own overdrawn office balance.

**A posting guard that was right, and reshaped a demo.**
The branch seed's first draft back-tagged a year of existing documents
and was refused: `branch_id` is one of the figures a journal is built
from, and the ledger is append-only. That refusal is also the truthful
shape, so the seed keeps it — a company that opens a branch in March has
a January that happened at head office.

### A mutant that survived, which is a missing assertion

Sinar's manufacturing seed: dropping the routing step from the bill of
materials passed every assertion written for it. The bench and
`work_centres.cost_per_hour` were dead configuration and the finished
servers would have been carried at components alone. Two assertions were
added and it dies now.

## The service tax on a firm's own hours

`app.bill_time_internal` raises the fee note behind `bill_project_time`
and `bill_matter_time` — what a consultancy, a secretarial practice or a
law firm sends for the hours it recorded. Every line it wrote said
`tax_rate => 0`, with no tax code, for every organization, always.

Group G of the First Schedule to the Service Tax Regulations 2018 makes
legal, accounting, surveying, consultancy, management and information
technology services taxable. A registered firm was billing them and
declaring nothing.

### Measured

```
RM3,330 of engineer time, service tax charged   0.00
after the fix                                 266.40
```

Found only because a demo seed gave an SST-registered tenant a job to
bill and a revenue identity went red — by RM3,330, for a different
reason (the account, not the tax). Until then no registered tenant had
ever billed time, so no assertion anywhere could have said so.

The rate is not guessed. `set_sst_registration` already refuses to be
called without knowing which tax a company registered for, and records
it as the one `tax_codes` row with `is_default`. `app.default_sales_tax`
reads that.

### What the mutants corrected

The header first claimed the date test stopped a pre-registration fee
note carrying tax. It does not — a posting guard from `0145` already
refuses such a document. What became reachable once fee notes carried a
default code was a firm *unable to bill pre-registration work at all*,
because the guard would refuse the invoice. Header and assertion both
say that now.

## The quotation that forgot the tax

The same predicate over every function that inserts a document line:
fourteen write a tax rate unconditionally, six write no tax code at all.
One is provably wrong.

`quote_opportunity` names neither a code nor a rate, and
`transfer_document` — which copies the line's tax code and rate,
correctly — carries the omission into the invoice.

### Measured

```
deal worth        84,000.00
quotation total   84,000.00   tax 0.00
invoice total     84,000.00   tax 0.00
the real price    90,720.00
```

Worse in reach than the fee note: a quotation is the front of the whole
pipeline, so every invoice raised from a quoted deal inherited it.
`0417` was the reverse failure on the same pair of documents — an
invoice that charged *more* than the quotation — and this is the one
that made them agree on the wrong number.

### The five left alone, and why

Named so this is a decision on the record rather than an omission.
`bill_statutory_charge` writes quit rent and assessment at zero: those
are charges levied by a land office and a local authority, not a supply
of services by anybody. `settle_pos_stalls` nets a stall's takings
against the operator's commission into one figure; whether that
commission is a taxable supply, and how it would be presented, is a
modelling decision and not a rate to slot in. `raise_rent_invoices` and
`raise_strata_charges` are scope questions with thresholds and
exclusions attached, and **nothing in this repository records which
reading it follows** — a number there would be a statutory figure nobody
chose. `raise_recurring_document` looked like a sixth and is not: it
copies its template's lines wholesale.

## The terms the customer agreed

The same predicate over dates instead of rates.

A fee note fell due the day it was raised: `coalesce(p_due, p_to)`, with
`payment_term_id` never touched.

```
client on NET30
  doc_date  2026-09-02
  due_date  2026-09-02
  term on the document  null
```

`report_ar_aging` buckets on `coalesce(due_date, doc_date)`, so a client
entitled to thirty days was a month in arrears for a month they were
promised, and the chaser would have gone out.

An intercompany bill fell due on no date at all.
`accept_intercompany_bill` copies the counterparty's invoice faithfully
— doc_date, currency, exchange rate, subtotal, discount, tax, total,
base total, their number and their date — and copied neither `due_date`
nor `payment_term_id`. A null ages from `doc_date`, so the group showed
itself thirty days more overdue than it was, on both sides of the same
transaction.

The machinery existed and neither function used it.
`app.due_date_from_terms` has handled `net`, `eom`, `cod` and `prepaid`
since payment terms went in, and a trigger fills a missing due date from
the document's own term. What was missing is the step before: nothing
put the **contact's** agreed terms onto the document, so the guard had a
null to work from and did nothing, correctly, for a reason nobody could
see.

## The 0410 shape, five times, and then closed

A header column that a copying function was never told about. It has now
paid out five times, and the sweep for it is finished.

| where | what was missed | what it cost |
|---|---|---|
| `0415` | the service charge, on the e-Invoice header | LHDN told 113.00 for a bill of 123.00 |
| `0416` | the service charge, in the recurring snapshot | every monthly bill short by it |
| `0439` | `due_date` on an intercompany bill | thirty days of false arrears, both sides |
| `0440` | the charges on a credit note | a full return that never cleared |
| `0441` | the tax on the charge, in the snapshot | the whole charge off the SST return |

### 0440, measured

```
INVOICE  sub=10000.00 ship=500.00 svc=300.00 tax=800.00 total=11600.00
CREDIT   sub=10000.00 ship=  0.00 svc=  0.00 tax=800.00 total=10800.00
```

Credited in full, every line, nothing left — and the customer still owed
RM800 for delivering and serving goods they had returned. The receivable
never clears, so the invoice sits on the ageing forever and the only way
out is a manual journal somebody has to justify. `0417` had already
settled how much of a header charge follows a partial transfer;
`0440` uses that rule in that form so the two paths cannot drift.

### 0441, and an exemption that was wrong

```
TEMPLATE svc=100.00 svc_tax=8.00 code_set=t
RAISED   svc=100.00 svc_tax=0.00 code_set=f
```

`report_sst_summary` reaches the service charge through an **inner
join** on `service_charge_tax_code_id`, so with no code there is no row
and the whole RM100 leaves the return — the taxable value as well as the
tax.

This one was not an oversight. The test file already had those two
columns on a deliberate do-not-carry list, reasoning that they are
"derived at the till from the outlet's rate" and that "whatever raises
the invoice works them out again". The first half is true. The second is
false, and measuring is how that came out: nothing outside the POS path
computes them. **When a test already exempts the thing you are about to
fix, read the exemption's reasoning and measure it** — and replace the
comment as well as the list, answering the worry it recorded rather than
deleting it.

### Where the sweep stops, with the negative results

- **The purchase half of `app.snapshot_document` is clean.** Every
  column it does not carry is per-instance: the supplier's own number
  and date, the expected date, the approval, the e-Invoice state, the
  attachments, the intercompany link.
- **`transfer_document` is clean**, and has been since `0417` gave it
  the branch, the payment term and the apportioned charges.
- **No screen can put a service charge on a non-POS document.**
  `service_charge_amount` is read in three places in `app/lib` and
  written by exactly one function, `set_pos_service_charge`. So the
  limit `0441` names — that nothing outside POS computes the tax on a
  service charge — is not currently reachable from the product. It is
  worth knowing before anybody adds the field to the invoice editor.
- **Every remaining path that writes a line's tax code copies it from a
  source document**, which is right: a credit note, a transfer, a
  recurring raise and an accepted intercompany bill must all mirror what
  was actually charged, not today's default.

### A method note worth more than any of the findings

Three separate times this run, a mutant was killed by the migration's
own apply-time guard *before any test ran*, because the guard
string-matches the text the mutant edits. That is the guard working. It
is **not** a test kill and must not be counted as one — write a further
mutant that keeps the guarded string and changes behaviour instead.
Twice more, the system caught a mutant harder than the assertion did:
`create_gl_entry` refused an unbalanced journal, and `decide_approval`
refused a role before reaching its self-approval check. Say so; an
assertion credited with a kill it did not make is how a test file starts
drifting from what it covers.

## An eighth sweep, which found nothing, and why the predicate was wrong

Two assertions in this suite were found this session to pass by not
running — `demo_rebuild.sql`'s "no active module is left without a demo
tenant" (satisfied by a flag) and `corp_particulars.sql`'s four s.28(4)
assertions (true the whole time nothing called the function). Both were
found by doubting a specific claim. The obvious next move is to look for
the rest mechanically, so it was tried.

### The predicate, and what it caught

An assertion of the shape `check_eq('no X does Y', (select count(*) …),
0)` is satisfied by an empty table. There are **269** of them, across 90
of the 196 files.

Narrowing to those whose scanned relation the file never inserts into
left **250**. Excluding relations that are set-returning functions
rather than tables — `from public.report_matters_over_agreed_fee(…)`
reads exactly like `from public.some_table` to a regex — and those with
a positive expectation elsewhere in the same file left **35**.

All thirty-five were then read. None is vacuous in the harmful sense.

### Why not

Two reasons, and both are the suite being right rather than lucky.

**This suite populates through functions on purpose.** A file that
asserts about `pos_sales`, `receipts`, `revenue_schedule_periods` or
`leave_requests` does not insert into them; it calls
`complete_pos_sale`, `post_receipt`, `recognise_revenue`,
`apply_for_leave`. That is the project's own discipline — write through
the function that owns the rule — so "the file never inserts into the
table it asserts over" is the *normal* case here, not a smell.
`revenue_recognition.sql` reads `revenue_schedule_periods` in six
assertions and inserts into it never.

**"This table should be empty" is a legitimate claim, and a common
one.** A haircut leaves no stock movement behind. A preview raises no
charge run and no invoice. A deleted report is gone. The product ships
with nobody else's logo on the landing page. In every one of those the
emptiness *is* the assertion, and a control demanding rows would be
asserting the opposite of what the file means.

### What that leaves

The failure mode is real — it has bitten twice — but it is not a shape a
regex can see. What distinguishes a vacuous assertion from a correct
negative one is whether the population the claim is *about* exists, and
that is a fact about the fixture's intent, not its text. The two that
were caught were caught by reading a sentence and disbelieving it.

So this predicate is recorded as tried and unproductive, and the number
is here so nobody re-derives it: 269, then 250, then 35, then none. The
method that works on this class is still the slow one.

## Re-measuring a document that was never claiming to be current

`docs/pre-deployment.md` was corrected this session because it stated
counts in the present tense — "306 tables", "796 SECURITY DEFINER" — and
the numbers had moved since somebody wrote them. The obvious next move
was to do the same to `docs/security.md`, which is dense with figures:
238 and 228 grants, 247 tables and 2 views, 249 relations, 240 of them
holding `MAINTAIN`, 250 with RLS, 41 audited. One of those lines is what
produced 0442.

They were measured. Then the change was not made, and this is why.

### The figures there are dated evidence, not live claims

`security.md` is a record of what each migration found and what it did
about it. Its numbers are the counts *at the moment the migration was
written*, and the prose says so — the grant table is introduced with
"**Counted on production before writing it:**", and the `TRUNCATE`
paragraph reads "Supabase grants `TRUNCATE` to `authenticated` on every
table in `public` by default — 238 of them here."

Renumbering those to today's 308 relations would say that 0240 revoked
three privileges from 308 tables. It did not; it revoked them from the
247 that existed. The default-privileges half of 0240 is precisely what
covers the 61 tables created since. Updating the number would delete the
evidence that the second half was needed, which is the whole point of
that section.

So: a figure in a *checklist* is a claim about now and goes stale. A
figure in a *narrative* is an observation with a date attached and stays
true. `pre-deployment.md` is the first kind and was wrong;
`security.md` is the second kind and is right. The two documents needed
opposite treatment, and treating them alike would have damaged one of
them.

### The one line in it that is a live claim

There is an exception in the same passage, and it is the sentence that
matters most:

> It is inert only because every one of the 249 relations in `public` is
> owned by `postgres`. `table_grants.sql` asserts that premise rather
> than trusting it: if a relation ever appears under another owner, the
> test fails.

That is present tense about the database as it stands, because a
`supabase_admin` default ACL that `postgres` cannot revoke is only
harmless while nothing in `public` is owned by anyone else. Measured on
production:

| | |
|---|---|
| relations in `public` | 308 |
| not owned by `postgres` | 0 |
| client roles holding `MAINTAIN` | 0 |

and `table_grants.sql` does assert it — it reads `pg_get_userbyid(c.relowner)`
and fails on any owner that is not `postgres`, and it checks the default
ACLs' `defaclrole` the same way. The premise holds, the assertion is
real, and the 249 in that sentence is the count 0240 was written
against. It stays.

### The general form

Before re-measuring a number in a document, read what tense the sentence
around it is in. "Counted before writing it" is not a stale claim to be
refreshed; it is a citation. The correction that `pre-deployment.md`
needed would have been vandalism here.

## The tenant-scoped half of 0442's question

0442 asked what, outside the 41 tables carrying an `audit_changes`
trigger, ought to be inside — and answered it for the platform-wide
half. The tenant-scoped half went unasked, so it was asked here.

### The predicate, and what it caught

Every table in `public` with no `audit_changes` trigger, split by
whether it has an `org_id` column: **47** without one. Of those, the
ones with a write policy at all — the ones a person can actually
change — number 18, and they fall into three groups. Chat, presence,
device tokens and profiles are communications and identity. Landing
pages, site pages, reserved names, OCR providers and platform settings
are platform configuration. What is left is the interesting group: a
table with no `org_id` that nonetheless belongs to one company, naming
its tenant through a parent.

**`leave_entitlement_bands` is that shape, and it decides money.**
`app.leave_entitlement` reads it for every employee's years of service;
`leave_bands_dialog.dart` edits it. Measured before 0443: inserting a
band wrote 0 audit rows, and editing that band from 8 days to 99 wrote 0
more. `leave_types` above it was equally unaudited. Every neighbouring
HR table that moves money — `payroll_settings`, `salary_components`,
`employee_salary_components`, `employee_tax_reliefs` — has been audited
since 0055 or 0236.

### The part that was 0442's own fault

`write_audit_log` takes `org_id` from the row it audits. For a table
that names its tenant through a parent it does a lookup, and on a
cascade the parent is already gone, so the lookup resolves to null.
`access_type_modules` has had that shape since 0236. Measured:

```
null-org rows after access_type cascade: 1 (access_type_modules)
```

Before 0442 a null `org_id` was readable by nobody and this was
invisible. 0442 gave those rows a reader — every platform
administrator — and so turned a harmless null into one company's
deleted permission set filed under the platform. **A change that gives
an existing value a new meaning inherits every place that value was
already being written.** That is the lesson worth keeping from this
one; the leave tables were the easy half.

0443 makes the rule explicit in the function: a null `org_id` means the
platform, and only the two statutory tables may write one. Anything
else that cannot name its tenant writes nothing. No event is lost —
those rows only arise on a cascade, and the parent's own deletion is
audited against the right company, which is why 0443 also audits
`leave_types` rather than only its bands.

### What the rest of the sweep found

Nothing else, and the reasons are worth recording so the list is not
re-derived:

- **`tax_brackets` and `tax_reliefs`** feed `app.annual_tax` and
  `app.calc_pcb` — the same statutory class 0442 named — and are *not*
  audited, deliberately. There is no write path: RLS is on, the only
  policy is `for select using (true)`, and no function writes them.
  They change by migration, and the migration is the record: numbered,
  append-only, in git, with its applied date in `schema_migrations`. A
  trigger would record `user_id` null every time and add nothing.
- **`platform_admins`** — who may see every tenant — has one policy,
  `for select using (user_id = auth.uid())`, and no write policy at
  all, so the API cannot change it. Same reasoning as above.
- **`pos_promotions` and its three child tables** are org-scoped and
  unaudited, and a promotion does move money. That is a real question
  and a separate one: the child tables are the same parent-lookup shape
  0443 solves, so it can be answered whenever the discount trail is
  worth having. It is recorded here as noticed, not as done.

## The reader 0442 did not add

0442 wrote this in its own header, and then did not finish acting on
it:

> An audit row nobody can read is the same shape as an assertion that
> passes by not running: it exists, and it discharges nothing.

It widened `audit_logs_select` so a platform administrator may read the
rows whose `org_id` is null. That is a permission. Measured afterwards,
on the installed schema:

- `public.audit_trail(p_org_id, ...)` is the **only** function in the
  schema that returns audit rows. It raises 42501 unless
  `app.can_admin(p_org_id)` and then filters `l.org_id = p_org_id`, so
  no argument anybody can pass reaches a row whose `org_id` is null;
- the app's only caller passes the current organization;
- so the statutory publish 0442 started recording was readable by
  policy and reachable by nothing. A platform administrator with a
  connection string could see it. The same person, in the product,
  could not.

This is worth naming as a shape, because it is not the same as the
gaps this document usually records. The usual one is a function with no
caller. This is a *permission* with no route — the check passed, the
policy test passed, and the feature was still absent. **Widening a
policy is not the same as adding a reader**, and a test that asserts
through the table cannot tell them apart. 0444's assertions go through
the route for exactly that reason.

### The second one, one level up

`app.note_read` writes a `sensitive_read` event with whatever `org_id`
it is handed, and `security_log` filters the same way `audit_trail`
does. So a platform trail that recorded its own reading against a null
org would have written a row nothing could show — repeating the mistake
inside the fix for it. 0444 therefore adds two functions, not one:
`platform_audit_trail` and `platform_security_log`, the same pair a
tenant has.

### And the surviving mutant, recorded rather than papered over

Removing the `least(...)` cap on the row limit survived every
assertion. It is not fixed. Observing a 500-row cap needs 501 platform
audit rows in the fixture, which is a great deal of scaffolding for a
resource guard, and the cheap alternative — string-matching `least` in
the apply-time check — would assert the source text rather than the
behaviour, which this project has been bitten by before. Written down
so the next person knows it was tried, not missed.

## The trail that would have reported saving as changing

0445 closes the audit sweep, and it is the one where adding the trigger
was the smaller half of the work.

A discount *applied* at the till has always been attributable —
`pos_sale_promotions.applied_by`, and 0153's report names the person.
The *definition* was not: `pos_promotions` and its three scope tables
had no trigger, no `created_by` and no `updated_by`, so the sale that
gave away half the stock was attributable and the decision to give it
away was not.

The scope tables are where the money is — a promotion is harmless until
something is in its scope — and `upsert_pos_promotion` rewrote all three
wholesale on every call:

```sql
delete from public.pos_promotion_items where promotion_id = v_id;
insert into public.pos_promotion_items (promotion_id, item_id)
select v_id, i from unnest(p_items) i on conflict do nothing;
```

Correct, and invisible while nothing watched. Put a trigger on it and
correcting a promotion's *name* writes a delete and an insert for every
item in its scope: forty rows saying nothing, with the one row that
matters buried among them. **A trail that reports a change nobody made
fails in the same way as one that misses a change somebody did**, and
the second failure is the one people notice.

So the delete was narrowed to the rows actually leaving. The insert
needed nothing — `on conflict do nothing` inserts no row for one already
there, and a trigger does not fire for a row that was not inserted — so
the path is differential in both directions. Saving a promotion whose
scope did not change now writes nothing to those tables where it
previously wrote 2n rows.

### The general form

Auditing a table is not free of the write path's habits. Before putting
a trigger on something, look at how it is written, not only at what it
holds: a delete-and-reinsert, an `updated_at` bumped unconditionally, a
job that rewrites a table nightly — each turns a trail into noise, and
noise is what makes a trail stop being read. The question to ask is not
"is this table important" but "does a write to it correspond to a
change somebody made".

## The tool that found this document's subject, re-run and re-fixed

`scripts/reachability.py` exists because schema lands ahead of
behaviour here: of the eleven capabilities built before it was written,
nine were already in the database with nothing able to call them. It
was re-run this session, and the answer is worth recording twice over.

### The headline: nothing is unreachable

**Zero RPCs.** Every function in `public` that `authenticated` may
execute is called by something. The gap this script was written to find
is, for now, closed.

The 98 tables it lists are the known false positive its own footer
names: this codebase writes through functions, so a table reached only
by `complete_pos_sale` or `post_receipt` looks unreferenced to a search
of the client. That triage has not changed.

### The tool was lying in two directions, and both are fixed

**A hand-kept list of what the database already knows goes stale in one
migration.** The script filtered extension functions with a prefix
list — `citext`, `gtrgm`, `gin_`, and so on — written when those were
the only extensions installed. `btree_gist` was installed later and
nobody revised it, so 37 of its internals (`gbt_*`, `gbtreekey*`,
`*_dist`) were reported as gaps every run. A third of the output was
the noise the filter existed to remove, and the report had been that
way long enough that its length was the reason nobody read it. The
inventory query now asks `pg_depend`, which is exact and cannot drift:
1,133 rows became 869.

**A function called from SQL is not unreachable.** The script reads
`app/lib` and `supabase/functions` and nothing else, so six functions
that other routines call looked dead:

| Function | Reached by |
|---|---|
| `shared_payment_options` | `open_shared_document` |
| `pos_line_modifier_gaps` | `send_order_to_kitchen` |
| `pos_item_portions` | `pos_menu`, `pos_item_availability`, `app.add_pos_sale_line_internal` |
| `decide_claim_step` | `decide_expense_claim`, `claims_awaiting_my_approval` |
| `corp_display_name`, `corp_issued_capital` | the corp-sec reports |

They are now listed apart, as reachable, with a note that each holds an
execute grant it may not need.

### Why that note is a note and not a migration

Inside a SECURITY DEFINER function the caller is the owner, so a
function only SQL calls does not need its grant to `authenticated` at
all: revoking six of them would narrow the PostgREST surface by six
functions nothing calls. It was measured, and then not done, for
reasons that are specific rather than cautious.

`shared_payment_options` is granted to `anon` deliberately by 0413, for
the customer holding a share link. `pos_line_modifier_gaps` and
`pos_item_portions` are the server-side halves of rules the client
repeats on purpose — `modifier_sheet.dart` says why, and says it is
"not to replace the server's check but so the refusal never has to
happen" — which makes a screen calling the server's version directly a
plausible next step rather than a mistake. Revoking a grant that harms
nothing, to close a hole nobody can reach, is the kind of change that
looks like work and is not.

## The bonus that was taxed as though it came every month

A statutory arithmetic finding rather than a reachability one, and the
worst-shaped kind: correct over a year, wrong every month inside it.

`app.calc_pcb` implements the MTD computerised calculation, and for
normal remuneration it implements it correctly — project the month's
taxable pay over the months remaining, subtract the reliefs, tax the
result, take off what has been deducted, divide by the months left:

```sql
v_n         := 12 - month + 1;
v_projected := ytd + opening + p_taxable_this_month * v_n;
```

The `* v_n` says "this month is what every remaining month looks like".
True of a salary. False of a bonus. Under the Income Tax (Deduction from
Remuneration) Rules a bonus, commission, arrears, director's fee or
gratuity is **additional remuneration**: it enters the year's income
once, and the deduction on it is the difference between the year's tax
with it and without.

Nothing in the schema could say which earnings were which, so
`calculate_payroll_run` summed every taxable line into one figure and
handed it over to be annualised.

### Measured

One employee, RM5,000 a month, resident, single, paid 25 February 2026:

| Month's taxable pay | PCB deducted |
|---|---|
| 5,000 | 90.95 |
| 5,000 + a 12,000 bonus | **2,528.85** |
| 5,000 + the same bonus, after 0446 | 994.45 |

### Why nothing caught it

**The year comes out right.** The formula subtracts `v_ytd_pcb`, so
March onwards deducts less and the twelve months sum to about the
correct figure. A test that runs one payroll and checks the annual
identity sees nothing wrong. What is wrong is every month in between,
and two cases where "in between" is where the employee lives: somebody
who leaves before December never gets the correction, and a bonus in a
final month is the same error at full size.

**And the suite paid in the wrong month.** `payroll_run.sql` pays in a
single period, and a December bonus is unaffected because `v_n` is 1.
The bug is invisible in December and largest in January.

That is the general form worth keeping: *an error that self-corrects
over a cycle is not caught by an assertion about the cycle.* Ask what
the intermediate states are, and whether anybody lives in one.

### What the fix cost, and the mutant that mattered

`salary_components` and `payslip_lines` each gained
`is_additional_remuneration`; the copier that builds a payslip line
from a component had to be taught the new column, which is the 0410
shape for the sixth time and is asserted rather than assumed.

The fourth mutant is the one worth recording. Defaulting the new column
to `true` rather than `false` **survived**: nothing asserted what an
ordinary component does when nobody mentions the flag, which is the
migration's most consequential silent claim — every allowance in every
company would have stopped being annualised the day it applied. The
assertion added for it is one line. A new column with a default is a
claim about every existing row, and it deserves an assertion of its
own.

## The same blind spot, one module over: which day of the year

0446 was invisible because every payroll fixture paid in a single
month. The obvious next question is where else a figure depends on
*where in a cycle you stand* while the assertions only ever stand in one
place. Three candidates were measured and two came back clean.

**Revenue recognition and depreciation are not this shape.**
`revenue_recognition.sql` asserts intermediate periods explicitly — "the
first month earns only its twelve days", "three months have reached
revenue", "nothing later was touched". `depreciation_schedule.sql` does
the same — "six months of van were charged", "the first charge is three
months, the second is the three to disposal", "each opens where the last
one closed". `fx_revaluation.sql` measures April from the booked rate
rather than only the closing position. All three spread an amount across
periods; all three check the periods.

**`app.leave_entitlement` is.** Every band assertion in
`hr_reference.sql` hired on 1 March. The function measures service as
`p_year - extract(year from hire_date)`, which counts New Year's Eves
crossed rather than months served, so the day of the year decides the
answer and one position cannot see it. Measured:

| Hired | Leave year | Service at 1 January of it | Days given |
|---|---|---|---|
| 2024-01-01 | 2026 | 24 months | 12 |
| 2024-12-31 | 2026 | 12 months and a day | 12 |
| 2025-01-01 | 2030 | 5 years | 16 |
| 2025-12-31 | 2030 | 4 years and a day | 16 |

### Why this is recorded rather than fixed

Because it is not clearly a mistake, and saying so is the point.

s.60E(1) sets the twelve-day band for an employee "employed for a period
of two years or more". The 31 December 2024 hire is not, on 1 January
2026 — and is, by 31 December 2026. The present answer is right under
the end-of-year reading and wrong under the start-of-year one, and the
Act itself measures entitlement against *twelve months of continuous
service* rather than against a calendar year at all, which is a third
frame the schema cannot express because the function only receives a
year.

Changing it would reduce somebody's leave. That is a decision about a
statutory entitlement, and this project has declined to invent rules of
that class before — the rounding method that would apply to every sales
document, rent and strata. Declining consistently is the rule.

So the convention in force is now pinned by four assertions that vary
the day within the year, with the question named beside them, and the
measurement is here. What was actually wrong — that nothing tested more
than one position in the cycle — is fixed. What needs a person's
decision is visible to the next person who looks at leave, instead of
being a subtraction nobody had read closely.

## A quarter is not a Postgres interval

0446's question — which figures depend on where in a cycle you stand,
and do the assertions ever stand anywhere else — asked of the date
arithmetic. It found two faults in nine lines, one of them a feature
that had never worked at all.

`app.advance_schedule` built an interval by pasting a number to a word:

```sql
(p_interval || ' ' || case p_frequency
   when 'daily' then 'days' ... when 'quarterly' then 'quarters'
   ... end)::interval
```

### `quarterly` raises 22007 every time

Postgres has no `quarters` unit. The recurring journal editor offers
**Quarter** in its dropdown and `recurring_documents_screen.dart`
renders `quarterly` in its summary line, so this was reachable from two
screens. Measured through the real scheduler:

```
quarterly journal ran, 0 raised
last_error: invalid input syntax for type interval: "1 quarters"
next_run_date is still: 2026-01-31
```

**The retry is what made it silent.** `run_recurring_journals` catches
the failure, records `last_error` and deliberately leaves
`next_run_date` alone so the run is retried — correct for a transient
fault, and exactly wrong for one that can never stop happening. A
quarterly schedule failed every night, posted nothing, and said so only
in a column nobody reads. A permanent error dressed as a transient one
is quieter than a crash.

### And monthly walked off the end of the month

Adding a month to 31 January gives 28 February, which is right. Adding
a month to *that* gives 28 March:

```
2026-01-31 -> 2026-02-28 -> 2026-03-28 -> 2026-04-28 -> ...
```

A tenancy invoiced on the last day of every month becomes the 28th of
every month, permanently, the first time it crosses February. The 30th
does the same through a leap February. **It takes two steps to see**,
which is why nothing saw it: the function advances from the previous
occurrence, so once a short month has clamped the date the intent is
gone, and a test that advances once is looking at the step that behaves.

0447 gives the function the schedule's `start_date` as an anchor and
puts the result back on that day of the month, clamped to the month's
length — and replaces the pasted string with `make_interval`, so a unit
that does not exist stops being expressible.

### The general form

Both faults share a property with 0446 and it is worth stating on its
own: **a function that is called repeatedly on its own output cannot be
tested with one call.** The first step of the drift is correct. A
quarterly schedule's first failure looks like a warning. Where the
output of one call is the input of the next, the assertion has to run
the loop.

## Two setup screens with nothing on them, and what the mutants found

0446 put a checkbox on the HR setup screen. Then, measured on
production:

| company | employees | runs | payslips | components | leave types |
|---|---|---|---|---|---|
| Sinar Teknologi | 4 | 7 | 28 | **0** | **0** |

Every other tenant has none of any of it, correctly — they do not buy
payroll. Sinar does, and has run it seven times without a single
allowance, deduction or kind of leave. Two setup screens showed their
empty state in the only company that can open them, and the checkbox
0446 added had nothing to sit beside.

**This is not the demo register reopening.** That sweep asked which
modules had no tenant at all, and is closed. This is a shape it could
not see: a module with a tenant, real transactions, posted books — and
two of its tables empty.

0448 seeds the allowances, a February-only bonus marked as additional
remuneration, the leave types with the Act's bands applied by
`apply_statutory_leave_bands`, and rolls the leave year so there are
balances. It runs before the payroll loop, so the payslips carry it.

### The mutants found two things that were not mutants

**The demonstration was on the wrong person.** The bonus first went to
the highest earner, and the assertion about February's deduction passed
whether the flag was set or not. Measured: on RM9,500 a month the two
methods give 3,741.35 and 3,469.75 — seven per cent apart, because she
is already near the top band, so annualising buys little extra tax and
dividing by eleven hands most of it back. On RM5,200 the same bonus
gives 2,641.35 and 1,268.95.

An assertion that cannot fail is not always the assertion's fault. **A
demonstration has to be built on a case where the thing demonstrated is
visible**, and mutation testing is what said the first one was not.

**And the obvious assertion cannot be written in a demo at all.** The
natural check is that February's deduction is below the annualised one,
recomputed by handing the payslip's own figures back to `calc_pcb`. It
passes with the flag removed. `calc_pcb` reads `payroll_ytd`, and by
the time the test looks that holds the whole year rather than the one
month February saw, so the recomputed figure is not the figure February
took.

*A figure that depends on accumulated state cannot be checked by
recomputing it later.* The arithmetic is asserted where the inputs are
controlled — `payroll_run.sql` — and what belongs in the demo is that
the flag is carried onto the payslip and that the bonus month costs
more than an ordinary one.

## The counter that had never taken money, and one thing left unresolved

0448 suggested a sweep the demo register could not do: not "which module
has no tenant" but **"which tenant has a module switched on and its
tables empty"**. Run over every demo tenant, attributing each org-scoped
table to the narrowest module whose tenants are a superset of the
tenants that populate it, exactly one gap was left after 0448:

| module | table | tenant with none |
|---|---|---|
| pos | pos_sales, pos_sale_lines, pos_shifts, pos_tenders, pos_tender_types | Sinar Teknologi |

`app.demo_pos_sinar` built the outlet, two registers and the walk-in
customer, then said so itself: *"No sale has been rung through it yet."*
A seed that reports where it stopped is better than one that does not;
it is still a counter that has never taken money.

0449 rings one through: RM9,180.00 on a card, RM680.00 of tax, one
tender, a shift opened and cashed up, and a half payment refused before
the full one was taken.

### The thing that looked unresolved, and the answer

0449's header records a conflict as open, and **it was resolved shortly
afterwards. That header is superseded by this section**; a reader who
reaches it first should stop there.

The two measurements were:

- a controlled fixture — tracked item, no recipe, ten on hand, two sold
  over a till — going to **eight**;
- the demo showing **no `pos_sales` row** among Sinar's stock movement
  sources after the counter sale.

Both were correct. The mistake was the second question. Printing the
fixture's movements rather than counting them gave it away in one line:

```
OB-1          opening_balance qty=10  src=(null)
SM-2026-00001 sales_delivery  qty=-2  src=sales_documents
```

**A POS sale does not move stock in its own name.** It raises a sales
document, and the delivery against *that* is what takes the goods out,
so `source_table` is `sales_documents` and never `pos_sales`. A query
filtering on `pos_sales` returns nought however well the till is
working. Confirmed on the demo: the counter sale raised
`INV-2026-00024`, and that invoice carries
`SM-2026-00051 sales_delivery qty=-1.0000` — one component out of MAIN,
which is exactly what the first draft of 0449's header claimed before it
was softened.

So there is no defect, and the softening was unnecessary. It was still
right at the time: the header could not claim what had not been shown.
What this cost was an hour; what the alternative costs is a document
that says something untrue for as long as nobody checks.

The lesson is narrower than "measure things", and worth keeping: **a
count of zero proves nothing until you have seen the same query return
something.** Printing one row of what the query *does* match would have
ended it immediately.

## The two sweeps that met in a payslip

`app.calc_pcb` and `app.calc_statutory` are the whole of what a payslip
deducts. Sweeping both, back to back, found one defect in the arithmetic
and a large hole in what the suite was looking at.

### `calc_pcb`: 19 of 41

Three worked examples pinned the monthly deduction for three people —
single on 5,000, married on 12,000 with two children, aged 62 on 4,500 —
and **almost every branch between them was invisible**. A deduction that
ignored a disability, a working spouse, a child's claimed share, a
dependant's tax flag, or the PCB already deducted this year would have
passed the suite unchanged.

So would all three `greatest(..., 0)` floors, and those are not
cosmetic: each is the difference between deducting nothing and paying
money **out** through a payslip. The third is the least obvious — a
bonus raises the year's income by its own amount and the year's relief
by twelve times the EPF taken from it, so a small bonus with a large EPF
deduction makes the year's tax go DOWN. Unfloored, the engine hands the
difference back.

Twenty-eight assertions later, 36 of 42 die. The six survivors are
equivalent and each provably so:

| survivor | why it cannot matter |
|---|---|
| `greatest(12 - month + 1, 1)` loses its floor | 12 down to 1 for months 1..12; the floor never binds |
| chargeable income may go negative | `app.annual_tax` of a negative is already zero |
| zakat may take the tax below zero | same, and the final floor catches the rest |
| the EPF cap falls back to something absurd | the fallback is 4,000 and the seeded cap IS 4,000 |
| the spouse relief falls to nothing | same shape; fallback equals the seeded value |
| a non-resident missing a rate is charged nothing | every PCB schedule carries one |

The last three are equivalent *because of the data*, which is why the
same commit asserts the data: every PCB schedule carries a non-resident
rate and four reliefs, and the two caps are the numbers the fallbacks
assume.

### The defect: RM14,000, not RM8,000

Reaching for a figure to pin one survivor with is what showed the figure
was wrong. The child relief `CASE` read:

```sql
when d.is_disabled and d.in_higher_education then 8000
when d.is_disabled then 6000
when d.in_higher_education then 8000
else 2000
```

The first arm is indistinguishable from the third. Section 48 of the
Income Tax Act 1967 gives an unmarried disabled child RM6,000 and an
**additional** RM8,000 where that child is in full-time higher
education — diploma and above in Malaysia, degree and above abroad. The
two are cumulative: RM14,000. **The disability was read and then thrown
away for exactly the children entitled to most.**

Which way it is wrong decides who is out of pocket. Under-relieving
OVER-deducts, so it is the employee's money, held by LHDN, for a year,
because of a line in a `CASE`. 0530 fixes it; both arms are now pinned.

### `calc_statutory`: 19 of 24, then 23

One function serves EPF, SOCSO, EIS and HRDF. Four survivors, and the
one worth repeating is **the RM20 step**.

KWSP rounds the wage UP to the next twenty before applying the rate.
Every wage the suite used was already a multiple of twenty, so rounding
to the NEAREST step gave the same answer everywhere. RM5,001 is where
they part: up lands on 5,020, nearest falls back to 5,000 — and 5,000 is
in a different **employer** band. Not a rounding difference. Forty-seven
ringgit of somebody's contribution.

The other three were all about a flag rather than a figure: a date
before any table exists, and an unverified schedule, both reported
`is_verified` that nothing checked. `payslip_pdf.dart` prints its
warning off that flag, and all five seeded tables are unverified — so a
mutant hard-coding `true` took the warning off **every payslip in the
product** and passed.

### The survivor that needed a new file

The last one — taking the lowest matching band rather than the highest —
is equivalent only while no two bands cover one wage.
`app.assert_statutory_bands` enforces that when a schedule is published
through `platform_publish_statutory_schedule`, and it ran once over the
seed at migration time. **Nothing re-checked it afterwards**, so the
equivalence was an assumption rather than a fact.

`supabase/tests/statutory_bands.sql` re-checks every shipped schedule,
and requires every statutory body to have a table at all — otherwise
"every schedule passes" is satisfied by a body losing its table
entirely. It has no fixtures on purpose: `statutory_schedules.sql`
deliberately builds a schedule WITH a hole in it, so a loop over every
schedule cannot live in that file. The first draft put it there and
failed on the fixture, which is the shortest possible demonstration of
why.

**An equivalent mutant is a finding.** Half of these were equivalent
because of a rule somewhere else, and each one was worth the trip to go
and assert that rule.

### `calculate_payroll_run`: 61 of 91, then 90

The largest function in the payroll module, and the widest hole this
method has found. `post_payroll_run`, which merely files the numbers,
was already at 27 of 27; the function that PRODUCES them killed 61 of
91 one-line mutants.

Almost every survivor was the same failure, and it is not a failure of
assertions. `payroll_run.sql` pays three people and checks every figure
on their payslips — it is a good file. But **nobody in it leaves**.
Nobody works a rest day or a public holiday. Every allowance is a flat
amount that is active for ever. Nobody is paid a bonus. So the branches
that survived were not unasserted; they were unreached. A run that pays
a leaver to the end of the month, charges holiday overtime at the rest
day rate, keeps paying an allowance that ended in March, or deducts
annual leave as if it were unpaid passes that file without a mark on
it.

`supabase/tests/payroll_shapes.sql` is the other shapes: a leaver, a
person who left last year, somebody sixty years old to the day, a month
of rest-day and holiday overtime, five leave requests of which two
count and both only partly, four allowances of which one is payable,
and a bonus. 57 assertions.

Four of the survivors are worth naming, because each is a class rather
than a case.

**The company that has never opened the payroll settings screen.** The
three overtime multipliers are read as `coalesce(v_set.ot_normal_multiplier,
1.5)`. Every company in the suite HAD a settings row, and the column
defaults carry the same 1.5, 2.0 and 3.0 — so the fallbacks were never
reached and mutants changing all three to the wrong multiple lived. The
company with no settings row is not a strange company. It is a new one.
Its rest-day overtime would have been paid at time and a half.

**Sixty years old to the day.** SOCSO's Act 800 and EPF's over-sixty
rates begin AT sixty. `v_age >= 60` and `v_age > 60` differ for exactly
one employee per birthday per company, and a suite that does not name
one will never meet them.

**A percentage of basic.** The amount is
`coalesce(esc.amount, nullif(sc.default_amount, 0), basic * percent / 100)`.
`default_amount` defaults to **zero, not null**, so the `nullif` is the
only thing that lets a percentage through at all — and every allowance
in the suite was a flat amount, so dropping it changed nothing. Without
it, every percentage-based allowance in the product pays nothing.

**The bonus's own EPF, which is only visible in December.** `calc_pcb`
splits the month into ordinary pay and additional remuneration, and the
bonus's EPF relief is its proportional share of the month's EPF. Two
mutants attacked that share, and both are equivalent **because of the
figures**: the year's EPF relief caps at RM4,000, and above the cap
`least(v_epf_used + v_add_epf, 4000)` is 4,000 whatever the share is.
`calc_pcb` projects the month's EPF over the months that REMAIN, so in
any month but December the projection alone clears the cap. And on an
ordinary salary the cap is reached at about RM3,000 a month, which is
below where PCB starts at all — so the payslip that has both a live EPF
split and a non-zero PCB has most of its pay OUTSIDE EPF wages. That is
a commission structure: small basic, large non-EPF allowance, year-end
payment split between something inside EPF and something outside it.
The fixture is built on that shape deliberately, and says so.

The two mutants about WHICH money is additional need the opposite
month: in December the projection has one month left in it, so moving a
ringgit between ordinary pay and additional remuneration leaves the
year unchanged. They are killed in June. One PCB call, two mutants that
need December and two that need June.

### The levy's schedule, which had only ever been one

Three of the four conditions in the HRDF rate lookup had nothing
asserting them, for the same reason: the repository ships **exactly
one** HRDF schedule with two categories in it, and every test used the
same category of the same schedule. A superseded rate charged for ever,
a rate gazetted for 2030 charged today, and the voluntary registrant
charged the mandatory rate all passed.

The fixture now puts a superseded schedule and a future one on file.
The superseded one is left with **no end date**, which is how these
tables are actually maintained — a new schedule is published and the
old row is left alone — so `effective_to` is not what puts it out of
reach. The ordering is, and that is the point.

### The one equivalent mutant, and why the branch stays

`v_basic := case when v_worked >= v_days then v_emp.basic_salary
else round(v_emp.basic_salary * v_worked / v_days, 2) end`

`v_from` is never before the period start and `v_to` never after its
end, so `v_worked <= v_days` always and the guard is `= v_days`.
`basic_salary` is `numeric(18,2)`, and `round(x * d / d, 2) = x` holds
for every one of the 12,000 combinations of a two-decimal amount and a
28-to-31-day month. Forcing the pro-rated arm is provably the same
money.

It is not the same payslip. The line's DESCRIPTION carries an identical
`case`, and that one is killed — a full month must not say "Basic
salary (31 of 31 days)". The two arms exist to agree with each other,
which is a reason to keep the branch rather than to delete it.

### `corp_upcoming_filings`: 9 of 29, then 25

The one list a company secretary works from, and the only place in the
product where a silent wrong answer costs money to somebody who did
nothing wrong. A filing that drops off this list is a filing nobody
makes, and s.68 of the Companies Act 2016 carries a fine and a daily
default penalty on top.

Nine of twenty-nine. `secretarial.sql` pins the two **dates** the Act
gives — thirty days from the anniversary, two hundred and ten from the
year end — and pins that a Sdn Bhd holds no AGM. Nothing pinned **who
is on the list at all**. Every one of these passed:

- a company **struck off the register** still chased for its annual
  return, which SSM would reject
- a client the practice has **resigned from** still on the firm's list,
  which is billing for work it has no authority to do
- an **LLP** given a Companies Act s.68 annual return — the anniversary
  join's `applies_to` had nothing on it, only the year-end join's, by
  way of the AGM
- a filing **approved** or marked **not applicable** still listed as
  outstanding — three statuses take a filing off the list and one was
  pinned
- one company's lodged return **signing off another's**, because the
  join was matched on filing type without the entity or the year

`supabase/tests/corp_deadlines.sql` is 41 assertions over those shapes.

**A filing due today is not late.** `due_date < v_today` versus `<=`
decides what a secretary lodging on the last lawful day is told. That
needs three companies whose returns fall due yesterday, today and in
ten days, and nothing in the suite had one on any of those days.

**Today is a Malaysian day.** `v_today` is
`(now() at time zone 'Asia/Kuala_Lumpur')::date`, and a mutant using
`current_date` — which follows the *session* time zone — passes
everything, because a test that does not move the session clock cannot
tell them apart. Between midnight and eight in the morning in Kuala
Lumpur a server left on UTC is a day behind, and a return due yesterday
is reported as due today.

Asserting it needs a session time zone whose date differs from
Malaysia's, and **which one does depends on the hour**. Kuala Lumpur is
UTC+8. `Etc/GMT+12` is twenty hours behind it and differs except in the
last four hours of a Malaysian day; `Pacific/Kiritimati` is six hours
ahead and differs in the last six. The test picks whichever of the two
currently differs, so it is a real assertion at every hour rather than
one that quietly passes for most of the day.

**The default window is two guards, not one.** `p_within_days integer
DEFAULT 120` and `coalesce(p_within_days, 120)` catch two different
callers: omitting the argument takes the SQL default, and PostgREST
passing a JSON null takes the coalesce. The Flutter client's
`withinDays` is a non-nullable `int`, so only the first was ever
reached — and a mutant shrinking the coalesce to a fortnight lived
until the test called the function with an explicit null.

**Ordering needed a second company.** `order by c.due_date, c.name`
mutated to `order by c.name` survived, because with one company on the
books the two orderings agree. Two more, named so that alphabetical
order is the exact reverse of deadline order, and it dies.

#### The four equivalent mutants, and what each depends on

| Mutant | Why it cannot matter |
|---|---|
| `e.incorporated_on is not null` dropped | The anniversary count is `extract(year from …incorporated_on)`, so a null makes the series bound null, and `generate_series(1, null)` returns **no rows**. Verified. |
| `e.financial_year_end_month is not null` dropped | `app.corp_fye` returns null without a month, and `d.trigger_date is not null` on the next line already removes it. |
| `d.trigger_date >= e.incorporated_on` dropped | Subsumed by the outer `c.trigger_date > (select incorporated_on)`, which is the same comparison one notch stricter. `>` implies `>=` for every pair of dates; verified over a year of them. |
| `or c.due_date >= v_today - 365` dropped | Unreachable **for the year-end kinds**, because the year-end series runs over only the current calendar year and the one before it: the oldest year end it can produce is 31 December of last year, and 210 days after that is inside the 365-day window for all but a few weeks at the end of a year. |

The last one is the interesting one, and it is equivalent **because of
the series** rather than because the clause does nothing. Widen the
series by a year and it becomes live again — so what the test asserts is
the **series bound itself**, exactly as `statutory_bands.sql` asserts the
band rule that makes its own survivor equivalent. Same shape, second
time.

And the one place the outer `>` earns its strictness: a company whose
first financial year end is recorded as **the day it was incorporated**.
The anniversary series can never reach the incorporation date — it
starts a year after it — so that condition bites on one shape only, a
financial year of zero days. It is a data-entry artefact, not a filing,
and a deadline computed from it is a deadline for accounts that cannot
exist. That company is now in the fixture.

### The s.258 and s.259 clock: 9 of 24, then 24

Three functions carry one rule: `app.fs_lodge_by` is the rule,
`public.fs_deadlines` is one filing's answer, and
`public.report_fs_deadlines` is the list a practice works from. Swept
together, because a mutant in the rule is only visible through the
other two.

`fs_statutory_order.sql` asserts the ORDER of the three dates —
approved, circulated, lodged — and pins the thirty days that run from
circulation. What nothing asserted was the filing that has **not been
circulated yet**, which is every filing for the first six months after
a year end and therefore most of them. Its lodgement date comes from
`fy_end + 6 months + 30`, and the six months in that expression had no
test at all: a mutant making it three passed the whole suite, and would
have told every client in the country it was three months late.

Also alive: the days-left countdown pointed at the wrong deadline, a
filing already lodged reported late for ever, a filing late on the day
it was due, another practice's accounts on this practice's list, and
the report readable by a company that had not bought the module.

**A date built from months does not survive a round trip.** The first
draft of the fixture built a year end as `today - 6 months - 30 days`
and expected the deadline back on today. It came back three days early:
subtract six months from a date in early March and add them back, and
February is short. The boundary cases are dated from the CIRCULATION
instead — thirty days is thirty days — which is exact, and happens to
exercise the branch that matters more anyway.

**The sentence is not decoration.** `basis` is what the screen prints
to tell a director *why* the date is the date, and the two sections
describe two different obligations: a private company CIRCULATES the
accounts under s.258, a public company LAYS them before a meeting under
s.340. Three mutants lived in that one `case` — forced each way, and the
`= 'bhd'` test widened to every company — because nothing had ever
looked at the string. A private company told it must hold an AGM is a
private company convening a meeting the 2016 Act abolished for it.

**A tie-break needs five companies, not two.** The list is ordered by
deadline and then by name. Replacing the name with the row's uuid puts
two companies in the right order half the time — so the mutant survived
a fixture with two tied filings, and the sweep was reporting a coin
toss. With five, an arbitrary order lands alphabetical once in a
hundred and twenty. Most of a practice's clients have a 31 December
year end, so most of this list IS ties: the tie-break is the ordering,
not a detail of it.

Two filings with different year ends and the same circulation date have
the same deadline, which is how five of them get onto one day while the
one-year-end-per-company constraint still holds.

### The depreciation engine: 19 of 42, then 39

`fixed_assets.sql` opens by saying that depreciation is the one charge
in the ledger nobody enters by hand, so nobody checks it either. That
is exactly right, and it is also what the sweep found: the ARITHMETIC
was well covered — straight line, reducing balance, the closed form,
idempotence — and the REGISTER SHAPES around it were not covered at
all.

Every asset in the suite had a residual value of nought, no asset had
been deleted, none was bought after the date being run, none carried
its own pair of accounts, and no chart was missing the two the run
falls back to. So:

- **`v_depreciable` versus `cost`.** RM50,000 with a RM5,000 residual
  over 60 months is RM750 a month, not RM833.33. With every residual at
  nought the two expressions are the same number, and a mutant swapping
  them passed.
- **A company that splits depreciation by class of asset** — which is
  what an auditor asks for — has assets carrying their own expense and
  accumulation accounts. A mutant ignoring them and posting everything
  to 6400 and 1590 passed, and the note to the accounts could not have
  been produced.
- **A chart missing 6400.** `0500` made the chart editable. Without the
  raise, `create_gl_entry_internal` is handed a null account id and
  fails somewhere less helpful.
- **An empty run.** With nothing to charge the run row is deleted; a
  mutant leaving it behind writes a line in the audit trail claiming a
  posting that never happened.

**Land.** The mutant that needed the strangest fixture was
`if v_charge <= 0 then continue` weakened to `< 0`: it writes a
depreciation entry of nought. A run where EVERY asset is up to date is
deleted whole and takes the zero rows with it, so the mutant hides — it
is only visible in a run that posts something AND passes over
something. The asset that is always passed over is land: carried at
cost, residual equal to cost, on the register so the fixed asset note
foots, and never depreciated.

**A reducing-balance asset is not written off. It is rounded off.**
The mutant marking an asset finished one cent early is unreachable on a
straight line with any credible figures — it needs a monthly charge of
one sen. On a reducing balance it is exactly where the asset ends,
because the closed form never reaches the depreciable amount: RM30,000
at twenty per cent a year is within one sen of finished after 864
months and finished after 929. Seventy-seven years. Both dates are in
the fixture, and the fiscal years they post into have to be opened
first, which is period control doing its job.

**A percentage typed as 2500.** The check constraint on `rate_percent`
is only `> 0`, so twenty-five per cent typed as 2500 is a number the
database accepts. At a monthly factor of `1 - 2500/1200` the closed
form says the asset is worth minus RM10,833 after one month and MORE
than it cost after two — a charge of minus RM1,736, which without the
clamps would post a CREDIT to depreciation expense. Income, from a typo
in a percentage field. Both clamps are now pinned, one at each month.

#### The three equivalent mutants

| Mutant | Why it cannot matter |
|---|---|
| `if p_as_at < p_asset.acquisition_date then return 0` removed | `app.months_held` already returns 0 for every date before the acquisition — verified over every acquisition day in an eleven-year range. The two guards **mask each other**, which is why the pair is now pinned by asking `months_held` directly rather than only through its caller. |
| `v_depreciable <= 0` removed | `fixed_assets_residual_below_cost` makes `cost - residual_value` non-negative, so the guard is only reachable at equality, where the arithmetic returns 0 anyway. Equivalent **because of the constraint**, so the constraint is what the fixture asserts. |
| `acquisition_date <= p_as_at` removed from the RUN | The charge for such an asset comes out at nought and `continue` fires. It is a performance filter, not a correctness one — and the same condition in the PREVIEW is not equivalent, because the preview returns the row rather than skipping it. Both are in the fixture; only one mutant survives. |

The first of those is the interesting shape, and it is one this campaign
has now seen twice: **two guards that each hide the other's mutant.**
Neither is dead. The only way to tell is to test the smaller function on
its own.

### The SST engine: 25 of 46, then 39

Two functions: `app.sst_period_for`, which says which taxable period a
date falls in, and `app.sst_output_due`, which says what falls due in
one. `sst_taxable_period.sql` pins the two-month cycle and
`service_tax_on_payment.sql` pins section 11's payment basis. Both are
good files, and 21 mutants still lived.

**A taxable period the Director General fixed by hand.** Section 8 of
the Service Tax Regulations 2018 lets the Director General assign a
different taxable period on application. The column is there, the code
has three branches for it, and NOTHING in the suite had ever set it — so
a mutant ignoring the column, one deleting the step back to the
registration month, and one deleting the wrap into the following year
all passed. The last of those is the subtle one: a month named EARLIER
in the calendar than the registration month belongs to the *following*
year, and without the `+ 12` a company registered in November with a
January cycle gets a first taxable period beginning in October — before
it was registered at all.

**The day the twelve-month clock strikes.** Section 11(2) puts the tax
due on the day FOLLOWING twelve months from the invoice. The mutant
taking the anniversary itself passed, because nothing had ever paid an
invoice on exactly its anniversary — the one day the two readings
disagree. Two invoices dated the same day, one paid on the 15th and one
on the 16th, separate them: the first is a payment, the second is a
default, and the payment that arrives on the day of default must not be
declared a second time.

**The service charge is service tax on a payment basis.** It lives on
the document HEADER, not on a line, because it is a percentage of all
of them. A mutant dropping the whole second arm of the union passed —
and writing the assertion turned up the thing worth knowing: a
restaurant's ten per cent is not due when the bill is printed. It is
service tax on an invoice, so it is due when the money arrives, and it
does not appear in the return until the bill is paid.

**A return has to be in sen.** The payment basis apportions by
`p.amount / s.total`, which is a third of a ringgit as often as not.
Both `round(..., 2)` calls had nothing on them.

#### Seven equivalent mutants, and the reason for each

| Mutant | Why it cannot matter |
|---|---|
| `not is_sst_registered` dropped | Masked by `sst_registered_from is null` |
| `sst_registered_from is null` dropped | Masked by `not is_sst_registered` |
| zero service charge admitted | Masked by `having sum(l.tax) <> 0` when the charge is service tax, and by the final `net <> 0 or tax <> 0` when it is sales tax |
| `max(l.total_amount) > 0` dropped | The division it guards is unreachable: a payment cannot exist against a zero-total invoice, and `total > paid_by_then` cannot hold when the total is nought |
| `a.org_id = p_org_id` on allocations | `payment_allocations_invoice_same_org` — the `0512` composite key already ties an allocation's company to its invoice's |
| an invoice paid in full falls due again | It contributes `(total - paid) / total`, which is nought; over-allocation is refused elsewhere |
| `x.tax is not null` dropped | The `(x.net <> 0 or x.tax <> 0)` on the next line is null for a null tax, so the row goes anyway |

The first two are **the third mutually-masking pair this campaign has
found**, after `months_held` / `accumulated_depreciation_at` and the two
`>=`/`>` comparisons in `corp_upcoming_filings`. A company registered
with no date, or unregistered with one, would tell them apart, and
neither state exists — `set_sst_registration` writes the boolean and the
date together and `guard_sst_registration` refuses any other writer. So
the fixture asserts THE PAIRING: registering sets both, deregistering
clears both, and the trigger refuses each field on its own.

That is now the standard move when a survivor turns out to be equivalent
because of a rule enforced elsewhere: **assert the rule, not the dead
branch.** Four times now — the statutory band overlap, the corp-sec
series bound, the residual-below-cost constraint, and this.

### Withholding tax: 23 of 48, then 47 — and the method's own blind spot

`withholding.sql` pins the eight rates in the Act, the arithmetic, the
journal and the s.109(2) penalty. It also *appears* to pin the refusals.
It does not, and why it does not is the most useful thing this campaign
has turned up about how these tests are written:

> **An assertion that catches an error code catches ANY error with that
> code.**

`withholding.sql` proves an unposted bill is refused by calling
`create_withholding` on a draft and catching `22023`. Delete the
unposted-bill guard entirely and the call still raises `22023` — from
the *next* guard, because a draft bill with no lines has a balance of
nought and any tax is more than nought. The test passes, the guard is
gone, and nothing says so.

The same shape appeared three more times in one function group:

- **posting a certificate twice.** Without the guard the second post
  inserts a second allocation, the bill goes over, and
  `apply_allocation` raises. `when others` catches that too.
- **a viewer remitting.** `remit_withholding` and `create_gl_entry` both
  refuse with `42501`. Catching the code alone passes with the outer
  guard deleted — and the outer one is what stops the bank balance and
  the certificate being touched at all.
- **a certificate on nothing.** Refused by `create_withholding` in one
  place and `post_withholding` in another, in different words.

The fix in every case is the same and it is cheap: `get stacked
diagnostics` the message and assert on it. A guard is identified by what
it SAYS, not by the class of error it belongs to. Where two guards word
themselves identically there is nothing to assert, which is its own
argument for wording them differently.

What else lived: the whole of `remit_withholding`'s bank account — the
cross-organization guard, the lookup, the fallback, the balance update
and the `where id =` on it — because the existing file remits without
naming an account, so five branches had one case between them; the
supplier's own payable account, which a related company or a director's
loan needs; and a foreign bill, where USD1,000 withheld at 4.50 is
RM4,500 of liability and a mutant made it RM1,000.

The one surviving mutant is `round(v_gross * v_rate / 100.0, 2)` with
the round deleted, and it is equivalent because `tax_amount` is
`numeric(18, 2)` — the column rounds what the function did not. So the
fixture asserts **the column's scale**. Fifth time.

### And a ratchet for the blind spot

The withholding sweep found the method's own weakness, so it is worth
counting how far it goes. Across the suite there are **420** `when
others` handlers. **298** of them look at the error — `sqlerrm`, `get
stacked diagnostics`, a `check_` on the message. **97** assert nothing
at all.

Not all ninety-seven are wrong. Where only one thing can possibly raise,
catching broadly costs nothing. But every one of them is a place where a
future edit can break the thing under test and nothing will say so, and
a blind handler also swallows a typo in the statement it is testing and
reports it as a pass.

Ninety-seven is too many to fix in one go and exactly the number that
makes a new rule worthless — a check that fails a hundred times teaches
people to ignore it, which is the lesson `check_narrow_rows.py` taught
already. So `scripts/check_blind_catches.py` is a **ratchet**: the count
may go down and must not go up. And `pg_temp.check_refused(label,
statement, message_like)` is the thing to write instead — it requires
the statement to be refused, requires the refusal to be the one meant,
and refuses to count one of our own `P0004` assertion failures as a
pass.

Proved in place on `bank_accounts.sql`: `upsert_bank_account` has six
guards in a row, four of its refusals were blind, and deleting the
bank-or-cash guard now fails the file with *"it was not refused at
all"*. Before the change it passed.

### The foreign-currency engine: 21 of 41, then 36

Five functions: the rate lookup, the gain and loss accounts, the
realised difference on settlement, the revaluation, and its preview.
`fx_revaluation.sql` and `multicurrency.sql` pin the arithmetic — a
falling rate on a receivable is a loss, the run is idempotent, gains
and losses are stated separately rather than netted. Twenty mutants
lived anyway.

The revaluation walks the whole sales and purchase ledger and its
`where` clause has six conditions on each side. The fixtures hold **one
open foreign invoice each**, so five of those conditions had nothing on
the other side of them, and the entire PURCHASE half of the union had no
case at all.

**And one of those filters turned out to be load-bearing in a way
nothing had noticed.** `d.currency <> v_base` looks like an optimisation:
a ringgit document restated at a ringgit rate of one moves by nothing.
Except that **nothing normalises the rate on a base-currency document**.
An invoice in ringgit will happily carry an exchange rate of 4.50 —
posting does not object, because for a base-currency document the rate
is never read. Except here. Without the filter that invoice is
"revalued" from 4.50 to 1.00 and RM3,500 of loss appears from nowhere.
The fixture now proves the stray rate is storable, and then proves the
filter catches it.

**A rerun out of order.** Two mutants — the already-reversed filter, and
the ordering of the standing-revaluation lookup — can only be told from
the right code when the newest revaluation on file is one that has
already been undone. That happens when a bookkeeper reruns a prior
month: March, then February, then March again. Nothing in the suite had
ever run them out of order.

**A twin covered on one side.** `realised_fx_on_settlement` has the same
loop twice, once for receipts and once for payments, and the fixtures
settle one invoice with one receipt. Both `where a.<id> = p_settlement_id`
filters were unasserted; two customers paying on the same day would
have had each other's exchange difference booked against them.

#### The five equivalent mutants

| Mutant | Why it cannot matter |
|---|---|
| `if v_rate <= 0` deleted, and weakened to `< 0` | `exchange_rates_rate_check` is `rate > 0`; the table will not hold such a rate. The fixture asserts the constraint. |
| `coalesce(d.exchange_rate, 1)` → `, 0)` | `exchange_rate` is NOT NULL with a default of 1 on all four document tables. The fixture asserts the nullability. |
| the standing-revaluation ordering flipped | Only visible with two un-reversed revaluations at once, and each run reverses the one before it. The fixture asserts that invariant. |
| `d.balance_amount <> 0` dropped | A settled document contributes `0 × rate - 0 × rate`, and the `having ... <> 0` removes the row. |

Four of those are the same move for the sixth time: **a survivor that is
equivalent because of a rule enforced elsewhere is answered by asserting
that rule.**

### The aged listings: 20 of 42, then 38

`aged_balances.sql` does the hard part. It foots the listing against the
control account, and it pins all four bucket boundaries from both sides
— the last day inside a column and the first day outside it. Every
bucket mutant died on the first pass.

Everything else lived, and all of it was about **what is on the listing**
rather than which column a row lands in. A settled invoice, an
unallocated receipt, a voided receipt, a credit note half used, a
settlement discount, a foreign invoice: each is an ordinary row, and
each of the two reports has a `where` clause that exists to keep it off
or a piece of arithmetic that exists to net it down.

**The two reports are one function written twice.** The tail —
`round`, `days_overdue`, the bucket ladder, the ordering, the
membership filter — is word for word the same in both. Nine mutants
were therefore applied to each, and the payables half failed every one
the receivables half failed, for the same reason: the fixtures exercise
receivables. That is also how, as `aged_balances.sql`'s own header
records, "every division on the payables side came to be movable".

**The one that would have cost the most.** `and r.status <> 'void'` on
the ALLOCATIONS join, not on the receipt arm. Voiding a receipt has to
give the invoice back; without that condition the allocation still
settles it, the invoice drops off the listing, and a real debt is owed
by nobody. The fixture voids a receipt and asserts the invoice returns
at its full RM3,000.

**A credit note keeps its full total in `balance_amount` however much of
it has been used**, so how much is LEFT can only be worked out from the
allocations. RM2,000 raised and RM1,200 applied is RM800 of credit —
and a mutant standing it at RM2,000 for ever understates the debtors by
twelve hundred.

**And a settlement discount can only be written through its own
function.** `allocation_discount_guard` refuses a discount written
straight into an allocation, because taking it off the document without
taking it off the ledger overstates the control account for ever. The
fixture goes through `allocate_with_discount`, inside the ten days the
terms allow, which is the only window in which the discount exists.

#### The four equivalent mutants

| Mutant | Why it cannot matter |
|---|---|
| `round(d.outstanding, 2)` deleted, on both reports | Every figure the subtraction touches is `numeric(18,2)` — six columns across five tables — so the difference cannot carry a third decimal. The fixture asserts all six scales. |
| the `doc_type in (...)` filter dropped | The list is word for word the list in `post_sales_document_internal`, and the next condition is `gl_entry_id is not null`. Nothing outside those four can ever reach the ledger. The fixture asserts the pairing by refusing each of the other four types at the ledger door. |
| `a.org_id = p_org_id` dropped from the allocations | A foreign allocation names a foreign invoice, and the outer query only asks for allocations against documents in this organization. The `0512` composite keys make the cross-company row unstorable anyway; the fixture asserts both keys. |

Seventh time the answer to an equivalent mutant has been **assert the
rule it depends on** — and the second time (after the depreciation
`accumulated_depreciation_at` / `months_held` pair) that the rule turned
out to be *two lists in two files having to stay identical*, which is
exactly the kind of agreement nothing re-checks.

### Group consolidation: 17 of 37, then 31

`group_consolidation.sql` carries the assertion that matters most — the
eliminations sum to zero — and pins the four directions an adjustment
can go in. Twenty mutants lived anyway, and all of them were about the
SELECTION rather than the arithmetic.

`app.group_intercompany_lines` is one query with eight conditions on it,
and the fixture posts one pair of entries between two companies in one
group on one day. An entry outside the period, an unposted entry, a
customer linked to a company outside the group, a company linked to
itself, a bank line carrying a contact: every one is a row that query
exists to exclude, and none had ever been written.

A consolidation that eliminates the wrong thing **does not fail
loudly**. It produces a balanced set of accounts that is wrong by
whatever was taken out, which is the one error an auditor cannot see by
looking.

**Two companies is the smallest group and it is not enough.** With two,
"the pair that reconciles" and "any pair" are the same set. With three —
a holding company and two trading subsidiaries, which is what a group
actually is — they come apart: A's reconciled balance with B would carry
A's *unreconciled* balance with C out of the accounts with it,
eliminating four hundred ringgit of revenue the group really did earn.

**Two membership checks that mask each other.** `app.group_orgs` filters
both the company asked about and each company returned, and somebody in
neither is stopped by either — so a stranger cannot tell them apart. The
person who can is a member of ONE company in the group: a subsidiary's
bookkeeper, who must not be able to read the group's list from the
parent's id and, through the reports built on it, the parent's ledger.

**And a `limit 1` with no `order by` made the fixture lie.** Two
`select id from accounts where account_type = 'revenue' … limit 1` calls
in one test returned *different* accounts, so an invoice and its credit
note landed on different codes and did not cancel. The same shape as
`test_user()`'s ordering bug recorded in `_helpers.sql`: a fixture whose
identity is decided by physical row order is a coin toss.

#### The equivalent mutants, and a pair that hides itself

Four are ordinary: a company with a null `group_id` is excluded by
`null = <group>` being null rather than by the `is not null` test; a bank
line's category `case` returns null, so its group sums to null and the
`having … <> 0` drops it; a `left join` to contacts leaves
`linked_org_id` null, and `null in (…)` is null.

The fifth and sixth are the interesting ones and they are **a mutually-
masking pair**, the fourth this campaign has found:
`app.group_eliminations` groups by account code, and its only consumer
re-groups by code and sums. Widen the inner grouping and the outer sum
undoes it; weaken the outer `sum` to `max` and the inner grouping has
already left one row. Neither is dead. The rule that makes both
equivalent is that **one account code gets one adjustment**, and that is
what the fixture now asserts.

## The recurring engine — schedules, snapshots and what they raise

Ten functions: `app.advance_schedule`, `app.snapshot_document`,
`app.advance_recurring_document`, `app.raise_recurring_document`, the
two nightly runners, their two per-organization twins,
`public.create_recurring_document` and
`public.update_recurring_template`. A mutation sweep of 105 one-line
mutants killed 52.

**The tests were built on one shape and it was the wrong one to stop
at.** Both existing files bill a monthly ringgit retainer, and almost
everything that survived was a case that is not that: a dollar retainer,
a company that does not keep its books in ringgit, a viewer who may not
post, a document with no lines on it, a standing journal rather than a
standing invoice.

**A mutant that hangs is not a mutant that passes.** `M15` replaces the
`exit;` in `advance_recurring_document`'s failure handler with `null;`.
The loop then retries the same failing schedule for ever — `v_n` is only
incremented on success, so the `exit when v_n >= 60` runaway guard never
fires — and the existing fixture *does* reach it, using a closed period
as the failure. It simply hangs instead of failing, which in CI is a job
that never returns rather than a red assertion. The sweep harness now
sets `statement_timeout`, and the code comment that says this is exactly
why the `exit` is there turns out to be load-bearing and correct.

#### The equivalent mutants

Three survive the finished file, and all three are equivalent because
of a NOT NULL somewhere else. Three more were equivalent for the same
kind of reason and are listed with them, because the branch is still
there to read. Answering a survivor by asserting the rule it leans on
is now the standard move, and this sweep used it six times:

| Mutant | Why it is equivalent | The rule now asserted |
|---|---|---|
| `coalesce(o.status, 'active')` → `o.status` in the nightly sweep | `organizations.status` is NOT NULL with a default of `'active'` | the column cannot be given a null |
| `greatest(coalesce(v_due - v_doc_date, 30), 0)` → drop the `greatest` | a negative gap needs a document due before it was raised, and `0385` put a trigger on both document tables refusing that | a document cannot fall due before it was raised |
| the `else` arm of `app.advance_schedule` (unknown frequency → monthly) | both tables CHECK `frequency` against the same five words | no schedule can carry a frequency the calendar does not know |
| `if p_from is null then return null`, and `next_run_date is not null` in the journal runner | `next_run_date` is NOT NULL on both tables | a schedule always has a next run date |
| `coalesce(v_header ->> 'currency', 'MYR')` | `sales_documents.currency` and `purchase_documents.currency` are NOT NULL, and the snapshot names `currency` unconditionally | every document has a currency, and every snapshot carries one |
| `coalesce(v_base, 'MYR')` | `organizations.base_currency` is NOT NULL | every company has a base currency |

The fifth is different and worth naming, because it looks load-bearing
and is not. `r.auto_email and r.kind = 'sales' and r.auto_post` — remove
the `kind` test and a schedule for a BILL still cannot mail the
supplier, because `app.queue_document_email` reads `sales_documents` by
the id it is given and returns null when there is nothing there. A
bill's id is never in that table. So the test is a belt over a brace,
and what the fixture pins is the brace: the queue refuses a document
that is not a sales document, quietly, rather than queueing a message
about a bill.

Two further survivors were already recorded by the previous sweep of
this code and are not counted again: `is_active` and `next_run_date <=`
are each checked in both the runner and the worker, so each hides the
other's mutant.

#### Three survivors that were the fixture's fault, not a gap

Worth writing down because each looked like a finding and was not, and
the shape recurs:

* **`coalesce(p_auto_post, false)`.** The parameter's own SQL default is
  already `false`, so a call that omits it never reaches the coalesce —
  the assertion was testing the signature rather than the body. The
  caller that does reach it sends an explicit null, which is what an
  unset checkbox serialises to.
* **Two arms of one function need two assertions.** The line-identity
  check landed on the purchase snapshot only; the sales arm is a
  separate query with its own `- 'id'` list and its mutant lived.
* **The wrong twin.** `app.run_recurring_journals` and
  `public.run_recurring_journals_for` are the same body written twice,
  and every assertion drove the second. Five mutants in the first
  survived a file that appeared to cover them thoroughly. This is the
  third time this campaign has met a duplicated function where the
  unattended copy is the one with no coverage — after the two aged
  listings and the two document runners.

## Paying several companies' invoices with one transfer

`record_group_payment`, its line parser `app.group_payment_lines`, and
`report_group_trial_balance`. A mutation sweep of 63 one-line mutants
killed 35, and `group_payment.sql` deserves the credit: both permission
checks, all three grouping keys, the overpayment guard from both sides
and the duplicate-document check all died on the first pass.

**What lived was one fixture decision with four consequences.** `gp_org`
gives every company exactly ONE customer, ONE supplier and ONE bank
account, every figure is a whole number of ringgit, and every payment is
made today. So:

* with one document per payer, `sum(amount)` and `max(amount)` are the
  same number, and the figure banked was never really asserted
* with one contact per company, the allocation loop's
  `contact_id = g.contact_id` had nothing to cross, on either side
* with one bank account, three of the four conditions on the default
  fallback were unasserted — including that a CLOSED account must not
  take the money
* and paying today made `p_paid_on` and `current_date` the same date, so
  the receipt's date, the allocation's date and **the day the exchange
  rate is read on** could each be swapped unnoticed. Reading today's
  4.80 instead of the day's 4.10 conjures RM700 of difference from
  nowhere.

#### The equivalent mutants

Three survive the finished file.

`coalesce(p_lines, '[]'::jsonb)` is belt over two braces:
`record_group_payment` refuses a null payload several lines before the
parser runs, and `jsonb_to_recordset` is strict anyway — given null it
returns no rows rather than raising.

The other two are **a mutually-masking pair, the fifth this campaign has
found**. The parser rounds the discount to the sen; the overpayment
guard rounds the sum it compares. Each hides the other: the parser
rounds before the guard sees anything, and the guard rounds the sum
regardless. What is stored is rounded again by
`payment_allocations.discount_amount`'s own scale. The rule underneath
all three is one rule — money is kept to the sen in the columns as well
as in the arithmetic — and that is what the fixture asserts.

The amount's rounding is NOT equivalent, and the difference is worth
recording. One line of RM333.333… is rounded by the column and nothing
shows. THREE lines are not: rounded first they come to RM999.99, left
alone to RM1,000.00 — so the receipt would be banked a sen larger than
the allocations that make it up, and an invoice settled by money nobody
transferred. Same blind spot the withholding sweep recorded: a column
with a scale hides a missing `round` until something adds the parts up.

#### And one thing that is not a bug but should be written down

`g.bank is distinct from g.bank_hi` cannot differ from a plain `<>`,
because both sides come from `min()` and `max()` over the same column
and aggregates ignore nulls — one side can be null only when both are.
The consequence is a product decision nobody has stated: when one line
of a company's share names a bank account and another leaves it blank,
no refusal is raised, and the named account takes that company's whole
share. The fixture pins it so it is a decision rather than a discovery.

## The drawer at close of day

`open_pos_shift`, `close_pos_shift`, `resume_pos_shift`,
`app.pos_expected_cash` and `expire_loyalty_points`. A mutation sweep of
56 one-line mutants killed **15** — the weakest coverage this campaign
has found, on the arithmetic that decides whether a cashier is accused
of being short.

**The existing files prove the good path and never get it wrong.**
`pos_counting.sql` and `pos.sql` between them do a float, a cash sale, a
count, a close and the `counting` state in between, thoroughly. What
neither does is produce a variance that is not nought — so which way
round `declared - expected` reads was never pinned, and `abs()` was
invisible. Nothing had ever set `variance_tolerance` at all, so the
whole ladder above it was one branch nobody had walked.

The shape that would have been silent is a SHORTFALL. A shortfall is a
negative, and a bare `> tolerance` never fires on a negative however
large: a till RM500 short closes itself while a till RM6 over needs a
manager.

#### Two things about writing these fixtures

**A bare `viewer` role is not a restricted user here.**
`app.module_access` returns `'write'` to any member with no
`access_type_id` — which is right, and means a restriction has to be
built as an ACCESS TYPE with the module set to `read`. Three permission
assertions passed for the wrong reason before this was found.

**`pg_temp.sign_out()` does not restore the owner.** It clears the JWT
claim entirely, so `auth.uid()` is null and everything after it runs as
nobody. `sign_in_as(pg_temp.test_user())` is what puts the owner back.

#### The equivalent mutants

Six survive the finished file.

Two are rounding: `round(p_declared - v_expected, 2)` and
`round(v_float + v_cash, 2)` each have a column with a scale under them.
Third time this campaign has met that shape, after the withholding tax
and the group payment, and the answer is the same — assert the scale.

`and sa.status = 'completed'` in the expected-cash sum reads like it is
keeping voided sales out of the drawer, and it cannot be: a paid bill
cannot be voided at all (`void_pos_sale` refuses and says to raise a
credit note), so the only sale that can reach `voided` is a PARKED one,
which has no tenders. The rule is asserted from both ends.

Three are in the loyalty expiry, and two share a reason worth naming.
`coalesce(max(e.created_at), a.joined_on)` in the `HAVING` has a
fallback that cannot change an answer: an account with NO entries is the
only one that reaches it, and a balance is the sum of its entries — so
it is nought, and `if v_balance <= 0 then continue` skips it two lines
later. Every account the fallback uniquely admits has nothing to expire.
Likewise a programme with no dormancy months returns early and would
return nothing anyway, because `make_interval(months => null)` is null
and `last_at < now() - null` is null, which no row satisfies.

The sixth is `<` rather than `<=` on the dormancy boundary. It needs a
card whose last activity is the same MICROSECOND as the cutoff — a
coincidence rather than a case somebody can be in, and no fixture can
produce it reliably.

## The customer portal — the one door somebody who is not staff holds a key to

`open_customer_portal`, `portal_document_token`,
`share_customer_portal`, `revoke_customer_portal` and `app.portal_url`.
A mutation sweep of 59 one-line mutants killed **17** — the worst result
of this campaign, on the only function in the system granted to `anon`.

**Two findings were serious enough to name.** `share_customer_portal`
revokes the previous link with
`where contact_id = p_contact_id and revoked_at is null`. Scoped to
nothing, sending one customer a portal link revokes EVERY PORTAL ON THE
PLATFORM. Scoped away entirely, the old link stays live beside the new
one — and re-issuing is how somebody takes back a link that went to the
wrong address. The function's own comment states the rule ("a revoke
that leaves an older door open is not a revoke") and neither half of it
was asserted.

**And a cross-tenant hole that is real because of a missing constraint.**
`contacts.party_id` links a customer filed twice (`0477`). It is a bare
uuid: no foreign key, nothing scoping it to a company. So a contact in
ANOTHER company can carry this company's party id, and
`c2.org_id = l.org_id` is what stands between that and a portal token
minting a link to a stranger's invoices. The fixture builds that
impostor.

#### Two mutually-masking pairs — the sixth and seventh

Both are one tenancy rule written twice, which is exactly why they mask.
`portal_document_token` refuses a document unless `d.org_id = l.org_id`
AND its contact is found by a lookup that itself filters
`c2.org_id = l.org_id`. Remove either and the other still refuses: the
lookup starts from `c2.id = d.contact_id`, so once the document is in
this company its contact is too. Only removing BOTH opens the door.
`open_customer_portal`'s listing has the identical pair.

Neither is dead code. They are two spellings of the same rule, and what
the fixture proves is the PAIR — by building the thing that would get
through if the rule were absent.

#### The rest of the equivalents

| Mutant | Why it is equivalent | The rule now asserted |
|---|---|---|
| `c.id is null then 'withdrawn'` | `customer_portal_links.contact_id` is a foreign key ON DELETE CASCADE, so a link cannot outlive its customer — deleting the contact deletes the link, and the token reads `invalid` | the cascade |
| `coalesce(o.base_currency, 'MYR')` | the column is NOT NULL | third time this campaign |
| `d.doc_type = 'invoice'` in the listing | the status filter already admits only `posted`/`partial`, and a quotation cannot reach either — the ledger door refuses it | a quotation cannot be posted |
| the minted link's `l.org_id` | the guard four lines above has already established `d.org_id = l.org_id` | one company per link |
| `c.party_id is not null` | `c2.party_id = null` is NULL, not true, so the arm cannot match anyway — the guard says out loud what three-valued logic does quietly | a null equals nothing, including a null |
| `revoked_at is null` in the revoke's `where` | re-revoking a shut door changes no answer; it keeps the audit trail saying when it was closed rather than last re-closed | the state is unchanged |

#### And a note on testing time inside one transaction

`now()` is the TRANSACTION's clock, so three visits to a portal share a
timestamp and `opened_at` cannot be told from `last_opened_at` by
waiting. Backdating each in turn is what separates them: one is
`coalesce`d and must not move, the other is assigned and must. The same
trick pins the expiry boundary — a second either side cannot tell `<`
from `<=`, but `expires_at = now()` can.

---

## The group trial balance, and the consolidated e-Invoice run

`report_group_trial_balance` is the number a group's directors read, and
`consolidate_pos_einvoices` is the return a shop files with LHDN. A
sweep of 40 one-line mutants across the two killed 19.

What lived was **the arithmetic**, and for one reason: the fixture
behind the group report posted a single entry in a single company. With
one row per code there is nothing to add up, so `sum` and `max` return
the same number, `count(*)` and `count(distinct code)` return the same
number, `min(name)` and `max(name)` return the same name, and grouping
by code is indistinguishable from grouping by code and name. **A report
that showed the largest subsidiary's turnover in place of the group's
would have passed every assertion in this repository.** Nor was the
period ever varied: `p_from` and `p_to` were passed through untouched,
so a report that ignored both and totalled everything up to today read
exactly the same.

The consolidation had the mirror-image gap. One company, one
consolidation, one run — so every `where` clause that says *this one*
was untested for want of a second one to confuse it with.

`supabase/tests/group_trial_balance_shapes.sql` builds two companies
whose figures deliberately differ (700 against 300, openings of 100
against 400, one account code carrying two different names), an account
whose only content is a balance brought forward, a pair of openings that
cancel across the companies, money that moved before the period and
money that moved after it. `pos_einvoice_consolidation.sql` gains the
shop next door's own return, this shop's empty return for last month, a
consolidation that has been drawn up but not sent, and a sale taken out
of the return and put back.

**38 of 40 now die.** Both survivors are equivalent.

#### A mutually-masking pair — the eighth this campaign

`report_group_trial_balance` opens with `app.is_org_member(p_org_id)`.
Deleting it opens nothing: `app.group_orgs` carries the same check, so
the group comes back empty and the report refuses one line later with
*this company is not in a group*. Two guards, each hiding the other's
absence — and only the WORDING tells them apart. A person who belongs to
another company in the same group is told to go and fix a group
membership that is perfectly correct.

So the assertion is on the message, through `pg_temp.check_refused`,
which is the argument for wording two guards on one path differently
rather than for asserting less.

#### The two equivalents

| Mutant | Why it is equivalent | The rule now asserted |
|---|---|---|
| dropping `round(..., 2)` from the group's sums | every figure it adds up has already been rounded to two places by `report_trial_balance`, and `gl_lines` holds sen in `numeric(18,2)` besides | that no figure arriving from `report_trial_balance` has a scale above 2 |
| widening the totals update from `c.id = v_con` to every consolidation of the company | the two subqueries are correlated on `c.id`, so each row is rewritten with the figures it already had — a wasted update, not a wrong one | already recorded in that file's own header; the fixture keeps the two months' returns apart regardless |

---

## Selling an asset, and the note that says so

`dispose_fixed_asset` is the only place in this system where an asset
leaves the balance sheet, and `report_asset_movements` is the fixed
asset note an auditor reads. A sweep of 71 one-line mutants over those
two, `app.disposal_account` and `report_depreciation_history` killed 43.

**One survivor was a crash**, and it is written up in migration `0532`.
The fixture set out to prove that a retired 6510 is not silently reused
for this year's loss on disposal, and the disposal did not post at all:
`accounts_org_id_code_key` is a plain UNIQUE (org_id, code) and knows
nothing about `deleted_at`, so a lookup that filters deleted rows can
never find the account and the insert can never succeed. Five helpers
had that shape. They revive the retired account now.

How reachable it is, stated exactly: `retire_account` refuses every code
in `app.posting_account_codes()`, and 6510, 4930, 3900, 4840 and the
property codes are all in it — so the product's own button cannot get
you there. `public.accounts` carries a plain `accounts_update` policy
allowing `app.can_post(org_id)`, so anybody who may post the books can
set `deleted_at` on the table directly through PostgREST, which is the
same door the app is built on. An import or a restore is the other way
in.

The rest of what lived was of three kinds.

**The account a disposal creates.** Every existing assertion checked
which account the money landed in and none checked what kind of account
it was. A loss on disposal filed as `revenue` under Sales would have
passed the whole suite, and it does not show up as a wrong number — it
shows up as a profit and loss where the loss on disposal has been added
to turnover.

**The accounts an asset carries its own.** `asset_account_id`,
`accumulated_account_id` and `expense_account_id` were null on every
asset in every fixture, so three `coalesce`s were doing nothing
observable and a company filing its motor vehicles apart from its plant
would have had the whole disposal posted to the wrong three accounts.
Note the shape that hid one of them: the catch-up CREDITS the
accumulated account and the disposal DEBITS it straight back, so its net
on that journal is nought whichever account was used. The fixture asserts
the two sides separately, and that the fallback account has no line at
all.

**Every boundary in the note.** Four dates, eight comparisons, and a
fixture that bought on the first of a month and sold on the last of
another — so nothing ever landed ON a boundary and `<` could not be told
from `<=`. An asset sold on the last day of the year is the ordinary
case, not a corner one.

**69 of 71 now die.** Two are equivalent.

| Mutant | Why it is equivalent | The rule now asserted |
|---|---|---|
| dropping the `greatest(..., 0)` floor from the disposal catch-up | `v_catchup` is only ever read as `> 0`, and a negative fails that test exactly as a floored nought does | that an asset already written down further than the formula says is charged nothing on the way out, and leaves no depreciation run behind it |
| dropping `deleted_at is not null` from `app.revive_account` | every caller looks for a live account first and only reaches the revive when there is none, so there is no live row for the widened `where` to match | that a second disposal finds the account already on the chart, and that there is still only one of it |

#### And a wart in the note, recorded rather than fixed

`report_asset_movements` takes a disposal's accumulated depreciation
from the figure FROZEN ON THE ASSET, and takes the opening and closing
accumulated from `app.accumulated_charged_at`, which reads
`depreciation_entries`. The two agree for an asset this system
depreciated from new. They do not agree for an asset keyed in carrying a
balance from a previous system: nothing ever charged that balance, so it
is in `fixed_assets.accumulated_depreciation` and not in any entry, and
the note's brought-forward accumulated is understated by it while its
disposals column is not. The movement identity
`accum_closing = accum_opening + charge - disposals_accum` does not hold
for such an asset.

Nothing in the app writes `accumulated_depreciation` today — there is no
field for it on the asset editor — so this is reachable only by writing
the column directly. It becomes a real problem the day an asset importer
lands, which is the reason for writing it down now.

---

## The statutory calendar: what SSM is owed, and when

Seven functions carry the Companies Act's dates — `app.corp_fye`,
`corp_open_filing`, `corp_mark_lodged`, `corp_upcoming_filings`,
`fs_deadlines`, `app.fs_lodge_by` and `report_fs_deadlines`. A sweep of
69 one-line mutants killed 50. What lived was of three kinds.

**The financial year end itself.** `app.corp_fye` is four nested date
functions turning "our year ends on the 31st of February" into a date
that exists, and nothing had ever called it directly. Every test reaches
it through `corp_upcoming_filings` with a year end of 31 December —
the one date on which `least(day, days-in-month)` and `greatest(...)`
agree, and on which a missing day and a day of 31 are the same day. A
company whose year ends in February is what tells them apart.

**What a refusal says.** Four guards on `corp_open_filing` and five on
`corp_mark_lodged` are each followed by another that raises for a
different reason, so deleting the first one still refused and the
assertion still passed. A filing that does not exist was refused with
"not permitted" — which sends a secretary to ask for permission she
already has. Every refusal in the new file is asserted on its message.

**What happens to a filing that is already done.** Opening a filing
twice is ordinary; the same event gets noticed again. The second call
must not put a lodged return back into preparation, and marking one
filing lodged must not mark the practice's others. Neither was asserted,
because the fixture held one filing.

**66 of 69 now die.** Three are equivalent.

#### A ninth masking pair — this one a subsumption

`corp_upcoming_filings` keeps `d.trigger_date >= e.incorporated_on`
inside `year_ends`, and `c.trigger_date > (select incorporated_on)` in
the outer `where`. The second is strictly the stronger of the two, so
deleting the first changes no answer at all — unlike the mutual pairs
earlier in this campaign, where each hid the other. What separates them
is a company whose year end falls exactly ON the day it was
incorporated, and only the outer guard decides that one. The fixture
builds it: a company incorporated on 30 June with a 30 June year end did
not trade for a year that lasted no days.

#### And two dead arms, named so a reader need not work them out

| Mutant | Why it is equivalent | The rule now asserted |
|---|---|---|
| `trigger_kind in ('fye', 'agm')` narrowed to `('fye')` | no filing type in the catalogue has kind `'agm'` — the annual general meeting is filed under `'fye'`, because it is the year end that triggers it | that no filing type is triggered by an AGM, and that several are triggered by the year end |
| `coalesce(v_public, false)` in `fs_deadlines` | `organizations.entity_type` is NOT NULL and `fs_filings.org_id` is a foreign key to it, so the lookup always finds a row and always answers true or false | both of those, read off the catalogue |

#### A note on building a date test that holds every day of the year

The 365-day floor on year-end filings cannot be reached with the Act's
own 180 and 210 days: the generator offers only last year's year end and
this year's, and last year's deadline lands inside the window on most
days of the year. Anchoring the fixture on "today minus something"
produces a test that passes in September and fails in February.

What works is a company whose year ends on **1 January** and a filing
type due **one day before** its own year end. Last year's deadline is
then 31 December of the year before that — always more than a year ago —
and this year's is 31 December of last year, the last day of the
twelve-month window and so always inside it. Neither depends on when CI
runs. The filing type is not a real form, and the file says so: what is
being asserted is the report's floor, not the Act.

---

## The leave year: entitlement, the roll, and what expires

Seven functions decide what every employee is owed and what carries into
next year. A sweep of 77 one-line mutants killed 46, and **almost the
whole of two functions lived**.

**`app.roll_leave_year` is the annual job that decides what everybody
has**, and nine mutants survived on it, because nothing had ever called
it with a previous year worth carrying. A resigned employee got next
year's entitlement; a retired leave type got a fresh row; and the
carry-forward could drop any one of its four terms — entitlement, last
year's own carry, an adjustment, and what was taken — with the suite
green. Leave liability is money, and a carry that quietly counts leave
already taken is money the company does not know it owes. The fixture
gives the four terms four different non-zero numbers (10, 3, 2, 4) and a
cap wide enough not to hide them, so dropping any one gives 8, 9 or 15
against the right answer of 11.

**`app.leave_entitlement` reads the Act's bands**, and five lived: a type
that does not scale looking its days up in the bands anyway, an employee
hired after the year being asked about getting negative service, the
LOWEST matching band winning instead of the highest, a scaling type with
no bands returning null rather than its own days, and one leave type
reading another's bands.

**The bands themselves.** `apply_statutory_leave_bands` writes the First
Schedule to the Employment Act 1955. The DAYS were asserted — 8, 12, 16
for annual leave and 14, 18, 22 for sick. The YEARS the bands run
between were not, and they are half the rule: s.60E(1) reads "less than
two years", "two years or more but less than five", and "five years or
more", so the top band has no ceiling. A ceiling on it is an employee of
twenty years' service falling off the end of the schedule.

**74 of 77 now die.** Three are equivalent.

| Mutant | Why it is equivalent | The rule now asserted |
|---|---|---|
| `least(taken_days, carried_forward)` reduced to `taken_days` in the expiry sweep | a row is only selected when the carry EXCEEDS what has been taken, and on those rows the two expressions are the same number | a balance with more taken than carried is not swept at all, and its carry is untouched |
| `coalesce(max_carry_forward, 0)` given any other fallback | the column is NOT NULL with a default of nought | both of those — and that a leave type nobody has set a limit on carries nothing, because silently rolling everything forward is how liability grows unnoticed |
| `v_available is not null and ...` reduced to the comparison alone | `12 > null` is NULL and plpgsql treats a null condition as false, so the comparison already lets the request through | the behaviour that depends on it: a company that has not set an entitlement for a type and a year can still file leave on the day it starts |

#### A fixture that proved nothing, and why

The first version of the tenancy assertion — "the roll opens no balance
for the company next door's employee" — stood the neighbouring company
up AFTER calling the roll. It passed against the mutant with `org_id =
p_org_id` deleted, because a roll that swept every employee on the
platform still would not have found somebody who did not exist yet.
Building the other company first is the whole assertion.

---

## Bringing a company's books across

`import_opening_balances` and `import_opening_stock` are how every new
customer's ledger arrives, and an opening balance that is wrong poisons
everything posted after it. A sweep of 74 one-line mutants killed 57,
and what lived was of two kinds.

**Which row the lookup finds.** Both functions match a code from the
file against the chart or the item list with `lower(x) = lower(y)`, and
every fixture types the code exactly as it stands on file — so the
lowering was doing nothing observable, on both sides of the comparison
and on the duplicate check as well. A migration file is exported from
somebody else's system: it is the one place in the product where the
codes were NOT typed by the person who made them, and the case is
whatever that system used. Nor was the lookup's tenancy tested. With
`org_id` deleted, a file could name an account, an item or a warehouse
belonging to another company on the platform and be told it was fine.

**And what counts as already done.** An opening balance is brought in
once, and the guard that says so is four conditions long: the right
source, the right source table, posted rather than drafted, and not
already reversed. Only the last was asserted, because `0525` was written
for it. A draft opening balance blocking the real one is a migration
nobody can finish, and a journal filed against the same record from a
different source is not an opening trial balance at all.

**73 of 74 now die.** One is equivalent: `import_opening_stock` asks
whether an item has already moved with `m.org_id = p_org_id and
m.item_id = v_item_id`, and dropping the first condition changes no
answer, because `stock_movements_item_same_org` holds a movement's item
to the movement's own company. The constraint is asserted in its place.

#### Two assertions that passed for the wrong reason

Worth recording, because both looked right and neither was.

The duplicate-code check lowers the code on the way INTO the list of
what has been seen as well as on the way out of it. A file spelling the
code `fx-1` and then `FX-1` is caught either way — lowering one end is
enough. It is `FX-1` and then `fx-1` that separates them, so the ORDER
of the two rows is the whole assertion.

The bank-balance resync is scoped `b.org_id = p_org_id`, and the first
version of the tenancy test set the neighbouring company's balance to a
figure nothing could arrive at and then had that company import its own
books — which moved it legitimately. The company whose figure must not
move is one that has imported nothing at all.

---

## Which batch left, and which batch came back

`app.materialise_movement_lots` decides which batch or serial number
every movement of a tracked item is against, and `app.pick_lots_fefo`
decides which one goes out when nobody has said. Between them they are
the whole of batch traceability: a recall, an expiry date on a shelf,
and the cost a sale is charged at all read off what those two wrote.

A sweep of 44 one-line mutants killed 20 — **the worst result of this
campaign, on stock that people eat.**

**One survivor was a live defect**, written up in migration `0533`: the
credit-note loop ordered by `m.created_at desc, sml.lot_id`, and
`sml.lot_id` is a random uuid. Across two sales `created_at` decides;
WITHIN one sale it ties, because a line that spans two batches writes
both against one movement. Which batch a return went back to was
therefore decided by `gen_random_uuid()`. A sale of five that empties a
three-unit batch and starts a ten-unit one is the ordinary case, and
half the time the return reopened the batch that had been emptied and
closed — a closed batch with stock in it again is a batch somebody will
pick from, on a date already counted as gone. The order now mirrors
`pick_lots_fefo` exactly, in reverse.

The rest of what lived was of four kinds: the picker's own order and
scope (it had never been called directly, and the fixtures hold one
batch in one warehouse, so earliest-expiry-first could not be told from
latest, an undated batch had never been picked against a dated one, and
the warehouse filter had nothing to exclude); what a batch already on
file keeps (three `coalesce`s against the incoming null, and no fixture
had ever named the same batch twice); whose batches a return goes back
to; and what a conversion's output inherits.

**38 of 44 now die.** Six are equivalent.

| Mutant | Why it is equivalent | The rule now asserted |
|---|---|---|
| `v_track is null` dropped from the untracked guard | `items.tracking` is NOT NULL and defaults to `'none'` | both, read off the catalogue |
| the source-table half of each of the three `document_line_lots` arms | the three columns are foreign keys to three different tables, so a line id from one is never a line id from another and an arm reading the wrong column finds nothing | that all three foreign keys exist |
| `m.quantity < 0` on the transfer-arrival lookup | a transfer line is received once, so the only arrival is the row being written, whose own lots do not exist yet | that a transfer line arrives once |
| `+ excluded.quantity` reduced to `= excluded.quantity` on the return's conflict | the recipe depletion writes one movement per item per sale, so each batch appears once in the loop and the conflict never fires | that a sale takes each ingredient out on one movement |

#### Testing a random tie-break

The defect above cannot be caught deterministically by a fixture that
offers the loop two batches to choose between: a coin comes up right
half the time, and the test is then flaky rather than failing. What
works is raising the number of batches. The fixture holds **six**, one
unit each a month apart; a sale takes five and two come back, so a
random order has to guess the right two in the right order — one time
in twenty. The same six batches do a second job: the OTHER ingredient
on the sale expires between the two the return is owed, so a loop that
read every ingredient rather than this one reaches the wrong batch on
its second unit rather than never getting that far.

#### A gap found on the way, and not fixed here

A counter sale of a batch-tracked item cannot be completed at all. The
POS invoice writes a `sales_documents` delivery, that source is
deliberately kept out of the FEFO list, and nothing names lots on the
line — so `complete_pos_sale` raises. A recipe whose COMPONENT is
tracked works, because that movement carries `pos_sales`. So a pharmacy
or a mini-market with dated stock cannot ring a sale through the till.
The narrow fix is for the POS to name lots on the invoice line it
creates, which leaves the general refusal intact; it is a design
decision rather than a sweep fix.

---

## The inventory forecast, and the orders it drafts

`run_inventory_forecast` decides what every stocked item needs, and
`create_po_from_suggestions` turns that into documents sent to
suppliers. A sweep of 64 one-line mutants killed **10** — the worst
result of this campaign.

The reason is that the two orchestrators had never been tested as
orchestrators. `inventory_forecast.sql` checks the ARITHMETIC against
worked examples — safety stock scaling with the root of lead time, empty
periods counting as zero — and that a suggestion becomes a draft order
and does not become two. Behind it sits one company, one location, one
currency, five items all stock-tracked and active, and no purchase
history at all. So none of the following was observable:

- **Which items are looked at.** A service, a discontinued line and a
  deleted one were all forecast; an item the buyer had excluded was
  forecast anyway. Every parameter an item can carry of its own —
  method, window, alpha, service level, lead time — could be ignored in
  favour of the company default.
- **What the position is.** `available = on hand − reserved + on order`,
  with reserved and on-order nought throughout, so both signs could be
  flipped; so could the warehouse filter on the stock read.
- **Where the ladder's lines are.** Three of its comparisons are `<=`
  where `<` reads the same on every item not sitting exactly on the
  line, and nothing ever sat on one.
- **What the order says.** Neither permission check, the run it reads,
  the date it is expected, the currency, the payment terms, the
  warehouse on the line, and above all THE PRICE — read from the last
  purchase, from this supplier by preference, in this currency, not
  voided, not deleted. Five conditions with no history to get wrong.

`supabase/tests/forecast_order_shapes.sql` is 70 assertions. **60 of 64
now die.**

#### Standing an item exactly on a line

Three mutants need an item whose available position equals its safety
stock, its reorder point, or one review period above it. Those figures
are computed, so the fixture runs once to find out where the lines are,
sets the shelf to exactly each of them, and runs again.

That only works if the figures are exact. `mean_daily_demand` is stored
rounded to six places, and a partial first or last bucket makes the mean
a recurring decimal — so the computed threshold misses the real one by a
few parts in a million and lands on the wrong side. **The window has to
be whole buckets**: the run is asked for a Sunday, `history_days` is 69
rather than 70 (seventy days before a Sunday is another Sunday, which
leaves a one-day bucket on the front), and demand is five whole weeks of
one a day against five of nothing — a bucket mean of 3.5, a daily mean
of exactly 0.5, and a spread that is not nought.

#### Two runs in one transaction have no order

`create_po_from_suggestions` takes the latest forecast with
`order by r.run_at desc limit 1`, and `run_at` defaults to `now()` —
the TRANSACTION's clock. Two runs inside one test file share a
timestamp and the "latest" is then arbitrary, which is how the first
version of that assertion failed. In the product they are two requests
minutes apart, so this is a fixture problem rather than a defect; the
file backdates the first run by an hour to stand in for it.

#### What is left

| Mutant | Status |
|---|---|
| the forecast parameters', the stock read's and the price lookup's `org_id` filters | equivalent — each is joined on an item id besides, and an item belongs to one company; the three foreign keys are asserted instead |
| `app.measured_lead_time` ignored in favour of the settings default | **still alive.** Reaching it needs two complete order → bill → receipt chains so the median has two observations to work from. Worth building; not built here. |

## The public menu: the door a phone orders through with no account

`app.pos_menu_link`, `public.public_pos_menu`,
`public.public_pos_menu_modifiers` and `public.place_public_pos_order`
are the only POS functions granted to `anon`. A token typed into a phone
is the whole credential. A sweep of 71 one-line mutants killed **21** —
the worst opening result of this campaign, on the surface with the
widest reach.

`pos_public_menu.sql` is not the problem. It proves the assertion the
endpoint exists to make — a price arriving from a browser is ignored —
and it proves that an expired link, a retired one and a used single-use
one are all refused. What stands behind it is ONE company, ONE outlet,
ONE till, TWO items and ONE question, so every filter that separates one
shop from the next had nothing to exclude.

`supabase/tests/pos_public_menu_shapes.sql` is 47 assertions against a
second company next door with its own outlet, till and menu; four tills
the order must not land on, each excluded by a different condition and
all coded to sort before the right one; three items that are not on the
menu; a question the shop stopped asking, an answer it stopped
offering, and a question with no answers yet; and a table with somebody
else's bill on it. **66 of 71 now die.**

Two migrations came out of it.

**0534** holds `pos_menu_links.token` to `not null`. The lookup is
`where token = coalesce(p_token, '')`, and the `coalesce` is what stops
a caller who sends no token from being treated as a caller whose token
is null. It cannot be told apart from `token is not distinct from
p_token` today, because no row has a null token — but the column
permitted one and its unique index is no help, since a unique index
permits as many nulls as you like. A row in that state, by any route,
would be a shop's till reachable by an anonymous caller who sends
nothing.

**0535** is a masking pair, the tenth of this campaign, and the first
where the two guards are on the same path in the same function.
`place_public_pos_order` refuses an empty order twice — once for an
empty array, once if the loop added no line — and both said *There is
nothing in this order.* So the first could be deleted and no assertion
noticed, because the second raised the same words. The second is
unreachable as the loop stands, so its wording is one nobody should
read; naming it for what it would mean leaves the customer's sentence to
the first and gives a fixture two refusals it can tell apart. This is
exactly the case `pg_temp.check_refused`'s own note argues about: where
two guards word themselves identically the answer is to word them
differently, not to assert less.

### Equivalent mutants

| Probe | What it changes | Why nothing can see it |
|---|---|---|
| `L7` | `token = coalesce(p_token,'')` → `token is not distinct from p_token` | No row has a null token: the column defaults to eighteen random bytes and `upsert_pos_menu_link` never names it. **0534** now holds the column to that, and the fixture asserts the column is `not null`. |
| `N1` | `public_pos_menu_modifiers` drops `img.org_id = v_org` | `item_modifier_groups_item_same_org` holds the row to its own item's company, so `img.item_id = p_item` has already named the company. The constraint is asserted in its place. |
| `P15` | the channel case's `when 'delivery' then 'delivery'` → `'takeaway'` | Two lines later `set_pos_delivery` sets `order_channel = 'delivery'` itself when it is anything else, so the case arm is overwritten before anybody can read it. The rule — that a delivery is booked as one — is asserted, from the writer that actually decides it. |
| `P36` | the second empty-basket guard never fires | Unreachable behind the first: a non-empty array either adds a line or raises, so `v_n` cannot be nought. **0535** words it so that if it ever does fire it says something of its own. |
| `P48` | `select o.org_id into v_org ... where o.id = v_link.outlet_id` → `where o.id is not null` | A `select ... into` from a query returning several rows takes an arbitrary one, and no fixture can pin which. On this database it happens to take the shop under test, so the mutant is invisible; on another it would take a different company and every order would be refused. The boundary it guards is asserted from the other side: `P26`, another shop's item on this bill, dies. |

### The two refusals on the sold-out path, which is why P31 dies

`place_public_pos_order` checks `app.pos_item_off` itself and so does
`app.add_pos_sale_line_internal` two calls later. The outer raise says
the reason alone — `Habis` — and the inner one says the dish's name and
then the reason — `Nasi lemak: Habis`. That difference is the only thing
that makes the outer check assertable at all: a fixture catching
`check_violation` cannot tell which of them fired, and one asserting the
exact sentence can. Where the SSM sweep found guards worth wording
apart, this one found a pair already worded apart and used it.

## The appraisal guards: whose half of the appraisal is whose

`app.appraisal_change_guard`, `app.appraisal_goal_change_guard`,
`app.appraisal_part` and `app.appraisal_part_of` decide who may write
which column of a performance review. A sweep of 75 one-line mutants
killed **49** — the best opening result of this campaign, and it says
what it ought to about `appraisals.sql`, which asserts column by column
that the subject cannot write the manager's half.

What that file has no room for is anybody standing OUTSIDE the two
halves. Its cast is a manager, the person who reports to them, and the
owner — who is HR by virtue of owning the place. So the bottom of
`appraisal_part_of`, where somebody who is neither party and not HR gets
nothing at all, had never been reached: `return 'hr'` for everybody
passed every assertion in the file. The same gap covered the scale's
floor and ceiling on three of the five rating columns, the six-part rule
that an appraisal opens EMPTY, reopening a half and rewriting it in one
statement, and the two thirds of a goal's manager half that are not the
rating — the comment, and what actually happened.

`supabase/tests/appraisal_guard_shapes.sql` is 32 assertions with two
people the existing file has no room for: **Zul**, a member of the
company with a login and an employee record who is nobody in this
appraisal, and **Hana**, who runs HR and has an appraisal of her own.
**74 of 75 now die.**

### A probe that was not the rule

The first version of `C2` swapped the subject and reviewer lines at the
top of `appraisal_part_of`, on the theory that it tested the ordering
the function's own comment states — *somebody who is both HR and the
person being appraised is the person being appraised*. It does not: that
swap is invisible unless one person is both the subject and the NAMED
reviewer of the same appraisal, which the function's next comment
explains the product avoids. The mutant that tests the stated rule moves
the `can_manage_hr` check ABOVE the subject check, and that one was
already being killed by `appraisals.sql`. Worth recording because the
survivor list looked for a moment like a hole in the rule the comment is
proudest of, and it was a hole in the probe.

### Equivalent mutants

| Probe | What it changes | Why nothing can see it |
|---|---|---|
| `D1` | `appraisal_part` drops `if v_a.id is null then return null` | The early return cannot be observed, because every branch of `appraisal_part_of` falls through for a row of nulls anyway: nobody is an employee of no company, and nobody runs HR at one. The rule is asserted directly — `appraisal_part_of(null, null, null)` is nobody's. |

### The guards refuse before the foreign keys do

Both `if ... is null then raise` checks at the tops of these guards look
like belt-and-braces over a foreign key, and they are not: a row trigger
runs before the constraint, so an appraisal naming a cycle that is not
there is refused by the guard's own sentence rather than by a
`23503`. That is worth an assertion of its own — the guard says *An
appraisal belongs to a cycle*, and a fixture asserting the sentence
proves the guard fired rather than the key.

## The e-Invoice payload: what LHDN is actually told

`prepare_einvoice` takes a posted sales document and writes the snapshot
submitted to MyInvois. Every column it fills is a claim made to a tax
authority on the company's behalf. A sweep of 86 one-line mutants killed
**63** — the second-best defence in the codebase, and `einvoice_statutory.sql`
earns it.

What that file has no room for is a document with anything IN it. Its
fixture files one invoice, in ringgit, dated today, at a company whose
address, SST number and MSIC code are all null, to a buyer whose email,
phone and address are all null, with one line carrying no
classification, no unit, no tax code and no discount, and it is never
submitted twice. So every fallback had nothing to fall back FROM, and
every pair of adjacent columns of the same type could be swapped without
anybody noticing: the supplier's SST number and its MSIC code, the
buyer's email and phone, its state and its country, the line's tax RATE
and its tax AMOUNT.

`supabase/tests/einvoice_payload_shapes.sql` is 60 assertions against a
company filled in with no two fields alike, a buyer the same, a document
in dollars dated forty days ago with both header charges and a header
discount, and four lines arranged so that each link of every fallback
chain is the one that decides: one naming everything itself and no item
at all, one naming nothing whose item has a classification and a unit,
one whose item has neither, and one with no item and no unit so the last
link is reached. **84 of 88 now die.**

**0538 came out of it.** The resubmission upsert refreshed the amount
before tax, the amount after it, the tax, the rounding and the PAYABLE
AMOUNT — and not `total_charges` or `total_discount`, the two figures
that sit between them. So a shipping charge corrected between
submissions produced a header that contradicts itself: the payable
amount moved and the charge that moved it did not. That is exactly the
fault 0410 fixed from the other end, whose note reads *"Shipping alone
left the header not adding up: LHDN was told 113.00 for a bill of
123.00, measured rather than reasoned about."* A first submission was
always right; it is the second one that was wrong, and only for a
document somebody changed between the two — which is every document that
comes back rejected for a figure.

The buyer and supplier columns are still not refreshed, and should not
be: a snapshot is what was filed, and a customer who renamed itself last
week did not rename itself on an invoice issued last month. The fixture
gives each buyer its own document rather than swapping the contact
underneath one, because swapping proves nothing about a chain that is
only read at insert.

### Equivalent mutants

| Probe | What it changes | Why nothing can see it |
|---|---|---|
| `H5` | `coalesce(shipping,0) + coalesce(service,0)` → the bare sum | Both columns are `not null default 0` on `sales_documents`, so the sum is never null and the coalesce is defensive. The two NOT NULLs are asserted in its place. |
| `L9` | `round(quantity * unit_price, 2)` → no round | `einvoice_lines.subtotal` is `numeric(18,2)`, so the column rounds on the way in whatever the expression says. The scale is asserted instead. |
| `L21` | the `order by line_no` on the insert's select | Ordering the select feeding an insert orders nothing readable back: rows are a set, and `line_no` is stored so every reader sorts for itself. Asserted from the reader's end — four distinct line numbers reach the table. |
| `C1` | `when new.validated_at is null then null` → never | Null plus seventy-two hours is null, so the arm cannot be wrong. It reads as intent rather than as arithmetic, and the arithmetic is asserted. |

### A fixture note worth keeping

`prepare_einvoice` WRITES, so calling it inside a `where` clause runs it
once per row of the table being filtered. The first version of two
assertions here did exactly that and came back null. A function that
writes belongs on the left of an assignment.

## The other eight that post to a retired account

0532 fixed five helpers that reach for an account by code and make it if
the company has not got one, and recorded that eight more had the same
shape. This is those eight, and **they fail differently from the five,
and worse.**

The five looked for an account `where deleted_at is null`, found none,
and went on to INSERT — hitting `accounts_org_id_code_key` on the
retired row and crashing the whole posting. Loud, traceable, and it
stopped.

The eight have no `deleted_at` filter at all. They FIND the retired
account and return it, and the entry is posted to an account the chart
no longer shows. Nothing raises. The trial balance still balances,
because the entry really is there — it is on a row every screen filters
out. A company that tidied its chart last year is the population at
risk, and 2145 (Withholding Tax Payable), 2127 (Deferred Revenue) and
1140 (Cheques on Hand) are exactly what a company that has not needed
them yet would retire.

**0539** gives all eight 0532's shape: look for a live account of the
code, revive a retired one, insert only then. All thirteen helpers now
read the same way.

### Counting the class rather than the instances

`supabase/tests/account_revival.sql` is 85 assertions, and the one that
matters most is not any of the thirteen behavioural ones. It is this:

```sql
select count(*) from pg_proc p
 where n.nspname = 'app'
   and p.proname like '%\_account'
   and p.prosrc like '%insert into public.accounts%'
   and p.prosrc not like '%revive_account%'
```

which must be nought. A helper written next year that reaches for an
account by code and does not revive is the fourteenth instance of this
fault, and counting them is what makes that a failing build rather than
something somebody notices in a year. The five were found by a sweep and
the eight by reading the five; the fourteenth should be found by CI.

The behavioural half was checked against the old code rather than
assumed: restoring `withholding_account` to the shape it had fails the
fixture with *"2145 is alive again rather than posted to while
retired"*, and 0539 passes it.

---

## `transfer_document`: six mutants that change nothing

A sweep of `public.transfer_document` (98 one-line mutants) left 92
killed by `supabase/tests/transfer_shapes.sql` and the five files that
were already exercising it. The six that remain alive are alive because
the line they change cannot be observed from outside, and each is
recorded here rather than chased with more fixture.

### The two null-guards after a `select ... into` (P5, P6)

```sql
select p2.id into v_person
  from public.contact_persons p1 ... limit 1;
if not found then v_person := null; end if;
```

PL/pgSQL assigns NULL to every `INTO` target when the query returns no
rows, so the guard is already true when it runs. Deleting both lines
passes every assertion, and would go on passing them. They are a
statement of intent — *the prospect's own row is never carried onto the
customer's document* — written where a reader of the next `select` will
see it, and worth keeping for that. `pos_public_menu_shapes.sql` has the
same shape for the same reason.

### `valid_until is not null` (E5)

```sql
and v_sales.valid_until is not null
and v_sales.valid_until < app.today() then
```

`null < date` is null, and `if null then` is false, so an offer with no
end date does not expire whether or not the first line is there. It is
the second line's precondition written out, and dropping it would leave
a reader working out three-valued logic to answer *does a quotation with
no expiry ever expire.* The assertion **"an offer with no end date does
not expire"** pins the behaviour; the line pins the reason.

### `coalesce` around `transfer_counter` (T1)

`app.transfer_counter` either raises on a transition that is in neither
cycle or returns one of four counter names — its final `case` has an
`else`, so it has no null path. Wrapping the call in
`coalesce(..., 'quantity_invoiced')` is therefore unobservable. The
refusals are asserted directly (**"a quotation is not a purchase
order"**, **"nor a delivery note a quotation"**).

### `greatest(v_left, 0)` (Q4)

```sql
v_want := case when p_lines is null then greatest(v_left, 0)
               else coalesce(r.asked, 0) end;
if v_want <= 0 then continue; end if;
```

`greatest` matters only where `v_left` is negative — a line taken
forward for more than its own quantity, which the *"Line % has %
outstanding"* refusal exists to prevent. On a negative `v_left` the two
readings are `v_want = 0` and `v_want = v_left`, and the very next line
sends both to `continue`. The clamp is a second lock on a door the
refusal above already holds shut.

### The zero-quantity divisor (L6)

```sql
case when r.quantity = 0 then 0
     else round(r.discount_amount * v_want / r.quantity, 2) end
```

A source line of quantity nought never reaches this insert: `v_left` is
nought, so a whole transfer skips it at `if v_want <= 0 then continue`,
and a named list asking for any quantity of it is refused for asking for
more than is outstanding. The guard prevents a division by zero on a
path there is no way in. It stays because the alternative is a
`division_by_zero` in the middle of somebody's month-end if a future
change makes that path reachable.

---

## The payroll engine: three clamps that guard a door already shut

A sweep of the statutory engine — `app.calc_statutory`, `app.calc_pcb`,
`round_statutory`, `epf_category`, `statutory_schedule_on` and
`pcb_schedule_for_year` — put 85 one-line mutants through the twelve
files that exercise payroll. 82 die. The three that live are all the
same shape: a clamp whose case is already refused further down.

### `greatest(v_projected - v_relief, 0)` (P33)

Reliefs larger than the year's projected income make the chargeable
amount negative, and `app.annual_tax` opens with
`if p_chargeable <= 0 then return 0`. The clamp and the guard reach the
same answer, and the chargeable amount is not returned to anybody — it
is only ever passed to `annual_tax`, twice.

### `greatest(v_tax - v_zakat_year, 0)` (P36)

Zakat larger than the year's tax makes `v_tax` negative, which makes
`v_remaining` negative, which leaves this function through
`greatest(app.round_statutory(v_remaining / v_n, 'nearest_5sen'), 0)`.
The bonus arm does not read `v_tax` at all — it calls `annual_tax`
directly — so nothing else can carry the sign out.

### `if v_add > 0` around the additional remuneration (P40)

With no bonus the arm computes
`annual_tax(projected + 0 - (relief - least(epf, cap) + least(epf + 0, cap)))`
minus `annual_tax(chargeable)`, and the two arguments are equal by
construction, so `v_extra` is nought either way. The guard saves two
calls to `annual_tax` rather than a wrong figure.

All three stay: each says something true about what the function is
allowed to produce, and a reader working out three-valued arithmetic
from the callee is a reader who will get it wrong once.
`pcb_reliefs_and_defaults.sql` asserts the rules they lean on instead —
that nothing chargeable is nothing taxed, that less than nothing is not
a refund, and that zakat past the tax leaves nothing to deduct — so
removing the guard downstream is a failing build even though removing
the clamp is not.

## The pass at `0566`, and the eight names that stay reported

Both sweeps run again. The provider sweep came back **empty** — 452
providers across 21 files, every one referenced. The method sweep
reported fourteen, and the triage matters more than the number:

| name | what it turned out to be |
|---|---|
| `writeCustomFields` | reached now. `openMatter` and `createTicket` each wrote their own inline copy of it, so the shared method had no caller and the rule had two. Both point at it. |
| `reopenOpportunity` | a gap. A deal closed by mistake — or one the customer came back on — could only be recreated from nothing. Button on the pipeline card. |
| `unlinkContactRecord` | a gap, and the one with teeth. `0482` built it as "the way back, for the record linked on a number that turned out to be a typing mistake", and a group **stops being reported once it is linked**, so a wrong link had nowhere at all to be undone. On each row of the records sheet. |
| `openRequisition`, `closeRequisition` | a gap. `openBlockedBecause` had been sitting in `requisition_editor.dart` since the editor was written, deciding nothing, because nothing could open one. |
| `clearOrgPaymentGateway` | a gap. Unticking Active means "do not offer this to customers" and leaves the key on file; nothing could remove one, so a leaked key could not be rotated away. |
| `setExpenseSplit` | **deleted.** Not a gap: an expense is captured and posted in one step, and `set_expense_split` refuses an expense already in the ledger — so there is no moment at which this could ever have been called. A method for a state the product does not have. |

The eight still reported are the known false-positive class, and are
listed here so the next pass does not re-triage them:

`callRpc`, `callRpcOnce`, `keyFor`, `succeeded`, `notifyPush` are
internal helpers with hundreds of calls inside their own file, which
`unreferenced` excludes by design. `landingPreview` and `navGrouping`
are called by providers declared in the same repository file, the
`creditLedger` shape this document already warns about. `writeCustomFields`
joined them at this pass for the same reason — its two callers are in
`repository.dart`, which declares it.

**The lesson this pass adds.** Four of the seven gaps were not missing
code anywhere: the RPC existed, the repository method existed, and in
two cases the *decision function* existed too — `openBlockedBecause`
written and consulted by nothing, `unlink_contact_record` documented in
its own migration as the way back. What was missing was a button. A
sweep that only counts database functions cannot see that, and neither
can one that only counts providers; the repository method is where the
two halves fail to meet.
