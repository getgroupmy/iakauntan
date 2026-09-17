#!/usr/bin/env python3
"""A script the app loads that the CSP will not let it load.

Cloudflare Turnstile reached production unable to draw. `captcha_web
.dart` appends a `<script src="https://challenges.cloudflare.com/...">`
to the head; the Content-Security-Policy in
`deploy/vercel-output-config.json` said `script-src 'self'`. The browser
refused the script, the widget never rendered, and the sign-in form went
on demanding a token from a box that was not on the screen. Nobody could
sign in with a password, and nothing anywhere said why -- a blocked
script is a console message on somebody else's machine.

    python3 scripts/check_csp_allows.py

## Why a script and not care

This is the second failure of exactly this shape in one day. The other
was `passkeys_web` calling a JS global that was never loaded. Both
compile. Both pass `flutter analyze`, every widget test, and a release
build. Both are invisible until a browser somewhere refuses something,
and by then it is in front of a user.

The gates this repository already has all ask "does the code do what it
says". This one asks "will the browser let it" -- which is a different
question, and the answer lives in a JSON file that nothing else reads.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / 'deploy' / 'vercel-output-config.json'
DART = ROOT / 'app' / 'lib'

# A host the app reaches for, the directives it needs, and why. Kept
# here rather than inferred, because a host that SHOULD be allowed and a
# host that merely appears in a string are not the same thing, and the
# difference is the whole point of a policy.
REQUIRED = [
    ('https://challenges.cloudflare.com',
     ('script-src', 'frame-src', 'connect-src'),
     'Cloudflare Turnstile. The script draws the widget, the widget is '
     'an iframe, and it posts back -- so all three, and a missing '
     'frame-src falls back to default-src and blocks it silently.'),
    ('https://fonts.gstatic.com',
     ('font-src',),
     'The web fonts.'),
]

# `..src = 'https://...'` in Dart: something being loaded, not linked.
SRC = re.compile(r"""\.\.?src\s*=\s*['"](https://[^/'"]+)""")


def directives(csp: str) -> dict:
    out = {}
    for part in csp.split(';'):
        part = part.strip()
        if not part:
            continue
        name, _, rest = part.partition(' ')
        out[name] = rest.split()
    return out


def allows(d: dict, directive: str, host: str) -> bool:
    # An absent directive falls back to default-src. That fallback is
    # what made the Turnstile iframe fail without anybody editing a
    # policy, so it is modelled rather than assumed away.
    sources = d.get(directive, d.get('default-src', []))
    return host in sources or '*' in sources


def main() -> int:
    config = json.loads(CONFIG.read_text())
    csp = None
    for route in config.get('routes', []):
        csp = route.get('headers', {}).get('Content-Security-Policy', csp)
        if csp:
            break
    if not csp:
        print(f'FAIL: no Content-Security-Policy in {CONFIG.name}.')
        return 1

    d = directives(csp)
    bad = []

    for host, needed, why in REQUIRED:
        for directive in needed:
            if not allows(d, directive, host):
                bad.append((host, directive, why))

    # And anything the Dart loads that nobody declared above.
    declared = {h for h, _, _ in REQUIRED}
    for path in sorted(DART.rglob('*.dart')):
        for m in SRC.finditer(path.read_text()):
            host = m.group(1)
            if host in declared:
                continue
            bad.append((host, 'script-src',
                        f'loaded by {path.relative_to(ROOT)} and on no '
                        f'list here -- add it to REQUIRED with the '
                        f'directives it needs, and to the policy'))

    if bad:
        print(f'FAIL: {len(bad)} thing(s) the app loads that the policy '
              f'does not allow.')
        print()
        print('A blocked script is not an error the app can see. It is a')
        print('feature that silently does not work, in front of a user.')
        print()
        for host, directive, why in bad:
            print(f'  {directive}: {host}')
            print(f'    {why}')
            print()
        print(f'The policy lives in {CONFIG.relative_to(ROOT)}.')
        return 1

    n = sum(len(x[1]) for x in REQUIRED)
    print(f'ok   {n} host/directive pair(s) the app needs, every one of '
          f'them allowed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
