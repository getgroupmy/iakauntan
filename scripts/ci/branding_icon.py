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

page = (payload or {}).get("page") if isinstance(payload, dict) else None
url = (page or {}).get("app_icon_url") if isinstance(page, dict) else None
print(url if isinstance(url, str) else "")
