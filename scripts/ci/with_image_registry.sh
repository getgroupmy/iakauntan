#!/usr/bin/env bash
# Run a Supabase CLI command against whichever image registry answers.
#
# ## The failure this exists for, twice
#
# Runs 2097-2100 died pulling `ghcr.io/supabase/edge-runtime` with
#
#     toomanyrequests: retry-after: 937.64µs, allowed: 44000/minute
#
# and the remedy was to move to `public.ecr.aws`. Run 2148 then died
# pulling the same image from there with
#
#     toomanyrequests: Data limit exceeded
#
# Both have ONE cause, and it is not the registry: **the pull is
# anonymous**. An Actions runner shares its address with every other
# runner on the host, so an anonymous per-address budget is not ours to
# stay inside — and there is always a third bucket to move to, which will
# also run out. `docker login ghcr.io` with the `GITHUB_TOKEN` every run
# already carries costs one step and no secret, and quotas an
# authenticated pull to the account instead of to the address.
#
# ## Why a fallback and not a swap
#
# Because the last two changes here were swaps, and each one held until
# the new bucket ran out. This runs the command against `ghcr.io` first
# and, if that fails for any reason at all, runs it again against
# `public.ecr.aws` — which is exactly what CI does today. So the worst
# case of this script is the current behaviour, and it cannot regress the
# pull however wrong the authenticated attempt turns out to be.
#
# That property is the point, so it is asserted:
# `with_image_registry_test.sh` covers the primary succeeding, the
# fallback rescuing a failed primary, both failing (the status is the
# FALLBACK's, and non-zero), and the registry each attempt actually saw.
#
# ## What it does not do
#
# It does not retry. `retry.sh` does that, and the two compose — wrap
# this OUTSIDE it and each registry gets the retry budget:
#
#     RETRY_ATTEMPTS=2 RETRY_DELAY=60 \
#       scripts/ci/with_image_registry.sh scripts/ci/retry.sh supabase ...
#
# Halve the attempts when you do, or the wall-clock doubles. Two
# registries at two attempts is a better spend than one at four: a quota
# refusal is immediate and identical however long you wait for it, which
# run 2148 proved by failing four times 60, 120 and 240 seconds apart and
# then succeeding on a fresh runner within a minute. The cap is bound to
# the RUNNER, not the clock.
#
# Usage:
#   scripts/ci/with_image_registry.sh supabase db dump --local -f out.sql
set -uo pipefail

primary="${IMAGE_REGISTRY_PRIMARY:-ghcr.io}"
fallback="${IMAGE_REGISTRY_FALLBACK:-public.ecr.aws}"

if [ "$#" -eq 0 ]; then
  echo "with_image_registry.sh: nothing to run" >&2
  exit 2
fi

# Exported rather than passed as a `VAR=x cmd` prefix, because the
# command is often `bash -c '...'` or another wrapper, and a prefix on
# the wrapper does not always reach the CLI underneath it.
status=0
SUPABASE_INTERNAL_IMAGE_REGISTRY="$primary" "$@" || status=$?
if [ "$status" -eq 0 ]; then
  exit 0
fi

if [ "$primary" = "$fallback" ]; then
  echo "::error::\`$*\` failed against $primary, and there is no other" \
       "registry configured to try." >&2
  exit "$status"
fi

echo "::warning::\`$*\` failed against $primary (exit $status); trying" \
     "$fallback. If this says \`toomanyrequests\` the pull was refused," \
     "not the command — see scripts/ci/with_image_registry.sh." >&2

status=0
SUPABASE_INTERNAL_IMAGE_REGISTRY="$fallback" "$@" || status=$?
if [ "$status" -ne 0 ]; then
  echo "::error::\`$*\` failed against both $primary and $fallback;" \
       "last exit $status" >&2
fi
exit "$status"
