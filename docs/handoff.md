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
| Head at time of writing | `14d6d164` |
| CI | green and APPLIED through run 2011 (`ae74039a`); 2012 (`14d6d164`) in flight |
| Migrations | `0668` is the highest (the LHDN filing calendar) |
| Live database | **level with the branch through `0667`.** `0668` was pushed and is waiting on run 2012 |
| Mobile | **iOS build 5 in TestFlight, Android version codes 5 and 6 on Play internal testing.** Both from this repository's own workflows |
| Gates | 341 SQL assertion files, 48 Python gates, 5,269 Flutter tests, 32 deno tests |
| API description | 759 functions, 362 tables, version `0668` |

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

Counts to expect from a clean run: **48** gates, **341** SQL assertion
files, **32** deno tests, **5,269** widget tests with 1 skipped,
analyser clean.

Counting the SQL files: 343 sit in `supabase/tests/`, less `_helpers.sql`
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

## This session's commits

Newest first. Each is a self-contained piece of work with its reasoning
in the commit message — read those rather than the diff.

| SHA | What |
| --- | --- |
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

## The tax computations — `0664` through `0668`

Five migrations built a thing this product did not have: the arithmetic
between the accounts and a return, and the dates it is owed on. It is
worth understanding as one piece, because each layer only makes sense
on the one below.

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
- **`0667` does not model a new company's first basis period**, which
  has its own timing and its own exemption from instalments.
  `first_period` is on the estimate so the screen can say the rules
  differ rather than quietly applying the wrong ones. CP500's
  instalment rhythm for individuals — six bimonthly, on the 30th — is
  not modelled either; `tax_estimate_rules` is company-shaped.
- **`0668` cannot know whether a particular obligation applies.** A
  CP58 appears for every trading company because the threshold test is
  about payments to agents this schema does not track, and a dormant
  company still gets its Form C because a dormant company still files
  one. It is a calendar, not an assessment of who is exempt.
- **Nothing files.** No submission of anything, no instalment paid, and
  nothing marks an obligation as met.

### Where they are

Financial statements carries three actions: the calculator picks a
financial year and opens the right form by entity type
(`/tax-computation/:id`, `/form-b/:id`, `/form-p/:id`); the repeat
icon opens the CP204 estimate (`/tax-estimate/:id`, with the
computation as a query parameter where one exists); the notes icon
opens the calendar (`/tax-calendar`). Fixed assets → the receipt icon
opens the capital allowance schedule. The account editor carries the
tax treatment picker, and **until accounts are tagged every computation
is the profit unchanged** — which is not wrong, only empty, and the
screen cannot warn about it.

The calendar needs no posting permission, deliberately: it computes
dates and writes nothing, and the person who most needs to see a
deadline is often not the one who keys the return. The estimate opener
does NOT open a computation to measure against — it asks whether one
exists, because opening one writes a document somebody then has to
deal with, and the estimate screen is honest about not knowing.

## Open work, ranked

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

   * **Form BE**, the return for a person with no business income —
     due 30 April, two months before Form B, and `0668` names it in a
     description rather than seeding it because nothing here knows
     which individuals have a business source.
   * **CP500 for individuals.** `0667`'s `tax_estimate_rules` is
     company-shaped: twelve instalments on the 15th. An individual's
     is six bimonthly on the 30th, revisable by 30 June on a CP502.
     The table would need a form dimension rather than a second copy.
   * **A company's first basis period**, which has its own CP204
     timing and its own exemption from instalments. `first_period` is
     already on the estimate for the screen to say so.
   * **Marking an obligation as met.** `0668` computes and shows; it
     has no equivalent of `corp_filings`, so nothing records that a
     Form C was actually filed and nothing falls off the list.

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

### All forty-eight Python gates — run every one, every time

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
