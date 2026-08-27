#!/usr/bin/env bash
# Put the platform's own icon, name and colour on the build.
#
# The console's branding tab stores a square source image on
# `landing_page.app_icon_url`, a name on `wordmark` and a colour on
# `brand_colour`. The favicon, the PWA icons, `index.html` and
# `manifest.json` are all files inside the built bundle, so the only
# moment they can change is here, just before `flutter build web` —
# which is why the tab says an upload takes effect on the next deploy
# rather than on save.
#
# The running app repoints the same tags again once it has the payload
# (`lib/src/core/brand_chrome.dart` and `favicon.dart`), so a change in
# the console does not wait for a deploy to reach a visitor. What waits
# for a deploy is what a browser sees *before* the app boots, and what a
# PWA install reads — which is only ever these files.
#
# Reads through `landing_page()`, the same anon-readable function the
# front page uses, so this needs no credential the shipped bundle does
# not already carry.
#
# ## Never fatal, never silent
#
# The icons are decoration; the deploy is the product. A branding upload
# that is the wrong size should cost somebody a second go at the console,
# not a blocked release of an accounting system. So every path exits
# zero.
#
# What it must not do is fail quietly, because "no icon is configured"
# and "I could not ask" produce the same result — the shipped icons —
# and only one of them is fine. They are reported as different things.
#
# A script rather than an inline `run:` block because it embeds Python,
# and a heredoc inside a YAML block scalar is how you get a workflow that
# parses as something else. It is also how this gets tested at all.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

: "${SUPABASE_URL:=https://ewwcgtnniwqndrzukksm.supabase.co}"
: "${SUPABASE_ANON_KEY:=sb_publishable_QcTtzLYCECOYRVOt4erFtg_k-YaQWHA}"

note() {
  echo "$1"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '\n%s\n' "$1" >> "$GITHUB_STEP_SUMMARY" || true
  fi
}

body="$(curl -sS --max-time 30 \
          -X POST "$SUPABASE_URL/rest/v1/rpc/landing_page" \
          -H "apikey: $SUPABASE_ANON_KEY" \
          -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
          -H 'Content-Type: application/json' \
          -d '{}')"
status=$?

if [ "$status" -ne 0 ] || [ -z "$body" ]; then
  echo "::warning::Could not read the branding, so this build keeps the icons it shipped with. That is not the same as no icon having been set."
  note "The branding could not be read; the shipped icons were kept."
  exit 0
fi

icon="$(printf '%s' "$body" | "$root/scripts/ci/branding_icon.py")"

cd "$root/app" || exit 0

# The name and the colour, onto the two files a browser reads before any
# Dart runs. Given the same payload, and just as unable to fail the
# deploy: it prints what it did and exits zero either way.
printf '%s' "$body" | dart run tool/brand_chrome.dart

if [ -z "$icon" ]; then
  note "No app icon is set in the console; the shipped icons were kept."
  exit 0
fi

dart run tool/make_icons.dart "$icon"
