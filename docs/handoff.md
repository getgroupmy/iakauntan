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
| Head at time of writing | `40a8c538` — the dialogs pass, in progress |
| CI | green through run 2045 (`1cfca06c`); 2046–2047 running — **every migration to `0674` is live** |
| Migrations | `0674` is the highest (the tax tile on the home screen). **Nothing since `b635b4b0` touches the database** — the eight commits after it are Dart, tests and gates only |
| Live database | **level with the branch.** Nothing is waiting |
| Mobile | **iOS build 5 in TestFlight, Android version codes 5 and 6 on Play internal testing.** Both from this repository's own workflows |
| Gates | 348 SQL assertion files, **45 Python gates (+11 gate self-tests)**, **5,456 Flutter tests**, 32 deno tests |
| API description | 766 functions, 364 tables, version `0674` — unchanged, because no migration has been added |

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
