#!/usr/bin/env bash
# Run the SQL assertions CI runs, against the local database.
# Usage: scripts/localdb/suite.sh [file.sql ...]   (default: all of CI's list)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PSQL="psql -U postgres -h ${PGDIR:-/var/tmp/pgd} -p ${PGPORT:-55432} -d iakauntan"
if [ $# -gt 0 ]; then FILES="$*"; else
  FILES=$(sed -n '/for f in supabase\/tests/,/migration_progress.sql; do/p' \
          "$ROOT/.github/workflows/ci.yml" | grep -o "supabase/tests/[a-z_]*\.sql")
fi
fails=0; total=0
for f in $FILES; do
  out=$($PSQL -q -f "$ROOT/$f" 2>&1)
  total=$((total + $(printf '%s' "$out" | grep -c "NOTICE:  ok ")))
  if printf '%s' "$out" | grep -q "ERROR:"; then
    fails=$((fails+1)); echo "FAIL $f"; printf '%s' "$out" | grep "ERROR:" | head -3
  fi
done
echo "assertions=$total files_failing=$fails"
