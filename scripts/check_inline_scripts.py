#!/usr/bin/env python3
"""Refuse an inline <script> the Content-Security-Policy will not run.

    python3 scripts/check_inline_scripts.py

The policy in `deploy/vercel-output-config.json` says

    script-src 'self' 'wasm-unsafe-eval' https://challenges.cloudflare.com

with no `'unsafe-inline'` and no hashes. So a `<script>` with a body
rather than a `src` is refused by the browser on EVERY load, on every
browser, and the only sign is a console entry nobody is looking at.

That is not hypothetical. The service-worker rescue in
`web/index.html` -- the block that unregisters the stale worker keeping
old code alive on installed phones -- was inline for its whole life. It
never ran once in production. The symptom was people on Android Chrome
still seeing a version that had been replaced weeks earlier, which
looks like a deployment problem and is not one: the fix was deployed,
correct, and unreachable.

Nothing else catches this. The Dart analyzer does not read `web/`, the
widget tests do not load `index.html`, CI serves no page, and a local
`flutter run` uses no CSP at all -- so it works perfectly right up
until it is deployed.

## The fix is a file, not a hash

`script-src` also accepts `'sha256-...'` of the script's exact bytes.
That would work today and fail the first time somebody corrects a
comment inside the script, with the same invisible symptom. A file
under `'self'` cannot drift from its policy.

## What this reads

The policy itself, rather than a copy of it: if `script-src` ever gains
`'unsafe-inline'` this check stands down on its own instead of becoming
a rule nobody remembers the reason for.

Inline event-handler attributes -- `onclick=`, `onload=` -- are the
same refusal by the same directive, so they are reported too.
"""

from __future__ import annotations

import json
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
CONFIG = os.path.join(ROOT, 'deploy', 'vercel-output-config.json')
WEB = os.path.join(ROOT, 'app', 'web')

# `<script ...>` whose attributes carry no `src`. Non-greedy to the
# first `>`, so a body containing `>` cannot confuse it.
SCRIPT = re.compile(r'<script(?P<attrs>[^>]*)>', re.I)
SRC = re.compile(r'\bsrc\s*=', re.I)

# `onclick="..."` and friends, which `script-src` refuses for the same
# reason. `on` followed by letters, then `=`, inside a tag.
HANDLER = re.compile(r'<[^>!][^>]*?\s(on[a-z]+)\s*=', re.I | re.S)


def script_src() -> str | None:
    """The `script-src` directive of the deployed policy, or None."""
    try:
        with open(CONFIG) as handle:
            config = json.load(handle)
    except (OSError, ValueError):
        return None
    for route in config.get('routes', []):
        headers = route.get('headers') or {}
        policy = headers.get('Content-Security-Policy')
        if not policy:
            continue
        for directive in policy.split(';'):
            directive = directive.strip()
            if directive.startswith('script-src'):
                return directive
    return None


def main() -> int:
    directive = script_src()
    if directive is None:
        print('No Content-Security-Policy with a script-src found in')
        print(f'  {os.path.relpath(CONFIG, ROOT)}')
        print('so this check cannot say what the browser will run.')
        return 1

    if "'unsafe-inline'" in directive:
        print("script-src allows 'unsafe-inline'; nothing to refuse.")
        return 0

    problems = []
    for root, _, files in os.walk(WEB):
        for name in sorted(files):
            if not name.endswith('.html'):
                continue
            path = os.path.join(root, name)
            with open(path) as handle:
                source = handle.read()
            rel = os.path.relpath(path, ROOT)

            for m in SCRIPT.finditer(source):
                if SRC.search(m.group('attrs')):
                    continue
                line = source[: m.start()].count('\n') + 1
                problems.append(
                    f'{rel}:{line}: an inline <script> the deployed CSP '
                    f'will refuse')

            for m in HANDLER.finditer(source):
                line = source[: m.start()].count('\n') + 1
                problems.append(
                    f'{rel}:{line}: an inline {m.group(1)}= handler, refused '
                    f'by the same directive')

    if problems:
        print('Scripts the browser will not run:\n')
        for p in problems:
            print(f'  {p}')
        print()
        print(f'The deployed policy is: {directive}')
        print()
        print('Move the body into a file under app/web/ and load it with')
        print('<script src="...">. Do NOT add a hash to the policy: it is a')
        print('hash of the exact bytes, so the next edit to the script')
        print('re-breaks it with no visible symptom. See the header of this')
        print('script for what that cost last time.')
        return 1

    print('every script in app/web is one the CSP will run')
    return 0


if __name__ == '__main__':
    sys.exit(main())
