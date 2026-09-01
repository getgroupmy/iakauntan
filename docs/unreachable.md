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
