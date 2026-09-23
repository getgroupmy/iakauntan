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

# No Deno, no deno.land to get one from. Rather than reporting that the
# gate cannot run -- which is how it came to not run, on exactly the
# machines where jsr.io is unreachable, for the same reason -- hand over
# to the `tsc` fallback. It is weaker and it says so; it is not nothing,
# and nothing is what this printed before.
#
# Before handing over, TRY NPM. `dl.deno.land` is what the official
# installer fetches and it is exactly what a locked-down network
# refuses -- this machine gets 403 to CONNECT on it. But Deno is also
# published as an npm package, and `registry.npmjs.org` is reachable
# from the same place, so one `npm install` produces a real `deno` where
# the installer cannot.
#
# That is the difference between the strong gate and the weak one. The
# tsc fallback declares the Deno globals rather than knowing them and
# resolves modules the way a bundler would, and
# `docs/edge-functions.md` records what that costs: a type error in
# `pay-invoice-callback` found by CI rather than before the push.
#
# Cached in the directory below, so the download happens once. Set
# DENO_SKIP_NPM=1 to go straight to the fallback.
if ! command -v deno >/dev/null 2>&1; then
  cache="${DENO_NPM_DIR:-${TMPDIR:-/tmp}/iakauntan-deno}"
  if [ -x "$cache/node_modules/.bin/deno" ]; then
    PATH="$cache/node_modules/.bin:$PATH"
  elif [ -z "${DENO_SKIP_NPM:-}" ] && command -v npm >/dev/null 2>&1; then
    echo "No deno on this machine. Trying npm, which reaches a registry" >&2
    echo "  that dl.deno.land's installer cannot..." >&2
    mkdir -p "$cache"
    if npm install --prefix "$cache" --no-save --silent deno \
         >/dev/null 2>&1 && [ -x "$cache/node_modules/.bin/deno" ]; then
      PATH="$cache/node_modules/.bin:$PATH"
      echo "  got $("$cache/node_modules/.bin/deno" --version | head -1)." >&2
    fi
  fi
fi

if ! command -v deno >/dev/null 2>&1; then
  echo "No deno on this machine, and npm could not supply one." >&2
  echo "Falling back to tsc, which is weaker:" >&2
  echo "  the Deno globals are declared rather than known, and modules" >&2
  echo "  resolve the way a bundler resolves them." >&2
  exec "$(dirname "$0")/check_with_tsc.sh"
fi

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
if ! grep -q '"jsr:@supabase/supabase-js@2.117.0"' supabase/functions/_local_check/import_map.json; then
  echo "The import map no longer names the specifier the functions import." >&2
  exit 1
fi
for f in "${entries[@]}"; do
  if grep -q 'from "jsr:@supabase/supabase-js@' "$f" &&
     ! grep -q 'from "jsr:@supabase/supabase-js@2.117.0"' "$f"; then
    echo "$f imports a supabase-js version the import map does not map." >&2
    exit 1
  fi
done

printf 'checking %s\n' "${entries[@]}"
deno check \
  --import-map supabase/functions/_local_check/import_map.json \
  --no-remote \
  "${entries[@]}"

# ---------------------------------------------------------------------
# And the tests CI runs, which have never run here
# ---------------------------------------------------------------------
#
# Type-checking says the code compiles. These say it is right, and CI
# has been the only place they ran -- so a broken assertion in
# `billplz_test.ts` was a red run rather than a red command here.
#
# The list is READ OUT OF ci.yml rather than kept here, for the reason
# `run_locally.sh` gives about its own two lists: a second copy is a
# copy that drifts, silently, in the direction nobody looks. The flags
# come from the same line, because `web_push_test.ts` needs
# --allow-read and nothing else does.
#
# `--no-remote` is deliberately NOT passed: these test their own pure
# modules and pull `jsr:@std/assert`, which is cached after the first
# run. A machine that cannot reach jsr says so here rather than
# pretending the assertions passed.
# The flags sit BETWEEN the command and the file, so the pattern has to
# allow them. Written `deno test[^ ]*` first, this found nine of the ten
# -- `web_push_test.ts` carries `--allow-read` and was the one that went
# missing. Only the count gave it away, which is the same tell
# `run_locally.sh` records about its own "(0 files)".
tests=()
while IFS= read -r line; do
  [ -n "$line" ] && tests+=("$line")
done < <(grep -oE 'deno test( +--[a-z-]+)* +[^ ]*_test\.(ts|js)' \
           .github/workflows/ci.yml | sed 's/^deno test//' | sort -u)

# And the mirror of it. Every `deno test` line in the workflow has to
# come out of that pattern, or the next flag somebody adds silently
# drops a file from this run while leaving it in CI.
named=$(grep -cE '^\s*- run: deno test ' .github/workflows/ci.yml || true)
if [ "${#tests[@]}" -ne "$named" ]; then
  echo "ci.yml names $named deno tests and this script matched" \
       "${#tests[@]}." >&2
  echo "The pattern above has gone stale against the workflow." >&2
  exit 1
fi

if [ "${#tests[@]}" -eq 0 ]; then
  echo "No deno tests named in .github/workflows/ci.yml." >&2
  echo "That is either a workflow rewrite or this grep going stale." >&2
  exit 1
fi

echo
failed=0
for t in "${tests[@]}"; do
  # shellcheck disable=SC2086
  if deno test --quiet $t >/dev/null 2>&1; then
    printf 'ok   deno test%s\n' "$t"
  else
    printf 'FAIL deno test%s\n' "$t"
    # shellcheck disable=SC2086
    deno test --quiet $t 2>&1 | tail -12
    failed=1
  fi
done
[ $failed -eq 0 ] || exit 1

echo
echo "Checked locally, and the ${#tests[@]} deno tests CI runs passed too."
echo "The supabase-js client was a stub -- see"
echo "supabase/functions/_local_check/supabase_js_stub.ts. CI checks it"
echo "against the real package and CI is the authority."
