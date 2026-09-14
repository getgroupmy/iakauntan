#!/usr/bin/env python3
"""Refuse an edge function that writes its own cross-origin headers.

    python3 scripts/check_edge_cors.py

`_shared/cors.ts` allows `authorization, x-client-info, apikey,
content-type, x-scheduler-secret` on the preflight, honours
`ALLOWED_ORIGINS`, answers OPTIONS, and stamps the headers onto every
response on the way out. `serveFunction` is how a function gets all of
that, and every function used it -- until `ssm-search` shipped with a
three-line `CORS` constant of its own allowing `authorization` and
`content-type`.

supabase-js sends `x-client-info` on every call, and `apikey` when the
client was built with one. So the browser's preflight was refused, and
what reached the screen was

    ClientException: Load failed, uri=.../functions/v1/ssm-search

with no status, no body and nothing in the function's log, because the
request never arrived. Nothing in this repository could see it: `deno
check` type-checks a hand-written header map perfectly happily, the
Deno tests exercise the pure helpers, `check_edge_authorization.py`
asks a different question, and the SQL suite never reaches the wire.
It is only wrong in a browser, which is the one place none of the
gates run.

## What is checked

Every `supabase/functions/<name>/index.ts`:

1. calls `serveFunction`, which is the only route to the shared
   headers; and
2. does not name an `access-control-*` header itself.

The second is the one that matters. A function could call
`serveFunction` and still set its own `Access-Control-Allow-Headers` on
a response -- `serveFunction` overwrites what it knows about, so the
result would be a header that looks deliberate, disagrees with the
shared list, and behaves differently depending on which of the two ran
last.

Underscore directories (`_shared`, `_local_check`) are not functions.
"""
import re
import sys
from pathlib import Path

FUNCTIONS = Path(__file__).resolve().parent.parent / 'supabase' / 'functions'

# Case-insensitive: a header name is case-insensitive on the wire, and
# the version this check was written for spelled them in lower case
# while `_shared/cors.ts` spells them in title case.
OWN_HEADER = re.compile(r'["\']access-control-[a-z-]+["\']', re.IGNORECASE)


def main() -> int:
    problems: list[str] = []
    checked = 0

    for index in sorted(FUNCTIONS.glob('*/index.ts')):
        if index.parent.name.startswith('_'):
            continue
        checked += 1
        source = index.read_text()
        rel = index.relative_to(FUNCTIONS.parent.parent)

        if 'serveFunction' not in source:
            problems.append(
                f'{rel}: does not use serveFunction from _shared/cors.ts, so '
                f'it answers the preflight on its own terms')

        for match in OWN_HEADER.finditer(source):
            line = source.count('\n', 0, match.start()) + 1
            problems.append(
                f'{rel}:{line}: names {match.group(0)} itself. The shared '
                f'headers are in _shared/cors.ts, and a second list is a '
                f'second list to get wrong')

    if problems:
        for p in problems:
            print(f'::error::{p}')
        print(
            '\nA function that sets its own CORS headers is wrong only in a '
            'browser, and only as "Load failed" with no status and no body. '
            'Import serveFunction from ../_shared/cors.ts and delete the '
            'header map.',
            file=sys.stderr)
        return 1

    print(f'ok   {checked} edge functions, all on the shared CORS headers')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
