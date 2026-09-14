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
#
# `--keep` refuses if the migrations on disk have changed since the
# database was built: the cluster a mutation run leaves behind still
# holds its last mutant, and a suite run against it reports a failure
# that is not in the code.
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
  # A cluster that is ALREADY up still has to be checked. This returned
  # here without calling `check_cluster`, which meant the three
  # diagnostics below it could only ever fire on the run that created
  # the cluster -- and never on the warm container, which is every run
  # after the first. The failure that exposed it: a `$PGDATA` built
  # before `max_locks_per_transaction` was raised came up cleanly, and
  # `bootstrap` then died inside a `>/dev/null 2>&1` with exit 3 and no
  # output at all. The message explaining exactly that was already
  # written, ten lines further down, and unreachable.
  if $PSQL -tAc 'select 1' >/dev/null 2>&1; then check_cluster; return; fi
  if [ ! -s "$PGDATA/PG_VERSION" ]; then
    rm -rf "$PGDATA"; mkdir -p "$PGDATA"; chown -R postgres:postgres "$PGDATA"
    su postgres -c "$PGBIN/initdb -D $PGDATA -A trust -U postgres" >/dev/null
    # pg_cron is a shared library and 0060 installs the extension, so it
    # has to be preloaded before any migration runs.
    printf "shared_preload_libraries = 'pg_cron'\ncron.database_name = 'postgres'\n" \
      >> "$PGDATA/postgresql.conf"
    # `bootstrap` drops the whole public schema in ONE transaction, and
    # a cascading drop takes a lock on every object it removes. The
    # default 64 locks per transaction was enough until the same-org
    # foreign keys went in; at around six hundred constraints the drop
    # started failing with "out of shared memory / you might need to
    # increase max_locks_per_transaction", which names the setting but
    # not the transaction that ran out.
    #
    # CI does not hit this -- it builds a fresh database with
    # `supabase start` and never drops anything -- so this is a limit of
    # this script's rebuild, not of the schema.
    printf "max_locks_per_transaction = 1024\n" >> "$PGDATA/postgresql.conf"
  fi
  su postgres -c \
    "$PGBIN/pg_ctl -D $PGDATA -l /var/tmp/pg.log -o '-k $PGSOCK -p $PGPORT' start" \
    >/dev/null
  for _ in $(seq 1 30); do
    $PSQL -tAc 'select 1' >/dev/null 2>&1 && { check_cluster; return; }
    sleep 1
  done
  echo "postgres did not come up; see /var/tmp/pg.log" >&2; exit 1
}

# A cluster this script did not build.
#
# The block above writes `shared_preload_libraries` and
# `cron.database_name` only when it runs `initdb`. A `$PGDATA` that
# already exists is adopted as-is, on the assumption that a previous run
# of this script made it -- and that assumption is wrong often enough to
# be worth checking, because `/var/tmp` survives longer than the thing
# that put it there.
#
# It cost a full rebuild to work out once. A five-day-old cluster with
# `cron.database_name = 'iakauntan'` was adopted, started cleanly, and
# then failed sixty migrations later with
#
#     0060: ERROR: can only create extension in database iakauntan
#
# which is pg_cron refusing on a setting nothing in the output had
# mentioned. The migration is fine; the cluster was wrong, and the error
# names neither.
#
# So the settings the migrations actually need are checked against the
# running server, and the remedy is named. `current_setting(..., true)`
# rather than `show`, because `show` on a GUC pg_cron never registered
# is itself an error and would report the wrong thing.
check_cluster() {
  local libs cron_db here locks
  libs="$($PSQL -tAc "select current_setting('shared_preload_libraries', true)")"
  cron_db="$($PSQL -tAc "select current_setting('cron.database_name', true)")"
  here="$($PSQL -tAc 'select current_database()')"

  case "$libs" in
    *pg_cron*) ;;
    *) cluster_wrong "pg_cron is not preloaded (shared_preload_libraries = '${libs:-}')" ;;
  esac

  # pg_cron will only install into the one database it was pointed at,
  # and the migrations run in whichever one this script connects to.
  if [ -n "$cron_db" ] && [ "$cron_db" != "$here" ]; then
    cluster_wrong \
      "pg_cron is pointed at database '$cron_db' but the migrations run in '$here'"
  fi

  # Checked for the same reason as the two above: a cluster built before
  # this setting was added starts cleanly and then fails in `bootstrap`
  # with "out of shared memory", which names max_locks_per_transaction
  # but not the drop that exhausted it.
  locks="$($PSQL -tAc "select current_setting('max_locks_per_transaction', true)")"
  if [ -z "$locks" ] || [ "$locks" -lt 1024 ]; then
    cluster_wrong \
      "max_locks_per_transaction is ${locks:-unset}, and dropping the public schema needs at least 1024"
  fi
}

cluster_wrong() {
  cat >&2 <<EOF
The postgres cluster already at $PGDATA is not configured the way the
migrations need, and this script only writes that configuration when it
creates the cluster itself. So it was started and left alone.

  $1

It is a throwaway test cluster, so the fix is to let this script build a
new one:

  rm -rf $PGDATA

or point somewhere else with IAK_PGDATA=/some/other/path.
EOF
  exit 1
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

# A fingerprint of every migration file's contents.
#
# Recorded when the database is built and checked when `--keep` skips
# the rebuild, because the trap below has been walked into three times.
migration_stamp() {
  cat "$ROOT"/supabase/migrations/*.sql | md5sum | cut -d' ' -f1
}

# `--single-transaction` is the whole point of this loop, not a tidiness.
#
# CI applies migrations with `supabase db push`, which wraps each file in
# one transaction. Without the flag psql commits every statement on its
# own, and a file whose later statements depend on its earlier ones
# being *committed* passes here and fails there. That is not
# hypothetical: 0471 adds a value to `app.contact_type` and then asks
# whether it is there, and `enum_range` on a type altered in the same
# transaction is refused with 55P04 -- green locally, red in CI.
#
# A migration that genuinely cannot run inside a transaction (`create
# index concurrently`, `vacuum`) would now fail here. It would fail in
# CI too, so failing here is the correct answer.
migrate() {
  local f err
  for f in "$ROOT"/supabase/migrations/*.sql; do
    err=$($PSQL -q -v ON_ERROR_STOP=1 --single-transaction -f "$f" 2>&1 | grep 'ERROR:' | head -2 || true)
    if [ -n "$err" ]; then
      echo "MIGRATION FAILED  $(basename "$f")"; echo "$err"; exit 1
    fi
  done
  migration_stamp > "$PGDATA/iak_migration_stamp"
  echo "migrations applied"
}

# Refuse to run assertions against a database older than the migrations.
#
# `--keep` exists for two good reasons: `scripts/check_embeds.py` needs
# a database that already exists, and re-running one test file while
# iterating should not cost two minutes. It has a bad third use, which
# is running the suite on a cluster left behind by a mutation run — the
# mutant is still in the database, the file on disk is innocent, and the
# failure looks like a real one for as long as it takes to work out that
# the deployed function is not the code being read.
#
# So: the stamp. If the migrations have changed since the database was
# built, say so and stop, rather than reporting on a schema that no
# longer exists anywhere but in this cluster.
check_stamp() {
  local want have
  want="$(migration_stamp)"
  have="$(cat "$PGDATA/iak_migration_stamp" 2>/dev/null || true)"
  if [ "$want" != "$have" ]; then
    echo "--keep refused: this database was built from different" >&2
    echo "migrations than the ones on disk. Re-run without --keep." >&2
    echo "(A mutation run leaves its last mutant in the database.)" >&2
    exit 1
  fi
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
  if [ $keep -eq 0 ]; then bootstrap; migrate; else check_stamp; fi

  local files failed=0 out
  if [ $# -gt 0 ]; then files="$*"; else files="$(ci_tests)"; fi
  # A run that finds no tests is not a run that passed. This printed
  # "all SQL assertions passed (0 files)" once, in green, and only the
  # count gave it away.
  if [ -z "$files" ]; then
    echo "no assertion files found in .github/workflows/ci.yml" >&2
    exit 1
  fi

  # And the mirror of it. CI has a step asserting that every file in
  # `supabase/tests/` is named in the list; this script did not, so a
  # new assertion file could be written, run by hand, reported green,
  # and never run by either -- which is the hole the CI step exists to
  # close, arriving from the third side. `ssm_register_lookup.sql` went
  # that way: fourteen assertions passing locally against a list that
  # had never heard of it.
  #
  # Only on a full run. Given explicit files the caller is iterating on
  # one, and that is not the moment to be told about another.
  if [ $# -eq 0 ]; then
    local listed unlisted=""
    listed=" $(echo $files) "
    for f in "$ROOT"/supabase/tests/*.sql; do
      case "$(basename "$f")" in _*) continue ;; esac
      case "$listed" in
        *" supabase/tests/$(basename "$f") "*) ;;
        *) unlisted="$unlisted supabase/tests/$(basename "$f")" ;;
      esac
    done
    if [ -n "$unlisted" ]; then
      echo "on disk and not named in .github/workflows/ci.yml:$unlisted" >&2
      echo "  add them to the list in the database job, or CI never runs them" >&2
      exit 1
    fi
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
  if [ $failed -ne 0 ]; then return $failed; fi
  echo "all SQL assertions passed ($(echo "$files" | wc -w) files)"

  # Only on a full run. Given explicit files, the caller is iterating on
  # one assertion and does not want five whole-repository scans.
  if [ $# -eq 0 ]; then
    schema_checks || failed=1
  fi
  return $failed
}

# ---------------------------------------------------------------------
# The checks that need the client AND the schema in the same room
# ---------------------------------------------------------------------
#
# Five of these run in CI and none of them ran here, which is a gap the
# four gates could not see: every one of them lives inside a Dart string
# literal, so `flutter analyze` cannot read it, the widget tests have no
# database, and the SQL assertions do not know what the client asks for.
#
# It cost a red run. `posSaleLines` grew an `items(tracking)` embed for
# `0546`, the comment beside it said "one foreign key, so PostgREST
# resolves it unaided", and that was simply wrong -- `0520` added a
# composite same-org key alongside the plain one, and PostgREST refuses
# two candidates with PGRST201. `check_embeds.py` says so in one line
# and takes two seconds, and it said so in CI eight minutes after a push
# that had passed all four gates.
#
# The cluster is already up and already migrated by the time this runs,
# so the whole set costs seconds. There is no reason for CI to be the
# first place they are asked.
schema_checks() {
  local url="postgresql://postgres@localhost/postgres?host=$PGSOCK&port=$PGPORT"
  local failed=0 out script args

  # The list is READ OUT OF ci.yml rather than kept here, for the same
  # reason `ci_tests` reads the test list out of it: a second copy is a
  # copy that drifts, and the drift is silent in the direction nobody
  # looks. This function used to name seven scripts by hand. CI ran
  # fifteen, and the eight it did not name included
  # `generate_api_description.py --check` -- which is how a migration
  # went up with `docs/api/` still describing the schema before it: a
  # red run over a file that regenerates in one command, with every
  # gate on this machine green.
  #
  # Whether a script takes the database url is decided the same way, by
  # whether the step in ci.yml passes it one. Nothing here knows what
  # any particular script wants.
  while IFS='|' read -r script args; do
    [ -n "$script" ] || continue
    [ -f "$ROOT/scripts/$script" ] || continue
    if [ -z "$args" ]; then
      out=$(python3 "$ROOT/scripts/$script" 2>&1) || {
        echo "FAIL  scripts/$script"; echo "$out" | head -12; failed=1; }
    elif [ "$args" = "db" ]; then
      out=$(python3 "$ROOT/scripts/$script" "$url" 2>&1) || {
        echo "FAIL  scripts/$script"; echo "$out" | head -12; failed=1; }
    else
      # shellcheck disable=SC2086
      out=$(python3 "$ROOT/scripts/$script" "$url" $args 2>&1) || {
        echo "FAIL  scripts/$script $args"; echo "$out" | head -14; failed=1; }
    fi
  done <<GUARDS
$(ci_guards)
GUARDS

  if [ $failed -eq 0 ]; then echo "schema and client agree"; fi
  return $failed
}

# Every `python3 scripts/<name>.py` step in the workflow, and whether
# that step hands it the database url.
#
# Two are excluded, each with its reason written beside it below:
# `schema_drift.py`, which compares the LOCAL schema against the HOSTED
# project and needs credentials this machine has no business holding,
# and `dependency_audit.py`, which needs api.osv.dev. The `*_test.py`
# files are excluded too, because they are unit tests OF the scripts
# rather than checks of this repository. Every exclusion is named
# rather than inferred, so skipping something is a decision somebody
# had to write down.
ci_guards() {
  python3 - "$ROOT" <<GUARDSPY
import re, sys

# \`dependency_audit.py\` asks api.osv.dev about every pinned package and
# treats an unreachable advisory database as a FAILURE rather than a
# pass -- which is right, and which means it cannot pass on a machine
# whose egress is a proxy that refuses it. A gate that is always red is
# a gate people learn to scroll past, so it is CI's to run. Its own
# unit tests run everywhere and are covered by the \`_test.py\` rule
# below.
SKIP = {'schema_drift.py', 'dependency_audit.py'}

text = open(sys.argv[1] + '/.github/workflows/ci.yml').read()
seen = set()
for m in re.finditer(r'python3 scripts/([A-Za-z0-9_]+[.]py)([^\n]*)', text):
    name, rest = m.group(1), m.group(2)
    if name in SKIP or name.endswith('_test.py'):
        continue
    # \`"\$DB"\` is how every workflow step spells the url; what follows
    # it is the flags that step passes, \`--check\` being the only one
    # today.
    takes_db = '"\$DB"' in rest
    flags = rest.replace('"\$DB"', '').strip()
    key = (name, takes_db, flags)
    if key in seen:
        continue
    seen.add(key)
    print(name + '|' + ((flags or 'db') if takes_db else ''))
GUARDSPY
}

main "$@"
