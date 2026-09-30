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

### THE "NOT DONE" LISTS GO STALE. CHECK BEFORE YOU BUILD.

Not a hypothetical, and not one slip. In a single session on
2026-09-28, five separate entries in this file described work as
outstanding that had already been done:

| This file said | Actually |
| --- | --- |
| Per-kind PDF handling is next | Done by `0697` and `0701` |
| The bill editor and expense form need the matter picker | Done by `document_editor.dart` and `0692` |
| The client-side general journal screen is not built | `legal/client_transfer_screen.dart`, routed |
| Nothing reads `OcrExtraction.fields` | `scan_field_map.dart` does |
| Statement lines are not turned into `bank_transactions` | `importBankTransactions`, wired |

Each cost a round of reading to disprove, and one of them — the matter
picker — nearly cost building something twice.

**The cause is structural, not carelessness.** An entry is written when
the work is deferred and is never revisited when the work is done,
because the person doing it is solving the problem rather than auditing
prose about it. Nothing in CI reads this file, so nothing can catch it
the way `check_screens_built.py` catches a screen with no test.

**So: grep for the thing before you build it.** A `grep -rln` for the
function, the column or the widget takes ten seconds and is the only
thing standing between you and reimplementing something that shipped
three migrations ago. The entries below marked with a strikethrough have
been checked; the ones that are not, have not.

### The container restarts without warning, and that rule is why

It happened in this session, after `8b9d390e` and with no prompting.
**Nothing was lost**, and the reason is the paragraph above rather than
luck: the tree was clean and `HEAD` matched `origin` exactly. A restart
costs nothing if every push has landed, and costs whatever is uncommitted
if one has not. Check with

    git status --porcelain && git rev-parse HEAD origin/<branch>

**Background work does NOT survive it, and no notification arrives for
what was running.** A session waiting on a backgrounded `mutate.py` sweep,
a `flutter test` run or a timer simply never hears back. So a long sweep's
findings want writing down — into a commit, or at least into this file —
as they arrive rather than at the end. What the restart took here was only
a stale wait-loop whose sweep had finished several commits earlier.

### A `pgrep` wait-loop matches itself

Paid for twice in one session, and it looks exactly like work in progress:

    until ! pgrep -f mutate.py >/dev/null; do sleep 20; done   # never exits

`pgrep -f` matches the full command line, and the loop's own shell has
`mutate.py` in its command line. So the condition is true forever, the
loop reports `RUNNING` long after the sweep has finished, and further
copies of the same loop keep each other alive. Three of them were still
spinning when the container went.

**Escaping the pattern is NOT the fix, and that was checked rather than
assumed.** A test written to compare `mutate.py` against
`"scripts/mutate\.py"` hung on BOTH, including with no such process
running at all — because the probe's own `bash -c "until ! pgrep -f
<pattern> ..."` command line embeds whatever pattern it is probing with.
That is the same effect one level up, and it means a self-referential
test cannot tell the two apart. Whether quoting saves a given loop depends
on which escape characters survive into its command line, which is not
something to rely on.

**Wait on what the job WRITES instead**, which has no self-reference in it:

    until grep -q "restored:" out.log 2>/dev/null; do sleep 20; done

Verified both ways: it exits once the marker appears, and it keeps waiting
while the file exists but is empty. `mutate.py` always ends with
`restored:`, `flutter test` with `All tests passed!` or `Some tests
failed`, and the gate sweep with `FAILURES=`. Pick the line the job cannot
finish without printing.

## Where things stand

| | |
| --- | --- |
| Branch | `claude/iakauntan-accounting-crm-8snun0` |
| Head at time of writing | `4a04963f`, the ninth commit of this session. What each one did is the table under **What this session shipped** below |
| CI | **green through run 2154 (`4a04963f`)** — every one of this session's nine commits green, four of them on the first attempt after the pull fix. Confirmed by reading the runs rather than inferring them; 2150 is the one that proved the authenticated docker pull works, see below. 2146 (`0ba8b12c`) applied `0721` live and deployed `platform-users`; both were verified against production — the two functions exist and the edge function is ACTIVE at `verify_jwt: true`. Do NOT take a green run as proof a migration landed: the apply job SKIPS when a newer commit is at the branch tip, which nearly had a `0719` reported live in this session when it was not. Check the database. | 2103 applied `0704` live and deployed. Eight runs went red in this stretch and only ONE was the diff: 2084 (Android JDK quota), 2085 (Deno dependency age), 2090 (**mine** — three imports left behind by a move), and 2097–2100 (`ghcr.io` refusing anonymous pulls — the backoff was widened first and run 2100 proved that was not it, so the images now come from `public.ecr.aws`). All written up below |
| Migrations | `0721` is the highest, and `0716`–`0721` are ALL applied live and verified against production — `platform_users` and `platform_update_user` were read back out of the hosted database, not inferred from a green run. CI applies on green — see below |
| Live database | **level with the branch.** Edge functions deployed on the same run |
| Mobile | **iOS build 5 in TestFlight, Android version codes 5 and 6 on Play internal testing.** Both from this repository's own workflows |
| Gates | 380 SQL assertion files, **53 Python gates (+17 gate self-tests)**, **6,439 Flutter tests**, 39 deno test invocations. Both build backlogs are **ZERO**: every screen and every dialog opener is built by a test |
| API description | 807 functions, 367 tables, version `0721` |
| In-app calling | **ON**, 30 September. The mediasoup SFU and coturn run on a Synology DS224+ behind a public address; `CALL_SFU_URL` and the rest are set. Proved the only way that counts — two devices on different networks, one on mobile data. `docs/call-deployment.md` is the runbook and its last section lists the four failures that were actually hit |
| Rows put in production BY HAND | One set, 29 Sept 2026: the App Review demo company `iakauntan-demo` and the two accounts that ring each other — see `docs/apple-voip-review.md`. It is NOT in any migration and nothing in the schema records it, which is why it is named here. `0724` is the function that wires such a pair; the accounts themselves were made in the console, because an account cannot be created from SQL |

## What this session shipped

Nine commits, all green. The first two are the product work; the rest came
out of watching CI and reading its logs, which is where most of the
interesting findings were.

| Commit | Run | What |
| --- | --- | --- |
| `0ba8b12c` | 2146 | **Console: the people on this platform.** `0721`, the `platform-users` edge function, Users and Support access as console pages, support-access banner on every screen. Live and verified in production |
| `8c5ea0c4` | 2147 | **Every screen and every dialog built by a test.** Both backlogs to zero — dialogs 105 → 50 → 0, screens 38 → 2 → 0 |
| `56149eb6` | 2148 | The CI line in this table, 24 runs stale |
| `5ad922bd` | 2149 | Diagnosis of the edge-runtime image quota |
| `cc179f48` | 2150 | **The authenticated docker pull**, with the old registry kept as a fallback |
| `da2495b2` | 2151 | What 2150 proved about it |
| `4ab9f77f` | 2152 | One registry per job; the local dump does pull after all |
| `8b9d390e` | 2153 | Confirmation that the double pull is gone |
| `4a04963f` | 2154 | The container restart, and a wait-loop that watched itself |

**What found what**, which is more useful than a count:

- `check_routes.py` refused the banner's `context.go('/admin/support-access')`
  — and investigating showed the gate had never been able to see ANY
  console route, because the router builds them in a loop. It reads them
  off the section table now: 179 routes, up from ~147.
- `dropdown_census_test.dart` caught the role picker twice over: not on the
  census, and missing `isExpanded: true`. The second was the same 49-pixel
  overflow a widget test had already found, from a different direction.
- `shell_rail_scroll_test.dart` broke for the fourth time. Its own comment
  said a fourth time meant deriving the height rather than guessing, so it
  measures the rail's overflow now and follows a destination added tomorrow.
- A **new** test found the `credit_ledger_dialog` overflow, once it was fed
  one realistic row. Nothing pre-existing could have: the totals line does
  not exist in the empty state the dialog had been "tested" with.
- Reading CI's own logs found the rest — `db dump --local` pulling when a
  comment said it did not, and the same image coming down twice.

And one lesson rather than a defect, now the eleventh way a green widget
test asserts nothing: fifty dialogs opened cleanly with every provider
answering `const []`, fifty passes, nothing learned.

**Three things I got wrong and corrected**, each written up where it
belongs rather than only here: `db dump --local` does pull (a comment in
this workflow had said otherwise for a long time, and I repeated it);
`cc179f48` made the same postgres image download twice under two names;
and escaping a `pgrep` pattern does not stop a wait-loop matching itself.

**Still yours to decide**, unchanged: CP39, KWSP Form A and PERKESO
Lampiran 1 need their published layout specifications, not more code.

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

## The image quota is not a backoff problem, it is an anonymity problem

**Fixed in `cc179f48`, and proved by run 2150 — see the end of this
section.** The diagnosis is kept in full because it took two wrong
remedies to reach, and because the shape of it generalises: a quota bound
to the runner cannot be waited out.

Run 2148's **"Deploy the edge functions" failed on attempt 1** and passed
on attempt 2, which nobody in this session asked for — the re-run's actor
is the account, and I did not trigger it.

    public.ecr.aws/supabase/edge-runtime:v1.74.3
    Error response from daemon: toomanyrequests: Data limit exceeded

**All four retries failed — 60s, 120s, 240s apart — and then a fresh
runner succeeded within a minute.** That is the whole diagnosis: the cap
is bound to the RUNNER, not to the clock, so no backoff on the same
machine can ever clear it. `retry.sh`'s widening delays are the right
shape for `ghcr.io`'s per-minute request limit and the wrong shape for
this one, and making them longer would burn more minutes to fail
identically. The comment above the registry swap says "a backoff has to
outlast the thing it is backing off from"; here there is nothing to
outlast.

**And it was the second registry to refuse the same pull.** 2097–2100
went red on `ghcr.io` refusing anonymous pulls, and the remedy chosen was
to move to `public.ecr.aws`. Both failures have one cause — **the pull is
ANONYMOUS** — and swapping buckets treats the symptom. There is a third
bucket and it will run out too.

### Done: the pull is authenticated, with the old path as the fallback

`docker login ghcr.io` with the `GITHUB_TOKEN` every run already carries —
no new secret — in each of the three jobs that pull an image, and
`scripts/ci/with_image_registry.sh` runs the command against `ghcr.io`
first and against `public.ecr.aws` if that fails for any reason.

**Its worst case is what CI did before it**, which is the whole argument
for making the change at a spot that has already cost four red runs by
being confident, and it is asserted rather than claimed:
`with_image_registry_test.sh` covers the primary answering (one attempt,
fallback untouched), the fallback rescuing a refused primary (exit 0 —
the non-regression property), both refusing (non-zero, not swallowed),
one registry configured twice, no command at all, and a `bash -c` payload
seeing the registry. Registered in `ci.yml` beside the other gates' own
assertions, and the file was mutated twice to prove the test bites.

`RETRY_ATTEMPTS=2` wherever it wraps `retry.sh`, so the worst case stays
four attempts — **two registries at two attempts rather than one at
four.** That is faster as well as broader: the old shape spent 60 + 120 +
240 seconds waiting out a cap that a fresh runner cleared in under a
minute.

Which commands actually pull, since three of the five candidates do not:

| Command | Pulls | Wrapped |
| --- | --- | --- |
| `supabase start` (database) | yes, the whole stack | yes |
| `supabase db dump --linked` (×2) | yes — `pg_dump` runs in a container of the matching version | yes |
| `supabase functions deploy` | yes, `edge-runtime` | yes |
| `supabase db dump --local` | **no** — `supabase start` in the same job already cached it | no, and the line says why |
| `link`, `migration list`, `db push` | no, network only | no |

The `--local` one is worth the sentence: it was wrapped in the first pass
on the assumption that a local dump pulls, and the comment eight lines
above it in this very workflow says `supabase start` has already fetched
the image. A wrapper that reads as a pull needing a fallback and is a
no-op is worse than none.

**Run 2150 settled the one claim that could not be tested here.** Before
it, `docker login` had been exercised locally only in its FAILURE path — a
bogus token exits non-zero, the `else` branch fires, and the primary stays
at `public.ecr.aws`, which is what CI did anyway. Whether a real
`GITHUB_TOKEN` lifts the quota needed a run.

It does. `cc179f48`, run 2150, **green on the first attempt** where 2148
had needed two, and the deploy job's log says which registry answered:

    Status: Downloaded newer image for ghcr.io/supabase/edge-runtime:v1.74.3
    ghcr.io/supabase/edge-runtime:v1.74.3

`ghcr.io` — the authenticated primary. No `toomanyrequests`, no
`::warning::` about the login, no fallback to `public.ecr.aws`, and all
twenty functions deployed. So the fix addresses the cause rather than
moving to a third bucket, and the fallback sat unused, which is where it
should sit.

### Then the other two jobs were read, and found two things

**The migrate job: confirmed, whole log** (2,017 lines, all of it).
`Login Succeeded`, and `db dump --linked` pulled
`ghcr.io/supabase/postgres:17.6.1.155`. No refusal, no fallback. The one
`Could not log in to ghcr.io` line in it is the SHELL ECHOING the
untaken `else` branch — `[36;1m` colour on the line is how you tell. The
run's only real `##[warning]` is the pre-existing Node 20 deprecation.

**The database job: `supabase start` still unread, and it cannot be read
this way.** Its log is 25,578 lines and `get_job_logs` caps at 5,000, so
the `start` step is in the 20,578 lines the API will not return. Asking
for 40,000 returns the same 5,000; `original_length` in the response is
what says so, and comparing it against the lines returned is the only way
to know a "whole log" is a tail. **A 5,000-line answer to a 5,000-line
request is a truncation, not a complete log** — read while writing this
section, having first said the opposite.

What the tail did show is worth more than the line it was looking for:

    13:50:45  time supabase db dump --local -f /tmp/schema-local.sql
    13:51:00  Downloaded newer image for public.ecr.aws/supabase/postgres:17.6.1.155
    13:51:11  Downloaded newer image for ghcr.io/supabase/postgres:17.6.1.155

**Two things wrong there, and one of them was mine.**

1. **`db dump --local` pulls.** The workflow has said for a long time that
   `supabase start` "has already pulled the Postgres image the dump
   needs", and `cc179f48` repeated it as the reason not to wrap it.
   Untrue: `config.toml` sets `major_version = 15`, so `start` brings up a
   postgres 15 image while `db dump` runs the CLI's pinned `17.6.1.155`
   for a matching `pg_dump`. **Different tags — nothing `start` pulls is
   ever the image the dump wants**, and the dump spends 14 seconds
   downloading its own. Both comments corrected, and the dump is wrapped.
2. **The same bits came down twice, because of `cc179f48`.** The local
   dump was unwrapped, so it took the job env (`public.ecr.aws`); the
   linked dump was wrapped, so it took the primary (`ghcr.io`). Two names
   for one image is two cache misses. The login step now sets
   `SUPABASE_INTERNAL_IMAGE_REGISTRY` to the chosen primary as well, so
   **the whole job agrees on one registry** and the second dump hits the
   cache. One registry per job, or the cache never hits.

### Confirmed in run 2152: one pull where there were two

Same job, same grep, before and after:

| | 2150 (before) | 2152 (after) |
| --- | --- | --- |
| `Pulling from supabase/postgres` | 2 | **1** |
| images downloaded | `public.ecr.aws/…:17.6.1.155` **and** `ghcr.io/…:17.6.1.155` | `ghcr.io/…:17.6.1.155` |
| anonymous-registry pulls | 1 | **0** |
| refusals, fallbacks | none | none |

The step env carries `SUPABASE_INTERNAL_IMAGE_REGISTRY: ghcr.io` beside
`IMAGE_REGISTRY_PRIMARY: ghcr.io`, so the job and the wrapper now agree
rather than contradict each other. One `Pulling from` serves BOTH dumps —
the linked one produces no pull at all — and a layer reports `Already
exists`, shared with the postgres 15 image `supabase start` brought up.

**Still not claimed:** `supabase start`'s own pull. Both dumps are inside
the 5,000-line tail; `start` is not, and no argument to `get_job_logs`
will return it. To settle that one, read the step's live log in the web UI
while a run is going, or have the workflow echo the registry it is about
to use.

**How this fails in future, and what it looks like.** A `::warning::
Could not log in to ghcr.io` means the token was refused, and
`packages: read` on the job is the first thing to try — the jobs declare
no `permissions:` block today, so they take the workflow default. A
`::warning::` naming `public.ecr.aws` means the login worked and the
authenticated pull was refused anyway. Either way the run stays green off
the fallback, so **these are warnings to go looking for rather than
failures that will announce themselves.**

## Every screen and every dialog is built by a test

Asked for as **"Also build all screens"**. Read as the two gates' own
backlogs, because the other reading has nothing in it: README's `Not
built yet` is struck through except CP39, KWSP Form A and PERKESO
Lampiran 1 — all three blocked on layout specifications this machine
cannot fetch, not on code — and `Built, but not reachable from the app`
is empty.

**Both backlogs are now zero.** `check_dialogs_built.py` went 105 → 50 →
0; `check_screens_built.py` went 38 → 2 → 0.

### An empty list proves nothing, and fifty tests proved it

All fifty remaining dialogs opened cleanly at 412x900 with every
provider answering `const []`. Fifty passes, nothing learned: an empty
list draws an `EmptyState`, which is an icon and two centred sentences
that cannot overflow anything.

Feeding each one ONE realistic row broke two immediately:

- **`credit_ledger_dialog.dart` overflowed by 46 pixels.** Its totals
  line — `Expanded(Text(...))` beside an unflexed `Text` of two money
  figures — *does not exist at all* in the empty state that had been
  "tested". Now `Flexible`. Honest limit, stated because it would
  otherwise be over-claimed: the test font draws every glyph at a full
  em, so this fits on a real phone today. It would not with two
  five-figure totals and a large system font scale, which is why the fix
  is worth making rather than arguing with.
- **The collections sheet threw `Null is not a subtype of String`**,
  because the test invented `attempted_at`/`note` where
  `collectionHistory` selects `attempted_on`/`notes` — a dialog fed a
  shape the database never sends. A test bug, and the kind that would
  have sat there passing if the cast had been defensive.

So: a long Malaysian company name, the column names the repository
actually selects, and figures with digits in them. Written up as the
eleventh way in `docs/widget-tests.md`.

The console's own dialogs from the previous commit were checked the same
way — 412x900, long name, suspended and platform-admin both set — and all
six fit. They had only ever been pumped at the default 800x600.

### The two private screens were never a backlog

`_PreviewScreen` and `_RequestAccessScreen` are private, so **no test in
another library can name them, ever**. Listing them as a backlog implied
nothing built them, and in both cases something did:
`_RequestAccessScreen` through `PayrollScreen` with an auditor who has no
grant, already asserted in `screens_build_batch_test.dart`.

`_PreviewScreen` genuinely was unbuilt, and so was its host:
**`LandingCmsTab` is neither a `*Screen` nor a dialog opener, so it fell
between both gates entirely.** `landing_cms_preview_test.dart` now builds
the editor, asserts it says the page is a draft, presses Preview, and
lands on the private screen — reached by the door the app uses rather
than by naming a constructor, which also proves the door works.

`EXEMPT` is replaced by `COVERED_VIA`: screen → (source, test, the public
host). The gate refuses an entry whose test has gone, whose test no
longer builds that host, whose screen no longer exists, or which a test
names directly now. **Verified by breaking it**, and the first version of
the host check was too weak — `in` passed a test renamed to
`LandingCmsTabX`, which builds nothing and contains the old name. It is
`\bhost\b` now, with a case for that exact rot among seven new
self-tests.

### Both gates' self-tests asserted their own backlogs were NOT empty

`test_the_exemptions_are_not_empty_and_not_everything`, in both files,
with a comment saying to delete it when the list emptied. Each failed the
moment its list did — which is the assertion doing its job on the way
out. Replaced with the opposite: the backlog is empty and stays that way,
plus, for dialogs, the same fact read off the gate's own data rather than
its exit code.

## Users, companies and support access in the console

Asked for, in the user's words: *"Add option to view add and with users /
Add option to add and edit organisation / Add option to access user and
organisation"*, then *"Also allow assign or remove a organisation access
for user"*, then **"Complete all of it"**.

Two choices were the user's, made through `AskUserQuestion` and not to be
re-litigated:

- **Support access — enter their account**, rather than a read-only
  detail view of somebody else's data in the console.
- **Create with a password the admin sets**, rather than invite by
  e-mail.

Three migrations and one edge function: `0719` (support access, and a
company made for somebody), `0720` (who can open which company), `0721`
(the people on this platform), and `supabase/functions/platform-users`.

### The three things that are not SQL

Creating an account, setting a password and suspending one live in
`auth.users`. There is no supported way to write them from SQL — not from
a SECURITY DEFINER function, not from RLS — only the Admin API with the
service role key. So `platform-users` exists, and the key is in it and
nowhere else.

Its own shape matters:

- `callerOrThrow` calls `am_i_platform_admin` **through the caller's own
  client**, with the caller's JWT, BEFORE the admin client is
  constructed. Checking with the admin client would be checking with the
  key that already answers yes to everything.
- `MIN_PASSWORD = 10`, `email_confirm: true`, and
  `ban_duration: suspended ? "876000h" : "none"` — Supabase has no
  "suspend forever", so a hundred years is what that is.
- **An operator cannot suspend themselves.** That is the one mistake that
  locks the platform's own staff out of the platform.
- The password is never logged, never returned, and never written into
  `audit_logs`. `note()` writes the audit row with `org_id: null`,
  because none of this belongs to a company.

`_callPlatformUsers` in `repository.dart` unwraps
`FunctionException.details['error']` into `PlatformUserException`, which
`implements Explained`, so "A user with this email address has already
been registered" reaches the dialog as itself rather than as
`FunctionException(status: 400, ...)`.

**Every decision the function makes before it touches that key is in
`platform-users/rules.ts`, which imports nothing**, and
`rules_test.ts` asserts them: the ten-character floor and its exact
boundary, `banDuration` (`"none"` lifts a ban — NOT `"0h"`, which some
GoTrue versions read as a ban of no length), refusing self-suspension
while allowing self-restore, lower-casing an address so one person is not
two rows in the console, `text()` turning a non-string into `""` rather
than `[object Object]`, and `action()` being a CLOSED list — "call the
method named in the request" is how a service role key gets used for
something nobody wrote. Split out for the reason `ask/wire.ts` is:
`index.ts` imports `jsr:@supabase/supabase-js` and `jsr.io` is
unreachable from some of the machines this gets worked on, so a test that
needed it would be a test only CI could run. Registered in `ci.yml`; the
local check now runs **39** deno tests and all of them pass.

`supabase/config.toml` gains `[functions.platform-users] verify_jwt =
true`. The CLI defaults to true and most functions are not listed, but
this one is, with the reason written next to it: with no JWT there is no
caller to check `am_i_platform_admin` against, and the function would
become an unauthenticated endpoint that can create accounts and set
passwords.

### `audit_logs.action` is a CLOSED vocabulary

`insert, update, delete, post, void, submit`. `'granted'`, `'ended'` and
`'platform_update'` were all refused by `audit_logs_action_check`. **The
event name goes in `new_data`**; the action is the shape of the write.
Cost three failed applies to learn, and it is written here so it costs
nobody else any.

### `app.org_role` is the seam, and `coalesce` is the order

Support access grants `auditor` and nothing more:

```sql
select coalesce(
         (select m.role from public.org_members m
           where m.org_id = p_org_id and m.user_id = auth.uid()),
         (select 'auditor'::app.member_role
            where app.support_access_active(p_org_id)))
```

**Real membership first.** Reversed, a support session over a company the
operator actually owns would DEMOTE them for its duration — and then
expire, silently restoring them. Every one of `can_write`, `can_post`,
`can_admin`, `can_read_ledger`, `can_manage_hr` and `can_run_payroll`
reads `has_org_role`, which reads this, so the whole refusal surface came
from those four lines. `app.is_org_member` and `public.my_organizations`
needed the same seam — without the second, the company never appears in
the switcher and the access is unreachable.

### `hand_company_over` steps an admin down, not out

`platform_create_organization` composes `create_organization` with
`app.hand_company_over`, and that leaves the caller as `admin` — "steps
down rather than out", which is right when a real member hands a company
over and wrong here. An operator who made a hundred companies for
customers would have held standing access to all hundred. The function
now ends with an explicit

```sql
delete from public.org_members
 where org_id = v_org and user_id = auth.uid();
```

and `platform_org_access.sql` asserts the operator is not a member
afterwards. **This is the single most important line in `0719`.**

### Three existing SQL gates caught three omissions

None of them was found by thinking about it:

- `table_grants.sql` — a policy on `support_access` with no `grant
  select` behind it. A policy without a privilege is a policy that
  refuses everybody.
- `live_change_feed.sql` — the `live_change_*` triggers, missing, so a
  session opened on one device would not have appeared on another.
- `a_colleague_not_a_stranger.sql` — `support_access.admin_id` needed a
  named exemption with a reason.

Run `supabase/tests/run_locally.sh` before pushing. It is two minutes and
it found all three.

### The fixtures collapse if you assume two users

`pg_temp.test_user()` returns ONE fixed user (`fixture@iakauntan.test`),
and the `add_creator_as_owner` trigger makes them owner of EVERY test
org. So "a platform admin who is not a member" and "an ordinary user" are
the same row unless you make another one — and `pg_temp.another_user()`
**always INSERTs**, so calling it twice for the same address violates the
unique constraint. `platform_users.sql`, `support_access.sql` and
`platform_org_access.sql` each wrap it in a lookup-first helper. Also:
`v_admin` is a platform admin from its declaration onward, so a test that
wants "an ordinary user is refused" has to run as the customer.

`support_access_window_ck` refuses winding `expires_at` backwards on its
own — a test that expires a session has to move `granted_at` back too.

### The screens, and what the widget tests are for

`/admin/users` (`UsersAdminTab`) and `/admin/support-access`
(`SupportAccessAdminTab`) are registered in `platformConsoleSections`;
creating a company, editing one, granting support access and assigning a
role are dialogs in `organization_admin_dialogs.dart`, reached from the
Organizations page — a reason typed next to a name is a reason about that
company.

`platform_people_test.dart` (31 tests) asserts the SCREEN half: which
call each button makes and with what. The rules are in the three SQL
files. Two things it found that reading would not have:

- **The role dropdown overflowed by 49 pixels.** `'Auditor — reads
  everything, changes nothing'` did not fit a 460-wide dialog, and
  Flutter paints that as a striped bar over the words it could not fit.
  The names are names now (`niceRole`) and what each one can do is a line
  under the picker (`roleMeans`), read off the `app.can_*` guards.
- **Two `link_off` icons, no keys.** The companies list in the person
  sheet had an unkeyed remove button per row, so no test could tap a
  specific one. Keyed `person-org-remove-<org_id>`.

`shell_support_banner_test.dart` covers the banner being in the SHELL:
`auditor` reads everything the owner reads, so every screen looks normal,
and the banner is the only thing that says whose books these are. It also
asserts a failed lookup draws no banner and breaks no shell —
`valueOrNull`, never `.value`, which throws and takes the whole app's
build with it.

Mutation runs: `support_access_admin.dart`, `users_admin.dart` and
`organization_admin_dialogs.dart`, each against
`platform_people_test.dart`. One equivalent survivor is written down next
to the assertion it belongs to.

### Three gates the console's own screens tripped

None was a gate I thought about; all three are now permanently better.

- **`check_routes.py` could not see a single console route.** The router
  builds them in a loop (`for (final section in platformConsoleSections)`
  → `GoRoute(path: section.path)`), so `path:` is not a literal and
  `declared_routes` found none of the thirty-odd console pages. Every one
  of them was a route the gate believed did not exist, and it only bit
  when something first navigated to one by name — the banner's
  `context.go('/admin/support-access')`. `console_routes()` now reads the
  paths out of the section table, conditional on the router still looping
  over it, with four cases in `check_routes_test.py`. 179 routes, up from
  ~147.
- **`dropdown_census_test.dart` caught the role picker twice**: once for
  not being on the census (the ten `app.member_role` values are a fixed
  set — a new one is a migration that changes what `can_write` and
  friends admit), and once for missing `isExpanded: true`, which is
  exactly the 49-pixel overflow the widget test had already found. Two
  independent gates on the same defect, and both were right.
- **`shell_rail_scroll_test.dart` broke for the fourth time.** Two new
  console sections pushed the ungated rail past the 2000px window the
  test used, so it silently started measuring a rail that scrolls — the
  opposite of the case it asserts. Its own comment said a fourth time
  meant deriving the number instead of guessing, so **it now measures**:
  probe at 800, read `maxScrollExtent` off the rail's scroll position (an
  ANCESTOR of `NavigationRail` — the rail itself does not scroll), add
  that back plus 120 of headroom, and assert the overflow is then zero.
  A destination added tomorrow moves the probe and the test follows. Its
  killing power was re-checked by mutation: remove the `minHeight:
  constraints.maxHeight` and it still fails.

### Either side can close the door

`end_support_access` accepts the administrator who holds the session, any
platform administrator, **and `app.can_admin(s.org_id)`** — the
customer's own admin. A door only we can shut is not support access.

## Five switches for the scanning surfaces

Asked for: a Settings page under Console → Document scanning, with a
toggle for the Scan button, the Upload button and "My own key" on AI
SmartScan, "Send a document to reader — on by default", and the Upload
button on Bank statements. `0718`, and `/admin/scan-settings`.

### They are not five of the same thing, and are not built the same way

THREE ARE PRESENTATION. Hiding the Scan button stops nobody scanning —
`ocr_begin` decides that, off the company's own switch and its module —
and hiding either Upload button stops no file reaching storage. They
exist to take a surface off the product while it is being worked on.
The console page says so in as many words, because an operator who
believes a hidden button is a safeguard has been misled by a screen.

TWO ARE RULES and are enforced in the database. "My own key" decides
whose money pays for a reading, so `set_ocr_settings` refuses the
choice; hiding the segmented button alone would leave the RPC working.

### The default had to be true in three places at once

`org_ocr_settings` has one row per company and NO ROW means off. Three
functions read that absence: `ocr_status` (what the screen draws),
`ocr_begin` (what lets a document go to a reader) and
`ocr_record_local` (what files a reading made on the device).

Changing only the first would have put a switch reading "on" above a
server refusing every document. All three now call
`app.scan_surface('scan_reader_on_by_default')`, and
`supabase/tests/scan_surfaces.sql` walks all three in both positions.

`ocr_begin` needed two more lines for the same reason: a company running
on the default has no row, so it has no provider and no `key_source`
either, and the first company to use it would have been told **"There
is no reader called <null>"**.

**A ROW IS A CHOICE; ITS ABSENCE IS NOT.** A company that turned
scanning on and then off keeps its answer whatever the platform default
becomes. That is what makes this a default rather than an override, and
it is why nothing is backfilled. Asserted.

### Restated from `pg_get_functiondef`, not by hand

Four functions had to be reproduced whole — `ocr_status`,
`set_ocr_settings`, `ocr_begin`, `ocr_record_local`. They were dumped
out of the local database with `pg_get_functiondef`, edited by exact
string replacement in a script that asserts each pattern matches ONCE,
and pasted in. Worth repeating for the next restatement of this size:
hand-copying nine kilobytes of plpgsql is how a body drifts.

### Everything ships in the state the product is already in

Four switches ship ON because those surfaces are on;
`scan_reader_on_by_default` ships **OFF** because scanning is off for a
new company today. Applying the migration changes nothing for anybody.

Turning that one on is a real decision: it sends documents a company
has not asked to have read to a third-party model and spends platform
credit doing it. The row's description says so, the console draws a
warning while it is on, and the handover pack's standing note — *do not
send bank statements to arbitrary third-party OCR services by default*
— is the reason it was not shipped on.

### A function, not a wider read policy

`platform_settings` is readable by platform staff and by nobody else,
except `nav_grouping`, which `0298` named in the policy. Five more
names in that `using` clause would be five more chances to open a table
that also holds `maintenance_mode` and `signup_enabled`.
`scan_surfaces()` is SECURITY DEFINER, granted to `authenticated`, and
returns those five and nothing else.

`set_scan_surface` refuses a key that is not one of the five — `0678`'s
lesson in another corner, where a setter that took any string wrote a
row nothing read.

## A screenshot that was three defects, not one

Reported as "Why such error", with the bank reconciliation screen
showing

    Book balance                             RM 0.00
    Less what the bank has not seen         RM -0.00
    Statement should read                    RM 0.00
    Statement says                      RM 11,008.23
    Out by                             RM -11,008.23

and, in a red bar under it, `PostgrestException(message: The
reconciliation is out by -11008.23. ..., code: 23514, details: Bad
Request, hint: null)`.

**The scan was not what failed.** Measured against production, read
only: the statement is Maybank, October 2025, twenty-four lines from
09/10 to 31/10, every one carrying a running balance that chains
without a break from 974.74 to 11,008.23. The closing figure in the box
is the bank's own, carried through by the import. What was wrong is
that the ledger of that company **begins on 2026-01-02** — zero posted
entries on or before the statement date, anywhere in the org. The
difference was the statement balance itself, to the sen.

Three separate defects, all fixed in this stretch.

### One: the driver's envelope around the sender's sentence

`runWithFeedback` did `Text('$err')`. `PostgrestException.toString()`
prints its fields, so every careful sentence a migration ever wrote
arrived wrapped in the wrapper. `AsyncView` did the same on load. Those
two are how every action button and every screen in this app report a
failure, so it was every refusal the database has ever made.

`core/error_text.dart` has `errorText()`: the three Supabase envelopes
unwrapped, `Explained` for the app's own exceptions (which now
implement it rather than being named in `core/`), a connection that
never landed reported in words instead of a host name, and Dart's own
`Exception: ` prefix dropped. **An unrecognised error still prints** —
swallowing it would be worse than showing it untidily.

112 sites were rewritten. `scripts/check_error_text.py` holds it,
walking each `catch`/`error:`/`onError:` binding's own BLOCK rather
than matching the name — `repository.dart` maps a list with `(e) =>
'$e'` in one place and catches an error called `e` in another, and a
name-matching scan called the map a defect. `debugPrint` and `print`
are allowed: a log line may hold the whole object.

`deniedDetail` in `core/denials.dart` deliberately does NOT use it, and
says so beside the line. That one feeds the SECURITY LOG, which wants
the type name and the host precisely because a person is working out
what was refused. Routing it through `errorText` broke
`denials_test.dart`, correctly.

### Two: three named causes, none of which had happened

The screen said "A difference is a line nobody has matched, a payment
entered twice, or a charge the books have not heard of." All three are
discrepancies between two sets of records. There was one set.

`0716` puts two figures on `bank_reconciliation_status`:
`posted_entries` (how many posted lines the account has BY the
statement date — a book balance of zero cannot tell "nothing posted"
from "posted and netted off") and `books_start` (the earliest posting
at ANY date, deliberately not bounded by the statement date, because
the whole use of it is to say the books start after).

`whyItIsOut` in the screen writes the sentence; the function returns
facts. **No date has to be passed to it**: `posted_entries == 0`
already means every posting falls after the statement, so comparing the
two dates would ask a question the pair has answered. A server that
does not send `posted_entries` gets the sentence that was always there
rather than a guess.

`complete_bank_reconciliation` names it too, because the refusal is the
only explanation somebody gets at the moment they are stopped.

And `RM -0.00`: `-Fmt.toDouble(x)` on a double zero gives NEGATIVE zero.
It is `0 - Fmt.toDouble(x)` now, with the reason beside it.

### Three: import had no verb for "this was never entered"

The largest of the three. `suggest_bank_matches` can only offer
documents that are ALREADY posted, so against that ledger every one of
the twenty-four lines answered "Nothing posted matches that amount and
date. Record the receipt or payment first" — and no screen would record
one. Import brought lines in; nothing turned a line into a posting.

`0717` adds `post_bank_transaction(line, account, description?,
contact?)`. Two sides: the bank's own GL account and one account
somebody chooses. **`bank_transactions.amount` is already a GL-signed
movement** — `0085` fixed the meaning and `0712` made a credit card
obey it by storing the card negated — so there is no account-type
branch: `amount > 0` debits the bank, `amount < 0` credits it, and a
card purchase raises the liability for free. It posts through
`app.create_gl_entry_internal` like every other route, as source
`bank_transaction`, which `0004` has held in the enum since the
beginning and nothing had ever written.

**The part that would have rotted:** `unmatch_bank_transaction` used to
clear `gl_entry_id` and stop. For a line matched to a receipt that is
right. For a line posted FROM ITSELF it is wrong twice — the journal is
orphaned in the ledger and the line is free to post a second one, so an
undo and a redo double the figure silently. Unmatching now REVERSES an
entry whose source is the line it is detaching (reversed, not deleted;
`0102`'s rule), and leaves alone one somebody has already reversed by
hand.

### What is deliberately not in this

**Category suggestions.** The posting dialog asks which account and
offers no opinion. Suggesting one — 21 categories, transfers matched
before P&L, a card payment that must not duplicate the card's own
expenses — is the separate piece of work still waiting on the user's
word, and guessing quietly in a dialog is a worse place for a first
attempt than a screen that says what it is doing.

### And a note on the account in the screenshot

It belongs to a DEMO organisation (`organizations.is_demo`), so
`app.demo_rebuild()` deletes and recreates it, taking those 24 imported
lines with it. Worth saying to the user if the work in it matters.

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

### Both destination forms fill from it now

`OcrExtraction.target` and `.fields` arrive and are asserted.

**Two things read the map.** `readerColumns` in
`smartscan/scan_field_map.dart` turns it into rows and
`smartscan/scan_detail_sheet.dart` shows them under "What it filled in",
so a person can SEE what the reader put in each destination column. And
`contacts/scanned_contact.dart` now turns it into the contact editor's
boxes, which is the half this entry used to say was missing: showing a
value and putting it in the field somebody is about to save are
different things, and both exist for `contacts.contact`.

`scan_target_fields` asks for **sixteen** columns there and the form
used six properties off the parse, so the legal name, the old
registration number, the SST number, the mobile, the second and third
address lines, the city and the state were asked for on every scan, paid
for, listed on screen, and then typed in again off the same piece of
paper. Two decisions in that mapping are worth knowing before changing
it, and both are asserted in `app/test/scanned_contact_test.dart`:

* **The reader's columns win over the parse, and a blank answer is not
  an answer.** "The tax number is not printed on this receipt" is
  useful and must not blank a field the parse did find.
* **The address comes from ONE source, whole.** A reader that answered
  the address columns read one address; `splitScannedAddress` split
  another off the printed block. A postcode from one on the lines of the
  other is wrong and looks right.

`contacts.mobile` had a controller, a line in `_load` and a line in
`_build` **and no box** — loadable, saveable, and impossible to type
into. There is one now, beside Phone.

### The expense form fills from it too, and a silent under-recording is gone

`expenses/scanned_expense.dart`. All eight configured
`accounting.expense` columns now have a path into the form; four had
none at all before — the reader's own `description` (the "being payment
of" line, in the words on the page), `payment_mode_code`, `currency` and
`tax_amount`.

**The tax is the decision worth reading.** The form does not take a tax
figure: it takes a tax CODE and computes the figure from its rate, and
that computed figure is what gets stored. So a printed tax can only
choose a code — and a code is chosen only where `Fmt.taxOn(net, rate)`,
the exact arithmetic the form itself will apply, reproduces the printed
tax to the sen. Matching with the form's own function rather than with
`tax / net` is what makes the match mean something: what is chosen
recomputes to what is printed, by construction. An `isExempt` code is
refused even when its rate would match, because that is a claim about
the purchase rather than a rate.

**Where nothing matches, the amount box now holds the TOTAL**, and this
fixes a defect rather than adding a feature. `_apply` took
`subtotal ?? total`, so a receipt printing 1000.00 + 90.00 = 1090.00
against a chart that knows only 6% recorded an expense of 1000.00 with
no tax — ninety ringgit of a real payment simply gone from the ledger,
with nothing on screen saying so. A company that cannot match the code
is a company not claiming the input tax, and for it the whole 1090.00 IS
the cost.

**A foreign document is SAID, not stored.** `expenses.currency` defaults
to `MYR` and `exchange_rate` to 1, and `recordExpense` sets neither, so
a USD receipt was being posted as ringgit at a rate of 1 — a wrong
number that looks like a right one. There is no FX here to build on, so
the form says which currency the paper is in and leaves the conversion
to the person holding it.

**Three traps this paid for:**

* The tax codes, payment modes and company currency must be **awaited**.
  `_apply` ran in `initState`, where nothing has watched any of those
  providers yet — the first `ref.watch` of each is in `build` — so
  `.valueOrNull` is the loading state. Read instead of awaited, the tax
  code is never matched and the payment mode never accepted, silently,
  while every assertion about the mapping still passes. Third time this
  branch has hit it.
* `_apply` is async now, so the re-read path's
  `setState(() => _apply(accepted))` had to go: an arrow body returns
  the Future and Flutter asserts against exactly that —
  `check_setstate_futures.py` in one line.
* **`OcrExtraction.netAmount` (`subtotal ?? total`) is still used by
  `documents/document_editor.dart:501`**, as the single-line fallback
  for a bill whose reader returned no lines. NOT changed here, and not
  because it was overlooked: a document editor applies tax per line and
  reconciles against the supplier's own printed total (`0706`,
  `roundingThePaperApplied`), so whether the same hole exists there is a
  question about a different machine. Somebody should look; a blind
  change would be a guess about a total that is already being checked.
* **The date is read off the TEXT, not through `DateTime.tryParse`.**
  A reader answering `2026-03-04T18:00:00Z` parses to an instant that is
  already the fifth in Malaysia, so anything reading its local
  components files a document dated the fourth on the fifth. The
  mutation run is what surfaced this: the `toLocal()` mutant SURVIVED,
  because the test VM runs in UTC and CI does too — a defect that only
  appears east of UTC is one no run here would ever show. Taking the
  three numbers as printed cannot do it on any machine, which is why
  the code changed rather than the test.

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

### ~~Not done~~ — wired since this was written

The reader returns a statement's lines, and turning them into
`bank_transactions` is now done: `Repo.importBankTransactions`, called
from `banking/reconciliation_screen.dart`, with the bank account chosen
and the duplicate check the bank-import machinery already had.
`banking/bank_statements_screen.dart` shows what became of each scan,
filtered to the ones that reached `bank_transactions`.

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

* **`main` touches nothing in production — but it is not true that it
  deploys nothing.** The migrate, edge-function and workspace-proxy jobs
  are all gated on
  `github.ref_name == github.event.repository.default_branch`, so on a
  push to `main` those three are SKIPPED. PR #4 merged this branch into
  `main` on 2026-09-21 and its run skipped all three; PR #5 merged it
  again on 2026-09-28 (`7af418f9`) and run 2157 skipped the same three.

  **The Vercel job is the exception, and it is easy to miss.** Its `if:`
  has no `default_branch` comparison in it at all — only
  `github.event_name != 'pull_request'`, the two upstream jobs and the
  `superseded` check — so it runs on a push to ANY branch. What the
  branch decides is the *kind* of deploy: on the default branch it runs
  `vercel deploy --prebuilt --prod`, and anywhere else it takes the
  `else` and runs `vercel deploy --prebuilt` with no `--prod`, which is a
  **preview** deploy to a throwaway URL. "Confirm the domain is serving
  this commit" is inside the default-branch arm, so on `main` it is
  skipped too.

  On run 2157 the Vercel job therefore RAN — it built the web bundle and
  deployed it — as a preview. Nothing the live domain serves changed.
  So: a push to `main` cannot touch the database, the edge functions,
  the workspace proxy or the production web app, but it does build and
  publish a preview, and saying "`main` deploys nothing" overstates it.
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
  bookkeeping — plus a preview deploy nobody asked for, plus the one
  thing in the next bullet.
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
2. ~~**Per-kind PDF handling.**~~ **Done, and this entry was stale for
   several sessions — worth knowing as a fact about this list, not just
   about PDFs.** `0697` and `0701` did all of it: `readGemini` is its
   own function on Gemini's `generateContent` rather than Google's
   OpenAI-compatibility shim, so `inline_data` carries
   `application/pdf` and the model reads the document; the
   chat-completions path sends a `{ type: "file", file: { filename,
   file_data } }` part instead of refusing by name; and
   `ocr_providers.reads_pdf` is a nullable column where null means
   `app.reader_reads_pdf(kind)` decides, so a platform can switch one
   reader on the day its vendor ships it without a release. Read the
   code before trusting an entry here.
3. ~~**A default model on the ChatGPT row.**~~ **Done, but NOT the way
   this entry proposed, and the difference is the point.** `0113` left
   `model` null on ChatGPT and Grok deliberately, and its header says
   why: *"Guessing an identifier would produce a migration that looks
   finished and a 404 at the first scan, blamed on the feature rather
   than on the guess."* Seeding a model identifier out of a model's own
   memory is exactly that, so it was not done.

   The real complaint in this entry was the other half: an operator was
   left to TYPE an identifier they had to already know, from a vendor
   that renames its models every few months, into a free-text field
   that accepts anything and only fails at the first scan — by which
   time `ocr_begin` has taken a tenant's credit for it.

   So the vendor is asked. `supabase/functions/ocr-models` lists what
   the platform's key can actually reach — `/v1/models` on the
   chat-completions shape and on Anthropic, `/v1beta/models` on Gemini
   — and the console's reader editor gained a magnifier beside the
   Model box that fills it from the answer. `model` is still null on
   those two rows, and that is still right: what changed is that
   nobody has to guess.

   Four things about it that are not obvious:

   * **The list URL is DERIVED from `ocr_providers.endpoint`**, not a
     second column. A column would be blank on every row that exists
     and a second thing to get wrong when somebody adds a reader. All
     three shapes differ by their last path segment, so the URL we have
     determines the one we want — and `catalog_test.ts` asserts the
     derivation, including that `/messages` is anchored at the END (a
     proxy mounted under `/messages/v1/messages` must lose only the
     last one) and that Gemini's `models/` prefix comes OFF the id,
     because an id that kept it produces
     `/models/models/x:generateContent`.
   * **Asking does not spend a scan.** `claim_ocr_key` rolls a key's
     minute, day and month counters forward in the same statement that
     hands the key over — right for a document, wrong for a catalog
     lookup, and an operator opening a picker would otherwise eat a
     tenant's allowance. So the pool is READ with the service role, in
     the order the claim would have used, and no counter moves.
   * **It is a `SearchablePicker`, not a dropdown**, and
     `dropdown_census_test.dart` is why: OpenAI's `/v1/models` answers
     with dozens of entries on an ordinary account — embeddings,
     moderation, audio, every dated snapshot — and somebody looking for
     one of them is typing, not reading. The census freezes
     `ocr_catalog_admin.dart` at one dropdown and a second would have
     failed it by name, which is the gate working.
   * **`ocrModels` is on `PlatformRepo` itself, not on the
     `PlatformOcrCatalog` extension** where the rest of the catalog
     lives. A Dart extension method is resolved STATICALLY, so a test's
     `_FakePlatform` cannot stand in for one — it falls through to the
     real `functions.invoke` and tries the network. The first draft had
     it on the extension and the widget test could not be written.
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

1. ~~**Matter on all transactions**~~ — **done.** `0688` made every
   posting path carry it: `app.create_gl_entry_internal` is the only
   function that inserts `gl_lines`, and a caller that knows its matter
   puts `matter_id` on the line the way `project_code` already travels.
   All four pickers are now placed — the journal editor (`0688`), the
   expense form (`0692`), the bill editor (`document_editor.dart` carries
   `matterId` on the header) and the bank reconciliation (`0723`).
2. **Client trust monies with collections and payments** — already built
   (`ClientMoneyScreen`, `/legal/receipts`, `/legal/payouts`). Asked the
   user what is missing in practice rather than rebuilding it.
3. ~~**General entry with inter-account transfers**~~ — **done, screen
   and all.** The missing reading was a general journal on the client
   side and `0690` is it; the screen that was outstanding when this was
   written is `legal/client_transfer_screen.dart`, routed at
   `router.dart:840` and reached from the matter detail screen too.
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

### ~~Still to place~~ — all three are placed

The journal was taken first because it already had two dimensions to sit
beside, so the pattern was established rather than invented three more
times. The other three followed: the expense form in `0692`, the bill
editor on its header, and the bank reconciliation in `0723` — which was
the only one that genuinely still needed it by the time somebody looked,
and needed it most, because `post_bank_transaction` had no argument to
carry a matter at all.

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
| "a progress popup and block all activity till its 100% completed" | `whileScanning` in `scan_progress.dart`, around the capture, the rescan and the attachments card |
| "all scanning activities logged, all replies logged in raw" | `0704` — `ocr_exchanges`, one row per CALL, opened from the console's scan log |
| "prompt if to override the description" | `whatToTakeFrom`, both values side by side, keep is what a dismissal does |
| "why does keying the item no. replace the price, tax and amount" | the same prompt, one row per field — so the item's tax can be taken while the figure off the paper stays |
| "in some cases the tax is calculated in total instead of in single item" | `0705` + `ScanTotalsBanner` — tax stays per line, and the paper's own three figures are now shown beside what the lines come to when they disagree |
| "scanned in with no round up or round down, make it automatic but not for all cases" | `0706` — `documents.rounding_method`, decided from the paper's own stated total. Bank Negara rounds CASH; the company-wide switch was restating every supplier bill |
| "all entry created with AI SmartScan tagged 'AI Scan', beside posted/draft/overdue/complete" | `0707` — `entry_source` on the four tables a reading becomes one record of, written beside `ocr_scans.posted_id` in the same statement; `EntrySourceChip` beside every status |
| "all uploaded documents saved in record; if used it can't be deleted, if not it can" | `0708` — `app.attachment_is_evidence` plus a `before delete` trigger; the card draws a lock instead of a button |
| "when the file is uploaded it should also add date and time in the filename" | `stampedFileName` — `bil_20260924-1710.pdf`, the extension left last |
| "all document may be handwritten" | the reader's prompt, now its own module with `prompt_test.ts` asserting it still says so |
| "why can't read again / the file should be available till it's deleted or attached" | the two automatic deletes in `scan_flow.dart` are gone; a deliberate "Remove the file" sits in the scan sheet, and `check_capture_is_kept.py` stops the automatic one coming back |
| "bank statement was sent for scanning but it did not scan and recognise it, why?" | it very likely did — `foundNothing` on the model replaces two screens each asking the three questions an INVOICE answers, and `allDataLines` now lists `rows` |
| "a rescan icon after the AI Scan button... revert back or add what was missed out, item by item, or ignore" | `scan_recheck.dart` — `differencesFromPaper` and `askWhatToRestore`; nothing ticked to begin with, nothing applied unless ticked |
| "when nothing is recognised, let them view the document and say what it is; an Other with free text" | `0709` — `ocr_scans.document_kind_named`, `platform_named_kinds`, and the kind sheet gains "View the document" and "Something else — say what it is" |
| gap 9 — populate `scan_target_fields` | `0710` — 37 rows across the six destinations that had none, `payment_voucher` pointed at expenses, and a leak in `scan_target_columns` the data exposed |

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

## The paper says one tax figure; this system charges each line

> in some cases the tax is calculated in total instead of in single item
> do also ponder on that

Both halves of that are true and only one of them is a defect.

**Tax is per line here, by design, and that is not changing.**
`app.calc_document_line` charges each line at its own code; the header's
`tax_amount` is DERIVED — `0009_functions.sql:280` has a trigger that
sets it to `sum(lines.tax_amount)` every time a line moves. MyInvois
requires tax per line item, the SST return reads the line, and the
posting reads the line. So a document-level tax figure has **nowhere to
be stored**: anything written to `documents.tax_amount` is overwritten
by the next keystroke on any line.

That is also why the obvious fixes were not built. Three were on the
table and the user chose the first:

1. **Reconcile and warn** — compare, say nothing unless they differ.
2. Distribute the stated tax pro-rata across the lines.
3. Post the difference as an explicit tax-adjustment line.

2 and 3 both CHANGE THE NUMBERS on a statutory return to make a screen
tidy, and neither can tell rounding apart from a line on the wrong code
— which is the case that actually matters. They remain unbuilt, on
purpose, and what option 1 surfaces is what should decide them.

### What was built

`0705` — `public.document_scan_totals(org, table, record_id)`. **No new
columns:** the paper's subtotal, tax and total have been in
`ocr_scans.extracted` since `0111`, and copying them onto the document
would be a second copy to drift — worse, one a re-scan would leave
stale. The function walks document → attachments → scans and returns the
newest SUCCESSFUL reading's three figures with the file name it came
off. Guarded by `app.is_org_member` in the WHERE clause, so a stranger
gets no rows rather than an exception.

`scan_totals_check.dart` — `totalsDisagreement()`, pure, and
`ScanTotalsBanner`, which reads the provider and is silent unless
something differs by half a sen or more.

Three things it deliberately does NOT do, each of which would put a
warning on a document that is perfectly fine:

- **No paper is not zero paper.** A document nobody scanned gets no
  rows, not zeroes — otherwise every typed-in bill in the system would
  be reported as disagreeing with a reading that does not exist.
- **A figure the reader did not find is skipped.** "There is no total
  printed on this delivery order" is a real answer; comparing against
  zero would report the whole document as out.
- **Under half a sen is agreement.** Both sides are already rounded to
  the cent, so what is left below that is floating point.

Sixteen mutants across the three files, all killed, controls survived.
One survived the first sweep and was a genuinely equivalent mutant
(replacing a null reading with one that found nothing, which is the same
answer); the real version — comparing against ZEROES — is killed.
Three of the sixteen are on `document_editor.dart` itself, because every
test of the banner passes with the banner deleted from the document.

## The supplier did not round, and we did

Reported with the supplier's own PDF — Google Asia Pacific tax invoice
`5665871390`, filed against `BILL-2026-00016`:

| The paper | This system |
| --- | --- |
| Subtotal MYR 1,086.12 | Subtotal RM 1,086.12 |
| Service tax (8%) MYR 86.89 | SST RM 86.89 |
| **Total MYR 1,173.01** | Rounding RM -0.01 · Nearest 5 sen |
| | **Total RM 1,173.00** |

One sen of rounding that nobody on either side of the bill applied. Paid
that way, the supplier's statement is a sen short for ever.

### `app.round_amount`'s own comment had said it since `0009`

> Bank Negara rounding mechanism: **cash** totals round to the nearest 5
> sen.

The mechanism, in force since 1 April 2008, rounds the amount payable in
CASH at a counter, because there is no one sen coin to pay the last sen
with. A bill settled by transfer, card or on credit terms is paid to the
sen and nobody rounds it.

But `organizations.rounding_method` is one switch for the whole company,
and both recalculation triggers applied it to every document ever raised
or received. A company that takes cash over a counter — which is why the
switch is set — had that setting silently restating every supplier bill
it received as well.

### The document decides; the paper tells it what to decide

`0706` puts a nullable `rounding_method` on both document tables. **Null
is every row in every existing database** and means the company's
setting, exactly as before, so nothing already raised or posted moves by
a sen. Both triggers resolve `coalesce(document, organization)`.

What sets it is the scanned paper, and it is not a guess — the total is
printed on the page. `roundingThePaperApplied` compares the stated total
against what the lines come to under each method and takes the one that
matches.

**It answers nothing in three cases, and that is the load-bearing half:**

- no total was read;
- MORE THAN ONE method produces the stated total — a bill landing on a
  5 sen boundary reads identically however it was rounded, and answering
  there would override a company setting on no evidence;
- NO method produces it, which means the document does not tie to the
  paper for some other reason. That is what `0705`'s banner is for.

### The trap the tests found

The first build decided at the moment of reading, and a widget test
driving the real `_applyScan` returned null for the reported invoice.
`_applyScan` **puts no tax code on a line** — deliberately, since a rate
guessed off a printed figure is a posted amount that does not match the
return — so at that instant a taxed bill is 1,086.12 against a paper
saying 1,173.01 and ties to nothing.

So the question is asked again from `_markDirty`, against the total
`0705` already fetched, every time the lines move. It is answered
minutes later, when somebody has put the codes on. `?? current` keeps
the answer once reached, so editing away from the paper does not start
the rounding up again — the banner raises that instead.

### Three classifications the gates demanded

- **Frozen once posted.** The method decides `rounding_amount` and
  `total_amount`, both already frozen, and the journal carries the
  rounding line they produce.
- **Carried by a recurring schedule.** A standing order meets the same
  supplier's habit every month. Asserted behaviourally, not just
  structurally: the walk only checks the column is named.
- **Granted to `authenticated` and `service_role`.** A trigger function
  needs no EXECUTE to fire, but the first thing it calls inside is
  checked against the role that caused the write — which is what
  splitting the recalculation into `app.recalc_*_totals_for(uuid)`
  created, and what `trigger_reachable_grants.sql` caught.

Twenty-one mutants across the migration, the Dart and the editor; all
killed, controls survived. Two survived a first sweep and each was a real
hole: nothing compared against a paper with more decimal places than the
sen, and nothing proved a half-typed document keeps the answer already
reached.

## What the machine read, and what a person typed

> all entry which are created with AI SmartScan will be tagged as "AI
> Scan" in the background database and in any where that shows posted
> draft overdue complete it should show "Ai Scan" beside it also

`ocr_scans.posted_table` / `posted_id` have known what a reading became
since `0694`. What they could not do is be READ: every list in this
product selects the document table and nothing else, and a join per list
— bills, invoices, orders, receipts, expenses, aging, the taxman's queue
— is a join to forget in the next list somebody adds.

So `0707` puts `entry_source` on the record as well, **written in the
same statement as the link** inside `record_scan_posting`, which is what
stops the two from drifting.

- **Four tables**, the ones from `scan_targets` that are a single record
  somebody opens: `sales_documents`, `purchase_documents`, `expenses`,
  `contacts`.
- **`bank_transactions` is deliberately excluded.** One statement is one
  reading and a hundred rows — `scan_targets.repeats` is true for that
  reason and `record_scan_posting` files it against a placeholder id —
  so there is no single record to tag.
- **Null means a person typed it**, which is every existing row and the
  overwhelming majority of every row after this. Text, not a boolean,
  because the question is WHERE FROM and a bank import is the same
  question with a different answer.

Two paths create a scanned record and only one was ever recorded:

1. a reading BECOMES a record — `record_scan_posting`, stamped in SQL;
2. a record that already existed, whose lines a reading filled in. This
   is the reported case and nothing calls that function on it, because
   the file was already filed. The editor stamps it, and the migration
   backfills it from "a successful scan exists against an attachment on
   this row".

`EntrySourceChip` sits beside the status in the document list, the
expenses list, the contacts list and the document editor's header. The
assertion that matters most is the **silence**: it appears on nearly
every screen in the product, so a chip that showed on a typed row would
mean nothing within a week.

Seven mutants, all killed, controls survived — five of them on
`document_editor.dart`, because a chip has three separate ways to be
missing (never read back, never shown, never sent back).

## Bank statements: a door on a room that had no door

> add a sub module to general ledger module known as "Bank Statement"
> where here user can upload bank statement

Importing a bank statement has worked since `0157` and picked up MT940,
file opening and photographs since. **Nothing said so.** It was an
unlabelled `upload_file_outlined` in the Reconcile screen's app bar,
disabled until an account was picked, sitting between five other
unlabelled icons — so a person who had not found it had no way to learn
the product could take a statement at all.

`accounting` is the module code whose display name is **General
Ledger**, so that is where the new screen hangs: `/bank-statements`,
above Reconcile in the rail, because a statement arrives before it is
reconciled.

**It imports nothing.** The parse, the balance chain, the duplicate
skip, the closing-balance write and the three sources (paste, file,
photograph) all live on the Reconcile screen and all work. A second copy
would be a second set of answers to drift apart. What the new screen
does is name the thing, list the accounts, show what has already been
read, and hand over:

    /reconcile?account=<id>&import=1

`ReconciliationScreen` gained `openAccountId` and `openImport` for that
one link.

### Both halves of that link fail silently

This is the part worth not re-deriving.

- **Drop `?account=`** and the import still opens, still parses, still
  reports success — into whichever bank account sorts first. A statement
  in the wrong account, reported as a win, found weeks later when
  neither side reconciles.
- **Drop `&import=1`** and somebody who pressed "Upload" lands on a
  reconciliation screen and has to find the unlabelled icon after all,
  which is the exact thing this screen exists to stop.

Both are asserted, and both mutants were killed. A **stale** id — a
bookmark, or an account closed since — falls back to the first account
rather than to an empty screen, and that fallback is asserted too, with
its own mutant.

### The once-only guard, and a latch that was not one

`openImport` opens the dialog from a post-frame callback inside the
seeding block in `build`. `build` runs again on every rebuild and
`_refresh` calls `setState` twice, so "once" is not free.

It was first written with a `bool _openedImport` latch. **The mutation
sweep showed the latch survived being removed** — because the seeding
block is already guarded by `_bankAccountId == null` and sets it in the
same statement, so the block cannot run twice. The latch was dead
defensive state, and it is gone; the comment now names the condition
that actually does the work.

The mutant that *would* prove it — widening the guard to
`if (banks.isNotEmpty)` — puts the screen into an unbounded
rebuild/refresh loop and was abandoned after twenty minutes of one
`flutter test` invocation. It is killed by the plain
`findsOneWidget` on the open dialog, which a reopening loop turns into
`findsNWidgets(n)`. **Killing `mutate.py` mid-run leaves the mutant in
the source file** — check the file before doing anything else.

### The list beneath

`_Read` reads the **scan inbox** rather than a table of its own: a
photographed statement IS a scan, and `0694` already records what each
one became. Filtered by `isBankStatementScan`, which is deliberately two
conditions —

    entry.postedTable == 'bank_transactions' || entry.documentKind == 'bank_statement'

— because the second half is the half worth showing. A statement read
and **never imported** was invisible everywhere in this product until
now, and that is the one somebody needs to see. It asks the inbox for
`all`; `posted` would hide exactly that row.

Twelve mutants across the two files, all killed, both controls survived.

## A statement is a PDF more often than it is a CSV

> bank statement should allow to upload pdf csv and also image not
> only csv

The import dialog's "Open a file" called `readAsString` on whatever was
picked. So:

- **a CSV or an MT940** parsed, as designed;
- **a PDF** — which is what a bank emails — threw a `FormatException`,
  reported as *"Could not read the file: FormatException…"*, which
  reads as the statement being broken rather than the button being for
  something else;
- **a photograph** did the same.

Both halves of the fix already existed and neither could be reached
from here. `parseStatement` reads CSV and MT940. `scannedStatement`
turns an AI SmartScan reading of a statement into the same
`StatementRow`s — `0682` gave the `accounting.bank_statement` target
`repeats` for exactly this. The only way to reach the second was to go
to SmartScan FIRST, photograph it there, and be navigated back with the
reading parked in `pendingStatementProvider`. Nobody holding a PDF
guesses that.

### One button, and the file decides

`statementFileKind({mimeType, bytes})` in `statement_import.dart` is the
switch, and it is a pure function on purpose — the decision is the rule,
and a rule that needs a file dialog to reach is a rule nothing can
assert.

    StatementFile.text    -> parseStatement, costing nothing
    StatementFile.scan    -> captureAndRead + scannedStatement
    StatementFile.neither -> a sentence saying what to do instead

Not two buttons. Which importer a file belongs to is a question about
the file, so nobody has to know that a CSV is free and a PDF costs a
scan, and nobody pays for a reading of a file that would have parsed
here.

**Both directions are wrong in a way that costs something**, which is
why both are asserted: a CSV sent to the reader is a scan charged for on
a file that parses better locally, and a PDF sent to the parser is the
reported bug.

### Sniffed from the bytes, not the extension

The mime type is only a fallback. A browser hands over whatever the
operating system guessed from the extension — routinely
`application/octet-stream` for a `.sta`, empty for anything with no
association — and a statement renamed by whoever downloaded it is the
ordinary case. So `%PDF`, the PNG/JPEG/GIF/BMP magic, `RIFF….WEBP`, and
`….ftyp` at **offset four** for an iPhone's HEIC.

### The rule that was right on every file anybody tried

"Is it text?" was first written as *contains no NUL byte*. That let
`PK\x03\x04` — the first four bytes of a spreadsheet — through as text.
A real `.xlsx` has a NUL a few bytes later, so the rule was correct on
every file that would ever be tested by hand and wrong on the short one
nobody would. It is now **any control byte except tab, newline and
carriage return**, and the test names the four-byte case.

Latin-1 is decoded rather than refused: a Malaysian statement is ASCII
plus the occasional accented payee, and refusing a whole statement over
one character in a narration nobody reconciles against is the wrong
trade.

### `captureAndRead` gained `picked`

The importer picks the file itself, because it has to look at the bytes
before it knows whether a reader is involved at all. So
`captureAndRead` now takes a `CapturedFile` in place of asking for one,
and everything after the pick is unchanged and deliberately so — the
PDF refusal that happens **before** the upload and the charge, the
progress modal, and the attachment that is kept when the reading fails.

The capture is filed against `bank_transactions`, so the scan inbox and
the Bank statements screen both say what became of it.

Eleven mutants on the classifier, all killed, control survived. The
`_openFile` routing itself is not widget-tested: it opens a real file
dialog and there is no seam. The rule it applies is the pure function
above, which is.

## Three ways a scan was quietly wrong, and the arithmetic that says so

Asked for as "keep solving scanning issue for both ai smartscan and
bank statements". Three defects, all of the same shape: **a figure the
reader gives that can be CHECKED against another figure the reader
gives, and was not.**

### 1. A statement's sign was a guess, and a wrong guess refused everything

A Malaysian retail statement prints Debit and Credit columns and **no
sign**. So a reader looking at a photograph infers it from column
position and gets it wrong often enough to matter.

The only thing catching that was `import_bank_transactions`, which
walks the running balance (`0369`) and **refuses the whole import**
naming one line. Right check, wrong remedy: somebody who photographed
forty lines got an error about line 12 and no way forward but to type
all forty in.

The balance is not an opinion. Where two consecutive lines carry one,
the amount between them is arithmetic:

    oldest-first:  amount[i]   = balance[i] - balance[i-1]
    newest-first:  amount[i-1] = balance[i-1] - balance[i]

`balancesDecideTheSigns` does that before the rows leave Dart. Agreeing
in magnitude and disagreeing in sign is **repaired and said so**.
Disagreeing in MAGNITUDE is **not touched** — that is a missing line or
a misread figure, and it must still reach the refusal, because
rewriting an amount to make a chain close is how a statement comes to
reconcile against a number nobody printed.

Direction is read off the dates the same way the RPC reads it, or a
pair of balances gets attributed to the wrong line and the "repair"
breaks a chain that was sound.

`StatementParse` gained **`notices`**, separate from `problems`: a
problem is a line that will not be imported and a notice is a line that
will be, differently from how it was read. Counting them together would
put "3 could not be read" over three lines that were read perfectly
well.

### 2. The document editor threw away the printed amount column

`_applyScan` built each line as:

    unitPrice: l.unitPrice ?? (amount != null ? amount / qty : 0)

So `amount` — **the figure the supplier's own total is built from** —
was consulted only when there was nothing else. A misread price column,
or an invoice with a discount column the reader was never asked about,
produced a bill whose lines quietly did not equal the paper. `0705`'s
banner then said the document did not tie: true, and silent about which
line.

`lineFromScan` makes the printed amount win and derives the price from
it. `unit_price` is `numeric(18,4)`, so 10.00 over three stores as
3.3333 and extends to 9.9999, which the 2-decimal line total rounds to
the printed 10.00 — **the document ties to the paper by construction
rather than by luck.**

**The tolerance scales with quantity**, and that is the whole subtlety.
A unit price is printed to two places and meant to four: 3.33 for a
third of ten ringgit. Over three units that is one sen out and not a
misreading; over a hundred it is fifty sen. So the slack is half a sen
PER UNIT. A flat half-sen reports half the invoices in the country; a
flat ringgit hides a real misread digit on a single-unit line.

`ScanLineCorrections` puts every one on the screen, above the totals
banner it explains. Not in the log: it changes a figure somebody is
about to post.

### 3. Which means the review dialog's one editable box was inert

The dialog shows exactly one editable figure per line — the amount —
because "quantity and unit price are rarely what needs correcting".
Under the old rule, **editing it did nothing** whenever the reader had
returned a unit price. Correct 255.00 to 155.00, press Apply, get
3 × 85.00 = 255.00. The one correction the dialog offers on a line was
the one thing it could not do. Fixed by the same change, and asserted
by name.

### And the copy that would have rotted

`scan_recheck.dart` had its own `_priceOf` — the same arithmetic
`_applyScan` had **at the time**. The moment `_applyScan` was fixed,
the recheck would have reported every correctly-built line as a
difference against the figure this app itself put there, with a
"restore" button that put the misreading back. Both now call
`lineFromScan`, and a test says so in the only way that keeps saying
it.

Twenty-eight mutants across the four files, all killed, every control
survived. One survivor found a real gap on the way: a paper line
carrying no figures at all was treated as a price of zero.

## The two things every Malaysian statement has that this could not read

Still under "keep solving scanning issue". Both are on the commonest
statement layout there is, and both made a photographed statement
useless rather than imperfect.

### The brought-forward row

BAKI DIBAWA KE HADAPAN, B/F, BALANCE BROUGHT FORWARD, OPENING BALANCE.
Nearly every statement opens with one and many close with one. It is
not a transaction: a balance, a description, and no amount.

It was reported as **"Line 1: no amount could be read"** — a complaint
about the one line on the page with nothing wrong with it, on the first
line, where it is the first thing anybody reads about their own
statement.

The balance on it was the more expensive half. **It anchors the
chain**, and without it the first real line is the one line with no
pair of balances either side of it — so it was the one line whose sign
nothing could settle.

Recognised by **shape and position**, never by its words: the wording
differs at every bank and in two languages, and a keyword list is a
list that is missing the one this statement used. A balance with no
amount in the MIDDLE is a different thing — a line whose amount was
unreadable — and is still reported.

`balancesDecideTheSigns` now takes `leading` and `trailing`, and the
chain walk runs from −1 to `rows.length` so one loop covers the
ordinary pairs and both anchors. A statement printing both a b/f and a
c/f row is the ordinary case, and the walk reaching one step past the
last row is why the "is this index a real line" guard exists.

### Lines with no year on them

Maybank, CIMB and Public Bank all print `03/09` or `03 SEP` on each
line and put the period in the header **once**. `parseStatementDate`
returned null for every one of those, so a photographed statement in
that format came back as **forty lines of "no date could be read"** —
the whole statement, unusable, with nothing on screen to say why.

`parsePartialStatementDate` returns a day and a month rather than a
date, because a date it is not. `resolveStatementYear` picks the
**nearest occurrence** to an anchor: the statement's own document date,
or the first line that carried a whole year.

Nearest, not the header's year, because of one case: a statement dated
5 January 2027 with a line reading `28/12` means December **2026**.
Taking the header's year would file it twelve months out, into a
financial year that may already be closed, and the only sign would be a
reconciliation that never closes.

**Never today's year.** With nothing on the page to anchor to, the line
is still reported. A statement photographed in January whose lines are
last December would otherwise be filed a year out, silently.

Seventeen mutants across the two, all killed, controls survived. Three
survivors on the first pass were real gaps, each a case the tests did
not yet have: a foot marker that nothing depended on, a chain that
never reached past the last row, and a statement printing both b/f and
c/f.

## The prompt's first sentence said every document was a purchase

The likeliest single reason a bank statement scanned badly, and it had
been there since the prompt was written.

    "You are reading a purchase document for a Malaysian bookkeeper: a
     receipt, a supplier invoice, a bill, a payment voucher or a
     payment slip."

Then, several paragraphs later, `targetPrompt` appends the destination
list — which includes `accounting.bank_statement`. **The framing comes
first.** A statement is emphatically not a purchase document, it has no
supplier and no total, and the whole body of the prompt was about
suppliers, totals and line items.

The opening now names what actually arrives — purchase documents, an
invoice this company issued, a bank statement, a letterhead or name
card — and says plainly that a document which is not a purchase leaves
those fields null.

### Four paragraphs that each hold up code in Dart

Added, and each one is a way a Malaysian statement is read wrongly:

- **It prints no sign.** Debit and Credit are two columns and which one
  a figure sits in is the only thing that says which way the money
  went.
- **The running balance is the most valuable figure on the line**, for
  every line that prints one. `balancesDecideTheSigns` settles every
  sign from it and settles nothing at all without it.
- **The date is often a day and a month**, with the year in the header
  once — given exactly as printed, with no year added.
  `parsePartialStatementDate` and `resolveStatementYear` put it in the
  right year, **including the December that belongs to the year before
  the header's**. A reader that helpfully added the header year would
  take that decision away and get it wrong across new year.
- **The brought-forward row is not a transaction** — given with its
  balance and NO AMOUNT, which is exactly the shape `scannedStatement`
  recognises as an anchor.

`OcrExtraction.fromJson` drops null values from a row, so "no amount"
arrives as an absent key rather than an empty string. That is what
makes the shape test work, and it was already true.

Seven new assertions in `prompt_test.ts`, which runs in CI and locally.
A paragraph in a prompt has no callers, no types and no compiler, and
dropping one here silently disarms code in
`statement_import.dart` — so the test says which paragraph holds up
what.

## Seventy lines, which is not a bank statement

The likeliest reason a real statement "did not scan", and the plainest
number in this whole stretch.

All three readers sent `max_tokens: 4000`. That is right for what the
function was built to read — a receipt has fourteen fields and a handful
of lines. A bank statement is one record per printed line, and a line of
this JSON (a date, a narration the bank wrote, a reference, an amount
and a running balance) costs somewhere around **fifty-five tokens**.

    4000 / 55  ≈  70 lines

A one-month business current account runs to two or three hundred. What
came back was not a partial answer — it was `stop_reason: max_tokens`,
which this function turns into *"The document was too long to read in
one pass. Attach the page with the totals on it."* Reported to somebody
who had just photographed their statement as the scan having failed,
with advice that means nothing for a statement: every page is the point
and the totals page is the one part nobody needs.

`outputBudget(schema, cap)` reads the need **off the schema**: `rows` is
present exactly when some target repeats, which is exactly when the
answer is many records rather than one. No flag to set, and a
destination marked `repeats` in the console gets the room on its next
scan. `tooLongMessage(schema)` picks the sentence the same way, and for
a statement it names the way out with no length limit at all — a CSV or
MT940 export, which is read here rather than by a model.

**The cap is the vendor's**, because exceeding it is a 400 rather than a
truncation: Gemini 2.0 Flash tops out at 8192 output tokens where Claude
and the OpenAI-shaped endpoints go far higher. Asking for more than the
model can give would turn a long statement into a refusal, which is the
failure being removed.

### And the bug I wrote on the way

`targetSchema` returns `{ target, fields, rows }` with `rows` at the
top. **That is not what a reader is handed.** `index.ts` spreads it into
the base schema's properties:

    { ...SCHEMA, properties: { ...SCHEMA.properties, ...extra } }

so by the time a reader sees it, `rows` is at `schema.properties.rows`
and `"rows" in schema` is **false**. Written the obvious way, this
returned 4000 for every statement in production — and its test passed,
because the test asked `targetSchema` directly.

Caught by reading the call site rather than by the test. Both functions
now look under `properties` first, the tests are built from the
**assembled** schema exactly as `index.ts` assembles it, and both were
checked by putting the bug back and watching each fail. There is no
mutation harness for Deno here, so that check was done by hand and is
worth doing by hand again on anything in this file.

## DR, CR, and the figure that parsed as nothing

`double.tryParse('1250.00DR')` is null. So a statement whose bank writes
the direction as a word — which is half of them — reported **"no amount
could be read" on every line of it**, over a convention rather than
over anything being wrong with the page.

`_number` now reads four conventions, and only the first two were read
before:

    1,250.00   RM 1,250.00   MYR1250.00
    (120.00)                            brackets for a withdrawal
    120.00-                             a trailing minus, mainframe-era
    1,250.00 DR   DR 1,250.00           the direction as a word

**At either end**, because banks put it at both: after the figure on a
statement laid out in columns, before it on one laid out in running
text.

### Why taking DR/CR as a sign is safe

On a current account `DR` is money out. On a credit card the same word
describes the same movement from the bank's side and the opposite one
from the holder's, so getting it backwards would be the most expensive
mistake available here — **except that it cannot survive**.
`balancesDecideTheSigns` settles every sign against the running balance
afterwards and says so. A hint the arithmetic checks is a hint worth
taking, and there is a test for exactly that: a statement whose `CR`
disagrees with its own balance column comes out right and says it was
corrected.

### One equivalent mutant, written down

Dropping the `^` from the prefix pattern cannot be caught. The suffix is
tried first, so the prefix branch is reached only when the string does
not end in DR or CR — and a figure with the tag loose in the middle
(`1250.00DRX`) comes back null either way. There is no input that tells
them apart, and the note sits beside the assertion rather than in a
list somebody has to find.

## The importer knew, and never said

Reported with two screenshots: Upload pressed inside the bank statement
importer, beside a named Maybank account, and back came *"Nothing on
that document read as statement lines."*

### The reader was never told what it was reading

The `ocr` edge function took `org_id`, `attachment_id` and `provider`.
**Nothing else.** So a screen that exists to import bank statements and
does nothing else uploaded a statement and asked the reader to pick
from seven destinations with no hint at all. Classify it as a bill and
`rows` comes back null — and `rows` is the only place statement lines
can be.

`narrowToTarget(targets, key)` narrows to the one the caller named.
Three things follow at once: **`rows` is certainly in the schema** (not
"if some other target happens to repeat"), the prompt stops describing
six destinations that are not this one, and the other targets' fields
stop being asked for — which on a long statement is output budget spent
on nulls.

`targetPrompt(targets, known)` changes the job entirely when the
destination is known: from *"decide which of these it is"* to *"this is
a bank statement, transcribe it"*. **Null stays sayable** — somebody
who picked the wrong file has said something untrue and the reader must
be able to disagree — but it is told not to quietly choose a different
destination, because the screen that asked has nowhere to put one.

**An unknown key widens rather than narrows.** A caller out of step
with the database gets the behaviour it had before, every target
offered, not a reader with nothing to choose from — which would make
every scan from that caller return nothing.

`ScanDestination.targetKey` is the Dart side, with a round-trip test
against `destinationFromTarget`. Two tables of the same facts drift,
and the failure when they do is *silent*: a stale key widens back and
the hint is simply ignored.

### And my own message was wrong about all three failures

It said *"a platform administrator sets up under Kinds of document."*
**`0683` set the statement's five columns up and they are live** — so
the one person who saw it was sent to configure something already
configured, on the strength of a guess this screen had no business
making.

It also wore one sentence over three different failures. Now:

- the scan failed outright → *"could not be read at all"*, and where to
  try a different reader;
- `foundNothing` → *"nothing legible came back"*, and the usual reason;
- read fine, read as something else → *"read, but not as a bank
  statement"*, and what to check.

Eleven new assertions on the edge function, four killed mutants on the
key table, control survived. The edge-function assertions were checked
by putting each bug back by hand and watching the right test fail —
there is still no mutation harness for Deno.

## The live database, and the one field my own prompt suppressed

The Supabase connector attached mid-session, so this is the first thing
in this stretch checked against **the real database** rather than
reasoned from the code. Three scans were there, all
`target: accounting.bank_statement`, all `status: ok`.

### What already works, proven on real paper

A photographed Maybank statement — `IMG_7621` — **imported cleanly**:
eight transactions, one deposit and seven withdrawals, and the balance
chain closes exactly from the 504.50 opening to the 10.50 close. The
reader returned `OPENING BALANCE` with a null amount and a balance,
which is precisely the brought-forward shape `7b9bc7fe` added, and the
response carried **no `fields` key at all** — proof the narrowing from
`faa23d90` was live and the schema had been cut down to the statement
alone.

### And what did not

Two RHB PDFs, 43 and 59 rows. The reading is faultless: correct target,
b/f and c/f rows in the right shape, signed amounts, running balances,
multi-line narrations preserved. Every line prints `01 Oct` or
`23 Jan` — **a day and a month, no year** — and `document_date` came
back **null**.

`resolveStatementYear` then has no anchor, refuses to guess, and every
line of both statements is thrown away.

**That was this prompt's own doing.** The rewrite in `de693ad0` told the
reader a statement *"does not fill in the fields above"*, so it
dutifully left the one generic field that could place those lines in a
year. A correct instruction, one exception too broad.

`document_date` is now carved out explicitly and told it is **not
optional**, with the consequence spelled out — a statement whose lines
have no year and no `document_date` cannot be filed at all.

### Forty-three copies of one sentence

The other half. Each unplaceable line raised its own problem, so the
dialog showed five identical *"no date could be read"* messages out of
forty-three, none of which named the cause. They are now **counted and
said once**, naming the count, the reason and what to do — and stating
plainly that nothing was guessed.

A line that is genuinely unreadable (`smudged`) still keeps its own
line number: folding it into the count would hide a real failure among
placeable ones.

### The assertion that earned its keep

Reflowing the statement paragraph split `"in the order printed"` across
two array entries, so the joined string no longer contained the phrase.
`prompt_test.ts` caught it immediately. That is exactly why those
assertions exist — a prompt has no callers, no types and no compiler,
and the failure would have been a reader quietly told something
slightly different.

## The year was in the file all along

The handover PDF the user attached — *Malaysian Bank & Credit Card
Statement Parser* — sets the extraction order in its Stage C: **native
PDF text first, geometry second, OCR third, vision/LLM only for what is
left**, and §15 repeats it: "the LLM must not be the final authority for
transaction amount, sign or balance when deterministic evidence exists."

This repository already owned the deterministic half and the statement
importer had never asked it anything.

`app/web/pdfjs/` has had `pdf.js` vendored for two years — 1.8MB, lazy,
served from our own origin so no CDN sees anybody's documents — and
`text_reader_web.dart` exposes `readTextFromPdfBytes` with
`onDeviceReadsPdf => true`. It was wired only to the "on this device"
reader CHOICE in Settings. So `_readStatement` sent every PDF straight
to the edge function to be LOOKED AT by a vision model.

RHB exports a text PDF. Its period is printed on page one as selectable
text. We asked a model for the year instead, it declined, and fifty-five
lines of a faultless reading went on the floor — which is the bug the
user photographed.

### `statementPeriodFromText`

Pure, in `statement_import.dart`, so the parser stays testable with no
platform behind it. `pdfTextLayer` in `scan_runner.dart` is the seam
that feeds it.

It reads a LABEL and the date beside it — `Statement Date`, `Tarikh
Penyata`, and the period forms in both languages, taking the LATER date
because that is what a statement is named by. It does **not** hunt for
loose dates: a statement's text layer is thick with them — a print date,
a payment due date, every transaction line, an address whose postcode
reads like a year — and taking the first thing shaped like a date is
precisely how a statement gets filed twelve months out.

With no label it will accept ONE named month and year **in the header
region only**, and refuses where the header offers two. Numeric
`10/2025` is not enough, because it is also the middle of `01/10/2025`.

It OUTRANKS `document_date`. One was extracted from the page; the other
was a question put to a reader that may decline — and did.

### Bahasa Melayu months, which were never read

`_monthNumber` took the first three letters and matched them against an
English list. Five of the twelve Malay months do not survive that: MAC,
MEI, OGOS, OKTOBER, DISEMBER. The other seven were being read by
accident.

So a statement printed in Malay came back as every line unreadable —
over the language it was printed in. Maybank, CIMB and Bank Islam all
issue them. It is now a map covering both languages.

### And a heading that was false

The import dialog printed `"$n lines were corrected against the running
balance"` above the notices. True while a sign repair was the only kind
of notice; false the moment a second kind existed — and wrong twice
over, because it also counted NOTICES as LINES. One notice covering
fifty-five undated lines would have announced itself as one line.

`noticesHeading(int)` is now a pure function with assertions on it,
claiming neither a cause nor a line count. Each notice carries its own.

### What is NOT fixed by this

- **A photographed statement has no text layer.** The prompt change in
  `95e08146` is still what carries those, and it is a request rather
  than a guarantee.
- **A phone cannot do this at all.** `onDeviceReadsPdf` is false under
  `dart:io` — ML Kit takes an image and there is no `pdf.js` on a phone.
  `pdfTextLayer` returns null and the reading proceeds exactly as
  before; the assertions in `statement_period_test.dart` are about that
  degradation, because it is the half that runs everywhere.
- **The parked-photograph path** (`_takeParkedStatement`) has no file
  bytes, so no period.

### Still open from the handover, and the user has not chosen

Named to them, unanswered: whether to sequence the whole six-phase
program or make the statement path solid first. The gaps ranked were
(1) deterministic PDF text — this commit; (2) **credit-card statements,
entirely absent** from the seven scan destinations, and half the
handover is about them — statement date vs due date, statement balance
vs outstanding, a sign convention that inverts; (3) per-bank adapters
with fixtures; (4) the confidence/status ladder.

Two decisions left with the user, both real:

- §4 says **"do not send bank statements to arbitrary third-party OCR
  services by default"**. They currently go to Gemini. This commit
  reduces it — a text PDF now yields its period without leaving the
  browser — but the document itself still goes out.
- §5 says **never use floating point for money**. The Dart import path
  uses `double`. The ledger is safe (`numeric` throughout, and
  `import_bank_transactions` re-checks), so this is preview arithmetic,
  not posting arithmetic.

## Three real statements, three different defects

The user sent three of their own statements after the fix above was
still not enough: Hong Leong (9pp), AmBank (3pp) and UOB (14pp). Each
broke something different, and the reported one was not what the
previous commit had addressed at all.

### `01Jan` — no separator, which is what the screenshot said

AmBank prints the day and month welded: `07Dec`, `26Dec`, `01Jan`,
`13Jan`. `parsePartialStatementDate` required `[\s-]` between them, so
it returned null on every line — "0 lines read, 27 could not be", over
dates that are perfectly legible. The separator is now optional.

### AmBank prints labels and values in two blocks

Its text layer extracts as every label, then every value:

```
ACCOUNT NO. / NO. AKAUN
STATEMENT DATE / TARIKH PENYATA
: 1234567890123
: 01/12/2025 - 31/12/2025
```

The period is three lines below its label, behind the account number.
`statementPeriodFromText` tried only the next line, found an account
number, and gave up on a period printed in full. `_labelWindow = 4` now
scans a short way down. SHORT ON PURPOSE: a window long enough to reach
the transaction rows would anchor the statement to its own first entry,
and there is a test that fails if it is widened to 40.

### Hong Leong welds the address onto the period end

`09/12/24 - 08/01/25PERSIARAN SG LONG 2`. `_datesIn` ended its
day-first pattern with `\b`, and there is no word boundary between `5`
and `P` — so the closing date was invisible and the OPENING one was
taken instead: a statement anchored to the wrong end of itself. The
boundary is now `(?!\d)`, which keeps the year from running into a
reference number (the thing `\b` was really guarding) while letting a
welded letter through.

### And the fourth, which the tests found rather than the files

Relaxing the separator turned `03DECLINED` into 3 December and
`12MARGIN` into 12 March, because `_monthNumber` matched on the first
three letters. Harmless while a separator was required; dangerous the
moment it was not. A month name must now be a PREFIX of a real month
name — `DEC`, `SEPT` and `OGOS` are; `DECLINED` agrees for three
letters and then disagrees.

No two months across the two languages share a three-letter prefix with
different numbers, so there is nothing to disambiguate.

### Fixtures, and what they are not

The layouts in `statement_period_test.dart` are copied from the real
files. The account numbers, names and addresses are NOT — those are
somebody's actual banking details and do not belong in a repository.

One caveat recorded beside them: they were extracted with a different
PDF library than the browser's. `pdf.js` joins its text items with a
space unless the item carries `hasEOL`, so it will not weld tokens in
the same places. Both spellings are asserted where it matters.

### UOB, and a cap worth knowing about

UOB's statement is largely inline images — its text layer is legal
boilerplate and column headings, with the rows rendered. It stays a
vision-model job and nothing here helps it.

`_pagesRead = 3` in `text_reader_web.dart` also caps the typed reading
at three pages. Fine for a header, and NOT fine if anything later wants
the transaction lines off a 13-page statement's text layer.

## A corpus that measures us, separately from the model

The SmartScan Training/Handover v2 pack: 120 marked-synthetic fixture
PDFs, twelve document families crossed with ten variants, each with
ground-truth JSON and CSV. Nothing in it is a real institution, account
or person.

### What it settled, measured rather than argued

Running the REAL parser over all 120 before changing anything:

| | |
| --- | --- |
| Import correct, reader assumed perfect | **120 / 120** (1,488 rows) |
| Import correct when the reader loses every sign | **120 / 120** (108 repaired from the balance chain) |
| Statement period found | **0 / 120** |

The first two are the useful news and neither had ever been measured.
Our half — the dates, the arithmetic, the sign logic — files all twelve
families correctly, and `balancesDecideTheSigns` puts back every one of
1,488 signs when handed the worst plausible reading.

The third was a real gap in a single line: these fixtures label it
`Period: 01/08/2026-31/08/2026` and bare `period` was not in
`_periodLabels`. Added LAST in the list so every more specific label
still wins first. 120 / 120 after.

### The gate

`app/test/smartscan_corpus_test.dart` over
`app/test/fixtures/smartscan_corpus.json` (380KB). The PDFs are NOT
committed: Dart cannot open one on a test VM, and a corpus that needs a
Python library to run is a corpus that stops being run. What is
committed is the extracted text layer plus ground truth.

**Dates are stored AS PRINTED (`01/08/26`), not as ISO.** The first
version of this fixture stored the ground-truth ISO date in the `rows`,
which meant `parseStatementDate` was never exercised — a mutant that
put two-digit years in 1926 instead of 2026 survived the whole corpus.
That is exactly the failure the mutation harness exists to catch, and
it would have left a 120-document gate that could not see a century
error.

Four mutants, all killed: the bare `period` label removed, the balance
chain stopped repairing, the century flipped, and the period taking its
start rather than its end. The last needed its own assertion — both
ends of a one-month period share a year, so the year check alone could
not tell them apart; the period end must now not precede the last line.

### What it does NOT prove

Nothing here runs a vision model. `rows` is what a PERFECT reader would
return, so every failure is ours and every success says only: given a
correct reading, we file it correctly. The model's eyesight is measured
by the live database, not by this.

## Phase 1: what a statement says about itself

First phase of the SmartScan programme from the two handovers. A
repeating document is now asked for a HEADER beside its rows:
`period_start`, `period_end`, `opening_balance`, `closing_balance`,
`account_number_tail`, `institution`.

### No migration, and why

`scan_target_fields` maps to COLUMNS of the destination table, and a
statement header maps to no column of `bank_transactions`. `0683`'s own
reasoning settles it: a question whose answer does not vary per
installation should not be asked once per installation. So the header
is hard-coded in `targets.ts` beside `rows`, not seeded.

`currency` is deliberately NOT in it. The base schema already has a
top-level `currency`, and offering the same thing twice is what the
`0682` comment in `targets.ts` warns against. Multi-currency is its own
family in the corpus and gets done properly later.

### The check that could not be made

`import_bank_transactions` walks the running balance from each line to
the next. That catches a line misread BETWEEN two balances, and it
cannot catch:

- a line missing from the END of the statement;
- a second page never read;
- a first line never returned.

Each of those leaves a chain that closes PERFECTLY, because what is
missing is missing from both sides of every comparison that remains.
The statement reconciles to a number nobody printed.

`opening + sum(every amount) == closing` is the check that spans the
whole document. One sen of tolerance, which is the acceptance matrix's
own figure. Nothing is adjusted to make it agree, and the reader is told
to give the two balances as printed or to give null — a closing balance
worked out from the rows agrees with the rows by construction.

Proved across the corpus: all 120 foot, and dropping the last row of
each fixture is caught **108 times out of 108**.

### Four characters of the account number

`account_number_tail`, never the whole number, even where the statement
prints it in full. Enough to say "this statement may not be for the
account you are importing into"; not enough to be worth leaking. That
is `docs/SECURITY_PRIVACY.md` in the pack, applied.

### And a regression of mine, found on the way

`95e08146` made ONE message cover fifty-five undated lines — the right
change, because fifty-five copies of one sentence buries the cause. The
heading above it went on counting MESSAGES:

    '${preview.problems.length} could not be'

So fifty-five discarded lines would have announced themselves as "1
could not be", on the exact line the user photographed twice.

`StatementParse.unreadable` now counts LINES. A document-level problem
counts as none of them: a statement that does not foot has a problem
with the STATEMENT, not with any line, and inflating a line count with
it would be the same mistake pointing the other way.

### Is it even the right account?

`accountTail` takes four digits off both sides with the punctuation
stripped, because a statement prints `**** 4001` while the account was
typed into this system as `3900-0007-994` — comparing the strings
compares the hyphens.

A mismatch is a NOTICE, not a refusal, for two reasons. Four digits can
collide. And somebody may be filing a statement from an account that was
renumbered, or an old one from before a migration, whose lines are still
perfectly importable — refusing would make this system wrong about a
document the person holding it knows more about than we do. It names
both tails so it can be checked against the page.

`_PasteDialog` takes the number as a parameter rather than looking it
up: the dialog does not know which account the person pressed Upload
beside, and the screen does.

### And a latent bug `check_async_value.py` caught

I wrote `ref.read(bankAccountsProvider).value ?? const []`.
`AsyncError.value` THROWS, so the `??` never runs — an errored provider
would have taken the Import button down with it. `.valueOrNull` is the
form that returns null on error and loading. The gate has a budget of
39 and my line made it 40.

### Gates

Twenty-two assertions in `statement_header_test.dart`, two more in the
corpus gate, fourteen mutants across two sweeps killed with both controls surviving, 38 deno
tests, analyzer exit 0.

## UOB, and a correction I owed

I told the user UOB's statements were "largely inline images" and would
stay a vision-model job. That came from page one of ONE file — a page of
legal boilerplate with the table headings rendered — and it was wrong
about the document.

Four more UOB statements have a full text layer: around eight thousand
characters in the first three pages, every transaction in it.

### The shape, which no other bank here prints

```
Basic Savings Acct* A/C Number: 1-2-3 RM 01 FEB 2021  To 28 FEB 2021
```

The period is on the same line as the account number with NO LABEL
anywhere — not `Statement Period`, not `Tarikh Penyata`, nothing. What
resolves it is the UNLABELLED path: one month and one year in the
header region and nothing contradicting them. It lands on the period
END on all four (28 Feb 2021, 31 Mar 2023, 31 May 2023, 30 Jun 2023),
because the last day of the only month named is where the period ends.

Line dates are `01 FEB 01 FEB ...` — a transaction date and a value
date, neither carrying a year — and place against that period.

Four fixtures in `statement_period_test.dart`, account number and name
redacted and the layout intact, plus the guard: a header naming TWO
months refuses rather than guesses.

### And the limit that remains

`_pagesRead = 3` in `text_reader_web.dart` reads the first three pages
only. Fine for a header, and these statements run to 6, 12, 18 and 22
pages — so every transaction past page three still depends on the
model, not on the text layer.

## The user was testing a stale build

Worth knowing before reading any bug report from this stretch. A
screenshot showed the toast:

> A reader has to be asked for the lines, which a platform
> administrator sets up under Kinds of document.

That string was DELETED in `faa23d90`, which deployed and went green.
So the browser was serving a cached Flutter web build from before that
commit, and every test the user ran that day was against code
predating the whole day's work. `web/sw_rescue.js` exists because this
has happened before. A hard reload, or unregistering the service
worker, is the fix.

## The same file, twice — `0711`

Asked for as "when the bank statement or ai scan or any file is
uploaded it should keep a copy of the file in storage so it can be used
back as[well as] will prevent duplicate upload of same file".

### Half of it was already true

`attachments` has kept every upload since `0010`, the bytes live in the
`attachments` bucket, and `0708` refuses to DELETE a file once a reading
or posting is built from it. Nothing has ever been thrown away.

### The half that was not

Nothing anywhere knew what a file CONTAINED. Upload the same statement
twice and it became a second row, a second object, and a second scan —
which is a second charge to whichever reader the org pays for.
`import_bank_transactions` still refuses a line it has already posted,
so the books stayed right; what was wasted was money.

`file_name` cannot answer it: `stampedFileName` puts the moment of
upload into every name, so two uploads of one file never share one.
`file_size` alone is a coincidence waiting to happen.

### Three decisions, each a way it could have gone wrong

**NULLABLE, permanently.** Every existing row has no hash and cannot be
given one without downloading every stored object back. A migration that
reads the whole bucket to populate a column that only helps future
uploads is not worth it. Callers treat null as UNKNOWN, never as "not a
duplicate", and `identicalFile` documents that.

**NOT UNIQUE.** A unique index would make the database REFUSE the second
upload. Somebody re-uploads a file when the first scan went badly and
they want another go — their document, their call. The index is for
LOOKING UP.

**Scoped to the org.** Two companies uploading the same public form are
not duplicates, and one org must never be told a file exists on the
strength of a row it cannot see.

### What is built and what is not

Built: `contentHash(bytes)` (pure), the hash written on every upload,
migration `0711`, and `supabase/tests/attachment_content_hash.sql` in
CI's run list.

**Now built, in the commit after:** the LOOKUP and its caller. See
"Telling somebody the file is already here" below.

It was written and then taken back out of `0711`'s own commit, because
`check_unreachable.py` refused it — "a wrapper for a call nobody can
make is a promise the product does not keep" — and the gate was right.
Reusing an existing attachment is not the one-liner it looks like: a row
carries `entity_table`, `entity_id` and `0708`'s evidence lock, and
handing a new document an attachment filed against a different record
needs more thought than a commit about hashing should contain.

So this commit RECORDS and does not yet match. That is not a
placeholder: a hash cannot be computed backwards without downloading
every stored object, so the only way to have one for today's uploads is
to take it today. Every upload from `0711` onward builds the history the
lookup will need.

### The gate my local sweep could not see

CI run 2129 went RED on "Check the API description still matches the
schema". `docs/api/openapi.json` and `docs/api/llms.txt` are GENERATED
from the live schema and carry the highest applied migration in their
header — they said `0710` and the schema now says `0711`, plus three
lines for the new column.

The reason it was not caught here: the local gate sweep runs
`for f in scripts/check_*.py`, and the generator is
`scripts/generate_api_description.py`. It does not match the glob.

**Run this too, before any push that adds a migration:**

```
DB="postgresql://postgres@/postgres?host=/var/tmp&port=5599"
python3 scripts/generate_api_description.py "$DB" --check
```

The local Postgres reproduced CI exactly — same line counts, same first
difference — so regenerating locally is safe. The diff was the version
in two files and the new `content_sha256` property, and nothing else.

### Verification

Five assertions against the PUBLISHED SHA-256 vectors rather than
against our own output. Four mutants killed with the control surviving,
including "hash only the first kilobyte", which would call two 22-page
statements identical whenever their first page matched. The SQL test was
watched to FAIL twice: with the index dropped, and with it made UNIQUE.

## Telling somebody the file is already here

The other half of `0711`. `captureAndRead` now asks, BEFORE uploading,
whether this organization has filed these exact bytes before —
`Repo.identicalFile(bytes)` — and carries the answer out on
`StagedReceipt.alreadyHere`. The statement importer turns it into a
notice.

### The choke point, and why there

`receipt_capture.dart`, inside `captureAndRead`'s `whileScanning`
action, just before `repo.uploadAttachment`. EVERY scan path goes
through it — statement, receipt, bill, expense — which is what was
asked for: "bank statement or ai scan or any file". The comment two
lines above it already said the second press is "a second upload and a
second charge"; it simply had no way to tell.

### The upload still happens, and that is the decision

Three options were on the table: reuse the existing attachment row, make
a new row pointing at the same storage object, or upload normally and
SAY so. The third was chosen.

An `attachments` row is not merely a file. It carries `entity_table`,
`entity_id` and `0708`'s evidence lock, so handing this document
somebody else's attachment would re-file THEIR paper against a record
they did not choose. Telling them costs one duplicate object in a
bucket; reusing silently could cost them the audit trail.

And re-uploading is often deliberate — the first scan went badly and
they want another go, on their own document, for a reason they
understand better than this system does. So it is a NOTICE beside the
sign repairs, never a refusal, and `alreadyHereNotice` has an assertion
that it does not read like one.

### The lookup never blocks

A query that throws is treated as "found nothing" and the capture
carries on. The one thing worse than missing a duplicate is refusing
somebody's document over a lookup that went wrong.

### Verification

Ten assertions in `content_hash_test.dart`, five mutants killed with
the control surviving — including "it reads as a refusal instead of a
notice", which is how this feature most plausibly goes wrong.
`check_unreachable.py` is green because `identicalFile` now has a real
caller; it was refused in the previous commit and that refusal was
correct.

### And the sweep now runs the API-description check

`0711` taught this the hard way (CI 2129). The local gate command now
ends with

```
python3 scripts/generate_api_description.py "$DB" --check
```

because `for f in scripts/check_*.py` never matched the generator.

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
eleven ways a green test covers a broken screen — the eleventh is
opening it with every provider answering an empty list, which is how
fifty dialogs passed while proving nothing. For Deno there is no
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

## Counting the live database: most of it is demo, and it evaporates

A correction to something `0712` states as fact, and a trap for anyone
who measures production the way that migration did.

`0712` decided not to backfill a credit card's sign because the live
database held no `credit_card` account, and offered the surrounding
counts as context:

    fifteen current accounts, two cash accounts and sixty-eight
    statement lines between them

The `credit_card` half is true and was still true when checked again an
hour later. **The sixty-eight lines are not what that sentence implies.**
Re-running the identical query eighty minutes on returned **zero**
`bank_transactions`, and `attachments` had gone from six to zero as
well.

Nothing was lost and nothing is wrong. Fourteen of the seventeen bank
accounts belong to **demo companies**, and `app.demo_rebuild()` DELETES
and recreates every one of them — `0682` says so in its own comment.
The rows were demo rows and a rebuild ran between the two queries.

Three things follow, and the third is the one that costs time:

- **Count `is_demo` separately, always.** A bare `count(*)` over this
  database is mostly a measurement of the demo tenants, and it changes
  under you. `join public.organizations o on o.id = x.org_id` and group
  by `o.is_demo`.
- **The MCP connector runs as `postgres`**, and none of these tables
  sets `FORCE ROW LEVEL SECURITY`, so the owner bypasses RLS and a count
  is literal. When two identical queries disagree, the rows really did
  go — do not go looking for a policy hiding them, which is where the
  first ten minutes of this went.
- **`reltuples` lies in the useful direction.** `pg_class.reltuples`
  still read 6 for `attachments` after the delete, which is how the
  contradiction was spotted at all: an `ocr_scans` row referencing an
  attachment that `count(*)` said did not exist.

Real, non-demo footprint at the time of writing: **three bank accounts,
all `current`, and one scan** — gemini, `status: ok`, twenty rows. That
is the whole of the production evidence any of this work rests on, and
it is worth re-measuring rather than assuming, because one scan is also
what makes a four-state confidence ladder premature.

## Six complaints about chat and calling, and six different causes

Reported in two messages, the second while the first was being
investigated. They are written up together because they were found
together, not because they share a cause — they do not share one, and
guessing that they did would have cost the whole afternoon.

> - now when 1 user ends the call why the other user call screen does
>   not close
> - also for chat messaging why does it not have read reception double
>   tick
> - also for chat messaging why does it flicker when its updating
> - also for chat messaging why does not get instant update
> - also for chat messaging why attachment only file but no option to
>   attach image or snap image to attach
>
> *(and, from a screenshot)* `PlatformException(DarwinAudioError, Failed
> to set source … AVPlayerItem.Status.failed on setSourceUrl)` over a
> voice note

### One: a call is a database row, and hanging up wrote only the row

`chat_end_call` marks every participant `left` and the call `ended` in
the database. It tells the media server nothing — there is no signalling
path from Postgres to mediasoup and there does not need to be, because
the row is what a call IS.

So on the other device: the websocket stayed up, `CallPhase` stayed
`connected`, and the only thing that changed was that the grid emptied.
`call_screen.dart` draws an empty grid as **"Waiting for somebody to
answer"**, so a call that finished minutes ago went on saying it was
waiting until somebody pressed back.

`CallScreen` watched nothing. Its three exits were the hang-up button,
the back gesture, and its own socket dying, and none of those is what
the other person did. `chat_live.dart` was already invalidating
`chatActiveCallProvider` on every `chat_calls` change — the answer was
arriving and nothing was listening to it.

It listens now, from `initState`, on three conditions: no row (the
status is `ended`), a row for a different call, or a row in which this
person is `left`. Plus a fourth that is not about ending at all:
**everybody else has gone**. Only whoever STARTED a call may end it for
everybody — `chat_end_call` refuses anybody else — so in a two-person
call the one who did not start it can only *leave*, which writes their
own participant row and nothing else, and leaves the starter alone with
a live row and an empty grid. A high-water mark of the joined count
catches that, and has to be a high-water mark rather than "is anybody
else here", because at the start of every call the answer is no.

**`listenManual`, not `ref.listen`.** `ref.listen` fires on CHANGES, and
the value already in the provider when the screen opens is not one. The
first version used it, the call the screen was opened for went unseen,
and the flag that distinguishes "not started yet" from "already over"
stayed false. Only the manual form takes `fireImmediately`. The four-second
poll beside it is not decoration either: hanging up is the one thing
that must not depend on a socket somebody else's network is in charge of.

### Two: the grey tick was drawn against a column the RPC does not return

The blue double tick works and always has — that is `chat_mark_read`,
and the chat screen calls it on open. What has never appeared is the
**grey** double tick, the middle state: delivered but not read.

`chat_receipts.dart` was written to fix exactly that, and could not
work. It read the conversation out of `c['id']`.
`chat_my_conversations` returns **`conversation_id`**; there is no `id`
column, and `chat_screen.dart` reads `c['conversation_id']` twice on its
way down the same list. The `c['id'] != null` guard therefore threw away
every row, `newlyDelivered` returned an empty list on every device since
the day it was written, and `chat_mark_delivered` still had no caller.

Nothing failed, because **the test's fixture used `'id'` too.** Twelve
green assertions against a shape production never produces. This is
number twelve for `docs/widget-tests.md`: a fixture that agrees with the
code instead of with the database tests nothing but itself. The fixture
is the fix; the mutant `read the id off a column the RPC never returns`
now kills the test.

A second defect underneath it: the "already reported" set was keyed on
the conversation. Marking delivered does not change `unread`, so the
first batch was reported and nothing after it ever was — message two
would have sat on one tick until the app restarted. Keyed on the
conversation *and* the message it was newest at now.

### Three and four: one cause, two complaints

Both the flicker and the lag came out of `chat_live.dart` treating six
tables as one kind of event.

Two of those tables are written by machines, not people. `chat_presence`
takes a heartbeat from every signed-in colleague **every thirty
seconds**. `chat_typing` takes a row every few seconds for as long as
anybody is pressing keys — at both ends, because a client is sent its
own writes back. Every one of those invalidated
`chatConversationsProvider`, so the list, the open thread's header and
the unread counts were refetched over and over while a conversation was
simply being had. And a message — the one row anybody is waiting on —
queued behind them and waited out the same 250 ms window.

A screen that will not sit still and will not keep up is a strange pair
of complaints until you notice they have one cause.

Two speeds now. What a person did (`chat_messages`,
`chat_participants`, `chat_calls`, `chat_call_participants`) flushes in
150 ms and moves everything it touches. What a timer did flushes in two
seconds and moves only the dot and the word it is about, with the
conversation list allowed one refetch per twenty seconds out of the pair
— presence does draw "online" beside a name and does have to arrive
eventually.

The fast window is also no longer a resettable debounce. `_settle
?.cancel()` on every event has no upper bound: a steady trickle holds
the flush off for as long as the trickle lasts, which is precisely a
busy conversation.

And `subscribe()` was called **with no callback**, so a subscription
that was refused, timed out or quietly died was indistinguishable from
one with nothing to deliver. Chat simply stopped updating and nothing
anywhere knew. It takes `_onStatus` now: a channel that errors is
resubscribed after three seconds, and a channel that comes back forces a
full refetch rather than working out what it missed.

All six chat tables were checked against production and all six are in
`supabase_realtime` with `REPLICA IDENTITY FULL`. `chat_attachments` is
not, and does not need to be — the message insert is what moves.

### Five: `file_picker` cannot reach a camera

There was one attach button and it opened a document browser. A
photograph taken thirty seconds ago is somewhere inside that browser
under a name nobody knows.

`image_picker` was already a dependency, for the receipt camera, and
already asks for the right permission on each platform. The attach
button is a three-way menu now — take a photo, photo, file — with the
shutter shown only where `cameraLikely` says there plausibly is one.
Photos go out at quality 88 and a 2400px long edge, which is still wider
than any screen they will be read on and is not four megabytes off
somebody's data plan. The two iOS usage strings were widened to say
chat as well as receipts.

### Six: `BytesSource` is not a byte source on Apple platforms

The voice note in the screenshot. `audioplayers` has no native
`setSourceBytes` on iOS or macOS — the Swift side answers "not currently
implemented on iOS" — so the Dart side writes the bytes to a temporary
file **named after their hash, with no extension**, and plays that file
instead. AVFoundation then has nothing to go on: no extension, no
content type, no way to tell an m4a from a webm. Hence
`AVPlayerItem.Status.failed on setSourceUrl`, from a call the app never
made.

A mime type is the entire fix — `audioplayers` forwards it to
`AVURLAssetOverrideMIMETypeKey`, which is the hint AVFoundation is
missing. The row already carries one; it was simply not passed down. It
costs nothing on Android or the web, where the decoder sniffs the
container itself.

**Not verified on a device.** The same caveat the top of
`chat_attachments.dart` already carries: this environment has no
microphone, no camera and no AVFoundation. The mechanism is read out of
the plugin's own source and the failure it explains is the one in the
screenshot, but only a phone can say it plays.

## "Why does the whole chat page reload when text is sent or received?"

It did. So did every other screen in the application, whenever anybody
in the company saved anything. Chat was simply the screen somebody sits
and watches while writes land every few seconds.

Three things had to be true at once, and **each one alone would have
hidden the other two** — which is why all three are fixed and all three
are asserted. Fixing only the one that was found first would have made
the symptom go away and left the defect in place.

### The chain

1. **The broad refresh is the normal path, not an edge case.**
   `live_updates.dart` narrows a table's refresh to a handful of
   providers when `_watchers` has an entry for it, and otherwise calls
   `_refreshEverythingFetched()` — every provider holding an
   `AsyncValue`. That fallback is deliberate and documented.

   What nobody had counted is how often it fires. **296 tables carry a
   `live_change_*` trigger and about fifteen have a narrow entry.** So
   the sledgehammer is what happens on nearly every write in the
   product. `chat_participants` is one of the 281, and chat writes it
   constantly: `chat_mark_read` on opening a thread,
   `chat_mark_delivered` on every message that arrives.

2. **The sledgehammer threw away the company.** `currentOrgProvider`
   holds an `AsyncValue`, so it was in scope. Invalidating it rebuilt
   `repoProvider`, which is `Repo(client, org.id)` — and `Repo` had no
   `==`, so **every rebuild produced an object unequal to the last**.

3. **Nearly everything watches the repository.** `requireRepo(ref)` does
   `ref.watch(repoProvider)`. A watched dependency changing is a
   **reload**, not a refresh, and `AsyncValue.when` skips its loading arm
   on a refresh and **does not skip it on a reload**. So `AsyncView`
   drew six skeleton rows over a conversation it was still holding, and
   then drew the conversation again.

The distinction between a refresh and a reload is invisible from inside
the widget and means nothing whatever to the person looking at the
screen. Both have a previous value in hand and it is still the best
answer anybody has.

### Proved before it was fixed

Not reasoned about — measured. A throwaway probe rendered an
`AsyncView` over a provider with data in it and printed what happened:

    AFTER INVALIDATE  skeleton=0 text=1      <- a refresh, content kept
    AFTER DEPENDENCY  skeleton=1 text=0      <- a reload, content ERASED

That single line settled a question three rounds of reading the code had
not. Invalidating a whole `family` was probed too, in case
`chat_live.dart`'s family-wide invalidate was the culprit — it is also a
refresh, and it is not.

### The four changes

- `Repo` has value equality on `(client, orgId)`, `identical` on the
  client because `SupabaseClient` has none. Keeping the earlier instance
  also keeps its `_attempts` map, so an idempotency record no longer
  evaporates when an unrelated list refreshes.
- `currentOrgProvider` and `organizationsProvider` joined
  `liveUpdateNeverInvalidated`, beside `authStateProvider` and for the
  same reason. Nothing is lost: a company really being renamed arrives
  as a change to `organizations`, which has a narrow entry of its own,
  and `currentOrgProvider` watches `organizationsProvider` and follows.
- `AsyncView` passes `skipLoadingOnReload: true`. A skeleton is for a
  screen with nothing to show; erasing something correct to draw a
  picture of it arriving is strictly worse than leaving it up.
- The nine chat tables got narrow entries. **This is an optimisation and
  not the fix**, and the comment beside them says so, because the first
  diagnosis stopped there and it was the wrong place to stop.

### One thing this made worse before it made it better

The delivered-tick fix in `5e6ae1b1` gave `chat_mark_delivered` its
first working caller. Every incoming message therefore began writing
`chat_participants` — which, until this commit, meant a full-app refresh
per message. The grey tick arrived and took the whole screen with it.
Worth remembering when a fix lands on top of a defect nobody has found
yet.

## The incoming video is sideways, and this is as far as reading gets

Not fixed. Diagnosed, with the last step needing a device.

Both phones show the remote camera rotated 90° while their own
picture-in-picture is upright. That pairing is the signature of
**Coordination of Video Orientation (CVO) not surviving the trip**: the
phone captures landscape sensor frames and sends the rotation as an RTP
header extension rather than rotating the pixels, and a receiver that
never negotiated the extension draws the raw sensor frames. The local
preview is upright because it never goes through RTP at all.

What was checked, and rules nothing out:

- mediasoup **does** support `urn:3gpp:video-orientation` —
  `supportedRtpCapabilities.js`, preferredId 8, `direction: 'sendrecv'`
  — so the router is willing.
- `mediasfu_mediasoup_client` never mentions the extension, so it is not
  being stripped on purpose.
- The app does **not** lock orientation: no `setPreferredOrientations`
  anywhere, and `Info.plist` allows portrait and both landscapes. So the
  device orientation the capturer reads is real.
- `_cameraConstraints` asks for 640×480, i.e. landscape, which is what
  makes the un-rotated frames look 90° out rather than merely cropped.
- In `flutter_webrtc`, `RTCVideoValue.rotation` feeds **only**
  `aspectRatio`; the pixels are rotated natively. So a sideways picture
  means the frames arrived without rotation, not that the widget ignored
  it.

The likeliest remaining cause, and the one to test first: mediasoup
computes a consumer's header extensions from the **consuming** peer's
`rtpCapabilities`, which `call_engine.dart:267` sends from
`device.rtpCapabilities`. Those come from a dummy offer, and libwebrtc
does not always advertise CVO on an offer with no video **sender**. If
the receiving side never offered the extension, mediasoup will not put
it on the consumer, and the rotation is dropped — while the sending side
negotiated it perfectly well and is relying on it.

**The one measurement that settles it:** log
`consumer.rtpParameters.headerExtensions` in `_attach` for a video
consumer. `urn:3gpp:video-orientation` present means look elsewhere;
absent means this is it.

Deliberately NOT changed on a guess. Calling was taken from a 503 to
working across two networks over one long evening, and a speculative
edit to the media path is the wrong trade against that.

## CI went red on a commit that contained no SQL

Run 2176, `ffff7127`. The diff was six Dart and Markdown files. The
failing step was **"Run the database assertions"**:

    ERROR: FAIL three counter sales are waiting to be rolled up:
           expected 3, got <NULL>
    supabase/tests/pos.sql

Run 2175 had passed the same assertions three hours earlier on the same
files. Nothing about the diff could reach SQL. What changed was the
clock.

### 17:04 UTC on the thirtieth of September

`current_date` is the SESSION's date. In CI the session is UTC. The
product's date is `app.today()`, which is `app.malaysian_day(now())` —
Kuala Lumpur, UTC+8. **From 16:00 UTC the two disagree, every single
day, for eight hours.**

Measured against production at the time, rather than reasoned about:

| | |
| --- | --- |
| `current_date` | 2026-09-30 |
| `app.today()` | 2026-10-01 |
| `date_trunc('month', current_date)` | 2026-09-01 ← the test asked |
| `date_trunc('month', app.today())` | 2026-10-01 ← the product filed |

`pos_einvoice_outstanding` buckets on `doc_date`, and a POS sale's
`doc_date` comes from `app.today()`. So the three sales existed, in
October, and the September row the test asked for was never there. One
day of skew, landing on a month boundary, is a whole month.

### The file already knew

`pos.sql` declares `v_kl_today` at line 60, with a comment describing
this exact failure — *"between 16:00 and midnight UTC it is already
tomorrow in Kuala Lumpur"*. Somebody hit it on the day board, fixed
that, and the six e-Invoice consolidation assertions twenty lines below
went on using `current_date`.

That is the thing worth remembering. The knowledge was in the file. It
was not applied to the neighbours, because on the day it was written
the neighbours were green.

### What was fixed, and what was only counted

Refused outright now, by `scripts/check_test_clock.py`: `month`, `week`
and `quarter` bucketed over `current_date` anywhere in
`supabase/tests`. Their fuses are short — one evening a month, one
evening a week — and every one is a test that goes red on somebody
else's diff. Eight were found and fixed:

- `pos.sql` — six, the ones that went red
- `pos_einvoice_consolidation.sql` — two, the identical bug, not yet
  fired
- `group_trial_balance_shapes.sql` — three, a report window that slides
  a month on the last evening of a month
- `pos_service.sql` — one, *"next Monday at ten, in the salon's own
  time"*, derived from the session's Monday. A Sunday-evening fuse.

**Counted rather than refused: `date_trunc('year', current_date)`, 150
of them.** Almost all are `create_fiscal_year` in a fixture, and their
fuse burns one evening a year — on 31 December after 16:00 UTC the
test builds FY2026 while the product posts into 2027. Too many to
convert in the commit that found this, so the number is PINNED in the
gate: it may fall, it may not rise. The gate FAILS if the count drops
without the pin being lowered, so the ratchet cannot quietly rust.

The fix is the same everywhere:

    (now() at time zone 'Asia/Kuala_Lumpur')::date

### And the lesson about green

A run that is green at 13:35 and red at 17:04 on identical files is not
flaky infrastructure. It is an assertion that was always wrong and is
only observable for eight hours a day. The first instinct — "my diff
has no SQL, so this is a flake, re-run it" — would have been wrong, and
would have left it for the next person on the last day of October.

## Who may say what this is for, and two things found on the way

### The feature: 0725

Six switches over the three answers to "What is this for?" on the
registration form — a business, an accountant, myself — one per answer
per surface. Asked for as *"Admin Console → Sign up page → add option to
show or hide for web and mobile app separately … If all are turned off
then by default it will use as 'Myself' but no selection bar will be
shown."*

Built on `0638`'s machinery exactly: columns on `landing_page`, carried
in the payload's `brand` object, read off `LandingContent`, edited in
`site_pages_admin.dart`. All six ship TRUE, because they take something
away rather than offering something new — the rule
`signin_show_register_mobile` was added under.

The rule itself is one pure function, `signup_kinds.dart`:

- three answers, or two — draw the bar;
- **one — register as that one and draw nothing.** A segmented bar with
  a single segment is a button that cannot be pressed and cannot be
  unpressed, and it invites somebody to hunt for the options that are
  not there;
- **none — register an individual and draw nothing.** Not a form that
  cannot be submitted: an operator who switched all three off said what
  they want the form to BE. The individual is the answer that needs
  nothing else to be true — no SSM number, no registered name, no paid
  module.

`settledUse` is the other half and is easy to miss: `_use` starts life
as `business` whether or not business is offered, and the payload is
re-read while the form is open. So nothing reads `_use` directly — the
metadata, the blurb and the company-name field all follow
`_registeringAs`, which is one getter, so they cannot disagree.

### Two restatements, both verified rather than trusted

A `landing_page` switch needs TWO functions changed, and the second one
is easy to miss because missing it fails silently:

- `app.landing_payload` READS the columns out to the app.
- `public.platform_save_landing_page` WRITES them, **and it sets every
  column by name.** A switch the console draws and that function does
  not list saves nothing and reports success — the optimistic UI moves,
  the round trip returns, and the value never changes.

Both are ~300–370 lines and had to be restated whole. Neither was
typed:

- `landing_payload` was transcribed and then PROVED: the transcription
  minus the six added lines was hashed and compared against
  `md5(pg_get_functiondef(...))` on production —
  `124dd36877bb18ccf463f8beb2dca75a` both sides, byte-identical.
- `platform_save_landing_page` was not transcribed at all. `0653`'s
  copy in the repository turns out to BE what is live — collapse
  whitespace and both sides are `b2ab0709fb2c948c67d10f9758d7a686` — so
  0725's version was derived from that file by inserting six
  assignments, and the derivation was checked back to the same hash.

Do it this way every time. A 370-line function restated by hand is a
transcription error waiting to be found by somebody else, and the check
costs one query.

### A widget test runs on Android, and this one nearly did not notice

The four new widget assertions were written against the WEB columns and
three of the four passed anyway, because a widget test runs on the VM:
`kIsWeb` is false and `defaultTargetPlatform` is `android`, so
`currentSurface` is `Surface.android` and the screen was reading the
MOBILE columns the whole time. Writing a per-surface test against the
wrong surface is precisely the mistake six switches exist to make
possible. They are written against the mobile columns now, and say why
in the file.

### And the constraint that has now bitten three times: 0726

`fs_filings` was `unique (org_id, fy_end)`. A practice is ONE
organization holding many client companies — that is what
`corp_entities` is for — so that key said *one set of accounts per year
end, whichever client it is for*. A great many Malaysian companies end
on 31 December, so a practice could record the first such client and not
the second.

It was never found as itself. Always as a test dying on a date:

- `supabase/tests/fs_deadlines.sql` carries a paragraph about
  **7 September 2026**, when two fixtures a day apart both clamped to
  28 February and "the file died on a duplicate key, on that day only,
  with nothing wrong in the code it tests". The fixture was rewritten.
- **Run 2177**, 1 October in Kuala Lumpur: `app.demo_amanah_accounts`
  gives Kilang the last complete calendar year (a 31 December) and Bayu
  nine months back off the start of this month — which in OCTOBER is
  the same 31 December. `demo_rebuild()` failed and took the whole
  assertion run with it.

Two workarounds and a third one waiting. The third is what turned it
from a fixture problem into a schema problem: **`demo_rebuild()` is not
a test.** It runs in production, and a demo rebuild that fails for the
whole of October is a product broken for a month.

Replaced by two partial unique indexes, because `corp_entity_id` is
nullable and a plain three-column unique would treat every NULL as
distinct — letting the practice file its OWN accounts twice for one
year, which is the one duplicate the old key was right about:

- `unique (org_id, corp_entity_id, fy_end) where corp_entity_id is not null`
- `unique (org_id, fy_end) where corp_entity_id is null`

Strictly weaker than what it replaces, so no existing row can violate
them and the change cannot fail on live data.

### The shape worth remembering from all of this

Run 2176 failed on pos.sql. Fixing it did not make run 2177 green — it
made run 2177 reach the NEXT latent failure, which had been sitting
behind the first one. A serialised assertion run reports one problem at
a time, and "the fix did not work" and "the fix worked and there is
another" look identical from the outside until you read which assertion
died.
