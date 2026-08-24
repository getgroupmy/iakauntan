#!/usr/bin/env bash
# Rebuild a local Postgres from the migrations, for machines without
# Docker. CI uses `supabase start` and CI is the authority; this is a
# development convenience only.
#
#   scripts/localdb/rebuild.sh          # rebuild and apply every migration
#
# Needs: postgresql-16, postgresql-16-cron. Serves on port 55432 over a
# unix socket in $PGDIR.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PGBIN=${PGBIN:-/usr/lib/postgresql/16/bin}
PGDATA=${PGDATA:-/var/tmp/pgdata}
PGDIR=${PGDIR:-/var/tmp/pgd}
PORT=${PGPORT:-55432}
PSQL="psql -U postgres -h $PGDIR -p $PORT"

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  mkdir -p "$PGDATA" "$PGDIR"; chown postgres:postgres "$PGDATA" "$PGDIR"
  su postgres -c "$PGBIN/initdb -D $PGDATA -U postgres --locale=C.UTF-8 -E UTF8" >/dev/null
  # 0060 schedules the daily job with pg_cron, which must be preloaded.
  echo "shared_preload_libraries = 'pg_cron'" >> "$PGDATA/postgresql.conf"
  echo "cron.database_name = 'iakauntan'"     >> "$PGDATA/postgresql.conf"
fi
if ! $PSQL -d postgres -tc "select 1" >/dev/null 2>&1; then
  su postgres -c "$PGBIN/pg_ctl -D $PGDATA -o '-p $PORT -k $PGDIR -c listen_addresses=' -l /var/tmp/pg.log start" >/dev/null
  sleep 2
fi

# pg_cron's background worker holds a session on the target database.
$PSQL -d postgres -q -c "select pg_terminate_backend(pid) from pg_stat_activity
                          where datname='iakauntan' and pid <> pg_backend_pid()" >/dev/null
$PSQL -d postgres -q -c "drop database if exists iakauntan"
$PSQL -d postgres -q -c "create database iakauntan"
$PSQL -d iakauntan -v ON_ERROR_STOP=1 -q -f "$ROOT/scripts/localdb/supabase-shim.sql" 2>&1 | grep -v NOTICE || true

log=/var/tmp/mig.log; : > "$log"
for f in "$ROOT"/supabase/migrations/*.sql; do
  if ! $PSQL -d iakauntan -v ON_ERROR_STOP=1 -q -f "$f" >>"$log" 2>&1; then
    echo "FAILED AT: $(basename "$f")"; grep ERROR "$log" | tail -3; exit 1
  fi
done
echo "all $(ls "$ROOT"/supabase/migrations/*.sql | wc -l) migrations applied"
