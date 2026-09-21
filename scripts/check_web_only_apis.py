#!/usr/bin/env python3
"""Refuse a web-only API called on a path a phone can reach.

    python3 scripts/check_web_only_apis.py

Some of Dart's core library is only correct in a browser. It does not
degrade off the web -- it throws -- and the analyser has nothing to say
about it, because the call is perfectly well typed. A web build is
where this app is mostly looked at, so the throw is found on a phone.

## `Uri.base.origin`

    Bad state: Origin is only applicable schemes http and https

`Uri.base` is the page address in a browser and a `file:` URI on
Android, iOS, macOS and Windows. Asking a `file:` URI for its origin
throws, so every unguarded `'${Uri.base.origin}/#/...'` is a crash on
every native run, not a wrong string.

Four of them had shipped: the share dialog, the e-signature link on the
entity screen, the ticket share dialog, and -- worst of the four --
`menu_links_screen.dart`, which called it inside `build`, so the
published-menus list threw on every row and the screen was a column of
grey error boxes on the phone. It was found by putting the screen on a
test surface, where `Uri.base` is also a `file:` URI, which is the same
reason the test catches it and the browser never did.

`shareOrigin()` in `lib/src/core/safe_link.dart` is the answer, and
`kIsWeb ? ... : null` is the other one -- the sign-in screen's four
calls were already written that way, which is how the rule was known
before it was enforced.

Note what is NOT refused: `Uri.base.host`, `Uri.base.path` and the rest
are fine everywhere. A `file:` URI simply has an empty host. Only
`origin` throws.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

APP = Path(__file__).resolve().parent.parent / 'app' / 'lib'

#: Where the guarded version lives, and is therefore allowed.
HOME = 'src/core/safe_link.dart'

#: The call, and what makes it safe on the same line or just above it.
CALL = re.compile(r'Uri\.base\.origin')
GUARD = re.compile(r'\bkIsWeb\b')

#: How far above the call a `kIsWeb` still counts as guarding it.
#: Three, because `emailRedirectTo: kIsWeb\n ? '...'\n : null,` is the
#: shape the sign-in screen already uses and the widest of them spans
#: that much.
LOOK_BACK = 3

_LINE_COMMENT = re.compile(r'//[^\n]*')
_BLOCK_COMMENT = re.compile(r'/\*.*?\*/', re.S)


def blank_out(source: str) -> str:
    """Comments call nothing.

    Spaces rather than nothing, so a line number computed from an
    offset is the line the reader will open. This file's own
    explanation names the API it refuses, repeatedly, and so does
    `safe_link.dart`.
    """

    def spaces(match: re.Match[str]) -> str:
        return re.sub(r'[^\n]', ' ', match.group(0))

    return _BLOCK_COMMENT.sub(spaces, _LINE_COMMENT.sub(spaces, source))


def findings() -> list[str]:
    out: list[str] = []
    for path in sorted(APP.rglob('*.dart')):
        if str(path.relative_to(APP.parent)).replace('\\', '/').endswith(HOME):
            continue
        source = path.read_text()
        code = blank_out(source)
        for match in CALL.finditer(code):
            lines = code.split('\n')
            line_no = code[:match.start()].count('\n') + 1
            # `kIsWeb ? ... : null` is a conditional, so the guard is
            # on this line or on one of the few above it -- the
            # argument it guards is often wrapped over three. Counted
            # in LINES rather than characters, because the first
            # version of this counted newline offsets and got the
            # window a line short, which its own test caught.
            first = max(0, line_no - 1 - LOOK_BACK)
            if GUARD.search('\n'.join(lines[first:line_no])):
                continue
            out.append(
                f'  {path.relative_to(APP.parent.parent)}:{line_no}\n'
                f'    Uri.base.origin throws on every scheme but http and '
                f'https, and on\n'
                f'    Android, iOS, macOS and Windows Uri.base is a file: '
                f'URI. This is a\n'
                f'    crash on a phone, not a wrong string. Use '
                f'shareOrigin() from\n'
                f'    core/safe_link.dart, or guard it with kIsWeb the way '
                f'sign_in_screen does.'
            )
    return out


def main() -> int:
    problems = findings()
    if problems:
        print('Web-only APIs on a path a phone reaches:\n')
        print('\n\n'.join(problems))
        print(f'\n{len(problems)} of them.')
        return 1
    print('No web-only API is called where a phone would reach it.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
