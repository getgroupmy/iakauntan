#!/usr/bin/env bash
# =====================================================================
# iAkauntan :: the edge-function type check, without Deno
#
#   supabase/functions/_local_check/check_with_tsc.sh
#
# `check_locally.sh` needs `deno`, and there are machines this
# repository gets worked on from where Deno is not installed and
# deno.land is unreachable -- which left the one gate CLAUDE.md names
# unrunnable, on the same machines where jsr.io is unreachable, for the
# same reason. That is how a type error in `pay-invoice-callback`
# reached CI rather than the machine it was written on, and the fix for
# that was a stub for supabase-js; this is the fix for the runtime.
#
# `tsc` over the same entry points, with the same supabase-js stub, one
# more stub for `@std/assert`, and a narrow declaration of the four
# pieces of Deno this repository uses.
#
# ---------------------------------------------------------------------
# What this is weaker than
#
# Everything `check_locally.sh` gives up, plus two of its own:
#
#   * the Deno globals are DECLARED here rather than known, so a change
#     in Deno's own types is invisible;
#   * `tsc` resolves modules the way a bundler does, not the way Deno
#     does, so an import that Deno would refuse can pass here.
#
# So the ordering is: green here is not green under `deno check`, and
# green under `deno check` is not green in CI. Red at any level is red
# at every level above it, which is the whole of what these are for.
# =====================================================================
set -euo pipefail

cd "$(dirname "$0")"
HERE="$PWD"
cd ../../..

TSC="${TSC:-}"
if [ -z "$TSC" ]; then
  for candidate in \
      node_modules/.bin/tsc \
      "${TSC_HOME:-}/node_modules/.bin/tsc"; do
    [ -x "$candidate" ] && TSC="$candidate" && break
  done
fi
if [ -z "$TSC" ] && command -v tsc >/dev/null 2>&1; then
  TSC="$(command -v tsc)"
fi
if [ -z "$TSC" ]; then
  echo "No tsc. Install one where this can find it:" >&2
  echo "  npm install --no-save typescript@5" >&2
  echo "or set TSC to a tsc binary." >&2
  exit 127
fi

# The Deno globals first. `files` replaces tsc's automatic discovery
# entirely, so a declaration file that is not named here is a
# declaration file that does not exist -- which reads as thirty
# "Cannot find name 'Deno'" errors and no type checking at all.
entries=("supabase/functions/_local_check/deno_globals.d.ts")
for dir in supabase/functions/*/; do
  case "$(basename "$dir")" in _*) continue ;; esac
  [ -f "$dir/index.ts" ] || continue
  entries+=("$dir/index.ts")
done
# The shared helpers and their tests too. A helper is where a wrong
# argument shape hides longest, because nothing imports it by hand.
for extra in supabase/functions/_shared/*.ts; do
  [ -f "$extra" ] && entries+=("$extra")
done

if [ "${#entries[@]}" -eq 0 ]; then
  echo "No edge functions found under supabase/functions." >&2
  exit 1
fi

# The stub has to actually be reached, for `check_locally.sh`'s reason:
# a `paths` entry that silently fails to match would leave `tsc`
# reporting "cannot find module" rather than checking anything, and a
# script that reports nothing is a script that passes.
if ! grep -q 'supabase_js_stub' "$HERE/tsconfig.check.json"; then
  echo "The check tsconfig no longer maps supabase-js to the stub." >&2
  exit 1
fi

# `tsc -p` refuses a file list on the command line, so the list goes
# into a generated project that extends the checked-in one. Generated
# rather than committed because the file list is derived from what is
# on disk, and a committed copy would go stale the first time somebody
# adds a function -- silently, by checking one fewer file.
GEN="$(mktemp -d)"
trap 'rm -rf "$GEN"' EXIT
{
  echo '{'
  echo "  \"extends\": \"$HERE/tsconfig.check.json\","
  echo '  "files": ['
  for i in "${!entries[@]}"; do
    comma=','
    [ "$i" -eq $((${#entries[@]} - 1)) ] && comma=''
    echo "    \"$PWD/${entries[$i]}\"$comma"
  done
  echo '  ]'
  echo '}'
} > "$GEN/tsconfig.json"

echo "Type-checking ${#entries[@]} files with $("$TSC" --version)…"
"$TSC" -p "$GEN/tsconfig.json" \
  && echo "ok   the edge functions type-check. Green here is not green in CI."
