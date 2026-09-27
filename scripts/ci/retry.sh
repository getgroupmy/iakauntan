#!/usr/bin/env bash
# Retry a command that has to reach the hosted Supabase project.
#
# Every `supabase ... --linked` call in CI is one TCP connection to
# `aws-0-ap-northeast-2.pooler.supabase.com`, and the pooler times out
# occasionally. Twice in one hour on 2026-08-24 that took a branch red on
# commits whose diffs touched no network at all — `7cc95ea` at "Confirm
# the project is level" and `54f8e5e` at "What is applied and what is
# pending" — and both times it also skipped the two deploy jobs behind
# them.
#
# CI is this project's real failure signal, so it must not cry wolf. A
# check that goes red for reasons the commit cannot cause is a check
# people learn to re-run without reading, which is the same as not having
# it.
#
# Bounded, not infinite: four attempts with backoff, then the failure
# stands. A pooler that is down for ten minutes should still turn the run
# red — what this removes is the single-packet loss, not the outage.
#
# Retrying `db push` is safe, which is the part worth writing down: the
# CLI records each migration in `supabase_migrations.schema_migrations`
# inside the same transaction that applies it, so a connection lost
# mid-flight leaves either both or neither. A retry re-reads the history
# and applies whatever is genuinely still pending — the same thing the
# next push to the branch would do.
#
# Usage:
#   scripts/ci/retry.sh supabase db push --linked
#   scripts/ci/retry.sh -o /tmp/list.txt supabase migration list --linked
#
# `-o FILE` captures stdout to FILE and echoes it on success. Piping to
# `tee` instead would append every failed attempt's partial output to the
# same file, and the awk that parses it cannot tell a half-written table
# from a real one.
set -uo pipefail

attempts="${RETRY_ATTEMPTS:-4}"
delay="${RETRY_DELAY:-10}"

# Exit codes that mean "this cannot come right on its own", space
# separated. Empty by default, because a `supabase` CLI failure gives
# no such signal and everything here was written for those.
#
# `scripts/play_upload.ts` does give one. The first real Play upload
# spent seventy seconds and four identical stack traces retrying a
# DISABLED API — a switch in a browser. Backoff against a
# configuration error is not resilience, it is four times the noise
# and four times as long to read.
never="${RETRY_NEVER_ON:-}"

out=""
if [ "${1:-}" = "-o" ]; then
  out="$2"
  shift 2
fi

if [ "$#" -eq 0 ]; then
  echo "retry.sh: nothing to run" >&2
  exit 2
fi

n=1
while true; do
  # Captured inside the branch, not after it. Read after an `if`, `$?`
  # is the status of the `if` itself — zero whenever the body ran — so
  # the first version of this reported every failure as exit 0 and, far
  # worse, *exited* 0 once the attempts ran out. A retry wrapper that
  # turns a genuine failure green is worse than no retry at all, and it
  # would have been invisible: the run goes green, which is what you
  # were hoping to see.
  status=0
  if [ -n "$out" ]; then
    "$@" > "$out" || status=$?
  else
    "$@" || status=$?
  fi

  if [ "$status" -eq 0 ]; then
    if [ -n "$out" ]; then cat "$out"; fi
    exit 0
  fi

  for code in $never; do
    if [ "$status" -eq "$code" ]; then
      echo "::error::\`$*\` failed with exit $status, which says trying" \
           "again cannot help. Not retrying." >&2
      exit "$status"
    fi
  done

  if [ "$n" -ge "$attempts" ]; then
    echo "::error::\`$*\` failed $attempts times; last exit $status" >&2
    exit "$status"
  fi

  echo "::warning::\`$*\` failed (attempt $n of $attempts, exit $status); retrying in ${delay}s" >&2
  sleep "$delay"
  n=$((n + 1))
  delay=$((delay * 2))
done
