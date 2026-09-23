# Handoff

For picking this work up in another session — including one signed in as
a different account, on a different machine.

**Read `CLAUDE.md` and `README.md` first.** They are the standing rules;
this file is only the state of play and the things that cost time to
learn. Where the two disagree, `CLAUDE.md` wins.

## What this file can and cannot carry

It carries everything needed to continue: what is on the branch, what is
live, what is blocked, how to run every gate, and the traps that have
already been paid for.

It is not a transcript, and cannot be:

- the session it was written from had been **compacted**, so not even
  that session still held its own earliest turns;
- the full log lives at
  `/root/.claude/projects/-home-user-iakauntan/<session-id>.jsonl` on the
  **container that ran it**, which is ephemeral and unreadable from any
  other account;
- **no secret values are here, by rule.** Secret NAMES are, because you
  need to know what to set. The values live in the Supabase dashboard
  and never in this repository, this database, or any payload the app
  can read.

The repository is the only thing that crosses accounts. If it matters,
it has to be committed.

## Where things stand

| | |
| --- | --- |
| Branch | `claude/iakauntan-accounting-crm-8snun0` |
| Head at time of writing | Reading it here when the chosen reader will not answer (`0703`) |
| CI | **green through run 2096 (`ce6b2ae0`)**. Five runs went red in this stretch and only ONE was the diff: 2084 (Android JDK quota), 2085 (Deno dependency age), 2090 (**mine** — three imports left behind by a move), 2097 and 2098 (`ghcr.io` pull quota, on the edge deploy and then on `supabase start`, both fixed by putting a minute between the retries). All written up below |
| Migrations | `0703` is the highest. CI applies on green — see below |
| Live database | **level with the branch.** Edge functions deployed on the same run |
| Mobile | **iOS build 5 in TestFlight, Android version codes 5 and 6 on Play internal testing.** Both from this repository's own workflows |
| Gates | 363 SQL assertion files, **49 Python gates (+13 gate self-tests)**, **5,878 Flutter tests**, 36 deno tests |
| API description | 787 functions, 366 tables, version `0703` |

### `currentOrgIdProvider` is the SWITCHER, not the current company

The most expensive thing found this stretch, and it was found from
three words on a screenshot: **"Why can't save"**.

`currentOrgIdProvider` holds the org somebody PICKED out of the company
switcher. It is null until they pick one — which they never do with one
company, and mostly do not with two. The company they are actually
working in is `currentOrgProvider`, which falls back to
`profiles.last_org_id` and then to the first company they belong to, and
**`repoProvider` is built from that one**. So the app worked everywhere
while thirteen call sites that read the switcher were inert:

    final org = ref.read(currentOrgIdProvider);
    if (org == null) return;          // the Save button does nothing

No error, no snackbar, no trace. The same sheet's status card printed
the single word **null**, because `aiStatusProvider` had the same fault,
answered `{}`, and the card interpolated two absent keys into a string —
`'${s['provider_name'] ?? s['provider_code']}'` is four characters that
`isNotEmpty` then keeps.

Silently dead for anyone who had never used the switcher: EA forms, the
time terminals, the subdomain and the mailboxes, the addresses card, the
export card, bookkeepers, handover, mail compose, **the "More than one
key" pool editor on the SmartScan screen we were working on all
session**, the practice this company belongs to, and who has held the
company before.

Use **`orgIdProvider`** — `repoProvider`'s own org id, so it cannot
disagree with the id the call is already scoped to. `.notifier` for
selecting and clearing. `scripts/check_current_org.py` is the gate.

The shape to remember: **a provider whose null is the normal case, with
a name that reads like the opposite, next to one that does what the name
says.** Two of the three bugs reported in a row this week were invisible
failures of exactly that kind — this one, and `Fmt.dateTime` on a
`dynamic` drawing a grey rectangle.

### Check the analyzer's EXIT CODE, not its output

Run 2090 was red because of this and it is the cheapest lesson here.
The local check was

    flutter analyze ... | grep -E "^ +(error|warning|info)" | head

which reads NO MATCHING LINES as "no issues" — so a grep that fails to
match for any reason is indistinguishable from a clean run, and the
pipe throws away the one thing that actually answers. Three unused
imports sailed through it and CI refused the build.

Same shape as `run_locally.sh`'s "(0 files)" comment, and as the
`psql: error:` lower-case grep it also records. **Redirect to a file
and test `$?`.** That goes for `flutter test` too.

### The edge job resolves supabase-js fresh on every run

Run 2085 went red on **"Edge function assertions"**, at `deno check
supabase/functions/_shared/context_test.ts` -- the first file in that
list that imports supabase-js. Deno refused the graph:

    error: Could not find npm package '@supabase/auth-js' matching
    '2.117.0'.
    A newer matching version was found, but it was not used because it
    was newer than the specified minimum dependency date of
    2026-09-22 12:59:34 UTC.

Every edge function imported `jsr:@supabase/supabase-js@2` -- a
floating major, with no lockfile and no `deno.json` -- so CI resolved
whatever 2.x was newest at the moment it ran. That was `2.117.0`, whose
npm dependency is pinned to `@supabase/auth-js@2.117.0`, and Deno's
minimum-dependency-age policy refuses an npm package younger than 24
hours.

`@supabase/auth-js@2.117.0` was published at **2026-09-22T13:00:06Z**
(checked against `registry.npmjs.org`). Run 2085 started at
**12:59:34Z** -- **thirty-two seconds** inside the window. Run 2086
started at 13:01:29 and passed with nothing changed.

**Both specifiers are now pinned** to exact versions --
`jsr:@supabase/supabase-js@2.117.0` and `jsr:@std/assert@1.0.19` -- and
`scripts/dependency_audit.py` refuses a range by name, proved by
reverting one file to `@2` and watching it fail. `@std/assert` went too
because leaving one specifier floating under a rule that forbids
floating is not a rule.

**Moving a pin is a commit, and there is one way to get it wrong.**
Change the version in `DENO_CENSUS`, in the eighteen functions, and in
the three files under `_local_check` that name it
(`check_locally.sh` fails loudly if they disagree) -- and **pick a
version whose npm dependencies are more than 24 hours old**, or the pin
reproduces the outage it exists to prevent. `2.117.1` was published the
day this was written and would have done exactly that.

Verified here rather than left to CI, which is what the old census
comment said this commit owed: a real `deno check` of all eighteen
entry points against the REAL package -- not the `_local_check` stub --
plus the 35 deno tests on the pinned `@std/assert`.

### A red edge job ships the front end without the schema

The part of run 2085 that is more than a nuisance, and it is not fixed.

`migrate` declares `needs: [flutter, database, edge, sfu]`, so a red
edge job SKIPS Apply the migrations, Deploy the edge functions and
Deploy the workspace proxy -- while **Build and deploy to Vercel, which
does not depend on `edge`, deploys anyway**. For about twenty minutes
the web build was serving app code that expected a `reads_pdf` field
the database was not yet sending.

It degraded safely, because `readsPdf` parses to null and `pdfBlock`
treats null as "nobody has said". That was the design being lucky
rather than the pipeline being safe, and it is the shape to watch for
whenever the front end can land before the schema.

### The Android job's JDK, and why its retry did nothing

Worth knowing before reading a red run as a broken commit. The Android
job needs a **JetBrains** JDK, because `android/gradle/
gradle-daemon-jvm.properties` names `toolchainVendor=jetbrains` and
Gradle will not start its daemon without one. `jetbrains` is not baked
into the runner image, so it is resolved over the **GitHub API** every
run, from a shared runner IP whose anonymous quota is spent by whoever
else is on it. `token:` is passed and does not help — the error names an
IP rather than an account, which is GitHub's unauthenticated answer.

The job already had a second attempt. On run 2084 both attempts failed
**241 milliseconds apart**, which is the whole story: an immediate retry
fixes the `ECONNRESET` this defence was originally written for, and
cannot possibly fix a spent quota. There are now waits of 60s and 180s
between three attempts. If it still goes red there, check whether the
failure is this before looking at the diff.

### CI applies migrations, and this branch is the default branch

Worth stating outright, because it caught me out and it is the single
most consequential fact about pushing here.

`.github/workflows/ci.yml` has an **Apply the migrations** job and a
**Deploy the edge functions** job. Both are gated on
`github.ref_name == github.event.repository.default_branch`, and the
default branch **is** `claude/iakauntan-accounting-crm-8snun0` — not
`main`. Applying is further gated on the `MIGRATIONS_AUTOPUSH`
repository variable, which is `true`.

So a green run on this branch is a **production deploy**. There is one
Supabase project; a migration applied to it is applied to production,
its row is in `schema_migrations`, and undoing it means writing another
migration. A pushed migration that passes CI is live within about
fifteen minutes of the push.

Do not describe work on this branch as "waiting for a deploy" without
checking the run first.

And read the right thing when you check. The apply job's **"Say that
nothing was applied" step being SKIPPED means nothing** — it is skipped
on every green push, because it is skipped whenever the `Apply` step ran
at all. The tell is inside the `Apply` step's own log, which says either

    **Applied:** 0683_the_five_columns_a_statement_line_has.sql

or

    **Nothing was pending**

This paragraph previously said the opposite, and a session acting on it
told the user a migration had gone live when the run said nothing of the
kind.

## The reported bug, and the three things that had to be true

> `PostgrestException(message: Claude is not available, code: 23514)`

from the AI SmartScan card, on a company whose administrator had just
switched Gemini ON and Claude OFF in the console. Nothing about it was a
coding slip, and all three of these had to be true at once:

1. **`ocr_status` answered `coalesce(s.provider, 'claude')`** for a
   company that had never chosen a reader. The name of the fallback
   reader was a string literal in a function body, so switching readers
   on and off in the console changed what was ON OFFER and never changed
   what anybody GOT.
2. **The settings card echoed that literal back on the toggle** —
   `setOcrSettings(enabled: v, provider: ocr.provider, ...)` — so the
   company asked to switch on a reader it had never wanted, and
   `set_ocr_settings` refused it, correctly.
3. **The reader dropdown was drawn inside `if (ocr.enabled)`**, so the
   only way to choose a different reader was to switch scanning on
   first, which was the call that was failing. A company in this state
   could not reach the control that fixes it from any screen it had.

`0678` fixes 1 and the refusal's wording; the settings card fixes 2 and
3 (`OcrSettings.mustChooseAnother`). The shape of the lesson is worth
keeping: **a default that cannot be changed from a console is not a
default, it is a constant with a friendly name.**

### And the rule the fallback is built on

`0679` retries a failed scan on the platform's default reader, ONCE,
**and only when that reader is free**. The condition is not a
preference. The fallback runs without asking — nobody chose that vendor
for that company and nobody was shown its price — so charging for it
would be billing for a decision the company did not make. For the same
reason it always runs on the PLATFORM's key, never the company's: a
company's own key belongs to the reader that company chose.

A platform that prices its default reader has therefore switched the
fallback off for everybody, which is invisible from the dropdown. The
console says so in as many words; `ocr_default_state()` is what it
reads.

## The reference nobody could redeem

Reported the same day as the one above, from Bills:

> `Could not read it: FunctionException(status: 502, details: {error: The
> document could not be read. Quote this reference if you get in touch.,
> details: {ref: e5b6506c-…, scan_id: 6e50da40-…, refunded: false}})`

The vagueness is correct and stays — `0111` keeps the vendor's message
out of the response because a Document AI failure quotes the project,
the processor and sometimes the page it choked on. The real reason goes
to `ocr_scans.error`.

    $ grep -rn "ocr_scans" app/lib --include=*.dart | wc -l
    0

Nothing read it. So "get in touch" resolved to hand-written SQL against
production, run by the same person being told to get in touch. `0680`
is the console page: **Scan log**, at `/admin/scan-log`.

And a sharper one underneath it. `logFailure` mints `ref` with
`crypto.randomUUID()` and writes it to the function's **stdout only** —
it was never stored. So of the two identifiers in that banner, the one
labelled "quote this reference" was the one that could never be
resolved from the database, and the one that could (`scan_id`) is not
what the sentence points at. `ocr_scans.log_ref` fixes that; the edge
function now mints the ref *before* settling so it has it in hand.

### The number that does not look like a failure

`platform_scan_health()` counts scans still `pending` an hour after
they started. That is a function that died between `ocr_begin` and
`ocr_finish` — the charge was taken and the refund never ran. It goes
uncounted precisely because the status reads as "still going" for ever,
and nobody goes looking for a row that claims to be in progress.

## What a scanned paper fills in

`0681`. `0614` gave a scan a KIND and a free-text `destination`, and
that destination named a SCREEN. It could not say which module the
screen belongs to and it could not say what the screen has room for —
so the reader was asked the same eleven questions about every document
ever scanned, out of one hard-coded schema in
`supabase/functions/ocr/index.ts`, whether the paper was a bill, a bank
statement or a name card.

A kind now points at a **module** and an **action** (`scan_targets`),
and the fields on offer are the **real columns** of the table that
action writes, read out of `information_schema` when the console asks.
What is stored is the tick (`scan_target_fields`).

Three things about that are load-bearing and easy to undo by accident:

- **Discovered, not typed.** A list somebody typed goes stale the first
  time a column is renamed, silently, and the symptom is a reader being
  asked for a field that no longer exists.
  `set_scan_target_fields` refuses a tick on a column the table does not
  have, so the stored set cannot outlive the schema.
- **A dropped column is shown, not hidden.** `scan_target_columns` is a
  FULL OUTER JOIN for that reason — `still_there` false rather than a
  row quietly vanishing.
- **Fields belong to the TARGET, not the kind.** A delivery order and a
  bill both land in purchasing; configuring the same columns twice is
  two lists that disagree by Thursday. The console says so on the
  checklist.

`destination` still exists and the app still routes on it. A trigger
sets it from the target, so the screen a scan opens and the fields it
fills cannot be edited into disagreeing.

### What reaches the reader

`scan_extraction_targets()` → `supabase/functions/ocr/targets.ts` →
the JSON schema and the system prompt. The schema is FLAT — one
property per askable column across every target, plus a `target` enum
that **includes null**. A model with no way to say "none of these"
picks the closest one, and the closest one becomes a record somebody
has to find and undo.

Two readers do not get it and that is deliberate: **Document AI**
answers with the entities its processor was trained on, configured in
Google's console rather than ours, and a **self-hosted** reader is sent
`schema=iakauntan.extraction.v1` — a name it implements at its end.

### Not done, and worth knowing

`OcrExtraction.target` and `.fields` arrive and are asserted. Wiring
each destination screen's form to read arbitrary columns out of
`fields` is the next step — 14 files consume `OcrExtraction` today and
none of them reads the new map yet.

## `or()` is a grammar, not a parameter

Reported off a phone, on the supplier picker after a scan:

> `PostgrestException(message: "failed to parse logic tree
> ((name.ilike.%SHAHARUDIN, SHAM SUNDER & PARTNERS%, …", code: PGRST100)`

PostgREST's `or` parses its own argument. A comma starts another
branch, a dot separates column from operator from value, parentheses
nest, and `&` ends the query string. Five call sites interpolated typed
text straight into it, so **any Malaysian firm with a comma or an `&`
in its name was unsearchable**.

`Repo.orValue` double-quotes and escapes; `Repo.orLike(column, q)`
builds one `ilike` branch with it. `scripts/check_or_filters.py` fails
on any `or()` whose string carries a `$` interpolation that is not
going through one of the two. It has a self-test, because a gate that
has stopped matching passes everything cheerfully.

The gate cannot see `.eq()`, `.ilike()` or `.contains()` — those are
separate query parameters and postgrest-dart encodes them. Only the
logic tree parses its own argument.

### The half that was worse

`resolveSupplier` wraps that lookup in `catch (_)` and treats a failure
as "no supplier found". So the parse error never surfaced as an error:
it became a missing-supplier dialog with an empty list of near-misses,
next to a Create button. **That is how a second contact record for a
company already on file gets made.** The catch stays — a lookup that
fails for a real reason should still not offer to create a duplicate —
but it was hiding a bug, not a network blip.

### Suggesting, rather than asking again

The substring search finds nothing whenever the two spellings differ at
all, and they usually do: one was typed by a person, the other read off
a letterhead. `rankedLikeName` now scores every supplier on file
against the printed name.

On WORDS, not characters — two spellings of one company share their
distinctive words and differ in punctuation, in `&` against `and`, in
whether `Sdn Bhd` was typed at all. Generic words (`sdn`, `bhd`,
`trading`, `partners`, and the rest of `_generic`) come off first,
because they are on half the letterheads in the country and a scorer
that counted them would rank every company against every other. The
score is over the SMALLER word set, so a supplier saved as two words
matches a six-word letterhead. A registration number outranks
everything: it is an identity, not a label.

The suggestions are tappable now. They were bullets with a "Choose
existing" button that reopened the picker — so somebody who could SEE
the right supplier named in front of them had to dismiss the dialog and
search for it again.

## SmartScan is a module, and a statement is many rows

`0682`.

**The module.** Scanning was switchable per company since `0111`, but
only as a SETTING any administrator could turn on — and it is the most
expensive thing in this product per use. `smartscan` is a module now,
off by default, gated in `app.require_smartscan` and called from every
door: `ocr_begin`, `ocr_record_local`, and `set_ocr_settings` on the
way ON only. Switching OFF always works — a company whose module has
lapsed still has a switch reading "on", and refusing to let them turn
it off would be refusing to let them tidy up after us.

`ocr_status` reports `has_module` so the Settings card says so rather
than drawing a switch that refuses. A refusal a screen could have
predicted is a screen that was not finished.

`ocr_record_local` is the assertion that would rot: it costs the
platform nothing, which is the argument for leaving it open and exactly
how a paid feature ends up free on the phone.

**A target that repeats.** `0681` left bank statements out and said
why — "a statement becomes MANY rows, and a field list that describes
one record cannot describe it". `scan_targets.repeats` is the fix: the
reader is asked for an ARRAY of the field objects. A repeating target's
columns go in `rows` and **nowhere else** — offered in both, a model is
invited to answer both, and a running balance filled in once at the top
and again per line is two answers that disagree.

**Invoices.** The Scan action was hidden on the sales side. The reason
given was that a sales invoice is raised from what we are owed rather
than read off paper — true of most and not of the ones that matter (a
copy returned with a payment, every invoice raised on another system
during a migration). The real obstacle was the wording: everything
under the button asked "which supplier?". `ScanContactKind` carries the
noun, and `supplier_doc_no` is written on the purchase side only —
a sales document's number is this company's own sequence.

### Two traps this paid for

- **`app.demo_modules_in_use` had been redefined four times.** I copied
  its body from `0233` and reverted `0324`, `0329`, `0470` and `0486`.
  `demo_rebuild.sql` caught it — 6 modules missing instead of 1. **Copy
  a function body from the migration that LAST defined it**, which
  `grep -rln` finds in a second.
- A one-off `update` over the demo companies is undone by the next
  `app.demo_rebuild()`, which deletes and recreates them. The seam is
  `demo_modules_in_use`, and for a feature with no rows of its own the
  idiom is `select id, '<module>' from organizations where is_demo`.

### Not done

The reader returns a statement's lines. Turning them into
`bank_transactions` is not wired: that needs a bank account chosen, an
import batch and the duplicate check, which is the bank-import
machinery rather than the scan machinery.

## A schema is `strict`, and `required` grows with `properties`

Scanning worked all week and then stopped, with the sentence this
function says about everything:

> `The document could not be read. Quote this reference if you get in
> touch.`

`SCHEMA` in `supabase/functions/ocr/index.ts` is `strict: true` with
`additionalProperties: false` and an explicit `required` naming every
property — its own header says "every field is required and nullable
rather than optional". `0681` merged the configured target fields into
`properties` and **not** into `required`. OpenAI's strict mode rejects
that schema outright: 400 from the vendor, caught, reported as the
document being unreadable.

Two things made it hard to see:

- **It only bites once somebody ticks a field in the console.** An
  empty target list leaves the schema untouched, so it presented as a
  feature that had worked for days and suddenly did not — with nothing
  deployed in between except the console that made ticking possible.
- **The nested objects have the same rule.** `fields`, and each item of
  `rows`, are objects with `additionalProperties: false` and no
  `required`. Strict mode is not a top-level-only rule, and the second
  400 looks exactly like the first.

`requiredWith(base, extra)` in `targets.ts` is the fix and is tested on
its own, because getting it wrong is silent at every layer this
repository controls and loud only at the vendor.

**The rule:** in this codebase a JSON schema sent to a reader is strict.
Add a property, add its name to `required`, at every level.

### THE DEFAULT BRANCH IS THIS BRANCH, NOT `main`

```
"default_branch": "claude/iakauntan-accounting-crm-8snun0"
```

Everything downstream follows from that one line, and none of it is
obvious:

* **`main` deploys nothing.** The migrate, edge-function and
  workspace-proxy jobs are all gated on
  `github.ref_name == github.event.repository.default_branch`, so on a
  push to `main` they are SKIPPED. PR #4 merged this branch into `main`
  on 2026-09-21 and its run skipped all three.
* **This branch deploys everything.** Those same jobs run here, and
  `MIGRATIONS_AUTOPUSH` is `true`, so a green run on this branch
  applies its migrations to the live project and redeploys the edge
  functions, the workspace proxy and the web app.
* **But only the run for the branch TIP deploys.** `migrate` sets a
  `superseded` output from its "Has this commit already been passed?"
  step, and all four deploy jobs are gated on
  `needs.migrate.outputs.superseded != 'true'`. Push twice inside the
  twelve minutes a run takes and the FIRST run goes green with `Apply`
  and every deploy SKIPPED — deliberately, so an older commit cannot
  overwrite a newer one.

  So "green" and "deployed" are different questions, and reading a
  green run as a deploy is wrong for any commit that was overtaken.
  Run 1985 (`ec9d7706`) is the worked example: green, everything
  skipped. Run 1987 (`08c87ac1`) was the tip and carried all of it —
  `Apply`, then the edge functions, the proxy, and Vercel at 04:38 UTC,
  with "Confirm the domain is serving this commit" passing.

  To answer "is the live site running commit X", look at the run for
  the TIP at the time, not at X's own run.
* So the live product tracks THIS BRANCH. Merging to `main` is
  bookkeeping, plus the one thing in the next bullet.
* **`workflow_dispatch` needs the file on the ref being dispatched.**
  `supabase/functions/ios-release` names a ref, and GitHub looks for
  the workflow file THERE — not on the default branch because it is the
  default branch, which is the usual folklore and is not what bit this
  repository.
* **That is why the console button no longer assumes `main`.** It
  used to dispatch `GITHUB_RELEASE_REF || "main"`, and `main` is a
  snapshot of this branch at the PR #4 merge — so the button built a
  tree without the pods `xcconfig` fix, `ITSAppUsesNonExemptEncryption`
  or the purpose strings, and failed at signing with errors fixed hours
  earlier. A button that worked, against code that did not.

  `ios-release` now reads `default_branch` from the GitHub API and
  builds that, with `GITHUB_RELEASE_REF` left as an override for
  releasing from a specific ref on purpose. **The secret no longer
  needs setting**, and if the default branch moves the function follows
  it. It refuses rather than guessing if the lookup fails.

**A previous version of this file got this exactly backwards** and
said the migrations were unapplied, reasoning from "the job runs on
the default branch only" plus an assumption that the default branch
was `main`. The rule was right and the assumption was wrong, which is
the combination that produces a confident wrong answer. Read
`default_branch` from the API rather than assuming; nothing in a
checkout tells you.

Whether this arrangement is INTENDED is a question for the user and
has not been asked. It is unusual, and if the default branch is ever
moved to `main`, the deploy jobs move with it — at which point this
branch stops deploying and `main` starts.

Counts to expect from a clean run: **42** gates and **8** gate
self-tests, **348** SQL assertion files, **32** deno tests, **5,331**
widget tests with 1 skipped, analyser clean.

Counting the SQL files: 350 sit in `supabase/tests/`, less `_helpers.sql`
and `_local_stack.sql`, which are included by the others rather than run.

The branch carries `main`'s history — PR #3 merged `main` INTO it — so
`git log 9ce1d22..HEAD` prints hundreds of commits that are not this
work. Use `--first-parent`.

### The working agreement

The user's standing instruction, still in force: *"continue applying
skeletons to the rest of the screens and keep on going solve all issues
and uncompleted stuff don't stop till i say so do all recommended
automatically without asking"*. In practice that means: pick the next
real thing, do it properly, verify it, commit, push, watch CI to green,
and only stop to ask when proceeding would be unsafe or would waste the
work if the guess were wrong.

Hard constraints: commit and push **only** to the branch above; **no
pull request** unless asked; GitHub access is scoped to
`getgroupmy/iakauntan`; never disable TLS verification or unset
`HTTPS_PROXY`; no model identifier in any commit message, code comment
or anything else pushed to the repository.

## A photographed statement becomes bank lines

The last gap in the SmartScan work. `0682` made `accounting.bank_statement`
a target that **repeats**, so the reader answers with an array, and the
edge function returns them in `OcrExtraction.rows` — and nothing read
them. A photographed statement came back with its lines correctly
separated and then stopped.

### Nothing had to translate

`import_bank_transactions` (`0369`) already takes
`{transaction_date, amount, description, reference, running_balance}`.
Those are `bank_transactions` column names — which is exactly what a
repeating target's **ticked fields** produce, because the console's
checklist is built from `information_schema` on the target's own table.
The two shapes are the same shape, and neither knows about the other.

So the new code only **coerces**: `scannedStatement` in
`app/lib/src/features/banking/statement_import.dart` turns the printed
strings a reader hands back — `03/09/2026`, `1,900.00`, `(250.00)`,
`RM 1,900.00` — into ISO dates and plain numbers, reusing
`parseStatementDate` and `_number` that the CSV path already had. It
falls back to `value_date` where `transaction_date` was not ticked, and
reports an unreadable line by its number rather than dropping it.

`statementPreview(scanned, typed)` is the dialog's precedence rule, and
it is a function rather than an expression in `build` for one reason:
the rule cannot be reached in a widget test without a camera. A
photograph beats a paste; they are never merged, because they are two
readings of the same statement and importing both puts every line in
twice under two slightly different descriptions — the case
`import_bank_transactions` deduplicates worst, since the descriptions
differ just enough for its key to miss.

### The seam that would have shipped broken

`scan_extraction_targets` **only offers a target that has at least one
field**. `0682` ticked none. So as pushed, the reader was never asked
for statement lines at all, and every photograph came back correctly
empty — a feature that is present, wired, tested and does nothing.

`0683` seeds the five: `transaction_date`, `description`, `reference`,
`amount`, `running_balance`, each with the sentence the reader is asked
with. `on conflict do nothing`, so an installation that ticked its own
set keeps it.

Two of those sentences carry things a general reader gets wrong:

- **the sign.** A statement prints two money columns, or one column
  with `DR`/`CR` beside it. Neither is a negative number, and a reader
  left to itself returns the figure as printed — which makes every
  withdrawal a deposit.
- **`running_balance` is not optional.** It is the only figure on a
  statement that can be checked against the rest of it. Leave it
  unticked and the import still works and is never checked, which is
  the silent half of `0369`'s whole argument.

The ordering rule is already handled: `targetPrompt` adds *"Every line,
in the order printed"* to any target that repeats, and
`import_bank_transactions` reads the statement's direction off its own
dates.

`supabase/tests/bank_statement_scan.sql` asserts the whole path as one
thing, and builds its fixture rows **out of the ticked names
themselves** rather than typing them — so the assertion moves when the
ticks move. Nothing else joins those two sides: one is a table of
strings, the other is `->>` on a jsonb, and a rename on either side is
invisible until a statement imports as nothing.

## What the reader got wrong — and the rest of the SmartScan list

`0684`. `ocr_scans.extracted` held what the model said and nothing held
what the person changed it to. `showScanResult(canApply: true)` puts the
reading on screen beside the fields it is about to fill; somebody
corrects the total, the date, the supplier — and that correction, the
only ground truth this system produces, was handed to the form and
dropped.

### Three states, because two cannot say it

The obvious design is one `corrected` column, and it cannot tell apart
the two interesting cases. A scan with no correction is either a
reading somebody checked and AGREED with — the reader was right, the
datum the whole thing is for — or one nobody looked at. Opposite facts,
both null.

| | |
| --- | --- |
| `reviewed_at` null | nobody accepted this reading |
| `reviewed_at` set, `corrected` null | accepted as read. **The reader was right** |
| `reviewed_at` set, `corrected` set | somebody changed something, and `corrected` is what to |

`corrected` is written only where it differs, and `raw_text` is stripped
on the way in.

### What counts as a difference

Not `jsonb <>`. `1900` and `1900.00` are the same money and different
JSON, and a reader marked wrong for a trailing zero would bury the real
signal under noise that scales with volume. So the comparison is per
field and by type — money as numeric, dates as date, text trimmed and
case-folded, null against `''` treated as agreement. The field list is
`app.scan_corrected_fields()` and lives nowhere else, so the write path
and the report cannot disagree about what a correction is.

`public.platform_scan_accuracy(days)` is the payoff: per reader, how
many readings a person checked, how many they changed, the share
accepted as read, and **the field that reader gets wrong most**. That
last column is the useful one — readers do not fail evenly, and a reader
that reads totals perfectly and dates badly wants a better sentence in
that field's description rather than replacing.

### Called even when nothing changed

`rememberCorrection` fires on every accepted reading. Recording only the
corrections gives every reader a denominator of nothing and a score of
0% for ever. Best effort, beside `rememberDocumentKind` and for the same
reason: this is a note about a reading, and a bill that was read and
corrected must not be lost because the note would not write.

### The rest of the list, not yet done

Established by reading the code, in the order I would take them:

1. ~~**Settle the Gemini path.**~~ Could not be settled from here, so
   `0685` built the instrument that settles it instead — see below.
   **Go and look at `/#/admin/scan-log`.** The question stands: `0675`
   gave Gemini `kind: 'openai'`, so it goes through `readOpenAiShaped`
   with `strict: true`, `max_completion_tokens` and nested
   `additionalProperties: false`, and Google's OpenAI-compatibility
   layer is a compatibility layer rather than the same API. Nothing
   here has proven a Gemini scan ever came back schema-shaped.
2. **Per-kind PDF handling.** `readOpenAiShaped` refuses
   `application/pdf` by name for everything that speaks
   chat-completions. Correct for ChatGPT and Grok when written;
   **Gemini reads PDFs natively**, and a supplier's emailed invoice is
   a PDF far more often than a photograph. OpenAI takes them now too,
   through a different request shape.
3. **A default model on the ChatGPT row.** `0113` inserts `openai` with
   `model: null` and a blurb saying to set one in the console. Claude
   ships with `claude-opus-5` and Gemini with `gemini-2.0-flash`;
   ChatGPT ships as a row that cannot run until somebody types a model
   name they have to already know.
4. **Prompt caching on Claude, and a cheap Claude row.** The system
   prompt plus the schema is re-sent on every scan and has GROWN since
   `0681` — `targetPrompt` appends every configured field — while being
   identical for every scan on a platform. Anthropic caching needs an
   explicit `cache_control`; it is not automatic. And `claude-opus-5` at
   RM 0.30 is the careful reader: rather than swapping the model and
   losing the awkward layouts it was chosen for, add a second row.
5. **MCP.** `docs/gaps-against-rillet.md` kept it off its list for a good
   reason — *"an agent calling undescribed, non-idempotent write
   functions is the worst version of this"* — and both preconditions
   have since been met (`0307` idempotency keys, `docs/api/` describing
   781 functions and 366 tables, regenerated and CI-checked). What is
   missing is the thing that page never had to consider:
   **authorisation**. RLS answers "what may this user see"; MCP needs
   "what may this agent do on this user's behalf", which is narrower.
   That is the design question, not the server.

## What a reader keeps saying

`0685`. The Gemini question above could not be answered from the
container this was built in: the egress proxy blocks `ai.google.dev`
**and** the Supabase project, so neither Google's documentation nor the
live scan history was reachable. Writing a native Gemini client against
remembered field names would have been the same failure that produced
the `required` regression — silent at every layer this repository
controls and loud only at the vendor.

So the instrument got built instead, and it is the better artefact
anyway.

### Why the scan log could not answer it

`0680`'s log answers *"what happened to THIS scan"*, which is what
somebody asks holding a reference number. Fifty rows at a time, no
grouping, no provider filter. So a reader that has failed on every scan
since the day it was switched on looks exactly like a reader that
failed twice last Tuesday — and `0679`'s fallback hides even that: the
scan quietly goes to another reader, the tenant gets their document,
**the platform pays twice**, and the only trace is a row nobody groups.

`public.platform_reader_failures(days)` is one row per reader and
distinct fault, carrying that reader's `read` and `failed` totals down
every row. `read = 0` beside `failed = 47` is the row that matters, and
it sorts first. On `/#/admin/scan-log`, above the search box, drawing
nothing at all when no reader has failed.

### The normalisation is the whole thing, in both directions

Group on the raw vendor text and every scan is its own group — four
hundred identical failures read as four hundred unrelated problems,
which is the same as reading as nothing. So ids, hex blobs, digit runs
of six or more and long quoted payload fragments are replaced, and
spacing is collapsed.

Over-normalise and it lies the other way. Two rules exist because of
that:

- **Short numbers are kept.** `HTTP 400` and `HTTP 429` are a schema
  this code sent wrongly and a quota somebody has to go and raise —
  different people, different afternoons.
- **Short quoted names are kept**, and only quoted runs of 40+
  characters go. `Unknown name "strict"` is the *fault*; the quoted
  word is the single most useful thing in the message and the only
  thing distinguishing it from `Unknown name "max_completion_tokens"`.
  The first version replaced both and merged two different faults into
  one line. `supabase/tests/reader_failures.sql` caught it.

A mutation run also caught a real gap on the Dart side: the screen
tests built `ReaderFault` directly, so nothing read `fromJson`, and
swapping `read` and `failed` on the way in passed every test while
inverting the one claim the section exists to make.

## The matter the rest of the ledger could not see

`0687`. A law firm keeps the firm's books and one set per matter, and
the second is a statutory obligation rather than a view over the first.

`0021` built the client side properly — `matters`,
`client_account_transactions` with its four movements, and
`app.assert_client_funds()`, the rule that matters most: **a matter may
not spend money it does not hold**. What it never did was put the matter
anywhere the rest of the ledger could see it.

`matter_id` reached exactly four tables: `client_account_transactions`,
`disbursements`, `sales_documents`, `time_entries`. Everything else
posts through `gl_lines`, which carries `contact_id`, `item_id`,
`project_code` and `department_code` — every dimension except the one a
solicitor files by. So a bill from a searcher, an expense for a courier,
a journal correcting last month: none could be told which matter it
belonged to. And because `report_trial_balance` is built on `gl_lines`,
a per-matter trial balance could not be written at all.

### What went in

- **`gl_lines.matter_id`**, nullable and staying that way. Most of what a
  firm posts — rent, salaries, its own bank charges — belongs to no
  matter, and a mandatory one would put a fictitious matter on every
  such line.
- **`report_matter_trial_balance(org, matter, from, to)`** — the summary.
- **`report_matter_ledger(org, matter, from, to)`** — the pull an
  internal audit wants: every posted line, oldest first, with a running
  balance and what created each entry. This is what the user asked for
  in those words.

### Three things that would have been wrong and still balanced

- **The composite foreign key.** `(org_id, matter_id)` references
  `matters (org_id, id)`, per `0160` — RLS scopes a row by its own
  `org_id` and says nothing about the ids it carries, so a simple
  reference would accept another firm's matter onto this firm's ledger.
- **No opening balance off `accounts`.** `report_trial_balance` adds
  `accounts.opening_balance`, which is what the **firm** brought forward.
  Carried onto a matter it puts the firm's whole opening position under
  a client's name — and the report still adds up.
- **`line_no` is returned by the pull.** The running balance is only
  meaningful in the report's own order, and without the line number a
  caller that re-sorts cannot reproduce it. My own first assertion
  sorted by date alone and got an arbitrary one of two lines sharing a
  date — which is how the gap was found.

### Two gates caught real faults

`tenant_foreign_keys.sql` refused a bare `on delete set null` on a
composite key — it nulls **every** column in the key, and `org_id` is NOT
NULL, so deleting a matter would raise rather than detach the line. The
fix is naming the column: `on delete set null (matter_id)`. `0681` hit
exactly this once already.

`utc_is_not_today.sql` refused `p_to date default current_date` —
a Malaysian business day starts eight hours before UTC does, so a report
run at 7am local would stop at yesterday and omit the morning's
postings. `app.today()`.

### Still open on the legal work

The user asked for four things. This is the foundation for two of them.

1. **Matter on all transactions** — the column exists and `0688` makes
   every posting path carry it: `app.create_gl_entry_internal` is the
   only function that inserts `gl_lines`, and a caller that knows its
   matter now puts `matter_id` on the line the way `project_code`
   already travels. The Flutter picker is **on the journal editor**; the
   bill editor, expense form and bank reconciliation still need it.
2. **Client trust monies with collections and payments** — already built
   (`ClientMoneyScreen`, `/legal/receipts`, `/legal/payouts`). Asked the
   user what is missing in practice rather than rebuilding it.
3. ~~**General entry with inter-account transfers**~~ — the missing
   reading was a general journal on the client side, and `0690` is it.
   The SQL is done; **the screen is not**.
4. **Per-matter trial balance** — done, plus the audit pull.

The user settled the scope question: everything tagged to the matter,
not client-money-only. A Rule 8 client account reconciliation —
restricted to the designated client bank accounts, which
`bank_accounts.is_client_account` already marks — is a separate report
against a separate question and was deliberately not folded in.

## The matter, on every posting path at once

`0688`. `0687` put `matter_id` on `gl_lines` and built the reports that
read it; nothing wrote it. This is one line in one function.

`app.create_gl_entry_internal` is the only thing in this product that
inserts into `gl_lines`. A bill, an expense, a manual journal, a bank
charge, a payroll run, a client account movement — every one builds its
lines as jsonb and hands them there. `0160` made the same observation
for a different reason: it is where a change reaches every caller at
once, and where reading the callers would never catch the next one.

So the matter travels the way `project_code` and `department_code`
already do, and **no caller had to be changed to keep working**.

`nullif` before the cast, for `0640`'s reason inverted: `0640` found the
two text dimensions stored `''` as a nameless dimension. The uuids have
the louder failure — `''::uuid` raises, so a form that sends an empty
string when the picker was opened and closed would refuse the entire
journal rather than post an untagged line. That is asserted directly.

### The mutant that mattered

"Every line takes the first line's matter" survived the first sweep,
because every fixture tagged both lines with the same matter. That is
not a hypothetical shape: **a transfer between client ledgers is one
entry with two different matters on it**, one credited and one debited,
and under that mutant the whole transfer would post against the paying
matter while the receiving one showed nothing. Pinned now, and it is the
assertion the client-side general journal will lean on.

## The matter picker, on the journal first

`matterPickerOptions` beside the other list helpers, and a Matter field
on `JournalDraft` that `toJson` omits when it is null — the same shape
`project_code` and `department_code` already send, and the shape `0688`
expects.

**Per line, not per journal**, for the reason the other two are: the
entry that moves a cost between matters is one journal touching both.
That is not a corner case — it is what a transfer between client
ledgers IS, and a header field could not express it.

**Gated by emptiness, not by a module check.** `widget.matters.isEmpty
? null : picker` is the rule this file already applies to projects and
departments — *"a company that has never created one gets neither
control rather than two empty ones"* — and it means every company that
is not a law firm never sees it without anything having to ask.
Open matters only: a journal is posted today, and a file closed last
year is not something anybody means to post to.

### A layout bug this would have shipped

The wide arm sized the narrative with

```dart
flex: 3 - [project, department].whereType<Widget>().length,
```

written when two was the most there could be. A third dimension makes
that `3 - 3`, and an `Expanded` with a flex of zero is a description
with **no width at all** — not truncated, gone. Clamped to `(1, 3)`.

### An equivalent mutant, written down

A sweep mutant giving `matterId` a field initializer survives, and it is
equivalent rather than a gap: `JournalDraft` takes `this.matterId` as a
constructor parameter, and a parameter always wins over a field
initializer, so the default is unreachable. Noted in
`journal_problem_test.dart` so the next sweep does not spend an
afternoon on it.

### Still to place

The bill editor, the expense form and the bank reconciliation. The
journal was taken first because it already had two dimensions to sit
beside, so the pattern is now established rather than invented three
more times.

## A bank account on the chart, and nowhere else

`0689`, from a feedback report — GESWANT & CO, 23/09/2026, "BANK
ACCOUNT NOT SHOWING": they added a sub-account under Bank on the chart
of accounts and went looking for it in the bank dropdown on a customer
collection.

**Nothing was broken, which is why it needed fixing.** `bankAccounts()`
filters on `is_active` and nothing else; `bankPickerOptions` filters
nothing at all. No filter hid it — it was never a bank account. A bank
account here is TWO records: an `accounts` row where the money sits and
a `bank_accounts` row that pickers list. `upsert_bank_account` makes
both; the chart screen makes only the first.

`public.unregistered_bank_accounts(org)` answers one question — which
accounts money can sit in that no bank account points at — and
`NewBankAccountDialog` offers them. `upsert_bank_account` has taken
`p_account_id` since `0529` and already refuses a group or a non-bank
account, so **nothing new is permitted**; what was missing was the
offer.

### Why it offers rather than decides

A `bank_accounts` row carries the bank, the number, the kind, and
whether it is a **client account** — which for a solicitor is a
statutory distinction, not a label. Creating one automatically means
inventing all four, and an account silently created as an ordinary
current account in a law firm's chart is the mistake the Solicitors'
Accounts Rules exist to prevent. Nor is everything under the bank
heading a bank account: a petty cash tin reconciles against no
statement.

### Registered is registered, switched off or not

The test is whether ANY `bank_accounts` row points at the account,
including a deactivated one. Testing `is_active` instead would offer a
switched-off account back, and registering it again puts **two bank
accounts against one ledger account** — the same money in two pickers
and a reconciliation that can be run twice. Asserted directly.

### Two things the tests caught

**A 38-pixel overflow.** The dialog's content was already near the
height a phone gives it and had no scroll view; the new section pushed
it over. Flutter reports that as a test failure and a release build
simply CLIPS — taking the Save button with it. Now scrollable.

**And the mutant that mattered.** Dropping `accountId` on the way to the
save survived the first sweep, because nothing pressed Save. Without it,
pressing Register opens a **second** chart account beside the one being
adopted — a worse outcome than the reported bug, since the original was
a missing entry and this would be a duplicated one.

### The report itself is not replied to

The Supabase project is unreachable from this container (403 at the
egress proxy), so `set_feedback_status` cannot be called from here. The
reply text and the recommended status (**planned**, not done) were given
to the user to press in the console.

## A journal on the client side

`0690`. Money already held for one matter becomes money held for
another: a deposit paid into the wrong file, a related matter opened and
the balance carried across, a correction.

`0021` saw it coming. `app.client_txn_type` has carried `transfer_in` —
commented *"moved from another matter"* — and `transfer_out` since the
module was written, and **nothing has ever written either**. There was
no way to make the entry the enum was built for.

### Why it is two client rows and not a journal

The tempting shape is a general journal against `gl_lines`: `0687` put
the matter there and `0688` made every posting path carry it, so it
would work.

It would also route client money around the one control that matters.
`app.assert_client_funds` is a deferred constraint trigger on
`client_account_transactions` — *a matter may not spend money it does
not hold* — and a journal written straight to the ledger is not such a
row, so the trigger never fires. **The first thing this feature would be
used for, moving money between two clients, is exactly what the trigger
exists to refuse.**

So the transfer is written as the two rows it actually is, and the
statutory guard applies because it was never avoided. Deferred means
both rows land before it looks, so emptying a matter exactly is fine and
overdrawing it is refused whole. Both asserted.

### What posts, and what does not

Not `post_client_transaction` on each leg. That debits the client bank
and credits client monies held for money in, and the reverse for money
out — right for a receipt, wrong here twice over, because **no money
moves**. It is in the same client bank account before and after.

So one entry, two lines, both on 2300:

```
debit  2300, matter FROM   -- we owe that client less
credit 2300, matter TO     -- and that one more
```

The account nets to zero, which is right — the firm owes its clients the
same total. Each *matter's* ledger shows the movement, because `0687`
put the matter on the line. This is the one entry with two different
matters on it that `0688`'s assertion was written for.

### Three refusals worth naming

- **A description is required.** Every other movement here takes one or
  defaults. This one does not: a transfer between two clients' money
  with no explanation is the first thing an auditor asks about and the
  hardest to reconstruct a year later.
- **The same matter twice is refused**, rather than posting two
  cancelling rows that read as a completed transfer.
- **Two firms' matters cannot be transferred between.** The function
  takes two ids from a caller and nothing else would compare them.

Seven SQL mutants, all killed, control survived.

### Still to build

**Built.** `/legal/transfers` is the third page beside `/legal/receipts`
and `/legal/payouts` (`2c6a456f`), and building it is what found that
`0690` had broken `0358`'s function by overloading it — see that commit
message, and `scripts/check_ambiguous_overloads.py`, which is the
general answer.

The matter picker is now on the bill editor and the expense form.

**The bank reconciliation was the third one asked for, and there is
nowhere on it to put a matter.** Worth writing down so it is not
re-opened: that screen imports statement lines into
`bank_transactions` and MATCHES them to records that have already
posted — `suggest_bank_matches` (`0085`) returns receipts and
purchase payments, and `_match` refuses with "Record the receipt or
payment first" when nothing matches. No row in `bank_transactions`
ever reaches `gl_lines`, so there is no line whose `matter_id` a
picker there would set. The matter arrives with the receipt or
payment the line is matched to, which `0691`/`0692` put on the
document.

The nearest real thing, if it is wanted, is the other direction:
SHOW the matched document's matter on the line tile and in the
suggestion dialog, so a firm reconciling a client account can see
which file each cleared item belongs to. That is a display change and
a different piece of work from a picker, so it has not been assumed.

While looking: `public.suggest_bank_coding` (`0625`) and
`Repo.suggestBankCoding` both exist and **no screen calls either**. A
rules engine with no consumer — separate from the above, and not
touched.

## A PDF, and the reader that could not open it

Reported with the PDF attached: a supplier bill was uploaded into AI
SmartScan and the inbox came back

    This reader takes photographs, not PDFs. Photograph the document,
    or switch to Claude, which reads PDFs.

Three separate faults were behind one report, and only the middle one
was what the person actually complained about.

### The refusal was right, and arrived too late

The company is on **Gemini**, whose `ocr_providers.kind` is `openai` —
Gemini, ChatGPT and Grok are three vendors wearing one chat-completions
shape — and `readOpenAiShaped` in `supabase/functions/ocr/index.ts`
refuses a PDF **by name**. That is correct: chat-completions takes an
image part, a document would be a different endpoint on every one of
them, and sending it anyway would be a misreading rather than a
refusal. Only `anthropic` (Claude) and `google_docai` open one.

What was wrong is **when** it arrives. `ocr_begin` has already taken the
charge, the reader refuses, the charge is refunded, and the person is
looking at a failure after doing all the work. Everything the question
turns on was knowable before the file left the machine.

So `app.reader_reads_pdf(kind)` (`0697`) answers it, `ocr_status` sends
it per provider beside the `kind` it has carried since `0682`, and
`pdfBlock` in `app/lib/src/features/smartscan/scan_availability.dart`
predicts the refusal at the moment the file is chosen — the same
argument `scanBlock` was written for, one step further in. Both doors
go through it: the SmartScan capture path and the "Read this document"
button on the attachments strip, which is the one control in the
product that spends money on a press.

**`reads_pdf` is tri-state and the third state is load-bearing.** It is
`null` for `kind = 'device'`, because the on-device reader is `pdf.js`
in a browser and ML Kit on a phone and only the app knows which — so
`pdfBlock` takes `deviceReadsPdf` as an argument rather than reading it,
and stays pure. It is also `null` for a kind added to the catalog since
that function was written. Null reads as **yes** when deciding whether
to block (refusing on an unknown would withdraw a reader the platform
had just added) and as **no** when naming alternatives (promising "X
opens them" and then refusing one setting later is worse than the
sentence it replaced). That asymmetry is deliberate and both halves are
asserted.

### The supplier question then degenerated

With no reading, `resolveSupplier` returns `ask`, which drops into the
ordinary picker — an empty search box over an unfiltered list of every
contact on file, none of them the one on the document, with nothing
said about why. That is the screen in the report.

The machinery the person was asking for **already existed**:
`createSupplierFromScan` pre-fills a new contact from the extraction,
and `_SupplierNotFound` offers it whenever a name was read and matched
nothing. It never ran because there was no reading to match. Fixing the
PDF is what makes it reachable.

What the picker gained is `pickerNote`: three different situations had
been arriving wearing one blank dialog — a name was read, nothing was
read at all, or the page was read and genuinely names no supplier
(`0686`'s payment voucher). The last two said nothing, which reads as a
screen that HAS looked and found nothing.

### And the picture nobody could open

Reported in the same breath: "View the image" answered
`StorageException(Object not found, statusCode: 404)`.

`ocr_scans.storage_path` is where the object was **at the moment it was
read**. `Repo.refileAttachment` then MOVES it — a capture is parked
against a placeholder uuid and moved onto the bill once the bill has an
id — and updates `attachments.storage_path`, not the scan's. So every
scan that successfully became something pointed at a vacated key, and
only the ones that became nothing could be opened. `scan_inbox` prefers
`a.storage_path` now and falls back to `s.storage_path`, which is not
decoration: deleting a document deletes its attachment, and
`ocr_scans.attachment_id` is `on delete set null`, so an orphaned scan
has nothing but its own path left.

## AI SmartScan, end to end

Six commits of reports from somebody using it, and the interesting
thing about them is how many were faults the module already had rather
than faults in the new work.

### What was asked for, and what it turned into

| Asked | Built |
| --- | --- |
| a contact not on the system should start the add-contact flow pre-filled | `createSupplierFromScan` already did this. It never ran because the PDF was never read — so fixing the PDF is the fix |
| "create with all the data that was extracted" | `sendScanOn` (`9b5926e4`) — the same door a fresh capture uses, entered one step in |
| rescan, and rescan with another reader | `ocr_begin(.., p_provider)` (`0698`), and a menu with each reader's price |
| move scanning config out of Settings | `smartscan_settings.dart` behind a "How it reads" chip (`80664d07`) |
| SmartScan second on the phone bar | `19418ab3` |
| "add in the reader list Local Read" | `0700` + the on-device branch of `_offerable` |
| "why csnt read with local" | `0703` — it read, and the RECORDING was refused |
| "when the ai model is not reachable it should read with local" | `readerUnreachable` + `canReadHere` in `scan_runner.dart` |

### Four faults that were already there

- **Every scan that WORKED pointed at a vacated storage key.**
  `ocr_scans.storage_path` is where the object was when it was read;
  `refileAttachment` then moves it and updates the ATTACHMENT's path.
  So "View the image" 404'd on exactly the rows worth opening. `0697`.
- **Payment Methods, Collect Payments, Bank Feeds and Bank Rules had
  ONE construction site each, inside the scanning card**, drawn only
  when the OCR key source was `platform`. A company on its own scanning
  key could reach none of them — how it takes money was gated behind
  who pays for OCR. `80664d07`.
- **`set_ocr_credentials` refused every provider but `claude` and
  `google`**, two names hardcoded in `0111` against what `0113` made a
  table and `0675` added Gemini to. "My own key" was offered for
  Gemini, ChatGPT and Grok and raised `23514` at the save. `0699`.
- **The rescan menu offered a reader for a PDF it cannot open**,
  because `attachments.mime_type` is whatever the picker supplied and a
  browser-chosen file often supplies nothing. `scanIsPdf` asks the name
  too. `da043b63`.

### The judgement worth not re-deriving

**`reads_pdf` is tri-state and the third state is load-bearing.** Null
for `kind = 'device'` because that reader is `pdf.js` in a browser and
ML Kit on a phone, and null for a kind added since `0697` was written.

Null reads as **yes** when deciding whether to BLOCK — refusing on an
unknown would withdraw a reader the platform just added — and as **no**
when deciding what to OFFER, because every name on an offer list is a
promise that pressing it will read this file. `pdfBlock` does the
first, `pdfReaders` and `rescanChoices` do the second. A mutation sweep
is what caught me writing "unknown means yes" in both.

**Build a reader list out of what can READ the file, not out of what
the server will accept.** `ocr_begin` refuses an on-device reader
because there is nothing for the server to do — true, and not a reason
to hide a reader that reads the document on the spot for free. That
single wrong instinct is why Local Read had to be asked for.

**A guard written for one way in goes on answering the old question.**
`ocr_record_local` asked "is this COMPANY set to a device reader"
since `0113`, which was the whole truth while the only way to read
locally was to be set to one. `0700` made it a per-document choice and
the guard stayed — so Local Read read the file, and then

    PostgrestException(message: This organization reads documents with
    Gemini, not on the device, code: 23514)

refused to record it. The reading was thrown away AFTER it had
happened. `0703` asks "is there a device reader to file this against"
instead, and files it against that reader rather than against the
company's setting — a company on Gemini that read one bill here had a
scan row saying Gemini, which is the inbox stating as fact something
that did not happen.

What was protecting the platform was never that guard: it is
`app.require_smartscan`, the company's own switch, `can_write` and the
tenancy of the attachment. `local_rescue.sql` asserts all four next to
the new behaviour, because the way a change like this goes wrong is a
guard leaving with the one that was in the way.

**Falling back to the local reader is the APP's decision, and it is made
on a status.** `0679`'s `ocr_fallback` excludes device readers on
purpose — `and not p.runs_on_device` — because the edge function cannot
run one: the file would have to travel back to the machine that sent
it. So `readDocument` does it, on `retry.ts`'s rule (408, 409, 429, any
5xx, and anything that answered with no status at all), never on the
wording of a message. A 402 is no credit, a 403 is scanning switched
off, a 413 is a file too big — reading those here anyway would be the
app routing around a policy with a reader that happens to be free.
`OcrException` carries `status` since `0703` for exactly this; deciding
by looking for "busy" in the sentence would stop working silently the
day somebody improved the sentence.

## This session's commits

Newest first. Each is a self-contained piece of work with its reasoning
in the commit message — read those rather than the diff.

| SHA | What |
| --- | --- |
| `40a8c53` | Three more dialog openers; the journal editor already got it right |
| `ac26934` | **Fix: the stock card's six columns never fitted a phone** |
| `1cfca06` | The two ticket routing sheets, and the rule they mirror |
| `9811e39` | **Fix: `check_narrow_rows` was doing the wrong arithmetic in both directions** |
| `d005dc4` | **Fix: the same trailing fault again, in the capitalise dialog** |
| `de3f780` | **Fix: a quote-mismatch row had no width left for its own words** |
| `637b3d1` | **Fix: the late-orders dialog threw whenever there was a late order** |
| `4ed1820` | A dialog nothing opens cannot be known to build — `check_dialogs_built.py` |
| `f47f4c6` | The screens-built backlog is empty |
| `99af040` | **Fix: good news was 289 pixels too wide to read** |
| `9b82619` | **Fix: a ticket could not be replied to from a phone** |
| `c086398` | **Fix: a payroll run number went 55px off — the same shape again** |
| `964997d` | Stalls and scales; five real ones left |
| `5efb0df` | Email and delivery setup; seven real ones left |
| `cf784b4` | Recipes and cash flow; nine real ones left |
| `675f351` | Transfers and Onboarding; eleven real ones left |
| `e455910` | The handoff, through the screens-built stretch |
| `09f2c4f` | People and profile built; fifteen left, two of which cannot be |
| `b1c0773` | Six more screens built; the backlog is down to seventeen |
| `df99117` | **Fix: `Uri.base.origin` throws on a phone, and four screens called it** |
| `ce3630f` | Four more screens built, and the sentences they assemble |
| `5ba9f97` | **Fix: a matter number went 37 pixels off a phone, and two gates let it** |
| `462926c` | Correct the last commit: the tickets filter bar was never broken |
| `615aeec` | **Fix: the leads filter bar had never drawn**, and a gate for the shape |
| `bb6505d` | **Fix: the expenses app bar ran off a phone** |
| `025d87c` | A screen nothing builds is a screen nobody has run — `check_screens_built.py` |
| `b635b4b` | The tax stack, walked as one year — cross-layer assertions |
| `4c441a7` | The five tax screens, actually built |
| `a4e9253` | The handoff, through the tax tile |
| `eb1f8d9` | **The taxman's queue, beside the Registrar's (`0674`)** |
| `423e3f5` | **What was payable, and what was paid (`0673`)** |
| `d76211b` | **A revision does not undo the year (`0672`)** |
| `e55c8e5` | **The first year has its own rules (`0671`)** |
| `aa20715` | **A person pays on a different rhythm (`0670`) — CP500** |
| `d4ba69d` | **A deadline that never clears is one nobody reads (`0669`)** |
| `cc1de24` | The handoff, two migrations later |
| `14d6d16` | **The dates LHDN counts from (`0668`) — the filing calendar** |
| `ae74039` | **CP204: the estimate, before it becomes a penalty (`0667`)** |
| `b4e128f` | The handoff, four migrations later |
| `6d5f583` | **Form B and Form P (`0666`), on the machinery Form C already had** |
| `ecf4628` | **Form C: the gap between the accounts and the return (`0665`)** |
| `4b3117f` | Say when the beta button actually appears, rather than that it has |
| `bc0f1e6` | **Capital allowances, Schedule 3 (`0664`)** |
| `4317718` | **A beta tester carries the report button with them (`0663`)** |
| `2063024` | The last screens that were still spinning, and the gate that keeps them |
| `8defd45` | A policy is only half a permission (`0662`) |
| `c692c36` | A policy nobody can evaluate shuts every bucket (`0661`) |
| `46227d6` | Attach a screenshot to a bug report (`0660`) |
| `0e69d4d` | Eleven more skeletons; four dialogs that all open from a figure |
| `7078fc6` | Nine more; the stock card is the second real `TableSkeleton` |
| `0e64536` | **Fix: `functions.invoke` throws, so the release card's refusal handling never ran** |
| `4eb1c59` | Nine on the team and document screens |
| `3c9ac2e` | Twelve across HR, including the editor that is also a new-record screen |
| `d596c44` | The settings cards; `CardRowsSkeleton` gains `leadingHeight` |
| `da3211f` | Ten on the platform console; six screens deliberately left alone |
| `3cde124` | Eleven, two of them tables rather than lists |
| `717b29d` | **A button that builds the iOS app on a Mac it does not own** |
| `3635e0c` | Eleven, the first that is a grid |
| `4a16d1f` | Eight, and two that were right as they were |
| `c996304` | Six, and the grep that had been missing a third of the call sites |
| `c4b83c0` | Seven, and one that already had a skeleton |
| `a5be72e` | Twenty-five screens outline what is coming |
| `339d463` | A deploy that fails on one lost packet should not redden a branch |
| `842fed5` | A phone that rings like a phone — CallKit and PushKit |
| `24adf7e` | Create one and look, rather than asking the catalog about it |
| `551dc7f` | Ask the catalog which database this is |
| `6256953` | CI has two databases, and three migrations argued about the wrong one |
| `7b8a39e` | An iPhone that registers itself (`0658`) |
| `9ce1d22` | The previous version of this file |

Everything older is in the git history with its reasoning in the
message. Read those rather than the diffs.

## Blocked on the user — nothing can proceed without these

1. ~~The new Application ID.~~ **Settled: it stays
   `my.iakauntan.iakauntan`.** Answered 2026-09-20. Nothing changes, so
   the ten-places-at-once problem is closed — but the list is worth
   keeping for whoever revisits it, because they still have to move
   together: `app/android/app/build.gradle.kts` (namespace **and**
   applicationId), `MainActivity.kt`'s package line **and its directory
   path**, `project.pbxproj` (3 Runner + 3 RunnerTests),
   `app/web/.well-known/apple-app-site-association`,
   `doc_scanner_io.dart`'s MethodChannel, `push_native.dart`'s
   `pushChannel` and `callkit.dart`'s `callChannel` against
   `AppDelegate.swift`'s two channel names — **all of which break
   SILENTLY if they drift** — `Runner.entitlements`, `docs/passkeys.md`,
   and `APNS_TOPIC` in the function secrets.

2. **The upload key SHA-256** for `assetlinks.json`, and which
   certificate the one already supplied is. The JSON pasted used
   `delegate_permission/common.handle_all_urls` (App Links) rather than
   `get_login_creds` (passkeys), and carried a single fingerprint —
   the gate refuses that by name, because listing only one works on the
   developer's handset and nowhere else. Whether App Links is wanted at
   all is also open.
3. ~~**Associated Domains** and **Push Notifications** on the App
   ID.~~ **Both done, and proved rather than reported.**
   `Runner.entitlements` asks for `com.apple.developer.associated-domains`
   and `aps-environment`; Xcode refuses to sign against a profile
   carrying neither and names the one it is missing. The archive in
   `ios-release.yml` run 5 signed, so the profile carries both, so the
   App ID has both. This is the useful way to check either of them
   again: a green release run IS the check, and CI cannot be, because
   it builds iOS with codesigning off.
4. **Publish Terms of Use, Terms of Service and Privacy** in the
   platform console. Until then the consent line names them without
   linking, and the new app footer links draw nothing — by design, but
   it looks like the feature is missing.
5. ~~**A new app build**, for any of the mobile work to reach a
   phone.~~ **Done. There is an iOS build in TestFlight.**

   | | |
   | --- | --- |
   | build 4 | `ios-release.yml` run 4, commit `466d91ff` |
   | **build 5** | run 5, commit `08c87ac1` — the current one |

   Both archived, signed and uploaded (`No errors uploading archive`).
   All six Actions secrets and both function secrets exist and work.
   The two things that took four failed runs to find are written up in
   `docs/ios-release.md`'s symptom table; the short version is that
   `flutter build ipa` resolves its own DEVELOPMENT identity before it
   ever reads `signingStyle: manual`, and that an `xcodebuild` build
   setting given on the command line is applied to every pod and Swift
   package too.

   **Android works too.** Version code 5 is on the internal testing
   track, uploaded by `.github/workflows/android-release.yml` through
   the Play API. All five secrets exist. `docs/android-release.md` has
   the setup and a symptom table.

   Three failures on the way, each worth keeping:

   * `app/android/app/build.gradle.kts` signed RELEASE builds with the
     DEBUG key — the Flutter template's TODO, never done. Every release
     bundle this repository ever produced would have been refused by
     Play.
   * R8 stopped the build on four ML Kit script recognizers the
     text-recognition plugin references and nothing here depends on.
     **CI built Android in debug, and a debug build does not run R8**,
     so that whole class went unchecked until the first publish. It
     builds release now, and `check_mlkit_scripts.py` refuses any
     script both asked for in Dart and suppressed in the R8 rules —
     which would otherwise be a NoClassDefFoundError on a handset.
   * The Google Play Android Developer API was never enabled on the
     Cloud project. Creating a service account does not enable it.

   Two rules with no Apple equivalent, both still true for any future
   app: **Play will not take the first bundle from the API** (done by
   hand, once), and **the version code must clear whatever went up by
   hand** (`ANDROID_VERSION_CODE_OFFSET`, added to the run number).

   Firebase is still absent, but that is PUSH, not delivery — the two
   were conflated in an earlier version of this file. An Android build
   reaches Play without a Firebase project; it just cannot receive a
   notification when it gets there.

   One thing left, and it is item 0 of this list rather than this one:
   `GITHUB_RELEASE_REF` is unset, so the console's button dispatches
   `main`, which is behind. Builds 4 and 5 were dispatched against the
   branch explicitly.
6. For push on a phone: the five `APNS_*` secrets (iOS) and
   `FCM_SERVICE_ACCOUNT` + `google-services.json` (Android). See
   `docs/push-notifications.md`. `google-services.json` cannot live in
   this repository.

   **`APNS_PRODUCTION` must now be `true`**, and that is a change of
   answer, not a restatement. It has to agree with the build's
   `aps-environment`, and the build that exists is a TestFlight one —
   a distribution archive, which Xcode signs as `production` whatever
   the checked-in entitlements file says. The old advice here and in
   `docs/push-notifications.md` was "leave it unset while testing",
   which was right when the only handset build came off a cable and is
   now exactly the way to get `BadDeviceToken` on every push. Both
   files carry the table instead.

## The tax computations — `0664` through `0674`

Eleven migrations built a thing this product did not have: the
arithmetic between the accounts and a return, the dates it is owed on,
and a record of what was done about each one. It is worth understanding
as one piece, because each layer only makes sense on the one below.

**`0664` — Schedule 3 capital allowances.** Rates by asset class,
effective-dated, with the motor caps and the small-value rule.
`capital_allowance_schedule(org, year)` produces the working: qualifying
expenditure, initial and annual allowances, the balancing adjustment on
disposal, residual carried forward. An asset carries a
`ca_class_code`, and **null is a real answer** — land attracts no
allowance and never will.

**`0665` — Form C.** The company's computation. The add-backs come off
the CHART OF ACCOUNTS: an account carries a `tax_treatment` and the
computation reads the profit and loss and applies it. What a tag cannot
say is a typed `tax_adjustments` row with a reason.

**`0666` — Form B and Form P**, on `app.tax_business_income`, which is
`0665`'s business half extracted so the three forms cannot disagree
about it.

**`0667` — CP204 and CP204A.** The other half of the year, running the
opposite way: a company says what it will owe BEFORE the basis period
begins, pays that monthly, and is penalised for guessing too low. Two
questions that look like one and are not — the FLOOR is about last
year (below it the estimate is invalid, not low, and LHDN substitutes
its own figure), the EXPOSURE is about this year (an estimate can
clear the floor comfortably and still cost money). A revision is a NEW
row that names the one it replaces, because CP204A is its own form and
next year's floor is measured against the revised figure.

**`0668` — the filing calendar.** Every date the four above are owed
on, computed from the company's own periods rather than stored. SSM's
deadlines had been computed since `0063` and SST's since `0455`;
income tax, which carries the largest penalties of the three, had
none. Nothing is stored per company, so a corrected rule corrects
everybody rather than everybody who asks after today.

**`0669` — what was done about each one.** `0668` had no way to say an
obligation was dealt with, so its list was permanent — the failure its
own header warned about. `tax_filings` records a filing keyed on the
OBLIGATION (type plus period, not the fiscal year: a Form E covers a
calendar year and a Form C the basis period, and both sit against one
fiscal year). Filed and "does not apply" take a row off the list;
merely started does NOT, because a calendar that cleared on the
intention to do something would be worse than one that never cleared.

**`0670` — CP500.** `0667` was company-shaped and `open_tax_estimate`
never asked, so a sole proprietor got twelve monthly instalments on
the fifteenth instead of six bimonthly on the thirtieth — twelve wrong
dates printed as confidently as right ones. `tax_estimate_rules` gains
a FORM, and CP500 has no floor at all: LHDN issues it, so there is
nothing to fall short of. `floor_applies` is the third state that
distinguishes that from "cannot be checked yet".

**`0671` — the first basis period.** `0667` put `first_period` on every
estimate and nothing read it. Both differences are now real: three
months from commencing operations rather than thirty days before the
period opens, and no instalments at all for a qualifying new SME's
first two years. Nothing infers the flag — see below.

**`0672` — the revision re-spread.** Measured, not guessed: revising
RM120,000 to RM240,000 in the ninth month produced twelve instalments
of RM20,000 starting in February, eight of them already past and none
at a figure ever payable on its date. s.107C(7) spreads what is LEFT —
the instalments already due stay where they were, and the revised
total less everything already scheduled divides over the rest. Two
revisions compose. A downward revision takes the remainder to nil
rather than negative, because LHDN does not refund through the
schedule.

**`0673` — what was paid.** The schedule said what was PAYABLE and
never what was paid. `tax_estimate_payments` is keyed to the chain
ROOT rather than to the estimate a payment was made against, because
a revision supersedes that row and the payment has to outlive it.
Overdue, late and partly paid are three different states: s.107C(9)
charges 10% of an instalment paid after its date, which a company can
incur in a year it estimated perfectly.

**`0674` — the tile.** All of the above lived behind the financial
statements screen and an icon. The home screen now carries returns
overdue, returns due within a month with the FORM named, and
instalments unpaid — every figure read from the same functions the
screens use, so there is no second definition of "overdue" to drift.

### Two test files that are not about one migration

**`supabase/tests/tax_stack_end_to_end.sql`** walks a company through
one year — open the computation, open the estimate, pay instalments,
revise, file, roll into next year — and after each step asks the OTHER
surfaces whether they agree. Every mutant it kills breaks ONE
migration and is caught by a question asked of a DIFFERENT one. It
exists because a per-migration test cannot catch a later migration
quietly changing what an earlier one measured, which happened twice in
this stretch.

**`app/test/tax_screens_build_test.dart`** constructs all five tax
screens. Nothing did before, so nothing knew they built. Two faults
were found by breaking them afterwards: the e-filing date could
replace the statutory one, and every instalment could read as paid.

### The five rules that are easy to get wrong and are each asserted

1. **Capital allowances are NOT apportioned** for part-year ownership.
   An asset in use at the end of the basis period gets the full year,
   bought in January or December. `0084`'s `app.months_held` pro-rates
   accounting depreciation to the month, CORRECTLY, and reaching for it
   here by analogy is the single likeliest mistake — there is an
   assertion whose only job is that a December asset and a January one
   come out identical. A secondary source says to pro-rate. It is
   wrong.
2. **Allowances cannot create a loss.** They go against adjusted income
   and stop at nothing; what is left is unabsorbed capital allowance,
   which is NOT a loss and carries forward under its own rules. Adding
   the two together is the mistake the screen's wording exists to
   prevent.
3. **Losses come off statutory income, AFTER the allowances.**
4. **Zakat is a rebate against the TAX, capped at it.** s.6A(3) gives
   relief, not a refund.
5. **A partnership pays no tax.** It allocates. A partner's salary is
   not an expense — a partner cannot employ themselves — so it is added
   back and handed to that partner.
6. **"N months from the date FOLLOWING the close" is not N months from
   the close.** A period ending 30 June runs from 1 July and seven
   months of it ends 31 January, not the 30th. February moves the
   other way: 30 September, not the 28th.
7. **Unknown is never the generous answer.** `0665` charges the
   standard rate and says the SME test was not taken; `0671` schedules
   the instalments and says the exemption was not tested. Both run
   that way because the recoverable mistake is paying too much, and
   the expensive one is a penalty.

### Things that fail silently here

- **A tax treatment on the wrong side of the ledger** drops its line
  rather than applying it. The computation still balances and is wrong
  by whatever that account holds. `tax_computation_misfiled` finds them
  and the Form C screen warns above the figures.
- **An asset filed in a small-value class that is not a small-value
  asset** gets NOTHING rather than the class's 100%. RM2,000 exactly is
  not under RM2,000. The safe direction, and the residual sitting at
  the whole cost is the signal to reclassify.
- **Partnership shares that do not come to 100** allocate a fraction of
  the income and the remainder appears nowhere. The allocation still
  adds up, down its own column, to the wrong total.
- **A first basis period nobody has ticked** gets the ordinary CP204
  deadline, which for a company incorporated partway through a year
  passed before the company existed. Nothing can infer it — see the
  next section — so the box being unticked is indistinguishable from a
  company that is genuinely not new.
- **A first period whose two SME figures are missing** is handed
  instalments it may not owe. Deliberate and stated on the screen, but
  it is money moving on an untested question.

### The limitations, stated to the user and still true

- Every rate in `0664` through `0668` is seeded `is_verified =
  FALSE` — published summaries, not transcribed from the Act. The same
  flag and the same meaning as `0025`'s payroll schedules. **They want
  an accountant's check before anybody files.** In `0668` that covers
  the deadlines themselves, and the e-filing grace on top of them.
- `0664`'s RM20,000 small-value aggregate cap UNDER-claims where a
  company buys more than that in a year: the excess should go at
  ordinary rates and that is not modelled.
- One basis period per year of assessment. A company changing its
  accounting date has a period that is not twelve months, and Schedule
  3 apportionment across it is not modelled.
- Form P assumes the accounts EXPENSED the partners' salaries. Where
  they were shown below the line the allocation over-states by that
  amount; the screen says so.
- ~~`0667` does not model a new company's first basis period~~ — done
  at `0671`, and CP500 at `0670`. What remains is that **nothing can
  infer a first basis period**. The obvious rule, "the company's first
  financial year in this product", is wrong for every company that
  migrated in with history behind it, and `corp_entities` is a
  secretarial firm's CLIENT list with no flag saying which row is the
  company using the software. So it is a switch a person sets, and an
  unticked one looks exactly like a company that is not new.
- **The SME exemption test needs two figures nobody's ledger holds** —
  paid-up capital at the start of the period and gross business
  income. Both typed, and both null means the instalments are
  scheduled.
- **`0668` cannot know whether a particular obligation applies.** A
  CP58 appears for every trading company because the threshold test is
  about payments to agents this schema does not track, and a dormant
  company still gets its Form C because a dormant company still files
  one. It is a calendar, not an assessment of who is exempt.
- **A basis period that is not twelve months is still not modelled.**
  A company changing its accounting date is the case, and `0665` says
  so. `0671` does not change that: a first period shorter than a year
  gets the full instalment count on the ordinary rhythm.
- **Nothing files, and nothing posts.** No submission of anything.
  `0669` records that somebody SAYS a return was filed and `0673`
  that somebody says an instalment was paid — notes with a name on
  them, never verified with LHDN — and neither touches the ledger.
- **The late-payment charge is computed, not raised.** `0673` says
  what s.107C(9) comes to on the instalments already paid late.
  Whether LHDN actually raised it is not something this can know, and
  the screen says so.

### Where they are

Financial statements carries three actions: the calculator picks a
financial year and opens the right form by entity type
(`/tax-computation/:id`, `/form-b/:id`, `/form-p/:id`); the repeat
icon opens the estimate (`/tax-estimate/:id`, with the computation as
a query parameter where one exists — CP204 or CP500, decided from the
entity type); the notes icon opens the calendar (`/tax-calendar`),
which has a segmented toggle between what is falling due and what has
been recorded. Fixed assets → the receipt icon
opens the capital allowance schedule. The account editor carries the
tax treatment picker, and **until accounts are tagged every computation
is the profit unchanged** — which is not wrong, only empty, and the
screen cannot warn about it.

The calendar needs no posting permission to READ, deliberately: it
computes dates and the person who most needs to see a deadline is
often not the one who keys the return. Recording against one does need
it.

The estimate's edit dialog is where a first basis period is declared,
with the commencement date and the two SME figures behind the switch —
they are meaningless without it and hidden until it is on. The estimate opener
does NOT open a computation to measure against — it asks whether one
exists, because opening one writes a document somebody then has to
deal with, and the estimate screen is honest about not knowing.

## Open work, ranked

00. **GEMINI AND THE KEY POOL — built, both halves.** The user asked for Google AI Studio as a SmartScan
   reader, with several keys, per-key limits "time day month", and an
   on/off in the admin console. They chose the widest reading of all
   three questions: caps AND a schedule, platform pool AND per-company,
   and Gemini as another reader in the existing catalog rather than an
   override.

   **Done and pushed.** `0675` is the pool — `ocr_provider_keys`, many
   rows per reader, `org_id` null for the platform's and a uuid for a
   company's own. Each key has a BUDGET (per minute, day, month; null
   is no cap) and a CLOCK (hours, weekdays, months; empty is always),
   and runs only when both let it through. `public.claim_ocr_key` takes
   the next key and spends one call of its budget in one statement,
   round-robin on `last_used_at` so the pool wears evenly.
   `0676` moved that function out of `app` and into `public`, because
   PostgREST does not serve `app` — see the note below, it is the
   sharpest trap in this stretch. The edge function asks the pool first
   on both sides and falls back to the older arrangements, so a
   deployment that has not filled one carries on unchanged. Gemini is a
   row of `kind = 'openai'` against Google's OpenAI-compatible
   endpoint, so there is no new protocol handler; it arrives
   `is_active` false and the Readers screen is the on/off.
   `/admin/reader-keys` in the console manages the platform pool.

   **The tenant half is done too.** `OcrKeyPoolEditor(provider:,
   orgId:, canEdit:)` in `features/shared/` is ONE editor used twice:
   the console hands it a null org id, the Settings card hands it the
   company's, and the database decides who may do what. It sits BELOW
   the single-key field rather than replacing it, for two reasons that
   are not tidiness — the scan asks the pool first and falls back on
   the single key, so a company that never opens it carries on exactly
   as before; and Document AI needs a project, a location and a
   processor, which a pool row has nowhere to put, so that field is
   still the only way to configure that reader at all.

   **The trap worth reading before touching any of this.** A function
   the edge function cannot reach fails by SILENTLY DOING NOTHING.
   `db.rpc("claim_ocr_key")` looks in `public`; `app.claim_ocr_key`
   would have been missed on every scan and the code would have fallen
   through to the old key, so everything would have kept working while
   the pool sat filled and unused with its counters at nought. Anything
   an edge function calls goes in `public`, `security definer`, granted
   to `service_role` alone — `public.ocr_finish` has been that shape
   since `0111`.

   **Also worth knowing.** The caps are counted HERE, not at Google.
   Google's free-tier day rolls over on Pacific time and this schema is
   Malaysian throughout, so a cap set in the console is a budget of our
   own — set it under what the account allows, never equal to it. The
   screen says so.


0a. **The DIALOGS backlog — 50 of 121 openers left. In progress.**
   `scripts/check_dialogs_built.py`, the same idea as the screens gate
   pointed at the other half of the app: **272 dialog and sheet
   classes**, more than there are screens, which the screens gate
   never asked about because a dialog body is not a `*Screen`.

   **It is keyed on the public OPENER, not the class.** 242 of the 272
   classes are private, so a gate demanding `_MappingDialog` be
   constructed would be unsatisfiable for 89% of the surface. The way
   in is the way the app goes in: `showFsMapping(context)`,
   `showPersonEditor(context, person: ...)`. 121 of those exist; 71
   are covered.

   `app/test/dialogs_build_batch_test.dart` is the pattern. Two hosts:
   `opened(tester, overrides, opener)` pumps a button at **412x900**
   whose `onPressed` calls the opener with its own context, and
   `openedWithRef` does the same inside a `Consumer` for the openers
   that want a `WidgetRef` too. Taking the opener as a CALLBACK is
   what lets a test reach a private dialog class.

   Re-seed `EXEMPT` from reality after each batch rather than editing
   it by hand — the gate refuses a stale entry in both directions, so
   it self-checks.

   **Eleven defects so far, and the reason some of them cluster here.** A
   dialog's box is the screen LESS its insets LESS its content
   padding, so about 284px on a 412px phone. The identical `ListTile`
   row throws inside a dialog at 412 and draws on a screen at 360 —
   checked by rendering both. A dialog written at 620 or 760 wide is
   written on a laptop.

   - `late_orders_dialog.dart` returned a `Flexible` into a `SizedBox`
     — `Incorrect use of ParentDataWidget`, on every build of the
     branch that HAS orders, and only that branch.
   - `quote_mismatch_dialog.dart` and `capitalise_dialog.dart` each
     tripped `Trailing widget consumes the entire tile width`. Both
     fixed with `RowActions`.
   - `stock_card_dialog.dart` laid out six columns, four of them
     fixed, totalling 364px in a 284px box. The register scrolls
     sideways now; the closing sentence does not.

   The rest are not about width, and none was visible in a browser
   either:

   - `strata_sheet.dart` printed the Schedule of Parcels as
     `700.0 of 1000.0 allocated`. Share units are numeric, so the
     parcels come back as doubles and the denominator is parsed as
     one. `Fmt.qty` on both now — it drops the zeros on a whole
     number and keeps them on the fractional allocations a schedule
     is still allowed to make.
   - `whyNotBillable` was handed a statutory charge row exactly as
     the database sends it and asked it for `bill_no`, which is not a
     key that row has: `propertyStatutoryCharges` selects the number
     as an embedded `purchase_documents(doc_no)`, and only
     `site_screen` flattens it. So a charge already on BILL-0042 was
     told "Already on a bill." There is now one `billNoOf(charge)`
     that reads both shapes, and `statutory_charge_payment_test.dart`
     asserts the embedded one — every fixture it had used the flat
     key, which is exactly why the defect survived a tested file.
   - **`SearchablePicker` threw `setState() or markNeedsBuild() called
     during build` whenever its value was settled from outside inside
     a `Form`.** `didUpdateWidget` wrote the chosen row's label
     straight into the controller; the controller belongs to a
     `TextFormField`, which tells its `Form` the field changed, and
     the `Form` calls `setState` — mid-build. The share movement sheet
     defaults its class to the first one the moment the list arrives,
     so the first frame after the classes loaded took the sheet down.
     Every register sheet built the same way was one provider
     resolution away from it. The write is deferred to a post-frame
     callback now; `searchable_picker_test.dart` asserts BOTH halves,
     no throw and the box still filled, because deferring a write is
     an easy way to lose it.
   - `charge_sheet.dart` computed the s.352 thirty days as
     `add(Duration(days: 30))` while `CorpCharge.registrationDue`
     computed the same statutory date as calendar arithmetic — with a
     comment on the model saying exactly why the other way is wrong.
     They agree in Malaysia, which keeps no daylight saving, and would
     name different days anywhere that does. One way now, and
     `corp_register_test.dart` asserts the two agree across five
     dates.
   - `hire_dialog.dart` pre-filled the salary box with
     `double.toString()`, so an expectation of RM 4,800.50 arrived as
     "4800.5" — one decimal place in a money box. `toStringAsFixed(2)`,
     which is what the asset editor's cost field already did.
   - `transfer_dialog.dart` said "taken forward to **a invoice**".
     Invoice is the one document singular of fourteen that begins with
     a vowel, and it is the one the product says most often. There is
     an `articleFor` in `doc_types.dart` now, with BOTH halves
     asserted — an article function answering "an" to everything would
     pass the invoice case and read wrongly on the other thirteen.

   **Traps, each paid for once:**

   - `DataRow.key` is NOT a widget key — a `DataRow` is a
     configuration object. Assert on what the row renders.
   - A dialog reading `repoProvider` directly needs a `Repo` fake.
     Give it a `noSuchMethod` that THROWS with the method's name; that
     is how you learn what a dialog needs without reading all of
     `Repo`. And check the real signature before writing `@override`
     — `lateOrders` takes `{DateTime? asAt}`.
   - Get the FAMILY KEY right. `showExpiringDocuments` opens on 60
     days, not 30; the wrong key leaves the real provider live and the
     dialog renders an error view.
   - A `ListView` does not build what the viewport cannot reach. A
     dialog with a paragraph above its list will not construct the
     third row, so assert one row per test when the rows are tall.
     This cost time twice.
   - **An extension method is NOT virtual, so a `Repo` fake cannot
     intercept one.** Great swathes of the repository live in
     `extension RepoProperty on Repo` and its siblings, and Dart
     dispatches those on the STATIC type — so `implements Repo` with
     an `@override` of `rentPreview` is silently ignored and the real
     body runs against a null Supabase client. The seam that holds
     is `callRpc`, which is a method on `Repo` itself: the fake in
     `dialogs_build_batch_test.dart` takes an `rpc` map keyed on the
     function name, and every extension method bottoms out there.
     Check which of the two you are facing with
     `grep -n '^class \|^extension ' app/lib/src/data/repository.dart`
     and the line number of the method.
   - `find.text` reaches INSIDE an `EditableText`. A dialog titled
     with a value it also prefills into a field — the asset editor,
     with the asset number — matches twice, and `findsOneWidget`
     there asserts the form did not load.
   - Material shows a field's helper text OR its error, never both.
     Assert the helper BEFORE tapping Save.
   - `StatusChip` runs its word through `Fmt.label`, which
     capitalises — the chip reads "Default", not "default", whatever
     case the column holds.
   - **The full suite was OOM-killed at `--concurrency=2` once and the
     container restarted.** Nothing was lost (the work was on disk),
     but a run that dies takes twenty minutes with it. Run the single
     changed file first, and keep `--concurrency=1` in reserve — it
     works and is roughly twice as slow.
   - Check whether the opener takes a `WidgetRef` before writing the
     host. `showCreditDialog` does, and four tests written against
     `opened` failed to COMPILE rather than failing an assertion — the
     quickest failure in this whole pass, and the reason to read the
     signature first.
   - Read the `initState` default before asserting on it. The
     statutory charge sheet opens on **assessment**, not quit rent; a
     new charge opens dated **today**, not blank; and a new resolution
     opens **circulated**, not passed at a meeting — so the venue, the
     chair and the attendance chips are not on the sheet until the
     switch is turned on.
   - A `maxLength` truncates before the validator sees it. Typing
     "RINGGIT" into a three-character currency box passes, because
     what arrives is "RIN".
   - Do NOT run `dart format` on a file you touched. The repository is
     not format-clean and it reflows the whole file.

0a-i. **One statutory wording to check with the user, not to change
   on my own.** `resolution_sheet.dart` tells somebody recording a
   circulated **directors'** resolution that it was "Circulated for
   signature under s.297". s.297 of the Companies Act 2016 is the
   members' written resolution; a directors' written resolution comes
   from the constitution and the Third Schedule instead. A new
   resolution opens as kind `board` AND circulated, so this is the
   FIRST thing the sheet says. Left alone deliberately: changing an
   Act reference is a statutory claim, and `README.md` says to read it
   before touching anything statutory. Worth one line of the user's
   time.

0b. ~~The screens-built backlog.~~ **EMPTY — and it found SEVEN
   defects on the way.**
   `scripts/check_screens_built.py` requires every `*Screen` under
   `app/lib/src/features` to be constructed by at least one test. It
   went in with **thirty-eight** exemptions, explicitly a backlog
   rather than a decision, and is now at **two** — and those two are
   `_PreviewScreen` and `_RequestAccessScreen`, private classes that
   no test outside their own library can name. **No amount of effort
   takes them off, so this list is a floor and not a backlog.** All
   115 reachable screens are built by a test.

   **Putting a screen on a surface for the first time found SEVEN real
   defects**, none of which any gate or the analyser could see:

   - the expenses app bar overflowed by 104px at 412 wide;
   - the leads filter bar put a horizontal `ListView` inside
     `FilterBar`, which is a horizontal scroll view — it threw in
     `performResize` on every build and had **never once drawn**;
   - a matter number and its status chip overflowed by 37px;
   - a payroll run number and its chip overflowed by 55px — the
     identical shape, four commits later, and
     `check_narrow_rows.py` passed both for the identical reason;
   - `menu_links_screen.dart` called `Uri.base.origin` inside `build`,
     which throws on every native run, so the published-menus list was
     a column of grey error boxes on the phone and perfect in a
     browser;
   - the ticket reply box overflowed by **252px**, so Send was
     entirely off the right edge and **a ticket could not be replied
     to from a phone at all.** A release build clips that silently, so
     the button was not broken-looking, it was absent;
   - and the largest, **289px**, on the balance card of a set of
     financial statements. The reason it survived is worth keeping:
     the BAD-news branch of the same Row ("Out by RM 1,250.40") fits
     comfortably, so the screen looked correct exactly when something
     was wrong with the accounts and broke exactly when they were
     fine.

   Six of the seven are invisible to a browser, which is where this
   app is mostly looked at. That is the whole argument for the method.

   **That pattern is now being applied to the dialogs** — see 0a
   above, which is where the work is.

   `app/test/screens_build_batch_test.dart` is the pattern. Build at
   **412x900** — an overflow is a test failure needing no assertion —
   put one realistic answer through **every** provider the screen
   watches, and assert something the screen DERIVED rather than was
   handed.

   Three traps, each paid for once:

   - **An empty list can build nothing.** `StockTakeScreen` with an
     empty on-hand list short-circuits to "Nothing to count" and never
     builds its body, so a fixture returning `[]` asserts nothing
     about the screen it names.
   - **Get the family key right.** `PropertyScreen` reads
     `propertySitesProvider('strata')`, not `(null)`, when only one
     property module is held — the filter is not shown and the list is
     narrowed silently. Override the wrong key and the real provider
     is left in place, reaching for the network.
   - **A missing provider renders an error view, not a blank.** Name
     every one, including the ones a screen only reads for a name.

0. ~~The skeleton pass.~~ **Finished and GATED — do not reopen it.**
   All 309 `AsyncView` call sites now account for themselves:
   `skeleton:`, or an explicit `loading:`, or a named exemption with a
   reason. `scripts/check_async_skeletons.py` refuses a new one that
   does none of the three, and refuses a stale exemption too.

   Seven keep the circle on purpose and they share one shape: a lookup
   whose job is to decide WHICH surface to show. The till, the diary,
   the kiosk board and the floor plan each pick a register and then
   draw an entirely different screen; the platform console picks a
   section; the landing preview is `core/page_waiting.dart`'s own
   argument about an operator-edited page. Bones cannot outline a
   branch.

   The gate itself had a bug worth knowing about: it matched the type
   argument with `<[^>]*>`, which stops at the first `>`, so
   `AsyncView<List<Map<String, dynamic>>>` was invisible to it and it
   reported a clean sweep over five bare call sites. What caught it was
   its own staleness check refusing five exemptions that then matched
   nothing. `test_nested_generics` is that bug written down.

1. **Try iOS push and calls on a real handset.** The code is all here
   — `AppDelegate.swift`, `push_native.dart`, `callkit.dart`, `0657`,
   `0658`, `send-push/routing.ts` — and none of it has ever run on a
   phone.

   **This is now the top of the list, and half of what blocked it is
   gone.** Blocker 5 was "there is no build"; there is one, in
   TestFlight, signed with both the push and associated-domains
   entitlements. What remains is blocker 6, the five `APNS_*` secrets
   — and `APNS_PRODUCTION` is `true` for a TestFlight build, which is
   the opposite of what this file said until today. Two things to
   check first, in this order:

   * **does a call make a sound?** `didActivate` sets the audio
     category and nothing else. If the ring connects to silence, add
     the `RTCAudioSession.audioSessionDidActivate(_:)` /
     `audioSessionDidDeactivate(_:)` handshake `flutter_webrtc`
     documents. It is not in the file on purpose: importing `WebRTC`
     ties `AppDelegate.swift` to a CocoaPods module name, and a rename
     would break the iOS build for everybody rather than being a quiet
     audio bug for one person.
   * **does `APNS_PRODUCTION` agree with the build's
     `aps-environment`?** Crossed, every notification comes back
     `BadDeviceToken`, which reads as a dead handset and is not one.

2. ~~**Set up the iOS release secrets, then press the button
   once.**~~ **Done.** All eight secrets exist, and `xcrun altool
   --upload-app` — which nothing in CI could ever exercise — has now
   run twice and uploaded twice.

   The build number comes from `github.run_number`, so it is the
   workflow's run number and NOT a count of builds: a failed run burns
   one. Builds 1 to 3 do not exist in TestFlight because runs 1 to 3
   failed. The marketing version comes from `pubspec.yaml` and is still
   `0.1.0`.

   What is left of this item is one secret, in blocker 0 above:
   `GITHUB_RELEASE_REF`. Set it and the console button is usable;
   until then the button builds `main`, which is stale.

3. ~~Make the local stack match the hosted project on function
   privileges.~~ **Done.** `_local_stack.sql` now reproduces Supabase's
   `grant all on functions to anon, authenticated, service_role`, and
   the two files that encoded the opposite are corrected. The cause was
   that CI has TWO databases — `supabase start` for the SQL assertions,
   the linked hosted project for the migrations — and nobody had said
   which was being measured.
4. **What the tax stack still does not do**, in the order it would be
   worth doing. None is started; each is honest work rather than a
   gap somebody will trip over:

   * ~~CP500 for individuals~~ — done at `0670`.
   * ~~A company's first basis period~~ — done at `0671`.
   * ~~Marking an obligation as met~~ — done at `0669`.
   * ~~Tracking an instalment as PAID~~ — done at `0673`. What
     remains of it: **nothing posts to the ledger**, and having now
     looked at what that would take, it is blocked on a decision
     rather than on effort.

     The obvious cheap version — linking a tax payment to the bank
     line that paid it — **cannot be done**. `match_bank_transaction`
     resolves a `gl_entry_id` for whatever it matches and refuses
     anything without one, because completing a reconciliation needs
     to know which ledger entries the bank has already seen. A link
     that bypassed that would mark a statement line as matched with
     nothing behind it and leave the reconciliation out by the
     amount. So it has to be a real journal.

     And a real journal needs an accounting policy nobody here can
     choose: a CP204 instalment is either an asset (tax paid in
     advance, recoverable at assessment) or a draw-down of a tax
     liability already provided for, and which one depends on the
     company. Guessing puts wrong journals in somebody's books. **Ask
     the user which account, then build it**: a mapping, a posting
     function, reversal on `clear_tax_instalment`, and a closed-period
     refusal. The existing matcher then works unchanged.
   * **Form BE**, the return for a person with no business income —
     due 30 April, two months before Form B. Low value: a person with
     no business is not using an accounting product. `0668` names it
     in a description rather than seeding it.
   * **A basis period that is not twelve months**, which is a company
     changing its accounting date. Stated as unmodelled since `0665`
     and still is.

5. **Task #11, the MIA headless scraper** — blocked, MIA unreachable
   from here. Do not start without the user.
6. Older backlog, not to be started unprompted: `close_fiscal_year`
   sweeping to 3200 vs 3300; stripping the posting redirect out of
   `0635`; P14 per-document rounding; G3(b) relaxation flag.

## The environment, exactly

Nothing below is optional. `flutter` and `deno` are not on the default
path and the database is a throwaway cluster that stops on its own.

```bash
export PATH="/opt/flutter-3.47.4/bin:$PATH"          # flutter
export PATH="/tmp/iakauntan-deno/node_modules/.bin:$PATH"   # deno
DB="postgresql://postgres@/postgres?host=/var/tmp&port=5599"
```

**When the cluster has stopped** — and it does, repeatedly — several DB
gates fail at once with `psql` exit 2. A dead database and a broken gate
are indistinguishable from an exit code, so check this *first* rather
than debugging the gates:

```bash
su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D /var/tmp/pgdata \
  -o '-k /var/tmp -p 5599' -l /var/tmp/pg.log start"
```

### The gates, in the order that finds faults soonest

```bash
# 1. SQL — rebuilds a throwaway Postgres, ~2 minutes
./supabase/tests/run_locally.sh

# 2. Edge functions — type-checks all of them and runs the deno tests
#    CI runs, reading the list out of ci.yml so it cannot drift
./supabase/functions/_local_check/check_locally.sh

# 3. Widget tests
cd app && flutter test --concurrency=2 --reporter failures-only

# 4. Analyser LAST
flutter analyze --fatal-infos --fatal-warnings
```

### All fifty-six `check_*.py` files — run every one, every time

**Forty-five are gates; eleven are gates' own assertions.** The loop
below runs all fifty-six, which is what you want: a gate that is wrong
is worse than no gate, because it is believed. The figure was once
written here as "forty-eight", which was the total then and read like
a count of gates — it was not.

`check_dialogs_built.py` is the newest, and "Open work" 0a above says
what it does and why it is keyed on openers.

**`check_narrow_rows.py` was corrected rather than extended**, and the
correction is worth knowing because the gate had been quietly wrong
for as long as it has existed. It counted a money figure written as
`Text(Fmt.money(...))` as ZERO — only the `Money` widget counted — and
it SUMMED children that stack, so a Column of two figures measured
twice its width. Two shipped dialog rows passed it and two innocent
screen rows would have been accused. It now looks inside every `Text`
for a money call, and recurses: a Row is the sum of its children, a
Column or a Wrap is the widest. Verified against all four cases, not
just the two that were broken.

Three of the forty-five are new this week and each was written because
a defect had already shipped through the gap:

- `check_nested_scrollables.py` — an EXPANDING viewport inside a
  scroll view on the axis it scrolls is offered infinity and asserts
  in `performResize` before it draws. `ListView`, `GridView`,
  `CustomScrollView`, `PageView`, `ReorderableListView`,
  `NestedScrollView` and `TabBarView` expand;
  `SingleChildScrollView` sizes to its child and does NOT, so it is
  allowed. Every entry in that table was settled by building the
  widget and watching whether it threw, after the first version of
  the gate accused a screen that was fine.
- `check_web_only_apis.py` — `Uri.base.origin` throws on any scheme
  but http and https, and `Uri.base` is a `file:` URI on every native
  platform. `Uri.base.host` and the rest are fine; only `origin`
  throws. `kIsWeb` within three lines above counts as a guard.

```bash
for f in scripts/check_*.py; do
  out=$(timeout 600 python3 "$f" 2>&1) \
    || out=$(timeout 600 python3 "$f" "$DB" 2>&1) \
    || { echo "FAIL $f"; echo "$out" | tail -6; }
done
```

Running a remembered handful is how CI run 1931 was allowed to fail.
**CI's job uses `shell: bash -e`, so it stops at the FIRST failing
gate** — green-after-one-fix is not evidence the rest pass.

After any migration: `python3 scripts/generate_api_description.py "$DB"`.

## Process rules that cost time to learn

- **`flutter test` can exit 0 with failures.** Read the
  `+N: All tests passed!` line. Never trust the exit code.
- **Do not `git add -A`.** Stage by name.
- **`git commit -F` and `-m` cannot be combined.**
- **Bash rejects heredocs containing literal control characters** — use
  the Write tool for anything with em dashes or unusual punctuation.
- **`mutate.py` takes app-relative paths** (`lib/...`, `test/...`). The
  control's description must **begin** with `CONTROL` and it must be
  **last**. `$` in a mutant string needs a raw string or it silently
  fails to match and is reported as HARNESS ERROR.
- **The cheapest CI check**: `mcp__github__actions_list`,
  `method=list_workflow_runs`, `resource_id=ci.yml`, `perPage=2`,
  `minimal_output=true`, filter
  `{"branch":"claude/…","status":"completed"}`.
  **Stale pages are common on that endpoint — seen three times.** If
  `total_count` moves backwards or the newest run is days old,
  re-query. `status:"success"` caches badly; `status:"completed"` has
  been reliable.
- **Reading a failed CI job**: `mcp__github__get_job_logs` with
  `failed_only`, `return_content`, `tail_lines: 200`. The useful line
  is the `ERROR: … (SQLSTATE …)` one, which sits well above the tail —
  a short tail shows only the echoed SQL and tells you nothing.
- **PR #3 is `main → this branch`**, making this branch the BASE. Do
  **not** rebase or force-push. Always fetch before pushing.
- Watch CI after every push. `send_later` (minimum 1 minute) for the
  check-ins; `create_trigger`'s cron minimum is 1 hour, which is too
  coarse.

## Traps found this session

Each of these was paid for once. None is obvious from the code.

**A surviving mutant can be a mutant of a different function.**
`scripts/mutate.py` applied each pattern with `replace(old, new, 1)` —
first match, no uniqueness check. `statement_import.dart` holds two
parsers that both contain `if (date == null) {` above `problems.add(`,
so a mutant aimed at `scannedStatement` landed in `parseCsvStatement`,
whose branch that test file does not reach, and survived **under the
name of the function whose assertion was there and correct all along**.
The control cannot catch this — it applied cleanly and the baseline
passed. Hand-applying the mutant to check the harness reproduces the
survival, because it means pasting the same ambiguous pattern and
hitting the same first match; it reads as confirmation and is not one.
The harness now refuses an ambiguous pattern, reports un-applied
mutants under **NOT RUN** and exits 1, and `apply_once` is asserted in
`scripts/mutate_test.py`. Full write-up in `docs/widget-tests.md`.

**Not every nested scroll view is broken, and I said four of them
were.** A `ListView` inside a same-axis scroll view throws; a
`SingleChildScrollView` inside one does not — it is built on
`_RenderSingleChildViewport`, which sizes to its child rather than to
its constraints, so it draws, and the outer keeps scrolling. I wrote a
commit message, a code comment and a CI step name saying
`tickets_screen.dart` had "never drawn", and it had drawn perfectly
well. What caught it was writing the test EXPECTING it to fail against
the unfixed screen and watching it pass. `462926c6` is the correction.
**Establish which it is by pumping the two shapes and looking**, not
by reasoning about render objects — it takes two minutes.

**`Uri.base.origin` throws; it does not give a wrong answer.**
`Bad state: Origin is only applicable schemes http and https`, and
`Uri.base` is a `file:` URI on Android, iOS, macOS and Windows — so an
unguarded call is a crash on every native run and is invisible to a
web build, which is where this app is mostly looked at. Four had
shipped. `shareOrigin()` in `core/safe_link.dart` is the answer and
`check_web_only_apis.py` is the gate. A widget test catches it for
free, because `Uri.base` is a `file:` URI in the test harness too.

**`check_narrow_rows.py` measures two things as zero**, and it is not
fixable inside the estimate: a bare `Text(matter.matterNo)` (no
quotes, no `$`, so neither a literal nor an interpolation) and a
trailing `Column` whose widest line is a bare `Text`. Counting the
bare expression as an unknown was written, run and reverted — it does
not close the gap, because the number that is wrong is the ROOM, not
the want. `docs/widget-tests.md` carries the full account. The thing
that catches it is building the screen at 412px.

**A screen nothing constructs cannot be known to build.** Five were
written in one stretch with a full set of tests underneath them, every
one of those tests on the MODELS, and nothing anywhere called any of
the five constructors. They did build; that is luck rather than
evidence. `scripts/check_screens_built.py` now refuses a new screen
that no test puts on screen, and its exemptions are a BACKLOG that
should shrink — unlike `check_async_skeletons.py`'s seven, which are a
decision. Thirty-eight when it went in, fifteen now, and see "Open
work" above for what putting those twenty-three on a surface found.

**Do not run the DB gates while `run_locally.sh` is rebuilding the same
database.** It drops and rebuilds the local cluster's schema, so
anything asking that database mid-run sees a half-built one:
`generate_api_description.py` wrote 696 functions instead of 762, and
`check_query_columns.py` and `check_rpc_grants.py` reported every new
relation missing. None of it was real. Wait for "all SQL assertions
passed", then regenerate and re-run.

**`select ... into` takes the first row and says nothing about the
rest.** So widening a table's key can silently change what an OLDER
test measures. `tax_estimates.sql` looked up its rules by year alone;
that was unambiguous until `0670` gave the table a second row per
year, after which it was reading whichever row the heap handed back —
and it kept passing, because that happened to be the right one.
`0671` rewrote the rows and it finally failed. A green suite is not
evidence a query still means what it did.

**`scripts/mutate_sql.py` extracts a `create or replace function`
block.** A bare `create` after a `drop` — which is what a changed
return type needs — is invisible to it, and the sweep reports HARNESS
ERROR rather than pretending to have tested anything. Write
`drop ... ; create or replace ...`.

**An OUT parameter sharing a name with a column is ambiguous.**
`tax_estimate_exposure` gained an OUT parameter called `form` and its
own `where form = e.form` stopped compiling. Postgres refuses rather
than guessing, which is the good outcome — the guess would have
compared the rules to an uninitialised output. Alias the table.

**A migration that ALTERs is not idempotent.** A `create table` fails
the second time with a message that stops psql; an `alter table ...
add column` does too, and there is no re-running the file to recover
from a failure halfway down it. Write the teardown alongside the
migration — drop the columns, restore the old key and constraint,
delete the seeded rows — and keep it until the migration is pushed.

**`tenant_foreign_keys.sql` refuses `on delete set null` on a
composite key.** The pair includes `org_id`, which is NOT NULL, so
nulling the reference would null the tenant. NO ACTION, and usually
the refusal is what you wanted anyway.

**A surviving mutant in table-driven code is often a missing FIXTURE.**
Not a missing assertion. Three of them this session: one fiscal year
could not show that a recorded filing is keyed on the period; a
Sdn Bhd fixture could not reach the Form B branch at all; and
`floor_applies` was indistinguishable from `floor_known` until a
company existed whose floor applied and was unknown.

**Six and twelve both divide 60,000 evenly.** When a rhythm changes,
the DATES are the assertions and the amounts prove nothing.

**`mutate.py` replaces the FIRST occurrence in the file.** A mutant
written as `periodFrom: Fmt.parseDate(j['period_from']),` matched four
model classes, mutated the one nearest the top, and was reported as a
SURVIVOR — a missing assertion about code the test never loads. The
harness has no way to notice: the mutation landed, it just landed
somewhere else. Anchor a mutant on a neighbouring line whenever the
string is not unique, and `grep -c` it first when in doubt.

**`make_date(2027, 2, 31)` raises before anything can clamp it.** The
obvious spelling of "the last day of a month" —
`least(make_date(y, m, 31), end_of_month)` — fails on exactly the case
it exists for, because the argument is evaluated before `least` sees
it. Count forward from the first of the month instead.

**"N months from the date FOLLOWING the close" is not N months from
the close.** A period ending 30 June runs from 1 July, and seven
months of it ends on 31 January — a day after `end + 7 months` gives,
and 30 January is late. February moves the other way: 30 September,
not the 28th. Written as "forward a day, forward the months, back a
day".

**A grace period in days is not the same grace in months.** A month
from 31 January is 28 February; thirty days from it is 2 March. Two
days past a deadline somebody filed against. `0668` stores both units
for that reason.

**A December year end makes every statutory clock agree.** The basis
period, the year of assessment and the calendar year of remuneration
all end on the same day, so a Form E measured from the wrong one still
comes out right and a fixture built on one passes over every error.
Use a 30 June year end for anything date-shaped.

**An entity type can keep a whole branch from ever running.** The
mutant that made a return due IN the year of assessment rather than
the year after survived a sweep whose only fixture was a Sdn Bhd — a
company never reaches the Form B branch, so nothing exercised it. A
surviving mutant in a table-driven function is often a missing
FIXTURE, not a missing assertion.

**`pg_temp.check_refused` takes a LIKE pattern, not a substring.**
Without a trailing `%` it fails on the very message it was written to
match, and reports it as "refused, but for the wrong reason".

**A mutation harness that reports everything killed is broken.** A
migration is not idempotent, so re-applying one to the same database
fails on "already exists" — and every mutant after the first reads as
KILLED, including the control. The first capital-allowance run reported
four mutants killed and proved nothing. Run the migration and its test
inside ONE transaction the test's own `rollback` undoes, and always
include a control that must SURVIVE.

**And it leaves the database without the migration.** That rollback
takes the schema with it. `check_query_columns.py` then reports "no such
relation" for every new table and `check_rpc_grants.py` reports every
new function granted to nobody. Re-apply the migration and regenerate
`docs/api` before running the gates.

**`Positioned` must be a DIRECT child of its `Stack`.** A `LayoutBuilder`
between them throws "wants to apply ParentData of type StackParentData
to a RenderObject set up to accept BoxParentData". Wrap the builder in
`Positioned.fill` and put a second `Stack` inside it.

**A widget in `MaterialApp.builder` is ABOVE the navigator.** The
builder's child IS the navigator, so `Navigator.of(context)` walks
upward and finds nothing — "Navigator operation requested with a context
that does not include a Navigator", on every tap, in production, under a
green test suite. `core/router.dart` exports `rootNavigatorKey` for
exactly this. A test that wraps the widget under `home:` puts it BELOW
the navigator and proves nothing.

**`pg_temp.sign_in_as` does not change the database role.** It sets the
JWT claim; the session is still `postgres`, which owns every table and
is exempt from row level security. A `check_refused` on a direct insert
therefore passes as the OWNER — the insert succeeds. Issue `set local
role authenticated` at the top level (it does not survive a `do` block)
and `grant select` on any temp fixture table the block reads.

**RLS does not raise on an UPDATE it hides.** It updates no rows,
silently. Assert by EFFECT — read the value back — rather than with
`check_refused`, which fails with "it was not refused at all". An
INSERT does raise, because `WITH CHECK` is about the row being written.

**postgrest-dart defaults `ascending` to FALSE.** A bare
`.order('sort_order')` is Z to A, and supabase-js defaults it the other
way, so the same call means the opposite in an edge function.
`check_order_direction.py` catches it.

**`0.14 * 100` is `14.000000000000002`.** Round before formatting a
percentage or it goes into the dropdown exactly like that.

**A `Column` of a fixed-height strip and a body OVERFLOWS.** In debug
that is the yellow stripe; in RELEASE it is clipped silently, so the
screen looks right and the content has quietly lost its last row.

**A `TabBar` with text-only tabs is 48 pixels, not 46.** Test against a
real one rather than against the number.

**A `revoke … from public` does not remove a direct grant.** A hosted
Supabase project's default privileges hand a newly created function in
`public` an EXECUTE grant held *directly* by `authenticated`. Revoking
from the PUBLIC pseudo-role leaves it. `0141` and `0143` write
`from public, anon, authenticated` in full; `0657` wrote a third of it
and CI refused the migration on its own self-check. **Write all three
roles out, every time.**

**The local run catches it now, and did not before.**
`_local_stack.sql` reproduces the default privilege as of this branch,
and reintroducing `0657`'s missing two words makes the migration refuse
itself on this machine with CI's exact error. Before that it passed 333
local files and was refused by CI twenty minutes later.

**CI has TWO databases and it is easy to measure the wrong one.**
`supabase start` brings up the CLI's local stack, which is where every
file in `supabase/tests/` runs. The migrations are pushed to the
*linked hosted project*, in a different job. They do not have the same
default privileges for functions, and three migrations plus two CI runs
were spent arguing past each other because nobody said which database
an observation came from. When an assertion about privileges behaves
differently in two places, ask that question first.

**A default ACL belongs to ONE role, and `pg_default_acl` will happily
show you somebody else's.** Filter on `defaclrole` or do not read it at
all. `supabase start` has a function default for `public` naming
`authenticated` under a role that is not the migration runner, so a
check that read the rows unfiltered answered "present" and then watched
a new function arrive callable by nobody. `0498` learned this for
tables; CI run 1947 relearned it for functions. When a test needs to
know what a new object arrives with, CREATE one and look.

**Dropping a function drops its COMMENT**, and
`check_undocumented_writes.py` refuses a write function without one.
Re-state the comment whenever you drop and recreate.

**`create or replace` with a new signature OVERLOADS, it does not
replace.** PostgREST then resolves a call that omits the new argument
to the old function, silently. Drop first. For a set-returning function
it is stricter still: the OUT parameters *are* the return type, so
adding a column makes `create or replace` refuse outright.

**Deno's ECDSA is deterministic.** Two signings of one string with one
key are byte-identical, so a test cannot distinguish "minted fresh"
from "came back from cache" by comparing strings. Move the clock
instead. A test that appeared to check this was really checking clock
arithmetic, and passed with the code deleted — found by mutation, not
by review.

**postgrest-dart's `.order(column)` defaults to DESCENDING.** Pass
`ascending: true` explicitly. `scripts/check_order_direction.py` names
the columns this has already reversed.

**`context.canPop()` throws where there is no GoRouter, and it is
called at BUILD time** — so a screen using it cannot be rendered
outside a router at all, which is a preview and embedding problem as
well as a test one. `GoRouter.maybeOf(context)` answers null, and null
is the right answer anyway.

**Two gates have failed on their own documentation.** A regex looking
for code found the migration header quoting the code it was fixing.
`check_passkey_association.py` and `check_realtime_topic.py` both did
it; the latter strips whole-line `--` comments now.

**`functions.invoke` THROWS on a non-2xx — it does not return a
response with a status.** Code shaped like

    final res = await client.functions.invoke('...');
    if (res.status >= 400) { ... }

is a branch that can never run, and whatever is inside it never
happens. This shipped in `iosReleases()` and the console drew a raw
`FunctionException(status: 503, details: {...})` under the words
"Something went wrong" at somebody whose only mistake was not having
added a secret. `ssm_search_service.dart` and `ssm_repository.dart`
both had it right first. Catch `FunctionException` and read
`e.details`.

**And a refusal is not always an error.** The same fix is worth more
than the catch: a 503 meaning "nobody has set this up" belongs in the
DATA arm, not the error arm, or the screen shouts at somebody who has
done nothing wrong. `iosReleases()` returns a result type for that
reason.

**`Bone` is abstract and its concrete classes are private**, so
`find.byType(Bone)` in a widget test matches nothing at all — it does
not fail loudly, it finds zero widgets. Key the bone and find it by
key. `CardRowsSkeleton`'s leading bone is keyed
`skeleton-card-row-$r-leading` for exactly this.

**A widget test that passes has proved nothing.** Break the source on
purpose and watch it fail — `python3 scripts/mutate.py <source> <test>
<mutants.py>`, always with a no-op control, because a harness that
errors on every run reports a clean sweep. `docs/widget-tests.md` lists
ten ways a green test covers a broken screen. For Deno there is no
equivalent harness; do it by hand with `sed`/`python3` and restore
afterwards.

## Things the database already knows that are easy to re-derive wrongly

- `app.contact_blockers` reads `pg_constraint` rather than carrying a
  list of tables, so a table added tomorrow is covered. `public.todos`
  is the one deliberate exemption and is named explicitly.
- Composite foreign keys per `0511` are `(org_id, x)` referencing
  `(org_id, id)`, and **in half of them `org_id` comes first** — so
  `conkey[1]` reads the wrong column and answers questions about the
  organization instead of the row.
- `0014`, `0016` and `0100` sum **leaves** (`and not a.is_group`), which
  is why promoting a posting account to a heading silently removes its
  balance from three statements at once. `0655` is built around that.
- Demo accounts ship a password **inside the bundle**. Every gate in
  front of them is cumulative and is only ever added to, never replaced.
