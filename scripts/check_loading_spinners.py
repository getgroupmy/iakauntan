#!/usr/bin/env python3
"""No screen answers "your rows are on the way" with a circle.

    python3 scripts/check_loading_spinners.py

`app/lib/src/core/skeletons.dart` sets out when an outline is honest
and when it is not, and `AsyncView` is where that choice is made: a
screen that passes `skeleton:` gets bones, and one that does not gets
the circle, deliberately, because the pages whose LAYOUT the payload
decides are right to keep it.

What this refuses is the third case -- a screen that calls `.when()`
itself and puts a `CircularProgressIndicator` in the `loading:` arm.
That is the same decision made somewhere nothing documents it, on a
screen whose shape usually IS known, and it is how the last three
survived a hundred and thirty conversions: they were never on a list.

  * `TodoCard` on the dashboard -- five rows of a checkbox and two
    short lines, outlined as a spinning circle in the middle of a card.
  * `_ClockCard` on My HR -- an icon, two lines and two buttons.
  * `_AppointDialog` in the practice screen -- a picker and a dropdown.

## What is still allowed, and why the rule is this narrow

A `LinearProgressIndicator` in a `loading:` arm is not this. It is a
two-pixel bar at the top of a card section that already has its
heading drawn, which says "more is coming here" without claiming a
shape -- forty-five of them, and none is the thing this is about.

A spinner inside a BUTTON is not this either. It means "your press is
being dealt with", which is about time passing rather than about a
shape, and `skeletons.dart` says so in as many words.

And the circle itself is not banned: `AsyncView` still draws one for
every screen that leaves `skeleton:` null. This only says that the
choice has to be made THERE, where the reasoning is written down, and
not a hundred and thirty times in a `loading:` arm.

## The exemptions

There are none. A screen that genuinely needs a raw `.when()` AND a
circle can be named in `EXEMPT` below with the reason -- and an
exemption that no longer matches anything in its file is refused too,
because a list of what is missing that nobody revisits is how
`docs/gaps-against-autocount.md` came to be wrong about four of its own
entries.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIB = ROOT / 'app' / 'lib'

# path (relative to app/lib) -> why the circle is the right answer there.
EXEMPT: dict[str, str] = {}

SPINNER = 'CircularProgressIndicator'


def blanked(src: str) -> str:
    """The source with comments and string bodies turned into spaces.

    Same length, so every offset still points where it did. Without
    this a bracket inside a string throws the depth count off and a
    mention of the spinner in a comment reads as a use of it -- and
    both appear in this repository.
    """
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            while i < n and src[i] != '\n':
                out[i] = ' '
                i += 1
        elif c == '/' and i + 1 < n and src[i + 1] == '*':
            while i < n and not (src[i] == '*' and i + 1 < n and src[i + 1] == '/'):
                out[i] = ' '
                i += 1
            for _ in range(min(2, n - i)):
                out[i] = ' '
                i += 1
        elif c in "'\"":
            quote = c
            triple = src[i:i + 3] == quote * 3
            end = quote * 3 if triple else quote
            i += len(end)
            while i < n:
                if src[i] == '\\':
                    out[i] = ' '
                    i += 1
                    if i < n:
                        out[i] = ' '
                        i += 1
                    continue
                if src[i:i + len(end)] == end:
                    i += len(end)
                    break
                out[i] = ' '
                i += 1
        else:
            i += 1
    return ''.join(out)


def loading_arms(src: str):
    """Every `loading:` argument, as (line number, its text).

    The argument runs to the next comma at the depth it started at.
    Reading to the next comma FULL STOP would end at the first comma
    inside the widget it builds, which is the second character of most
    of them.
    """
    blank = blanked(src)
    for match in re.finditer(r'\bloading:\s*', blank):
        start = match.end()
        depth, i, n = 0, start, len(blank)
        while i < n:
            c = blank[i]
            if c in '([{':
                depth += 1
            elif c in ')]}':
                if depth == 0:
                    break
                depth -= 1
            elif c == ',' and depth == 0:
                break
            i += 1
        yield src.count('\n', 0, match.start()) + 1, src[start:i]


def main() -> int:
    offenders: list[tuple[str, int]] = []
    seen_files: set[str] = set()

    for path in sorted(LIB.rglob('*.dart')):
        src = path.read_text()
        if SPINNER not in src:
            continue
        rel = str(path.relative_to(LIB))
        for line, arm in loading_arms(src):
            if SPINNER in arm:
                seen_files.add(rel)
                if rel not in EXEMPT:
                    offenders.append((rel, line))

    problems = []
    for rel, line in offenders:
        problems.append(
            f'{rel}:{line}: a `loading:` arm draws a {SPINNER}. Pass a '
            f'skeleton from core/skeletons.dart, or let AsyncView decide '
            f'by leaving `skeleton:` off -- see the reasoning there.')

    for rel, reason in sorted(EXEMPT.items()):
        if rel not in seen_files:
            problems.append(
                f'{rel}: exempted ("{reason}") but nothing there draws a '
                f'{SPINNER} in a `loading:` arm any more. Remove the '
                f'exemption rather than leaving it to read as a gap.')

    if problems:
        for p in problems:
            print(f'::error::{p}')
        return 1

    print(f'no `loading:` arm in app/lib draws a {SPINNER} '
          f'({len(EXEMPT)} exemption(s))')
    return 0


if __name__ == '__main__':
    sys.exit(main())
