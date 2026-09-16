#!/usr/bin/env python3
"""A missing asset must 404, not come back as the app's HTML.

`deploy/vercel-output-config.json` ends with a single-page-app
fallback: anything the filesystem handler did not serve is rewritten to
`/index.html`. That is right for a route -- `/hr/people/3f2a...` is not
a file and never will be, and the app is what should answer it.

It is wrong for an ASSET, and wrong in a way that is hard to read from
the far end. A request for a font, a script or a `.wasm` that is not in
the bundle comes back as `200 OK` with `text/html` in it, so the
browser does not report a missing file -- it reports a CORRUPT one. The
font decoder says the WOFF2 is invalid, the WebAssembly loader says the
magic word is wrong, and the actual fault, that the file was never
deployed, appears nowhere in the message.

So the config carries a rule, between the filesystem handler and the
fallback, that answers `404` for any path with a file extension on it.
This checks the rule is still there and still in that order, because
all three routes look interchangeable in a diff and they are not:

  * before `handle: filesystem` it would 404 every real asset in the
    bundle, which is the entire app;
  * after the fallback it is unreachable and nothing happens.

Only the middle position does anything, and only the middle position is
accepted here.
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIG = ROOT / 'deploy' / 'vercel-output-config.json'

# What has to be refused, whatever else the rule grows to cover. Each of
# these is a file type a browser parses rather than displays, which is
# what turns "not deployed" into "corrupt".
MUST_COVER = ['woff2', 'woff', 'ttf', 'otf', 'js', 'wasm', 'json', 'png']


def main() -> int:
    routes = json.loads(CONFIG.read_text())['routes']

    fs = next((i for i, r in enumerate(routes)
               if r.get('handle') == 'filesystem'), None)
    spa = next((i for i, r in enumerate(routes)
                if r.get('dest') == '/index.html'), None)
    if fs is None or spa is None:
        print('no filesystem handler or no single-page fallback; '
              'this check no longer describes the config', file=sys.stderr)
        return 1

    guards = [r for r in routes[fs + 1:spa]
              if r.get('status') == 404 and 'src' in r]
    if not guards:
        print('a missing asset would be served the app\'s HTML with a 200.',
              file=sys.stderr)
        print('Add a 404 rule for extension paths between the filesystem '
              'handler and the /index.html fallback.', file=sys.stderr)
        return 1

    missing = []
    for ext in MUST_COVER:
        probe = f'/assets/whatever-was-never-deployed.{ext}'
        if not any(re.search(g['src'], probe) for g in guards):
            missing.append(ext)
    if missing:
        print('the 404 rule does not cover: ' + ', '.join(missing),
              file=sys.stderr)
        print('A missing file of that type would decode as a corrupt one.',
              file=sys.stderr)
        return 1

    # And it must not swallow a real route. Deep links carry no
    # extension, and a rule that 404s one of these is a page of the
    # product that has stopped existing.
    for path in ['/', '/sign-in', '/hr/people/3f2a17c0-0000-4000-8000-000000000000',
                 '/documents', '/corp/entities/12']:
        if any(re.search(g['src'], path) for g in guards):
            print(f'the 404 rule would also refuse {path}, which is a route',
                  file=sys.stderr)
            return 1

    print('a missing asset gets a 404; a deep link still gets the app')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
