#!/usr/bin/env bash
#
# Run the SQL assertions as if today were some other day.
#
#     supabase/tests/run_at_dates.sh                    # the default days
#     supabase/tests/run_at_dates.sh 2027-01-05 ...     # these days
#     IAK_ONLY="a.sql b.sql" supabase/tests/run_at_dates.sh 2027-01-05
#
# ## Why
#
# Every assertion here is run on ONE day: the day CI happens to run it.
# A fixture that opens `date '2026-01-01'` and then voids something
# dated today, or opens this year and back-dates an invoice by twenty
# days, is right on that day and wrong on others -- and nothing says so
# until the calendar turns and CI goes red on a push that changed
# nothing. Here a red CI stops every deploy.
#
# On 9 October 2026 this was measured rather than reasoned about: the
# local database was copied and the copies started with their clocks set
# to 28 December, 5 January, 15 February, 10 March and 1 June. Some
# thirty files failed, the scheduled demo rebuild would have failed
# every day from 1 January to early June (`0771`), and one file's
# expected count would have gone wrong a week later. `docs/handoff.md`
# has the list.
#
# ## How
#
# libfaketime, preloaded into the postgres server, so `now()` itself --
# and with it `app.today()`, `pg_temp.today()` and every default and
# trigger that reads the clock -- is the day asked for. Replacing
# `app.today()` in a transaction was tried first and is NOT the same:
# half the schema reads `now()` directly, and the result was dozens of
# failures that were artefacts of a clock disagreeing with itself.
#
# Each day gets a COPY of the cluster `run_locally.sh` built, on its own
# port, started at 10:00 in Kuala Lumpur (02:00 UTC) so the Malaysian day
# and the UTC day agree. The copies are removed at the end.
#
# ## What it needs
#
#   * a cluster built by `run_locally.sh` at $IAK_PGDATA (default
#     /var/tmp/pgdata), stopped or running -- it is stopped for the copy
#     and started again after;
#   * libfaketime (`apt-get install -y libfaketime`);
#   * root, as `run_locally.sh` does, to run postgres as `postgres`;
#   * disk: one copy of the data directory per day (about 1 GB each).
#
# ## What it is not
#
# Not CI, and not a substitute for `run_locally.sh`, which it reads its
# file list from the same way. A file that fails here on some day is a
# file that WILL fail in CI on that day; one that passes here has passed
# on the days asked and on no others.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PGBIN="${IAK_PGBIN:-/usr/lib/postgresql/16/bin}"
SRC="${IAK_PGDATA:-/var/tmp/pgdata}"
SOCK="${IAK_PGSOCK:-/var/tmp}"
SRCPORT="${IAK_PGPORT:-5599}"
BASEPORT="${IAK_CLOCK_PORT:-5700}"
LIB="${IAK_FAKETIME_LIB:-/usr/lib/x86_64-linux-gnu/faketime/libfaketime.so.1}"

if [ ! -f "$LIB" ]; then
  echo "libfaketime is not installed: apt-get install -y libfaketime" >&2
  exit 2
fi
if [ ! -f "$SRC/PG_VERSION" ]; then
  echo "no cluster at $SRC -- run supabase/tests/run_locally.sh first" >&2
  exit 2
fi

# The days. Without arguments: the end of this year and the first months
# of the next, where every failure found so far was -- the year turning
# under a fixture that assumed it would not -- and one ordinary day.
if [ $# -gt 0 ]; then
  days=("$@")
else
  y=$(date +%Y)
  # 1 January because "yesterday" is last year on it and on no other
  # day: pos_food_court.sql settled yesterday into a year it had not
  # opened, and failed on that one day alone (measured, 9 October).
  days=("$y-12-28" "$((y + 1))-01-01" "$((y + 1))-01-05" "$((y + 1))-02-15"
        "$((y + 1))-03-10" "$((y + 1))-06-01")
fi

# The list CI runs, exactly as `run_locally.sh` reads it.
ci_tests() {
  python3 - "$ROOT" <<'PY'
import re, sys
t = open(sys.argv[1] + '/.github/workflows/ci.yml').read()
best = []
for m in re.finditer(r'for f in (supabase/tests/.*?); do', t, re.S):
    found = re.findall(r'supabase/tests/[a-z0-9_]+\.sql', m.group(1))
    if len(found) > len(best):
        best = found
print('\n'.join(best))
PY
}
files="${IAK_ONLY:-$(ci_tests)}"
if [ -z "$files" ]; then
  echo "no assertion files found in .github/workflows/ci.yml" >&2
  exit 1
fi

as_postgres() { su postgres -c "$*"; }

copies=()
cleanup() {
  for c in "${copies[@]:-}"; do
    [ -n "$c" ] || continue
    as_postgres "$PGBIN/pg_ctl -D $c stop -m fast" >/dev/null 2>&1 || true
    rm -rf "$c"
  done
}
trap cleanup EXIT

# One consistent copy per day: the source is stopped while it is taken.
was_running=0
if as_postgres "$PGBIN/pg_ctl -D $SRC status" >/dev/null 2>&1; then
  was_running=1
  as_postgres "$PGBIN/pg_ctl -D $SRC stop -m fast" >/dev/null
fi
i=0
for d in "${days[@]}"; do
  c="$SRC.at.$d"
  rm -rf "$c"
  cp -a "$SRC" "$c"
  rm -f "$c/postmaster.pid"
  copies+=("$c")
  i=$((i + 1))
done
if [ $was_running -eq 1 ]; then
  as_postgres "$PGBIN/pg_ctl -D $SRC -o '-k $SOCK -p $SRCPORT' -l $SOCK/pg.log start" >/dev/null
fi

# Start each copy with its clock, and run the list against it. The days
# run side by side; the files within a day run in CI's order, because a
# file can leave state the next one reads and CI does not shuffle.
run_day() {
  local d="$1" c="$2" port="$3" out="$4" f msg
  as_postgres "LD_PRELOAD=$LIB FAKETIME='@$d 02:00:00' FAKETIME_DONT_FAKE_MONOTONIC=1 \
    $PGBIN/pg_ctl -D $c -o '-k $SOCK -p $port' -l $c/clock.log start" >/dev/null
  for _ in $(seq 1 60); do
    pg_isready -h "$SOCK" -p "$port" -q && break
    sleep 0.5
  done
  : > "$out"
  for f in $files; do
    if msg=$(cd "$ROOT" && psql -h "$SOCK" -p "$port" -U postgres -d postgres \
               -X -q -v ON_ERROR_STOP=1 -f "$f" 2>&1 >/dev/null); then
      :
    else
      echo "$d  $(basename "$f")  $(echo "$msg" | grep -m1 ERROR \
             | sed 's/^psql:[^:]*:\([0-9]*\): ERROR: */line \1: /' | cut -c1-200)" >> "$out"
    fi
  done
}

tmp="$(mktemp -d)"
i=0
for d in "${days[@]}"; do
  run_day "$d" "${copies[$i]}" $((BASEPORT + i)) "$tmp/$d" &
  i=$((i + 1))
done
wait

n_files=$(echo "$files" | wc -w)
failed=0
for d in "${days[@]}"; do
  if [ -s "$tmp/$d" ]; then
    cat "$tmp/$d"
    failed=$((failed + $(wc -l < "$tmp/$d")))
  else
    echo "$d  all $n_files files passed"
  fi
done
rm -rf "$tmp"
[ $failed -eq 0 ]
