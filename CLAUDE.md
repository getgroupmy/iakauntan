# iAkauntan

A Flutter (web/Android/iOS) front end over a Supabase Postgres back end:
accounting, CRM, HR and payroll, corporate secretarial and LHDN e-Invoice for
Malaysian businesses. `README.md` is the real orientation — read it before
changing anything statutory.

Two things to know before you touch the code:

- **The database is the application.** Business rules live in SQL — numbered,
  append-only migrations in `supabase/migrations/`, applied in order and never
  edited once applied. Permissions are RLS policies plus `app.can_*` guards
  inside SECURITY DEFINER functions. A rule enforced only in Dart is not
  enforced.
- **Statutory arithmetic is asserted, not eyeballed.** `supabase/tests/*.sql`
  runs in CI. Anything touching EPF, SOCSO, EIS, PCB or an SSM deadline needs a
  test that would fail if the number moved.

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
runs the same list against a throwaway Postgres on this machine in about two
minutes — use it to find a broken assertion before pushing, not to skip the
push. It stubs Supabase's `auth` and `storage` schemas, and its own header says
where the stubs stop being the real thing.

The edge functions have the same arrangement.
`supabase/functions/_local_check/check_locally.sh` type-checks all of them here,
stubbing `jsr:@supabase/supabase-js` so the check does not need jsr.io — which
is unreachable from some machines this gets worked on, and was the reason a
type error in `pay-invoice-callback` was found by CI rather than before the
push. Green there is not green in CI: every call made *on* the Supabase client
is unchecked. Red there is red in CI.

Where there is no `deno` either, it hands over to `check_with_tsc.sh` on its
own — same entry points, same supabase-js stub, plus a narrow declaration of
the four pieces of Deno this repository uses. It needs a `tsc`
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
