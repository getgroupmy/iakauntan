#!/usr/bin/env bash
# =====================================================================
# iAkauntan :: type-check the edge functions without a network
#
#   supabase/functions/_local_check/check_locally.sh
#
# CI's "Type-check every function" step runs `deno check` over every
# `supabase/functions/*/index.ts`. It resolves `jsr:@supabase/supabase-js`
# over the network, and on a machine that cannot reach jsr.io that step
# cannot be run at all -- which is how a `boolean` passed to a parameter
# typed `Record<string, string>` reached a branch and was found by CI
# rather than here.
#
# This maps supabase-js onto `supabase_js_stub.ts` so everything else in
# a function is checked locally: the shared helpers, the local types,
# the argument shapes. Read that file for what the substitution costs --
# in short, every call made *on the client* is unchecked, and only CI's
# run against the real package says anything about those.
#
# So: green here is not green in CI. Red here is red in CI.
# =====================================================================
set -euo pipefail

cd "$(dirname "$0")/../../.."

entries=()
for dir in supabase/functions/*/; do
  case "$(basename "$dir")" in _*) continue ;; esac
  [ -f "$dir/index.ts" ] || continue
  entries+=("$dir/index.ts")
done

if [ "${#entries[@]}" -eq 0 ]; then
  echo "No edge functions found under supabase/functions." >&2
  exit 1
fi

# The stub has to actually be reached. An import map that silently fails
# to match would leave `deno check` going to the network, and on a
# machine where that works this script would quietly become a slower
# copy of CI rather than the offline check it claims to be.
if ! grep -q '"jsr:@supabase/supabase-js@2"' supabase/functions/_local_check/import_map.json; then
  echo "The import map no longer names the specifier the functions import." >&2
  exit 1
fi
for f in "${entries[@]}"; do
  if grep -q 'from "jsr:@supabase/supabase-js@' "$f" &&
     ! grep -q 'from "jsr:@supabase/supabase-js@2"' "$f"; then
    echo "$f imports a supabase-js version the import map does not map." >&2
    exit 1
  fi
done

printf 'checking %s\n' "${entries[@]}"
deno check \
  --import-map supabase/functions/_local_check/import_map.json \
  --no-remote \
  "${entries[@]}"

echo
echo "Checked locally. The supabase-js client was a stub -- see"
echo "supabase/functions/_local_check/supabase_js_stub.ts. CI checks it"
echo "against the real package and CI is the authority."
