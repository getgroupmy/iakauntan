#!/usr/bin/env python3
"""Print the app icon URL from a `landing_page()` response, or nothing.

Its own file so `branding_icon.sh` stays a shell script and the workflow
stays YAML. Prints an empty line for every shape that is not an icon —
an unpublished page comes back as `{"page": null}`, and a page written
before 0314 has no such key at all.
"""
import json
import sys

try:
    payload = json.load(sys.stdin)
except Exception:
    payload = None

def field(container, key):
    return container.get(key) if isinstance(container, dict) else None


# `brand` since 0316, and it is not gated on the page being published —
# an operator who has not put a marketing site up still gets their own
# favicon. `page` is the fallback for a project whose database predates
# that migration.
url = field(field(payload, "brand"), "app_icon_url") or \
      field(field(payload, "page"), "app_icon_url")
print(url if isinstance(url, str) else "")
