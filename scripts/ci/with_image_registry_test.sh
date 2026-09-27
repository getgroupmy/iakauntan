#!/usr/bin/env bash
# `with_image_registry.sh`'s own assertions.
#
#   bash scripts/ci/with_image_registry_test.sh
#
# The whole argument for that script is one property: **its worst case is
# what CI does today**, so it cannot regress the image pull however wrong
# the authenticated attempt turns out to be. A property nobody checks is
# a claim, and the two previous changes at this spot were claims.
#
# No docker and no network: the command under test is a shell function
# that reports which registry it was handed.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
under_test="$here/with_image_registry.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fails=0
check() {
  local what="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "ok   $what"
  else
    echo "FAIL $what: wanted [$want], got [$got]"
    fails=$((fails + 1))
  fi
}

# A stand-in for the CLI: records the registry it saw, and exits with
# whatever the registry's name is mapped to in $tmp/verdict.
cat > "$tmp/fake" <<'FAKE'
#!/usr/bin/env bash
echo "$SUPABASE_INTERNAL_IMAGE_REGISTRY" >> "$SEEN"
if grep -qx "$SUPABASE_INTERNAL_IMAGE_REGISTRY" "$FAILS_ON" 2>/dev/null; then
  exit 7
fi
exit 0
FAKE
chmod +x "$tmp/fake"

run() {
  : > "$tmp/seen"
  printf '%s\n' "$@" > "$tmp/fails_on"
  SEEN="$tmp/seen" FAILS_ON="$tmp/fails_on" \
    IMAGE_REGISTRY_PRIMARY=ghcr.io \
    IMAGE_REGISTRY_FALLBACK=public.ecr.aws \
    "$under_test" "$tmp/fake" 2>/dev/null
  echo "$?" > "$tmp/status"
}

# 1. The primary answers: one attempt, and the fallback is never touched.
run ''
check 'the primary answering exits 0' '0' "$(cat "$tmp/status")"
check 'and asks ghcr.io once, and nothing else' 'ghcr.io' "$(cat "$tmp/seen")"

# 2. The primary refuses: the fallback rescues it, and the exit is 0.
#    THIS IS THE NON-REGRESSION PROPERTY -- today's registry still runs.
run 'ghcr.io'
check 'a refused primary still exits 0' '0' "$(cat "$tmp/status")"
check 'having tried ghcr.io then public.ecr.aws' \
  'ghcr.io
public.ecr.aws' "$(cat "$tmp/seen")"

# 3. Both refuse: the failure stands, with the FALLBACK's status, and it
#    is not swallowed. A wrapper that turned this green would be worse
#    than no wrapper -- `retry.sh` says the same thing about itself.
run 'ghcr.io' 'public.ecr.aws'
check 'both refusing fails' '7' "$(cat "$tmp/status")"
check 'having tried both' \
  'ghcr.io
public.ecr.aws' "$(cat "$tmp/seen")"

# 4. Nothing to run is a usage error, not a silent success.
: > "$tmp/seen"
SEEN="$tmp/seen" FAILS_ON="$tmp/fails_on" "$under_test" >/dev/null 2>&1
check 'no command is exit 2' '2' "$?"

# 5. Primary and fallback the same: one attempt, not two identical ones.
: > "$tmp/seen"
printf 'ghcr.io\n' > "$tmp/fails_on"
SEEN="$tmp/seen" FAILS_ON="$tmp/fails_on" \
  IMAGE_REGISTRY_PRIMARY=ghcr.io IMAGE_REGISTRY_FALLBACK=ghcr.io \
  "$under_test" "$tmp/fake" 2>/dev/null
check 'one registry configured twice fails once' '7' "$?"
check 'and is asked once' 'ghcr.io' "$(cat "$tmp/seen")"

# 6. The command's own arguments survive being wrapped, including a
#    `bash -c` payload, which is how the database job starts the stack.
: > "$tmp/seen"
: > "$tmp/fails_on"
SEEN="$tmp/seen" FAILS_ON="$tmp/fails_on" \
  "$under_test" bash -c 'echo "$SUPABASE_INTERNAL_IMAGE_REGISTRY" >> "$SEEN"' \
  >/dev/null 2>&1
check 'a bash -c payload sees the registry too' 'ghcr.io' "$(cat "$tmp/seen")"

echo
if [ "$fails" -ne 0 ]; then
  echo "$fails assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
