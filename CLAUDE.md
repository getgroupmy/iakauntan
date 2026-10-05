# iAkauntan

A Flutter (web/Android/iOS) front end over a Supabase Postgres back end:
accounting, CRM, HR and payroll, corporate secretarial and LHDN e-Invoice for
Malaysian businesses. `README.md` is the real orientation — read it before
changing anything statutory.

**Claude Code tooling** — which plugins and skills this project uses,
which are deliberately not installed and why, and what needs a key or a
device — is in `docs/claude-tooling.md`. It is committed because
`.claude/settings.json` is not.

**Picking up work in progress?** `docs/handoff.md` carries the state of
the branch, what is applied to the live database, what is blocked on the
user, and the traps that have already been paid for once. It is written
to be read by a session that has none of the preceding conversation —
including one signed in as a different account.

Three things to know before you touch the code:

- **The database is the application.** Business rules live in SQL — numbered,
  append-only migrations in `supabase/migrations/`, applied in order and never
  edited once applied. Permissions are RLS policies plus `app.can_*` guards
  inside SECURITY DEFINER functions. A rule enforced only in Dart is not
  enforced.
- **Statutory arithmetic is asserted, not eyeballed.** `supabase/tests/*.sql`
  runs in CI. Anything touching EPF, SOCSO, EIS, PCB or an SSM deadline needs a
  test that would fail if the number moved.
- **A widget test that passes has not yet proved anything.** Break the screen
  on purpose and watch the test fail: `python3 scripts/mutate.py <source>
  <test> <mutants.py>`, always with a no-op control, because a harness that
  errors on every run reports a clean sweep. `docs/widget-tests.md` lists the
  ways a green test covers a broken screen — every one of them happened here,
  and several hid a real defect. **No count is given here on purpose:** that
  list has grown four times, and this line said "thirteen" while two scripts
  said "ten". Read the file; it numbers them. Three of its entries are the
  ones most worth knowing before writing any test here:

  - **A fixture that collapses the thing under test into one value.** If the
    right answer and the fallback answer are the same row, no assertion can
    say which one the code read. That is how a 1120 fallback survived in six
    posting functions with 382 assertion files running — and how, later, a
    settlement account, a payment mode code, a base currency, an interval of
    one and a year closed on its own each hid a mutant.
  - **The WINDOW.** A widget test's surface is 800x600 unless told otherwise,
    which is landscape — so a screen laid out for a portrait phone can be
    broken at every size a person holds and pass a file full of assertions
    that only ever counted widgets. Set `tester.view.physicalSize` and
    measure with `getRect`.
  - **Three things that look like coverage of a fix and are not:** a comment
    naming the gap, a static sweep of the function's source text, and a
    careful sweep of the guard NEXT TO it. All three were found in one
    afternoon, each leaving a shipped fix with no behavioural assertion at
    all, and a mutation sweep is immune to all three because it reads
    nothing.

## After every push: watch CI to green

A push is not finished when it lands. After pushing, set a recurring check of
the branch's latest CI run every 5 minutes and keep it running:

- still running — note it in one line and wait
- a job failed — pull that job's logs, diagnose the real cause, fix, commit,
  push, and keep checking until the run is green
- green — say so once, naming the commit SHA, then stay quiet about that SHA

Do not stop the watch the first time a run turns green; it should also catch
the next push. Do not poll with `sleep` — schedule it.

CI is where the SQL assertions in `supabase/tests/` are authoritative, so a red
run is the project's real failure signal, not a formality. `supabase/tests/run_locally.sh`
runs the same list against a throwaway Postgres on this machine — use it to
find a broken assertion before pushing, not to skip the push. It stubs
Supabase's `auth` and `storage` schemas, and its own header says where the
stubs stop being the real thing.

**Budget TWELVE MINUTES OR MORE, and do not give it a shorter timeout.**
This said "about two minutes" until 5 October, when it was timed: still
running at 681 seconds and finishing inside a 900-second limit, for
`383 files, 14330 assertions executed` over 742 migrations. Two minutes
was wrong by a factor of six, and the cost of the wrong number is not
patience — it is that a correct run looks like a hung one. Give it
`timeout 1800`, and do NOT pipe it through `tail`, which buffers the lot
and leaves you watching an empty file with no way to tell progress from a
hang. The honest check while it runs is
`ps -eo pid,etimes,args | grep postgres`: a live cluster on its port means
it is working.

**It needs no Docker, and a session has already concluded otherwise and gone
without it.** The cluster is built with `initdb` directly; what it wants is
`postgresql-16`, `pg_cron` and root, which the cloud container has. So "there
is no Docker here" is not a reason to push SQL unrun — check for
`/usr/lib/postgresql/16/bin` before believing it. Put `flutter` on `PATH`
(`/opt/flutter-3.47.4/bin`) or `check_xlsx.py` fails for want of it, in a
`subprocess` traceback that names nothing about Flutter.

The edge functions have the same arrangement.
`supabase/functions/_local_check/check_locally.sh` type-checks all of them here,
stubbing `jsr:@supabase/supabase-js` so the check does not need jsr.io — which
is unreachable from some machines this gets worked on, and was the reason a
type error in `pay-invoice-callback` was found by CI rather than before the
push. Green there is not green in CI: every call made *on* the Supabase client
is unchecked. Red there is red in CI.

Where there is no `deno`, it now **fetches one from npm** before giving up.
`dl.deno.land` is what Deno's own installer uses and is exactly what a
locked-down network refuses, but Deno is published to npm as well, and
`registry.npmjs.org` is reachable from the same places — so one
`npm install` produces a real `deno` where the installer cannot. Cached
under `$TMPDIR/iakauntan-deno`; `DENO_SKIP_NPM=1` goes straight to the
fallback.

It then runs **every `deno test` file CI runs**, reading their names and flags
out of `ci.yml` so the list cannot drift, and refusing to start if the count it
matched disagrees with the count the workflow names. Those tests had never run
anywhere but CI.

No count is given here on purpose. This said "seventeen of them now" in the
same breath as "the number is not worth keeping in prose", and by 5 October it
was **40 files and 503 tests** — the prose outlived its own advice. The run
prints the real figures and floors them (`503 tests ran, floor 503`), so ask
the check, not this file.

Only where npm cannot supply one either does it hand over to
`check_with_tsc.sh` — same entry points, same supabase-js stub, plus a narrow
declaration of the four pieces of Deno this repository uses. It needs a `tsc`
(`npm install --no-save typescript@5`, or set `TSC`). Weaker again, in the same
direction: green under tsc is not green under `deno check`, which is not green
in CI, and red at any level is red at every level above it.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
- **Install the SQL grammar first: `pip install "graphifyy[sql]"`.** Without it
  `tree_sitter_sql` is missing and every one of the ~800 migrations contributes
  **nothing** to the graph — silently, as one warning line at the end of a long
  extraction. On a project whose own first rule is that the database is the
  application, a graph built without it is a graph of the front end. It is worth
  5,476 nodes: 25,212 without, 30,688 with.
