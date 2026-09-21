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
| Head at time of writing | `0e69d4d`, plus the two commits below it |
| CI | green through run 1968 (`7078fc6`); 1969 was still in the queue |
| Migrations | `0658` is the highest. **Nothing since has touched SQL** — the recent work is all Dart |
| Live database | **`0637`–`0658` are NOT applied.** See below — this was wrong in the previous version of this file |

### The hosted schema is behind this branch, and the old note said otherwise

The previous version of this file said CI's "Apply the migrations" job
pushes to the linked project on any green run. **It does not.** Its
condition is

    github.event_name != 'pull_request' &&
    github.ref_name == github.event.repository.default_branch

— the default branch only, added in `aefac8e` and already on `main`.
So nothing this branch has ever pushed reached the live database, and
`0637`–`0658` are still pending there.

Even on `main` it applies nothing unless the repository variable
`MIGRATIONS_AUTOPUSH` is `true`; otherwise the job reports what is
pending and changes nothing. So the consequence of merging depends on
a variable, and the run summary on `main` is what says which happened.

This matters because it is the difference between "the schema is
already there" and "twenty-two migrations reach production the moment
this merges". Check the merge run's summary rather than assuming
either.

Counts to expect from a clean run: **41** gates, **335** SQL files,
**31** deno tests, **5,147** widget tests with 1 skipped, analyser clean.

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
3. **Associated Domains** enabled on the App ID in the Apple developer
   portal — and now also **Push Notifications**, for the same App ID in
   the same place. Without it the provisioning profile carries no
   `aps-environment` and a signed build fails at signing. CI builds iOS
   with codesigning off, so neither shows up until a real release.
4. **Publish Terms of Use, Terms of Service and Privacy** in the
   platform console. Until then the consent line names them without
   linking, and the new app footer links draw nothing — by design, but
   it looks like the feature is missing.
5. **A new app build**, for any of the mobile work to reach a phone.
   There is now a button for it — Mobile Application → Release the iOS
   app — but it needs the secrets in open work item 2 first, and it is
   iOS only. Android still has no equivalent, because it has no
   Firebase project either.

   **The button was pressed on 2026-09-20 and the card said "Not set
   up yet".** That is correct behaviour and not a fault: the two
   function secrets below do not exist, so the function answers 503
   with a sentence. Two secrets make the card list builds and the
   button live, and they are the smallest step that moves this
   forward:

   | Supabase → Edge Functions → Secrets | |
   | --- | --- |
   | `GITHUB_RELEASE_TOKEN` | a fine-grained PAT on `getgroupmy/iakauntan` with **Actions: read and write** and nothing else |
   | `GITHUB_REPOSITORY` | `getgroupmy/iakauntan` |

   Starting a build then needs the six Apple secrets in GitHub
   Actions, and the workflow stops with a list of whichever are
   missing rather than failing. **`docs/ios-release.md` now carries a
   step-by-step walkthrough** — including a `.p8`-and-`openssl` route
   to the distribution certificate that needs no Mac, which is the
   step that otherwise blocks anybody without one.
6. For push on a phone: the five `APNS_*` secrets (iOS) and
   `FCM_SERVICE_ACCOUNT` + `google-services.json` (Android). See
   `docs/push-notifications.md`. `google-services.json` cannot live in
   this repository. `APNS_PRODUCTION` must agree with the build's
   `aps-environment`; crossed, every notification is `BadDeviceToken`,
   which reads as a dead handset and is not one.

## Open work, ranked

0. ~~The skeleton pass.~~ **Done, and it should not be "finished" any
   further.** 276 of 313 `AsyncView` call sites carry a `skeleton:`.
   The 37 left are deliberate, and forcing bones onto them would break
   the rule the whole pass followed — `core/skeletons.dart`'s own: a
   skeleton belongs where the LAYOUT is already decided and only the
   values are missing. They fall into four groups:

   * **a payload that chooses a whole surface** — the till, the diary,
     the kiosk board and the floor plan all pick a register and then
     draw an entirely different screen depending on the answer; a
     matter, a filing, a forecast and a manufacturing order each
     choose between "not found" and a full page; `reports_screen` and
     `group_reports_screen` build their layout from a spec COMPUTED
     from the rows.
   * **a `loading:` fallback already better than bones** —
     `matter_detail_screen`'s AppBar falls back to the word "Matter",
     which is not waiting for anything.
   * **a block usually absent entirely** — `tax_details_card`'s second
     site resolves to `const SizedBox.shrink()`.
   * **`core/widgets.dart` itself**, four of them, where `AsyncView` is
     defined.

   `landing_cms`'s preview is the one to re-read if this is ever
   revisited: `core/page_waiting.dart` argues that a skeleton over an
   operator-edited page is a guess at a shape the payload is about to
   decide, and it is still right.

   Eleven `LinearProgressIndicator`s were removed along the way, all of
   them a `loading:` that `skeleton:` had made unreachable.

1. **Try iOS push and calls on a real handset.** The code is all here
   — `AppDelegate.swift`, `push_native.dart`, `callkit.dart`, `0657`,
   `0658`, `send-push/routing.ts` — and none of it has ever run on a
   phone, because there has been no build (blocker 5) and no APNs
   secrets (blocker 6). Two things to check first, in this order:

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

2. **Set up the iOS release secrets, then press the button once.**
   `docs/ios-release.md` lists them: six Actions secrets (the
   distribution certificate, the provisioning profile, the App Store
   Connect API key) and two function secrets (a fine-grained GitHub
   token, the repository). Until they exist the workflow stops with a
   list of what is missing rather than failing.

   The build number comes from `github.run_number` and the marketing
   version from `pubspec.yaml`. The first real run is also the first
   time `xcrun altool --upload-app` has been exercised here — it is the
   documented CLI for this and nothing in CI can prove it.

3. ~~Make the local stack match the hosted project on function
   privileges.~~ **Done.** `_local_stack.sql` now reproduces Supabase's
   `grant all on functions to anon, authenticated, service_role`, and
   the two files that encoded the opposite are corrected. The cause was
   that CI has TWO databases — `supabase start` for the SQL assertions,
   the linked hosted project for the migrations — and nobody had said
   which was being measured.
4. **Task #11, the MIA headless scraper** — blocked, MIA unreachable
   from here. Do not start without the user.
5. Older backlog, not to be started unprompted: `close_fiscal_year`
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

### All forty-one Python gates — run every one, every time

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
