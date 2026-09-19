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
| Branch | `claude/new-session-9rvhar` (a fresh container's designated branch; continues from `claude/iakauntan-accounting-crm-8snun0` at `9ce1d22`, which is this file's previous version) |
| Head at time of writing | `e0328e0` |
| CI | not yet checked for this push — watch it |
| Migrations | `0658` is the highest; `0658` is this session's |
| Live database | **`0650`–`0657` are applied; `0658` is not, until this push's CI run goes green.** CI's "Apply the migrations" job pushes to the linked project, so a green run means the hosted schema already has it |

Counts to expect from a clean run: **41** gates, **333** SQL files,
**29** deno tests, **5,095** widget tests with 1 skipped, analyser clean
— **not independently re-verified this session** for the Flutter/deno
counts; see the new container note below.

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
in the commit message — read those rather than the diff. Only this
session's own commit is listed under this heading now; everything below
`9ce1d22` is the previous session's and is unchanged — `git log` has the
rest, and repeating it here would drift the moment either list is
touched without the other.

| SHA | What |
| --- | --- |
| `e0328e0` | Close the leaked default: `authenticated` and `service_role` on functions (`0658`) — open work item 2, below, resolved |

### The previous session's commits, for reference

| SHA | What |
| --- | --- |
| `895ae59` | Fix: revoke from `anon`/`authenticated` by name, not just `PUBLIC` |
| `32599dd` | APNs direct transport (`0657`), so an iPhone needs no Firebase |
| `7e59db5` | To-do in the menu, list-and-detail page, bigger notes, contact link (`0656`) |
| `d8b0190` | Multi-level sub-accounts (`0655`) + quick-add from Record expense |
| `3052799` | Contact delete with a referential guard (`0654`) |
| `dfabf56` | Sign-in legal links, demo page, 5-second splash, Mobile Application console page (`0653`) |
| `f455e99` | Org live-feed lifecycle observer — the other half of the realtime fix |
| `40f0054` | Realtime broadcast topic (`0652`), public path for `/terms-of-service` |
| `9aff58a` | Terms of Service page + the consent line (`0651`) |
| `b3298d7` | Fix: `.order()` came back descending; two unreachable methods |
| `f804595` | Received e-Invoice screen |
| `3fcef9c` | The second passkey, which no device would save |
| `cb0a06c` | Received e-Invoices schema (`0650`) |

## Blocked on the user — nothing can proceed without these

1. **The new Application ID.** They chose "change the Application ID
   itself" (current: `my.iakauntan.iakauntan`) and never named a
   replacement. Eight places must change together:
   `app/android/app/build.gradle.kts` (namespace **and** applicationId),
   `MainActivity.kt`'s package line **and its directory path**,
   `project.pbxproj` (3 Runner + 3 RunnerTests),
   `app/web/.well-known/apple-app-site-association`,
   `doc_scanner_io.dart`'s MethodChannel — **which must match
   MainActivity's or document scanning breaks silently** —
   `Runner.entitlements`, and `docs/passkeys.md`.
   Also still unanswered: is the app published on either store? That
   decides whether the ID can change at all.
2. **The upload key SHA-256** for `assetlinks.json`, and which
   certificate the one already supplied is. The JSON pasted used
   `delegate_permission/common.handle_all_urls` (App Links) rather than
   `get_login_creds` (passkeys), and carried a single fingerprint —
   the gate refuses that by name, because listing only one works on the
   developer's handset and nowhere else. Whether App Links is wanted at
   all is also open.
3. **Associated Domains** enabled on the App ID in the Apple developer
   portal.
4. **Publish Terms of Use, Terms of Service and Privacy** in the
   platform console. Until then the consent line names them without
   linking, and the new app footer links draw nothing — by design, but
   it looks like the feature is missing.
5. **A new app build**, for any of the mobile work to reach a phone.
6. For push on a phone: the five `APNS_*` secrets (iOS) and
   `FCM_SERVICE_ACCOUNT` + `google-services.json` (Android). See
   `docs/push-notifications.md`. `google-services.json` cannot live in
   this repository.

## Open work, ranked

1. **The Flutter half of push.** `0657` gave iOS a sender that needs no
   Firebase; nothing in the app registers a device token, so
   `PushStatus` answers `unsupported` on a phone. iOS needs no
   third-party package — `UNUserNotificationCenter` and
   `didRegisterForRemoteNotificationsWithDeviceToken` over a
   MethodChannel, plus `PKPushRegistry` for the VoIP token, which is a
   second token against the same row shape. Register with
   `transport: 'apns'`. Android needs Firebase and is blocked above.
   Next real thing to pick up.
2. **Task #11, the MIA headless scraper** — blocked, MIA unreachable
   from here. Do not start without the user.
3. Older backlog, not to be started unprompted: `close_fiscal_year`
   sweeping to 3200 vs 3300; stripping the posting redirect out of
   `0635`; P14 per-document rounding; G3(b) relaxation flag.

Resolved this session: **make the local stack match the hosted project
on function privileges** — see `0658` and the trap below, which the old
list pointed at as "still open."

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

**A brand-new container has neither `pg_cron` nor `flutter` at all** —
not "not on PATH," genuinely not installed, because the container this
was last written from is gone and this one was provisioned fresh.
`pg_ctl start` fails with `could not access file "pg_cron"` until
`apt-get install -y postgresql-16-cron` is run once. `flutter` is
missing outright at `/opt/flutter-3.47.4/bin` (or wherever the PATH
line above points) until a real SDK is installed there — nothing
short of that makes `check_xlsx.py`, `check_android_compile_sdk.py` or
`check_web_boots.py` pass, and none of the three is a reason to stall
on a change that never touches Dart: this session's did not, and left
them failing for that reason alone, confirmed against `run_locally.sh`
before the previous run without them.

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

**And the local run does not catch that**, because
`supabase/tests/_local_stack.sql` deliberately reproduces no default
privilege for functions. The note in that file carries the evidence —
CI run 1941 was a controlled experiment: the function was *dropped* and
recreated and still came back executable by `authenticated`, which only
a default privilege explains.

**Resolved this session, by `0658`, without touching the two test
files.** Adding the default privilege locally, on the strength of that
evidence, would have failed `function_grants.sql` and
`trigger_reachable_grants.sql` — both assert that a function created
now is callable by nobody, which is the behaviour this machine has
always had and the hosted project did not. Rather than loosen the
tests to tolerate what the hosted project was doing, `0658` fixes the
hosted project to match: it revokes the leftover default privilege
itself (so nothing created after it depends on remembering), revokes
`authenticated` from the twenty-two functions that had it without a
matching explicit revoke, and sweeps `service_role` back to exactly the
list this repository's own local stack already said should hold it —
read off `has_function_privilege` on this machine, which has never been
able to hold a grant that no `grant execute` statement wrote, and
cross-checked against every `.rpc()` call site with
`check_rpc_grants.py` before being written into the migration. Its own
self-checks are what prove it against the hosted project; this
machine's checks staying green throughout is what proves the two now
agree instead of one being quietly loosened to match the other.

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
