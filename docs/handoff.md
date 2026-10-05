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
outstanding that had already been done, the 1 October session found two
more — including one that had cost an earlier session in this same
container the use of every SQL assertion it could have run locally — and
the 4 October session found **four more**, one of which this very table
had already disproved:

| This file said | Actually |
| --- | --- |
| Per-kind PDF handling is next | Done by `0697` and `0701` |
| The bill editor and expense form need the matter picker | Done by `document_editor.dart` and `0692` |
| The client-side general journal screen is not built | `legal/client_transfer_screen.dart`, routed |
| Nothing reads `OcrExtraction.fields` | `scan_field_map.dart` does |
| Statement lines are not turned into `bank_transactions` | `importBankTransactions`, wired |
| No `bank_transactions` row ever reaches `gl_lines` | `postBankTransaction` and the "Post this line" dialog do exactly that |
| CI is the only place the SQL assertions run | `supabase/tests/run_locally.sh` runs all 382 of them in this container; it uses `initdb`, not Docker |
| `app.post_receipt_internal` still has the 1120 fallback, on purpose | `0731` replaced it: it RESOLVES an account, writes it onto the receipt, and refuses only when the company has no bank account at all |
| All thirteen `pos_tender_types` rows have a null bank account | 13 of 13 carry a settlement account (`0732`), measured in production |
| There is no screen for editing a tender type | `app/lib/src/features/pos/tenders_screen.dart`, on `upsert_pos_tender_type` |
| No `bank_transactions` row ever reaches `gl_lines` — **stated again further down this file, three rows below its own correction** | `post_bank_transaction` makes it a journal and puts `matter_id` on the non-bank leg; the "Post this line" dialog is the picker |

Each cost a round of reading to disprove, and one of them — the matter
picker — nearly cost building something twice. The 1120 fallback cost
more than a round: a decision was put to the user as though it were open,
and approval to close it was given for work `0731` had already done.
**A correction recorded in this table does not delete the claim it
corrects**, which is why the fourth row above was still being stated as
fact nine hundred lines further down. When you disprove something here,
go and mark the place it was said.

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

### FIRST: this table's CI and Head rows are from 2 OCTOBER and are STALE

Read this block, not them. The rows below are kept because their
*history* is worth having — which run applied which migration, which
flakes are known — but their "now" is three days old, and the file's own
warning at the top applies to itself.

**As of 5 October:**

| | |
| --- | --- |
| Head | `1a803c8c`, on `claude/iakauntan-accounting-crm-8snun0`, pushed, tree clean |
| CI | `4bb88662` green on all 12 checks. `78201350` and `5e1e667a` went RED on "Statutory engine and ledger rules" and `4bb88662` is the fix — a new gate that passed over nothing; see "the gate that passed over nothing" below. `f1e65ffe` lost "Build the Android app" to the known unauthenticated-JDK rate limit (`API rate limit exceeded for 20.189.188.0`, three attempts), VERIFIED from its annotations rather than assumed, and Android passed on every commit after it |
| Migrations | **nothing new since `0740`.** No commit from `01040a8a` to `1a803c8c` touches `supabase/migrations`, so none of the skipped or displaced migrate jobs in that range cost anything |
| Gates | **68** now drivable by `check_sweeps_look.py`, up one: `scripts/check_temp_cleanup.py`. It reports "49 of 68 ... report a problem over an empty source tree, as they must ... 0 still pass over nothing" |
| New CI numbers | `6649 Dart tests ran (floor 6649)`; `0 of 6351 test bodies check only that nothing threw (ceiling 0, 13 excused)`; `call server tests that ran: 33 (floor 33)`; `124 python files checked, every mkdtemp has a removal` |
| Disk | **18G free, 53% used**, after reclaiming 21G of `/tmp`. It had been at **57M free, 100%** — see "THE DISK FILLED" below, and the cause was this repository's own `check_web_boots.py` |
| NO CI WATCH IS ARMED | The `Claude_Code_Remote` MCP server timed out on connect, so no scheduled trigger could be created or re-armed. Check CI by hand: `gh api "repos/getgroupmy/iakauntan/commits/<sha>/check-runs?per_page=30"`, **per SHA** — the run LISTING served runs from 21 September twice on 4 October |

### The 2 October table, kept for its history

| | |
| --- | --- |
| Branch | `claude/iakauntan-accounting-crm-8snun0` |
| Head at time of writing | `1c0a1599` (Claude Code tooling — see `docs/claude-tooling.md`), over `4664ee09` (`scripts/check_write_doors.py`, which closed the both-door question) over `0740`, which shuts the direct door onto a solicitor's **client account ledger** — the shipped client was inserting trust rows itself, skipping `app.can_post` and the sign rule, and `authenticated` is now SELECT-only there. It also **withdraws a claim**: the overdraw risk I first attributed to that door does not exist, because `app.assert_client_funds` is a deferred constraint trigger on the table and holds whichever door a write comes through — found by mutating the new assertions. Before it `0739` (39 date defaults off the session clock), `5bfc3141` (the test suite onto the product's clock) and `0733`–`0738` (the write-idempotency census, 137 → 0) |
| CI | **green through run 2222 (`5c10c54e`, `0740`)**, which ran "Apply the migrations" rather than skipping — which is how `0740` reached production. Runs **2223** (`4664ee09`, the write-doors gate) and **2224** (`1c0a1599`, the Claude Code tooling) were still in flight when this was written; in 2223 every gate job was already green, including the new step "Check no table has a weaker second write door". 2221 (`5625c5c9`) green; 2219 (`5bfc3141`, the test-suite clock sweep) and 2220 both ran "Apply the migrations" rather than skipping. Earlier, green through run 2217 (`3890007e`, `0738`); 2204 to 2217 are all green except **2213**, which is worth remembering: `846bd339` changed one markdown file and turned the deploy branch red, because `idempotency.sql` carried a UTC-minus-KL date subtraction that goes wrong for eight hours a day and 16:10 UTC was inside them — a red run whose cause was in neither the commit nor any migration. 2215 applied `0737`, 2217 applied `0738`. Run **2213 FAILED** and is worth remembering: `846bd339` changed one markdown file and turned the branch red, because `idempotency.sql` carried a UTC-minus-KL date subtraction that goes wrong for eight hours a day and 16:10 UTC was inside them — a red run whose cause was in neither the commit nor any migration. 2204 to 2212 are all green — 2204 (`685a3156`), 2205, 2206 (**`0733` applied**), 2207, 2208, 2209, 2210 (**`0734` applied**), 2211 (**`0735` applied**) and 2212 (**`0736` applied**; its top-level status flipped `in_progress` back to `queued` at 15:44 while the three deploy jobs waited for runners, and `gh api .../jobs` is the cheap way to see that is not a failure). 2194 to 2204 are all green, and `0732` landed in run 2201 (`9e42ebf1`); and "Apply the migrations" RAN rather than skipping in 2194, 2197, 2199 and 2201. Run 2200 needed a SECOND ATTEMPT: `npx wrangler deploy` failed with "A fetch request failed, likely due to a connectivity issue" reaching Cloudflare on a docs-only commit, and `rerun_failed_jobs` was green — an infrastructure flake, worth one re-run and not two. **The run listings are worse than this file used to say, and on 2 October they were briefly useless:** no run for `fdb0301f` appeared in any status filter for fifty minutes; the completed listing's newest entry went BACKWARDS from 2198 to 2196 between two checks; and a listing filtered by `event: push` with no status returned run 2004 from 21 SEPTEMBER. Run 2199 had in fact finished at 13:00:52, one minute before the listing showed 2196 — so **an empty or stale listing is evidence about nothing, in either direction.** What works: `actions_get get_workflow_run` on a known id, `get_job_logs` with `failed_only: true, return_content: false` for a cheap failure count, `mcp__github__get_commit` to prove a push arrived, and `git rev-parse origin/<branch>`. Also: a run's top-level status can flip from `in_progress` BACK to `queued` while later jobs wait for runners, and its job count grows from 8 to 12 as they register, neither of which is a failure; and **a green run does NOT prove a migration landed**, because the apply and deploy jobs SKIP when a newer commit is already at the branch tip. Check the database. Earlier history: 2183–2185 were three red runs of mine in a row on `0727`, each a different fault; 2146 applied `0721`; 2097–2100 were `ghcr.io` refusing anonymous pulls, which is why the images come from `public.ecr.aws` |
| Migrations | **`0740` is the highest, and `0733` through `0740` are ALL live and VERIFIED in production** (`0740` confirmed after run 2222: migration recorded, `authenticated` holds only SELECT, one policy left (`client_account_transactions_select`), RLS on, all five writers still SECURITY DEFINER; and the same run's drift check said "No drift: 8806 statements, and the hosted project has every one of them") — it revokes insert, update and delete on `client_account_transactions` from `authenticated` and DROPS its three write policies — with RLS on and no policy, the command is denied whatever a future grant says, which `table_grants.sql` insisted on after refusing a first draft that merely tightened them. Nothing dropped, no data moved, SELECT untouched. The figures to check in production: `authenticated` holds **only SELECT** on that table, and all five writers (`receive_client_money`, `pay_from_client_account`, `settle_from_client_account`, `transfer_between_matters`, `post_client_transaction`) are still SECURITY DEFINER. `0729` through `0732` are all applied live and VERIFIED against production too — not inferred from a green run. For `0732`: `schema_migrations` has it; `upsert_pos_tender_type` and `delete_pos_tender_type` both exist with execute granted to `authenticated` and **not** to `anon`; `app.tender_type_settlement_account`'s live body skips the `on_account` and `loyalty` kinds; and all 13 `pos_tender_types` rows have an account with none on the heading. The bank accounts pointing at the 1120 heading are down from twelve to **one** — YUSOF ZAIN & CO's CIMB, the one real decision left. The query to repeat: `select 1 from supabase_migrations.schema_migrations where version like '0NNN%'`, then `pg_get_functiondef` on whatever it restated — with `ilike`, not `like`, and `grep -i`, not `grep` |
| Live database | **level with the branch.** Edge functions deployed on the same run |
| Mobile | **iOS build 5 in TestFlight; Android version code 14** from the `android-release` run that printed `Firebase project: iakauntan-2026`. Both from this repository's own workflows. The Android push client is built and **not yet proved on a handset** — that is the user's to do, below |
| Gates | **383 SQL assertion files (**207 assertion calls in `idempotency.sql` alone** — `grep -oE 'pg_temp\.(check_eq|check_true|refuses_a_repeat)\(' | wc -l`, which is 115 + 69 + 23, plus two explicit `raise exception 'FAIL`), 62 Python gates (+28 gate self-tests, one of which is 28 assertions of its own, one 22 and one 10), 6,634 Flutter tests** (one skipped, pre-existing), 40 deno test invocations. Both build backlogs are **ZERO**: every screen and every dialog opener is built by a test. **And all of it except the Android and iOS builds runs IN THIS CONTAINER** — see the section below, which corrects what this file and `CLAUDE.md` used to say |
| API description | 842 functions, 367 tables, version `0740`. Regenerated with `python3 scripts/generate_api_description.py "$DB"` against the local cluster and committed; CI's `--check` fails if it drifts. `0740` changed only grants and policies, so the diff is three lines |
| In-app calling | **ON**, 30 September. The mediasoup SFU and coturn run on a Synology DS224+ behind a public address; `CALL_SFU_URL` and the rest are set. Proved the only way that counts — two devices on different networks, one on mobile data. `docs/call-deployment.md` is the runbook and its last section lists the four failures that were actually hit |
| Rows put in production BY HAND | One set, 29 Sept 2026: the App Review demo company `iakauntan-demo` and the two accounts that ring each other — see `docs/apple-voip-review.md`. It is NOT in any migration and nothing in the schema records it, which is why it is named here. `0724` is the function that wires such a pair; the accounts themselves were made in the console, because an account cannot be created from SQL |

## Claude Code tooling, and the one thing a person has to run

`docs/claude-tooling.md` is the record: which plugins and skills this
project uses, which are deliberately NOT installed and why, and what
needs a key or a device. It is committed because
**`.claude/settings.json` is gitignored** (`.gitignore:58`, this
repository's own choice) — so the live configuration crosses neither
machines nor sessions, and a cloud container is reclaimed. Four
marketplaces are registered there: `anthropics/skills`,
`obra/superpowers`, `rebelytics/one-skill-to-rule-them-all`,
`mobile-next/mobile-mcp`.

**Nothing is ENABLED, and that is not an oversight.** Registering a
marketplace is inert. `claude plugin install` is refused inside a Claude
Code session as `[Self-Modification]`, and writing `enabledPlugins` or
`.mcp.json` by hand is the same outcome by another route, so it was not
done. The six install commands are in `docs/claude-tooling.md` for a
person to run. **Do not retry it from a session and do not route around
it.**

Three were declined on 4 October with the reasons recorded: **OmniRoute**
(an AI gateway that would route this repository's source through
third-party free-tier providers) and **Headroom** and **Caveman** (both
rewrite prompts before the model sees them). The compression objection is
specific, not reflexive — this is a codebase whose documented failures are
mostly things that LOOKED equivalent and were not, so lossy compression
of prompts carrying EPF, SOCSO, PCB and SSM numbers adds a failure no
gate here can see. The saving is real and the tradeoff is a judgement
call; it was made once, with reasons, so changing it is a decision rather
than a drift.

`.github/workflows/security-review.yml` runs
`anthropics/claude-code-security-review` on `pull_request` only, pinned
to commit `0c6a49f1`, and is **dormant and green** until an
`ANTHROPIC_API_KEY` repository secret exists. That secret is the user's
to set in GitHub and is **not to be chased**. Confirmed at push time that
it does not fire on a push: only `CI` ran for `1c0a1599`.

## What is waiting on the user, as of 2 October

Re-read and reworked on 2 October: item 3 was answered and built, and
item 8 is new — it is what three days of the 1120 audit leaves for a
person. Nothing on this list can be moved from inside a session. They
are here so the next one does not spend a round rediscovering them —
and does not chase them unprompted either.

The numbering is stable on purpose: a new item is APPENDED rather than
inserted, because item 1 is referred to by number further down this
page and renumbering would quietly break the reference.

1. **Prove Android push on a handset.** Install the `android-release`
   artifact (version code 14) → Settings → Notifications → **Turn on**.
   Then `device_tokens` should hold an `android`/`fcm` row for that
   account, and one message with the app CLOSED is what proves
   `FCM_SERVICE_ACCOUNT`. Until that happens the Android half is built
   and untested, and two of its behaviours are written from
   documentation rather than observation: `areNotificationsEnabled`
   after a refusal, and data-only call delivery to a swiped-away app.
2. **Correct EXP-2026-00001.** The Reverse action is live on the expense
   dialog (`78ae9817`). It needs one decision first: the expense records
   payment mode **01 Cash**, and the only bank account on file is MBB
   `1120-M001` with a balance of 0.00, so re-entering against MBB would
   assert the money left Maybank. A cash till can be registered as a
   `bank_accounts` row of type `cash` instead. Also whether to re-attach
   the receipt PDF: a reversal LEAVES THE ORIGINAL STANDING, attachment
   and all.
3. ~~Where card and e-wallet money lands~~ — **answered on 2 October
   and built as `0731` and `0732`**: they settle into the company's own
   bank account a few days later, or into another where one is defined,
   and cash stays in the drawer. `0732` is the editor, so both halves
   are now reachable: **Counters → Ways of paying**. Nothing is
   outstanding on this one. (The video-rotation
   measurement that used to sit beside this is no longer wanted: the
   cause was found by reading the mediasoup package rather than by
   measuring a call.)
4. **CP39, KWSP Form A and PERKESO Lampiran 1** need their published
   layout specifications. Not more code.
5. **What is missing from client trust monies in practice.**
   `ClientMoneyScreen`, `/legal/receipts`, `/legal/payouts` and
   `/legal/transfers` are all built; the question was asked rather than
   the thing rebuilt, and it is still unanswered.
6. **The seven-shot App Review recording** in
   `docs/apple-voip-review.md`.
7. **Whether a video call is still sideways.** Not a chase — a thing to
   report if it happens. The cause is fixed and there is now NO fallback
   rotation, so a platform that never advertises
   `urn:3gpp:video-orientation` would show that peer sideways with
   nothing correcting it. The engine logs exactly that case, with the
   extensions the camera did arrive with, so one line from a real call's
   console settles it.
8. **YUSOF ZAIN & CO's CIMB account points at the 1120 heading, and it
   is the last one that does.** The whole remainder of `0727`-`0732` in
   anybody's real books: eleven of the twelve were demo companies and
   have put themselves right on 1121 at a rebuild, and this one is a
   real firm's. Nothing is broken today — `0730` lets an existing row
   keep reconciling, and the firm's other account is `1150 Client
   Account`, so no two accounts resolve to the same place. What it
   needs is a decision:

   * **Repoint the bank account** onto a child account in 1121-1199,
     which is what `upsert_bank_account` would make. The balance and
     the movements then agree on an account a statement can be matched
     against. `0730`'s trigger refuses the move while it points AT the
     heading, so this is a migration rather than a screen.
   * **And whether to move the posted lines with it.** Nothing in
     `0727`-`0732` moves a posted line, deliberately. Leaving them puts
     the history on the heading and the future on the child; moving
     them restates figures in somebody's books, which is not a thing a
     session should do on its own initiative.

   Say which and it is a short change. The one real ledger line on the
   heading is a separate thing: `EXP-2026-00001` at GESWANT & CO, item
   2 above.

And four things that are **known-unverified and must be described that
way** rather than as working: the voice-note mime-type fix; whether the
`google-services` Gradle plugin actually applied — the build log does
not show it, and the release run printing `Firebase project:
iakauntan-2026` is suggestive rather than the same thing; and the two
Android push behaviours in item 1.

The incoming video's orientation has moved off that list. It is fixed at
the cause — the mediasoup package's serialiser was dropping every RTP
header extension — and what remains unproved is narrower and stated in
its own section: whether a given platform advertises the rotation
extension at all. The engine now says which case a real call is in.

**Do not start task #11, the MIA headless scraper.**

## Three gates, one file — and the denominator nobody checked

Found by asking whether the gate written the day before could see
everything it claimed to. It could not, and neither could the two beside
it.

`check_write_doors.py`, `check_write_idempotency.py` and
`check_idempotent_calls.py` each had their own copy of this line:

```python
CLIENT = REPO / "app" / "lib" / "src" / "data" / "repository.dart"
```

That file holds **576 of the 597** named RPC calls and **144 of the 169**
direct writes. So all three looked thorough, and all three reported clean
sweeps — `BACKLOG = 0`, "every one is reviewed", "36 protected calls name
every parameter" — over a denominator none of them had checked. **Eleven
Dart files touch the database; they were reading one.**

### What was outside

**16 writing functions were never in the census**, reached from
`ai_repository.dart`, `corp_repository.dart`,
`custom_fields_repository.dart` and `ocr_repository.dart`. Seven are
corporate secretarial. The population was 339, not 340, and is really
**355**.

Classified by the gate's own logic, thirteen needed no judgement — ten
insert nothing (`corp_mark_lodged`, `verify_person_identity`,
`record_scan_posting`, …), three guard or replace every row
(`set_ai_credentials`, `set_ai_settings`, `upsert_custom_field`). Three
were undecided, and all three are **SSM filings** — each ends by calling
`corp_open_filing`, so a repeat would file the same change twice:

| | refuses a repeat with |
| --- | --- |
| `adopt_constitution` | "alteration under s.36, not a fresh adoption" |
| `change_company_name` | "That is already its name" |
| `change_registered_office` | "That is already the registered office" |

**All three already refused**, by state, in words that cite why — one of
them citing the Companies Act. So nothing needed a migration and three
verdicts were owed. That is the eighth and ninth and tenth time in this
programme that a body looked like a defect the database was already
refusing, and it is the reason the rule is to read before writing SQL.

**14 more tables are written directly**, including every `corp_*`
statutory register and `attachments`. Four are written from a **SCREEN**
rather than any repository — `inbound_emails` (inbox), `organizations`
(settings), `firm_members` (practice), `profiles` (`core/providers.dart`).
Those four are why the scope is `app/lib` and not `app/lib/src/data`: a
directory is a convention, and a screen writing a table breaks no
convention loudly enough for a glob to notice.

**The write-doors conclusion survived.** At full scope the same six tables
have the gap and no others — so `0740` and the "client money was singular"
finding stand. Right answer, wrong denominator; it was correct by luck,
which is not a property worth keeping.

### `scripts/client_surfaces.py` — one definition, and a test of the SCOPE

The fix is not "read more files", because that is the fix that was
available before and got copied into three places badly. It is one module
all three import, globbing `app/lib`, plus
`client_surfaces_test.py` (15 assertions) whose most important ones are
about **scope**: more than one file, more than one directory, and
`repository.dart` is not the only surface. A narrowed scope does not look
like a failure from the outside — every gate downstream goes on passing
over whatever it can still see — so the scope is the thing that has to be
asserted. Eight mutants with a no-op control; all eight died, including
"scope narrowed to the data directory" and "scope narrowed back to one
file".

**A test written to confirm something true found it false.** `client_text`
joined the files with a newline and the docstring said that stopped a
pattern matching across two of them. It does not: `DIRECT`'s middle group
matches `\s`, so a file ending at `client.from('t')` splices onto a next
file starting at `.insert({...})` and the gate reports a write that is in
neither file. Files are now joined with `BOUNDARY = "\n;\n"`, since a
semicolon cannot be matched by that group. **No spurious write was ever
reported** — no file in this tree happens to end mid-expression, so the
fix is prophylactic, and the module was new, so nothing shipped with it.
Worth keeping anyway: the bug was in the sentence explaining why the bug
could not happen.

### Was it a class or three instances? Audited — three.

Fixing three gates one at a time is the shape of work that comes back, so
all 62 Python gates were checked for the same defect: a scope pinned
narrower than the claim. **Eleven module-level path constants across seven
gates.** Six are correct by construction and one was already right on the
side that mattered:

| | |
| --- | --- |
| `check_android_compile_sdk`, `check_web_plugin_registrant` | `app/.dart_tool/package_config.json`. There is exactly one. |
| `check_currency_decimals` | compares two KNOWN copies — the `const` map in `format.dart` against the `ref_currencies` seed. That IS the subject; there is no third copy to miss, and the docstring scopes the claim to the two. |
| `check_document_types` | `docTypes` in `doc_types.dart` is the one map the router builds every document address from. Declared nowhere else. |
| `check_push_channels` | `send-push/index.ts` is the only sender, and the only file in that function naming a `channel_id`. |
| `check_routes` | pins `router.dart` for the route TABLE — the only file containing `GoRoute(`, confirmed — and **already globs `lib/` for the call sites**. Its input side was never narrow. Four other files mention `GoRouter`, but as the type, not a declaration. |

So the three write gates were the whole of it. **The difference is what the
claim is about:** a gate whose subject is one named declaration site may
pin it; a gate whose subject is THE CLIENT may not, because that is eleven
files. That distinction is now mechanical —
`NoGatePinsTheClientToOneFile` in `client_surfaces_test.py` allows a pin
under `app/lib` only with a reason, fails on a new one, and fails on a
reason whose pin has gone.

Two things it took to make that honest, both found by running it:

  * the first `ALLOWED` list named `check_push_channels`,
    `check_android_compile_sdk` and `check_web_plugin_registrant` — none
    of which pins anything under `app/lib`. **The staleness assertion
    failed on its first run and said so.**
  * the rule must tell a FILE pin from a DIRECTORY root.
    `LIB = ROOT / 'app' / 'lib'` and
    `AUTH = ROOT / 'app' / 'lib' / 'src' / 'features' / 'auth'` are ten
    gates doing the right thing, and a loose pattern flagged all of them.
    It now looks at whether the LAST segment names a file, because that is
    the one that cannot grow.

And one weakness in the new test that a mutant found: it asserted
`"client_surfaces" in text`, which **passes on a gate that has stopped
importing it**, because all three mention the module in a comment
explaining this bug. A mutant swapping the import for
`import pathlib as client_surfaces_NOT` survived. It now asserts the
import line and an attribute use. Five mutants, no-op control, all five
dead.

### `check_idempotent_calls` had no self-test, and that was the gate whose scope moved

The debt the previous two commits created. That gate's scope widened off
`repository.dart` like the other two, and the per-file attribution the
change needed was verified **once, by hand** — a `callRpcOnce` planted in
`corp_repository.dart`, reported as `corp_repository.dart:450`. A
verification done by hand once is a verification nobody will do again, and
this was the only one of the three with no self-test to put it in.

`main()` is now split into `run(db)` the way `check_write_idempotency`
already was and for the same stated reason, so the test can swap
`wrappers` and `CLIENTS` and exercise the four real rules rather than a
copy of them. 16 assertions; nine mutants with a no-op control, all nine
dead — one per rule, plus the two the scope change touched:

  * **"only the first surface is read"** (`CLIENTS[:1]`) — the bug the
    previous commit fixed, now failing by name.
  * **"the file a fault is in is not carried"** — hardcoding
    `"repository.dart"` back into the report. Sending a reader to the
    wrong line of the wrong file is worse than giving no line at all, and
    with eleven surfaces it is the obvious way for this gate to mislead.

And a mistake in the test itself, worth keeping because it is a trap with
no warning signs: **`corp_repository.dart` CONTAINS the string
`repository.dart`.** An `assertNotIn("repository.dart:1: …")` meant to
prove the gate names the right file fails on the right answer and the
wrong one alike. It compares the start of each reported line instead.

### A gate that had never run anywhere

`scripts/check_web_boots.py` opens the built web bundle in a real browser
and asks whether Flutter drew anything. It exists for the outage in
`docs/passkeys.md`: a plugin registrant that throws inside
`registerPlugins()`, which runs BEFORE `runApp`, so one exception there
means `main()` never finishes and **every page is blank, the landing page
included.** That shipped. `flutter analyze` is clean, the build compiles,
and the failure is a missing JS global at runtime in a browser.

**It was referenced in no workflow, not in `run_locally.sh`, nowhere but
its own file and the doc calling it "the general answer".** Found by
listing the gates with no self-test and noticing one of them was not run
either. A gate that exists and never executes looks exactly like
coverage — the same defect class as the three scope-pinned gates above,
in its purest form.

It is now a step in the **Vercel deploy job**, right after the web build
and **before "Assemble the Vercel build output"**, so a bundle that does
not start is never shipped. That job is the only place the check costs a
browser rather than a build. `check_web_plugin_registrant.py` stays where
it is — it fires on the commit that adds the one plugin known to do this,
which is earlier and cheaper; this is the general case.

**Proved both ways before wiring, because a gate that cannot fail is
worse than no gate.** On the real bundle: "ok the web bundle starts and
Flutter draws". With `throw new Error(...)` injected ahead of `runApp`:
"The web bundle threw before it finished starting", naming the exception.
With the bootstrap emptied instead — nothing drawn, nothing thrown: "did
not draw anything (blank)", and it says explicitly that this is NOT the
registrant failure. Two different faults, two different diagnoses, and
the control passes again afterwards.

Two things that make the CI step safe, both measured rather than assumed:

  * **it needs no `FLUTTER_ROOT`.** The gate copies the SDK's CanvasKit
    beside the bundle when it can find it, and `--no-web-resources-cdn`
    in the build above already makes the bundle carry its own — which the
    next step asserts with `test -f .../canvaskit/canvaskit.wasm`. Run
    with `FLUTTER_ROOT=/nonexistent` it still passes.
  * **the browser is discovered, not assumed.** The path differs between
    runner images, so the step tries four and the gate exits 2 with its
    own message if none exists, rather than passing quietly.

### A self-test for the ratchet that reached the bottom

`check_undocumented_writes.py` holds `BUDGET = 0` after `0569`–`0599`
wrote two hundred odd `comment on function`. It had no self-test, and a
ratchet at zero has three ways to stop working, none of which looks like
a failure:

  * the budget gets **raised** to make a red build green — the one thing
    its own comment forbids;
  * it stops being able to **ask the database** and reports nothing found,
    which reads exactly like nothing to find;
  * the **query drifts** and looks at fewer functions than it claims.

So `main()` is split into `run(db)` over an `undocumented(db)` helper, and
`undocumented` returning None now returns **2, not 0** — a gate that
cannot reach the schema must not report a clean surface. 13 assertions;
ten mutants with a no-op control, all ten dead, including "the budget is
RAISED", "ground gained is not ratcheted down" and "a database it cannot
ask reports a clean surface".

**A mutant found the query assertions weak, in the same shape as
yesterday's `assertIn` lesson.** The test asserted that `pg_depend` and
`deptype = 'e'` appear in the query, to prove extension-owned functions
are excluded. A mutant that changed

    and not exists (select 1 from pg_depend dp ...)

to `and true or exists (...)` kept **every word the test looked for** and
survived. Naming the tables a clause mentions says nothing about what it
does with them, so the assertion is now on the NEGATION —
`not exists ( select 1 from pg_depend` — and on the absence of
`true or exists`. The query assertions also read only the non-comment
part of each line, because `QUERY` explains itself in `--` lines
containing the very words being matched.

### `check_currency_decimals`: two regexes, and an empty map agrees with everything

`Fmt.money` is pure and called from four hundred places, so it carries a
`const` map of the ISO 4217 exceptions instead of awaiting a lookup. The
gate compares that map against the `ref_currencies` seed in `0011`. A
mismatch is a figure written wrongly on an invoice that goes to somebody.

**Both halves are regexes over files this repository writes, and that is
the whole risk: a parse that stops matching returns an empty map, and an
empty map agrees with everything.** The gate already knew this on the
seed side — it aborts with "the column order probably changed, and this
check has been passing by reading an empty list" rather than compare
nothing. That guard had no test.

`dart_map()` and `seeded()` now take optional text, and the verdict is a
separate `compare(theirs, ours)`, so the test states a disagreement
directly instead of building two files to imply one. 14 assertions; ten
mutants with a no-op control, all ten dead — including "the seed's
empty-parse guard is removed", "a missing dart map is not fatal", and two
that quietly narrow a regex (`[A-Z]{3}` → `[A-Z]{4}`, and a decimals
column that only ever matches `2`).

One assertion states the limit out loud rather than hiding it:
`compare({}, {})` returns 0, because the comparison **cannot** tell
agreement from a parse that found nothing. That is not a defect in
`compare` — it is why the parsers abort and why there is a floor on the
real files (`len(seeded()) > 10`, every real Dart entry a real exception).
Every other assertion in the file is about fixtures and would pass on a
day both parsers had stopped working.

### Where the stale `iakauntan` database came from

It cost this session an hour of wrong conclusions: `0740` looked
unapplied because the database being queried was hundreds of migrations
behind. The cause was `scripts/localdb/`, three files referenced by
**nothing in this repository**:

  * `rebuild.sh` — a second way to build a local Postgres from the
    migrations "for machines without Docker", which is now exactly what
    `supabase/tests/run_locally.sh` does and what `CLAUDE.md` documents as
    the local path. It used the **same `PGDATA` (`/var/tmp/pgdata`)** as
    `run_locally.sh` but a different socket directory and port
    (`/var/tmp/pgd`, 55432 against `/var/tmp`, 5599), and it applied the
    migrations to a database called **`iakauntan`**, which it dropped and
    recreated. That orphan is the one that misled this session.
  * `suite.sh` — ran CI's SQL list, selected with a `sed` range over
    `ci.yml`. **If that range stops matching, `FILES` is empty, the loop
    runs zero times, and it prints `assertions=0 files_failing=0` — which
    reads as success.** The same defect this session spent the day
    closing, sitting in an unreferenced script. `run_locally.sh`'s
    `ci_tests()` reads that list too and refuses to start when the count
    it matched disagrees with the count the workflow names.
  * `supabase-shim.sql` — what `supabase start` would have created, for
    the same purpose. `run_locally.sh` has `_local_stack.sql`, which
    carries the three hosted observations and says where the stubs stop
    being the real thing.

All three removed. Nothing EXECUTED them, every capability they had lives
in `run_locally.sh` and is better guarded there, and a second local path
sharing a `PGDATA` with the documented one is a trap with a proven cost.
Recoverable from git if ever wanted.

**Two migrations still point at the removed directory, and they stay
that way.** `0315_the_saver_could_not_save.sql` and
`0322_the_front_page_updates_itself.sql` each explain, in a comment, what
"the no-Docker harness in `scripts/localdb/`" could not do —
`pg_safeupdate` is not installable there, and it has no Realtime at all.
Migrations are **append-only and never edited once applied**, so those
comments cannot be corrected and were not. Read them as describing
`supabase/tests/run_locally.sh`, which is the no-Docker harness now and
stands in the same relation to CI: the same two limits apply, and
`_local_stack.sql` says where its stubs stop being the real thing. The
reasoning in those two migrations is unaffected — only the path is.

### The rest of that audit, which found nothing

Having fixed three scope-pinned gates and one gate that never ran, the
class was swept for other shapes of "claims more than it checks". **It
came back clean**, recorded here so nobody sweeps it twice:

| | |
| --- | --- |
| scripts referenced nowhere | 3, all in `scripts/localdb/` — none of them a gate. An unreferenced helper is untidy; an unreferenced GATE is a lie, and `check_web_boots` was the only one. |
| gate invocations whose exit code is swallowed | **none** — no `|| true`, no `|| :`, no pipe into `tee`/`head`/`grep` on a `scripts/` call |
| `continue-on-error` in `ci.yml` | 4, every one deliberate and explained. The one on "Dump both schemas" states the principle this session kept rediscovering: *"could not look is not the same as looked and found nothing — a check that reports the first as the second is worse than no check, because it is reassuring while blind."* |
| budgets above zero | 2 — `check_blind_catches` at 41, `check_async_value` at 39. **Both ratchet DOWNWARD as well** (`if n < BUDGET:` → "Lower BUDGET"), and both sit exactly at their count, so neither has quietly given ground back. |

### Card and e-wallet land in the till — measured, 4 October

Evidence for the open item "where card and e-wallet money lands", which
the user has again chosen to leave open. Read-only against production:

| | |
| --- | --- |
| `pos_tender_types` | 13 rows: 5 `cash`, 4 `card`, 4 `ewallet` — **all 13 carry a settlement account, none null** |
| what they point at | GL `1110` (and `1121` for some orgs), every one a bank account of `account_type = 'cash'` — **a till, for card and e-wallet alike** |
| `org_payment_gateways` | **zero rows** |
| `on_account` / `loyalty` tender types | **none exist**, so `app.tender_type_settlement_account`'s exclusion for them has never fired in production |

The last two together are the finding. The trigger tries a gateway's
`settlement_bank_account_id` first for anything that is not a drawer
tender — and with no gateway rows at all that branch **can never fire**,
so card and e-wallet always fall through to "the company's own account",
which for these shops is the cash drawer. Nothing is lost and nothing
reaches the 1120 heading; the money is simply in the wrong kind of
account, and no reconciliation against a card settlement will ever match.

`0728` said the right answer "cannot be guessed from here" because
merchant settlement is net of a fee and days later. That is still true.
What is new is that the wrong answer is now specific and measurable
rather than hypothetical.

### A fifth variant of the same mistake, and this one cost something

Four times today a mutant caught an assertion that matched text without
checking meaning. The fifth time there was no mutant, because it was not
a test — it was me asking production a question:

    pg_get_functiondef(p.oid) like '%1120%'   -- "is the fallback still there?"

It answered `yes`. **Every `1120` in that function is in a COMMENT** —
including `0731`'s own "the difference between this and the fallback it
replaces: 1120 was chosen at posting time". The string survived precisely
because the fix documented itself.

On that basis a decision was put to the user as though `0728`'s fallback
were still open, and approval to close it was given for work `0731` had
already done. No migration was written; the body was read first and it
refuses already. **Read the body, not a `like` over it** — and when a
grep agrees with a claim that something is still broken, that is the
moment to check whether the match is code or prose.

## `0740`: client money has one door — and the claim I had to withdraw

**The other door into the database.** The write-idempotency census covered
340 writes reachable by RPC; it said in writing that writes reached
"through `client.from(...)` rather than an RPC" were never in it. There
are **172 of those, over 83 tables**  — read from `repository.dart` only,
and the whole-client figure is **169 over 96 tables**; see "Three gates,
one file" — and 37 of the tables are also
written by a real (non-demo) `SECURITY DEFINER` function — so for those
37 the client has a sanctioned path and goes round it.

The worst was `client_account_transactions`, a solicitor's **client
account** ledger. `authenticated` held INSERT, UPDATE and DELETE, the
insert policy asked only for `app.can_write`, and
`Repo.recordClientTransaction` used that door: it inserted the trust row
itself — matter, type, signed amount, `transaction_no` minted in a
separate round trip — and then called `post_client_transaction`. A
hand-rolled copy of `receive_client_money` and `pay_from_client_account`
with their guards left out.

### The claim I withdrew, and how

The first draft of this section, the migration header and the Dart comment
all said the direct insert risked **overdrawing a client** — spending one
client's money on another, which the Legal Profession (Accounts) Rules
prohibit outright. That was the headline, and **it was wrong.**

It was caught by mutating the new assertions: re-grant the door, re-run
the file, watch them fail. They did not fail. The direct insert of
−999,999 was refused by **`app.assert_client_funds`, a DEFERRABLE
INITIALLY DEFERRED CONSTRAINT TRIGGER on the table**, with the sentence
*"Client money held for one matter cannot fund another."*

**The cardinal rule is enforced on the TABLE, at commit, whichever door a
write comes through.** Somebody built that properly and it held. The
mutation was run to prove my assertions bite; what it actually proved was
that my reasoning about the defect was overstated. That is the whole
argument for mutating in one paragraph — and it is why the claim is
corrected in all three places rather than quietly softened in one.

### What the open door really cost

| | |
| --- | --- |
| **`app.can_post`** | Both functions demand it — *"Insufficient privileges to move client money."* The insert policy asked only `app.can_write`. A member who may write but not post could record a movement, and `post_client_transaction` would then refuse it — **leaving an unposted trust row**: money shown against a client and absent from the accounts. Found at an audit, not at a desk |
| **sign and type** | Both functions refuse a non-positive amount and derive the sign from the type. The direct insert passed a *signed* amount through, so a `receipt` could carry a negative one. `assert_client_funds` checks the matter's TOTAL, not whether a row's sign agrees with its type |
| **`transaction_no`** | Minted client-side in one round trip and inserted in another: a gap on a retry, a duplicate on a race |

A privilege gap and a sign gap, not a hole in the trust arithmetic.
Narrower than it first looked and still worth closing.

`0549` had been here one door down: it took the transfer option off that
same dropdown because it wrote ONE leg, so the client ledger fell and the
office account was never debited.

### What changed

`recordClientTransaction` now calls `receive_client_money` for a receipt
and `pay_from_client_account` for a payment or refund — the three types
the dialog offers map exactly onto the two functions, so nothing is lost.
It throws rather than falling back for the other three enum values
(`transfer_in`, `transfer_out`, `transfer_to_office`), because those move
two legs and belong to `transfer_between_matters` or the receive-payment
flow; writing one leg from here is what `0549` had to undo.

`0740` revokes INSERT, UPDATE and DELETE from `authenticated`, leaving
SELECT — both screens read the table. The five writers are SECURITY
DEFINER, so they are unaffected and are now the only door.

### And a second correction, from the suite this time

The first draft KEPT the three write policies and tightened them to
`app.can_post`, on the reasoning that if a later migration ever restored
the grant the rule under it should already be right. `table_grants.sql`
refused it:

    FAIL a policy without the privilege to reach it:
      client_account_transactions (DELETE), (INSERT), (UPDATE)

That is `0661` and `0662`'s lesson — a policy nobody can reach is
decoration — and the assertion exists for the opposite mistake. It is
right here too, and the draft's reasoning was simply wrong: **row level
security with no policy at all is how this schema says no access**, which
`table_grants.sql` states three lines below the assertion that caught me.
With RLS on and no permissive policy for a command, Postgres denies it for
every non-owner role, grant or no grant.

So the three policies are DROPPED. That is not the weaker choice — it is
the one that still holds if somebody restores the grant. Two defences
rather than one defence and an ornament.

**Two corrections in one migration, both from measurement rather than
review**: the overdraw claim withdrawn by mutating the new assertions, and
the policy design overturned by an assertion written years earlier for a
different reason. Neither would have been caught by reading the diff.

Nine assertions, **run as `authenticated` rather than as the superuser the
rest of `client_account.sql` runs as** — under a superuser a revoked grant
is invisible and every one would pass for the wrong reason.

### The 36 that were left, now read

The other both-door tables are mostly plain reference data where RLS is
the right guard — `branches`, `warehouses`, `item_categories`, `todos`.
The ones worth looking at next, with the function they go round:

| | |
| --- | --- |
| `expenses`, `expense_claims` | `post_expense`, `post_expense_claim` |
| `stock_adjustments` | `post_stock_adjustment` |
| `fs_filings` | `fs_freeze`, `fs_lodge` |
| `tax_estimates`, `tax_computations` | `revise_tax_estimate`, `open_tax_computation` |
| `exchange_rates` | `ingest_exchange_rates` |
| `recurring_journals` | `run_recurring_journals_for` |
| `org_members`, `organizations` | `invite_member`, `hand_company_over`, and the platform functions |

**This is a measured list and not a verdict.** A direct write is not a
defect by itself: it is one where the function enforces something the
policies do not, which is a question per table and was answered here by
reading both and then mutating.

### The 36 have now been read, and the client-money case was singular

Reading 36 tables by hand is how a list like that gets abandoned, so the
question was made mechanical first: **for each both-door table, compare
what its write POLICIES ask for against what the FUNCTIONS that write it
demand.** Where the function asks for more, the direct door is the weaker
one and the function's guard is optional. That is exactly the client
money shape, and it is a catalogue query, not a reading exercise.

It fires on six tables. **None of the other five is a defect**, and that
is the finding, not a disappointment:

| table | policies ask | a writer demands | why it is not `0740` |
| --- | --- | --- | --- |
| `expenses` | `can_write_module` | `can_post` | the insert sets `status: 'draft'` and the very next line calls `post_expense`. Drafting is not posting. |
| `stock_adjustments` | `can_write` | `can_post` | same shape, `post_stock_adjustment` |
| `time_entries` | `can_write` | `can_post` | recording one's own hours is a `can_write` act; both `can_post` writers act on hours already recorded — `app.bill_time_internal` marks them billed, `close_project` marks the unbilled ones unbillable |
| `property_statutory_charges` | `can_write_module` | `can_post` | a charge DEFINITION, not a billing; `bill_statutory_charge` is the posting |
| `accounts` | `can_post` | `can_admin` | the one `can_admin` writer is `setup_legal_module`, inserting three `is_system` accounts while ENABLING a module — a different act, not a stronger guard on the same one |
| `tax_codes` | `can_post` | `can_admin` | `set_sst_registration`: registering a company for SST is an admin act |

So `client_account_transactions` was the only one where the weaker door
let a member skip a rule that mattered. Two things made it different:
the function's extra demand was about the SAME act (recording a movement
of client money), and the refusal downstream left a half-finished row
rather than nothing.

### `scripts/check_write_doors.py` — a gate that fails both ways

That reasoning is worth more than the one fix, so it is encoded rather
than written down. `REVIEWED` is a dict of table → **reason**, not a list
of names, because a hit here means "read both sides and say which shape
this is". The gate fails:

- on a table with the gap and **no** entry — nobody can add a weaker
  second door silently, which is what happened to client money;
- on an entry whose gap has **closed** — an excuse nobody prunes is not
  evidence. `0740`'s own fix makes a `client_account_transactions` entry
  illegal, and that is asserted.

It runs in CI beside the other idempotency gates, with
`check_write_doors_test.py` (22 assertions) in front of it. Ten mutants
were run against the gate with a no-op control; all ten killed the
suite. **Two of them did not, at first**, and both are worth keeping:

- the pattern allows whitespace between `.from('t')` and the verb
  because **75 of the 171 direct writes break the chain across lines**.
  Collapsing that group loses 44% of them — and a gate that sees fewer
  doors reports a cleaner repository. Nothing covered it until a mutant
  survived.
- the harness itself lied once. Two mutants of the same file SIZE,
  written within the same mtime second, **shared one `__pycache__`
  entry**, so the second ran the first's code and was reported as
  surviving. Mutate Python with `-B` and `PYTHONDONTWRITEBYTECODE=1`, and
  delete `scripts/__pycache__` between runs. This is the twelfth trap in
  `docs/widget-tests.md` wearing a different hat: a harness that cannot
  tell two things apart reports on only one of them.

**A trap worth the thirty seconds it costs:** `run_locally.sh` builds its
cluster at `/var/tmp/pgdata` and migrates **the default `postgres`
database** — `$PSQL` names no database. There is also a stale `iakauntan`
database in that cluster from an earlier era, hundreds of migrations
behind. Querying it to check whether a migration landed says the
migration did not land. The connection string for a gate here is
`postgresql://postgres@/postgres?host=/var/tmp&port=5599`.
**Its cause is now removed** — see "Where the stale `iakauntan` database
came from" — so a cluster rebuilt after 4 October has no such database.

## `0739`: thirty-nine defaults on the wrong clock, and a premise that was wrong

Thirty-nine functions defaulted a date argument to `current_date` — the
SESSION's date, which is UTC here and on Supabase. `app.today()` is Kuala
Lumpur. **From 16:00 UTC the two are different days, every day, for eight
hours**, which in Malaysia is midnight to eight in the morning.

So for eight hours out of twenty-four: every trial balance, balance sheet
and P&L run with the default window ended yesterday and omitted the day's
postings; AR/AP aging and `strata_arrears` were a day young, moving a
bucket boundary; `create_bank_transfer`, `transfer_between_matters`,
`remit_withholding` and `fs_lodge` stamped the money yesterday;
`exchange_rate_for` returned yesterday's rate for today's document; and
`app.run_daily_jobs` and the four it calls processed the wrong day.

### This had been audited and deliberately left alone

`utc_is_not_today.sql` carried all thirty-nine as a pinned list, with a
reason — and the reason is the interesting part:

> The rest are a TRAP AND NOT A BUG […] every Dart caller of the others
> passes a date of its own — so not one of those defaults is currently
> taken. Rewriting forty function bodies into an append-only migration to
> change a default nobody reaches would be a large irreversible artifact
> bought with nothing.

That is sound reasoning and the first sentence was right. **The second was
wrong.** `repository.dart` sends several of these dates with a
*conditional spread* — `if (asAt != null) 'p_as_at': Fmt.iso(asAt)` —
which omits the parameter whenever the caller has no date, and the server
default then decides. Six were reachable from the shipped client:

| | |
| --- | --- |
| `report_ar_aging`, `report_ap_aging` | **the doc comment three lines above the call says it outright: *"Passing no date asks about today, which is what the dashboard wants."*** So the dashboard asked for today and got yesterday |
| `report_asset_movements`, `report_stock_card` | `p_to` omitted |
| `run_recurring_documents_for`, `run_recurring_journals_for` | `p_on` omitted — **and these two WRITE.** A recurring invoice or journal run for the wrong day |

I nearly shipped the migration without reading that list, which would have
been overriding a reasoned decision without checking it. The check is what
turned it from an override into a correction.

### How it was found: not by reading

The test suite moved onto the product's clock in `5bfc3141`, and the swept
suite was then run with **`PGTZ='Etc/GMT+12'`** — a session a day behind
Kuala Lumpur *all* day, which is exactly what CI and this hosted database
see from 16:00 UTC. Two files failed that nothing in the tests explained:

    FAIL the combined trial balance balances: expected 0, got <NULL>
    FAIL there are eliminations to make at all

`report_group_trial_balance` came back EMPTY: the test posted on the
Malaysian day and asked for the default window, which ended the day
before, so every entry fell outside it.

**The tests had been wrong about the clock for as long as the product was,
so they agreed with each other and neither was tested.** Putting the suite
on the product's clock is what made the product's clock visible — which is
the whole argument for `5bfc3141` in one sentence.

### The suite is now green BOTH ways

383 files in UTC, and 383 files under `PGTZ='Etc/GMT+12'`. Before `0739`
it was green for sixteen hours a day. The technique is written into
`run_locally.sh`'s header, because a green suite that touches a date means
less than it looks until it has been run that way.

### The list became a ratchet at zero

`utc_is_not_today.sql` no longer holds thirty-nine names. It asserts that
**no** function in `public` or `app` defaults a date to `CURRENT_DATE`, so
there is no list to keep in step and nothing to excuse, and the next one
fails by name. Same shape as `check_write_idempotency.py` at `BACKLOG = 0`
and both of `check_test_clock.py`'s pins — and reached for the same
reason: a list of known-bad things needs somebody to prune it, and a zero
does not.

Three functions keep a `current_date` in a COMMENT explaining why they
already use `app.today()` — `draft_bill_from_received_einvoice`,
`module_dashboard`, `report_with_layout`. Untouched. Their comments are
why this class was already known to be real.

### What is not claimed

The bodies are restated verbatim from `pg_get_functiondef` with only the
default changed, and not one of the thirty-nine used `current_date`
anywhere else — checked, not assumed. Nothing about `anon`: none of the
thirty-nine is callable by it, which matters because an argument default
is evaluated in the CALLER's context and `app.today()` needs EXECUTE,
which `authenticated` has and `anon` does not.

## `0738`: the last eight, and the key that was already there

26 → **ZERO.** Eight wrappers and eighteen verdicts, all twenty-six
measured. **Every one of the 340 client-reachable writes in this schema is
now accounted for**, and `check_write_idempotency.py` has `BACKLOG = 0`,
so the next unprotected write fails CI by name.

> **CORRECTED on 4 October: that denominator was wrong.** The census read
> `repository.dart` alone, so "340" was really 339 over a population of
> **355**. Sixteen writing functions were reached only from four other
> repositories, seven of them corporate secretarial. Thirteen needed no
> judgement and three wanted verdicts. `BACKLOG = 0` now holds over the
> whole client — see "Three gates, one file" below. The ratchet was sound;
> what it was counting was not.

    create_recurring_document  -> 2 live monthly schedules
    run_item_conversion        -> the stock converted twice
    create_payroll_run         -> 2 runs, 2 run numbers
    upsert_bank_account        -> 2 accounts, 2 ledger accounts
    join_pos_queue             -> 2 ticket numbers for one party
    upsert_pos_menu_link       -> 2 live links, 2 tokens
    chat_create_group          -> 2 groups
    upsert_landed_cost_run     -> 2 runs

**`create_recurring_document` is the worst of the thirty-two wrapped
across the eight tranches**, worse than `0737`'s `settle_deposit`. Every
other duplicate in this programme is one wrong thing. A duplicated
schedule is a **machine that goes on producing wrong invoices on a
timer** — the customer is billed twice a month for ever — and the second
schedule looks exactly as legitimate as the first.

**`run_item_conversion` is the first to double a physical quantity.** One
box became twenty bottles instead of ten: two sets of output movements
from one press, so the shelf and the ledger both disagree with the room.

### The key that was already there

`open_pos_sale` doubled too, and it is **not wrapped**. It has had a
complete retry mechanism since it was written — `app.open_pos_sale_internal`
opens with

    if p_client_uuid is not null then
      select s.id into v_sale from public.pos_sales s
       where s.org_id = v_org and s.client_uuid = p_client_uuid;
      if v_sale is not null then return v_sale; end if;

— and the one caller, `till_screen.dart`'s `sale ??= await
repo.openPosSale(reg)`, passed nothing. **The mechanism had never been
given anything to work with**, which is `0307`'s fault exactly: four
wrappers that shipped complete and went unused until a gate found them.

So the fix is in the client. `openPosSale` now mints a per-attempt uuid
from the same `IdempotentAttempt` machinery `callRpcOnce` uses (32 hex
characters, which Postgres accepts as a uuid unhyphenated), and a caller
with its own uuid — the offline till replaying what it took while the line
was down — keeps using it. A second idempotency layer over a working one
would have been a worse answer.

`check_idempotent_calls.py` grew a fourth rule, `BY_OTHER_NAME`, for a
function whose idempotency key is not called `p_idempotency_key`. Proved
by mutation: dropping `p_client_uuid` from the call site fails with
*"does not send p_client_uuid, which IS this function's idempotency
key"*. The first mutation attempt was caught by the WRONG rule — a
non-literal params map made the call site invisible to the parser, so the
staleness check fired instead — and that is not proof, so it was redone
with a literal map.

### Eighteen verdicts, every one measured

Six refused by a unique index: `open_matter`, `upsert_item_conversion`,
`start_membership` and `cover_line_with_membership`. **The last two were
read as doubling and are not** — a session is unique on the line it
covers, a live subscription unique per member. That is the sixth and
seventh time in this programme that reading a body found a defect the
database was already refusing, against one time that reading found a real
one. The rule has not changed: make the duplicate happen.

Five hand back what is there (`existing:`) — `chat_start_direct`,
`ensure_default_warehouse`, `create_item_variants` (find-or-create per
variant code, reporting `created = false`),
`create_supplier_from_received_einvoice`, and `ingest_offline_sales`,
which dedupes on the till's own `client_uuid` because an offline sync that
did not would be useless.

Three state guards: `void_pos_sale`, `open_appraisal_cycle` (`not exists`
per employee) and `run_recurring_journals_for` (it advances
`next_run_date`).

Two natural: `calculate_payroll_run` deletes and rebuilds the payslips, so
recalculating *is* the button; `void_pos_sale_line` deletes the line it
voids.

**`create_po_from_suggestions` is the one worth remembering.**
`app.forecast_wanted` subtracts `app.quantity_on_draft_order(...)` from
what the forecast asks for, so the first call's draft order makes the
second call want nothing. Measured: one order, then still one. It is the
only one of the 340 that defends itself by **netting off its own output**,
and it is a deliberate mechanism rather than an accident.

Two repeat on purpose. `next_document_number` hands out the next number,
and asking twice is asking twice — a key would hide a gap that opening a
form and closing it makes anyway. `run_inventory_forecast` re-run is a new
forecast, which is the button's whole purpose.

### Three fixtures that proved nothing, and what they cost

- **`join_pos_queue`'s quote.** The assertion was
  `v_again.quoted_minutes = v_first.quoted_minutes` while both were null,
  because `app.pos_queue_quote` returns NULL until three parties have been
  seated — and `null = null` is null, not true, so it failed outright. The
  fix is NOT a null-safe comparison: it is a fixture that seats three
  parties so the quote is a real 20 minutes, and a wrapper that drops the
  column now comes back null and is caught. Both of those mutants are in
  the run.
- **`upsert_item_conversion` in one exception block.** Both calls were
  inside one `begin … exception`, so the second call's failure rolled back
  the FIRST call's insert as well — plpgsql puts a savepoint at the block,
  not at the statement. The row that was supposed to exist did not, and
  the next assertion was silently skipped.
- **`create_recurring_document` and `upsert_bank_account` branches.** Two
  mutants survived the first round: "only looks at sales documents" and
  "claims the key against the argument on an amend". Both blocks tested
  only one branch — an invoice, and a create. A recurring BILL and an
  amend with `p_org_id` null were added, and both mutants die.

Sixteen mutants, all killed, control surviving.

### The census, finished

| | |
| --- | --- |
| client-reachable writes | **340** |
| hold an idempotency key | **36** |
| insert nothing at all | **146** |
| guard or replace every row they insert | **34** |
| refuse a repeat BY NAME | **37** |
| carry a checked verdict | **87** |
| **undecided** | **0** |

137 → 85 → 56 → 48 → 38 → 26 → **0** across seven tranches of 3 October,
`0733` through `0738`. Thirty-two overloads, eighty-seven verdicts, and a
ratchet at zero.

**What `BACKLOG = 0` does and does not mean.** It means no
client-reachable write is unexamined, and that a new one must arrive with
a key, a guard or a written verdict or CI refuses it. It does not mean
every retry in this application is safe: a write reached by an edge
function rather than by `repository.dart` is outside this census
altogether, and so is anything a future screen calls through
`client.from(...)` instead of an RPC. Those are different populations and
would need their own count.

## `383e505d`: a green suite proved nothing about the eight hours it never ran in

    FAIL a null share window takes the function's 30 days:
         expected 30, got 29

Found by rerunning the suite at 16:31 UTC — **00:31 the next day in Kuala
Lumpur**. The `0735` assertion was

    expires_at::date - pg_temp.today()

a date in UTC minus a date in KL. `expires_at` comes from `now()` inside
`app.issue_share_token` and casts in the session's time zone;
`pg_temp.today()` is deliberately KL, because `idempotency.sql` is held to
the product's clock. For sixteen hours a day the two name the same day and
the subtraction is right. For the other eight, KL has rolled over and UTC
has not, and every window reads one day short.

**Every run of the `0735` and `0736` tranches was inside the sixteen.** It
was going to go red tonight, on a branch that is the deploy target, and
the cause would have looked like a migration.

**It did not have to wait for tonight, and CI proved the point by
itself.** The docs-only commit `846bd339` was pushed at 15:52 and its run
**2213 failed at 16:10 UTC** on this line and nothing else:

    psql:supabase/tests/idempotency.sql:507: ERROR:
      FAIL a null share window takes the function's 30 days:
      expected 30, got 29

A commit that changed one markdown file turned the branch red. Run **2214**
(`383e505d`, the fix) is green. So the sequence is on the record: the
local suite found it at 16:31 against a rebuilt cluster, CI found the same
line at 16:10 on a commit that touched no SQL, and the only reason both
happened on the same afternoon is that the clock crossed midnight in Kuala
Lumpur while the work was still going on.

The fix measures the window against the LINK'S OWN `created_at`. Both
columns are `now()` in the same transaction and cast with the same time
zone, so their difference is exactly the window at any hour, and there is
no clock in the assertion at all. Verified both ways at the hour it broke:

| | |
| --- | --- |
| `expires_at::date - created_at::date`, 30-day window | **30** |
| the same, with the null `app.issue_share_token` falls back to | **45** |
| the old form, right now | **29** |

So it still separates the two values it exists to separate, which is the
mutant it was written to kill: a wrapper that passes the null share window
straight through gets 45.

`check_test_clock.py` does **not** catch this. It fails a file that names
both `current_date` and a KL date, and this file names only the KL one —
**the second clock was inside the function under test.** That is the gap,
and it is written down here rather than closed, because a gate that
followed every call into its callees to find a `now()` would be a type
checker.

## `0737`: four statutory papers, and a refund paid twice

38 → **26**. Four wrappers and eight verdicts, all twelve measured. This
is the tranche where the duplicate is **a document somebody else holds**,
and the first where it is money leaving a bank account.

    settle_deposit       -> a 1,000 deposit at 400 on two 300 refunds
    create_withholding   -> 2 certificates, 2 numbers, 2 LHDN deadlines
    revise_tax_estimate  -> 2 live CP204 revisions of one estimate
    submit_leave_request -> 2 requests AND 4 pending days for a 2-day trip

**`settle_deposit` is the worst of the twenty-two wrapped so far.** It
has a balance guard — *"Deposit % has % left and this would take %"* —
and that guard only catches the FULL settlement. A **partial** refund
retried is inside the balance both times, so 600 left the bank for a 300
refund and the note shows two events. Reading the body found a guard;
calling it twice found the hole in the guard.

`revise_tax_estimate` and `create_withholding` are the first statutory
filings in this programme. Two CP204 revisions of the same estimate are
both *current* — only the original gets superseded, because the second
call supersedes the same row the first one did — each with its own
revision month and its own recomputed instalment schedule. Which one the
Revenue is holding is not a question this database can answer.

`submit_leave_request` doubles twice over, and the second half is the one
nobody would see: `leave_balances.pending_days` went to **4** for a
two-day request. Deleting the duplicate request does not put the two days
back.

### The eight verdicts

Five refuse by name; three do nothing quietly, and a silent repeat can
only be caught by counting:

- `clear_pdc` — "That cheque is cleared."
- `bounce_pdc` — "That cheque is bounced."
- `receive_stock_transfer` — "That transfer is received…"
- `bill_matter_time`, `bill_project_time` — "No unbilled chargeable time
  on this engagement between % and %", and the check runs BEFORE the
  invoice is inserted, so the second call writes nothing at all.
- `transition_ticket` — two calls to the same status left ONE
  `ticket_events` row. `if v_t.status = p_to then return` is the first
  line of the internal.
- `recognise_revenue` — first sweep released one period, second released
  none; it walks `gl_entry_id is null` and fills that column in.
- `run_depreciation` — first call returned a run id, second returned
  **null**, one run row survived. The charge is the gap between where the
  asset should be and where it is, which is zero on a retry; the function
  then deletes the empty run it opened. The null return is a wart — a
  client that retries is told nothing happened — but nothing doubles.

### The fixture that proved nothing, and said so

`submit_leave_request`'s first probe was green: the second call was
refused for want of days. That is not a state guard — there was simply no
entitlement, so the balance was zero and the first request took it
negative. **With an entitlement the function doubles.** The assertion
block now inserts one on purpose and says why in a comment, because the
green run was the misleading one.

### A survivor that is the same lesson in new clothes

"`submit_leave_request` fingerprints without the number of days" survived
the first mutation round. The assertion meant to catch it varied the end
date as well, so `end_date` in the fingerprint killed the mutant on its
own and `total_days` was never tested. Added: the same two days with
**1.5** claimed against them — a correction somebody really does make.

That is the second tranche running where a payload differing in two
fields could not say which field the key covered. `0736`'s was two
identical payloads; this one is two payloads differing twice. The rule
worth keeping: **vary exactly one field per fingerprint assertion.**

Seven mutants, all killed, control surviving.

### The third by-name assertion, and a gate so there is no fourth

`leave_requests.sql` asserted

    there is one submit_leave_request, not two

and `0395` wrote that on purpose: two forms of this name, and a call
giving only the six required arguments matches both, which is **42725 at
run time and in no test**. It is a real guard, and the overload broke it.

That is the THIRD assertion in this suite broken by a keyed overload, one
tranche at a time, each found by a red suite rather than before a push —
after `outbound_email.sql` and `ai_assistant.sql` in `0735`. The `0735`
section of this file predicted a third would be found the same way. It
was.

The rewrite asserts what `0395` was actually protecting, which is not the
count: **no call can be ambiguous, because the keyed overload has no
defaults at all.** `pronargdefaults = 0` is stronger than the count was —
a third form added later with a default fails even if somebody remembers
to bump a number.

And `scripts/check_overload_assertions.py` now crosses the keyed names
against every `proname = '...'` in `supabase/tests/`. Three overlap today
and each is named in a reviewed list saying the assertion was read; a
fourth fails in CI **by name**, and a reviewed entry that stops applying
fails too. Ten self-tests, one of which runs the lists against the
repository itself.

### Where the census stood after seven tranches

| | |
| --- | --- |
| client-reachable writes | **340** |
| hold an idempotency key | **28** |
| insert nothing at all | **146** |
| guard or replace every row they insert | **34** |
| refuse a repeat BY NAME | **37** |
| carry a checked verdict | **69** |
| **undecided** | **26** |

137 → 85 → 56 → 48 → 38 → **26** across six tranches of 3 October.

## `0736`: the POS back office, and a double handful of points

48 → **38**. Six wrappers and four more verdicts, all measured:

    upsert_cash_forecast_item  -> 2 forecast lines
    upsert_pos_driver          -> 2 drivers
    upsert_pos_report          -> 2 saved reports
    upsert_pos_menu_schedule   -> 2 schedules
    upsert_pos_promotion       -> 2 promotions
    adjust_loyalty_points      -> balance 100, from two 50-point taps

**`adjust_loyalty_points` is the second in this programme whose damage is
not a row**, after `0735`'s `escalate_ticket`. `app.loyalty_balance` came
back **100** after two identical 50-point adjustments: the ledger has two
entries, which is correct bookkeeping for two adjustments, and the
customer has twice the points a cashier granted once. Nothing on the
account says the grant was one press. That shape — a number, not a row —
is now two of eighteen, and it is the shape a person cannot find by
looking at a list and deleting the second one.

The five `upsert_*` are the ordinary shape: each takes no id on a create,
mints one, and has no unique index on anything the caller sends, so two
identical calls leave two rows. `upsert_pos_promotion` takes
**twenty-two** arguments, which is why the wrapper is long and why the
client call site is the one most likely to drift — the gate that requires
every parameter to be named is doing real work there.

`adjust_loyalty_points`'s organization comes from
`public.loyalty_accounts`, not from an argument: the call names an account
and a delta. Its stored result is keyed `balance`, so a replay returns the
balance rather than a row id — the same decision as `0734`'s `knock_off`,
which returns the count it returned the first time rather than zero.

### Four came out, measured

- `upsert_loyalty_tier` → `unique:loyalty_tiers_program_id_code_key`
- `upsert_pos_modifier` → `unique:pos_modifiers_group_id_code_key`
- `enrol_loyalty_member` → `existing:A cashier who taps twice enrols one
  member` — the second `existing:` after `0735`'s `open_tax_estimate`:
  the function looks for the member and hands them back.
- `set_module_hidden` → `natural:sets a flag`, which cannot be set twice.

Three of those four were in the "same shape and very probably safe" list
this file wrote at the 85, and the fourth was not on any list. Measuring
them was still worth it: `enrol_loyalty_member` is the one that would
have been wrapped on the strength of its body, and wrapping it would have
been wrong.

### The mutant that survived

"`upsert_pos_driver` fingerprints without the name" survived, because the
block's two keyed calls sent **identical arguments**. A wrapper that
ignored half its input would have passed. The assertion added is a
same-key-different-name call expecting `22023` — the idempotency layer's
"this key was used with different arguments" — and it kills the mutant.

**The general form: a block that only ever sends one payload cannot test
that the key covers the payload.** It is the twelfth entry of
`docs/widget-tests.md` wearing different clothes — a fixture where the
right value and the wrong value are the same value.

### Where the census stood after six tranches

| | |
| --- | --- |
| client-reachable writes | **340** |
| hold an idempotency key | **24** (0307's four, then 0733–0736's twenty) |
| insert nothing at all | **146** |
| guard or replace every row they insert | **34** |
| refuse a repeat BY NAME | **37** |
| carry a checked verdict | **61** |
| **undecided** | **38** |

`BACKLOG = 38` in the gate. 137 → 85 → 56 → 48 → 38 across the five
tranches of 3 October. What is left is listed in the section above for
the 85, minus what each tranche took; the largest remaining group is
still "inserts only through a callee", which the census cannot see and
which therefore has to be read one function at a time.

Six mutants, all killed, control surviving.

## `0735`: a second ticket, a second link, a second transfer

56 → **48**. Six wrappers and two more verdicts, all measured:

    create_ticket         -> 2 tickets
    escalate_ticket       -> escalation_level 2, from one press
    share_ticket          -> 2 live tokens
    share_document        -> the same, for a sales document
    report_feedback       -> 2 reports
    create_bank_transfer  -> 2 transfers

**`escalate_ticket` is the first in this programme whose damage is not a
row.** Everything else leaves two of something a person can see and
delete. An escalation level is a single integer: a retry escalates past
the person it was meant to reach, and nothing on the ticket says it
happened twice.

The two share functions are the second-worst shape. A retry mints a
second live token and does not revoke the first, so the number of ways
into somebody's invoice doubles until they expire. Their wrappers return
the SAME url on a replay, which has its own mutant.

### Two came out, measured

`attach_feedback_file` raised a unique violation on the second call —
`feedback_attachments_storage_path_key` is on `storage_path`, which comes
straight from the caller. A `unique:` verdict.

`open_tax_estimate` ran twice and left ONE row, which is neither a
refusal nor a duplicate: it looks for the live estimate and hands it
back. Its own comment says so — *"Pressing the button again means 'show
me it' rather than 'make a second'"* — and that is a third shape the
census had no name for. It has one now: **`existing:`**, checked against
the body exactly like `state:`.

### An overload broke an assertion in a file nobody was looking at

`ai_assistant.sql` asserted

    (select p.provolatile::text from pg_proc p
      where p.proname = 'report_feedback') = 'v'

— a scalar subquery over a function name, which started raising "more
than one row returned by a subquery used as an expression" the moment
`report_feedback` had two forms. The same shape as `outbound_email.sql`'s
"there is exactly one email_document", and the second time this
programme has hit it.

It is `bool_and(p.provolatile = 'v')` over every form now, which also
says something stronger than before: a volatile function cannot acquire a
STABLE overload that the AI assistant would then be offered as a reader.

**The lesson for the remaining 48 is procedural.** An overload is
invisible to the Dart analyzer and to the gates, and it is NOT invisible
to any assertion that reads `pg_proc` by name. There are two such
assertions in `supabase/tests/` and both have now been found by breaking
them. A third would be found the same way, which is the argument for
running the whole suite — not the one file a tranche touches — before
every push.

Six mutants, all killed, control surviving.

## `0734`: four ways to pay an invoice twice

60 → **56**, and this is the first tranche where the duplicate is money
against a customer's account rather than an email or a line of history.

All four were MEASURED. A thousand-ringgit invoice, a thousand-ringgit
receipt, and the same call twice:

    allocate_with_discount(receipt, invoice, 300, 0, today)  twice
      -> 2 allocations, invoice balance 1,000.00 -> 400.00

Seven hundred was expected. And nothing in the schema could have stopped
it: there is no unique index on `payment_allocations` and no "already
allocated" check, **because a receipt may legitimately be applied to the
same invoice twice**, in two instalments on two days. The database cannot
tell that from a dropped connection. This is the shape where only a key
will do, and it is the first one in this programme where that was true
rather than assumed.

| | |
| --- | --- |
| `allocate_with_discount` | measured: two allocations, 600 off a 1,000 invoice |
| `apply_deposit` | measured: applied twice |
| `knock_off` | measured: the whole batch landed twice |
| `allocate_payment_with_discount` | the purchase-side twin of the first, line for line; wrapped on that reading and asserted beside the others |

The organization comes from the thing each one is told about —
`receipts`, `purchase_payments`, `deposit_notes`, `contacts` — resolved
before the key is claimed so `0475`'s membership guard applies.

`knock_off` returns a COUNT, so its replay returns the same count and not
zero: zero would read as "there was nothing to settle", which is the
opposite of what happened. That has its own mutant.

**The optional date was checked, not assumed.** Three of the four take a
trailing date defaulting to null and `coalesce` it to today inside, so
the wrapper passes the null through — unlike `0733`'s `email_document`,
where null and omitted were 45 days and 30. The difference is one line of
each function and it is the kind of thing that only shows up in a
customer's share link three weeks later.

Six mutants, all killed, control surviving: each wrapper not claiming its
key, the replay returning null instead of the first id, the fingerprint
dropping the amount, and `knock_off`'s replay returning zero.

16 new assertions in `idempotency.sql`, each on the real figures.

## Twenty-five refusals the vocabulary did not know

85 → **60**, and the method is worth more than the number. The census's
automatic `guarded` category matches `already (posted|paid|void|…)` — a
closed vocabulary of past participles. So it found "Adjustment % is
already posted" and missed every one of these:

| | |
| --- | --- |
| `accept_intercompany_bill` | "That invoice has already been billed here" |
| `capitalise_bill_line` | "That line has already been capitalised." |
| `chat_request_link` | "These companies are already linked" |
| `close_fiscal_year` | "% is already %" |
| `convert_lead` | "This lead was already converted" |
| `create_contact_as` | "already has a % record" |
| `create_fiscal_year`, `create_previous_fiscal_year` | "A fiscal year already covers % to %" |
| `dispose_fixed_asset` | "has already been disposed of" |
| `draft_bill_from_received_einvoice` | "This document is already on a bill" |
| `hire_applicant` | "has already been hired" |
| `open_pos_shift` | "This till already has a shift open." |
| `post_bank_transaction` | "That line is already matched to something." |
| `post_landed_cost_run` | "That run is already %." |
| `quote_opportunity` | "This deal already has a quotation." |
| `remit_withholding` | "was already remitted on" |
| `renew_employee_document` | "That document has already been renewed." |
| `reopen_fiscal_year` | "% is %, not closed" |
| `request_einvoice_for_sale` | "e-Invoice for % is already %" |
| `request_payslip_access` | "You already have a request awaiting a decision" |
| `send_stock_transfer` | "That transfer is already %." |
| `split_pos_table` | "is already split into % parts" |
| `start_onboarding` | "This employee already has an open % checklist" |
| `transfer_document` | "every line has already been taken forward" |
| `book_appointment` | "already has somebody at %." |

They were found by pulling every `raise exception` out of each undecided
function and reading the ones that mention something having already
happened — not by widening the regex, which would have started matching
sentences like "the figures already agree with the statement".

Each is a `state:` verdict, so the gate looks for that exact text in the
body on every run: a reworded refusal is still a refusal, a deleted one
fails. Every one of the 25 was checked present before being written
down, which caught nothing but would have caught a typo.

Three are also asserted in `idempotency.sql`, because they are cheap to
stand up: `create_fiscal_year`, `close_fiscal_year` and
`reopen_fiscal_year`. The rest want a posted document, a sent transfer or
a hired applicant first, and their verdicts rest on the text check.

**And the helper that asserts them had to be widened.** It caught
`unique_violation` and `raise_exception`, which is what the `upsert_*`
block needed — and `close_fiscal_year`'s "2026 is already closed" is
neither, so it went uncaught and the block failed on a refusal that was
working. It is `when others` now, with the deliberate `FAIL:` re-raised
so a function that really does double is still not swallowed.

### 60 left, and what is in them

The genuine wrapper work, unchanged in shape from `0733`'s four: a number
the function mints (`create_bank_transfer`, `create_payroll_run`,
`create_withholding`, `create_po_from_suggestions`, `create_ticket`,
`open_matter`, `upsert_landed_cost_run`), no unique index at all
(`allocate_with_discount`, `allocate_payment_with_discount`,
`apply_deposit`, `knock_off`, `adjust_loyalty_points`,
`upsert_cash_forecast_item`, `upsert_pos_driver`, `upsert_pos_report`,
`upsert_pos_menu_schedule`, `cover_line_with_membership`,
`start_membership`), a state it increments (`escalate_ticket`), a token
it generates (`share_document`, `share_ticket`, `upsert_pos_menu_link`),
and the ones that insert only through a callee, where the statement is
out of the census's sight (`bill_matter_time`, `bill_project_time`,
`bounce_pdc`, `clear_pdc`, `recognise_revenue`, `ingest_offline_sales`,
`open_pos_sale`, `ensure_default_warehouse`, `next_document_number`,
`run_item_conversion`, `run_depreciation`, `run_recurring_journals_for`,
`settle_deposit`, `receive_stock_transfer`).

## The create-or-amend family, measured

93 → **85**. Eight `upsert_*` functions take an optional id — with one
they amend, without one they create — so the only question is whether a
second create collides. All eight were called twice against a built
database and all eight were refused:

    upsert_account             accounts_org_id_code_key
    upsert_pos_tender_type     pos_tender_types_org_id_code_key
                               (its own words, in fact: "The code CSH2
                               is already Cash two's.")
    upsert_pos_stall           pos_stalls_outlet_id_code_key
    upsert_scale_format        scale_barcode_formats_org_id_prefix_key
    upsert_pos_modifier_group  pos_modifier_groups_org_id_code_key
    upsert_kitchen_station     pos_kitchen_stations_outlet_id_code_key
    upsert_pos_delivery_zone   pos_delivery_zones_name_uq
    upsert_budget              budgets_org_id_fiscal_year_id_name_key

The probe is now a permanent block in `supabase/tests/idempotency.sql`
— "the create-or-amend family refuses a second create" — because the
gate can check an index EXISTS and cannot check that it BITES. Whether it
bites depends on where the value in its columns comes from, and
`create_bank_transfer` has an index of exactly the same shape that does
not bite at all: `next_document_number` mints the number and the second
call gets the next one. A verdict whose function starts generating its
own code instead of taking one now fails an assertion rather than
quietly becoming untrue.

Three more of that family are NOT excused, and the reason is that their
fixtures were more work than the verdict was worth today:
`upsert_item_conversion` wants an output line, `upsert_loyalty_tier` and
`upsert_pos_modifier` want a loyalty program and a modifier group that
the probe org has no module for. They have the same shape and are very
probably safe. They stay in the 85 until somebody measures them, because
eight measured is worth more than eleven assumed.

### Still undecided, and what they will need

Of the 85, the ones that will need a real wrapper rather than a verdict,
grouped by why the index cannot save them:

- **a number the function mints** — `create_bank_transfer`,
  `create_payroll_run`, `create_withholding`, `quote_opportunity`,
  `create_po_from_suggestions`, `draft_bill_from_received_einvoice`,
  `accept_intercompany_bill`, `upsert_landed_cost_run`,
  `open_pos_shift`, `create_ticket`, `open_matter`;
- **no unique index at all** — `allocate_with_discount`,
  `allocate_payment_with_discount`, `apply_deposit`, `knock_off`,
  `adjust_loyalty_points`, `upsert_cash_forecast_item`,
  `upsert_pos_driver`, `upsert_pos_report`, `upsert_pos_menu_schedule`,
  `book_appointment`, `cover_line_with_membership`, `start_membership`;
- **a state it increments** — `escalate_ticket` adds one to
  `escalation_level`, so a retry escalates twice;
- **a token it generates** — `share_document`, `share_ticket`,
  `upsert_pos_menu_link` mint a random token per call;
- **inserts only through a callee**, so the census cannot see the
  statement and neither could I without reading each one —
  `bill_matter_time`, `bill_project_time`, `bounce_pdc`, `clear_pdc`,
  `close_fiscal_year`, `knock_off`, `post_bank_transaction`,
  `recognise_revenue`, `remit_withholding`, `reopen_fiscal_year`,
  `request_einvoice_for_sale`, `ingest_offline_sales`, `open_pos_sale`,
  `ensure_default_warehouse`, `next_document_number`.

Each of those needs the same two things `0733`'s four needed: the
organization resolved from an argument where there is no `p_org_id`, and
a client call site that names every parameter. 38 of the 85 carry an org
argument; 47 do not.

## The import family was the loudest hazard, and is the best-protected

A migration `0734` was written, applied locally, and then DELETED. It
wrapped the six `import_*` functions, on the grounds that a retried
import is not one duplicated row but one duplicated SPREADSHEET — and
`import_sales_transactions` says so in its own comment: "is a file nobody
can run again: the good half is now a duplicate."

Every one of the six already refuses a second run, and each was found a
different way:

| | |
| --- | --- |
| `import_accounts` | "%s is already in the chart." Read. |
| `import_opening_balances` | "An opening trial balance has already been brought into this company." Read. |
| `import_opening_stock` | "Opening stock has already been brought into this company." Read. |
| `import_bank_transactions` | not a refusal but a SKIP: `if exists` per line, counted as `skipped`, asserted in `bank_reconciliation.sql` since it was built. Found by reading a test. |
| `import_sales_transactions` | **measured.** Ran the same file twice: "Nothing was imported: 1 of 1 rows have a problem." |
| `import_purchase_transactions` | **measured**, the same way. |

The last two are the ones worth the paragraph. `next_document_number`
appears in their call graph, which is what made them look like the worst
entries in the whole census: a file re-landing under the next numbers,
where the unique index on `(org_id, doc_type, doc_no)` cannot help. The
probe that was meant to demonstrate that found the opposite — the
importer REQUIRES a `doc_no` in the file (a row without one is a row with
a problem, and the whole file is refused), so the number always comes
from the caller and the index always collides.

**So `0734` is not in the repository.** The verdicts are, in
`scripts/check_write_idempotency.py`, and four of them are re-checked on
every run: two `unique:` naming the index, two `state:` naming the
refusal text, which the gate now looks for in the function's body.

### `state:` as a verdict kind

Because the automatic check reads each INSERT STATEMENT and these four
guard EARLIER — a refusal raised ahead of the loop, or an
`if exists … then continue` inside it. Widening the statement pattern to
catch that shape would make it catch things that merely look like it, so
instead a verdict may name the refusal text and the gate fails if that
text leaves the body. A refusal that has been reworded is still a
refusal; one that has been deleted is not.

### Where the backlog stands

99 → **93**. Three times now a function that read like a
duplicate-on-retry defect has turned out to be guarded by something not
visible in its own body: a unique index absent from `pg_constraint`
(`save_payment_method`), a per-line `if exists` (`import_bank_transactions`),
and a required argument that makes an index bite
(`import_sales_transactions`). The rule that keeps falling out of this is
the same one: **read the body to find the candidates, then make the
duplicate happen.** Nothing else distinguishes the three.

## The 3 October session, third change: deciding the 137

Asked for: "now do the remaining 137". This commit takes the backlog from
137 to **99** and the way it does it is the point — the 38 it removed
were decided by a check the gate RE-RUNS, not by prose somebody has to
be trusted about.

### The gate now reads INSERT statements, not function bodies

A function is idempotent if every row it creates would collide with one
already there. Three shapes in this schema say so, and all three are
machine-checkable: `on conflict` on the statement, `where not exists` on
the statement, and a `delete from` the same table earlier in the body —
the replace-the-lot shape `set_budget_lines` and `upsert_pos_recipe` use.

**Per statement, and that is the whole design.** `chat_create_group`
inserts a conversation with no guard and then participants `on conflict`.
A flag that looked for `on conflict` anywhere in the body would call the
whole function safe while the conversation doubles — so the check takes
each `insert into T …` up to its own semicolon, and one bare insert is
enough to leave the function undecided. Eight self-tests cover it,
including that shape and the case where the `on conflict` belongs to the
NEXT statement.

That absorbed **34**: `invite_member`, `file_sst_return`,
`post_payroll_run`, `clock_in`, `route_item_to_station`,
`set_budget_lines` and the rest, each spot-checked by hand against the
real body as well.

### Four verdicts written by hand

Three `repeats:` — `audit_list_payslips`, `audit_view_payslip` and
`log_document_download` are access and download logs, and a log that
drops a repeated access is worse than one that records it twice. One
`unique:` — `open_tax_computation` inserts `(p_org_id, p_fiscal_year_id)`
into a table with `tax_computations_org_id_fiscal_year_id_key` on exactly
those two columns, both straight from the arguments.

### What the remaining 99 are, and why they are not a prose problem

The decisive question for each is narrower than it looks: **does a unique
index cover columns the ARGUMENTS determine, or ones the function mints?**
`tax_computations` is unique on `(org_id, fiscal_year_id)` and both come
from the caller, so a retry collides. `bank_transfers`,
`payroll_runs` and `withholding_certificates` are unique on
`(org_id, <number>)` where the number comes from
`next_document_number` — so a retry gets the next one and does not
collide. The index looks identical in `pg_indexes`; only the insert says
which it is. That is not machine-decidable, which is why it is a verdict
and not a category.

Of the 99: **38 carry an org argument**, so their wrapper is mechanical
in the way `save_payment_method`'s would have been. The other **61 need
the organization resolved from one of their arguments** — the document,
the ticket, the receipt — which is the per-function decision
`email_document` and `assign_ticket` each needed.

The worst of them, in order of what a retry costs: the five `import_*`
functions, where a retried import is a duplicated FILE;
`allocate_with_discount`, `allocate_payment_with_discount`, `apply_deposit`
and `knock_off`, which duplicate a payment allocation; then
`create_bank_transfer`, `create_payroll_run`, `create_withholding`,
`quote_opportunity`, `create_po_from_suggestions`,
`draft_bill_from_received_einvoice` and `accept_intercompany_bill`, each
of which mints a second numbered document. `escalate_ticket` is its own
shape: it increments `escalation_level`, so a retry escalates twice.

## The 3 October session, second change: idempotency keys

Asked for: "apply idempotency keys to the remaining write functions",
where `docs/mcp-server.md` said the position was **4 of 482**. Shipped as
migration `0733` plus `scripts/check_write_idempotency.py`, and the
useful part of this entry is the three times the measurement was wrong.

### 478 was never the number, and my first correction of it was wrong too

A write only needs a key if a CLIENT can retry it. The population is
what `repository.dart` calls, not every volatile function — and I took
that census with

    grep -oE "callRpc\(\s*'([a-z0-9_]+)'" app/lib/src/data/repository.dart

which found **192** functions. grep matches within a line. A quarter of
this file's call sites put the name on the line AFTER `await callRpc(`.
The real figure is **577**, and the 385 it missed include
`email_receipt`, every `import_*`, and most of `create_*`. I had already
told the user "the real set is far smaller than 478" on the strength of
the 192 before finding this.

The gate now does the scan multi-line, and
`check_write_idempotency_test.py` asserts a split call site is found —
the assertion that would have caught it.

### What the schema actually looks like

| | |
| --- | --- |
| client-reachable writes | **340** |
| hold an idempotency key | **8** (0307's four, 0733's four) |
| insert nothing at all | **146** |
| refuse a repeat BY NAME — "Adjustment % is already posted" | **37** |
| carry a written verdict | **12** |
| **undecided** | **137** |

`BACKLOG = 137` in the gate. It may fall; it may not rise. Each
undecided function needs somebody to read it and record one of: a key, a
state guard it already has, or why repeating it is the feature —
`add_pos_sale_line` twice is two lines on the bill.

### Two that looked like defects and were not

`save_payment_method` and `create_layout_from_builtin` both end in an
unconditional `insert` when no id is passed. Both were written into
`0733` and into `idempotency.sql` as duplicate-on-retry defects. The
block asserting the duplicate then raised

    duplicate key value violates unique constraint "payment_methods_name_key"

— a UNIQUE INDEX on `(org_id, lower(name)) where deleted_at is null`
which is in neither the table definition nor `pg_constraint`, so reading
the function bodies could not have found it. `report_layouts` has the
same arrangement. Both came out.

**This is the argument for making the first assertion in each block the
unguarded double itself.** Without it both wrappers would have shipped,
and every assertion about them would have passed.

### The four that do double

`email_document`, `email_receipt`, `bulk_email_documents` —
a retry queues a second message to the customer, and that side effect
leaves the building and cannot be reversed by a journal — and
`assign_ticket`, where what doubles is the ticket's history.

`bulk_email_documents` is the first wrapper to return a TABLE rather
than an id: the stored result is `jsonb_agg` of the rows and a replay
re-emits them, because a replay that returned an empty set would pass
any test that only counted the outbox.

### Seven mutants, all killed, and the last one took three rounds

Restated into the built database and run against `idempotency.sql`, the
shape `0475` used. Six died at the assertion aimed at them. The seventh
— passing `p_share_days` through positionally instead of omitting it —
survived twice, and both reasons are worth keeping:

1. **`expires_at is not null` is not an assertion about a number.**
   There are two defaults for this one value: `email_document`'s own
   `p_share_days default 30` and `app.issue_share_token`'s
   `greatest(coalesce(p_valid_days, 45), 1)`. Passing the null through
   does not fail and does not produce a null expiry — it silently gives
   the customer a link good for 45 days instead of 30.
2. **`now()` does not move inside a transaction.** The fixed assertion
   read the keyed call's share link out of three with `order by
   created_at desc` — and all three rows carry the identical
   `created_at`, so the order was the planner's choice and it kept
   returning a link minted by an unkeyed send, which gets 30 whatever
   the wrapper does. A document sent only with a key has exactly one
   link. That is entry 12 of `docs/widget-tests.md` in a new costume:
   a fixture where the right value and the wrong value are the same row.

### Gates this tripped on the way, all of them right

`check_idempotent_calls.py` (a wrapper no caller uses is not
protection — and its own query had to be fixed: `proargnames` includes
the OUT columns, so it asked a caller to name `id`, `doc_no`, `sent` and
`problem`); `outbound_email.sql`'s "there is exactly one
email_document", which now asserts there are two and that the second is
the first plus the key and nothing else; `check_undocumented_writes.py`
(each wrapper needed a `comment on function` naming its refusals);
`check_test_clock.py` (the new KL-time fixtures made `idempotency.sql` a
two-clock file, so the whole file is on `pg_temp.today()` now);
and `generate_api_description.py --check`.

### What this deliberately did NOT do

The `post_*(p_id uuid)` family still answers a retry with "already
posted" rather than with the original id. `0307` called that "worth
having, not worth conflating with a correctness fix" and it is still a
separate change — one an agent would feel more than a person, because a
person reads the error and moves on.

## The 3 October session

One change, front end only, no migration: **the call stage is laid out
to fit the window rather than to a fixed portrait shape.** Reported as
"video call is not sideways now but incoming video shows blank dark
screen when the device is rotated" — and the rotation fix of 1 October
is not implicated. This is a second, unrelated defect that the first one
had been hiding.

### A fixed aspect ratio cannot fit both ways up

The stage was a `GridView.count` with `crossAxisCount` from the head
count and `childAspectRatio: 3 / 4`. Those two numbers fit a portrait
phone and cannot fit a landscape one, and the arithmetic is worth
writing down because it was measured rather than reasoned about:

| Window | Stage viewport | Tile laid out | Visible |
| --- | --- | --- | --- |
| 412x915, one peer | 396x771 | 396x528 | all of it |
| **915x412, one peer** | **899x268** | **899x1199** | **the top 22%** |
| 915x412, two peers | 899x268 | 445x594 | the top 45% |

The other 78% was below the fold of a scrolling list, and nobody scrolls
during a call. `objectFit: cover` then magnified what was left — the top
strip of the far end's frame, which is usually a ceiling or a blank
wall. Hence "blank dark screen" rather than "cropped": the symptom does
not sound like a layout bug, and that is why it was not one of the six
calling complaints fixed on 30 September.

**The default widget test surface is 800x600 — landscape, and wrong in
the same direction.** Every assertion in `call_screen_test.dart` passed
at that size while the screen was unusable on a turned phone, because
all of them counted widgets and none measured one. A thirteenth entry
for `docs/widget-tests.md`, and it is there.

### What it is now

`callStageColumns(tiles, box)` picks the column count from the SHAPE of
the window, the tile aspect is computed from the space that is actually
there, and the grid is `NeverScrollableScrollPhysics` — anything that
does not fit is now a layout error a test can see rather than something
hidden below a fold.

The rule for columns is to get each tile as near SQUARE as the head
count allows, because nothing on this side of the call knows the shape
of what is arriving: the far end may be holding a phone upright, or
sideways, or be a laptop. Squareness is measured as
`max(aspect, 1 / aspect)`, and the symmetry is load-bearing — the
obvious `(aspect - 1).abs()` is unbounded above and capped below, so it
quietly prefers narrow tiles and on a nearly square window stands two
people in two slivers instead of stacking them. A mutant swapping one
for the other is killed by a test at 450x500.

What that produces: one peer gets the whole stage either way up; two
stand side by side in landscape and stack in portrait; four go in a row
of four on a landscape phone and 2x2 on an upright one; three on an
upright iPad fill one row and half of the next.

The remote tiles also moved from `cover` to **`contain`**. With a tile
shaped by THIS window, cover throws away whichever edges of the far
end's frame disagree with it — on a landscape window with a portrait
camera at the other end, most of the person. Letterboxing costs black
bars against an already black screen. The 108x144 self-view keeps
`cover`, and a test asserts that it does, so a sweep over the remote
tiles cannot quietly take it too.

### Eleven mutants, all killed

`python3 scripts/mutate.py lib/src/features/chat/call_screen.dart
test/call_screen_test.dart <mutants>`, control surviving. Two rounds
were needed and both corrections were in the TEST, not the code:

- the first `allOnScreen` helper checked each tile against the WINDOW,
  and the stage clips, so a tile eight pixels past the bottom of the
  grid is invisible while still four hundred pixels inside the screen.
  Two arithmetic mutants — forgetting the gap between rows, and between
  columns — lived in that difference. Checking against the stage box
  killed the first;
- the second needed the tiles to FILL the stage and not merely fit in
  it, because `GridView.count` takes the tile WIDTH from
  `crossAxisCount` and uses `childAspectRatio` for the height alone —
  so an error in the computed width shows up only as a few pixels of
  stage nothing is drawn on;
- `rows ~/ columns` instead of `.ceil()` survived every size that
  divides exactly. Three peers on an upright iPad is the one arrangement
  in the group where it does not, and that test is why the mutant dies.

And one branch was DELETED rather than tested: `if (tiles <= 1) return
1;` could be removed without a single assertion noticing, because the
loop below already returns 1 for one tile. A branch that cannot change
an answer is a branch that can rot unobserved.

### What this does NOT explain

If a rotated call still goes dark on a real handset after this, it is a
different fault and this one is not it. The geometry above is measured
and now asserted; a black `Texture` that is correctly positioned would
be the platform renderer, not the layout, and the thing to capture is a
console log from a real call rather than another reading of this file.

## The 2 October session

One commit, `c891c3a4`, migration `0729`, **green in run 2194 and verified
in production**: the migration is in `schema_migrations`, both refusals
are in the live function bodies, the org-scoped bank lookup is there,
and the sweep that returned nine functions now returns seven — exactly
the allow-list. It exists because
the previous session's audit was asked to be re-run as a fresh sweep
rather than taken on trust — and the sweep found that the audit had
been wrong about its own scope.

### ASKING A FILTERED QUESTION CANNOT TELL YOU WHAT YOU DID NOT ASK ABOUT

`0727` closed the 1120 fallback in `post_expense`. `0728` said it had
found "the same shape in five more places" and closed four. The number
that matters:

    select p.oid::regprocedure::text
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public','app') and p.prokind = 'f'
       and pg_get_functiondef(p.oid) like '%code = ''1120''%';

**Nine.** `0728` reported one. The difference is two posting paths
nobody had looked at — `dispose_fixed_asset` and `remit_withholding` —
plus six demo seeders, which are data rather than rules.

Both earlier passes had asked a question with the answer already in its
`where` clause: a query over the functions that were known about, and a
grep of `supabase/migrations/` for `'1120'` that listed twenty files of
which five were opened. That is run 2183's lesson — grepping for a
token is not grepping for the behaviour — recurring one level up.

`remit_withholding` had a second reason, and it is the better
cautionary tale. `0506`'s header says it "already had the guard and an
org-scoped update, so neither needed changing". True — about the
CROSS-TENANT guard, and silent about the fallback. One sentence about
one property of a function was read as a verdict on the function. Its
own comment, meanwhile, described the harm while doing it: it documents
refusing another company's bank account because "falling back to the
default cash account would post the entry anyway and leave nobody any
the wiser".

### What `0729` changed

* **`dispose_fixed_asset`** refuses when proceeds are positive and no
  account is named, and — new, not a copy of `0728`'s work — **scopes
  the bank lookup to the asset's org.** It matched on `b.id` alone.
  `p_bank_account_id` is an ARGUMENT, so none of `0160`'s composite
  foreign keys reach it (those constrain stored columns), and naming
  another company's account would have debited THEIR ledger account
  inside this company's journal. Same hole `0505` and `0506` closed
  where the account is a column.
* **`remit_withholding`** refuses a remittance paid from no account.
* **`money_names_the_account.sql`** pins the ALLOW-LIST:
  `app.post_receipt_internal` plus the six demo seeders, asserted in
  **both directions**. A tenth function fails by name, and an
  allow-list entry matching nothing fails too — that second half is the
  one that rots, because a stale exemption reads as the truth, which is
  exactly how this migration's own subject survived.
* **Both dialogs** now ask. `disposal_dialog.dart` stars "Proceeds
  into" the moment an amount is typed; `withholding_screen.dart`
  replaces a yes-or-no `confirm` with a dialog that asks which account
  the money left, keeping the confirmation's words, because "do it when
  the money has actually gone" was always the right warning.

The disposal dialog's helper text had said *"Left blank, they go to
cash"* and **a widget test asserted that sentence.** It was not true —
blank went to 1120. Same species as the SQL fixture that asserted the
1120 credit and called it "the money leaves the bank": a test pinning a
false claim in place, in prose this time.

### The twelve accounts, and the door — now shut, in `0730`

Refusing a MISSING account does not catch the other way in: a bank
account whose `account_id` points AT the heading. **Twelve companies
have one** — active, named "CIMB Current Account", "Maybank Current
Account", with real balances — and a posting naming one of those passes
every null check and lands on 1120 anyway. That is most of the 97 lines
now sitting on the heading across 14 companies: 53 from receipts, 18
from purchase payments, 25 from manual journals, 1 from
`EXP-2026-00001`.

**Those rows are left exactly as they are, by the user's decision.**
Nothing in `0729` moves a posted line. Only two of the twelve companies
have a second bank account and in both it is `1150 Client Account`, so
no company has two accounts resolving to 1120 and nothing is
misreconciled between accounts today. It is latent.

Shutting the door behind them is `0730`, and it cost what the
measurement said it would. `app.bank_account_not_the_heading()` is a
BEFORE INSERT OR UPDATE trigger on `public.bank_accounts` refusing an
`account_id` that is a group heading, or is 1120 itself. The sweep it
needed: **23 of the 382 assertion files failed its first run**, and 29
test files plus `_helpers.sql` were changed to fix them — 39 of the 72
heading literals in `supabase/tests` are gone, and the 33 that remain
are about the heading rather than on it (the allow-list, the assertions
that nothing lands there, and manual journals in `budgets.sql`,
`general_ledger.sql` and `matter_trial_balance.sql`, which post to it as
a ledger account and are not bank accounts at all).

Read the section below for what the sweep found on the way.

### `0732`: a shop can say where its money goes

`0731` recorded that there was **no screen for editing a tender type**
— the table is read by the till and was written only by demo seeders,
which is why all thirteen rows had a null bank account and why "or into
another account where one is defined" was a half of the user's rule
nobody could reach. This is that screen, plus the two functions behind
it.

`public.upsert_pos_tender_type` and `public.delete_pos_tender_type`
exist rather than the client writing the table directly — which it
could, since `0208` gave `pos_tender_types` a write policy and a grant
— for the reason `CLAUDE.md` gives: a rule enforced only in Dart is not
enforced. The rules are: a name and a code, the code upper-cased
because it is what a report groups by, a duplicate refused **by naming
the tender that already holds it**, an LHDN payment mode that exists, a
bank account that belongs to this company, and `can_write_module`.

**Two kinds take no money, and the editor is what made that obvious.**
`0731`'s trigger filled an account for any tender that was not a
drawer, which was wrong for `on_account` — the customer owing it, and
`complete_pos_sale` writes no receipt at all for a basket wholly on
account — and for `loyalty`, points coming off the basket, where `0212`
gives a receipt for zero and `app.post_receipt_internal` resolves that
zero's account itself. Both are now left alone by the trigger and
refused an account by the upsert. A VOUCHER deliberately is not: one
the shop sold was paid for when it was sold, one a third party issued
is settled later, and which a shop means is the shop's to say.

Two things the screen cannot do, each said out loud rather than offered
as a control that undoes itself:

* **Clear the account on a tender that takes money.** The trigger fills
  it again, by design — money has to land somewhere.
* **Delete a tender that has taken money.** `pos_tenders` references
  the type `on delete restrict` on purpose, because `0208` copies the
  KIND onto each tender so retiring a type cannot change what last
  month's drawer was counted against. The refusal names how many times
  it has taken money and says to switch it off instead.

### What the mutation run changed about the code

A surviving mutant was right and the code was wrong. `_kindChanged`
cleared `_bank` when the kind stopped taking money, and that line
turned out to be both unobservable — `_save` already sends null for
those kinds — and mildly harmful: somebody who looked at On account and
changed their mind back to Card lost the account they had picked. **The
line is gone**, which is the other thing a surviving mutant can mean.

The other survivor was a real missing assertion: a new tender takes its
kind's habits (cash counts in the drawer, gives change, opens it; a
card does none), and nothing checked it. Three mutants on the sheet and
five on `tenderSummary` are killed now, each with a comment-only
control surviving.

### Two gates nobody warned me about, both right

`dropdown_census_test.dart` failed twice on the new screen: a
`DropdownButtonFormField` has to be **on the census with a reason** —
the seven kinds are `app.pos_tender_kind`, an enum, so a dropdown is
right and the LHDN mode beside it is a `SearchablePicker` because that
list grows — and it has to set `isExpanded: true` or "Bank transfer"
overflows instead of ellipsising. And `check_test_clock.py` refused a
152nd `date_trunc('year', current_date)`: a new fixture uses
`(now() at time zone 'Asia/Kuala_Lumpur')::date`, because `current_date`
is the session's UTC date and from 16:00 UTC they are different days.

### `0731`: where the card money lands, and a correction to all of this

The user answered the question the receipts half was waiting on: **card
and e-wallet settle into the company's own bank account a few days
later -- MBB for theirs -- or into another account where one is
defined.** Cash stays in the drawer. Asked which way to record the
lag, they chose the simple one: the receipt debits the bank on the sale
date, and the days until the statement shows it are an unmatched item
on the reconciliation, the same treatment a cheque in transit gets. The
acquirer's fee was already modelled -- `receipts.bank_charges` posts to
`app.bank_charge_account` (`0635`) -- so the bank is debited net. A
card-settlement-in-transit account is the more accurate model and was
explicitly deferred; the tender's account is a column, so that change
stays additive.

### THE CORRECTION, which matters more than the migration

`0728`, `0729` and `0730` each describe the heading as a live mess in
customers' books: "twelve companies have one, with real balances", "97
lines across 14 companies". **The counts were right and the
characterisation was wrong**, and all three inherited it from a
sentence none of them had measured:

| | demo | real |
| --- | --- | --- |
| bank accounts pointing at the heading | 11 | **1** — YUSOF ZAIN & CO / CIMB |
| ledger lines on the heading | 96 | **1** — GESWANT & CO, −22.50 |
| companies with a POS tender | 5 | **0** |

So the real remainder of three days' work is one bank account to
repoint and one expense of −22.50, which is `EXP-2026-00001` and was
already waiting on a person.

**And the eleven demo accounts have since put themselves right**, which
was the prediction and is now a measurement: after `0731` landed they
are all on **1121**, so the bank accounts pointing at the heading in
production are down from twelve to **one** — YUSOF ZAIN & CO's CIMB.
That is the whole of what is left of this in anybody's books.

And the reason `0728` gave for keeping the last fallback — refusing
"would stop the till rather than correct it" — was sound reasoning
about demo data. **There is no real till.** Read a count and a
characterisation as two different claims; this file carried the second
one for three days without anybody measuring it.

### What `0731` actually does

`app.post_receipt_internal` does NOT simply refuse a null account,
because three callers reach it without one and none of them is a person
who declined to answer:

* `complete_pos_sale` takes it from the tender type, and every tender
  row in production has none;
* the same function gives a basket cleared entirely by loyalty points a
  receipt for **zero** (`0212`), with no tender at all;
* `record_group_payment` looks for `is_default and is_active` and finds
  nothing when a company's default account has been closed. Its own
  comment said what happened next: "left null the posting falls through
  to cash (1120) and no bank balance moves at all".

So it RESOLVES one — a gateway's settlement account, else the default
active account, else the oldest active one, never a closed account and
never a client account — and **writes it onto the receipt**. That
write-back is the whole difference from the fallback it replaces: 1120
was chosen at posting time and left no trace, which is how a year of
entries reached the heading unnoticed. A resolved account is on the row,
in every list that reads one, and on the reconciliation that has to
agree with it. It refuses only when the company has no bank account at
all, and says a cash drawer counts.

`app.tender_type_settlement_account` fills the tender row by the same
rule, so the answer is visible where somebody can change it. **There is
no screen for editing a tender type** — tenders are read by the till
and written only by demo seeders, which is why all thirteen rows were
null. That editor is the follow-up this did not build.

> **STALE — corrected 4 October.** The editor WAS built:
> `app/lib/src/features/pos/tenders_screen.dart`, on
> `upsert_pos_tender_type` (`0732`). So a tender type can be changed by a
> person now, and all thirteen rows carry an account.

`app.demo_company` now gives every demo company a cash drawer at birth:
`app.demo_warung` sells at a counter before `app.demo_purchases` has
made it a bank account, and four more POS seeders are in the same
position. Fixed in the 22-line function every demo company passes
through rather than in five seeders totalling 1,080 lines.
`app.demo_bank_account`'s lookup is now asked for a TYPE as well, so a
till is not handed back as a current account.

### Three more fixtures that could not see what they tested

The same shape as `0730`'s four, found the same way:

1. **28 POS fixture files created tender types and no bank account at
   all**, so the takings went to the heading. `_helpers.sql` has
   `pg_temp.a_till(org)` now, called at 42 sites.
2. **Seven receipt fixtures never named an account** — `aged_balances`,
   `aging_shapes` (twice), `statement_of_account`, `void_an_invoice`,
   `knock_off`, `email_receipt`.
3. **`group_payment_shapes.sql` asserted "a closed account is not
   chosen even when it is the default" and passed because the field was
   NULL.** `is distinct from v_shut` is satisfied by nothing at all —
   the same trap as entry 9 in `docs/widget-tests.md`, in SQL.

And two in `demo_rebuild.sql` that only appeared once a demo company
had two bank accounts: `select b.current_balance into v_bank ... where
b.org_id = v_sinar` took whichever row came first and was compared
against the ledger for BOTH accounts, and a control asserting exactly
two distinct balances became three. Both were right while every tenant
had one account, which is the state that hid them.

### `0730`, and the four things the sweep found on the way

The trigger is five lines of rule. Everything else in that commit is
what shutting the door disturbed, and three of the four were found by
looking for writers BEFORE writing the trigger rather than after.

**1. Four demo seeders insert a bank account on the heading**, so the
trigger would have broken `app.demo_rebuild()` in production on the next
reseed — `demo_sinar_bank`, `demo_purchases`, `demo_practice_books`,
`demo_legal_guaman`, all restated in `0730` from `pg_get_functiondef`
with their md5s recorded in the header. They now call
`app.demo_bank_account`, which returns the account a company already has
— heading and all, because a seeder has no business repointing an
account that carries postings — and otherwise makes one in 1121-1199.

`demo_sinar_bank` needed one more line than the others:
its paid-up capital journal debits `v_bank_gl`, which was the heading,
so the GL account is now read OFF the bank account. Posting the capital
to the heading and the receipts to the child would have left the demo's
bank balance disagreeing with the demo's bank ledger, and
`app.demo_sync_bank_balance` would have "fixed" the wrong one.

**2. `app.demo_purchases` was never on `0729`'s allow-list and should
have been.** Its lookup reads

    where org_id = p_org and code = case when p_bank_type = 'cash'
                                         then '1110' else '1120' end

and the allow-list sweep matches a literal comparison, so it never saw
it. **That list is a net with a known mesh**, which is now written into
`money_names_the_account.sql` beside the list itself. Third instance in
three days of a pattern-match standing in for a question about
behaviour.

And the fourth instance, in the same hour: the query that found the
writers used `like '%insert into public.bank_accounts%'`, which is
CASE-SENSITIVE, and `0549` redefines `demo_legal_guaman` with
`CREATE OR REPLACE FUNCTION` in capitals. A lowercase `grep` for
`function app.demo_legal_guaman` reported one definition where there are
two, and the live one was the one it missed. **Use `ilike` and `grep -i`
when asking which code exists.**

**3. Two fixtures had a bank account on a REAL group heading**, which
the trigger's other branch caught: `client_money_crossing.sql` put a law
firm's office account on 1100 "Cash and Bank" — the parent of its own
client account, so a crossing from client to office moved between a
child and its parent — and `bank_feed.sql` chose its ledger account with
`account_type = 'asset' limit 1`, which is **1000**, the root of the
asset side of the chart.

**4. `opening_trial_balance.sql` had the two accounts the wrong way
round.** The "Current account" sat on 1110 Cash in hand and the "Petty
cash" on 1120, the BANK heading. The comment beside them says the point
is to cover the `bank` AND `cash` subtypes in the resync loop — and it
did, with each name pointing at the other one's account. Now the current
account is a bank account of its own and the petty cash is on 1130, and
the opening-balance file reads the bank's code off the account instead
of naming 1110.

### What `0730` deliberately leaves

**`budgets.sql`, `general_ledger.sql` and `matter_trial_balance.sql`
post manual journals to 1120** and still do. The heading is seeded
`is_group = false` and is therefore postable, and whether a manual
journal should be allowed onto it is a different question from whether a
BANK ACCOUNT may be hung on it. The trigger is on `bank_accounts` and
says nothing about `gl_lines`.

**The twelve rows themselves.** By the user's decision, and the trigger
returns early on an UPDATE that leaves `account_id` alone so they keep
reconciling — `current_balance` is written by every posting function.
`bank_accounts.sql` asserts that: a row on the heading can still be
banked and renamed, and cannot be repointed at the heading, with the
row made the only way left, by disabling the trigger for one statement.

### And the claim that had to go

`bank_accounts.sql` asserted, by name, that **"a caller may name the GL
account itself"** — by naming 1120 and checking it was accepted. It was.
That was the product's own route to the twelve, through
`upsert_bank_account`, whose guard lets it through because the heading is
`is_group = false` with subtype `bank`, which is exactly what that guard
asks for. The assertion is now the refusal, with the control beside it,
and `public.unregistered_bank_accounts` stops offering the heading in
the registration dialog — a list whose own comment says it excludes
groups because "offering them is offering a refusal".

Proved by breaking it: the three branches of the trigger were removed
one at a time against the live local database and each killed a named
assertion, with a comment-only control surviving. The demo-rebuild
assertion was proved the other way, by planting a heading-pointed row
with the trigger disabled and watching the detector name it.

### Four traps paid for in this one commit

1. **`pg_get_function_identity_arguments` prints PARAMETER NAMES.** The
   allow-list was first written in types, matched nothing, and the
   assertion failed naming all seven allowed functions as new arrivals
   — a formatting failure wearing the costume of a real finding. Use
   `p.oid::regprocedure::text`, which prints types and schema-qualifies
   only where it must.
2. **`prokind = 'f'` is load-bearing.**
   `pg_get_function_identity_arguments` raises on an aggregate
   ("array_agg is an aggregate function").
3. **`pg_get_functiondef` returns the COMMENTS as part of the body.** A
   function whose comment quotes `code = '1120'` matches a body sweep.
   The deferred trigger had to be restructured — `v_heading constant
   text := '1120'` and a reworded comment — so that the thing enforcing
   the rule did not fail the rule.
4. **`implements Repo` inherits no bodies.** A fake answering only
   `callRpc` sends `Repo.remitWithholding` to `noSuchMethod`, so the
   method never runs and nothing is recorded; `runWithFeedback` catches
   the throw and draws a snackbar, and the only symptom is an empty
   list. This is the mirror image of the extension-method trap and is
   now written up beside it in `docs/widget-tests.md`.

### What was run before the push

382 SQL assertion files, every Python gate and every gate self-test
(`supabase/tests/run_locally.sh`, which needs no Docker — see the
section below), `flutter analyze` clean, 6,616 Flutter tests, and two
mutation runs: five mutants killed on the remit dialog and six on the
disposal dialog, each with a surviving control. One remit mutant
survived the first pass — flipping `allowEmpty: true` changed nothing
any assertion could see — and the assertion that kills it is the one
saying the picker offers no "None" row, because a disabled button above
a list still offering a way out is a dead end rather than a rule.

## The 1 October session

Fourteen commits, all green. Thirteen runs, because `f217cd64` and
`4dd97e4e` were pushed together and share 2189.

It began as "set up android push notifications" and turned into four
separate pieces of work, three of which came out of the user looking at
a screen and asking why it said nothing: an expense that would not say
which account paid it, a reconciliation that posted without showing the
journal, and a remote camera lying on its side. The fourth — the 1120
audit — came out of fixing the first one properly and then asking where
else the same shape was.

| Commit | Run | What |
| --- | --- | --- |
| `68cbe84c` | 2180 | **Android push over FCM**: `Push.kt`, `PushService.kt`, the method channel, the conditional google-services plugin, `push_native.dart` for Android, and `check_push_channels.py` comparing the channel ids the sender names against the ones the client creates |
| `1eafa71b` | 2181 | An expense detail says which account the money left — the screenshot that started it showed nothing at all |
| `597de7a1` | 2182 | The bank reconciliation's "Post this line" dialog shows both legs before posting, and offers the contact |
| `7d57ca78` | 2183 | **`0727`**: an expense says where the money left, or it is not posted. RED — see below |
| `d5a42e59` | 2184 | The guard found a fixture my grep did not. RED |
| `7c558fc6` | 2185 | The door was already bolted: assert the lock that fires. RED |
| `4685a9ef` | 2186 | A function comment is published, so it may not lose three refusals. `0727` live |
| `78ae9817` | 2187 | Reverse an expense from the expense, and enter it again |
| `731e5b83` | 2188 | **`0728`**: the rest of the money that went to the heading — the 1120 audit, four more functions, three forms. `0728` live and verified |
| `f217cd64` | 2189 | This file, eight commits stale, and two of its claims disproved |
| `4dd97e4e` | 2189 | The graph rebuilt over all of it: 35,975 nodes, 56,834 edges |
| `df41280e` | 2190 | **The incoming video turned a quarter clockwise.** A stopgap, asked for directly, and superseded twice below |
| `50d6c23f` | 2191 | **The real cause**: the mediasoup package's `RtpCapabilities.toMap()` drops every RTP header extension. `call_rtp.dart`, plus `check_rtp_capabilities.py` and its self-test |
| `ca2386b1` | 2192 | Nothing in the widget tree turns a camera. The stopgap out, its absence asserted |

### Android push: three things that all report success

`68cbe84c`. The client half, written the way iOS was — a method channel
and Kotlin behind it, **no Flutter plugin** — because `firebase_core` on
the web injects the Firebase JS SDK into every page load and this app is
used from a market stall's phone browser.

Three traps, and what they share is that every layer of each one reports
success:

- **A channel that does not exist is DROPPED.** From Android 8 a
  notification naming a channel the app has not created is not shown
  quietly, it is dropped — while FCM answers 200 with a message name and
  the register says the handset is live. `send-push` names `chat`,
  `PushService` draws a call on `calls`, and they are two files in two
  languages in two directories. `scripts/check_push_channels.py`
  compares the two lists on every run, which is the only thing that can.
- **`deleteToken()` mints a new one.** Pressing Turn off took the row
  off the register; the next status read asked for the token; and
  `getToken` on a handset that still has permission issues a FRESH one.
  So the card read "on" for a handset nothing would ever reach again. An
  off switch is now a fact about the installation, kept locally and
  cleared by registering.
- **`notConfigured` is not `unsupported`.** `google-services.json`
  cannot live in this repository, so the Gradle plugin that reads it is
  applied only when the file is present. The copy for the two states had
  to be swapped as well: the old sentence sent somebody off to create a
  Firebase project for a phone that can never use one.

**And a widget test HUNG for ten minutes.** A `testWidgets` case that
reaches an unmocked method channel does not fail — fake async never
delivers the reply, so it stops. The coverage lives in
`push_native_test.dart` instead, where the channel is mocked, and the
trap is written into `docs/widget-tests.md`.

### Three red runs in a row, each a different fault

`0727` took runs 2183, 2184 and 2185 to land, and not one of them was
the same mistake twice. Worth keeping because the THIRD is the one that
would have shipped something wrong rather than merely failed.

**2183 — grepping for a token is not grepping for the behaviour.**
`expense_split.sql` section 5 was "An expense paid in cash": it posted
with a null bank account and asserted the credit landed on `1120` and
that no bank balance moved. Both true; together the bug. My check before
pushing was `grep bank_account_id` on that file, which MATCHED — on the
helper's signature and on a comment. The mechanical version is three
lines: parse the seventh argument of every `pg_temp.an_expense(...)` and
the column list of every bare `insert into public.expenses` in a file
that posts. Over all of `supabase/tests` it finds exactly the two
fixtures that posted without one.

**2184 — the door was already bolted.** A new block asserted that
`0727`'s `org_id` scoping refuses another company's bank account. It
cannot: `0160`'s `expenses_bank_account_same_org` foreign key means such
a row cannot be INSERTED, so the posting is never reached. `0727`'s own
header had claimed the account "would have resolved and been credited",
which was false — corrected in place, which was legitimate only because
the migration had not been applied anywhere.

**2185 — a `comment on function` is PUBLISHED.** `docs/api/` is
generated from the schema: a function's summary is the first sentence of
its comment and its description is the whole comment. `0727` replaced
`post_expense`'s comment outright with one sentence about the new
refusal, so the published description would have gone from documenting
four refusals to one. The other three are all still true — nothing
removed them, the comment just stopped mentioning them. **Extend such a
comment; never rewrite it.** `0728` follows that rule for five
comments, and `0571`'s wording is the base.

### The expense screen, end to end

`1eafa71b` and `78ae9817`, both from the user looking at a screen and
asking why it said nothing.

- The detail dialog now says which account the money left, in three
  states, and the third is the one worth building for: a named bank
  account; nothing at all where the expense is not posted, because no
  journal exists and naming an account would be a claim; and the
  heading, for a row posted before `0727`.
- **Reverse, on the expense itself.** `0102`'s rule is the one to hold
  on to: a reversal POSTS THE MIRROR AND LEAVES THE ORIGINAL STANDING.
  It does not void it. Voiding and mirroring together leave the reports
  holding the opposite of the entry, which is how that was learned.
  `repository.dart`'s doc comment used to say "voids the original" and
  now says otherwise.
- `reEntryFields` carries the original's fields into a fresh dialog, so
  correcting a posted expense is reverse-then-re-enter rather than
  retyping it.

### The reconciliation shows the journal before it is agreed to

`597de7a1`. The "Post this line" dialog drew the account picker and
nothing else, so somebody posting a bank charge could not see which way
round the entry would go. `postingLegs` names both sides and
`_LegsPreview` draws them.

The contact picker there is fetched **in its own try/catch**, outside
the one that gates the dialog: a company with no contacts, or a contacts
query that fails, must still be able to post a bank charge to an
account. Refusing to open the dialog over a picker nobody has to use
would take the whole feature away to protect a nicety.

### THE LOCAL RUNNERS WORK IN THIS CONTAINER. USE THEM.

This file and `CLAUDE.md` have both said, in effect, that CI is the only
place the SQL assertions run, and an earlier session in this very
container concluded there was no Docker and therefore no local database.
**Half of that was right and the conclusion was wrong.** There is no
usable Docker here, and `supabase/tests/run_locally.sh` does not need
it: it builds its cluster with `initdb` directly, and this container has
`postgresql-16` and `pg_cron` installed and runs as root, which is
exactly what the script asks for.

So the whole gate set runs here in about four minutes:

    supabase/tests/run_locally.sh          # migrations, 382 files, every python gate
    supabase/tests/run_locally.sh --keep f.sql   # one file, no rebuild

It found, before any push, every one of the following: that `0728`
applies at all; the three fixtures that posted a payment or a deposit
with no bank account; that my first `settle_deposit` assertion was
premised on something false; that `docs/api/` needed regenerating; and
that three `date_trunc('year', current_date)` of mine had pushed
`check_test_clock.py` past its pinned budget. Every one of those would
otherwise have been a red run — and runs 2183, 2184 and 2185 of this
same session were exactly that, three reds in a row for faults a local
run would have caught in minutes.

Two things to know when using it:

- **Put `flutter` on `PATH` or `check_xlsx.py` fails for want of it**
  (`export PATH=/opt/flutter-3.47.4/bin:$PATH`). The failure is a
  `subprocess` traceback and names nothing about Flutter.
- The DB url the guards want is
  `postgresql://postgres@localhost/postgres?host=/var/tmp&port=5599`.

It is still not Supabase and still not a reason to skip CI — its own
header says where the `auth` and `storage` stubs stop being the real
thing, and one of them is MORE permissive than CI. Believe the hosted
run. But find the fault here first.

### A green SQL assertion can be green for the wrong reason, and 380 were

`0727` closed one 1120 fallback. `0728` found the same shape in five
more functions, which raises the obvious question: how, with 380 files
of assertions running in CI — the count on the morning this was found —
had none of them noticed?

Because **every fixture in `supabase/tests/` that needed a bank account
hung it on account 1120 itself**:

    insert into public.bank_accounts (org_id, account_id, ...)
    values (v_org, (select id from public.accounts
                     where org_id = v_org and code = '1120'), ...)

1120 is "Bank Accounts" — postable, but the heading that
`upsert_bank_account` puts the real accounts beneath in the range
1121–1199. With the fixtures written that way, "the function used the
account it was handed" and "the function fell through to the heading"
are the SAME ROW, and no assertion can tell them apart. `deposits.sql`
even asserted *"the money leaves the bank"* by checking the credit on
`code = '1120'`, which was true either way.

How wide the blind spot is, measured rather than guessed: **69 fixture
sites across 29 files** hang their bank account on 1120 — a trigger
refusing it fails 29 of the 382 files. That sweep is still to do, and
has its own paragraph in the 2 October section above.

`_helpers.sql` now has `pg_temp.test_bank_account(org)`, which does what
`0529` does — the next free code in 1121–1199, a child of 1100, the bank
account on that — and `pg_temp.a_bank_account(org)`, which reuses the
one already there. **Use them in new fixtures.** The 1121-1199 range is
only 79 codes wide, so a helper called once per invoice wants the
second one.

This is the twelfth entry for the list in `docs/widget-tests.md` and the
first that is about SQL rather than Dart.

### What `0728` deliberately did NOT do, and the question it leaves

**Read this with the 2 October section above:** `0728` was right about
what it left on purpose and wrong about what was left by accident. Two
posting paths it never examined are closed by `0729`, and the set of
functions permitted to mention `code = '1120'` is now asserted rather
than described.

`app.post_receipt_internal` still has the fallback, on purpose.

> **STALE — corrected 4 October. Everything in the rest of this
> subsection was true when written and is not true now.** `0731` replaced
> that fallback (it resolves an account and writes it onto the receipt,
> refusing only when the company has no bank account at all), and `0732`
> gave every tender type one. Measured in production on 4 October: **13 of
> 13 `pos_tender_types` carry a settlement account, none null.** Read
> "What `0731` actually does" above instead. Kept rather than deleted
> because the reasoning below is why `0728` left it, and that reasoning
> was sound on its facts.

**Eleven posted receipts in production have no bank account** — all
created 1 October, all from the counter, across five demo companies —
and **all thirteen `pos_tender_types` rows that exist have
`bank_account_id` null**, CASH and CARD and EWALLET alike. So every
counter sale in the product debits the 1120 heading today. Refusing
there would stop the till rather than correct it.

`0357` already met one corner of this and its header names the fallback
as the mechanism.

What is missing is a fact, not a refusal: **where each tender's money
lands.** Cash belongs in a till account — `bank_accounts.account_type`
has permitted `cash` and `ewallet` since `0003`, so a till is an
ordinary bank account with a ledger account of its own. A card and an
e-wallet are the real question: they settle into a bank account days
later, net of a fee, which this schema does not model and which cannot
be guessed from here. **That is a question for the user**, and it is the
next piece of this work.

`app.demo_legal_guaman` (`0549`) also still reaches for 1120. It is demo
data rather than a rule, and it is reseeded rather than migrated, so it
was seen and left.

### The sideways camera, three times in one day

The whole of it is further down, under **The incoming video was sideways,
and it was five missing lines** — put there because it belongs with the
calling work rather than with the accounting. The short version, because
the middle step is a trap worth meeting before you read the detail:

1. `df41280e` — an unconditional `RotatedBox(quarterTurns: 1)` on every
   remote camera. Asked for directly. Correct for a phone and wrong for
   a desktop browser peer, which rotates pixels before sending.
2. `50d6c23f` — **the actual cause.** `RtpCapabilities.toMap()` in
   `mediasfu_mediasoup_client 0.1.4` serialises the codecs and silently
   drops every header extension, so the server built every consumer
   against an empty extension list and stripped
   `urn:3gpp:video-orientation` from every incoming stream. Five missing
   lines in somebody else's serialiser, found by reading it rather than
   by measuring a call.
3. `ca2386b1` — the stopgap removed, and **its absence asserted**,
   because with the rotation arriving natively a `RotatedBox` draws an
   upright picture 90° out the other way.

`scripts/check_rtp_capabilities.py` is what keeps step 2 in place:
`device.rtpCapabilities.toMap()` is what every mediasoup example in
every language writes, and nothing in the widget suite can reach that
call site.

### The one inconsistency, and why it is right

`post_expense` refuses a null bank account outright, which the user
asked for in those words. The three deposit and cheque functions refuse
it too. But a **forfeited** deposit still names no account, because no
money moved — so `settle_deposit` refuses on `refund` only, and
`deposits.sql` asserts both halves. A refusal with no paired success is
satisfied by a function that refuses everything.

## The 28 September session

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

> **STALE — corrected 4 October, and this one contradicted the
> correction table at the top of this file, which had already recorded
> it.** `post_bank_transaction` makes a bank line into a journal
> (`p_source => 'bank_transaction'`) and passes `matter_id` onto the
> lines — deliberately NOT onto the bank's own leg, which its header
> explains. So a `bank_transactions` row does reach `gl_lines`, and it
> does carry a matter. `postBankTransaction` in `repository.dart` takes
> `matterId`, and the "Post this line" dialog in
> `reconciliation_screen.dart` is the picker this paragraph says there
> would be no line for.

~~The paragraph above was true when it was written and is NOT true
now.~~ `Repo.postBankTransaction` and the "Post this line" dialog
(`reconciliation_screen.dart:384`) post a statement line STRAIGHT to an
account, writing `gl_lines` from a `bank_transactions` row — and
`0723` put a matter picker on that very dialog. So the reasoning for
"there is nowhere on it to put a matter" has been overtaken, and the
matter picker is there. Left in place rather than deleted because the
argument it makes about MATCHED lines is still right: a line matched to
a receipt takes its matter from the document, not from the line. This
is the fifth entry caught by the rule at the top of this file; it cost
one grep.

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

   **The Android app half is now built** — `Push.kt`, `PushService.kt`
   and the Android branch of `push_native.dart`. What is missing is
   purely the Firebase project, and it is TWO files from the same
   console that have to be set together: the service account JSON into
   Supabase as `FCM_SERVICE_ACCOUNT`, and `google-services.json` into
   GitHub Actions as `GOOGLE_SERVICES_JSON`. Either one alone is a
   half-built system that reports success: the server holds a key for
   an app that registers nothing, or the app registers a handset the
   server reports as `skipped`.

   The Gradle plugin that reads `google-services.json` is applied
   **only when the file is there**, so every build without it still
   compiles the whole Firebase client and reports push as
   `notConfigured` at run time. Which also means the first build that
   ever applies that plugin is a release build — see the note in
   `docs/push-notifications.md` if it refuses the AGP version this
   project pins.

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

## The incoming video was sideways, and it was five missing lines

**Fixed at the cause.** The diagnosis below was right about the
mechanism and wrong about where the mechanism broke, and the difference
is worth keeping because the wrong half is the more natural guess.

### What it actually was

`RtpCapabilities.toMap()` in `mediasfu_mediasoup_client 0.1.4` is, in
full:

    Map<String, dynamic> toMap() {
      return <String, dynamic>{
        'codecs': codecs.map((c) => c.toMap()).toList()
      };
    }

It serialises the codecs and **silently drops `headerExtensions` and
`fecMechanisms`**. `RtpHeaderExtension` has no `toMap` at all, so the
package cannot serialise one even when asked.

A mediasoup client sends that set exactly once, at `join`, and the
server uses it to decide what each CONSUMER may carry. Sending no header
extensions had the server build every consumer against an empty list and
strip every extension from every stream this device received —
`urn:3gpp:video-orientation` among them, without which a receiver draws a
phone's raw landscape sensor frames. Nothing errored: mediasoup treats a
missing `headerExtensions` as an empty one, so the call connected and
audio and video flowed.

So it was never a widget problem, and never the libwebrtc capability
round-trip the section below suspected. `app/lib/src/features/chat/call_rtp.dart`
holds `rtpCapabilitiesToMap`, which serialises the whole set and drops
only entries the server would reject (no uri, no `preferredId`, or a
`kind` of `data`) — because a rejected capability set is not a sideways
picture, it is a refused `join` and no call at all.

### Why the guess was wrong, and what it cost

The earlier reading was *"mediasoup computes a consumer's header
extensions from the consuming peer's `rtpCapabilities`, which come from
a dummy offer, and libwebrtc does not reliably advertise CVO on an offer
with no video sender."* The first clause is exactly right. The second
was an assumption about libwebrtc that was never checked against the
line of Dart in between — and that line was the bug.

It cost nothing, because the session that wrote it **declined to guess**
and said what measurement would settle it. That was the right call. What
settled it in the end was reading the package's serialiser, which is
cheaper than any device.

### The quarter turn is GONE, on the user's instruction

There were three versions of this in one day and the end state is the
simple one: **nothing in the widget tree turns a camera.** The tile
draws `RTCVideoView(peer.camera!)` as the frames arrive.

The two that came before it are worth knowing about, because the middle
one is the trap:

1. An unconditional `RotatedBox(quarterTurns: 1)` on every remote
   camera. Asked for directly, and correct for a phone — but it would
   have drawn a desktop browser peer sideways, since a browser rotates
   pixels before sending.
2. A per-peer turn, 0 or 1, off `CallPeer.cameraCarriesRotation`, read
   from the consumer's negotiated extensions. Correct in every case and
   now removed as well, because with the serialiser fixed the rotation
   arrives for everything that sends it and the branch had nothing left
   to decide.
3. No turn at all.

**Putting one back is the easy mistake, and it is now asserted
against.** `call_screen_test.dart` has four cases requiring no
`RotatedBox` anywhere — the camera tile, two tiles in a grid, the
self-view and a shared screen — and a mutation run putting the stopgap
back in four shapes kills all four. With the rotation arriving natively
a `RotatedBox` here draws an upright picture 90° out the OTHER way, so
the absence is the assertion.

One thing deliberately NOT asserted in those cases: `Transform`.
Material builds four of its own in that tree (the floating button and
the ink effects), so `findsNothing` fails on widgets this file has no
opinion about and a count would pin somebody else's implementation.
`RotatedBox` is the widget this screen would reach for and the one
Material does not use.

The engine still asks the consumer whether the rotation arrived, and
nothing branches on the answer — it is logged. If that line ever
appears, that peer's video is 90° out and the reason is that the
rotation did not survive the trip. That is the only remaining way this
failure can be seen, since it otherwise looks exactly like a working
call.

### `scripts/check_rtp_capabilities.py`, and why a gate

The fix is ONE call site and nothing in the widget suite can reach it:
`CallEngine` is an interface precisely because the real one needs a
camera, a network and an SFU. `app/test/call_rtp_test.dart` proves
`rtpCapabilitiesToMap` is correct and proves the package's `toMap` loses
the extensions — its first assertion is about the package, so a later
version that fixes it fails that test and the failure is the notice that
the helper can go — but no test can prove the engine calls the right one.

Reverting that line would restore a user-visible bug silently, with a
green suite, and `device.rtpCapabilities.toMap()` is what every mediasoup
example in every language writes. So the call site is a gate. Its
self-test puts the revert back in four shapes, checks a COMMENT naming
the lossy call is not mistaken for one, and checks that an engine
serialising nothing at all fails too.

**And the self-test caught a harness error in its own first draft**: it
invoked the real gate rather than the copy in its scratch tree, so every
case was answered from the real repository and the whole run said
nothing. Every case failed at once, which is the only reason it was
visible. The same failure with the polarity reversed would have been a
clean sweep over nothing.

### What is still not proved

That the extension is in this platform's receive capabilities at all. The
fix sends whatever the device advertised; if a platform never advertises
CVO, there is nothing to send and `cameraCarriesRotation` stays false,
which is the stopgap's behaviour and visibly correct for a phone. The
one thing a real call now tells you for free is which case you are in —
the console says so.

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

## Half a fix is a new bug: run 2178

`920c8013` moved the report window in
`supabase/tests/group_trial_balance_shapes.sql` onto the Kuala Lumpur
clock and **left the fixture dates on `current_date`**. Run 2178 went
red on:

    FAIL money that moved after the period is not in the report at all,
         however recent it is: expected 0, got 1

Because on 30 September UTC the window then closed on **30 September**
(the last day of last month in KL, where it is already 1 October) while
the entry that must fall OUTSIDE the window was dated `current_date` —
**30 September**. It landed on the boundary and was counted.

Leaving both clocks alone would have passed. The file was made more
correct and broke.

The fix is `v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date`
and every date in the file derived from it. `v_to` is the last day of
last month on that clock and `v_today` is always inside this month, so
the entry is strictly after the window **by construction, on every day
of the year** — which is better than the arithmetic it replaced even
ignoring time zones.

### The ratchet this earned

`check_test_clock.py` now also counts **files naming both clocks in
code** — the Kuala Lumpur expression somewhere and a bare `current_date`
somewhere else — and pins the number at **27**. It may fall; it may not
rise.

Most mixing is harmless: a `current_date + 7` beside a KL-derived fiscal
year is two independent facts, not a comparison. What is not harmless is
half a fix, and a new file starting to mix is exactly what half a fix
looks like. **This ratchet would have fired on `920c8013` itself** —
that commit took three files from one clock to two — and the advice it
prints is the advice that would have prevented 2178: put the whole file
on one clock.

It is a budget rather than a ban because converting all 27 is not this
change's job, and a gate whose backlog is the point is a gate nobody
believes.

### Three runs, three different failures

2176 pos.sql, 2177 demo_rebuild, 2178 group_trial_balance_shapes — and
only the third was caused by the fix before it. Worth being precise
about which is which rather than reading a run of red as one problem
resisting three attempts.

## The assertion count had a hole in it, and the hole was five files

`run_locally.sh` holds a floor under the number of assertions that
**actually ran** — counted off the `NOTICE:  ok ` lines psql prints,
raised from 0 to a measured **14,257** and now **14,276**. It is the
suite's only guard against an assertion that quietly stops being
reached: a fixture moves, a branch is never entered, and 383 files still
report green over fewer checks than yesterday. 383 files passing is not
the same claim as 14,276 assertions holding.

Five files contributed **nothing** to it, because they were written
entirely in the other idiom:

```sql
if <the bad thing> then
  raise exception '<what went wrong>';
end if;
```

That asserts perfectly well and says nothing on success. So a skipped
assertion in one of those five could not move the number, and the floor
could not see the file at all.

### I was wrong about whether it mattered

The first thing I did was look for a reason not to bother, hypothesising
the five were schema-shape files where a skipped assertion is low risk.
**They are not.** `matter_on_a_document.sql` has 22 inserts over 7
fixtures and **zero** catalog reads; `scan_inbox.sql` has 8 inserts over
7 fixtures and zero; `tenant_foreign_keys.sql` has 71 inserts. Every
assertion in them depends on a fixture, which is precisely the kind that
stops being reached without anything going red. The hypothesis was
checked before it was acted on, and it failed.

### What was converted, and what was proved about it

`matter_on_a_document.sql`, 19 sites, to `check_eq` / `check_true` — the
idiom the other 378 files use. +19, predicted before the run and
measured after, which is the check that nothing else moved at the same
time.

Converting a condition by hand is where an **inversion** hides, and a
green suite does not show one: `if v_n <> 0` becoming
`check_eq(label, v_n, 1)` passes nothing and still reads green if the
value happens to be 1. So every converted assertion was then mutated —
expected value perturbed one site at a time, 18 of them, with a no-op
control — and **all 18 failed as they should**. That sweep is the actual
evidence the conversion is sound. The suite passing is not.

### A second finding, which turned out to be nothing — recorded anyway

The bare form raises **P0001**, which `when others` CATCHES. The helpers
raise **P0004**, which it does not, and `_helpers.sql` devotes a long
header comment to why that matters: the suite's refusal-marker shape is

```sql
begin
  perform <the thing that must be refused>;
  raise exception 'FAIL: it was not refused';
exception when others then ...
end;
```

and with P0001 the marker is eaten by the handler immediately below it,
so the test passes BECAUSE it failed. That is a real defect this project
has already paid for once, in `create_contra`.

I swept all 383 files for it. **Zero** bare raises sit under a
`when others then null` arm — the shape where the assertion cannot fail
at all. 137 sit under a `when others` arm that does
`get stacked diagnostics` and matches the message, which is the
documented-fragile shape, not a dead one: the marker's own message does
not match the `like` pattern, so `check_true` raises P0004 and escapes.
So: latent, not live, and latent is where it should stay.

**The first version of that sweep reported 149 and was wrong.** It
walked back from a `when others` line to the nearest enclosing `begin`
without resolving nesting, so it attributed every `raise` in between to
a distant handler — `platform_console.sql`'s handlers are
`when sqlstate '42501'`, not `when others`. This is the seventh
appearance this session of *matching text is not checking meaning*, and
the first where the fault was in how the text was attributed rather than
in the pattern. **A detector's own output is a claim that needs checking
before it is reported**, which is the only reason the 149 never reached
anybody as a finding.

### The ratchet, which reached zero the same session

`scripts/check_counted_assertions.py` fails on a file that prints
nothing when it passes. It shipped holding four — `attachment_content_hash`,
`scan_inbox`, `search_path`, `tenant_foreign_keys` — as a reviewed list
with a reason each, and **those four were converted immediately
afterwards, so `UNCOUNTED` is now `{}`**. It fails **both ways**: on a
new such file, and on an entry whose file now prints, because an excuse
nobody prunes is not evidence.

A reviewed list at zero has one failure mode the four-entry version did
not: **an empty collection agrees with every per-entry assertion**, which
is a trap this session hit once already. So the self-test asserts the
zero state as both halves — no silent file in the suite AND an empty
`UNCOUNTED` — names all five converted files with the tick count each
must keep, and proves the finder still finds by feeding it a silent file
at the same moment the real suite is clean.

It does **not** prove a file with a countable source actually runs it: a
`check_eq` inside a helper nobody calls reads as countable here and
contributes nothing at runtime. The runtime floor catches that. Two
mechanisms, neither sufficient alone, and the docstring says so rather
than implying the gate is stronger than it is.

The gate's own self-test has 17 assertions and was mutated with 9
mutants plus a control: all 9 killed. The sharpest assertions are about
`strip_comments`, because a gate that greps raw text for
`pg_temp.check_eq` is satisfied by a **comment** naming it — which is the
same defect as the `1120` one that cost a wrong recommendation to the
user earlier this session.

**No Python mutation harness exists in this repository.** `mutate.py` is
hardwired to `flutter test` under `app/`, and `mutate_sql.py` is for SQL;
the Python gates' mutation sweeps have all been ad-hoc inline loops. If
one more gets written, that loop is worth promoting to
`scripts/mutate_py.py` — and it must clear `scripts/__pycache__` between
runs and pass `-B`, or two same-sized mutants in one mtime second share a
`.pyc` and the second is reported as surviving code it never ran.

### ~~Next, if this is picked up~~ — DONE, same session

The paragraph that stood here said the remaining four were the next
thing to pick up. They were converted immediately afterwards and the
ratchet is at **zero**. Left marked rather than deleted, because a
handoff that silently rewrites its own open items teaches a reader to
distrust the ones still open.

| file | ticks | how |
|---|---|---|
| `matter_on_a_document.sql` | +19 | `check_eq` / `check_true` |
| `scan_inbox.sql` | +24 | same, plus two refusal markers that KEEP their shape and tick in the handler |
| `attachment_content_hash.sql` | +13 | `check_true` on the catalog shapes |
| `tenant_foreign_keys.sql` | +14 | probe counters became **exact** `check_eq`, not `< 29` floors |
| `search_path.sql` | +3 | plain `raise notice 'ok …'` — see below |

**14,257 → 14,276 → 14,330.** Each step predicted before the run and
measured after. That is the actual check: a conversion landing on a
different total than its own arithmetic has changed something it did not
mean to.

**67 mutants, 67 killed, controls clean on every file.** 18 + 22 + 13 +
12 on the converted checks, 3 on `scan_inbox`'s refusal-marker handlers,
2 on `search_path`'s census floors.

Two of those sweeps need a note, because I read their output wrongly
first. Mutating `scan_inbox`'s two handlers to catch the wrong sqlstate
printed `SURVIVED` under my own harness — and both were kills. With the
handler no longer catching, the **product's** exception escapes
("Nothing scans into payroll_runs"), not my marker, so the message I had
told the harness to look for was the wrong one. **My expectation was
wrong, not the test.** A harness that reports a kill as a survivor is the
safe direction to be wrong in, which is the only reason this cost
minutes.

### Two decisions inside that work worth keeping

**`search_path.sql` was deliberately NOT converted to the helpers.** It
has no transaction and does not include `_helpers.sql`; it is a read-only
catalog query, and `_helpers.sql`'s fixtures write to `auth.users` when
called, with no rollback to undo a mistake. Adding both a transaction and
an include to gain a helper risks more than it buys. A notice after an
untouched `if` cannot change what is asserted.

**`tenant_foreign_keys.sql`'s probe counters went from floors to exact
counts.** It ran 3 probes against `v_tried < 3` and 29 against
`v_tried < 29` — zero slack today, but a floor is the wrong shape here:
when a probe stops being reached, `v_tried` and `v_refused` fall
TOGETHER, so `v_refused <> v_tried` stays false and only the floor
notices. `check_eq(…, v_tried, 29)` fails in the file and names it.
Adding a probe now means raising that number, and the friction is the
point.

## The floor I had just raised was enforced nowhere

Immediately after taking the assertion count to 14,330 I went looking for
what else was wrong with it, and found the thing that mattered most:
**`run_locally.sh` is not run by CI.** CI has its own loop in `ci.yml`
over a hand-kept list of the same 383 files, and that loop **counted
nothing at all.**

So the state after two commits of work was: "every assertion file ticks"
enforced in CI, and "the ticks add up to 14,330" enforced only on the
machine of whoever remembered to run the script. A floor nobody runs is
not a floor. This is worth stating plainly because the two commits read,
from their messages, like the job was done.

### Why the loop had been left alone, and why that reason was right

The previous note on this said: do not add counting to CI's loop without
`set -o pipefail` and a way to prove it. That was correct and specific.
The step runs under `bash -e` with **no `pipefail`**, so

```sh
psql "$DB" -v ON_ERROR_STOP=1 -f "$f" | tee /dev/null
```

hands the shell `tee`'s exit status, and **a failing assertion reads as a
pass**. Adding a `| grep -c` to count would have silently disarmed the
entire SQL suite in the one place it is authoritative.

The way round it is not `pipefail` but no pipe:

```sh
out="$(psql "$DB" -v ON_ERROR_STOP=1 -f "$f" 2>&1)" || {
  printf '%s\n' "$out"; echo "::error::$f failed"; exit 1; }
printf '%s\n' "$out"
n="$(printf '%s\n' "$out" | grep -c 'NOTICE:  ok ' || true)"
```

Command substitution keeps psql's own status for the `||`. The pipe that
remains is over a `printf` of a variable, where nothing can fail.

### The proof, because "it should work" is not one

The step was **extracted out of `ci.yml` by parsing the YAML**, its first
line (the `supabase status` lookup) swapped for the local connection
string, and run under `bash -e` exactly as Actions does:

| case | result |
|---|---|
| the real 383 files | exit 0, **14,330** — identical to `run_locally.sh` |
| a deliberately failing assertion spliced into the list | **exit 1**, with the file named |
| a file named in the list but absent from disk | **exit 1** |
| every file replaced by one that asserts nothing | **exit 1**, "printed no `NOTICE:  ok ` lines at all" |

The third case is worth keeping: psql says `psql: error: ... No such file
or directory` in **lower case**, which `run_locally.sh`'s grep for
`ERROR:` does not match — it needs a separate `[ ! -f ]` pre-check for
that. Using the exit status covers it with nothing extra, so CI's version
is stronger than the local one on that point.

### ~~The floor is NOT compared in CI yet~~ — MEASURED, and now compared

The paragraph here said CI would print its count and gate only on zero,
because CI runs a real Supabase stack where `run_locally.sh` stubs `auth`
and `storage`, so the two counts were not *known* to be equal — and
guessing a threshold on the branch that deploys to production is the
wrong way to find out. It left an instruction: read the number off the
next green run and compare before gating.

**Run 2239 (`2dbaa802`) is green and reported `assertions executed in
CI: 14330` against a local floor of 14330.** Identical. The stubs make no
difference to the count, which is worth knowing in itself — it means the
two runners can keep sharing one number.

So the comparison is in, and it is measured rather than guessed. Left
marked rather than rewritten, because the two-step was the point: the
same shape as `9626249f` counting with the floor at 0 and `a30af282`
setting the measured 14,257.

The step now has three guards, each proved by extracting the step out of
`ci.yml` and running it against the local cluster:

| case | result |
|---|---|
| the real floor | exit 0, "assertions executed in CI: 14330 (floor: 14330)" |
| floor raised to 99999 | **exit 1**, naming the dip and refusing to lower the floor |
| floor file with no bare integer | **exit 1**, "no floor to compare against" |

The third needed care. My first attempt at it ran
`grep -v '^99999$'` over a backup that holds **14330** — so it stripped
nothing, ran with a valid floor, and would have passed. I would have read
that pass as a statement about the guard. **Ninth instance this session
of a pattern that matched nothing being mistaken for a finding.** Tested
properly by pulling the guard out of the step with the YAML parser and
running it against a genuinely malformed file: exit 1, and the
"reached the end" sentinel never printed, so the guard fired rather than
falling through.

`check_assertion_floor.py` now also asserts that the step **compares**
the floor and does not merely read it to print it — those two read
identically from outside, and the step shipped read-only for exactly one
run. Two mutants on that assertion, both killed: dropping it, and
weakening it to "mentions the floor somewhere".

### One definition of the number

`supabase/tests/assertion_floor` now holds it, read by both runners.
Two copies would have drifted the first time one was raised.

A `grep -Ex '[0-9]+'` over a malformed file yields the **empty string**,
and `[ "$n" -lt "" ]` is not a comparison that fails loudly — so both
readers check for a bare integer first. Verified: with the number removed
from the file, `run_locally.sh` exits **2** saying "refusing to run with
no floor at all". (The first time I measured that I read `$?` after a
pipe and got grep's status instead — the very mistake this section is
about, made while writing it.)

`scripts/check_assertion_floor.py` asserts the plumbing, not the number:
one bare integer, above zero; both runners read the file and neither
hardcodes one; both count the same pattern; that pattern is what
`_helpers.sql` actually prints; the CI step does not pipe psql; it
initialises its counter; and the step is found **by name**, so renaming it
fails here instead of making the gate check an empty string.

**Its first version failed on the very step it describes.** The pipe
check was `psql "\$DB"[^\n]*\|`, and the capture line ends in `|| {` — so
a bare `\|` matched the first bar of a **logical OR**. Eighth instance of
matching text standing in for checking meaning, and the only reason it
cost nothing is that the gate was run against the file it was written
about before being believed. Both directions are now pinned in the
self-test: a real pipe is caught, `|| {` is not.

20 self-test assertions, 11 mutants plus a control, all 11 killed.

## Six gates could not tell a clean sweep from a sweep that looked at nothing

Having just found that the assertion floor was enforced nowhere, I asked
the generalisation: **what else exists but does not run, or runs but
checks nothing?**

Two clean negative results first, both worth having:

* **Every gate runs.** 62 `check_*.py` gates and 29 self-tests, all 91
  genuinely invoked in a `run:` block in `ci.yml` — checked by parsing
  the YAML and stripping `#` comments from the shell, because "named in
  ci.yml" includes being named in a comment. Zero run nowhere.
* **CI's test list is exactly the glob.** 383 entries, 383 distinct, no
  duplicates, nothing on disk unlisted. So one floor can serve both
  runners, which is what made the shared `assertion_floor` file safe.

### The finding

Of the 62 gates, **38 report what they examined and 24 do not.** A gate
that prints "No web-only API is called where a phone would reach it" and
nothing else cannot distinguish *looked and found nothing* from *could
not look* — and those are the same success line and the same green build.

Tested rather than assumed: each gate's scope constant was redirected at
an empty directory and its `main()` called. **Six passed over nothing:**

| gate | what it guards |
|---|---|
| `check_or_filters` | a user's name interpolated raw into a PostgREST `or()` — this shipped, and `SHAHARUDIN, SHAM SUNDER & PARTNERS` made every firm with a comma unsearchable |
| `check_web_only_apis` | `Uri.base.origin` on a path a phone reaches |
| `check_error_text` | a caught error shown as its wrapper rather than its message |
| `check_dialog_actions` | a `Spacer` in `actions:`, which throws at layout and draws a grey rectangle |
| `check_nested_scrollables` | an expanding viewport inside a scroll view on its own axis |
| `check_setstate_futures` | `setState(() => _x = future)` |

### The experiment had its own control, and needed it

`check_files_open_in_app` has the identical structure — `LIB` at module
level, `LIB.rglob` in `main()` — and **failed** under the same patch:
"FAIL only 0 files read storage as bytes". That is what proves the patch
reaches gates of this shape, rather than being ignored while the gate
read the real files and passed for the right reason. Without it the whole
sweep would have been unfalsifiable.

And it caught a false positive. `check_passkey_association` appeared to
pass over nothing, but it derives `ASSETLINKS = WELL_KNOWN /
"assetlinks.json"` at module level, so patching `WELL_KNOWN` afterwards
never reached it — and reading the code, it does fail when both files are
missing. **Not a defect.** Seven became six by checking.

### The fix, and why the floor is on sites rather than files

Each of the six now counts the sites **its own pattern matched**, prints
the number, and exits 2 below a floor. On sites, not on files read,
because pattern drift is the failure that actually happens — six times in
this session alone, in six different gates. A regex that stops matching
reports a clean sweep over a real directory full of files.

Proved on all six: empty scope → exit 2. And on `check_or_filters`,
separately, with the pattern deliberately broken to match nothing → exit
2, same message. Both failure modes, one guard.

| gate | measured | floor |
|---|---|---|
| `check_setstate_futures` | 1332 arrow-bodied setState assignments | 600 |
| `check_dialog_actions` | 430 `actions:` lists | 200 |
| `check_nested_scrollables` | 387 scroll-view constructions | 200 |
| `check_error_text` | 270 catch/onError bindings | 150 |
| `check_or_filters` | 8 `.or(` call sites | 4 |
| `check_web_only_apis` | 6 `Uri.base.origin` calls | 3 |

Set well below the measurement on purpose. The floor guards against the
pattern dying, not against the count moving by one: a gate that goes red
because somebody deleted a widget is a gate that gets deleted.

### Two things the work taught about its own method

**My probe disagreed with the gate, and the gate was right.** I measured
431 `actions:` lists; the gate reports 430, because it strips comments
first and one was inside one. The number in each gate is now counted by
the gate itself rather than by my re-implementation — a second
implementation that disagrees is the two-definitions problem in
miniature.

**A guessed floor failed, in the safe direction.** I put 300 on
`check_error_text` before measuring; the real figure is 270, so the gate
went red rather than silently green. Worth preferring that direction
deliberately: a floor guessed too high is a red build and a correction, a
floor guessed too low is a control that never fires.

### What the floors cost, and the hook they need

`LEAST` is read from `IAK_LEAST_SITES`, named after `IAK_ASSERTION_FLOOR`
which does the same job for the SQL suite. Nothing in `ci.yml` or
`run_locally.sh` sets it.

It exists because **four self-tests broke the moment the floors went in,
and they were right to.** They drive their gate over a fixture of one or
two files, which is below every floor by design — the floor is a claim
about `app/lib`, not about a temporary directory. The subprocess harness
in `check_or_filters_test.py` gets the environment variable; the
in-process harnesses patch `gate.LEAST` beside the scope they already
patch. `check_error_text_test.py` needed its two `offenders()` call sites
updated as well, since that function now returns the count alongside the
findings.

### Still open

**`check_dialog_actions` and `check_setstate_futures` have no self-test
at all**, so their new floors are verified only by the empty-scope
experiment above and not by anything that runs in CI. Of the 24 gates
without a count, **12 could not be driven by the experiment** because
they build their paths inside functions rather than at module level; they
are not cleared, merely untested by this method.

Both of those point at the same next piece of work: a meta-gate that
drives every source-scanning gate at an empty scope and requires a
non-zero exit, carrying a reviewed list of the ones it cannot drive and
why. That covers future gates automatically, which a per-gate test does
not. It is the generalisation this section is one instance of.

## Nineteen sweeps could not tell a clean result from an empty one

The six-gate finding above was the first pass, done by redirecting a
module-level scope constant. The fuller method reaches gates that build
their paths inside functions: build a tree holding `scripts/` and EMPTY
source directories, run each gate in it as a subprocess, and require it
to fail.

**Thirteen more gates passed over nothing**, for nineteen in total. And
the correction that matters most:

### Printing a count is not checking one

My earlier note said 38 of 62 gates "report what they examined" and
treated that as having a positive control. **That was wrong.** Three of
the thirteen print a number and pass anyway, because nothing compares it:

| gate | over an empty tree |
|---|---|
| `check_money_is_numeric` | "every money column is numeric (**0 migrations**, 0 allowed floats)", exit 0 |
| `check_dialogs_built` | "All **0** dialog and sheet openers are called by a test", exit 0 |
| `check_edge_cors` | "ok **0** edge functions, all on the shared CORS headers", exit 0 |

A number in the output looks like evidence and is not, unless something
refuses it. That is the twelfth variant of *matching text is not checking
meaning* — here, reading one's own output as a control.

### One of the nineteen was written this morning

`check_counted_assertions.py`, added earlier the same day, passed over an
empty `supabase/tests` printing **"every one of 0 assertion files says
something when it passes; the ratchet is at zero."**

Its own self-test *did* catch it — `test_it_looks_at_the_whole_suite`
asserts more than 300 files — so CI was covered while the gate alone was
not. Worth separating those two: a gate that only holds when its test
runs beside it is weaker than it reads, and nothing guarantees the pairing
except habit. It now has `LEAST_FILES = 300`, applied only to the default
scope so the fed fixtures in its tests still work, and exits 2 over an
empty directory.

### The gate, rather than nineteen fixes

`scripts/check_sweeps_look.py`. Nineteen is too many for one change, and
a per-gate fix does nothing for the twentieth gate written next week. The
gate makes the property the default: a new sweep must fail over nothing,
or be named with a reason.

Four buckets, each falsifiable **both** ways, which matters because every
excuse here is a claim that can go stale:

| bucket | n | what it must do over an empty tree |
|---|---|---|
| ordinary sweeps | 32 | report a problem |
| `NEEDS_A_DATABASE` | 10 | exit with a `usage:` line |
| `NEEDS_A_FILE` | 8 | raise `FileNotFoundError` for a named file |
| `PASSES_OVER_NOTHING` | 12 | pass — a ratchet that may only fall |

32 + 10 + 8 + 12 = 62, asserted in the self-test, because a gate in no
bucket would be checked by nothing — which is this gate's own subject.

### Its first run found two defects in itself

**It drove itself**, recursing until the timeout — and *reported* that
about itself rather than hanging, which is why it cost two minutes.

**It read `usage: ... <database-url>` plus exit 2 as "reported a
problem"**, so all ten database gates looked drivable. Non-zero for the
wrong reason is precisely the vacuous success this gate exists to refuse,
and the gate committed it on its first run. Hence four buckets rather
than two.

### And the mutation sweep found two more, in the test

Nine mutants, two survived the first time:

* **the mutant that deletes the usage branch entirely.** My assertion for
  it read `csl.verdicts.__doc__.count("usage:") > 0` — it tested the
  **docstring**. A test that reads prose about the behaviour is not a test
  of the behaviour, and this was the gate whose whole subject is that
  mistake. Now driven through `verdicts()` with a faked `drive`, over six
  cases including a traceback that also prints usage text (a crash, not a
  polite request for an argument).
* **the mutant truncating the remedy text.** The assertion checked a
  prefix that survived the truncation. Now pins the specific clause.

Second sweep: 8 killed, 0 survived, control intact.

### The ratchet, and what each entry needs

Twelve, each with a note saying what it would have to count and compare.
They are not one job: some need a floor on files globbed, some on sites
matched, and three only need to check the number they already print.

`check_captcha_tokens`, `check_capture_is_kept`, `check_current_org`,
`check_date_arguments`, `check_dialogs_built`, `check_edge_cors`,
`check_initstate_ref`, `check_loading_spinners`, `check_money_is_numeric`,
`check_narrow_rows`, `check_order_direction`, `check_token_rotators`.

### The ratchet fell to eleven the same session

`check_money_is_numeric` is done — statutory-adjacent, and it already
printed the number it needed to compare.

The floor is on **money-NAMED columns**, not on migrations read, because
that is downstream of all three ways the sweep can go quiet: the glob
returning nothing, `declarations()` drifting so it extracts no columns,
or `is_money_name()` drifting so none of them looks like money. A floor
on files would catch only the first. **453** money-named columns over 742
migrations and 5,419 column declarations; floor 250.

Proved both ways: empty tree → exit 2; `declarations()` stubbed to return
nothing → exit 2 with the same message. (Renaming `is_money_name`
outright gives a `NameError` instead, which is loud but not the floor —
worth knowing that the crude mutant and the realistic one take different
routes to red.)

**Its self-test already had the right instinct and the gate did not.**
`ItActuallyReadsColumns` carries the comment *"If this number is ever 0,
every other assertion in this file is theatre and the gate is passing
because it sees nothing"* — the same shape as
`check_counted_assertions`, where the test caught what the gate missed.
Twice in one day, so it is a pattern rather than an accident: when
somebody writes that thought down, it tends to land in the test, where
it only holds while the two run together.

Its harness now defaults `LEAST_MONEY_COLUMNS=0` because every case feeds
a one- or two-file fixture, and `TheFloorItself` passes the real floor
explicitly. Four new assertions, one of which pins the floor **between**
zero and the census: at zero it is not a floor, at the census it goes red
whenever a column is renamed.

One slip worth recording because it cost a confused minute: I appended
the new test class **after** `if __name__ == "__main__"`, so it was never
defined and the run reported 13 tests rather than 17 — passing, with four
assertions that did not exist. A test file that silently runs fewer tests
than it contains is the same defect class as everything else in this
section.

### Then two more, and the ratchet stands at nine

`check_edge_cors` (20 edge functions, floor 12) and
`check_dialogs_built` (128 openers, floor 80). Both already printed their
number and neither compared it — `check_edge_cors` said "ok **0** edge
functions, all on the shared CORS headers" over an empty
`supabase/functions`, which is a sentence that should be impossible.

`check_dialogs_built`'s harness turned out to capture **stdout only**,
so the floor message — which goes to stderr, as a failure should — was
invisible to it. The fix is worth noting beyond this one file: an
`assertIn` against a stream that was never captured fails loudly, but an
`assertNotIn` would have **passed for the wrong reason**. The harness now
captures both.

`check_edge_cors` has no self-test, so its floor is verified by the
empty-tree run and by `check_sweeps_look` in CI, not by assertions of
its own.

### Three more, and the distinction that matters for them

`check_captcha_tokens` (8 GoTrue call sites, floor 5),
`check_current_org` and `check_token_rotators`. The last two needed a
different shape, and getting it wrong would have been easy:

**A gate that expects to find NOTHING cannot be floored on its matches.**
`check_current_org` passes when no file outside `providers.dart` reads
`currentOrgIdProvider`; `check_token_rotators` passes when no draw path
rotates the token. A floor on matches would demand that offenders exist.
A clean codebase and a blind sweep give the same answer — which is why
both passed over an empty tree.

So two controls on the SWEEP rather than on its result:

| gate | floor on what it read | canary |
|---|---|---|
| `check_current_org` | 544 .dart files walked, floor 300 | `currentOrgIdProvider` must still match inside `providers.dart`, the one file the gate deliberately skips because the provider is **declared** there |
| `check_token_rotators` | 1,386 draw-path methods, floor 600 | `mfa.listFactors` / `auth.refreshSession` must still match **somewhere** in `app/lib` — the app does rotate the token, just not while drawing |

The canary is the better half. Rename the provider and the pattern stops
matching everywhere **at once**; the only way to notice is to check that
it still matches where it is supposed to. Both proved: renaming the
symbol gives exit 2 with a message that says *this is the canary, not a
defect in the app* — where before the gate would have reported "nothing
mistakes the switcher's selection for the current company" while matching
nothing anywhere.

That shape is worth reusing. A zero-expected gate wants a floor on what
it read **and** a positive match somewhere it should match.

### My probe disagreed with a gate three times today

431 vs 430 `actions:` lists, 10 vs 8 GoTrue calls, 5 vs 2 canary
references — every time because the gate strips comments or doc comments
first and my ad-hoc count did not. **Write down the number the gate
reports, never the one a re-implementation produces.** Three times in one
session is a rule, not bad luck.

### The ratchet reached zero: all nineteen are done

`check_capture_is_kept`, `check_date_arguments`, `check_initstate_ref`,
`check_loading_spinners`, `check_narrow_rows`, `check_order_direction` —
the last six. **44 of 62 gates now fail over an empty source tree; 10
exit on a missing database URL, 8 raise on a missing named file, and 0
pass over nothing.**

I was wrong in the note above about what these six needed: I said four
were zero-expected and wanted the floor-plus-canary shape. They are
zero-expected, but their patterns match **every site**, compliant or not
— 500 `Fmt.*` calls, 113 `initState` bodies, 36 `loading:` arms, 217
`.order(` sites, 521 ListTile constructions — so a plain census floor
works. The canary is only needed when the pattern matches **offenders
only**, which was `check_current_org` and `check_token_rotators`. Four
shapes, not two, and they are written out at the head of
`PASSES_OVER_NOTHING` so the next gate gets the right one:

| shape | floor on | examples |
|---|---|---|
| census — "N sites, all compliant" | N | captcha_tokens, edge_cors, dialogs_built, money_is_numeric |
| zero-expected, pattern matches all sites | sites examined | date_arguments, initstate_ref, loading_spinners, narrow_rows, order_direction, + the six given site floors earlier |
| zero-expected, pattern matches offenders only | what it READ, **plus a canary** | current_org, token_rotators |
| reads NAMED files, skipped them when absent | remove the `exists()` escape | capture_is_kept, order_direction |

### Two gates were turning absence into success, not just lacking a floor

`check_capture_is_kept` had **two** `exists()` escapes: `offenders()`
returns `[]` for a missing `scan_flow.dart`, and its canary was guarded
by `asked.exists() and ...`. Over a tree with neither file it printed
"ok a capture is kept until somebody asks for it to go".

Its test said that was deliberate — *"Renamed or moved. That is not this
gate's business to guess at, and inventing a failure would block the
rename."* That argument is right, and it is about `offenders()` not
inventing a **finding**. It is a different question from whether `main()`
may print a tick: refusing to claim the rule holds is not the same as
claiming it is broken. So `offenders()` is untouched — its test still
passes unchanged — and `main()` now exits 2 saying *this is NOT a defect
in the app, the file moved, point FLOW and ASKED at it*.

`check_order_direction` had the same shape in `if not tree.exists():
continue`. A moved tree now reports rather than skipping.

### The empty-list trap, for the third time in one session

With `PASSES_OVER_NOTHING` empty, two of the meta-gate's tests indexed
`sorted(PASSES_OVER_NOTHING)[0]` and raised `IndexError` — and **that is
the right direction to break in.** They failed loudly rather than passing
over nothing, which is the defect the whole gate is about. Both are now
driven from a **fed** entry, with a control asserting the same fed entry
passes when it behaves as the list says — otherwise they would be killed
by the feeding rather than by what they assert. Two more per-entry
assertions had gone vacuous and are now exercised against the fed entry
too.

### Harnesses patched, and why that keeps happening

Six self-test harnesses needed `LEAST = 0` (or an `IAK_LEAST_SITES`
override) because every one of them drives its gate over a fixture of
one or two files, which is below every floor by design. That is not an
inconvenience of the floors; it is the floors being claims about
`app/lib` rather than about a temporary directory. Two harnesses also
captured **stdout only**, so a floor message on stderr was invisible —
and an `assertNotIn` against an uncaptured stream passes for the wrong
reason.

### My probe disagreed with a gate FIVE times

431 vs 430 `actions:` lists, 10 vs 8 GoTrue calls, 5 vs 2 canary
references, 502 vs 500 `Fmt.*` calls, 219 vs 217 `.order(` sites. Every
time the gate strips comments or doc comments first and my ad-hoc count
did not. **Write down the number the gate reports.** Five times is not
bad luck.


## The ten gates the empty-tree sweep said it could not reach

`check_sweeps_look.py` excuses ten gates as `NEEDS_A_DATABASE`: they take
a database URL, so an empty SOURCE tree says nothing about them. That
excuse is honest and it is also a hole — the same defect class, in ten
gates, untested.

Tested now, by the one experiment that reaches them: a database that
**exists and has an empty schema**. `create database iak_hollow` on the
local throwaway cluster, zero functions and zero tables in `public`, and
each of the ten pointed at it.

**Four of the ten passed over nothing:**

| gate | what it said over an empty schema |
|---|---|
| `check_stable_writers` | "ok nothing declared STABLE or IMMUTABLE can reach a write" |
| `check_module_gates` | "ok every function checking two modules names them both" |
| `check_ambiguous_overloads` | "no two functions answer to one set of named arguments (**0 reachable**, 0 overloaded by name)" |
| `check_undocumented_writes` | "Every write a signed-in user can reach carries a `comment on function`" |

Six reported correctly, and `check_query_columns` had exactly the right
message already — *"only 0 relations in public — the catalogue query
cannot have…"*. That is the model for this bucket.

### The one that refines my own earlier work

`check_undocumented_writes` was given a positive control earlier today:
`undocumented(db)` returns **2 rather than 0** when psql fails. That
covered **the connection breaking**. It did not cover **the query
succeeding over nothing** — different holes, and only one of them was
shut. Worth being precise about rather than counting the earlier fix as
having handled it.

It is also zero-expected: `undocumented()` returns the offenders, so a
floor on its length would demand that offenders exist. The floor goes on
the **denominator** — every volatile `public` function `authenticated`
may execute, documented or not. 525 today, floored at 250, with the
census query kept beside `QUERY` so the two cannot drift apart quietly.

| gate | census | floor |
|---|---|---|
| `check_stable_writers` | 1,653 functions | 800 |
| `check_module_gates` | 842 rows | 400 |
| `check_ambiguous_overloads` | 824 reachable | 400 |
| `check_undocumented_writes` | 525 candidate writes | 250 |

All four now exit 2 against the hollow database and still pass against
the real schema; so do the other six, re-checked.

### Not automated, and why — plus what it would take

There is no gate driving this, deliberately. Automating it means a gate
that **creates a database**, and if that were ever pointed at the
production URL it would be a write to production, which the standing rule
forbids unless asked. The right design is clear enough to hand over:

* a uniquely named database, created and dropped in a `finally`;
* a **refusal to run at all unless the DSN is local** — a unix socket, or
  a host of `localhost`/`127.0.0.1`. Production is `*.supabase.co`, so
  the test is cheap and exact;
* a failure to create reported as "could not look", never skipped —
  otherwise the gate inherits the defect it exists to catch;
* the same four-bucket shape as `check_sweeps_look`, so an excuse that
  goes stale fails.

I left that unbuilt rather than bolting a database-mutating gate onto the
branch that deploys to production at the end of a long session. The four
fixes above stand on their own and are verified both ways.

**`iak_hollow` is still on the local cluster** (`/var/tmp/pgdata`, port
5599) if you want to re-run the experiment:

```sh
for g in ambiguous_overloads bank_account_types discarded_values \
         module_gates overload_assertions query_columns rpc_grants \
         stable_writers undocumented_writes write_doors; do
  python3 scripts/check_$g.py \
    "postgresql://postgres@/iak_hollow?host=/var/tmp&port=5599" \
    >/dev/null 2>&1
  [ $? -eq 0 ] && echo "PASSES OVER NOTHING: check_$g"
done
```


## The widget-test window: the trap was documented five times and gated once

Asked the day's question of the PRODUCT's tests rather than the gates:
which of them cannot fail? `docs/widget-tests.md` already names the
answer in its thirteenth entry — a widget test's surface is **800x600,
which is landscape**, so a screen laid out for a portrait phone can be
broken at every size a person holds and pass a file full of assertions
that only ever counted widgets.

457 test files; 117 set `physicalSize`, 18 measure with `getRect`.
Demanding all 457 set it would be wrong — a test that checks a widget
appears does not need a phone-sized window. But the doc names something
narrower and exactly checkable:

> `setSurfaceSize` resizes the RENDER SURFACE, so it does catch an
> overflow. It does NOT move `MediaQuery`, which goes on reporting 800 —
> so every `MediaQuery.sizeOf(context).width < 700` in the app still
> takes the DESKTOP branch, and a test asserting the narrow one is
> asserting against a layout that is not on the screen. **The shorter
> call is the trap.**

25 places in `app/lib` branch on a width threshold. **Five test files
carry a hand-written comment saying to use the other call** — the
decision written down five times and enforced nowhere. A comment is
advice to whoever reads the file, and nobody reads a file before writing
a new one.

### One real use, converted rather than excused

`scan_all_data_test.dart` resized to 1000x2400 so a lazily-built list
would construct every row, with a comment explaining why. Nothing there
asserted a narrow layout, so **the trap was not sprung** — and it was one
`MediaQuery`-sized sheet away from silently building only the rows that
fit 600 while believing it had 2400. It would not have failed; it would
have stopped looking at the rows it names. `tester.view.physicalSize`
drives both and cost two lines. All 14 tests in the file pass before and
after.

### `scripts/check_surface_size.py`

Zero-expected with a pattern matching only offenders, so it takes the
`check_current_org` shape from earlier today: a floor on what it READ
(457 files, floor 250) plus a **canary** — `tester.view.physicalSize`
must still appear somewhere, or the API was renamed and the gate is blind
rather than satisfied. Both proved: an empty tree exits 2, and renaming
the right call exits 2 saying *this is the canary, not a defect in the
tests*.

12 + 5 self-test assertions, 7 mutants, all 7 killed.

### Three things this one taught

**My first attempt at proving the comment-stripping proved nothing.** The
sample was prose — "not `setSurfaceSize`: it lies" — which has no paren,
so it never matched `TRAP` at all and reported 0 both stripped and
unstripped. The test now asserts the sample hits the pattern BEFORE
stripping, or it is not a test of stripping.

**Asserting a helper works is not asserting the caller calls it.** Two
mutants that removed `without_comments` from inside `offenders()` and
`census()` survived, because `ACommentIsNotACall` calls those helpers
directly. Both are now driven through the real functions over a fed tree
— which needed `offenders()` to stop raising on a path outside `ROOT`. A
gate that cannot be pointed at a fed tree can only be tested against the
real one, and then its failure paths are never exercised.

**One mutant is left alive deliberately, as EQUIVALENT:** widening `TRAP`
to the bare name `setSurfaceSize\b`. In this tree it changes nothing —
the only bare-name uses are comments, stripped either way — and flagging
a reference to the method in code is arguably right too. `mutate.py` is
explicit that a survivor is either a missing assertion or an unobservable
change, and saying which is the point.

### The meta-gate paid for itself here

`check_sweeps_look` picked the new gate up with no change to it: 44 of 62
became **45 of 63**, and the new gate had to fail over an empty tree to
get in. That is the thing a per-gate fix cannot do, and it was the whole
argument for building it.

### My probe disagreed with a gate a SIXTH time

`grep -rl physicalSize app/test` says 117 files; the gate says 106,
because 11 of those are comments. Same rule as the other five: write
down the number the gate reports.


## A row with the shape that shipped two overflows has never been laid out

`docs/widget-tests.md` is explicit about the limit of
`check_narrow_rows.py`: it measures a trailing `Column` by its `Money`
alone, so a wider second line contributes nothing to the estimate. Two
overflows shipped through that hole — `matters_screen` by 37 pixels and
payroll's `_RunTile` by 55 — and **both were found by pumping at phone
width, neither by either gate**. The doc's own conclusion: "the thing
that catches it is building the screen at 412x900."

So I went looking for the shape. **14 rows in `app/lib` have a
`trailing:` whose value is a `Column`**, two of them the already-fixed
pair. Of the fourteen, nine are pumped at 412 by some test, and two are
not: `asset_schedule_dialog` and `dashboard_screen`'s
`_ReceivablesCard`.

### The asset schedule note holds

Added a 412x900 pump to `asset_schedule_test.dart` — the only one of the
fourteen whose dialog no test ever laid out narrow. **It does not
overflow.** A clean negative, and the test stays as a guard: a
`RenderFlex` overflow is a test failure with no assertion required, so
this costs nothing to keep.

### `_ReceivablesCard`'s row has never been built at all

This is the finding. The row is

```dart
trailing: Column(children: [
  Money(outstanding, bold: true),
  if (daysOverdue > 0) Text('$daysOverdue days late', fontSize: 11),
])
```

— the documented shape exactly, and `'263 days late'` is wider than the
`Money` above it.

**Nothing in the test suite feeds `arAgingProvider`.** One file names it,
`live_updates_test.dart`, and only inside a provider-invalidation
assertion; it never renders the card. So that row has never been laid
out by any test, at any width.

`check_screens_built.py` counts `dashboard_screen` as constructed, and it
is right to: with `arAgingProvider` in its default state the card draws
**no rows**. This is the widget-test doc's **trap 11 hiding its trap
13** — opening it with nothing in it, so the window size never gets a
chance to matter.

### ~~I could not land the test~~ — LANDED, and the row is sound

The section below stood for an hour and is left marked rather than
rewritten, because what it got wrong is the useful part.

**The card is not on the Overview.** `ModuleDashboardPane` returns
`_Books` for the single code `accounting`, and the Overview never builds
it — which is why overriding `dashboardProvider` and pumping the Overview
gave a header and zero `Card`s. The path is: `modules: {'accounting'}`,
`labels` supplied (without them `codes` is empty and there is no picker
to tap at all), `panels: ['receivables']`, then `show(tester,
'Accounting')`.

**The row holds.** `module_surface_test.dart` now pumps it at **412 and
360** — both widths the rest of the suite uses, 360 being where
`timesheet_screen_test` and `document_list_screen_test` end their loops —
with a 43-character company name, a six-figure sum and a three-digit
overdue count. No overflow at either width.

**And the test catches one.** Lengthening the second line in the product
to `'263 days late and under formal demand'` fails it with
`trailing: RenderFlex … OVERFLOWING` out of `RenderFlex._computeSizes`.
So this is not a test that passes because nothing can fail it.

Two mistakes of mine inside that, both the same shape:

* The test first failed on **its own expectation** rather than on an
  overflow, because the fixture never reached the widget. That is the
  difference between a defect found and a harness that missed, and it is
  why the earlier version of this section claimed nothing.
* Verifying the forced overflow, I grepped the output for **"overflowed"**
  when Flutter's word is **"OVERFLOWING"**, and read a killed mutant as a
  survivor. Fourth time today that a non-match was my pattern rather than
  an absence — and the one time it mattered most, since it would have
  recorded a sound test as a useless one.

A Dart detail worth keeping: `show()` is a LOCAL function in that file,
so a test placed above its declaration fails to compile with "Local
variable 'show' can't be referenced before it is declared". The new block
sits after it.

### The original note, kept for the reasoning

`module_surface_test.dart` has a `dashboard(...)` harness and an
`onADesktop(tester, …)` helper — with no phone counterpart, which is part
of how this persisted. Adding `aging` and `dashboardProvider` overrides
plus an `onAPhone` helper got the screen to build its header and
**zero `Card`s**: the Overview's `AsyncView` never reaches its builder,
so more of its provider graph is pending than `dashboardProvider` alone
supplies.

My first attempt failed on **its own expectation**, not on an overflow —
which is the difference between a defect found and a fixture not reaching
the widget, and the reason this section does not claim an overflow. I
reverted the half-plumbed test rather than leave it in the tree.

**What it needs:** someone who knows the dashboard's provider graph to
list what the Overview's `AsyncView` waits on, then one test pumping
`_ReceivablesCard` with an overdue row at 412x900. The data to use, which
is the worst honest case: a long Malaysian company name, a six-figure
sum, and a three-digit overdue count, so the second line is the wider of
the two.

~~Until then: the row is unproven in both directions.~~ **Measured
now, and sound.** The guess in that sentence was right for the right
reason — the title carries `maxLines: 1` with ellipsis so the title side
cannot overflow — but a guess that happens to be right is still not a
measurement, which is the whole argument of this file.

### Two negatives from the same doc, recorded so they are not re-tried

* **Trap 7, `textContaining` on a prefix, is not gateable.** 784 call
  sites, 19 ending in a separator. A blanket rule carries a ~765 backlog,
  and most uses are legitimate long unique strings; the risk is specific
  to a prefix of a composed line, which is not statically distinguishable
  from a substring of a unique one.
* **The dead doubled-separator assertions are already gone.** The doc
  records four tests where a `'·  ·'` check could never fire; the three
  matches left in the tree are comments saying there is deliberately no
  such check.

### And a third time my own detector was wrong

My first pass said four of the fourteen screens set no window at all. It
was a literal-only regex, and three of them set `Size(width, 900)` with
width coming from a loop over `[1400, 1000, 800, 700, 600, 412, 360]` —
so they are tested at phone width and at 360. **A non-match meant a bad
pattern, not an absence**, for the third time today, and the corrected
count is two rather than four.


## `deno test` exits 0 over a file with no tests, and nothing counted

The morning's SQL work was: 383 files passing is a weaker claim than
14,330 assertions holding. The same question of the edge functions had
never been asked.

**Verified on deno 2.9.6**, which is the deno `check_locally.sh` fetches
from npm:

| case | exit |
|---|---|
| a passing test | 0 |
| a failing test | 1 |
| **a file that defines NO tests** | **0**, printing `ok \| 0 passed \| 0 failed` |

So a `Deno.test` block that stopped registering — deleted, commented
out, or left inside a condition that is never true — takes its
assertions with it and CI stays green. CI runs those files as **40
separate steps**, and not one of them counted anything.

(`--allow-none` is not a flag in deno 2.9; my first run passed it and
all three cases exited 1 on the flag itself, which looked like evidence
and was not.)

### The floor

~~`supabase/functions/deno_test_floor`~~
`supabase/functions/_local_check/deno_test_floor`, read by the new CI
step **Count the edge tests that ran** and by `check_locally.sh`.
**503**, measured. Moved, and the move is the next section — the first
spelling took `supabase start` down.

Proved five ways, by extracting the step out of `ci.yml` and running it:
the real list exits 0 at 503; a floor above the count exits 1; a floor
file with no integer exits 1; and — the case it exists for — **a
`Deno.test` block guarded off with `if (false)` drops the count to 502
and fails**, where all 40 per-file steps stay green.

### A file in supabase/functions/ breaks `supabase start`

Run **2251** went red on the commit that added the floor, and not on
anything about deno. `Statutory engine and ledger rules` failed at
**Start the throwaway local stack**, four attempts across two
registries, every one of them:

    BadResource: FileSystem.access
      (/home/runner/work/iakauntan/iakauntan/supabase/functions/deno_test_floor/index.ts)

A path that does not exist, naming a function nobody wrote. The CLI
walks `supabase/functions/` and reaches for `<entry>/index.ts` for every
entry it finds. A **directory** without one is skipped quietly —
`_shared` and `_local_check` have been there all along. A plain **file**
is not: the stat returns "not a directory", which the CLI does not
expect, and `supabase start` dies before the database is up. So the
commit that closed the edge-test hole took down the one job whose red is
this project's real failure signal, and the message pointed at neither.

Moved to `supabase/functions/_local_check/`, beside its reader. The
general rule is now asserted — `functions_dir_problems()` in
`check_assertion_floor.py` refuses **anything but a directory** directly
under `supabase/functions/`, because the next loose file will be a
`README` or a `.gitkeep` and will fail the same way. Proved on the real
tree, not only on a fed list: `touch supabase/functions/__probe` makes
the gate exit 1 naming it, and removing it exits 0.

### 503, not 467, and that mattered

The first version of the step globbed `supabase/functions/[^ ]*_test.ts`
and reported 467. `check_locally.sh` reported 503 over the same suite.
The difference is **three files outside `supabase/functions`** —
`cloudflare/email-router/mime_test.js`,
`cloudflare/workspace-proxy/route_test.ts`,
`scripts/play_upload_test.ts` — one of them a `.js` file.

A floor of 467 would have **passed, over a subset**, while reading as
though it covered everything. Caught by the two runners disagreeing,
which is the only reason I looked: one number from two places is a
cross-check, and this is what it is for. The list now comes off the
`deno test` command lines, as `check_locally.sh` always did, and the
guarded-off-block proof above was re-run against a **cloudflare** file
specifically — one of the three the first version dropped.

### Four false positives in my own new assertions, all one family

`check_assertion_floor.py` now covers this floor too. Getting its checks
right took four corrections and every one was the same mistake:

1. **"PIPES `deno test`"** matched the step's own COMMENT, which quotes
   `deno test ... | tee` while explaining why not to.
2. **"takes its file list from a narrow glob"** matched the comment that
   explains the glob it replaced.
3. After stripping comments, the pipe check matched the `grep -oE 'deno
   test...'` PATTERN — piped to `awk`. A string that mentions the thing
   is not the thing.
4. Stripping single-quoted strings fixed that and **blinded the glob
   check**, because the glob legitimately lives inside a quoted grep
   pattern. The mutant putting the narrow glob back went unflagged.

The fix is that the two checks get **different text**: comments stripped
for both, quotes stripped only for the pipe check. **One "cleaned" string
cannot answer two different questions** — which is the sharpest version
of the day's lesson, and I arrived at it by making the mistake four times
inside a gate written about it.

10 new assertions, 33 in that file now, and the five step-level cases
above each verified against a fed mutant.

### Two clean negatives from the same sweep

* **Every one of the 40 test files is genuinely invoked** on a `deno
  test` command line — checked by parsing the YAML and stripping `#`
  comments, since "named in ci.yml" includes being named in a comment.
  There is already a step asserting every file on disk is named, and it
  works.
* **`ask/wire_test.ts` is not a test with no assertions.** It showed 0
  under a grep for `assert*`/`.equals(`, and it has a hand-rolled four-line
  `eq()` instead — deliberately, because `jsr:@std/assert` would make it
  a file only CI can run, and `jsr.io` is unreachable from some machines
  this gets worked on. My pattern did not know the idiom. Fifth time
  today.

## The same question of the other two runners: `flutter test` and `npm test`

Two more layers of the day's question — *what does this check do when it
has nothing to look at?* — and both answered badly.

### `flutter test`: 6,638 tests behind a step that read nothing

Line 113 of `ci.yml` was

    - run: flutter test

for 2,251 runs. `flutter test` exits 0 when every test it FOUND passed.
It also exits 0 when it found fewer than yesterday, and the only number
that would say so is the `+N` at the head of its last progress line.

**Proved with a mutant, not reasoned about.** `contact_code_test.dart`
has three tests; `if (DateTime.now().year > 1) return;` above the third
is a test left after an early return. It compiles, the analyser is
silent, and:

    before:  00:00 +3: All tests passed!   flutter exit 0
    after:   00:00 +2: All tests passed!   flutter exit 0

The gate over the same two reports: `3 Dart tests ran (floor 3)` exit 0,
then `2 Dart tests ran; the floor is 3` exit 1.

#### The number is 6,638 and it is not the number flutter prints

Measured twice, twelve minutes a run, both `+6637 ~1`. `+` counts passes
and `~` counts skips **separately**, so the suite is 6,638.

The gate counts non-hidden `testDone` events out of
`--file-reporter json:`, never the console line. The report holds **465**
hidden events and none are counted:

* 457 `loading <path>` pseudo-tests, one per test file — exactly
  `find app/test -name '*_test.dart' | wc -l`;
* **8 more: four `(setUpAll)` and four `(tearDownAll)`.** They are
  reported as tests, they pass, they assert nothing, and the `hidden`
  flag is the only thing that separates them. 457 was the number I
  expected; 465 was the number there.

Counting hidden events would make the floor RISE when a file with no
tests in it is added, which is backwards.

#### One skip, and it is legitimate

`app/test/xlsx_sample_test.dart` calls `markTestSkipped` when
`XLSX_SAMPLE_OUT` is unset. It is a **fixture generator that happens to
be a test** — the only runner here that can compile code importing
`package:flutter` is `flutter test` — and `scripts/check_xlsx.py` sets
the variable, after which the same test writes the workbook the Python
gate reads back. It is counted either way, so the floor does not move.

Named in `SKIPPABLE`, keyed `test/<file>: <name>` and not by name alone:
test names here are group prefixes joined with a space and several repeat
across files, so a name-only key would cover a different test later.

#### The bug in my own gate that ten green assertions hid

    def floor_from(path: str = FLOOR_FILE) -> int | None:

A default argument is bound **when the function is defined**. The
self-test patches `gate.FLOOR_FILE` to a temporary file, and
`floor_from()` ignored it — every floor assertion was made against the
real file. They all passed for as long as the real floor file did not
exist, because `floor_from()` returned None, `main` exited 2, and the
tests expecting a refusal got one for the wrong reason. **Writing the
real floor turned ten of them red at once.** `floor_from` now takes the
path with no default, and `inspect.signature` asserts it stays that way.

A fed parameter the callee can ignore is not a fed parameter.

### `npm test`: the whole suite can vanish and the job is green

The sfu job's step was `- run: npm test`, and the package script is
`node --test test/*.test.js`. Probed on **node v22.22.2**, in that shell:

| what | prints | exits |
|---|---|---|
| the real two files | `# tests 33` | 0 |
| a file that defines no tests | `# tests 1` (node counts the FILE) | 0 |
| **a glob that matches nothing** | `# tests 0` | **0** |

So emptying `server/sfu/test/`, renaming the files out of `*.test.js`, or
moving the directory takes all 33 assertions about the call server's
protocol and token handling with it and the job goes green. Proved by
moving both files to `*.spec.js` and running the extracted step: `0 call
server tests ran and the floor is 33`, exit 1.

**The reporter is pinned.** node chooses `tap` when stdout is not a
terminal and `spec` when it is, and `spec` writes the same line as
`i tests 33`. A count that depends on what stdout is attached to is a
count that changes when the runner does, so `--test-reporter=tap` is in
the package script, and `node_problems()` asserts it is.

33 = 23 in `protocol.test.js` + 10 in `token.test.js`, subtests inside a
`describe` included and the four suites not counted.

### Four floors now, all defined once

| suite | floor | file | readers |
|---|---|---|---|
| SQL assertions | 14,330 | `supabase/tests/assertion_floor` | `run_locally.sh`, ci.yml |
| edge tests | 503 | `supabase/functions/_local_check/deno_test_floor` | `check_locally.sh`, ci.yml |
| Dart tests | 6,638 | `app/test/flutter_test_floor` | `check_flutter_test_count.py` |
| call server | 33 | `server/sfu/test/node_test_floor` | ci.yml |

`check_assertion_floor.py` asserts the plumbing of all four — 68
assertions in its own test file now — and `ci.yml` has neither a bare
`- run: flutter test` nor a bare `- run: npm test` left.

### And the sentence that counted wrong

`check_sweeps_look.py` said *"46 of 64 gates report a problem over an
empty source tree"*. The number was

    counted = len(found) - len(excused) - len(PASSES_OVER_NOTHING)

**arithmetic, not a tally.** `check_flutter_test_count` takes a report
path, exits 2 on a `usage:` line over an empty tree, is in no bucket —
and was counted among the 46 that "report a problem", which is the one
thing that gate's own docstring says must never count as looking. It was
the first gate to fall in; the hole had been latent since the ratchet
reached zero.

Two fixes: `counted` is now a tally of verdicts, and **any unexcused gate
whose verdict is not `reported` is refused** — `needs_argument` and
`crashed` included, where before only `passed_over_nothing` and `timeout`
were. A third bucket, `NEEDS_AN_ARGUMENT`, names what the argument is and
fails both ways like the other two. 45 of 64 now, and the 45 is counted
rather than computed.

One more vacuous assertion fell out of the same reading:
`test_every_gate_is_in_some_bucket_now_that_the_backlog_is_empty`
asserted `gate in excused or gate not in PASSES_OVER_NOTHING` — and
`PASSES_OVER_NOTHING` is **empty**, so the right-hand side was true of
every gate and the left-hand side was never reached. A vacuous test in
the file whose entire subject is vacuous success. It now drives the real
gates over a real empty tree and requires `reported` from each.

## The tests run — do they assert? Both suites surveyed, both clean

The floors above answer *did they run*. The next question is *did they
assert*, because a test block with no assertion is counted, passes, and
proves nothing — and a floor cannot tell it from a real one.

Surveyed by brace-matching each test's own body, following one level into
helpers defined in the same file, and treating a helper that **throws**
as an assertion helper as well as one that calls `assert*`/`expect`.

| suite | blocks found | with no assertion |
|---|---|---|
| `app/test` (Dart) | 6,340 | **1** |
| the 40 deno files | **503** | **1** |

Both survivors are legitimate and were read, not assumed:

* **`app/test/xlsx_sample_test.dart`** asserts nothing by design. It is a
  fixture generator that happens to be a test, and the assertions about
  what it writes live in `scripts/check_xlsx.py`, which reads the
  workbook back with `zipfile`, `xml.etree` and `openpyxl` — three
  parsers that know nothing about how it was written.
* **`supabase/functions/_shared/context_test.ts:167`**, "posting is
  owner, admin and accountant", calls `requirePostingRole` for each of
  three roles and asserts **that it does not throw**. That is a real
  assertion expressed without an assert call, and its control is the very
  next test: `assertThrows` for viewer, clerk, cashier and the empty
  role, checking the status and that the message names the role back.

**503 found by brace-matching is the same 503 the floor counts from
`N passed`** — two methods that share no code agreeing on the number.

### Three bugs in the surveys, all found by reading what they printed

The first run of the Dart survey reported **15** candidates and the first
run of the deno one reported **2**. Every one was the detector's fault:

1. **Expression-bodied callbacks.** `test('x', () => expect(y, z));` has
   no braces, so a scan for the body's `{` found the *next* block's and
   read three one-line tests as assertion-free. This is the same
   expression-body blindness `check_dialogs_built` once had, and whose
   test file says so in as many words.
2. **A brace inside a string.** Dart interpolation (`'... wide:
   ${at.wide}'`) and JS template literals put `{` inside the test's NAME.
   Brace-matching from there yields `{at.wide}` as the "body" — six tests
   full of `expect` calls reported as having none. Fixed by blanking
   string literals length-preservingly before scanning for structure,
   while still reading assertions out of the ORIGINAL text. Correcting it
   also raised the Dart block count from 6,323 to 6,340: a mis-matched
   body had been swallowing the seventeen tests that followed it.
3. **A helper that throws instead of asserting.**
   `platform-users/rules_test.ts` defines `function ok(condition, what) {
   if (!condition) throw new Error(what); }` and uses nothing else. The
   helper-following step looked for `assert*` in the helper's body and
   found none. An assertion is **something that can fail**, which is the
   rule now.

Both surveys were given a positive control before their result was
believed — a temporary file holding an assertion-free test, one asserting
directly, one asserting through a throwing helper, and one with
interpolation in its name. Each caught exactly the two that assert
nothing and cleared the two that do. `6,340 - 1` and `503 - 1` are
measurements, not the silence of a scan that stopped looking.

Neither survey is a gate. They answered a question and the answer was
clean; a gate over a backlog of zero would only be a file to maintain.

### And the third suite: 32 SQL assertions that cannot fail, all 32 right

The SQL suite's version of the question is different, because every
`pg_temp.check_*` call is an assertion by construction. What can go wrong
is an assertion that compares a thing to itself, or one handed a literal
truth — it ticks, it is counted, and it cannot fail.

Surveyed by brace-matching every `pg_temp.check_*` call across the 385
files, splitting its arguments at top-level commas with single-quoted
strings tracked, and looking for `check_true(label, true)`,
`check_eq(label, X, X)` and `check_true(label, X = X)`.

**12,880 call sites**, of which **32** cannot fail on their own reading.
Every one was opened and read, and every one is correct. Four idioms:

* **24 are the raise-expected pair.** `begin <the thing that must be
  refused>; check_true('FAIL ...', false); exception when
  insufficient_privilege then check_true('...', true); end`. If the
  statement succeeds the `false` arm fails the test; the `true` arm is
  the tick for the refusal arriving. One of these
  (`gateway_payments.sql:148`) labels its two arms differently, which is
  why a pairing rule keyed on the label alone left it over.
* **5 are aggregate-and-raise.** A `select string_agg(...) into v_bad` of
  everything wrong, then `if v_bad is not null then raise exception ...
  end if;` — and the `check_true(..., true)` after it is the tick that
  the `if` passed, exactly as `search_path.sql` ticks with a bare
  `raise notice 'ok ...'`. The assertion is the `if`; the helper call is
  the receipt.
* **2 call a function with side effects twice and compare.**
  `check_true('ensure_default_warehouse returns the same store',
  ensure_default_warehouse(v_org) = ensure_default_warehouse(v_org))`.
  Textually a thing compared to itself; in SQL two separate invocations,
  and that they agree is the whole definition of idempotent.
* **2 belong to `the_helpers_fail_loudly.sql`**: "a passing check_true
  does not raise" and "a passing check_eq does not raise". That file's
  other assertions prove the helpers raise when they should, and these
  two are the only thing standing between them and helpers that raise no
  matter what. Its own comment says so.

The sharpest of them is `sst_return_declares_what_was_charged.sql:228`,
which raises a sentinel inside the `begin` arm and then **re-raises it
from the handler** if that is the exception that arrived — so the handler
cannot absorb its own marker and tick anyway. That is the trap this whole
survey was looking for, already shut.

#### 12,880 call sites, 14,330 counted assertions

Not a contradiction. Many checks sit inside `for` loops and tick once per
row, there are 737 bare `raise notice 'ok ...'` ticks, and two files
(`expense_total.sql`, `view_security.sql`) tick that way without calling
a helper at all — which is why `check_counted_assertions.py` counts the
NOTICE lines rather than the call sites, and why the floor is on what
psql printed rather than on what the files say.

## 36 of 37 self-tests were run by CI, and the odd one out was the newest

The commit above added `scripts/check_flutter_test_count_test.py`, 27
assertions, passing locally — and **named it nowhere in `ci.yml`**. The
37 `*_test.py` files under `scripts/` are what makes the gates
believable, and they are run as a hand-kept list of `python3` lines. A
hand-kept list goes stale silently, and this one did on the very commit
that was about checks that cannot fail.

Found by asking the question of the gates themselves rather than by
noticing: `comm -23 <(ls scripts/check_*_test.py) <(grep -o
'check_[a-z_]*_test\.py' ci.yml)` — one line out, and it was mine.

`scripts/check_self_tests_run.py` now asserts it, both directions:

* a `*_test.py` on disk that no `python3` line in `ci.yml` runs;
* a name in `ci.yml` with no file behind it — a rename that moved one
  end only. **Both fired on the real tree while this was being written**:
  the first named `check_flutter_test_count_test.py`, and the second
  named `check_self_tests_run_test.py` in the window between wiring the
  step and writing the file.

Comments are stripped before matching, because `ci.yml` is full of prose
naming scripts — this gate among them — and a grep over the raw text
counts a mention in a comment as "run". Whole-line comments only: a step
that runs the thing and then says why on the same line is still running
it, and there is an assertion for each.

It has a floor (25, against 38 today) so an empty `scripts/` cannot read
as a clean sweep, and it refuses rather than passes when `ci.yml` or
`scripts/` cannot be read at all. 20 assertions, every message fed.

The joke is deliberate and load-bearing: `check_self_tests_run_test.py`
is itself one of the files its subject checks for, so if it ever stops
being run its own gate says so.

## Both new floors transferred to CI exactly

Run 2253, `58fc5110`:

    call server tests that ran: 33 (floor: 33)
    6638 Dart tests ran (floor 6638)

And the Dart one carries a vindication of the design. CI's `flutter test`
does not use the expanded reporter at all — under GitHub Actions it picks
the **github** reporter, which ends with

    🎉 6637 tests passed, 1 skipped.

There is no `+6637 ~1` anywhere in that log. **Scraping the console would
have failed outright on the first CI run**, not subtly: the gate reads
`--file-reporter json:`, which is the same regardless of what the console
reporter is doing, and the number came out the same 6,638 measured twice
on this machine.

## `flutter analyze` says "No issues found!" over code it never read

`- run: flutter analyze --fatal-infos --fatal-warnings` is the strictest
line in `ci.yml` and the easiest one in the repository to switch off
without touching it, because what it analyses is decided somewhere else:
`app/analysis_options.yaml`.

Measured, not reasoned about. A file with two hard type errors went into
`lib/src/`:

    2 issues found. (ran in 70.6s)      exit 1

Then, with that file untouched:

| one line added to analysis_options.yaml | analyze says | exit |
|---|---|---|
| `exclude: - lib/src/**` | `No issues found! (ran in 3.2s)` | **0** |
| `errors: invalid_assignment: ignore` | `No issues found! (ran in 18.2s)` | **0** |

**Seventy seconds became three** and nothing reads the duration either. A
third line does it more quietly still: delete `include:` and every lint in
`flutter_lints` goes with it, leaving only the type system — analyze still
runs, still passes, enforces almost nothing.

`scripts/check_analyzer_covers_the_app.py` asserts, over 1,001 `.dart`
files under `app/lib` and `app/test`:

* `include: package:flutter_lints/flutter.yaml` is still there;
* every `exclude:` entry is one of the four non-Dart directories, each
  named with the reason it holds no Dart — `build`, `android`, `ios`,
  `web` — and nothing else, in **both** directions, so a dropped entry is
  reported too (the harmless direction, and still worth reading);
* no `exclude:` pattern **matches** a real `.dart` file under `lib` or
  `test`. That is the check about effect rather than spelling: the clause
  above refuses an unlisted pattern, and this one catches the case where
  the pattern is unchanged and the tree moved under it — Dart put into
  `app/web/`, which is excluded and reasonably so while it holds only
  `index.html`, a manifest and a service worker;
* no `errors:` key downgrades anything to `ignore`, `info` **or
  `warning`** — the last because the only thing making a warning fatal is
  a flag in another file;
* no `rules:` entry is `false`, which is how one lint is switched off;
* a floor of 400 analysable files, so an empty `app/` cannot read as a
  clean configuration.

30 assertions, every message fed. The glob translation has a class of its
own, because `fnmatch` would have been one line and would have been
wrong: it renders `*` as `.*`, so `build/*` and `build/**` would exclude
the same thing, and telling those apart is the only reason this gate
globs. The test pins that difference *and* pins that fnmatch gets it
wrong, so the shortcut is not taken later.

### The same `relative_to` bug, twice in an hour

`OPTIONS.relative_to(ROOT)` in the unreadable-file message raises for a
path outside `ROOT`, which is exactly how the gate's own test reaches that
branch. It is the identical line that was written, hit and fixed in
`check_self_tests_run.py` less than an hour earlier — and the comment left
there about it did not stop it being written again in the next file. The
rule worth carrying: **a path constant that a test repoints is not inside
ROOT.** Two occurrences is a note; a third is a shared helper.

## Two empty dumps compare clean, and that is the schema-drift check

The most consequential check in `ci.yml` is the one that compares the
hosted project's schema to the one these migrations build — the thing that
caught migrations 0159 to 0173 having been typed into a console. It has a
`--self-test` for its normaliser, a separate red path for "the dumps could
not be read", `status=${PIPESTATUS[0]}` instead of a bare pipe, and both
dumps uploaded as artifacts whatever the verdict. It is carefully built.

And:

    $ : > a.sql ; : > b.sql
    $ python3 scripts/schema_drift.py a.sql b.sql
    No drift: 0 statements, and the hosted project has every one of them.
    $ echo $?
    0

**The number was in the sentence and nothing compared it** — the mistake
this repository has written about more than any other, in the step where
it costs the most. Two files holding nothing but the `SET` preamble do the
same thing, because the normaliser strips that and both sides come out
empty.

It is a narrow hole and worth being precise about why. An empty dump on
ONE side fails loudly: every statement becomes "missing from the hosted
project" or "not in the migrations". What passes in silence is **both**
sides being empty at once — which is exactly what a cause common to both
looks like: a CLI flag renamed, a container that exits 0 having written
nothing, an output format that moved. `continue-on-error` plus
`outcome == 'success'` tests the command's exit status, not its output,
and the `wc -l` two lines above is printed and read by nobody.

### The floor, and where the number came from

`LEAST_STATEMENTS = 2000`, checked on **both** dumps and **before**
comparing — the order matters, so a thin dump is reported as a thin dump
rather than as drift in every object in the database.

Measured on a cluster built from these migrations:

| dumped | statements after normalisation |
|---|---|
| `public` alone | 7,938 |
| `public` and `app` | 8,773 |

Floored at under a quarter of the smaller number, because which schemas
the hosted dump covers is the CLI's business and not this file's. Raise it
when a CI run has reported what it actually sees.

Six new assertions inside `_self_test()`, driven through `main` over real
temporary files, with both streams captured so the self-test's own verdict
is still the last line: two empty dumps, two preamble-only dumps, a
positive control that clears the **real** constant rather than a weakened
copy, each side thin on its own, and real drift above the floor still
reported as drift. Both mutants killed — floor set to 0, exit 1; the floor
check deleted from `main`, exit 1.

A detail worth keeping: `statements()` already refuses a TRUNCATED dump,
and said so when a local `pg_dump 16` emitted `\restrict`/`\unrestrict`
meta-commands it does not know. If the Supabase CLI's pinned `pg_dump`
ever starts emitting those, this step goes red loudly rather than quietly.

### And the completeness gate only knew one convention

`check_self_tests_run.py` asserted that every `scripts/*_test.py` is run
by CI. `schema_drift.py` carries its control behind `--self-test` instead,
in the same file as the filter, because a normaliser that can drop
everything needs its control beside it — and **nothing asserted that flag
was ever passed**. The gate's name claims every self-test; it covered one
of the two conventions. Both are checked now, both directions.

The detector for it was wrong twice in five minutes, the same way each
time. A regex over the file text matched:

1. `check_self_tests_run_test.py`, where `argv[1] == "--self-test"` appears
   as a **fixture**;
2. then `check_self_tests_run.py` itself, where it appears as an
   **example**, in the sentence explaining mistake 1.

It reads the **abstract syntax tree** now — an `ast.Compare` with `Eq`
against the constant — which prose cannot satisfy however it is worded.
That is the whole reason to parse rather than grep, and the gate's own
test pins it: a docstring, a comment and a string literal all naming the
flag, none of them answering to it.

## The drift check can switch itself off, silently and for ever

The comparison above only runs when `steps.level.outputs.ready == 'true'`,
and that is decided by parsing `supabase migration list --linked`:

```sh
pending="$(sed 's/│/|/g' /tmp/level.txt \
           | awk -F'|' 'NF>=3 && $1 ~ /[0-9]/ && $2 !~ /[0-9]/ {print $1}' ...)"
if [ -n "$pending" ]; then echo "ready=false" ...; exit 0; fi
```

The gate is right to exist — this job runs *before* `migrate`, so on any
commit that adds a migration the hosted project is legitimately one behind
and every object that migration creates would read as drift. A schema
behind by a known migration is a queue, not drift.

But the parse has two directions and only one of them is safe.

* **A parse that sees NOTHING** yields an empty `pending`, which reads as
  level, and the job goes on to dump and compare. Erring toward comparing
  is the right way round and needs no guard.
* **A parse that sees too much** sets `ready=false`, skips the comparison,
  and leaves the build **green** with a line in the step summary that
  nobody reads on a green build. A format change in the CLI's table — a
  column added, the box-drawing characters changed, a header reworded —
  would switch the drift check off and say so nowhere anybody looks.

So the step now refuses a `pending` count above **20**: this job runs
before `migrate`, so the queue is whatever one push added, and a hundred
"pending" migrations is not a queue but an awk reading the whole table as
unapplied. It also prints what it could see — `migration list: N row(s)
parsed, M pending, F migration file(s) on disk` — **without gating on it**,
deliberately: nothing outside CI can run `migration list --linked`, so the
only honest source for that number is a run that reports it. Floor it in a
later commit from the measurement, the way the SQL floor was.

Proved by extracting the parse out of `ci.yml` and running it against four
fixtures of the table:

| fixture | verdict |
|---|---|
| 820 applied, 0 pending | `ready=true`, exit 0 |
| 820 applied, 3 pending (a real queue) | `ready=false`, exit 0 |
| every row reads pending (the broken parse) | **exit 1**, naming the cause |
| no data rows at all (an error message) | `ready=true` — on to comparing |

The third is the one that matters: before this, that case set
`ready=false` and the most consequential check in the workflow stopped
running with nothing going red.

## 49 of 52 dialog tests assert only that nothing threw, and the first one read was wrong

`dialogs_build_batch2_test.dart` was written to clear the second half of
`check_dialogs_built.py`'s backlog — task #60, "Open all 50 backlogged
dialogs in tests". It opens 52 dialogs, and **49 of those tests assert
nothing but `expect(tester.takeException(), isNull)`**.

The comparison that makes the number mean something:
`dialogs_build_batch_test.dart`, the first half, has **0 of 154** in that
state. Every test in it pins text, measures a rect or taps something. I
had assumed the opposite before measuring — that the older file would be
the thin one — and the crude proxy I started with (`const []` counts) said
so. It was wrong both times.

### What the first one examined was actually doing

"and the project budgets dialog" fed `projectBudgetProvider`:

```dart
{'id': 'p1', 'name': long, 'budget_hours': 100, 'actual_hours': 42,
 'budget_amount': 25000.0, 'actual_amount': 10500.0}
```

`report_project_budget` (migration 0389) returns:

```
project_id, code, name, customer, start_date, end_date, is_active,
budget_amount, cost_to_date, revenue_to_date, unbilled_time, variance,
percent_spent
```

So the fixture sent **`id` where the function returns `project_id`**, **no
`code` at all**, and invented **`budget_hours`, `actual_hours`,
`actual_amount`** — three columns that function does not return. The
dialog therefore drew:

* a `ListTile` keyed `budget-null`, from `ValueKey('budget-${row['project_id']}')`;
* a title reading `null · Perniagaan Sinar Teknologi Maju Bersatu Sdn Bhd`,
  from `'${row['code']} · ${row['name']}'`;
* `BudgetState.none` — because `percent_spent` was absent — so **no
  progress bar, no overrun sentence and no unbilled-time warning**, which
  is three of the four things the row exists to show;
* and a Close button whose `row['project_id'] as String` would throw
  `Null is not a subtype of String` the moment anybody tapped it. Nothing
  taps it.

It passed. That is widget-tests.md **trap 11's second half** — "the column
names the repository actually selects; read the method, do not guess from
the screen" — found in the tree rather than in the doc.

### Fixed, and the fix is proved

The fixture now carries the shape 0389 returns, and the test pins what
only a correct shape can draw: the key `budget-p1`, the title
`PRJ-0007 · <long name>`, `RM 28,400.00 spent · RM 3,400.00 over budget`,
a `LinearProgressIndicator`, and `RM 4,200.00 recorded and not invoiced`.
A second test covers the other side of `is_active` — `closed`, `Reopen`,
and the `close` band at 86.25 per cent saying what is **left** rather than
what is over.

Both mutants killed: putting `'id'` back finds **0 widgets with key
`budget-p1`**; removing `'code'` fails the title. The old test passed with
*both* of those wrong at once.

One assertion of mine was wrong on the first run and the widget was right:
`find.text('Close')` finds two, because the dialog's own action bar has a
Close as well as the row. Pinned through the button's key with
`find.descendant` instead.

### And the attendance month, same file, same shape

`attendanceProvider` was fed `const <AttendanceRecord>[]`, which draws an
`EmptyState` — one icon and two centred sentences — so the row builder and
the totals line, which are the whole dialog, never ran. Fed a long
employee name, a day with lateness *and* overtime *and* a correction, and
a second day, it now pins the flags, the whole totals line
(`2 days · 95 min late · 3.08h overtime`) and the hours (`18.82h`).

Nothing overflowed at 412 wide, and that is worth stating as a measured
result rather than an absence: the totals line is an `Expanded(Text)`
beside an unflexed `Text`, the same arrangement that overflowed by 46
pixels in `credit_ledger_dialog.dart`. It holds here because the unflexed
side is one short label.

A note on the two fixed widths in `project_budget.dart` —
`SizedBox(width: 680)` in the budgets dialog and `480` in the editor,
inside an `AlertDialog`. They are **not** a phone defect: `SizedBox`
enforces its own constraints against the parent's, and Material's dialog
caps the content at the screen minus its inset padding, so 680 resolves to
about 332 on a 412 phone. The content then has 332 px to work in, which is
where an unflexed Row child would show — not the width itself.

**47 to go.** The list is in the commit that fixed these two.

### The same defect, mechanically: fourteen more fixtures of the wrong shape

The project-budget one was not a one-off. Comparing, for each
`opened(...)` in the batch files, the string keys its fixture **supplies**
against every `row['...']` the file defining that opener **reads**:

| dialog | fixture supplies, the file never reads | notable key it reads and the fixture omits |
|---|---|---|
| `showReferralHires` | `applicant_name, bonus_amount, hired_on, status` | `candidates, hires` |
| `showDeliveryDay` | `address, customer_name, sale_no, status, stops, total` | `delivered, failed, fees, outlet_name` |
| `showQueueDay` | `customer_name, party_size, status, ticket_no` | `seated, gave_up, median_wait` |
| `showTenderSheet` | `code, member_name, opens_drawer, paid, points` | `cash_due, change_due, total_amount` |
| `showCreditLedger` | `kind` | **`entry_type`, `balance_after`** |
| `showStallItems` | `item_id, item_name` | `code, name` |
| `showActivityDialog` | `created_at, kind, subject, to_address` | `to_email, last_error` |
| `showShareDialog` | `token, views` | `sent_to_email, open_count, revoked_at` |
| `showSettlementDetail` | `total` | `amount, doc_no, payment_mode_code` |
| `showAppraisalGoals` | `description, status, weight` | `target, actual, weight_percent` |
| `showInterviews` | `interviewer_name, notes, stage` | `full_name, feedback, round_no, outcome` |
| `showTemplateItems` | `due_days` | `due_offset_days, name, is_mandatory` |
| `showEditLeaveContact` | `leave_type_name, request_id` | `leave_type, has_contact` |
| `showCompose` | `address` | `local_part` |
| `showTicketShareDialog` | `token` | `ticket_no, status, open_count` |

The right-hand column is noisy — a file reads keys from several different
rows, so some of those belong to a map the fixture was never meant to
supply. **The left-hand column is not noisy**: a key the file never reads
anywhere is a column the database does not send.

#### `showCreditLedger` is the sharpest, because the doc is about it

`credit_ledger_dialog.dart` is the dialog trap 11 was written about — its
totals line overflowed by 46 pixels, and the `Flexible` that fixed it
carries a comment naming `RM 12,345.67 in · RM 9,876.54 out` as the case.
Its test fed **`kind`** where the dialog reads **`entry_type`**, so
`creditMovement(null)` fell to its `_` arm and every row said
**"Adjustment"** where a real usage row says "A scan". `balance_after` was
absent, so the figure under every amount was **`left RM 0.00`**.

Now fed the shape it is sent, and asserting it: "A scan" and "Credit
bought" from `entry_type`, `left RM 12,345.67` and `left RM 2,469.13` from
`balance_after`, `+RM 12,345.67` against `RM -9,876.54`, and the totals
line the `Flexible` exists for — with the two five-figure sums its comment
names. Both mutants killed: `kind` back finds no "A scan"; `balance_after`
removed finds no `left RM 12,345.67`.

Two of my own expectations were wrong on the way and the widget was right:

* **Three rows was one too many.** A `ListView` builds lazily and the
  third row is below the fold at 412x900, so an assertion about it counts
  a widget that is not in the tree. Two rows, and the five-figure totals
  come from those two.
* **`Fmt.money(-9876.54)` is `RM -9,876.54`**, not `-RM 9,876.54`. The
  currency prefix goes in front of whatever the number formatter produced,
  sign included.

### And the schema-drift floor, raised on the measurement it was waiting for

Run 2256 reported it:

    schema_drift self-test passed
    No drift: 8806 statements, and the hosted project has every one of them.
    109 statement(s) differ in comments or formatting only — same code

**8,806** against 8,773 measured locally for `public` and `app` — CI's two
dumps and this machine's agree to within a few dozen objects. So
`LEAST_STATEMENTS` goes from 2,000 to **7,000**: 2,000 was weak enough to
pass a dump that had silently lost three quarters of the schema, and 7,000
leaves a fifth of headroom, which is generous for a database whose
migrations only ever append. The second half of the two-step, done on
evidence rather than on a guess.

(109 is the current count of statements the hosted project has in a
different spelling — same code, so not drift. Worth watching: a number
climbing there means more is being applied by hand.)

### `showCompose` drew `From null@iakauntan.com`

Third of the fifteen. The fixture supplied `address`; `my_mailboxes`
(migration 0560) returns `setof public.org_mailboxes`, which has no such
column — it has `local_part`, and `mailboxAddress` builds the address from
it:

```dart
String mailboxAddress(Map<String, dynamic> mailbox, String domain) =>
    '${mailbox['local_part']}@$domain';
```

So the test drew **`From null@iakauntan.com`** and asserted that nothing
threw. `is_personal` was absent too, which is what `mailboxKind` reads to
say "Yours" rather than "Shared with the company" — the one distinction
the picker exists to carry.

Two tests now. One mailbox, so the address is *stated*: asserts
`From hello@iakauntan.com` and that nothing contains `null@`. Two
mailboxes, which is a branch a single mailbox cannot reach: the picker is
opened — a widget test cannot read a `SearchablePicker`'s displayed value,
and `expense_from_scan_test.dart` already knows that — and both addresses
and both sublabels are asserted.

Mutants: dropping `local_part` finds no `From hello@iakauntan.com`;
dropping `is_personal: true` from the personal mailbox finds no "Yours".

One mutant was **equivalent, not killed**, and saying so matters:
removing `'is_personal': false` from the shared mailbox changes nothing,
because `mailboxKind` reads `mailbox['is_personal'] == true` and absent is
as untrue as false. The flag that the assertion actually distinguishes is
the `true` one, and that is the mutant that was run.

### The hosted dump has more than doubled, and its budget is 85 per cent spent

Noticed while reading run 2257 for a different number:

    real  0m40.628s   /tmp/schema-local.sql    124,488 lines
    real  6m 5.966s   /tmp/schema-hosted.sql   124,676 lines

The step's budget is eight minutes and its comment reasons from a first
measurement of **2m40s** — "eight minutes is a little over twice that". It
is 6m6s now, so 6m48s of eight minutes is **85 per cent**, and this schema
only grows: these migrations append and never shrink. The next spurt starts
timing the step out, which fails the build through the "could not be read"
path — correct, loud, and about nothing to do with drift.

Raised to **15**, which is the same reasoning applied to the number as it
is rather than as it was. The job's own 30-minute budget is untouched and
does not need to move: the whole SQL job took **14.8 minutes** in that run,
so even a dump using all fifteen leaves it inside half an hour.

### Three more, and one of the fifteen was a false lead

**`showStallItems` drew "null null".** `Repo.itemStalls()` selects
`id, code, name, stall_id`; the fixture sent `item_id, item_name,
stall_id`. The dialog draws `'${it['code']} ${it['name']}'` and keys its
remove button `off-stall-${it['id']}`, so every row read **"null null"**
under a button keyed **`off-stall-null`**. Now fed three items — one on
this stall, one on none, one on another — and asserting the title, the
key, and that the other two are absent, because this dialog lists what
*this* stall sells and an unfiltered list is the defect the filter exists
to prevent.

**`showTemplateItems` labelled a mandatory task "optional".** The fixture
said `due_days` and the dialog reads `due_offset_days`, so
`Fmt.toInt(null)` gave 0 and every row said "on the start date" whatever
its real offset. `is_mandatory` was absent, and the subtitle appends
"optional" whenever it is not `true`. Now two rows, one of each, asserting
`Paperwork · day 7 · for hr_manager` and `3 days before · optional`.

`_dayLabel(7)` is **`day 7`**, not "in 7 days" — I wrote the expectation
from the sentence I expected and the code says otherwise:

```dart
static String _dayLabel(int offset) => switch (offset) {
      0 => 'on the start date',
      1 => 'the next day',
      _ when offset < 0 => '${-offset} days before',
      _ => 'day $offset',
    };
```

#### `showEditLeaveContact` was NOT one of the fifteen

The key sweep flagged it: the fixture supplied `request_id` and
`leave_type_name`, and `who_is_away.dart` reads `row['leave_type']` and
`row['has_contact']`. Reading it says otherwise — `_EditContactDialog`
takes a `LeaveRequest` object and reads `widget.request.contactWhileAway`.
**It never looks at `whoIsAwayProvider` at all.** The rows with those keys
belong to the who-is-away *list*, which lives in the same file and which
this dialog does not draw.

So the override was dead weight rather than a wrong shape, and that is
what a sweep comparing a fixture against every `row['...']` in a FILE can
tell you and cannot settle. Fourteen of the fifteen, then.

The override is dropped and the test given the thing it was missing: the
field opens carrying the contact there already is, which is the dialog's
one job. Two tests — prefilled from `contactWhileAway`, and empty when
there is none. Mutant: not passing the contact finds no `+60 12-345 6789`.

Seven of the fourteen are done. `dialogs_build_batch2_test.dart` is 54
tests now, up from 50.

## A fixture of the wrong shape was hiding a real overflow

The share dialog, the ticket share dialog and the activity dialog, and the
third one turned out to be hiding a layout defect rather than merely
failing to draw one.

### `showShareDialog` said "No address recorded · never opened"

`document_share_links` (0094) has `token_hash` and `open_count`; the
fixture said `token` and `views`, and the query is a bare `.select()` so a
real row carries every column in the table. With `sent_to_email` and
`open_count` absent the row read **"No address recorded"** and **"never
opened"** — the opposite of a link that was emailed and opened three times,
with `views: 3` sitting in the fixture saying so to nobody. Two rows now,
one active and one revoked, asserting the address, `opened 3 times, last
…`, and both chips.

`StatusChip` draws its status through `Fmt.label`, which capitalises — the
text on screen is **`Active`**, not the `active` the widget is handed.

### `showTicketShareDialog` was testing the refusal

Two things were wrong and the second is the bigger one. The link fixture
said `token` and carried no `open_count`, `reply_count` or
`sent_to_email`, so `describeTicketLink` fell to its "Not opened yet" arm.

And the **ticket** had no `requester_contact_id`, which is the first thing
`shareBlockedBecause` reads — so the dialog this test opened was in its
**refusing** state throughout, explaining that a staff ticket is not
shared. It exercised the branch it was not about and asserted nothing
either way. Two tests now, one for each branch. Mutant: removing
`requester_contact_id` puts it back in the refusal, and the assertion
catches it.

### `showActivityDialog`: 110 and 187 pixels over, at 412 wide

`document_activity` (0495) returns `at, kind, recipient, status, detail,
note`. The fixture sent `id, kind, to_address, subject, created_at,
status` — **two of six landed.** So the row drew "Emailed" with a "sent"
badge and nothing else: no address, no detail, no note, no timestamp.

Fed the real shape, the test failed — with **two `RenderFlex ...
OVERFLOWING` exceptions, by 110 and 187 pixels**, from
`email_dialog.dart:428`.

The cause, measured rather than guessed. `_ActivityTile`'s outer Row was

```dart
Row(children: [
  Padding(child: Icon(...)),            // 18
  const SizedBox(width: Space.sm),      // 8
  Expanded(child: Column(...)),         // the label, badge, detail, …
  if (at != null)
    Text(Fmt.dateTime(at), ...),        // UNFLEXED
])
```

On a phone the dialog's content is about **284** logical pixels — 412 less
the dialog's 40-a-side inset and 24-a-side content padding. The timestamp
took enough of that to leave the `Expanded` **59.6**, which the exception
states outright: `constraints: BoxConstraints(0.0<=w<=59.6, …)`. The inner
Row's inflexible children — the label at 151 and the badge at 67, with two
8-pixel gaps — need 234.

This is `check_narrow_rows.py`'s own doctrine, in its own words: *"An
`Expanded` is not a get-out… it can shrink only down to the width of its
INFLEXIBLE children, and if those alone do not fit it overflows exactly as
before."* That gate did not catch it because its subject is `ListTile`'s
`trailing:` and `title:`, and `_ActivityTile` is a hand-built
`Padding(Row(...))`.

**And it had never shown, because the fixture had no `at`.** No timestamp,
no trailing text, the row fitted, and the test passed over a layout nobody
had ever drawn. The wrong shape was not merely failing to verify the
dialog — it was concealing a defect in it.

Fixed: the timestamp moves **under** the line, beside the recipient and
the note, and the label is `Flexible` as belt and braces per the doctrine
above. No exception at 412 after it, and `activity_entry_test.dart`,
`send_now_outcome_test.dart` and the whole batch file still pass.

Honest caveat, the one widget-tests.md insists on: the test font draws
every glyph at a full em, so `Fmt.dateTime` measures wider in a test than
in Plus Jakarta Sans and 110/187 overstates the real-device figure. At real
metrics the row comes to roughly 284 of 284 with **nothing** left for the
detail — so what shipped was a line that silently dropped its detail and
would overflow on a larger system font. A latent fragility made
unbreakable, which is what the doc says to treat these as.

Ten of the fourteen done. The file is 55 tests.

### Three more: a settlement showing RM 0.00, a goal weighted 0%, a Round 0

**`showSettlementDetail`** said `total`, and `Repo.settlement` returns the
receipt row itself whose money column is **`amount`** — so the figure
beside the receipt number read **RM 0.00** while the fixture said 100.
`contacts` (an embed, `contacts(name, …)`), `receipt_date` and
`unapplied_amount` were absent too, so the header had a blank name and no
date and the one sentence about money left on account could not appear. Now
1,200 taken, 800 set against INV-0007 through the `sales_documents` embed,
and 400 still on account, each asserted.

**`showAppraisalGoals`** said `weight` and the dialog reads
**`weight_percent`** — in two places, the row's subtitle and the running
total. So every goal read "0%", the total read "0%", and the dialog sat on
its *"Short of 100% — some of the rating is unaccounted for"* warning while
the fixture said 25. Two goals now at 60 and 40, asserting the subtitle
whole (`60% · Delivery · target 12 filings · actual 11 filings`), both
ratings side by side (`4 / 3` and `— / —` where one is not in yet), the
total at 100% and **neither** warning; plus a second test at 70% that
asserts the warning, because the warning is what the dialog is for.

**`showInterviews`** said `stage`, `interviewer_name` and `notes`. The
dialog reads `round_no`, `mode`, `score`, `outcome`, `feedback` — and the
interviewer as an **embed**, `round['employees']['full_name']`, not a flat
column. So every row read **"Round 0"** with a date and nothing else. Two
rounds now, one held and one not, asserting the round numbers, the mode
through `Fmt.label`, the interviewer out of the embed, the score, the
outcome chip and the feedback line.

Two more formatter facts the code settled against my expectation:

* **`Fmt.label` capitalises EVERY word**, splitting on `_` — so
  `in_person` is `In Person`, not `In person`.
* **`Fmt.qty`** is what the weights go through, and 60 renders `60%`.

Every one of the three has both mutants killed: the old key name back, and
one further column dropped.

Thirteen of the fourteen done. The file is 56 tests, up from 50 when this
started.

### The last four, and a correction to the count

**The count in the commit before this was wrong.** It said "thirteen of
fourteen" and the true figure at that point was **ten** of fourteen. The
table has fifteen rows, one of which (`showEditLeaveContact`) turned out
not to be a defect, so fourteen is the real total — and this commit is what
makes it fourteen of fourteen.

**`showReferralHires`** described one HIRE and the function returns one row
per **REFERRER**: `report_referral_hires` (0381) gives `referrer_id,
referrer_no, referrer_name, hires, candidates`, and the fixture sent
`applicant_name, hired_on, bonus_amount, status`. `referrer_name` was the
only key that landed, so the row read **"null introduced"** and **"null
hired"**. Two referrers now, one with hires and one without, because the
colour on the trailing figure turns on `hires > 0`.

**`showDeliveryDay`** and **`showQueueDay`** had the same mistake twice:
the fixtures fed per-order and per-ticket rows to dialogs that read
per-outlet **summaries**. `pos_delivery_day` (0259) returns `outlet_name,
runs, delivered, failed, still_out, fees, free_rides, median_minutes`;
`pos_queue_day` (0257) returns `joined, seated, gave_up, no_shows,
still_waiting, median_wait, longest_wait`. With `joined` absent,
`queueDayLine` returned its first arm — **"Nobody queued"** — on a day the
fixture was describing as somebody waiting.

**`showTenderSheet`** was the widest, across all three of its providers:
the sale's money column is `total_amount` not `total`; a tender type is
selected by `id` and its cash-ness comes from `kind`, while the fixture
sent `code` and a non-existent `opens_drawer`; and memberships are filtered
on `o['is_active'] == true`, which the fixture never supplied — so the live
list came out **empty and the whole section drew nothing**.

#### A surviving mutant, and what it taught

Dropping the delivery outlet's `runs` **passed**. The assertion was
`findsWidgets` on `12 out · 9 delivered · 1 failed · 2 still out`, and the
dialog draws `runsLine` in two sections — per outlet and per driver. The
driver fixture carried the same figures, so its row satisfied the finder on
its own and the outlet's number was pinned by nothing.

Fixed by giving the driver different figures (7 out, 6 delivered, 1 still
out) and asserting each sentence with `findsOneWidget`. The mutant dies now.

**`findsWidgets` on a string that two sections can both produce pins
neither of them** — the same family as "two assertions either side of a
behaviour do not pin it", and worth adding to that list.

And the mutant was nearly misread. The first attempt used `sed` on
`'runs': 12,` which matched the driver's copy instead, so nothing changed
and the test passed — a mutant that was never applied reading exactly like
a mutant that survived. The second attempt asserted the occurrence count
dropped from 2 to 1 before running anything.

### The one number this guard waits on is now an annotation

`migration list: N row(s) parsed, M pending, F migration file(s) on disk`
sits at step ~70 of the SQL job, and the dump step after it prints a
hundred-odd lines of Docker image layers. Reading that line out of the log
means a 200-line tail; three attempts at 22, 58, 118 and 148 lines all
landed in the image pull or later and never reached it.

So it is a `::notice::` now, which becomes an **annotation** —
`repos/{owner}/{repo}/check-runs/{id}/annotations` returns it in one small
response. That is the only reason the number is printed at all: a later
commit floors `rows` from it, and a number nobody can read is a number
nobody will floor.

The guard was re-proved after the change: 820 rows with none pending
exits 0 and prints the notice, and 820 rows all reading pending still
exits 1.

#### And the dump timing, twice

| run | local | hosted |
|---|---|---|
| 2257 | 0m40.6s | **6m05.9s** |
| 2258 | 0m32.0s | **5m03.9s** |

Both dumps are ~124,500 lines. So the hosted half varies between about five
and six minutes against the first-ever measurement of 2m40s, which is what
the raise from eight minutes to fifteen was for. Five of fifteen is
comfortable; six of eight was not.

## 4 October, part two: the thin assertions, and what reading them found

### The measurement first

`expect(tester.takeException(), isNull)` and nothing else. Across the whole
of `app/test`, **47 test bodies** check nothing but that — out of 6,346 the
scanner could see (flutter counts 6,638; the difference is parameterised
loops that make several tests from one body).

**34 of the 47 are in `dialogs_build_batch2_test.dart`.** The other 13 are
not thin at all, and the count would have been wrong without checking them:
they are OVERFLOW tests — "the register totals do not overflow a phone",
"the new-company dialog fits" — where the FRAMEWORK is the assertion. A
`RenderFlex` overflow becomes the test's pending exception and
`takeException()` is what collects it, so that one line is the whole check
and it is a real one.

Proved rather than reasoned about: an unflexed wide `Row` put inside
`NewOrganizationDialog` killed `platform_people_test.dart`'s "the
new-company dialog fits", with a comment-only control surviving the same
run. So the thin backlog is 34, not 47, and it is all in one file.

### The scanner, and why it needed a second pass

The first pass reported 18 bodies with NO `expect` at all, which looked like
a finding. It was the detector: 17 of the 18 assert through a **helper** —
`allInsideTheStage(tiles(tester), screen)`, `expectShellStandsUp(tester)` —
defined in the same file and calling `expect` inside. Resolving one level of
same-file helper took 18 down to 1.

Same family as the helper-that-asserts-by-throwing from the SQL survey: **a
body with no `expect` in it is not a body with no assertion in it.**

### Twenty rewritten, and three more wrong-shape fixtures

Twenty of the 34 now assert something, and eight new tests were added
alongside them where one dialog call could not reach two branches. Three of
the twenty turned out to be **wrong-shape fixtures**, which makes
sixteen, seventeen and eighteen after the fourteen of the morning:

**The modifier groups dialog.** `pos_modifier_groups_admin` (0251) returns
ten columns and the fixture named four; `pos_modifier_options_admin` (0250)
returns seven and it named three. The three missing from each are the ones
the row BRANCHES on: `is_active` absent reads as `== true` false, so the
live group drew itself retired and greyed; `option_count` and `item_count`
absent made every group read "0 answers · asked about 0 dishes"; and the
answer row's subtitle is `'${option['code']}'`, which with no `code` is the
four characters **n-u-l-l** on the screen. Nothing threw.

The answers also live in an `ExpansionTile`'s `children`, which are
**offstage until it is tapped** — `find.text` does not see an offstage
widget, so a test that never taps asserts nothing about them either way.

**The recurring template dialog.** The title is
`'What ${widget.schedule['name']} bills'` and `recurring_documents` (0097)
has `name text not null`, which the fixture did not supply — so the heading
read **"What null bills"**. It also invented `doc_type` and `next_run`; the
columns are `kind` ('sales' or 'purchase') and `next_run_date`, and `kind`
is what decides whether the picker offers invoices or bills.
`templateKindOf(null)` happens to answer sales, so a purchase schedule
under that fixture would have been offered invoices and
`update_recurring_template` would have raised on the save.

**The filing details dialog — a row from ANOTHER TABLE.** It edits
`fs_filings` (0171) and saves through `updateFsFiling`; the fixture sent
`form` and `due_on`, which belong to the LHDN filing calendar, and
`status: 'due'`, which is not one of `app.fs_filing_status` (draft, frozen,
lodged). With no `fy_start`/`fy_end`, `filingPeriodRuns` was false and Save
was dead; nothing was ever lodged, so `kLodgedLockedFields` and the
paragraph explaining it drew for nobody. That set follows
`app.fs_refuse_lodged_edit` field for field, and a UI that leaves a locked
field editable sends an update the trigger refuses — which is the only
reason the set is duplicated in Dart at all.

### AND A REAL DEFECT: the approval rule named the wrong person

`rule_editor.dart` states the rule it is about to write in English, in a
highlighted box. `_sentence` picked the approver with

    team.where((m) => m.userId == _userId)

and `_byRole` is `_userId == null`. So the moment somebody switched the
editor to "A named person" with nobody chosen, `_userId` was null — and so
is the `user_id` of any member who has been **invited and not accepted**.
The comparison matched that member. The sentence then read

    Step 1: every purchase document of RM5000 or more cannot be posted
    until Siti Aminah has approved.

over a rule that named nobody, about a person the picker two widgets above
**deliberately refuses to offer** for exactly that reason. The guard existed
in the picker and was missing in the sentence.

Fixed with `m.userId != null &&` in front of the comparison, and the
regression is held by an assertion on "nobody yet" — reverting the guard
was run as a mutant and FAILED.

An approval rule is read once, when it is written, and then silently blocks
postings for ever. Nothing on that screen is checked by anything but the
sentence.

### Mutation results

Each run included a comment-only CONTROL, and every control survived.

| source | killed | survived |
|---|---|---|
| `msic_picker.dart` | 3 of 4 | 1, equivalent — written down |
| `modifier_groups_dialog.dart` | 6 of 6 | — |
| `recurring_template_dialog.dart` | 4 of 4 (after a test was added) | — |
| `budget_line_editor.dart` | 4 of 4 | — |
| `rule_editor.dart` | 3 of 3 | — |
| `organization_admin_dialogs.dart` | 1 of 1 | — |

**The MSIC equivalent mutant.** Swapping the second and third ranking
buckets — `[...exact, ...byWords, ...byCode]` — survives because with real
MSIC data no query can land in both: a code is digits, a description and a
category are words. A digit query only ever reaches the code buckets and a
word query only ever the word one. Killing it would need a description with
another row's code inside it, which `0011`'s seed does not have and MSIC
2008 does not either.

**The template mutant that survived, and then did not.** Forcing
`templateKindOf` to answer `DocKind.sales` always changed nothing on screen,
because the fixture was a sales schedule. What differs for a purchase one is
the QUERY, not the picture — `update_recurring_template` looks for a bill
and raises if handed an invoice — so the new test captures the provider's
`args` and asserts `kind` and `docType` directly. The mutant dies now.

### Two traps this file sets for a test author

**`find.byType(FilledButton).first` reads the HARNESS's button.** The
`opened` helper in this file builds its own `FilledButton` with
`key: ValueKey('open')` to open the dialog, and it is first in the tree. A
`savable()` written that way returned true in both directions and the
assertion passed before and after the thing it was testing. Anchor from the
label upwards: `find.ancestor(of: find.text('Add'), matching: ...)`.

**A tap on a second picker DISMISSES the first instead.** `SearchablePicker`
wraps its field and overlay in a shared `TapRegion`, so with one overlay
open a tap on the next field reads as "outside" and closes the first. Escape
first, then `ensureVisible` — eleven fields do not fit 900 logical pixels,
and `find` locates a child of a `SingleChildScrollView` outside the viewport
that `tap` cannot hit.

### The migration-list number, and the floor built from it

Run 2265's annotation answered it:

    migration list: 742 row(s) parsed, 0 pending, 742 migration file(s) on disk

Two numbers that are equal, which is what a sound parse of that table looks
like on a level project. **742 of 742 — the parse sees every row**, so the
worry recorded yesterday ("N near 0 with F at 742 is a FINDING about the
parse") does not apply.

It is floored now, against the files on disk rather than against 742: the
constant is the thing that goes stale, migrations are append-only here, and
`rows` has to keep up. One-sided on purpose — a migration applied to the
hosted project from outside this repository would add a row with no file
behind it, which is worth knowing about and is not this parse breaking. A
`files < 700` guard sits under it, because `ls supabase/migrations/*.sql |
wc -l` returning 0 would make `rows >= files` true over an empty table.

**What it catches that the two existing guards cannot.** The comment already
in the file says a parse that sees nothing errs toward comparing rather than
toward silence, and that is true. What it misses is that the same parse
leaves `pend_n` at 0, which is below 20 — so the `pend_n > 20` guard written
to catch a format change **cannot fire on the format change that matches
nothing**. Both existing tests pass on it.

Proved by extracting the step's own `run:` block out of `ci.yml` — not a
copy, so the proof cannot drift from the thing proved — stubbing only the
`link` and `migration list` calls, and feeding it four tables built from the
real 742 filenames:

| table | exit | says |
|---|---|---|
| 742 applied both sides | 0 | 742 parsed, 0 pending |
| separator character changed | 1 | 0 parsed, names the floor |
| one row with no remote stamp | 0 | 1 pending, `ready=false` |
| run where no migrations exist | 1 | names the `files` floor |

The second is the case that used to pass silently. Run 2266 then exercised
the new floor against the real table for the first time and printed the same
742/742.

### `flutter analyze` in 4.2 seconds is not a hole

Worth writing down because the number looks exactly like one.
`--fatal-infos --fatal-warnings` now reports "No issues found! (ran in
4.2s)" where a cold run took 70.6s, and **3.2s was what excluding
`lib/src/**` produced** — which is the hole `check_analyzer_covers_the_app.py`
exists to refuse. It is a warm analysis-server byte store: planting
`int _probe() => "not an int";` in `app/lib/src/core/format.dart` reported
both the type error and the unused-element warning, still in 4.2s.

### AND A SECOND DEFECT, of a different kind: a test that opened nothing

`and resolving one against what is already here` called `resolveSupplier`,
which asks `repo.contacts` BEFORE it draws anything. `_FakeRepo` raises,
`resolveSupplier` catches it and returns `SupplierOutcome.ask` -- so no
dialog ever appeared, and `expect(tester.takeException(), isNull)` was
asserted over an empty `Scaffold`.

`check_dialogs_built.py` counted that opener as covered the whole time,
because what it looks for is the CALL. A test that calls a dialog opener and
draws nothing is indistinguishable, to that gate, from a test that draws it.

It needed a fake whose `contacts` answers (`_ContactsRepo`, with a substring
filter mirroring the real `or(name.ilike.%q%, ...)`), and then the two-stage
lookup runs for real: a narrow search on `_searchable(name)`, and -- when
that finds nothing good enough -- `rankedLikeName` over everything on file.
The second stage is the expensive mistake the screen exists to prevent:
"Supplier not found" next to a Create button, when the company is already
there under a slightly different spelling. Both headings are now asserted,
because the whole point of the pair is that they differ.

### A CEILING, so the backlog cannot grow back

`scripts/check_thin_assertions.py`, wired into the Flutter job beside the
analyser gate, with its ceiling in `app/test/thin_assertion_ceiling`:

    14 of 6351 test bodies check only that nothing threw
    (ceiling 14, 13 excused with a reason), over 457 files and 6351 bodies.

It is a ceiling and **it fires in both directions** — over it, because a
screen built without throwing is not a screen that says the right thing;
under it, because ground won and not written down is ground that gets given
back. That is the `check_counted_assertions.py` idiom, and the same reason
it uses it.

Not a ban. Twelve overflow tests and one spreadsheet writer are excused BY
NAME with a reason each, and an excuse that is no longer needed is reported
as a problem of its own — a stale excuse is an excuse that gets reused for
something else.

Its two sweep controls are the shape `check_surface_size.py` uses:
`LEAST_FILES = 300` and `LEAST_BODIES = 5000`, because this gate's pattern
matches only offenders, so finding none is also what reading nothing looks
like.

Thirty-one assertions of its own, every one fed: the thin form against the
opposite claim (`isNotNull` is a real assertion), a `test(` as well as a
`testWidgets(`, `my_test(` which must not match, the helper resolution in
both directions, a helper in another file (a stated limitation, not a
discovered one), `${...}` inside a string, a `//` comment naming `expect`, a
block comment, both ratchet directions, a missing ceiling file, a ceiling
file with no number in it, the empty sweep, and
`inspect.signature(...).parameters['path'].default is empty` — because
`check_flutter_test_count.py` had a default argument there and ten of its
floor assertions silently tested the real file.

Three of the lessons already in this document were written into it as
comments rather than left for the next author to rediscover: the default
argument, `relative_to` raising for a path outside the tree (written, hit
and fixed twice in `scripts/` already), and a `{` inside a string breaking
brace matching — which the second time swallowed seventeen following tests
into one body and showed up as a count that was too LOW, not as an error.

### A trap worth one line: do not run tests beside `mutate.py`

`scripts/mutate.py` edits the SOURCE FILE IN PLACE and restores it at the
end. A `flutter test` started while it is mid-run compiles against the
mutant, so it fails for a reason that has nothing to do with the test. That
happened once here -- `a tax code that was typed rather than picked` came
back red while `tax_code_dialog.dart` was checked out mutated, and
`git diff` was what said so. Check `git status` before believing a failure
that arrived next to a mutation run.

## 4 October, part three: THREE TESTS DELETED BY ACCIDENT, AND WHAT CAUGHT IT

Worth its own heading because it is the clearest demonstration in this
file of why the Dart-count floor exists, and because the floor was too
slack to catch it.

Three more thin tests were rewritten -- `assigning a table`, `the forecast
settings`, `the delivery fee dialog` -- with a Python splice that computed
the start of the block to replace like this:

    i = s.index("testWidgets('%s'" % name)
    start = s.rindex('\n', 0, s.rindex('testWidgets(', 0, i + 1)) + 1

`str.rindex(sub, 0, i + 1)` searches `s[0:i+1]`, which ends ONE CHARACTER
INTO the match at `i` -- so the substring does not fit and `rindex` returns
the PREVIOUS occurrence. `start` was therefore the previous test's first
line, and the replacement ate it. Three edits in a row, each eating its
neighbour:

  * `assigning a table`        ate `and says so plainly when nothing on
                                    file is like it`
  * `the forecast settings`    ate `one forecast line`
  * `the delivery fee dialog`  ate `assigning a table` (the rewrite from
                                    two steps earlier)

`flutter test test/dialogs_build_batch2_test.dart` printed **"All tests
passed!"** after every one of them.

**What caught it** was extracting the test-name set from `git show HEAD:`
and diffing it against the working tree -- 61 against 58, with the three
names listed. Nothing else would have: the suite was green, the analyser
was clean, and every gate passed.

**And CI would not have caught it either**, which is the part worth
fixing. The floor said 6638 while run 2266 printed `6644 Dart tests ran`,
so there were six tests of slack; losing three would have left 6646, still
over the floor, still green. The floor is now **6649**, which is run 2267's
own number read out of its log, and the file says in as many words: raise
it in the same commit as the tests, because a floor that trails the count
is a floor with room in it.

Repaired by restoring the file from `HEAD` and re-applying the three
rewrites with an exact-match replacement of the `testWidgets(...)` call
alone -- no backward walk at all -- then re-checking the name set against
`HEAD` (61 of 61, nothing added, nothing removed) and running the file
(61 passed).

### Two more lessons from the same three tests

**An `@override` of an EXTENSION method is a new method.**
`AssignTableSheet._scan` awaits `repo.posTableByCode`, which lives on the
`RepoPos` extension rather than on `Repo`. A subclass of `Repo` that
declares `posTableByCode` does not override anything: the extension's own
body runs and reaches `callRpc` underneath, which the throwing fake then
raises from, out of a `try/finally` with no `catch`. The fake overrides
`callRpc` instead, which has the side benefit that the real
`posTableByCode` runs -- including its `rows.isEmpty ? null : rows.first`,
which is the line the branch under test turns on.

**`DropdownButtonFormField` asserts its initial value is among its items.**
A `default_method` of `'exponential'` rather than `'exponential_smoothing'`
raised at build rather than drawing blank. It cannot come from the database
-- `app.forecast_method` (0197) is an enum of exactly the three the
dropdown lists -- but it came from a fixture, which is how the assertion
got found. A UI list that drifts from its enum is therefore a crash and not
a quiet wrong value, which is the better of the two.

### And the ratchet fired downward, as designed

Raising the three tests took the thin count from 14 to 11, and
`check_thin_assertions.py` REFUSED the stale ceiling:

    ::error::only 11 thin test bodies remain and the ceiling still says 14.
    This is a RATCHET: lower the number in app/test/thin_assertion_ceiling
    so the ground that was won cannot be given back.

That is the half of a ratchet nobody remembers to write, firing on the real
tree within an hour of being written.

### Three count lines are annotations now

`6649 Dart tests ran (floor 6638)` sat at the end of a step followed by a
workbook check and a dozen lines of runner cleanup, so a 30-line tail of
the job log landed past it -- which is exactly how the floor stayed six
tests behind without anybody noticing. The Dart count, the call server's
count and the thin-assertion count are all `::notice::` now, so
`repos/{owner}/{repo}/check-runs/{id}/annotations` returns them in one
small response. Same fix as the migration-list number, for the same
reason, found the same way.

## 4 October, part four: four more, and a NINETEENTH wrong-shape fixture

The thin count went 11 -> 7, and both the previous step and this one were
the gate REFUSING the stale ceiling rather than anybody remembering to
lower it.

**`one forecast line` — the nineteenth wrong-shape fixture, and the first
where the map came in as an ARGUMENT rather than from a provider.** The
sheet is handed its row directly (`showForecastLineSheet(context, s, ...)`),
so the `forecastLinesProvider` override in the test was decoration — which
is the first thing that misleads about it. `forecast_suggestions` (0205)
returns twenty-three columns and the fixture passed three, so the header
read **"null · Widget"**, the state chip drew `Fmt.label(null)`, and all
eleven figures read nought. Every row the sheet exists to show was absent
or zero.

That sheet's whole reason for existing is the lead-time row — "a buyer
asked to spend money on a figure a model produced is entitled to see where
it came from" — and `measured from deliveries` against `the company
default` are worth very different amounts of trust. It now asserts the
three order figures as the subtraction they are (60 suggested less 20
drafted leaves 40), the four position figures, and both conditional rows.

**`a supplier made out of what was scanned`** — the dialog standing between
a misread letterhead and a permanent contact. It now asserts the
"correct anything wrong" blurb (the other form, for a reading that did not
happen, is noted as uncovered), that every read field reaches a box, the
Entity Search offer with no register line yet, and both validators
including that a CLEARED e-mail stops being complained about.

**`and one item's own parameters`** — fed `{}` and `[]`, so every box was
empty, the picker had nothing in it and the switch was off: the state of an
item nobody has touched, indistinguishable from one whose saved parameters
failed to load. Fed a full row at a named warehouse, which also draws the
"This location only" half of the blurb, and all four validator bounds.

**`the notifications sheet`** — the tile branches on `severity` (colour),
`kind` (icon), `read_at` (the title's WEIGHT, invisible to a text finder)
and whether there is a body or a timestamp at all. And
`myNotificationsProvider` is a FAMILY on `includeRead`, which is the point
of the "Show read" button: the flip must change which provider is watched,
not merely the label. Overridden per argument so the two lists differ and
the flip is observable.

### A timezone trap in an assertion

`Fmt.dateTime` formats `value.toLocal()`, so `find.text('01/09/2026 10:00')`
for a `02:00Z` timestamp passes only where the machine is on +08. This
container is UTC and the assertion went red. The expectation now goes
through `Fmt.dateTime` itself: the claim worth making is that the row is
DRAWN for the entry with a `created_at` and not for the one without, and
how it is formatted is `Fmt`'s own business.

## 4 October, part five: the MIA paste parser, an appraisal, and a gate that annotated its own self-test

### The annotation noise, which the change itself caused

Run 2268 confirmed the three count lines become annotations --
`6649 Dart tests ran (floor 6649)`, `11 of 6351 test bodies check only
that nothing threw`, `call server tests that ran: 33 (floor: 33)` -- and
also carried **ten of these**:

    notice: 0 of 1 test bodies check only that nothing threw
            (ceiling 0, 0 excused with a reason), over 1 files and 1 bodies.

They are `check_thin_assertions_test.py`'s own fed cases. The summary was
printed from inside `problems()`, so every passing fixture in the self-test
emitted a workflow command and CI turned each into an annotation. GitHub
caps annotations at ten per step and fifty per run, so self-test noise can
crowd out the number the change was made to make readable.

`problems()` returns `(problems, summary)` now and `main()` prints it, once.
Pinned by an assertion that `problems()` writes NOTHING to stdout.

### `verifying somebody against the MIA register`

The one with the most in it, as expected. "Read it" runs
`MiaResultParser.parse`, which is pure, so no fake was needed -- and it has
two outcomes that say opposite things. The test now pastes rubbish first,
because a parser that refuses is the branch somebody works around by typing
a number into the wrong box and the note has to say what to do instead;
then a real tab-separated row, which is what copying out of MIA's
server-rendered table actually gives. It asserts that the row reaches four
boxes with `member_type` upper-cased by the parser, that the practising
certificate dropdown resolves to Yes, that the Member/Firm segmented button
is NOT drawn when only one kind is offered, and the save rule -- the number
is the credential, and a row with a name and no number would put a green
"checked on" stamp beside nothing anybody can look up again.

### `an appraisal under review`, and two wrong expectations it corrected

A bare `Appraisal(id, status, employeeId)` leaves everything null, so the
title read 'Appraisal' rather than a person and the form opened empty --
which is the one state that cannot show what `initState` is for: the half
already written is the starting point, so a reopened review is edited
rather than retyped. Fed a full record with the MANAGER half filled in too,
to prove `initState` switches on the ACTION rather than on what happens to
be present.

Two of my expectations were wrong and the code settled both:

  * `selfRating` is a `num`, so the box is seeded '7.0' and not '7'. The
    field takes decimals so it is consistent rather than wrong, but it is
    what the person sees, so it is what the assertion says.
  * the manager's words ARE on the subject's screen -- in the three-section
    summary above the form, which is the record of what has been written
    and is right. What must not happen is their appearing in an EDITABLE
    box, which the absent 'Your assessment *' label says. Asserted both
    ways round, because the first draft assumed the wrong one.

## 4 October, part six: ZERO. All thirty-four, and the ceiling to match

The last five went in one pass and `app/test/thin_assertion_ceiling` reads
**0**, which is the only kind of ratchet nobody has to remember to lower.
The gate refused every stale number on the way down — 34 → 14 → 11 → 7 → 6
→ 5 → 0, and every step after the first was the under-ceiling arm firing
rather than anybody noticing.

**From here on a new body that checks only `takeException` fails CI.** The
remedy is to assert what the screen says, or to name the test in `ALLOWED`
with a reason. Thirteen are named there and all thirteen are legitimate:
twelve overflow tests where the framework raising on `RenderFlex` IS the
assertion, and one that writes a spreadsheet `check_xlsx.py` reads back in
the same job.

### The last five, and what each one could not see

* **`logging a chase on a debt`** — the fixture's shape was already right
  (its comment records the throw that got it there) and nothing read a
  thing off the screen. Its one rule is one the database also enforces: a
  promise DATE belongs only to "promised", so changing the outcome away
  from it has to clear the date rather than let somebody submit a
  contradiction. Unreachable before, because the outcome starts at
  `no_answer` and nothing ever changed it. A second history row with no
  notes covers the other side of the `notes == null` join.

* **`closing a deal`** — `stageType: 'won'` is the dialog's thinnest
  configuration: one choice, so no segmented button and no blurb;
  `outcomeNeedsReason('won')` is false, so `outcomeBlockedBecause` never
  fires. On `'lost'` it offers Lost and Abandoned and ONLY those two,
  because offering "Won" on a card dropped into Closed Lost would let the
  board say one thing and the record another. The walk now asserts the
  refusal that says WHY ("a pipeline that records that deals died and not
  why cannot answer the only question it is for"), the chip list changing
  with the outcome, and the button renaming itself.

* **`billing a matter`** — the empty list drew the sheet's most MISLEADING
  state: "Nothing to bill in these dates" above "Every billable hour on
  this matter has been billed", which is true of a matter with no time on
  it and reads as reassurance. Four entries now — one billable inside, one
  not billable, one already billed, one billable outside — so the card's
  whole point is asserted: 3.5h unbilled in all, 1.50h of it outside the
  dates, which is the sentence that stops a correct-looking total being
  accepted.

* **`one time entry`** — four empty providers, so the "Against" picker had
  nothing in it and the sheet drew its warning instead. The duration parser
  is the arithmetic here: '1.5' and '1:30' are the same hour and a half,
  '2h' is allowed because people type it, and '1:60' is a typo for two
  hours that the parser REFUSES rather than guesses at. Projects and
  matters share the box to enforce `time_entries_one_anchor`, and against
  nothing the Chargeable switch cannot be turned on at all.

* **`and the figures a tax computation is built on`** — none of the seven
  figures was in the fixture, so `_seed` ran on one arm only, the arm that
  cannot go wrong. Five supplied and the two SME figures left null covers
  both in one fixture: blank is deliberate for those two, because "a zero
  paid-up capital would pass the SME test, and a form that offers zero
  invites somebody to leave it". The hints are asserted too, because they
  are the only place the statutory reasoning is written on the screen —
  capital at the BEGINNING of the basis period, allowances brought forward
  are not a loss, zakat is a rebate capped at the tax under s.6A(3).

### Two more model traps

`Matter` requires `clientId`, which the compiler caught; and `Opportunity`
defaults `status` to 'open', which is what made the close-deal walk
possible without constructing a closed deal.

The method that is working, in order: read the RPC or repository query
behind each provider FIRST — the fixture shapes are where the defects are —
then assert whole joined subtitles rather than `textContaining` on one
clause, read `onPressed` directly wherever a disabled button is the point,
tap open anything offstage, and mutation-prove a sample per batch with a
comment-only control.

## 4 October, part seven: proving the excuses, and a comment that was wrong

The gate's `ALLOWED` list excuses thirteen test bodies whose only check is
`expect(tester.takeException(), isNull)`. Twelve were described as overflow
tests on the strength of ONE measurement. Writing an excuse list and then
asserting its contents is the same shape as everything else this file
complains about, so three more measurements were taken.

**`SectionHeader` — proved.** Taking the `Expanded` off the title column
makes `and the header reports no overflow` FAIL, with a comment-only
control surviving the same run. So the mechanism — a `RenderFlex` overflow
becomes the test's pending exception and `takeException()` collects it — is
now measured in two different widgets rather than one. The remaining
`platform_people_test.dart` entries share that mechanism, that file and
that helper, so they are argued from two measurements rather than none.

**The two `two_factor_test.dart` entries are NOT RenderFlex tests at all,**
which is what this gate first called them. They are QR CAPACITY tests:
`qr_flutter` throws rather than drawing a half code when the data does not
fit at the chosen error-correction level, so not throwing is the claim that
the URI fits. The reasons in `ALLOWED` now say that.

**And one of them carried a comment that was wrong.** `a long account name
still fits` said its 40-character label "is the case that would push a
fixed-capacity code over". Measured, with `mutate.py` run against the test
file as its own source — which is the right tool here because the claim
lives in the test's own parameters:

| mutant | verdict |
|---|---|
| level M → H | **survived** — it still fits at the highest correction level |
| label 40 → 400 characters | **survived** — a ~500-character URI is well inside version 40 |
| label 40 → 4,000 characters | **killed** — the test fails |

So the mechanism is real and the test is a regression test on a realistic
long label, NOT a capacity boundary. The comment says so now.

Three of the thirteen excuses are measured; the other ten rest on two
measured mechanisms in the same files. That is the honest state of it.

## 4 October, part eight: the survey one level up, and why it is NOT a gate

The thin-assertion gate's own docstring says what it does not prove:
`find.textContaining` on a fragment, and `findsWidgets` on a string two
sections can both produce, are not thin by its measure and pin almost
nothing. So the next question was asked: how many, and are they hiding
anything?

**The sizes, out of 13,079 `expect()` calls under `app/test`:**

| form | count |
|---|---|
| `textContaining` + `findsOneWidget` | 585 |
| `find.text` + `findsWidgets` | 57 |
| `textContaining` + `findsWidgets` | 33 |
| `byType` + `findsWidgets` | 6 |
| `findsAtLeastNWidgets` | 0 |
| `evaluate(), isNotEmpty` | 0 |

The 33 are the weakest combination — a loose matcher AND a loose count —
so they were listed and read. Several look indefensible at a glance:
`'tax'` is three characters; `'5,000'`, `'54.00'`, `'42.00'`, `'1320.00'`,
`'60'` and `'0 bills'` are bare numbers; `'ST8'`, `'ST6'`, `'SL10'` are
three short codes in a row.

**And then the weakest of the lot turned out to be sound.**
`intercompany_test.dart` asserts `find.textContaining('tax')` with
`findsWidgets` on a taxed invoice — and `findsNothing` on the same fragment
for an untaxed one, in the very next test. The presence/absence pair IS the
claim, and the loose matcher is deliberate because the exact wording is not
what is being asserted. Mutated both ways:

  tax printed whether or not there is any   KILLED
  tax never printed                         KILLED
  CONTROL: a comment                        survived

`manufacturing_order_test.dart`'s `'60'` is the same shape: paired with a
`findsOneWidget` on `'A short run'`, which is the real claim.

### So: no gate here, and that is the finding

A ratchet on `findsWidgets` would have fired on the two cases examined, and
both are correct. **The pairing is invisible to a pattern**, which is the
same reason the thin-assertion gate needed one level of helper resolution
and the same reason an excuse list is part of that gate rather than an
afterthought. A gate whose true-positive rate is unknown and whose first
two hits are both false is a gate that teaches people to excuse things.

What would be worth doing, if this thread is picked up again, is the
opposite of a sweep: take the 585 `textContaining` + `findsOneWidget` sites
in ONE file, mutate the strings they assert, and see how many survive. That
measures assertion strength instead of guessing at it from shape. The
tooling is already there — `scripts/mutate.py` works against a test file as
its own source, which is how the two-factor QR claims were measured.

## 4 October, part nine: a detector that reported a clean tree because it could not fire

The question from part eight's own write-up was whether assertion STRENGTH
can be measured from shape. A second frame was tried and it failed in a way
worth recording more than the answer.

### The frame

An assertion on a label the WIDGET owns cannot catch a wrong-shape fixture:
nothing it checks depends on the data. So — how many test bodies assert
only the widget's own words? Measured by taking every literal
`find.text`/`textContaining` argument in a body and asking whether it also
appears verbatim somewhere in `app/lib`.

Across `app/test`: **3,494** literal text assertions, of which **2,160**
name words that are in `app/lib` and **1,334** name something the fixture
supplied.

### IT REPORTED 0 AND IT WAS BROKEN

The per-body classification came back "0 bodies whose every literal
assertion is the widget's own words", which reads like a clean bill of
health. It was a dead detector.

`check_thin_assertions.bodies()` yields the BLANKED body — every string
literal turned to spaces, which is what makes brace matching safe — and the
classifier fed that to a string-literal regex. No literal could ever match,
so every body fell out of the sweep at `if not lits: continue` and the
count was structurally zero.

**What caught it was writing the two controls afterwards**: a synthetic
body that IS blind, and the same body with one fixture-derived assertion
added. Both came back empty, which is impossible if the detector works. The
controls now run FIRST and the script exits 2 if either is wrong, because a
sweep whose detector cannot fire reports a clean tree — the same shape as
`mutate.py` refusing to report without a CONTROL mutant, and the same shape
as the five floors.

### Fixed, it finds 649 — and they are all fine

Raw slices matched by offset instead of blanked ones: **649 bodies**. Then
read their NAMES:

  * and an empty inbox says so rather than showing nothing
  * a period with no assets says that rather than showing nil
  * nothing read yet says so
  * says which brightness it is showing
  * an untouched reason is null, not an empty string

These are EMPTY-STATE and BRANCH tests. The widget's own sentence is
precisely the claim, because the thing under test is which sentence got
drawn. Asserting fixture data there would be asserting the wrong thing.

### Sharpened once more, and inflated again

Narrowed to bodies whose literals are all generic chrome — Save, Cancel,
Close, Done — gives **8 of the 649**. The first one read,
`call_screen_test.dart`'s "and saying no leaves everybody on it", uses
`find.text('Cancel')` as a TAP TARGET; its actual assertion is
`expect(find.byKey(ValueKey('call-hang-up')), findsOneWidget, reason:
'still on the call')`. The classifier counted literals anywhere in the body
rather than only inside `expect(...)`, so 8 is inflated too.

### The conclusion, and it bounds today's approach

**Assertion strength is not inferable from the shape of an assertion.** It
depends on what the test's subject is, and that lives in the test's name and
intent rather than in its syntax. Two independent frames were tried —
`findsWidgets` on a loose fragment, and asserting only the widget's own
words — and both concluded NO GATE, each after its first hits turned out to
be correct code.

Three gates were built today and all three work because they measure
something structural: a body with no assertion at all, a count of tests
that ran, a parse that saw no rows. The fourth one does not exist because
the thing it would measure is a judgement. Worth knowing before the next
session reaches for one.

The one method that does measure strength is still mutation, and it is
per-site rather than per-sweep: `mutate.py` works against a test file as its
own source, which is how the two-factor QR claims and the intercompany tax
pair were settled. That is the tool for the 585 `textContaining` +
`findsOneWidget` sites if anybody wants the number.

## 4 October, part ten: the absence half, and the third and fourth frames

Parts eight and nine each tried to judge an assertion by its shape and
concluded NO GATE. This part tried the other half of the pairing —
`findsNothing` — because it looked structural in a way the others were not,
and it is where the clearest refutation of the whole approach turned up.

### The number the absence half is worth

Tree-wide, across 182 files, there are **3,041 assertions on a literal
string**:

| matcher | sites | |
|---|---|---|
| `findsOneWidget` | 2,254 | 74.1% |
| `findsNothing` | 658 | 21.6% |
| `findsWidgets` | 87 | 2.9% |
| `findsNWidgets` | 33 | 1.1% |
| `findsOne` | 9 | 0.3% |

That table matters for a reason beyond bookkeeping: **a `findsNothing`
assertion cannot be killed by mutating the string it names.** Garble the
string and it is still absent, so the mutant survives by construction and
says nothing about the test. 658 sites — more than a fifth of every literal
assertion in the repository — are outside the reach of the one method that
does measure strength. Any future mutation sweep should exclude them
explicitly rather than count them as survivors.

### The third frame: a string the app can never say

An absence check is real when the string is something the screen CAN show
and this state does not show it. It is a check that cannot fail when the
string is one nothing can ever produce — a typo, a renamed label, a
reworded sentence. Then it passes on a working screen and a blank one
alike.

That looked structural: it does not ask whether an assertion is strong, it
asks whether a string exists. Controls first this time, and they passed —
a paired absence was not flagged, an invented literal was. It reported
**55 of 658**.

Three of those were read. All three were correct code, and the second
reading destroyed the detector:

- `contact_records_test.dart:134` expects `'Create a Customer record'`
  absent. Two lines above, the same test asserts `'Create a Supplier
  record'` and `'Create a Prospect record'` PRESENT. The Customer string
  can only be rendered by the code path that renders those, so the role
  word is the only thing varying and the assertion is exact. The detector
  matched whole literals, so the siblings did not count.
- `dialogs_build_batch2_test.dart:2501` expects `'stays an account you can
  post to'` absent. `sub_account_dialog.dart:63` is

  ```dart
  return '${parent.code} ${parent.name} stays an account you can post '
      'to, and keeps its own balance. The new account is filed under '
      'it rather than replacing it.';
  ```

  The project wraps its prose to 72 columns, so **the sentence on screen
  appears in no source line**. The detector called one of the strongest
  assertions in that file vacuous.

### The fourth frame: join the literals, which is what the compiler does

That second failure has a mechanisable cause, so it was worth fixing: build
the corpus by concatenating adjacent string literals the way Dart does, turn
`$interpolation` into a wildcard, and count a needle renderable if any three
consecutive words of it appear. Three controls, run first — the wrapped
sentence must now read renderable, an invented sentence must still be
caught, and a sentence lifted out of `app/lib` must pass. All three did.

It reported **57 of 658**, and both prose false positives were gone. But the
57 are almost all strings composed at runtime — `'RM 4,000.00'`, `'in 0
days'`, `'1 attempts'`, `'Every 1 month'`, `'HTTP 0'`. A composed string is
absent from every literal by definition, so for those the detector has no
opinion at all and never did. The informative residue was the prose-shaped
ones, and every single one was read:

- `report_view_test.dart:82` — `'COST OF SALES'` absent, with
  `'REVENUE'` asserted present on the line above. The report upper-cases
  its section names, so the uppercase form exists in no literal and the
  sibling is the only proof it is producible.
- `shell_menu_search_test.dart:415` — `'BOOKS'` absent, and the test's own
  comment says why: "`RailHeading` upper-cases them, so this is the heading
  as it is actually drawn."
- `collections_screen_test.dart:185` — `'promises'` absent beside `'1 broken
  promise'` present. A singular/plural check; the plural is interpolated.
- `ocr_keys_admin_test.dart:504` — `'On this device'` absent, and the
  fixture ten lines above is `'name': 'On this device'`. The string comes
  from the data, so of course it is not in `app/lib`.
- `sst_card_test.dart:164` — `'Zero Rated'` absent, and the comment is
  already the argument this whole exercise was making: "'Zero Rated' rather
  than 'Not Applicable': NA appears in the card's own copy behind the
  dialog, so it would match whether or not it was on the menu, and an
  assertion that cannot fail is not one."
- `tax_details_test.dart:193` — `'Sabah'` absent, under the comment "What
  the fixture sent, and only that. A screen holding its own copy of LHDN's
  codes would offer all sixteen here."

### Why there is no fifth attempt

The last one is decisive, and not by weight of numbers. In
`tax_details_test.dart` **the string's absence from `app/lib` is the
property under test.** The screen must not carry its own copy of LHDN's
state codes; `'Sabah'` is missing from the source because that is the thing
being asserted. So the detector's signal is inverted: its sharpest hit is
the test it should least want to touch.

Underneath that, the set of strings an app can render is not computable from
its literals, and three separate mechanisms break it — each demonstrated
above, and only the first fixable:

1. adjacent-literal wrapping (fixed by joining, as the compiler does);
2. interpolation and runtime formatting — `'in 0 days'` can never be a
   literal;
3. render-time transformation — `toUpperCase()` in `RailHeading` and in the
   report headers.

Past those, the only evidence that a string is producible is a
*present*-assertion somewhere in the suite, and that is exactly what the
test's author already knew when they wrote the pair. **A gate cannot be
built out of the knowledge it was supposed to supply.**

Four frames now, four NO GATE: `findsWidgets` on a loose fragment, the
widget's own words, a string the app cannot say, and the same with a joined
corpus. The three gates that do exist all measure something structural — a
body with no assertion, a count of tests that ran, a parse that saw no
rows — and none of them needs to know what a test is about.

Both detectors are in the session scratchpad rather than `scripts/`,
deliberately: a detector whose every hit is correct code is not a gate, and
committing it would invite the next session to run it and start "fixing"
sound tests.

## 4 October, part eleven: the measurement that does work, and what it costs

Parts eight to ten tried four times to judge an assertion by its shape and
found no gate each time. This is the method that does work, run properly for
the first time: garble the string an assertion looks for, and see whether the
test notices.

### till_screen_test.dart: 65 of 65

Every `expect(find.text('X'), findsOneWidget)` and
`expect(find.textContaining('X'), findsNWidgets(n))` in the file was turned
into one mutant that appends ` ~gone~` to X. A correct assertion must then
FAIL, so a survivor is an assertion that cannot fail.

```
baseline: passed
...
CONTROL -- a comment line that changes nothing    passed
restored: passed

every mutant killed, control survived.
```

**65 mutants, 65 killed, control survived.** Not one assertion in that file
passes when the string it names is wrong. That is the first direct
measurement of assertion strength in this repository rather than an
inference from syntax, and it is the evidence the thin-assertion gate's
premise needed: the assertions left standing after the ceiling reached zero
are real.

Two design points, because both were nearly got wrong:

- **Only `expect(find.text(...), ...)` sites were mutated, never a bare
  `find.text(...)`.** A `find.text('Cancel')` that feeds `tester.tap` is a
  TAP TARGET, not an assertion; garbling it makes the tap throw and the test
  fail, which would read as a killed mutant and inflate the score.
  `call_screen_test.dart`'s "and saying no leaves everybody on it" is exactly
  that shape — its real assertion is on `ValueKey('call-hang-up')`.
- **The patterns were made unique by extending BACKWARDS A WHOLE LINE AT A
  TIME until the file contained the text once**, not by hand. `mutate.py`
  refuses a pattern matching two places, and 15 of the 65 needed a second
  line. Automating that refusal away would have aimed 15 mutants at the
  wrong site.

### What it costs, and why that settles the sweep question

68 `flutter test` runs — baseline, 65 mutants, the control, the restore
check — took **21m45s**, about 19 seconds each. There are **2,383**
present-expecting literal assertions in `app/test`. At that rate a tree-wide
sweep is **12.2 hours serially**, and that is before the 658 `findsNothing`
sites, which no string mutation can reach at all.

So mutation is a per-file instrument, not a gate and not a sweep — the same
conclusion parts eight to ten reached from the other direction. Pointing it
at one file costs twenty minutes and answers the question exactly; pointing
it at the repository costs a working day and answers it no better.
`scratchpad/gen_string_mutants.py <test file> <out.py> [--absent]` generates
the spec for any file, and it is in the scratchpad rather than `scripts/`
because nothing should run it on a schedule.

### If a test file reads as modified and nobody edited it

A mutation run holds its file MUTATED ON DISK for its whole length —
`mutate.py` writes the mutant, runs the suite, and restores in a `finally`.
So `git status` showing one test file modified, with a diff like

```
-      expect(find.text('Nothing to sell yet'), findsOneWidget);
+      expect(find.text('Nothing to sell yet ~gone~'), findsOneWidget);
```

is a run in progress, not work to commit. **Do not commit it** — the default
branch is this branch, so that would push a knowingly-false test. The stop
hook asked three times during the 4 October runs and was refused each time,
which was right: there were zero unpushed commits throughout, so nothing was
at risk.

If a run died without restoring — a container restart will do it — the
recovery is `git checkout -- app/test/<file>`, or the harness's own backup at
`$TMPDIR/<file>.orig`, which is byte-identical to HEAD. Check before
assuming a mutant is a real edit: `git diff` names the mutation.

### The same file, the other half: 0 of 20

The `findsNothing` sites in the same file were then mutated the same way,
with the same harness, in the same hour. **Twenty mutants applied, zero
killed, control survived, restore verified.**

```
passed (survived): 23      # baseline + 20 mutants + control + restored
FAILED (killed):   0
```

Set beside 65 of 65 on the present-expecting half, that is the blind spot
as a measurement rather than an argument:

| sites in till_screen_test.dart | mutants | killed |
|---|---|---|
| expect a string to be PRESENT | 65 | **65** |
| expect a string to be ABSENT | 20 | **0** |

Garbling a string an assertion expects to be missing leaves it missing, so
the test cannot notice. Those twenty assertions are not weak — several are
among the sharpest in the file — they are simply outside what this method
can measure. Tree-wide that is 658 of 3,041 literal assertions, 21.6%. A
sweep that reported them as survivors would be reporting a fifth of the
suite as untested on the strength of its own blind spot.

A twenty-first mutant was NOT RUN: `pattern not found`, because its spec was
generated while the previous run held the file mutated. The harness said so
under **NOT RUN -- these were never applied, so nothing above says anything
about them** and exited 1, which is exactly why it refuses to be quiet about
an unapplied mutant. The generator now reads HEAD; see the note in
`docs/widget-tests.md`.

### Three files, 120 mutants, 120 killed

The other two were then run, and the answer did not change:

| file | mutants | killed | control |
|---|---|---|---|
| `till_screen_test.dart` | 65 | **65** | survived |
| `withholding_screen_test.dart` | 21 | **21** | survived |
| `reconciliation_screen_test.dart` | 34 | **34** | survived in BOTH halves |

**120 of 120.** Not one present-expecting literal assertion in three
unrelated screens — a till, a withholding-tax register, a bank
reconciliation — passes when the string it names is wrong. That is 5.0% of
the 2,383 such sites in `app/test`, measured rather than assumed, and the
three files were chosen for different characters rather than for looking
promising: a long screen test, a statutory register, and the screen whose
arithmetic is the fiddliest in the app.

The reconciliation file was split into two 17-mutant halves, and **each half
carries the control**. A half without one proves nothing about itself, which
is the same argument the harness makes by refusing a run that has no control
at all.

### Run them in the FOREGROUND

The operational lesson, and it is cheap. `mutate.py` holds its file mutated
for a whole run, so a BACKGROUND run leaves the working tree dirty across
every pause — and the stop hook then asks, correctly by its own lights, for
a deliberately broken assertion to be committed and pushed to what is also
the default branch. It asked four times during the 4 October runs.

A foreground run cannot produce that state: the turn does not end until the
harness has restored the file and verified the restore. 24 runs fit in one
window comfortably; 38 do not, which is why 34 mutants became two halves.
Split on the mutant list, give each half the control, and the tree is clean
at every point a hook could look at it.

One at a time, never two — they share one `.dart_tool`, and a spurious
failure from contention reads as a KILLED mutant.

## 4 October, part twelve: turning the method on today's own work

The three files above were somebody else's assertions. The 34 thin tests
rewritten today were MINE, and "not thin" is weaker than "asserts the right
thing" — so they were the least established assertions in the repository and
the obvious thing to point the instrument at.

`87f3d069..HEAD` changed **51 test bodies** in
`dialogs_build_batch2_test.dart`: the 34 thin rewrites, the wrong-shape
fixture fixes, and five new tests. One mutant per body, aimed at an
assertion inside it, so a kill proves THAT test can fail:

| batch | mutants | killed | control |
|---|---|---|---|
| 1–5 | 12+12+12+12+3 = **51** | **51** | survived in every batch |

Every rewritten test has teeth. Nothing was left behind that passes with its
own assertion wrong.

### The day's total

| | mutants | killed |
|---|---|---|
| `till_screen_test.dart` | 65 | 65 |
| `withholding_screen_test.dart` | 21 | 21 |
| `reconciliation_screen_test.dart` | 34 | 34 |
| `dialogs_build_batch2_test.dart`, today's 51 rewrites | 51 | 51 |
| **present-expecting, total** | **171** | **171** |
| `findsNothing` (till) | 20 | **0** |

Eight controls, all survived. One mutant NOT RUN and reported as such.

## THE DISK FILLED, AND IT LOOKED LIKE A SLOW TEST

Worth more than any of the numbers above, because it cost an hour and the
first diagnosis was wrong.

`flutter test test/dialogs_build_batch2_test.dart` was started to time it.
After **fifteen minutes it had produced zero bytes**, and the conclusion
drawn was that this file is twenty times slower than `till_screen_test.dart`
and so too expensive to mutate. That was wrong. `df` said:

```
/dev/vda  252G  37G  57M  100% /
```

**The disk was full.** The frontend compiler was sitting at 857MB RSS and
1.6% CPU, unable to write its output dill — not slow, starved. The
environment's own note says this exactly: "Avail at 0 with low Used means
the allowance is spent, not that the machine is broken." With space freed
the same file ran in **35 seconds**.

What filled it, in order of size:

- **2,885 `/tmp/tmp*` directories, 4.9G** — orphaned Chromium profiles
  dated 9–20 SEPTEMBER, from a prior session. Deleted once the user asked
  for it; the first attempt was refused as a "Shared Scratch Sweep", which
  was right, because they are not this session's to delete.

  **This bullet first said "9,937 directories, 12G ... Chromium profiles",
  and that was wrong — one sampled directory was generalised to all of
  them.** Only ~2,885 plus a few hundred tiny `.org.chromium.Chromium.*`
  stubs were browser-related. See the section below for what the other
  7,052 actually are, because they are the bigger number and nobody has
  identified them yet.
- **34 `/tmp/flutter_tools.*` directories, 2.7G** — these ARE a mutation
  run's doing. Every `flutter test` makes one of roughly 100–200MB, and a
  killed run leaves it behind. A 65-mutant run can leak several gigabytes,
  so **`rm -rf /tmp/flutter_tools.*` between batches** is part of running
  one, and every batch in part twelve did it.
- two redundant Flutter SDK tarballs in `/tmp`, 2.8G, already extracted to
  `/opt/flutter-3.47.4`.

Deleting what this session owned took it from 57M to 5.6G, which is enough
to work. If a test suite ever goes quiet for minutes with no output, run
`df -h /` before concluding anything about the test.

### UNEXPLAINED: 7,052 copies of this repository in /tmp, 7.2G

Found while clearing the disk, and **nobody has identified the cause.** It is
written down here because it is 7.2G, because the first guess was wrong, and
because it may start again.

Each `/tmp/tmp<random>` directory is **1.3M and holds a partial copy of this
repository** — `.github`, `app`, `deploy`, `docs`, `scripts`, `supabase`,
113 files, no `.git`. Not a browser profile, which is what they were first
taken for.

When they appeared, by hour on 4 October:

```
03:00  72    09:00  100    13:00 1006
04:00  24    10:00  169    14:00  938
05:00  48    11:00 1288    15:00  848
06:00  53    12:00 1004    16:00  622
08:00  50
```

Up to ~1,300 an hour — twenty a minute — and then it **stopped dead**. The
newest is 16:41 and the count was still 7,052 seven hours later, stable over
a 20-second window, so nothing is producing them now. The container
restarted somewhere in that gap, which may be the whole explanation.

**The obvious hypothesis was tested and is WRONG.** Several
`scripts/check_*_test.py` build a throwaway tree with `mkdtemp`, and a leak
there would look exactly like this. It is not that: running
`check_or_filters_test.py` and `check_thin_assertions_test.py` leaked
**zero** directories. The stop hook does not copy anything either — it is
`git diff --quiet` and nothing more.

So the question is open: what wrote a 113-file copy of this repository into
`/tmp` twenty times a minute for five hours? Worth answering before it fills
the disk again, since a full disk does not announce itself — it presents as a
test that has gone quiet.

**Deleted, on 5 October, once the user asked for it.** The first attempt
was refused as a "Shared Scratch Sweep" and was not retried until then.

```
find /tmp -mindepth 1 -maxdepth 1 -name 'tmp*' -exec rm -rf {} +
```

**The cause is no longer a mystery and it was in this repository**: see
the next section. `boot()` in `check_web_boots.py` passed
`--user-data-dir={tempfile.mkdtemp()}` to headless Chrome and removed
nothing, which is where the browser profiles came from — not a prior
session's mess, as this document twice said. The `scripts/`-shaped
copies are `check_sweeps_look.py`'s `skeleton_tree` output; both of its
call sites do clean up, so those are from runs killed mid-flight, and
`scripts/check_temp_cleanup.py` now gates the whole class.

Where the disk ended up, across the whole exercise:

| | free | used |
|---|---|---|
| when the compiler stalled | **57M** | 100% |
| after clearing what this session owned | 5.6G | 86% |
| after the Chromium profiles | 11G | 73% |
| after the rest | **18G** | **53%** |

`/tmp` went from 21G to 2.7G.

`-mindepth 1` matters: without it `-name 'tmp*'` matches `/tmp` itself, which
made an earlier `du` report the whole of `/tmp` as the set's size and put the
count out by one.

## 5 October: the gate that passed over nothing

The `mkdtemp` gate added the day before went green locally, green in its
own 12 self-tests, and turned **CI red** — on "Statutory engine and ledger
rules", a job with nothing to do with temp directories, and red again on the
docs-only commit after it, which is what identified the cause as the gate
rather than anything statutory.

`check_sweeps_look.py` drives **every** gate in a tree holding a full copy of
`scripts/` and empty source directories, and requires each to FAIL, because
"looked and found nothing" and "could not look" are the same output. The new
gate globbed `scripts/` only — which the skeleton supplies for real, and
which was by then clean — so it ticked:

```
FAIL: test_every_gate_is_in_some_bucket_now_that_the_backlog_is_empty
      [check_temp_cleanup]
AssertionError: 'passed_over_nothing' != 'reported'
 : check_temp_cleanup is in no bucket and did not report over an empty tree
```

**A gate written to catch vacuous success, committing vacuous success.**
Fourteen seconds to reproduce locally, which is the whole argument for
running the meta-gate before pushing a new one.

### The excuse that was not taken

The first instinct was an excuse bucket, and it is wrong. Every excuse in
`check_sweeps_look.py` names the behaviour it expects and **fails both
ways**: `NEEDS_A_DATABASE` wants a `usage:` line, `NEEDS_A_FILE` wants a
`FileNotFoundError`, and a gate excused on either ground that PASSES instead
is reported as "the excuse is wrong and the gate is not looking". There is
no bucket for "passed because the skeleton handed it the real thing", and
adding one would have been adding a hole to the gate that exists to close
them.

The right fix is the CANARY shape that file's own docstring already
prescribes for a census gate: floor what was read, and name a place the
sweep must still reach. So `check_temp_cleanup.py` now sweeps every
first-party python file in the repository with canaries on `scripts/` and
`brand/`. Over the skeleton `brand/` is absent and it exits 2 — "nothing
python found under brand/ … this gate cannot tick over a tree it cannot
see". Over the real tree it reads **124 files, five more than before, and
still finds no leaks**, so widening it found nothing new.

### If you add a gate, run this before pushing

```
python3 scripts/check_sweeps_look_test.py     # ~15s
python3 scripts/check_sweeps_look.py          # ~2min, drives all 68
```

It now says *"49 of 68 gates report a problem over an empty source tree, as
they must. 10 exit on a missing database URL, 8 raise on a missing named
file, 1 exits on a missing argument, and 0 still pass over nothing."* A new
gate joins the 49 or it is named with a reason, and the reason has to be one
of the three shapes that file already knows how to verify.

### And one of its own tests had to be repaired

The floor test stubbed `python_files` to return nothing. Once canaries
existed the canary check fired first, so the floor was never reached and the
test asserted nothing about the thing it names. Its stub now satisfies both
canaries and still falls short, and a new test pins which of the two
sentences a stripped tree gets — they are both exit 2, so the order is
invisible from the code alone.

That is the twelfth way a green test covers a broken thing, in a new
costume: **adding a check EARLIER in a function can make a later check
unreachable, and the test for the later one goes on passing.**

### The SQL suite was run, and it is not a two-minute job

`supabase/tests/run_locally.sh` on `edd464d2`, with no Docker, in this
container:

```
migrations applied
all SQL assertions passed (383 files, 14330 assertions executed)
schema and client agree
[exited with code 0]
```

That is the whole branch verified locally — 742 migrations applied in order,
383 assertion files, **14,330 assertions**, and the schema/client comparison
that catches drift. Nothing on this branch since `0740` touches
`supabase/migrations`, so this also confirms the yesterday's displaced and
skipped migrate jobs cost nothing.

**It took over eleven minutes, not the two `CLAUDE.md` claimed.** Measured
rather than estimated: the process was still running at 681 seconds and
finished inside a 900-second limit. `CLAUDE.md` is corrected, because the
cost of that number being wrong is not patience — a correct run looks
exactly like a hung one, and this one was nearly killed on that belief at the
eleven-minute mark.

Two things that made it worse and are avoidable:

- **Do not pipe it through `tail`.** `... | tail -30` buffers every line
  until the process exits, so the output file sits at 0 bytes for the whole
  run and there is no way to tell progress from a hang.
- The honest liveness check is
  `ps -eo pid,etimes,args | grep postgres`. A cluster on its own port
  (`/usr/lib/postgresql/16/bin/postgres -D /var/tmp/pgdata -k /var/tmp -p
  5599`) with a checkpointer and a walwriter beside it means it is working.
  That is what settled it here.

It also prints `pg_ctl: another server might be running; trying to start
server anyway` and a page of `NOTICE: role ... has already been granted`
lines when a cluster from an earlier run is still up. Noise, not failure —
the run above carried all of it and still exited 0.

### And the edge functions, which are the other half of that pair

`supabase/functions/_local_check/check_locally.sh` on the same branch:

```
Checked locally, and the 40 deno tests CI runs passed too
(503 tests ran, floor 503).
[exited with code 0]
```

Every edge function type-checked and **40 test files, 503 tests** run, with
the supabase-js client stubbed — so green here is not green in CI, which
checks it against the real package. Red here is still red in CI.

**`CLAUDE.md` said "seventeen of them now".** It is 40. The sentence carrying
that number also said "the number is not worth keeping in prose", which is
exactly right and was exactly the problem; the number is now gone from
`CLAUDE.md` and the run's own floored output (`503 tests ran, floor 503`) is
the thing to read.

Both local runners therefore pass on `a8c585d8`: 383 SQL files with 14,330
assertions, and 40 deno files with 503 tests. That is as much of CI as can be
reproduced in this container.

### Which numbers in the documentation go stale, and which do not

Three stale figures turned up on 5 October by running what the docs describe
instead of reading what they say about it. That looked like "the docs are
riddled with stale numbers", so the rest of `CLAUDE.md`'s countable claims
were checked. They are not, and the pattern is sharper than the first
impression:

| claim | verdict |
|---|---|
| "thirteen ways a green test covers a broken screen" | **right** — `docs/widget-tests.md` has exactly 13 numbered sections |
| "382 assertion files running" | **right, and HISTORICAL** — it describes the state when the 1120 fallback survived, not today's 383. Nearly "corrected" into a falsehood |
| "a narrow declaration of the four pieces of Deno" | **right** — `deno_globals.d.ts` declares `env`, `serve`, `readTextFile`, `test` and nothing else |
| "~800 migrations" | 742. Overstated by 8%, but written as an approximation and the argument it serves does not turn on it |
| SQL suite "in about two minutes" | **wrong by 6x.** Fixed |
| "seventeen" deno test files | **wrong, it is 40.** Fixed |

**The two that rotted were both counts of things that GROW** — how many test
files exist, how long a growing suite takes. The three that held were about
fixed design: the number of numbered sections in a document, the number of
Deno globals deliberately declared, and a count explicitly pinned to a past
event.

So the rule is not "distrust the documentation". It is narrower and
actionable: **do not write a number for something that grows.** Where one is
needed, make the tool print it and floor it, which is what
`check_locally.sh` already does (`503 tests ran, floor 503`) and what
`check_flutter_test_count.py`, `check_thin_assertions.py` and
`check_temp_cleanup.py` do. A floored number in output cannot go stale
without failing; a number in prose goes stale silently.

And the near-miss is worth as much as the hits: **a historical count reads
exactly like a stale one.** `382` was one off from today's `383` and would
have been "fixed" into a lie about what the 1120 episode cost, if the
sentence around it had not been read first.

### setup-java v5 does NOT fix the Android JDK flake — checked, not assumed

The Android job's `API rate limit exceeded for <ip>` is the one known red in
CI, and its annotations now also carry `setup-java v4 is deprecated and will
no longer receive updates. Please migrate to actions/setup-java@v5`. Those
two sit next to each other and look like one fix. **They are not.**

`actions/setup-java`'s release notes were read (v5.7.0 is current): nothing
in any v5 release mentions authentication, GitHub API rate limits, or the
`token` input being used when resolving a distribution over the GitHub API.
So a v4 → v5 bump is a maintenance item with a deprecation behind it, and
**not** a cure for the flake. Do not spend the hour expecting one.

The flake's cause and why each fix is refused, in one place:

| fix | why not |
|---|---|
| pass `token:` | already passed, and the error still names an IP rather than an account — `setup-java` is not putting it on that request |
| `distribution: temurin` | `app/android/gradle/gradle-daemon-jvm.properties` names `toolchainVendor=jetbrains`; Gradle refuses its daemon without a JetBrains Runtime, and a Temurin 21 does not satisfy a vendor criterion |
| drop the vendor criterion | that file came from a developer machine running `updateDaemonJvm`. Editing it here moves the disagreement rather than removing it, which ci.yml says in its own comment |
| `distribution: jdkfile` | needs `cache-redirector.jetbrains.com`, which this container's egress proxy REFUSES with 403 on CONNECT, so it cannot be verified here and must not be pushed blind |
| cache the JDK | the one untried option. Not attempted, because it can only be verified by pushing to a branch that is also the deploy branch |

What is in place is the three-attempt ladder with waits of 0, 60 and 180
seconds, and it works often enough that **Android passed on every commit
after `f1e65ffe`**. Re-run the failed job rather than re-diagnosing:
`gh api -X POST repos/getgroupmy/iakauntan/actions/runs/<id>/rerun-failed-jobs`,
which returns 403 "already running" while any job in that run is in flight.

## 5 October: the statutory engine, mutation-tested for the first time

`CLAUDE.md`'s second rule is that anything touching EPF, SOCSO, EIS, PCB or an
SSM deadline needs a test that would fail if the number moved. The machinery
to check that — `scripts/mutate_sql.py` — has existed for weeks and had been
pointed at exactly one function family, bank rules. **The statutory engine had
never been measured.**

Eight mutants against `app.calc_statutory`, each moving a real statutory
number, now committed as `supabase/tests/mutants/calc_statutory.py`:

| mutant | killed by |
|---|---|
| the SOCSO insured ceiling ignored, so high wages over-contribute | `statutory.sql` — "SOCSO caps at 6000, employee: expected 30.00, got 60.00" |
| KWSP's round-up to the next RM20 removed | `statutory.sql` — "expected 333, got 332" |
| the wage rounded DOWN to the band instead of up | `statutory.sql` — "expected 333, got 330" |
| the employee pays the employer's rate | `statutory.sql` — "EPF 5000 employee: expected 550, got 650" |
| a wage no band covers reports the schedule as VERIFIED | `statutory_schedules.sql` |
| a band's flat amount ignored in favour of the percentage | `statutory_schedules.sql` — "expected 24.7" |
| an unpaid month contributes, the `<= 0` guard losing its equals | `statutory_schedules.sql` |
| the lowest matching band wins instead of the highest | `statutory_changeover.sql` — "the band starting higher is the one charged: expected 250.00, got 50.0" |

**8 of 8 killed, control surviving every run.** The statutory arithmetic is
genuinely asserted, not merely covered.

### The finding is about METHOD, and it nearly produced a false alarm

Run against `statutory.sql` alone — 90 assertions, the obvious choice — the
score is **4 of 8**, and the four survivors read as four missing assertions
in the most safety-critical function in the product. They are not. Three are
killed by `statutory_schedules.sql` and the fourth by
`statutory_changeover.sql`; `payroll_run.sql` kills none of them.

`mutate_sql.py` takes ONE test file. CI runs all of them. So **a per-file
mutation score understates the suite, and a survivor is only a gap once every
file that calls the function has been tried** — four files call this one.
Reporting the first number would have invented work and impugned a sound
suite.

The sharpest instance: "a wage no band covers reports the schedule as
verified" survives `statutory.sql`, and that is the **exact defect migration
`0404` was written to fix** — a verified table with a missing band printing
"verified" on a payslip that deserved a warning. A single-file run says that
fix is unprotected. `statutory_schedules.sql` kills it.

### Running it again

The cluster `run_locally.sh` leaves behind is what `mutate_sql.py` talks to
(`postgresql://postgres@/postgres?host=/var/tmp&port=5599`). If it has gone —
and it went once mid-sweep here, reported honestly as a `HARNESS ERROR` and
not as a survivor — the data directory usually survives and restarting beats
a twelve-minute rebuild:

```
rm -f /var/tmp/pgdata/postmaster.pid
su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D /var/tmp/pgdata \
  -l /var/tmp/pg.log -o '-k /var/tmp -p 5599' start"
```

Then confirm the schema is really there before trusting a baseline. Do
NOT do it by comparing counts against numbers written here — **the 381
public tables this paragraph used to name was wrong**, a correctly
rebuilt cluster holds 379, and two minutes went on hunting two tables
that had never gone missing. Ask the instrument that cannot be stale:

```
python3 scripts/generate_api_description.py --check "$DB"
# ok   the API description matches the schema (842 functions, 367 tables, version 0742)
```

It diffs the live schema against the committed description, so it is
right by construction and names the migration version it is at. (The
`app` function count, 518, has held — but a count in prose is a
documentation number that rots, and this one did.) There is no
`supabase_migrations.schema_migrations` in a locally-built cluster, so
its absence is not evidence of an empty database.

## 5 October: PCB is 10 of 10, and the harness downgraded the database twice

`app.calc_pcb` — the monthly tax deduction — got the same treatment as
`calc_statutory`. Eleven mutants, in `supabase/tests/mutants/calc_pcb.py`,
each breaking one rule a Malaysian payslip depends on: the bonus annualised,
the EPF and SOCSO/EIS relief caps, zakat not deducted from the year's tax, a
disabled child's RM6,000, the claim percentage, the months-remaining divisor
(wrong in both directions), PCB already paid not credited, and spouse relief
paid to a working spouse.

**10 of 10 killed by `statutory.sql` alone**, control surviving. Unlike
`calc_statutory`, this function needs no second file, and the diagnostics are
exact — "a RM40,000 bonus is taxed once, in full: expected 2901.40, got
19659.3" is the `0446` defect being caught by name.

### THE MIGRATION YOU NAME IS THE ONE THE RESTORE PUTS BACK

The expensive part. **`grep -ln "create or replace function app.calc_pcb"`
names `0446` as the latest definition, and it is wrong.** `0530` redefines
the same function with the statement in a different CASE, which a
case-sensitive grep does not see — and `0446`'s name
(`the_bonus_that_was_taxed_every_month`) reads exactly like the last word on
this function.

`mutate_sql.py`'s restore re-applies the body from **the file you named**. So
the run restored `0446`, leaving the live `calc_pcb` paying RM8,000 for a
disabled child in higher education where `0530` pays RM14,000 — and every
later run of the suite then fails for a reason that is in neither the code
nor the test. Repair is to re-apply the right migration by hand:

```
psql "$DB" -v ON_ERROR_STOP=1 -f \
  supabase/migrations/0530_a_disabled_child_in_higher_education.sql
```

**The control caught it.** It was reported killed and the harness refused to
let the run be believed. That is the whole argument for insisting on one, and
it is now paid for in SQL as well as in Dart.

Always find the definition case-insensitively:

```
grep -lin "function .*<name>" supabase/migrations/*.sql | tail -3
```

### The guard, and the wrong first version of it

`mutate_sql.py` now compares the file's function body against `pg_proc`
before the baseline and refuses a mismatch, naming the differing line and the
grep that finds the real migration. It already read `prosrc` to confirm a
mutation landed, so the check costs nothing.

**The first version of that guard was wrong, and wrong in the way this
document keeps warning about.** It sampled four long lines from the file and
asked whether the live source contained them. `0446` and `0530` differ by ONE
NUMBER, all four sampled lines matched, the check passed — and the run
downgraded the database a *second* time. A sampling probe cannot detect a
one-line difference. It is now a whole-body comparison, whitespace-
insensitive, and verified in both directions: it refuses `0446`, and it
accepts `0530` and `0404` with no false positive.

### Where SQL mutation now stands

| function | mutants | accounted for | by |
|---|---|---|---|
| `app.calc_statutory` | 8 | 8 killed | four files between them; **4 of 8 by `statutory.sql` alone** |
| `app.calc_pcb` | 10 | 10 killed | `statutory.sql` alone |
| `app.annual_tax` | 10 | 9 killed + 1 proven equivalent | `statutory.sql` 8, `tax_bands.sql` 1 |
| bank rules | — | — | `supabase/tests/mutants/bank_rules.py`, from September |

**28 mutants across the three statutory functions, every one accounted for.**
The arithmetic behind a Malaysian payslip is genuinely asserted, not merely
covered.

`annual_tax` makes the per-file point a second time: `statutory.sql` kills 8
of 10, and the survivor that matters — `floor(p_chargeable)` becoming
`ceil`, which is LHDN's practice of ignoring sen — is killed by
`tax_bands.sql` instead. Every `annual_tax` call in `statutory.sql` is whole
ringgit, so that file cannot see it.

The tenth is the first **proven equivalent mutant** in the SQL work.
`if p_chargeable <= 0 then return 0` weakened to `< 0` returns 0 either way,
because the lowest band starts at `0.00` and `greatest(..., 0)` floors the
result. Proved by applying the mutant and calling the function rather than by
reading it, and written up beside the "tax on 5,000" assertion in
`statutory.sql` so nobody hunts for a test that cannot be written.

Still worth the same treatment: `app.round_statutory`, and the posting
functions behind a payslip.

## 5 October: the posting journal, and two real gaps

After the three statutory calculators came the journal they end up in:
`public.post_payroll_run`. Twelve mutants,
`supabase/tests/mutants/post_payroll_run.py`.

Ten died against `payroll_run.sql` — claims not netted off salary expense,
EPF and SOCSO payable losing the employer half, net salaries credited with
gross, the HRD levy expensed but never made payable, CP38 dropped from the
year's PCB, an empty run and a draft run becoming postable, the journal
misdated, and the permission check removed.

**But five of those ten died on "Journal does not balance".** That is the
double-entry invariant, not a statement about where the money went, and it
is a cheaper kill than it looks. So two more mutants were written that keep
the journal BALANCED and post to the wrong account.

| balanced-but-wrong-account mutant | outcome |
|---|---|
| PCB credited to the zakat payable account | **killed** — zakat has an assertion of its own |
| EPF ⇄ SOCSO employer expense accounts swapped | **survived four files** |

The survivor is the finding. Both are employer contributions of similar size
on adjacent codes — `6110` and `6120` — which is exactly the pair an eye
slides over. `payroll_run.sql`, `payroll_chart.sql`,
`statutory_remittances.sql` and `ea_form.sql` all stayed green.

**`payroll_chart.sql` looks like the file that would catch it and
structurally cannot.** It reads the fallback codes out of the function's
SOURCE with a regex and checks each one EXISTS in a freshly seeded chart,
with a positive control on the count. Swap two codes and every code named is
still a real non-group account, so it passes — it is a test that the chart
can support the journal, not a test of the journal.

A wrong split there is invisible in the trial balance's total and wrong in
every P&L that shows EPF and SOCSO separately. Three assertions closed it,
in the style the file already uses — each figure joined to its own code,
plus `both are non-zero, so neither passes on 0 = 0` — and the mutant now
dies on "the EPF employer contribution is charged to 6110".

### Where SQL mutation stands at the end of 5 October

| function | mutants | outcome |
|---|---|---|
| `app.calc_statutory` | 8 | all killed, by four files between them |
| `app.calc_pcb` | 10 | all killed by `statutory.sql` alone |
| `app.annual_tax` | 10 | 9 killed, 1 **proven equivalent** |
| `round_statutory`, `epf_category`, `age_at` | 8 | 7 killed, **1 real gap closed** |
| `public.post_payroll_run` | 12 | 11 killed, **1 real gap closed** |
| bank rules | — | `mutants/bank_rules.py`, September |

**48 mutants, two real gaps found and closed, one equivalent proved.** The
assertion floor went 14330 → 14332 → 14335, measured each time.

### The three transferable rules

1. **A per-file score understates the suite.** `mutate_sql.py` takes ONE
   test file and CI runs all of them, so a survivor is only a gap once every
   file that calls the function has been tried. This bit on `calc_statutory`
   (4 of 8 in one file, 8 of 8 across four) and again on `annual_tax`.
2. **A journal-balance failure is a cheap kill.** A mutation that moves money
   symmetrically balances perfectly. Prefer mutants that name an account.
3. **Prove an equivalent mutant, do not reason it.** `annual_tax`'s
   `<= 0` guard looks like a gap and is not; applying the mutant and calling
   the function with 0 and -5 settles it in one command.

### The sales journal: twelve files, and a one-word edit that reverses it

`app.post_sales_document_internal` posts every invoice, credit note, debit
note and refund note. Eight mutants,
`supabase/tests/mutants/post_sales_document.py`, all accounted for — and it
took **twelve test files**, with no single file killing more than three.

| mutant | killed by |
|---|---|
| the contact's own receivable account ignored | `control_accounts.sql` — its whole purpose |
| receivable line with both sides positive | `control_accounts.sql`, via a check constraint |
| a credit note posted the same way round as an invoice | `credit_note_return.sql` and `revenue_recognition.sql` |
| the exchange rate ignored | `credit_note_return.sql` |
| an unearned line crediting revenue on the day | `revenue_recognition.sql` |
| a credit note opening a deferral of its own | `revenue_recognition.sql` |
| output tax moved off `2130` | `sst_return_declares_what_was_charged.sql` — **after nine files had missed it** |
| **a debit note reversed like a credit note** | **nothing, until 5 October** |

**The gap.** Adding `'debit_note'` to
`case when doc_type in ('credit_note', 'refund_note') then -1 else 1 end`
is a one-word edit that reverses the journal, and it survived all twelve.
The type is handled by the function and required by the e-Invoice rules,
yet neither place that builds one produces a journal: `credit_control.sql`
posts one only to watch the credit limit REFUSE it, and `sst_summary.sql`
inserts a row already marked `'posted'` without going through the function.
A reversed debit note moves a customer's balance the wrong way by twice its
value and balances perfectly. Closed with two assertions in
`control_accounts.sql`.

**The near-miss is worth as much.** The output-tax mutant survived NINE
files and was about to be reported as a statutory gap in the account a
Customs officer ties the SST return to. The tenth killed it, on
`sst_return_declares_what_was_charged.sql`'s positive control — "there is
tax to declare in the first place". Third time in one day that a per-file
score nearly became a false alarm.

Also: that function is declared `CREATE OR REPLACE FUNCTION` in UPPER CASE,
so `awk '/function app\.post_sales/'` finds nothing. Same case-sensitivity
that hid `0530` from a `calc_pcb` search. `mutate_sql.py` reads with `re.I`.

### SQL mutation, final tally for 5 October

| function | mutants | outcome |
|---|---|---|
| `app.calc_statutory` | 8 | all killed, four files |
| `app.calc_pcb` | 10 | all killed, `statutory.sql` alone |
| `app.annual_tax` | 10 | 9 killed, 1 proven equivalent |
| `round_statutory`, `epf_category`, `age_at` | 8 | 7 killed, **1 gap closed** |
| `public.post_payroll_run` | 12 | 11 killed, **1 gap closed** |
| `app.post_sales_document_internal` | 8 | 7 killed, **1 gap closed** |
| bank rules | 5 | September |

**56 mutants over nine functions, three real gaps found and closed, one
equivalent proved.** The assertion floor went 14330 → 14332 → 14335 →
14337, measured every time.

Every gap was a thing the eye slides over: a default nobody states, two
adjacent account codes, one word in a list of document types. None was a
weak assertion — they were absent ones, in paths that either nothing drives
or nothing looks at after driving.

### Where money lands: three gaps, and a timestamp that orders nothing

`app.post_receipt_internal` is the function `0728` found holding the LAST
surviving `code = '1120'` fallback, and `0731` replaced it with a
three-tier resolution: a gateway's settlement account, else the company's
default ACTIVE account, else the OLDEST active one, never a closed or client
account, and the answer written back onto the receipt. Ten mutants, one per
rule.

All ten accounted for, and **three were real gaps.**

| mutant | killed by |
|---|---|
| a CLOSED account receives the money | `money_names_the_account.sql` |
| a CLIENT account receives the firm's money | same |
| the gateway's settlement account loses priority | same |
| a company with no bank account posts silently | same |
| the contact's own receivable account ignored | `control_accounts.sql` |
| the bank charge not taken off the net | `bank_reconciliation.sql`, on a balance failure |
| the exchange rate ignored | `multicurrency.sql` |
| **`b.is_default desc` dropped from the tiebreak** | **nothing, until 5 Oct** |
| **`b.created_at` reversed to `desc`** | **nothing, until 5 Oct** |
| **the repost guard deleted** | **nothing, until 5 Oct** |

**The first two gaps shared one cause.** In the fixture the default account
was ALSO the oldest active one, so `order by is_default desc, created_at`
and `order by created_at` pick the same row — and two orderings that agree
cannot say which was used. That is the twelfth way, in a bank-account
fixture instead of a 1120 one. Fixed by creating an ordinary account FIRST
and the default SECOND, so the orderings disagree.

#### `created_at` DEFAULTS TO `now()`, WHICH IS THE TRANSACTION TIMESTAMP

The thing worth carrying out of this whole exercise, and the new block's own
positive control is what found it: **every row a test fixture inserts has
the SAME `created_at`**, because `now()` in Postgres is the transaction
timestamp and the suite runs each file in one transaction. So

```sql
order by b.is_default desc, b.created_at
```

orders nothing among fixture rows, and `created_at` versus `created_at desc`
is not a difference any single-transaction test can see. The assertion "the
default is not the oldest, so the two orderings disagree" FAILED on its
first run and said so, which is exactly what a positive control is for.

The block now sets them apart by hand:

```sql
update public.bank_accounts
   set created_at = now() - interval '2 days' where id = v_older;
```

**CORRECTION, same day.** This first said "nothing else in the suite does
this", and that is false: **twelve lines across eight files set `created_at`
explicitly** — `chat.sql`, `idempotency.sql`, `pos_counting.sql`,
`pos_drawer_shapes.sql`, `contact_duplicates.sql`,
`audit_trail_filters.sql`, `kept_files_in_the_inbox.sql`. Checked rather
than assumed, after the overstatement was already committed.

Every one of them is about **AGE**, not about order: an edit window of
twenty minutes, an expiry at twenty-five hours, dormancy at eighteen months,
a March date for duplicate detection. None separates two rows competing in
an `order by ... created_at` tiebreak, and before `money_names_the_account.sql`
nothing did.

So the narrower, true claim: **35 functions in `app` and `public` pick ONE
row by ordering on `created_at`** (`prosrc ~* 'order by[^;]*created_at[^;]*limit 1'`,
out of 72 that order on it at all, plus one window function). For every one
of them the ordering is invisible to a single-transaction test unless that
test sets the timestamps apart — and exactly one now does. That is a general
hole rather than a local one, and the best lead left for anyone continuing
this work.

**The third gap** is the repost guard: `if v_rcp.gl_entry_id is not null
then raise` could be deleted and every file that posts a receipt stayed
green. A receipt posted twice banks the same money twice and doubles the
customer's credit.

### SQL mutation, the whole of 5 October

| function | mutants | outcome |
|---|---|---|
| `app.calc_statutory` | 8 | all killed |
| `app.calc_pcb` | 10 | all killed |
| `app.annual_tax` | 10 | 9 killed, 1 equivalent proved |
| `round_statutory`, `epf_category`, `age_at` | 8 | 7 killed, **1 gap** |
| `public.post_payroll_run` | 12 | 11 killed, **1 gap** |
| `app.post_sales_document_internal` | 8 | 7 killed, **1 gap** |
| `app.post_receipt_internal` | 10 | 7 killed, **3 gaps** |

**66 mutants over ten functions, SIX real gaps found and closed, one
equivalent proved.** Floor: 14330 → 14332 → 14335 → 14337 → 14341, measured
every time.

### Two defaults is the same as none: nine tables, and 0092 said so in 2024

Task #83 set out to measure the `created_at` ordering hole and ended at a
fix, because the measurement kept pointing at one shape.

**What was measured.** Over the latest definition of every function in
`supabase/migrations/` (latest, not first — `latest_defining()` in
`scripts/mutate_sql.py` exists because a case-sensitive grep named the
wrong file twice):

- 73 `order by` clauses mention `created_at`, across 62 functions
- 45 of those pick ONE row (`limit 1`), across 35 functions
- 27 pick one row ordered **solely** by `created_at`, across 21 functions

`created_at` defaults to `now()`, which is the TRANSACTION timestamp, so
every row one transaction inserts carries the same value and
`order by created_at limit 1` picks by physical row order. Demonstrated
live, not argued: one org, two active warehouses inserted together, the
first `app.default_warehouse` call returned W1; rewriting W1's *name* —
which changes where the row sits and nothing about the ORDER BY — made
the next call return W2.

**Three of the 27 turned out to be safe, and the reason matters.**
`app.pos_deplete_recipes` reads back the movement it has just inserted
with `order by sm.created_at desc limit 1`, keyed only on sale and item —
which looks exactly like the bug, and is not, because the loop it sits in
is `group by n.item_id`: one movement per item, so the predicate matches
exactly one row. Only two functions in the repository insert a
`'pos_sales'`-sourced movement at all, so nothing else can add a second
in the same transaction. Structural, not lucky. The same reading cleared
`post_stock_adjustment`, whose predicate is per LINE.

**The real hole was not the ORDER BY. It was that nothing stopped a
second default.** Nine tables carry `is_default` with no uniqueness:
`bank_accounts`, `branches`, `payment_terms`, `pipelines`,
`pos_modifiers`, `price_levels`, `tax_codes`, `warehouses`,
`work_shifts`. Twenty-three functions pick a single row out of them,
among them where a group payment's money lands
(`record_group_payment`) and which warehouse a POS sale depletes.

**And this project already fixed this bug class, once, in 2024.**
`0092_one_default_per_contact.sql` found it on `contact_addresses` and
`contact_persons`, named it better than this section does -- "Two
defaults is the same as none. Whichever row the query happens to return
first wins, the answer can change between two runs of the same query,
and the thing it decides is where goods get delivered" -- and closed it
with a partial unique index. Six more tables have been given the same
index since, one at a time, as each was built. Nine never were.

`0741_two_defaults_is_the_same_as_none.sql` gives it to **eight** of the
nine, on `(org_id) where is_default and is_active`, with 0092's
demote-duplicates-first preamble so a failed index build cannot leave the
migration half-applied. Live was checked read-only first: no duplicates
in any of them, so this is a door being closed, not a mess being cleaned
up.

#### Both of the first version's mistakes were caught by the suite, not by me

This is the part worth keeping. The first version of 0741 covered all
nine tables and used the stronger predicate, `where is_default` alone.
Fourteen hand-written assertions passed against it, and three deliberate
mutations of the index were killed. It was wrong twice, and the full
`run_locally.sh` -- the thing it is tempting to skip because the change
"is only an index" -- named both in one run.

**`pos_modifiers` should not have an index at all.** It was indexed on
`(group_id)`: one pre-selected option per modifier group, which sounds
right. `pos_fnb.sql` has asserted since `0250` that *"a group that takes
two takes two defaults, and not a third"* -- `upsert_pos_modifier_group(
org, 'SAUCE', 'Sos', 0, 2)`, `max_select = 2`. The limit is the group's
own column, enforced where that column can be read; a partial unique
index cannot express a rule living in another table, and `(group_id)`
caps every multi-select group at one default. Dropped from the migration.

**`and is_active` is not optional.** The reasoning for leaving it out was
that no path retires a row without clearing the flag, so a retired row
holding a stale default cannot arise -- which is true of the app and
false of the suite. `money_names_the_account.sql` builds exactly that row
ON PURPOSE: a closed account still flagged default, beside an open one,
because what it tests is that the readers skip it. All seven
`bank_accounts` readers do filter `is_active`, so that fixture states the
contract. An index forbidding the state forbids testing the defence
against it.

The lesson is not "run the tests", which everybody already says. It is
that **a constraint's correctness is a claim about every fixture in the
repository, and nine tables' worth of that claim is not checkable by
reading.** Both refutations were single lines inside 11,000-line files
that no targeted grep of mine was going to surface -- the first search
tried was for fixtures inserting two defaults, and it found 113 warehouse
inserts and no way to rank them.

#### The grep that missed 0092, which is the third time for this mistake

Searching for the precedent returned nothing, twice:
`grep "unique index.*is_default"` and `grep -i "unique index" | grep -i is_default`.
Both require the two phrases on ONE line. 0092 writes

```sql
create unique index if not exists contact_addresses_one_default
  on public.contact_addresses (contact_id) where is_default;
```

— two lines. Had the precedent stayed missed, 0741 would have been
written as though no one had thought about this before, with a worse
header and probably the weaker predicate. The same too-narrow-search
mistake is already recorded twice in this file against other people's
code; it is recorded here a third time against this session's own.
**The reliable form is to ask the catalogue, not the text:** the query
over `pg_index`/`pg_attribute` that produced the nine-versus-eight split
cannot miss an index for being wrapped.

#### What the test asserts, and the ways an index can be wrong

`supabase/tests/one_default_per_company.sql`, 14 assertions. An index can
be wrong in three directions and only the first is obvious, so each has
its own assertion, and each was proved by applying the mutation:

| mutation | what caught it |
| --- | --- |
| `drop index warehouses_one_default` | `FAIL warehouses refuses a second default for one company: it was not refused at all` |
| `bank_accounts` tightened to `where is_default`, dropping `and is_active` | "a closed account may keep a stale default beside the open one" |
| `warehouses` scoped globally — `((true)) where is_default and is_active` | "each company keeps its own default warehouse" |
| re-add the `pos_modifiers` index 0741 omits | `pos_fnb.sql` goes red — the exclusion is guarded by a test that already existed |

Control run clean. The second and third rows are the ones that matter:
an index that refuses FAR TOO MUCH passes every refusal assertion, so a
test built only out of "was it refused?" is blind to the direction this
migration got wrong twice.

The last section is the one the index exists for: an ordinary warehouse
inserted FIRST, the default SECOND, then the two given `created_at` two
days apart so the orderings disagree, and
`app.default_warehouse` asserted to return the DEFAULT rather than the
oldest active row. A fixture whose default is also its oldest row cannot
tell those two implementations apart — the twelfth way in
`docs/widget-tests.md`, in SQL again.

#### What is left, and it is honest to call it a lead

The index closes the `is_default` tier. It does not touch the FALLBACK
tiers: `app.default_warehouse`'s second query is
`where org_id = ... and is_active order by created_at limit 1`, with no
`is_default` at all, and that is still decided by physical row order when
an org's active warehouses share a transaction timestamp. In production
they rarely do — rows created minutes apart have different timestamps —
so this is a fixture-determinism problem before it is a production one.
The mechanical fix is `order by created_at, id`, which is total and
cannot change an answer that was already determinate. It is deliberately
NOT applied here in bulk: each function needs a `create or replace`, and
re-defining a function to fix one line is how `0029` reverted `0404`'s
`calc_statutory` earlier in this same session.

### 0742: fix the premise, not the thirteen bodies

0741's header named what it left open, and task #84 closed it the same
day. Thirteen functions pick a default WAREHOUSE or PIPELINE with

```sql
where org_id = ... and is_default limit 1
```

and no `is_active` -- eleven of them with no `order by` either, so not
even a stable arbitrary answer. 0741's index is
`(org_id) where is_default and is_active`, which makes the ten readers
that DO filter `is_active` provably single-rowed and does nothing for
these thirteen: a warehouse that is closed but still flagged default is a
second matching row, and whichever one the plan reaches first is where a
sale gets depleted from.

**The obvious fix was the wrong fix.** The thirteen are
`app.post_sales_document_internal` (10,902 characters),
`public.complete_pos_sale` (27,407) and eleven more. Adding one word to
each means thirteen `create or replace` statements carrying ~80KB of
re-emitted body -- and re-emitting a body to change one line is exactly
how, earlier the same week, re-applying `0029` to restore one function
reverted `0404`'s `calc_statutory`. Thirteen of those is thirteen
chances at the same accident, for a one-word edit each.

So `0742_a_closed_warehouse_is_nobodys_default.sql` fixes the premise
instead. If a row cannot be default while inactive, then
`where is_default` and `where is_default and is_active` select the same
rows, all thirteen become correct **as written**, and no function is
touched:

```sql
alter table public.warehouses
  add constraint warehouses_default_is_active
  check (not (is_default and not is_active));
```

The app has always behaved as though it were there -- `retireWarehouse`
writes `is_active = false, is_default = false` together -- so this makes
a convention into a guarantee, which is the same move 0092 made. Live
was checked read-only first: zero stale defaults in warehouses,
pipelines or any of the other six, so the repair ahead of the CHECK is
expected to update nothing and is there because a CHECK validates
existing rows as it is added.

`bank_accounts` deliberately does NOT get this constraint, for the reason
0741 learned the hard way: `money_names_the_account.sql` builds a closed
account that still carries `is_default`, on purpose, because all seven
`bank_accounts` readers filter `is_active` and what the fixture tests is
that they skip it. The same argument covers branches, tax_codes,
price_levels, payment_terms and work_shifts -- their readers all filter
`is_active`, so the constraint would buy them nothing and could only
forbid a fixture.

Five more assertions in `one_default_per_company.sql` (19 now), each
proved by mutation: dropping either CHECK, and inverting the warehouse
one to `check (is_default or is_active)` -- which forbids the state the
app actually writes -- all three turn it red, control clean.

One of those five was written as `0 = 0` and had to be repaired on the
spot. After retiring the only warehouse, both
`where is_default` and `where is_default and is_active` count zero, and
an assertion that they agree is satisfied by nothing existing. A fresh
default is now inserted first and a second assertion pins the count at
ONE. **This is the twelfth lesson being walked into within the hour of
writing it up** -- the fixture collapsed the two things under test into
the same value, and the trap does not announce itself just because you
have read about it.

#### The gate, and the four false positives that shaped it

`scripts/check_default_readers.py` keeps the rule as a disjunction rather
than a ban:

> a function may read `is_default` without a liveness filter ONLY IF that
> table carries a `<table>_default_is_active` CHECK.

Either the query asks the question or the schema answers it in advance.
Dropping the CHECK while the bare readers remain fails it too, which is
the half a migration-only review would miss, and is pinned by a test
(`gate.offenders(allowed=set())` must name `app.pos_deplete_recipes`,
`public.complete_pos_sale` and at least nine more).

**The first version reported five findings and four were wrong**, all one
shape: `update <table> set is_default = false where ... and is_default`,
the clear-the-old-default half of a setter. There, NOT filtering on
liveness is the correct behaviour -- a retired row holding a stale flag
is exactly what wants clearing. The fifth,
`app.bank_charge_account`, was also not a defect: it filters
`deleted_at is null`, because a payment method can be switched off
without being deleted and its charge account is still needed for last
year's postings.

So the gate judges `from`/`join` and never `update`, accepts any of four
liveness spellings, and requires the pick to be of ONE row (`limit 1`, or
a `select ... into`, which takes the first row whether it says so or
not). All four false positives are pinned as must-not-report in
`check_default_readers_test.py`, because the shape is easy to
reintroduce while "tightening" the pattern, and **a gate that flags
correct code is a gate somebody turns off.**

Three things it is deliberately blind to, each because it would need
judgement: which liveness column is right, whether some other unique
index makes a pick single-rowed anyway, and anything about writes. This
file records four gates thrown away on 4 October for needing judgement;
the unique-index-implication version would have been the fifth.

1354 function definitions checked, from the LATEST definition of each --
`scripts/mutate_sql.py`'s rule, because a case-sensitive grep for
`create or replace function` named `0446` as the latest `app.calc_pcb`
and was wrong by RM6,000 of relief, twice. 19 self-tests. The gate count
`check_sweeps_look.py` sees is 69, still 0 passing over nothing, and
`check_self_tests_run.py` named the missing ci.yml line before CI had to.

#### The gate's own hand-kept list was wrong within the hour

`check_default_readers.py` shipped with its scope as a tuple of fourteen
table names, typed out from the analysis that had just been done. Asking
the catalogue the next question -- "are there other singleton flags?" --
showed the tuple was wrong twice:

- it **omitted `pos_modifiers`**, which carries `is_default` and
  `is_active` and so is exactly in scope; and
- it **named `contact_addresses`**, which carries `is_default` and no
  liveness column at all, so every row is live, no reader can pick a
  second one by accident, and there is nothing there to judge.

Two errors in fourteen entries, written and found inside an hour, by the
author of the analysis they were copied from. That is the whole argument
against a hand-kept list, made by the shortest possible example, and
`ci.yml` already says it in prose about the assertion-file list: *"a
hand-kept list of tests goes stale in the one direction that is
invisible."*

So the scope is now DERIVED: `_columns()` parses `create table` and
`alter table ... add column` out of the migrations, and `in_scope()`
keeps a table only if it declares one of `is_default`, `is_primary` or
`is_lead` AND something that can make a row stale (`is_active`,
`deleted_at`, `is_deleted`). It derives exactly the fourteen the live
catalogue reports, which is how the derivation was checked -- against
the database, not against the list it replaced.

The four excluded are `contact_addresses`, `contact_persons`,
`item_barcodes` and `ticket_team_members`. All four already have the
one-default unique index; none can have THIS bug.

Mutations, each verified to have applied before being believed:

| mutation | result |
| --- | --- |
| break the `create table` regex | scope -> 0 tables, gate exit 1 on the canary, 6 tests fail |
| drop the liveness requirement from `in_scope` | `contact_addresses` re-enters scope, gate exit 1, 5 tests fail |
| drop `is_primary`/`is_lead` from `SINGLETON_FLAGS` | ONE unit test fails; **the gate still exits 0** |

The third row is worth stating plainly rather than hiding in a count: no
table today needs `is_primary` or `is_lead` judged, because the four that
carry them have no liveness column. The unit test is the only thing
holding that capability for when a table appears that does need it.

#### Two gates read as passing because of a shell pipe

Twice in this stretch `echo "exit=$?"` was written after a command that
had been piped through `head` or `tail`, so it reported the PIPE's exit
status and not the program's. Both times a gate that had correctly
returned 1 -- printing `::error::` in the same output -- read as
`exit=0`:

```
python3 scripts/check_default_readers.py 2>&1 | head -2; echo "exit=$?"
  ::error::the canary ... proves nothing about the sweep
  exit=0
```

Measured without the pipe the same run is `exit=1`. Nothing was
published on the strength of the wrong reading, because the `::error::`
line was visible above it both times -- but the two disagreed in the
output and the pipe is the liar. `set -o pipefail`, or redirect to a
file and read it afterwards, which is what the corrected check does.

The first instance was read as a bug in `check_self_tests_run.py` --
"it reports a problem and exits 0" -- and briefly nearly written down as
one. It was not; the gate was right and the measurement was wrong.

### record_group_payment: 15 of 17, and no gaps

The widest single money mover in the schema -- one payment across
several companies, writing a receipt or a purchase payment per (company,
contact, currency), allocating every document and posting each one.
Seventeen mutants in
`supabase/tests/mutants/record_group_payment.py`, attacking three kinds
of claim separately: the eight refusals, the grouping, and the figures.

**15 killed, 2 proven equivalent, NO GAPS.** That is the strongest result
of any function mutated in this session; the earlier ten averaged better
than one real gap each. Nothing was added to the suite because there was
nothing missing -- the assertion floor is unchanged.

| file | kills |
| --- | --- |
| `group_payment.sql` (61 assertions, 27 calls) | 13 of 17 |
| `group_payment_shapes.sql` (62, 30) | 10, four of them the ones the first file missed |
| `money_names_the_account.sql` (40, 1) | **none** |

**The per-file survivor counts were 4 and 7. The union is 2.** That is
the whole argument for running every file that calls the function,
in one line of evidence: either file alone would have reported five or
six gaps that the other file closes. The third file kills nothing at all,
and that is not a defect in it -- its single call sits in a section
asserting where the money lands, which none of these mutations move.

The two equivalents, both proven rather than argued:

1. **Widening the loop's `group by org_id, contact_id, currency`** cannot
   change the groups, because an earlier guard already refuses a payment
   where one (org, contact) appears in two currencies. The proof is that
   the mutant which DISABLES that guard is killed by
   `group_payment.sql` -- so the guard demonstrably fires, so the loop
   can never see two currencies for one pair. The `currency` in the
   GROUP BY is defensive and dead. Same shape as the canary check that
   made its own floor test unreachable earlier today. Left in place:
   removing dead defence from a money function is not worth the edit.
2. **`nullif(l.discount, 0)` -> `l.discount`.** Both 5-arg allocators
   (`0385` sales, `0386` purchase) use `p_discount` in exactly ONE place,
   `v_discount := round(coalesce(p_discount, 0), 2)`, and nowhere else in
   either body -- established by listing every line that mentions it, not
   by reading the top of the function. The `coalesce` absorbs the
   difference. Worth noting the 6-arg idempotent overloads in `0734` DO
   put `p_discount` into the idempotency fingerprint, where 0 and null
   differ; `record_group_payment` calls the 5-arg form, so that path is
   not reached from here.

#### A mutant that was a no-op, and was nearly a finding

The grouping mutant's first version was
`group by org_id, contact_id, currency, currency` -- a DUPLICATE column,
which changes nothing whatsoever. It "survived" 61 assertions because
there was nothing to survive, and the write-up of it as a gap in the
suite had already begun. **A mutant has to be checked for being a no-op
before its survival means anything**, which is the same discipline the
CONTROL entry enforces for the harness as a whole, applied one mutant at
a time.

#### The health-check numbers in this file were wrong

This file has recorded the local cluster's health check as
"518 `app` functions / 381 public tables". After the worker restarted and
the cluster was rebuilt, it read **518 and 379** -- and 379 is correct.
The authoritative check is

```
python3 scripts/generate_api_description.py --check "$DB"
# ok   the API description matches the schema (842 functions, 367 tables, version 0742)
```

which diffs the live schema against the committed description and so
cannot be stale by construction. Two remembered counts can; one of them
already was, and two minutes were spent looking for two tables that had
never gone missing. **A health check whose expected value is written in
prose is a documentation number that rots** -- the same lesson as "about
two minutes" for the SQL suite and the deno test count, arriving this
time in the instrument meant to detect rot.

Also recorded in passing: the first draft of the mutants header said
`group_payment.sql` has 69 assertions, from grepping occurrences of
`check_eq|check_true|check_refused`, which also counts the helper
definitions. The run prints 61. Ask the run, not the text.

### transfer_between_matters: the worst score of the session, and a real defect

Client money, moved between two of the same client's matters. Chosen as
the riskiest target left on three signals, all of which proved right:
the function has been redefined **five** times (0358, 0690, 0696, 0698,
0739), exactly **one** test file calls it, and what it governs is
regulated.

Nineteen mutants. **Ten killed, EIGHT survived** — the worst first-run
score of any function measured this session, and with one calling file
nothing else in the suite could rescue them. After the work: 18 of 18
killed, control survived.

**Five were plain missing assertions**, and the list is uncomfortable for
a client-money function:

| survivor | what it means |
| --- | --- |
| `deleted_at` dropped | a deleted matter can be moved from, and to |
| `org_id` dropped on the destination lookup | client money crosses from one COMPANY's matter to another's |
| `has_module(...,'legal')` dropped | a company with no legal module moves client money |
| `can_post` dropped | **a stranger moves a firm's client money** |
| `status <> 'void'` dropped | a BOUNCED cheque counts as money the matter holds |

**Three were the one-bank-account fixture collapse.** The fixture had
exactly one bank account — the client account `setup_legal_module`
creates — so "a client account", "an active account" and "the default
account" were all the same row, and no assertion could say which rule
picked it. The twelfth entry in `docs/widget-tests.md`, in SQL, again.

#### Enriching the fixture was not enough, and that is the interesting part

The four bank-account rules **cannot all be observed in one company.**
`0741` gives `bank_accounts` a unique index on
`(org_id) where is_default and is_active`, so a company has at most one
default active account. To show that `is_client_account` is what keeps
client money out of the office account, the office account has to be the
default — and then no client account is the default, so
`order by is_default desc` has nothing to order. The two requirements
exclude each other. Hence two firms in the fixture, each configured so
that a different pair of rules disagree.

Chasing the last of them found a real defect. The bank is chosen with

```sql
   order by is_default desc limit 1;
```

with **no tiebreak**, so when no client account is the default the choice
is made by physical row order. Demonstrated, not argued: a firm with two
open client accounts and neither marked default returned account A, and
after account A's NAME was rewritten — which moves the row and changes
nothing about the ORDER BY — the same query returned account B.

And that is the ORDINARY configuration, not a corner case: a firm whose
company default is its office current account has no default client
account at all, so every transfer between matters picks whichever of its
client accounts the plan reaches first. Nothing is lost from the client
bank — both legs are the same two accounts with the signs reversed — but
which account the firm's own client ledger says the money sits in is
arbitrary, and reconciliation is done per account.

`0743_which_client_account_when_there_are_two.sql` makes the ordering
total: `order by is_default desc, created_at, id`. `created_at` alone is
not a total order — it defaults to `now()`, the transaction timestamp, so
two accounts created by one statement share it — which is why `id`
follows. It cannot change an answer that was already determinate.

The fixture pins it the only way that works: firm B's second client
account is inserted SECOND and dated EARLIER, so the correct row and the
first row are different ones. A fixture where the right account is also
the first account cannot tell a total ordering from no ordering at all.

#### `%privileges%` let the security mutant live

The first version of the stranger assertion matched `'%privileges%'`.
The mutant that deletes `can_post` **survived it**: with the guard gone
the stranger gets further and is turned away by a different guard whose
message also contains the word, so the assertion passed either way. The
whole message — `Insufficient privileges to move client money` — kills
it.

`bank_transfers.sql` already records this trap, in almost these words:
*"the same SQLSTATE and one word less, so the message is what says which
of the two turned them away. Whole message, not a fragment."* It was read
during this very session, while looking up how the suite writes a
no-rights refusal, and the fragment was written anyway.

#### Defence in depth, found by accident

The office-account mutant is killed by a message nobody here wrote:
`Bank account "Akaun pejabat" is not a client account.` That is `0740`
refusing downstream, so `transfer_between_matters` was never the only
thing standing between client money and the office account. The new
fixture is what makes that second door fire, and prove it fires.

#### A migration of mine was missing its semicolon, and psql did not mind

`0743`'s body was extracted from `0739` programmatically, and the
extraction stopped at the closing `$function$` — dropping the
statement's `;`. `psql -f` applied it and printed `CREATE FUNCTION`,
because psql flushes its buffer at EOF. The mutation harness refused it:
its pattern requires `\1\s*;`. **The stricter tool caught a malformed
migration that the real one accepted.**

Sweeping the directory for the same shape found one more:
`0540_a_counter_sale_of_dated_stock.sql` ends `end;\n$function$` with no
semicolon. It is applied, so append-only says leave it — recorded here
instead. It is latent rather than live: migrations are applied one file
at a time, and only a tool that CONCATENATED them would produce
`end $function$ CREATE TABLE ...` and fail. Six other migrations end in a
comment, which is fine.

### The terminator gate, and the nine false positives it opened with

`scripts/check_migration_terminators.py` (task #85) asks two structural
questions of every file in `supabase/migrations/`:

- does the last line that is not blank and not a comment end in `;`?
- does every dollar-quote tag appear an even number of times, so no
  function body is left open?

745 migrations, one allowed by name. The allowance is
`0540_a_counter_sale_of_dated_stock.sql`, which ends `end;\n$function$`
with no semicolon and is already applied; this directory is append-only,
so it is named with its reason rather than edited. The gate also refuses
to run if an allowlisted file has since become clean or disappeared --
an excuse nobody is using reads to the next person as a rule.

**It opened with nine findings and all nine were correct code.** Every
one was a `comment on ... is` whose prose contains a double dash:

```sql
comment on function public.void_pos_sale(...) is
  '... the lines are kept -- they are what was written off.';
```

`re.sub(r"--.*$", "", line)` throws away the closing quote and the
semicolon with it. The stripper is now quote-aware (and treats `''` as
an escaped quote, not the end of a literal), and both shapes are pinned
in `NOT_FAULTS` as must-not-report, checked by `main()` before the floor.
Same discipline as the four `update ... set is_default = false` writers
pinned in `check_default_readers_test.py`, and for the same reason: **a
gate that flags correct code is a gate somebody turns off.** Two gates
in a row have now had that failure on their first run, both from a
regex applied without regard to what it was inside.

Four mutations, each verified to have APPLIED before being believed:

| mutation | result |
| --- | --- |
| strip the `;` off `0743` | gate exit 1, naming the file |
| revert the stripper to the naive regex | gate exit 1, on the must-not-report canary |
| empty the allowlist | gate exit 1, naming 0540 |
| make the dollar-quote balance check return `[]` | **gate stays green**; one unit test fails |

The fourth row again: no migration at HEAD has an unbalanced tag, so the
live sweep does not exercise that half at all, and
`test_an_unclosed_body_is_reported` is the only thing holding it. That is
the second capability in two gates kept alive solely by its unit test --
the first was `is_primary`/`is_lead` in `check_default_readers.py`.
Worth stating rather than burying in a count.

#### `git checkout --` does not revert an untracked file

The mutation run was done with `git checkout -- <gate>` between mutants,
and the gate was a NEW file -- untracked. `git checkout` printed
`error: pathspec ... did not match any file(s) known to git` and changed
nothing, so mutant two stayed applied, mutant three was measured on top
of it, and **the control ran against a doubly-broken gate.** The control
is what caught it: it came back red, which a control may never do.

Three things follow, and the first is the one to keep:

1. **The control earns its place on the harness as well as the subject.**
   `mutate_sql.py` and `mutate.py` both demand one; this run had one by
   habit rather than by the tool, and it still did the job.
2. Revert with a file copy taken before the first mutation, not with
   version control, whenever the subject may be untracked.
3. Assert the mutation APPLIED. The earlier `sed` attempt at the same
   mutation matched nothing — `grep -c` said `0` — and the tests failed
   anyway for an unrelated reason, which read exactly like a kill. Every
   mutation in this stretch now goes through a Python replace with
   `assert s != before, "MUTATION DID NOT APPLY"`.

### The three client-money movers: eight more, and the same three families

`scripts/mutation_targets.py` put `public.pay_from_client_account` top of
its ranking, and the three functions in `0549` — money in, money out,
and the crossing to office — were mutated together.

**21 mutants. 13 killed, EIGHT survived. 21 of 21 after the work, and
nothing was equivalent.** `client_account.sql`, the only other file that
names any of them, killed **none** of the 21, so the union is one file.

The eight fell into exactly the three families found in
`matter_transfer.sql` hours earlier, and that repetition is worth more
than the eight:

1. **Three unasserted `can_post` guards, one per function.** A stranger
   could pay money onto a matter, pay money out of it, and cross it to
   office. All three raise the same sentence, which is why the
   assertions use the whole message.
2. **`status <> 'void'` in the payout check**, so a bounced receipt
   funded a disbursement.
3. **Four bank-selection rules on `receive_client_money` collapsed into
   one account** — the fixture's ordering landed on the client account
   whichever rule was doing the work.

The pattern across both: in a family of functions written in one
migration, a guard that nobody asserted in the first one is unasserted
in all of them. The mutation run found the same hole three times in
three functions, because they were written from the same template.

#### The update order in a tiebreak fixture, which cost a survivor twice

To show that a total ordering beats no ordering, the fixture needs the
correct row and the physically-first row to be DIFFERENT rows. Two open
client accounts, the second created later but dated earlier, then both
`created_at` values rewritten.

**Which one is rewritten last decides the physical order**, because an
UPDATE writes the new row version at the end of the heap. Updating the
older one last puts it after the newer one, so a query with no tiebreak
answers the same row as a query with one, and the mutant that deletes
the tiebreak survives.

That happened in `client_money_crossing.sql`, where it was the single
survivor of the second run. Fixing it exposed the same mistake in
`matter_transfer.sql`, written an hour earlier, whose comment claimed
the two orderings disagreed when they did not — there the mutant was
killed by a different assertion (call it twice after rewriting a row,
and the answer must not change), so the score was right and the stated
reason was wrong. Both fixtures now update the newer row last, and in
matter_transfer the mutant is killed by both assertions instead of one.

A note on fragility, since this is a test that depends on heap order: it
is deterministic for a fixed sequence of operations on a given
PostgreSQL, which is what CI runs, and the determinism assertion beside
it does not depend on heap order at all. If it ever does flake, the
determinism half is the one to keep.

### post_landed_cost_run: 14 of 15, and the 1120 bug again on the stock side

Next off `mutation_targets.py`'s ranking. **15 mutants, 14 killed on the
first run** — the best first-run score of anything measured this
session. `landed_cost.sql` already asserted the ratio, the sen, both
sides of the journal, the movement-to-journal link and the status, and
its balance check caught every sign mutation outright:

```
killed  the charge accounts are DEBITED and inventory credited
        -- Journal does not balance: debits 800.00, credits 0.00
```

**A balance check is a cheap kill for an ASYMMETRIC mutation and
useless against a symmetric one.** The rounding-order mutant — which
reverses `order by c.line_no` so the FIRST charge line absorbs the
rounding instead of the last, moving one sen between two accounts —
balances perfectly, and was caught only by an assertion naming the
account and the figure. That is the same rule the payroll run taught in
an earlier stretch, arriving again from the other direction.

The one survivor was `not is_group` on the 1310 lookup:

```sql
select id into v_inv from public.accounts
 where org_id = v_run.org_id and code = '1310' and not is_group;
```

It survived for the same REASON `0727`/`0728` went unnoticed for a
year: **the seeded 1310 is postable, so "the inventory account" and
"any account coded 1310" are the same row**, and nothing could say which
rule found it. Closed with a company whose 1310 is a heading, which must
get the refusal rather than a posting onto the parent, plus an assertion
that a 1311 beneath it is not 1310 either.

It is NOT the same MECHANISM as the 1120 bug, and the first version of
this section said it was. See the correction below: `1120` has
`is_group = false`, so a `not is_group` guard would never have caught
it.

#### The positive control I wrote was wrong, and the exact message saved it

The block first ended by making 1310 postable again and asserting the
run then posts — "so the refusal was about the heading and not the run".
It is not: that run has no bills, so it still refuses, with
`Those bills have no stocked goods on them`. The assertion was written
as though the heading were the only thing standing in the way.

What actually discriminates is that `check_refused` matches the **whole
message**. With `not is_group` deleted the function finds the heading,
gets past that check, and refuses further down for the other reason — a
different sentence, so the assertion reports *"refused, but for the
wrong reason"* and the mutant dies. A `%inventory%` fragment would have
passed against both. That is the third time in this session the whole
message has been the thing doing the work, and the second time a
fragment would have hidden a mutant.

The positive control is the rest of the file, which posts runs
successfully several times over. Written down rather than re-invented
locally, because a local one here needed a bill, a received line and
stock on hand to say what three existing blocks already say.


### The is_group audit that found nothing, and the claim it corrected

`app.post_goods_received_internal` looks up the inventory account with
`where org_id = ... and code = '1310'` and NO `not is_group`, where
`post_landed_cost_run` has one. That inconsistency looked like the start
of a sweep, so it was measured over the latest definition of every
function: **7 account-by-code lookups carry a not-is_group guard and
105 do not.**

105 against 7 reads like a finding. It is not, and both halves of the
reasoning behind it were wrong.

**First: `is_group` is not the signal the 1120 bug needed.** In the
seeded chart `1120` is `is_group = FALSE` — "Bank Accounts", postable,
with the real accounts hung beneath it in 1121-1199. It is a heading by
CONVENTION, not by the column. So a `not is_group` guard would not have
caught `0727`/`0728` at all, and calling the landed-cost survivor "the
1120 bug on the stock side" (as the section above first did) overstates
it. The analogy that holds is posting onto a parent instead of a leaf;
the mechanism is different, and the 1120 fix had to be its own thing
(task #74, refusing a bank account on the 1120 heading).

**Second: the codes that genuinely ARE groups are looked up as
PARENTS.** Of the unguarded lookups, only `2100` (Current Liabilities)
and `5000` (Cost of Sales) are `is_group = true` in the seed, three
times each — and every one of those six is

```sql
insert into public.accounts (org_id, code, ..., parent_id, ...)
values (..., (select id from public.accounts
               where org_id = p_org_id and code = '5000'), ...)
```

in `0539` and `0022`, hanging a new account beneath its heading. Being a
group is exactly what is wanted there. The rest of the 105 name postable
leaves: 1310, 2110, 1210, 1510, 1590, 2118, 4100, 5100, 5200, 6400.

So the guard in `post_landed_cost_run` is defence against a CUSTOMISED
chart — a company that has made 1310 a heading with real inventory
accounts beneath it — and the 105 lookups without it are not 105 call
sites to fix. **Written down so the next session does not run the same
audit and "fix" them.** If the guard is ever worth spreading, the
argument has to be about customised charts, and the measurement to make
first is whether any live org has `is_group` set on a code the posting
functions look up.

### post_goods_received_internal: 12 of 18 survived, and all twelve were one fixture

The worst score of the session. **18 mutants, six killed, TWELVE
survived.** `posting_a_bill.sql`, the only other file reaching it,
killed just the two journal-balance mutations `goods_received.sql`
already killed, so the union is twelve. 18 of 18 after the work.

**Almost all twelve were one fixture problem wearing twelve hats.**
Every goods received note in the file was in MYR at rate 1, for an item
whose selling unit is its stocking unit, with no inventory account of
its own, in a company with one warehouse. So

```
subtotal * rate      ==  subtotal
base_quantity        ==  quantity
round(x, 6)          ==  round(x, 2)        (the costs all divided clean)
the item's account   ==  the chart's 1310
the default warehouse ==  the only warehouse
```

and **five separate rules in the function were asserting the same
arithmetic.** This is the twelfth entry in `docs/widget-tests.md` at its
widest: not one value collapsed into another, but a whole fixture
flattened until half the function was unobservable. The earlier
instances of that lesson were single collapses — a bank account on 1120,
a default that was also the oldest row. This was five at once, and they
were invisible individually because each looked like a reasonable
simplification.

The fix is one note:

| | |
| --- | --- |
| 5 cartons of 24 at USD 100 | subtotal USD 500, base quantity 120 |
| rate 4.2345 | inventory debit MYR 2,117.25 |
| unit cost | `500 * 4.2345 / 120` = **17.643750** |
| drop the rate | 4.166667 |
| divide by the 5 cartons | 423.450000 |
| round to two places | 17.64 |

plus two warehouses where the default is not the first row inserted, an
item carrying its own `inventory_account_id` distinct from 1310, and a
second stocked line at quantity zero that must make no movement at all.
The test asserts all four unit costs differ, so the right figure cannot
be reached by a wrong route.

The unit cost is the figure worth the trouble: it is what the weighted
average is built on afterwards, so a wrong one here is invisible until
something is sold, and then wrong in the cost of sales rather than at
the point it was made.

#### Two guards that look alike, and one that had to be proved live

`v_total = 0` refuses a note of pure SERVICE lines. `v_n = 0` refuses
one where the stocked lines have no QUANTITY. They are different
refusals with different sentences, and the file asserted only the first.

Reaching the second needs a tracked line whose subtotal is non-zero
while its quantity is zero — which takes a **negative discount**,
because the line trigger computes `quantity * unit_price - discount`:

```
quantity 0, unit_price 0, discount_amount -100
  -> line_subtotal 100, base_quantity 0
```

Whether the schema permits a negative discount decided whether this was
a gap or an equivalent mutant, so it was checked rather than assumed: it
does, the branch is reachable, and the guard is live code. Had it been
unreachable, the right answer would have been to record the guard as
dead and leave the mutant alone.

One trap inside that fixture: the company used for it has its 2118
renamed, for the no-2118 assertion just above. The 2118 lookup happens
BEFORE the quantity guard, so the note has to have 2118 put back before
the quantity refusal can be the one under test. A fixture that tripped
the earlier guard would have passed this assertion while proving nothing
about the later one.

### post_stock_adjustment: 18 of 22, and a journal line that records no money

Second-best first-run score of the sweep. **22 mutants, eighteen killed,
four survived**; `lot_allocation_shapes.sql` killed nothing
`stock_adjustments.sql` had not already killed. 21 of 22 now, the last
proven equivalent rather than closed.

**The gap worth reading twice** is the third of three. `if v_cost = 0
then continue` skips a stocktake line whose stock is worth nothing — a
difference in quantity at a cost of zero. Nothing in
`app.create_gl_entry_internal` drops a line of two zeroes, so without
that `continue` the journal gains a row of `debit 0, credit 0`: an entry
in the ledger recording no money.

**It balances.** Every balance assertion stays green, and every figure
asserted anywhere else stays right. Only COUNTING the journal's lines
catches it — the clearest case in this sweep of a defect invisible to
every assertion about values and visible to one about shape. The two
others were plain: no 5900 with no account named on the count, and no
1310 with no account on the item. Both now assert the refusal AND the
documented way round it, so the refusal is about the missing account
rather than about the count.

The equivalent, proven rather than argued: reversing
`order by created_at desc` on

```sql
select total_cost into v_cost from public.stock_movements
 where source_line_id = r.id and source_table = 'stock_adjustments'
 order by created_at desc limit 1;
```

changes nothing, because `source_line_id` is per LINE, the function
inserts exactly one movement per line, it is the only function in the
repository that writes a `stock_adjustments`-sourced movement — checked
against every latest definition, not assumed — and a second post is
refused. One matching row, so the ordering orders nothing.

#### My own guard produced a false refusal, and sent the operator to a file with no function in it

`mutate_sql.py` refused to run against `0087` with

```
HARNESS ERROR: post_stock_adjustment is last defined in
0571_what_posting_and_creating_commit_you_to.sql, not 0087_stock_adjustments.sql.
  use: .../0571_what_posting_and_creating_commit_you_to.sql
```

`0571` holds **no definition of it at all** — only
`comment on function public.post_stock_adjustment(uuid) is ...`.
`latest_defining()` matched a bare `\bfunction\s+<name>\s*\(`, so a
`comment on function`, a `revoke all on function` and a
`grant execute on function` all counted as definitions.

This is worse than the failure the guard exists to prevent. That one
leaves the database wrong and says nothing; this one **refuses a correct
run and prints an instruction that is wrong while looking
authoritative** — follow it and you mutate a file with no body, for
reasons that will not make sense. Fixed to require
`create [or replace] function`, and verified still to refuse the real
case it was built for (`0446` for `calc_pcb`, where `0530` is the
latest).

Worth noting which tool was right: `scripts/mutation_targets.py` named
`0087` correctly all along, because its pattern always required
`create or replace function`. The newer, narrower tool was correct and
the older, more defensive one was wrong — defensiveness in the matcher
is not the same as correctness in it.

Also fixed while there: a mistyped migration filename came back as a raw
`FileNotFoundError` traceback, which reads like the harness is broken
rather than the argument. It now says `no such migration: <path>`.

#### A fixture helper that could only be called once

`pg_temp.stocked_item` hardcoded `movement_no = 'OPEN-1'`, and
`stock_movements` is unique on `(org_id, movement_no)` — so the helper
worked exactly once per company and the second call died on the
constraint. Every existing caller used it once, so nothing had noticed.
Now suffixed like the item code beside it.

### send_stock_transfer: 19 of 23, and an off-by-one on a boundary nobody stood on

**23 mutants, nineteen killed on the first run, four survived.** Across
all three files that reach it, 23 of 23 die; nothing is equivalent.

| file | kills |
| --- | --- |
| `stock_transfers.sql` | 19, then 22 |
| `lot_allocation_shapes.sql` | 7 |
| `lots_across_the_new_sources.sql` | 7 |

Four survivors in one file against **three** in the union, and here the
difference is instructive rather than arithmetic. Both lot files
transfer BATCH-TRACKED items, so they reach the `app.lot_available`
check that `stock_transfers.sql`'s untracked items skip entirely — and
the mutant pointing that check at the DESTINATION warehouse is killed
only there. The fixture was deliberately not given a tracked item for
it: two files already own that case, and a third copy is upkeep without
cover. **The right answer to a survivor is sometimes "another file
already kills this", and that is worth writing down rather than
duplicating.**

The three real gaps:

1. **`< v_qty` mutated to `<=` on the stock check.** Sending a store's
   ENTIRE holding is the ordinary last transfer of a line, and no
   fixture emptied a store completely — every one left a remainder, so
   "not enough" and "exactly enough" were never distinguished. The
   cheapest gap to leave open and the easiest to miss: an off-by-one on
   a boundary **nobody's fixture stood on.** Closed with thirty out of
   thirty going, and thirty-one refused.
2. **The 1310 guard**, which no company in the suite was without.
3. **The movement-to-journal link**, which nothing asserted at all —
   without it a stock movement and the journal that priced it cannot be
   reconciled to each other.

That first one generalises past this function. Every guard of the form
`x < y` has three cases and most fixtures exercise one: comfortably
under, and that is all. The boundary is where off-by-one lives, and a
suite can assert a refusal thoroughly without ever asserting the
permission next to it.

### import_opening_stock: 25 of 25, and a prediction that was half right

The best result of the sweep. **25 mutants, twenty-four killed by
`opening_stock.sql` and the twenty-fifth by `opening_import_shapes.sql`
— 25 of 25, no gaps, nothing equivalent.**

| file | kills |
| --- | --- |
| `opening_stock.sql` | 24 of 25 |
| `opening_import_shapes.sql` | the 25th, and 17 others |
| `migration_progress.sql` | 1 — it drives the preview, not the rules |

A different shape from the posting functions: **thirteen validation
rules in one `elsif` chain**, a preview mode and a commit mode, and a
comparison against what the ledger already says stock is worth. An
`elsif` chain is the easiest thing in SQL to test incompletely, because
every rule shadows the ones before it — a row that trips rule 2 never
reaches rule 7, so a fixture can cover thirteen rules with thirteen rows
and still not prove which rule fired for any of them. Each rule got its
own mutant for that reason, and all thirteen died.

#### The prediction, and what it got wrong

Going in, the three gap families this sweep keeps finding were written
down and looked for deliberately: unasserted permission guards,
boundaries no fixture stands on, and fixtures collapsing several rules
into one value. All three were given mutants.

The **boundary** one duly survived `opening_stock.sql`. `v_cost < 0`
mutated to `<= 0` refuses stock brought in at no cost — and free stock
is real, which is why the rule is `< 0` and not `<= 0`, one line below a
quantity rule that IS `<= 0`. Two adjacent comparisons that differ on
purpose, the exact shape that had just cost `send_stock_transfer` a gap.

**It is not a gap.** `opening_import_shapes.sql` asserts it directly —
*"stock brought in at no cost at all is allowed — samples are stock"* —
written by somebody who had thought about free samples, in the file
about shapes rather than the file about opening stock.

So: right about the shape, wrong about the gap. The only reason no
duplicate assertion was added is the rule this sweep keeps proving —
**run every file that reaches the function before believing a
survivor.** Four functions in this sweep have now had a survivor in one
file that another file kills, and this is the first time the prediction
of a gap family was itself the thing that needed checking.

#### A malformed mutant is safe, and that is worth knowing

One mutant dropped a closing parenthesis along with the predicate it was
deleting, and came back as

```
HARNESS ERROR: an item that has already moved ... -- ERROR:  mismatched parentheses
```

That is not a kill and not a survival — the apply failed, so the
function was never replaced. Checked rather than assumed: the live body
still matched the migration and carried no mutation marker. The harness
is safe against a mutant that will not parse, because PostgreSQL refuses
the whole `create or replace` atomically. A mutant that parses and is
wrong is the dangerous kind, which is what the CONTROL entry is for.

### The ranking tool was understating its own target set by 42%

`scripts/mutation_targets.py` decides what "moves money or stock" by
looking for one of a handful of signatures in a function's body. One of
them was `app.post_journal`.

**There is no `app.post_journal` anywhere in the repository. The name
was invented.** The real helper is `app.create_gl_entry_internal`, which
**twenty-nine** functions call — so the single most important signature
in the list matched nothing, and the tool ranked 26 money movers where
it should have ranked 45.

That is precisely the failure every gate in `scripts/` keeps a canary
against: a matcher that has stopped matching reports a short list, and a
short list reads like a small problem. It went unnoticed through five
functions' worth of use, because the 26 it DID rank were all real — the
tool was never wrong about what it named, only about what it left out,
which is the invisible direction.

Fixed, and given the guard the gates have: `dead_signatures()` reports
any MOVES entry matching no function, and `main()` prints a warning
above the ranking rather than quietly narrowing. Verified by adding a
nonsense signature and seeing it named.

The nineteen that were invisible include some of the most-redefined
functions in the schema: `public.create_deposit` (five definitions),
`public.create_contra`, `record_pdc`, `bounce_pdc`,
`post_bank_transaction`, `settle_shared_payment`, `close_fiscal_year`
and `reopen_fiscal_year`. The sweep is less than half done, not nearly
finished — which is the useful correction, since the previous entry read
as though the money movers were almost covered.

### create_contra: nothing in the suite had ever contra'd two records of one party

First target from the nineteen functions that were invisible until the
ranking tool's dead signature was fixed. **25 mutants, fourteen killed,
ten survived**; `allocation_party.sql` killed nothing new. 23 of 25
after the work, the two left proven equivalent.

**The largest gap is a fixture collapse of a kind worth naming.** Every
contra in the suite used ONE contact for both sides. `app.same_party`
allows two — the whole point of
`0272_the_customer_who_is_also_the_supplier` is that a party may be kept
as two records carrying one TIN — and with one contact:

```
the customer IS the supplier
so the receivable line's contact IS the payable line's contact
and the note's customer_contact_id IS its supplier_contact_id
```

Three separate claims with the same value, none of them testable. And
**nothing in the suite contra'd two records of one party at all** — the
case the function's hardest condition exists for. A contra between
`BJ-C` and `BJ-S`, same TIN, each with its own control account, closes
four mutants at once.

**The two module rights had to be defeated by different means**, which
is a nice illustration of why a shared `if` needs two fixtures.
`create_contra` requires write on sales AND on purchases. `sales` is a
CORE module a company always holds; `purchases` is not. So one guard is
defeated by a company that does not hold purchases, and the other only
by a clerk whose access type sets sales to `read` — a stranger is
refused whichever guard survives, and proves neither.

The rest: the credit-note-as-invoice half of a shared `if`, the
contact's own control accounts, and the no-control-accounts refusal.

#### An assertion that cannot kill its mutant, and is right anyway

Dropping `deleted_at is null` from the SEED lookup is **equivalent**:
the loop below looks every invoice up again with the filter, including
the first, and raises the same `No such invoice.` with the same P0002.
An assertion that a deleted invoice is refused was added regardless —
the behaviour is worth pinning — and it does not kill the mutant. That
is the clearest demonstration in this sweep of what an equivalent
mutant is: **a correct, valuable assertion whose subject the mutation
does not change.**

The second equivalent is the journal built from `v_bill_tot` instead of
`v_inv_tot`, where the equal-sides check has already raised. Proven the
same way as record_group_payment's currency case: the mutant that
DISABLES that check is killed, so the check demonstrably fires.

#### Two defects in my own harness, one of which left the database wrong

`mutate_sql.py` refused to run at all, reporting that a later migration
redefines `create_contra`. No migration does. **`public.create_contra`
is OVERLOADED** — the 5-argument one in `0421` and a 6-argument
idempotent wrapper in `0734` — and `live(name)` selected
`prosrc from pg_proc where proname = '<name>'`, concatenating every
overload into one string that could never match one migration's body.
**Forty-six functions in this schema are overloaded**, so this was
waiting for any of them. `live()` now returns one entry per overload and
the check passes if any matches; applying a mutant was never affected,
because the `create or replace` carries its own argument list.

Fixing that exposed a worse one. The "did the mutant land" check used
`marker not in live(name)`, which after the type change tested list
MEMBERSHIP, so it failed for every marker. Its error path called
`sys.exit` **after the mutant had already been applied** — so
`create_contra` was left carrying `-- purchases guard dropped` in the
live database, under a message beginning *"applied cleanly"*.

The next run's body comparison caught it, which is the defence working
as designed — but the message it printed blamed a later migration and
sent the reader hunting one that does not exist. **An error path that
leaves the subject broken is the one failure this harness exists to
prevent, so it may not have one.** Every exit inside the mutate loop now
goes through a `bail()` that restores the function first and says it
did.

Worth noting what caught what: the overload bug was caught by the body
guard, the landed-check bug by the body guard on the NEXT run, and the
mutated database by reading `pg_proc` for the marker rather than
trusting either message. Three layers, and the top two both reported the
wrong cause.

### record_pdc and bounce_pdc: a general test killing a specific defect

**27 mutants across the two functions, 23 killed by
`post_dated_cheques.sql`, four survived; 27 of 27 across all three
files.** Nothing equivalent.

| file | kills |
| --- | --- |
| `post_dated_cheques.sql` | 23, then 25 |
| `cash_forecast.sql` | 3 |
| `idempotency.sql` | the last 2 |

**The two that only `idempotency.sql` kills are the interesting result,
because it kills them without asserting anything about either.** They
are the status rule (a cleared or bounced cheque can be bounced again)
and `status = 'bounced'` not being written — which leaves the cheque
HELD while its journal and its deleted allocations say otherwise.

Both die on `pg_temp.refuses_a_repeat('bounce_pdc', ...)`, a helper that
calls the function twice and demands the second be refused. A cheque
left `held` can be bounced twice, so a generic idempotency check catches
a specific defect in a status write that nothing in the dedicated file
looks at.

**A test asserting a GENERAL property can kill a mutation in a
particular field, and that is the best argument in this sweep for having
both kinds.** Every other survivor rescued by a second file was rescued
by a file asserting the same subject from another angle; this one was
rescued by a file asserting something else entirely.

The two real gaps:

- **The boundary's other side.** `p_cheque_date <= v_on` is the entire
  definition of "post-dated" — a cheque bankable today is a receipt. The
  file stood on TODAY (refused) and on dates weeks out (accepted), so
  widening the rule to refuse TOMORROW changed no assertion. Tomorrow is
  the first valid date, and that is now asserted. **This is the third
  function in a row whose boundary gap was the permission next to the
  refusal rather than the refusal itself** — `send_stock_transfer`,
  `import_opening_stock` (already covered elsewhere) and now this.
- **`bounce_pdc`'s own `can_write_module`**, which nothing asserted. A
  bounce writes a journal and deletes the allocations, so it is as much
  a posting as taking the cheque in was.

### post_bank_transaction: the sharpest per-file understatement yet

Top of `scripts/mutation_targets.py`'s forty-five — the money mover
with the FEWEST test files reaching it (two) of all of them, and at the
same time the one a bookkeeper touches most. Every line a bank import
cannot match to a receipt or a bill ends up here, which in a small
company's first month is most of them.

**27 mutants plus a control. 15 killed on `bank_reconciliation.sql`,
5 on `matter_on_a_bank_line.sql`, 24 across the union; 27 of 27 after
the work, nothing equivalent.**

| file | kills |
| --- | --- |
| `bank_reconciliation.sql` | 15, then 24 |
| `matter_on_a_bank_line.sql` | the three matter mutants, 2 shared |

15 and 5 against a union of 24 is the widest gap this sweep has
measured. The matter file reaches the same function and kills three
mutants the bank file cannot see, while missing nineteen it does.
**Run every file that reaches the function, every time.**

Nine gaps, one per family, two worth reading twice.

**The boundary was not in the code. It was in the fixture.**
`round(t.amount, 2)` is a no-op on a `numeric(18,2)` column, so the
mutant worth writing is not a wider rounding but `round(..., 0)` — and
it survived because **every amount in both files is a round hundred**.
There were no cents anywhere to lose. A line of 123.45 kills it. This
is a new shape for the list: the previous boundary gaps were all a `<`
that no fixture stood on, where the rule itself was the thing with two
sides. Here the rule has no sides at all until a fixture gives the
input some.

**Three of the nine are fields that cannot unbalance a journal.** The
contact on the chosen leg, the statement's own reference, and
`reconciled_at`. A journal missing all three balances perfectly, posts
cleanly, reconciles, and reads as correct to every balance assertion in
384 files. The only way to see them is to name them.

**And the two-guards-one-code shape, for the fifth time.**
`reconciliation_id is not null` and `matched_table is not null` sit one
after the other, both raise `23514`, and both always hold together —
`unmatch_bank_transaction` refuses a line in a closed reconciliation,
so there is no route to a line stamped with one and not matched.
Cutting the first lets the second answer in its place, with a different
sentence and the same code. The file caught `23514` generically and
could not tell them apart; only the WHOLE message does.

The rest: `app.can_post` (neither file ever signed in as somebody who
may not post — a statement line posted straight to the ledger IS a
posting); `deleted_at is null` on the account lookup, which is how this
schema retires a code that has history; and two of the three steps of
the description fallback, because every fixture in both files gave its
line a description, so `'Bank statement line'` was unreachable and
"blank is a description" was indistinguishable from the correct
behaviour. A line with no description at all — which MT940 imports
produce routinely — and a `p_description` of nothing but spaces
separate all three steps.

**16 of 45 money movers now have a mutants file.** Next in the ranking
with none: `settle_shared_payment`, `close_fiscal_year`,
`reopen_fiscal_year`, `create_deposit` (five definitions), `clear_pdc`.

### settle_shared_payment: almost every survivor needed a second of something

The acquirer's callback — the one that turns a customer's card payment
on a shared invoice link into a receipt in the tenant's own ledger.
`shared_invoice_payment.sql` is the only file that drives it;
`function_grants.sql` names it to assert its grant and can kill
nothing.

**30 mutants plus a control. 13 killed, 17 survived; 28 of 30 after the
work, the last two proven equivalent.**

**Almost every survivor needed a SECOND of something.** The file had
one company, one bank account, one acquirer, one mode, one currency and
one rate, and seventeen mutants lived in the gap between the one and
the two:

| what was missing | what it hid |
| --- | --- |
| a second acquirer | which account the takings land in, under which mode code |
| a second bank account | the same, observably |
| a second company | whether the config lookup is org-scoped |
| a second currency | the receipt's currency and its rate |
| a callback with no amount | `coalesce(p_paid_amount, 0)` |
| a callback with no `paid` | `coalesce(p_paid, false)` |
| a padded reference | `btrim` |
| a mixed-case gateway code | `lower` |

**The mode code is the twelfth trap in `docs/widget-tests.md`,
verbatim, in a different module.**
`coalesce(v_cfg.payment_mode_code, '03')` falls back to `'03'`, and the
fixture configured its settlement with `'03'`. "Under the mode the shop
chose" was an assertion that could not fail — the value read from the
config and the value the code invents when it finds none were one
string. The second acquirer is given `'06'`.

**And one survivor was not a missing assertion at all — it was another
function's fallback repairing the defect before anything looked.**
Dropping `v_cfg.settlement_bank_account_id` from the receipt insert
survived because `app.post_receipt_internal` resolves a bankless
receipt to the settlement account of the first gateway by `created_at`,
else the default active account, else the oldest — **and writes the
answer back onto the row.** With one bank account and one gateway the
repair and the correct value are the same row, so the assertion
`r.bank_account_id = v_bank` was reading a figure a different function
had fixed. Two gateways settling into two accounts, and a payment
through the second, makes the repair visible as a repair.

**That is a shape to look for everywhere a posting function resolves
what its caller left null** — which, after `0728`, is most of them. The
fallback is correct and was added on purpose; what it also does is make
its callers' own choices untestable unless the fixture gives the
fallback a different answer to give.

The two equivalents, both proven by shape rather than reasoned:

- **`base_amount` on the receipt insert.** The insert writes
  `v_take, v_take`; `app.post_receipt_internal` overwrites the column
  with `round(amount * rate, 2)` two statements later, inside the same
  branch, unconditionally. The inserted value is unobservable. The file
  asserts the surviving figure instead — 420.00 on a USD 100 invoice at
  4.2.
- **`least(v_pay.amount, balance)` with `p_paid_amount` in place of
  `v_pay.amount`.** The short-payment guard has already returned unless
  `paid >= v_pay.amount`; `v_pay.amount` was the balance when the
  payment began; and a posted invoice's balance never RISES — there is
  no unallocate, no amend-upward, and `void_sales_document` refuses a
  document with `paid_amount > 0`. So `paid >= v_pay.amount >= balance`
  and both forms return the balance. The finding is about the code: the
  balance cap does all the work and `v_pay.amount` inside the `least` is
  belt-and-braces against a state this schema cannot reach.

**17 of 45 money movers now have a mutants file.** Next with none:
`close_fiscal_year`, `reopen_fiscal_year`, `create_deposit` (five
definitions), `clear_pdc`, `run_recurring_journals_for`.

### The year-end close: every block closed exactly one year

`close_fiscal_year` and `reopen_fiscal_year`, the two halves of the
largest journal this application posts — one line per profit and loss
account with movement, plus the result.

**32 mutants plus a control. 15 killed on `year_end_close.sql`,
`idempotency.sql` kills one more, 30 of 31 across the union with one
proven equivalent.**

**One cause accounted for most of the sixteen survivors: every block in
the file closed exactly ONE year.** Both ordering rules are three
conjuncts — the company, the status, the date comparison — and only the
date comparison can be stood on by a fixture that never closes a
second:

```
close:  no EARLIER year of THIS company may still be OPEN
reopen: no LATER   year of THIS company may still be CLOSED
```

Dropping `status = 'open'` from the close's rule means **a company can
never close its second year** — the first one being properly shut still
blocks it. That is a total loss of the feature, and no assertion in 384
files noticed, because nothing had ever closed two consecutive years in
order. The reopen's rule was unasserted in all three of its parts.

**The two org scopes needed a stranger with a year on a DIFFERENT
day.** Every company in the file has a year starting 2025-01-01, and
`y.start_date < f.start_date` is strict — so another company's open
2025 is not earlier than ours, and dropping the org scope found
nothing. A stranger's open 2024 and closed 2027 are what make both
scopes observable.

**And a break-even year, which nothing had ever closed.**
`if v_profit <> 0` is the whole of "no result line when there is no
result". Widening it posts a line of two zeroes to equity; the journal
still balances and every figure asserted elsewhere is unchanged. Only
the line count sees it — the same lesson `stock_adjustments.sql` gave
for a zero-cost stocktake line, and the fourth time in this sweep that
counting a journal's lines caught what checking its balance could not.

The rest were stamps and shapes that balance: the closing journal's
date and description, `closed_at`, `closed_by`, the three fields a
reopen has to CLEAR, and the reversal's date. Five of them are
invisible to any figure at all.

**The equivalent is a coupling worth knowing about.**
`close_fiscal_year`'s `where p.amount <> 0` can never exclude anything:
`report_profit_loss` already ends in
`having sum(l.debit - l.credit) <> 0`, and its `amount` column is that
same sum with the sign flipped for revenue — a flip that cannot change
whether a value is zero. The filter is belt-and-braces resting on a
property of a *different* function. Remove the `having` and the filter
starts mattering the same day, which is what the new line-count
assertion would notice.

**A near-miss worth recording.** The line-count assertion first read
`report_profit_loss` *after* the close, where it returns nothing, and
asserted `0 + 1` against a journal of three lines. It failed loudly
rather than passing over nothing — but had the arithmetic been
`v_moved` alone instead of `v_moved + 1`, it would have passed. A
report read after the thing that empties it is a fixture that measures
its own aftermath.

**19 of 45 money movers now have a mutants file.** Next with none:
`create_deposit` (five definitions), `clear_pdc`,
`run_recurring_journals_for`, `import_open_bills`,
`dispose_fixed_asset`.

### create_deposit: the three arguments nobody reads back

Five definitions, the most-redefined money mover in the schema, and two
live overloads since the write-idempotency programme added the keyed
wrapper.

**26 mutants plus a control. 13 killed on `deposits.sql`,
`money_names_the_account.sql` kills one more, 24 of 25 across the union
with one proven equivalent.**

**Seven of the twelve survivors were one fixture problem.** Every
deposit in a 1,233-line file is a round hundred or thousand taken
TODAY, with no payment mode and no reference. So:

- `round(p_amount, 2)` had no cents to lose;
- `coalesce(p_date, app.today())` had nothing to tell from today;
- `p_mode`, `p_reference` and `p_notes` were never read back;
- and the journal's `contact_id` on each leg was never looked at.

One deposit — 1234.56, nine days ago, mode `'02'`, reference
`'CHQ 900241'` — closes seven mutants at once. **The three arguments a
deposit carries purely so a person can find the money later are exactly
the three nothing asserted**, and not one of them can unbalance a
journal.

**The module derivation needed two fixtures** — the lesson `contra.sql`
paid for first. `app.can_write_module(p_org, v_module)` with
`v_module` derived from the kind is two claims in one call: that the
guard exists, and that each direction asks for the right module. A
stranger proves only the first, being refused whichever module is
named. The second needs a company holding one side and not the other,
and only `purchases` can be switched off because `sales` is a core
module every company has. Purchases off must refuse a SUPPLIER deposit
and still allow a CUSTOMER one.

**And one needed a company whose base currency is not the suite's.**
`v_cur := app.base_currency(p_org)` reads the company; every company in
384 files is MYR, so hardcoding `'MYR'` in its place changed nothing.
An SGD company is what makes "the base one" assertable — and
`group_reporting.sql` had already established that an in-place
`update organizations set base_currency` is the way to build one.

**The equivalent**, proven by shape: the ledger lookup's own
`and b.org_id = p_org`. By the time that `select` runs, `p_bank` has
already been refused if null and refused if it belongs to another
company, so the conjunct cannot exclude a row the id would not have
missed anyway. Belt-and-braces, and right to keep — the function's own
comment records that the row written and the balance updated once used
`p_bank` raw, which is the defect it guards against returning.

**20 of 45 money movers now have a mutants file.** Next with none:
`clear_pdc`, `run_recurring_journals_for`, `import_open_bills`,
`dispose_fixed_asset`, `revalue_foreign_balances`,
`receive_stock_transfer`.

### clear_pdc: nine of twenty-six, and a balance is one number

The third of the cheque trio, after `record_pdc` and `bounce_pdc`
(which scored 27 of 27). This is the one where the money actually
moves, and it scored **nine of twenty-six on its own dedicated file —
the worst first-run score of the sweep.** 24 of 25 across its four
files, one proven equivalent.

**The cause is one sentence: every clearing in
`post_dated_cheques.sql` asserts the BANK BALANCE and little else.** A
balance is one number, and it is the same number whether

- the cheque's own holding account was emptied or the other
  direction's — **1140 Cheques on Hand is an asset and 2115 Cheques
  Issued is a liability**, and fixing the direction to `'incoming'`
  empties an asset that was never filled while the liability the
  company really owes sits there for ever;
- the journal says which cheque it was for;
- the cheque remembers what settled it, or through which account;
- anybody is named on either leg;
- it cleared on the day it cleared or the day it was typed.

All of it balances. **The outgoing clearing's journal was not asserted
at all** — only that the balance fell by 8,000.

**And the status write is the second of its kind in this trio.**
`set status = 'cleared'` survives the whole dedicated file and dies in
`idempotency.sql`, which asserts nothing about clearing: a cheque left
`held` can be cleared twice, so a generic refuses-a-repeat check
catches a specific defect in a status write. `bounce_pdc` had exactly
the same shape. **Twice in three functions is not a coincidence — a
status column is what a file about MONEY never looks at.** Worth
checking first on every remaining money mover: is the state change
asserted anywhere but the idempotency file?

The equivalent is the ledger lookup's `and b.org_id = v_c.org_id`, the
same shape as `create_deposit`'s and proven the same way — by the time
it runs, `v_bid` has been refused if null and refused if it belongs to
another company.

**21 of 45 money movers now have a mutants file.** Next with none:
`run_recurring_journals_for`, `import_open_bills`,
`dispose_fixed_asset`, `revalue_foreign_balances`,
`receive_stock_transfer`, `import_opening_balances`.

### The standing journals: all thirteen survivors were inside the loop

`run_recurring_journals_for` — the monthly standing journals (rent,
depreciation, a management fee) posted on their due date and
rescheduled.

**25 mutants plus a control. 11 killed on `recurring_shapes.sql`,
24 of 24 across its three files, nothing equivalent.**

**All thirteen survivors were inside the loop.** The run's return value
and the posted entry's date and description were asserted; the three
columns the loop writes on its way out — `last_run_date`,
`next_run_date`, `last_error` — were not, except as `is null` on the
two schedules that did *not* run. **This is the same finding
`clear_pdc` gave an hour earlier: a file that watches the money does
not watch the state.** Two for two, so it is now the first thing to
check on every remaining money mover.

**And the error path WAS asserted — for the other runner.**
`recurring_shapes.sql` has four assertions on `last_error` after a
failed run, and every one of them is about `recurring_documents`. Its
own section-8 comment says "recurring journals and recurring documents
are two runners with two `where` clauses, and the journal one had
almost nothing on it" — and the half it wrote that comment for was
still the half with no coverage of the error path, the interval, the
review flag or the template. **A comment naming the gap is not the
assertion that closes it.**

**One survivor was an empty journal — the fifth of that shape in this
sweep.** `r.template -> 'lines'` read under the wrong key is NULL,
`app.create_gl_entry_internal` posts an entry with **no lines at all**,
and it balances. A month-end accrual that accrued nothing passed every
assertion in section 8, including "the accrual is dated the month it
accrues" — because an entry with no lines still has a date.

**And `auto_post`, which nothing in the suite had ever set to false.**
A schedule the bookkeeper wants to review first must advance and post
NOTHING. With every fixture auto-posting, "it posted" and "it ran" were
one claim.

The error path now has its own fixture: a template naming an
`account_id` that is not an account. The run posts four of five, the
broken schedule keeps its `next_run_date`, records `last_error` and
`last_error_at`, is not marked as having run, and posts nothing — and a
schedule carrying a STALE error from a previous month has it cleared on
the run that works, which is the only thing stopping a schedule reading
as broken for ever after one bad month.

**22 of 45 money movers now have a mutants file.** Next with none:
`import_open_bills`, `dispose_fixed_asset`, `revalue_foreign_balances`,
`receive_stock_transfer`, `import_opening_balances`,
`import_open_invoices`.
