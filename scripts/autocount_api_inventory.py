#!/usr/bin/env python3
"""Pull AutoCount Cloud's API description and print an inventory of it.

Why this exists
---------------
`docs/migrating-from-autocount.md` is written against search-engine
summaries of AutoCount's documentation, because the sandbox that document
was researched in blocks every `*.autocountcloud.com` host at the network
gateway. Planning against summaries is fine. Building against them is not:
field names, enum values and the auth flow all have to be exact.

This script closes that gap from a machine that *can* reach them. It needs
no password — the OpenAPI description is normally served without one, and
if your tenant requires a key, pass a key rather than a login.

Run it, commit `docs/autocount-openapi.json`, and the migration plan can
stop guessing.

Usage
-----
    python3 scripts/autocount_api_inventory.py
    python3 scripts/autocount_api_inventory.py --api-key "$AUTOCOUNT_API_KEY"
    python3 scripts/autocount_api_inventory.py --url https://.../swagger/v1/swagger.json

Nothing is sent anywhere. It reads, prints, and writes one local file.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request

# Swagger UI at /swagger/index.html is a viewer; the description itself is
# one of these. Tried in order because the version segment varies between
# releases.
CANDIDATES = [
    "https://accounting-api.autocountcloud.com/swagger/v1/swagger.json",
    "https://accounting-api.autocountcloud.com/swagger/v1.0/swagger.json",
    "https://accounting-api.autocountcloud.com/swagger/docs/v1",
    "https://accounting-api.autocountcloud.com/openapi.json",
]

OUT = "docs/autocount-openapi.json"


def fetch(url: str, api_key: str | None) -> dict:
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    if api_key:
        # Header name unconfirmed — this is one of the things the
        # description will settle. Both are sent so a tenant that wants
        # either is satisfied, and neither is a credential that can be
        # replayed as a login.
        request.add_header("Authorization", f"Bearer {api_key}")
        request.add_header("X-Api-Key", api_key)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def field_names(schema: dict, spec: dict, depth: int = 0) -> list[str]:
    """Property names of a schema, following one level of $ref."""
    if depth > 2:
        return []
    ref = schema.get("$ref")
    if ref:
        name = ref.rsplit("/", 1)[-1]
        target = spec.get("components", {}).get("schemas", {}).get(name) \
            or spec.get("definitions", {}).get(name)
        return field_names(target, spec, depth + 1) if target else []
    props = schema.get("properties") or {}
    out = []
    for key, value in props.items():
        kind = value.get("type") or value.get("$ref", "").rsplit("/", 1)[-1] or "?"
        enum = value.get("enum")
        out.append(f"{key}: {kind}" + (f" {enum}" if enum else ""))
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", help="Explicit OpenAPI URL")
    parser.add_argument("--api-key", help="API key, if your tenant needs one")
    args = parser.parse_args()

    urls = [args.url] if args.url else CANDIDATES
    spec = None
    for url in urls:
        try:
            spec = fetch(url, args.api_key)
            print(f"# Read {url}\n")
            break
        except (urllib.error.URLError, urllib.error.HTTPError, ValueError) as exc:
            print(f"# {url} -> {exc}", file=sys.stderr)

    if spec is None:
        print(
            "\nCould not read the description from any known URL.\n"
            "Open https://accounting-api.autocountcloud.com/swagger/index.html\n"
            "in a browser, find the .json link under the title, and pass it\n"
            "with --url.",
            file=sys.stderr,
        )
        return 1

    info = spec.get("info", {})
    print(f"## {info.get('title', 'AutoCount API')} {info.get('version', '')}\n")

    security = spec.get("components", {}).get("securitySchemes") \
        or spec.get("securityDefinitions") or {}
    print("## Authentication")
    if security:
        for name, scheme in security.items():
            print(f"- {name}: {json.dumps(scheme)}")
    else:
        print("- none declared in the description")
    print()

    print("## Endpoints")
    paths = spec.get("paths", {})
    for path in sorted(paths):
        for method, op in sorted(paths[path].items()):
            if method.lower() not in {"get", "post", "put", "patch", "delete"}:
                continue
            summary = op.get("summary") or op.get("operationId") or ""
            print(f"- {method.upper():6} {path}  {summary}")

            body = (op.get("requestBody", {})
                      .get("content", {})
                      .get("application/json", {})
                      .get("schema"))
            if body:
                fields = field_names(body, spec)
                if fields:
                    print(f"           body: {', '.join(fields)}")
    print()

    print("## Schemas")
    schemas = spec.get("components", {}).get("schemas") or spec.get("definitions") or {}
    for name in sorted(schemas):
        fields = field_names(schemas[name], spec)
        if fields:
            print(f"- {name}: {', '.join(fields)}")

    with open(OUT, "w", encoding="utf-8") as handle:
        json.dump(spec, handle, indent=2, sort_keys=True)
    print(f"\n# Raw description written to {OUT} — commit it and the "
          f"migration plan can stop guessing.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
