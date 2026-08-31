#!/usr/bin/env bash
#
# Run the SQL assertions against a throwaway Postgres on this machine.
#
# CLAUDE.md says "CI is the only place the SQL assertions in
# supabase/tests/ actually run". That was true, and it made every SQL
# change a twenty-minute round trip through a hosted runner. This runs
# the same list in about two minutes locally.
#
# ## What this is not
#
# It is not Supabase, and it is not a reason to skip CI. Supabase's own
# `auth` and `storage` schemas are shipped by services this script does
# not have, so it stands up the parts the migrations and tests actually
# touch:
#
#   * `auth.users` and friends, with the columns our fixtures insert.
#     The real table has more, and a test that starts using one will
#     fail here and pass there — which is the failure direction to
#     prefer, but it is a difference.
#   * `auth.uid()`, `auth.role()`, `auth.jwt()`, reading
#     `request.jwt.claims` the way the real ones do. This is what makes
#     `pg_temp.sign_in_as` work, so RLS is genuinely exercised.
#   * `storage.objects` and `storage.buckets` as bare tables. Our own
#     migrations supply every policy on them, so `logo_storage.sql`
#     asserts the real rules; what is approximate is the table shape.
#   * `pgcrypto` in `extensions`, on the search path, because that is
#     where Supabase puts it and migrations call `gen_random_bytes`
#     unqualified.
#
# `supabase start` in CI runs the real thing. Believe that one.
#
# ## Using it
#
#   supabase/tests/run_locally.sh            # migrations, then every test
#   supabase/tests/run_locally.sh --keep     # skip the rebuild, tests only
#   supabase/tests/run_locally.sh a.sql b.sql
#
# Needs postgresql-16 and pg_cron installed, and root (initdb refuses to
# run as root, so the cluster is started as the `postgres` user).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PGDATA="${IAK_PGDATA:-/var/tmp/pgdata}"
PGSOCK="${IAK_PGSOCK:-/var/tmp}"
PGPORT="${IAK_PGPORT:-5599}"
PGBIN="${IAK_PGBIN:-/usr/lib/postgresql/16/bin}"
PSQL="psql -h $PGSOCK -p $PGPORT -U postgres"

start_cluster() {
  if $PSQL -tAc 'select 1' >/dev/null 2>&1; then return; fi
  if [ ! -s "$PGDATA/PG_VERSION" ]; then
    rm -rf "$PGDATA"; mkdir -p "$PGDATA"; chown -R postgres:postgres "$PGDATA"
    su postgres -c "$PGBIN/initdb -D $PGDATA -A trust -U postgres" >/dev/null
    # pg_cron is a shared library and 0060 installs the extension, so it
    # has to be preloaded before any migration runs.
    printf "shared_preload_libraries = 'pg_cron'\ncron.database_name = 'postgres'\n" \
      >> "$PGDATA/postgresql.conf"
  fi
  su postgres -c \
    "$PGBIN/pg_ctl -D $PGDATA -l /var/tmp/pg.log -o '-k $PGSOCK -p $PGPORT' start" \
    >/dev/null
  for _ in $(seq 1 30); do
    $PSQL -tAc 'select 1' >/dev/null 2>&1 && return
    sleep 1
  done
  echo "postgres did not come up; see /var/tmp/pg.log" >&2; exit 1
}

# The schemas Supabase would have supplied. Dropped and rebuilt each
# time so a run starts from the same place a fresh CI database does.
bootstrap() {
  $PSQL -q -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL'
drop extension if exists pg_cron cascade;
drop schema if exists app cascade;
drop schema if exists auth cascade;
drop schema if exists storage cascade;
drop schema if exists public cascade;
drop publication if exists supabase_realtime;
create schema public;
grant all on schema public to postgres;
SQL
  $PSQL -q -v ON_ERROR_STOP=1 -f "$ROOT/supabase/tests/_local_stack.sql" >/dev/null
}

migrate() {
  local f err
  for f in "$ROOT"/supabase/migrations/*.sql; do
    err=$($PSQL -q -v ON_ERROR_STOP=1 -f "$f" 2>&1 | grep 'ERROR:' | head -2 || true)
    if [ -n "$err" ]; then
      echo "MIGRATION FAILED  $(basename "$f")"; echo "$err"; exit 1
    fi
  done
  echo "migrations applied"
}

# The list CI runs, read out of the workflow rather than kept in step by
# hand — a second copy is a copy that drifts, and the drift is silent.
ci_tests() {
  python3 - "$ROOT" <<'PY'
import re, sys
t = open(sys.argv[1] + '/.github/workflows/ci.yml').read()
# Every `for f in ... ; do` in the file, and the one that names the most
# test files wins. There is more than one now: the job also carries a
# guard step looping over `supabase/tests/*.sql` to check none has been
# left out of the list, and a non-greedy match found that one first — so
# this read a glob, ran nothing, and printed "all SQL assertions passed
# (0 files)". Which is the exact failure the guard exists to catch,
# arriving from the other side.
best = []
for m in re.finditer(r'for f in (supabase/tests/.*?); do', t, re.S):
    found = re.findall(r'supabase/tests/[a-z0-9_]+\.sql', m.group(1))
    if len(found) > len(best):
        best = found
print('\n'.join(best))
PY
}

main() {
  local keep=0
  if [ "${1:-}" = "--keep" ]; then keep=1; shift; fi
  start_cluster
  if [ $keep -eq 0 ]; then bootstrap; migrate; fi

  local files failed=0 out
  if [ $# -gt 0 ]; then files="$*"; else files="$(ci_tests)"; fi
  # A run that finds no tests is not a run that passed. This printed
  # "all SQL assertions passed (0 files)" once, in green, and only the
  # count gave it away.
  if [ -z "$files" ]; then
    echo "no assertion files found in .github/workflows/ci.yml" >&2
    exit 1
  fi
  for f in $files; do
    # A file named in ci.yml and not on disk. `psql -f` says
    #   psql: error: ... No such file or directory
    # in lower case, which the ERROR: grep below does not match — so a
    # test renamed on one side and not the other reported green here and
    # ran nothing. Same shape as the "0 files" hole above, one layer in.
    if [ ! -f "$ROOT/$f" ]; then
      echo "FAIL  $f"
      echo "  named in ci.yml and not on disk"
      failed=1
      continue
    fi
    # Both cases: `psql:file:12: ERROR:` is a failing assertion, and
    # `psql: error:` is psql itself refusing to start. A notice that
    # happens to contain the word would be a false failure, which is the
    # safe direction to be wrong in.
    out=$($PSQL -q -v ON_ERROR_STOP=1 -f "$ROOT/$f" 2>&1 \
            | grep -E '^psql.*([Ee][Rr][Rr][Oo][Rr]):' | head -3 || true)
    if [ -n "$out" ]; then echo "FAIL  $f"; echo "$out"; failed=1; fi
  done
  if [ $failed -eq 0 ]; then
    echo "all SQL assertions passed ($(echo "$files" | wc -w) files)"
  fi
  return $failed
}

main "$@"
