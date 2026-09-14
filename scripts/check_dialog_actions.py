#!/usr/bin/env python3
"""A widget that needs a Flex, in a slot that is not one.

    python3 scripts/check_dialog_actions.py

`Spacer` and `Expanded` ask their parent for a share of the remaining
space. A parent that is not a `Flex` cannot answer, and Flutter throws
at LAYOUT time -- not at compile time, not at analysis time.

`AlertDialog.actions` is the trap, because it reads exactly like a
`Row`. It is not: the actions are laid out by an `OverflowBar`, which
wraps them onto separate lines when they do not fit and has no notion of
flex at all.

## Why this is a script and not a lesson

It shipped. One `const Spacer()` between two dialog buttons, added to
put Cancel at the far end, and the whole dialog came up as a featureless
grey rectangle on the live site.

Grey is the point. In a debug build a layout error is the red screen
everybody recognises. In a RELEASE build `ErrorWidget.builder` draws a
plain grey box sized to whatever space it was given -- no text, no
stack, nothing to search for. The person looking at it cannot tell a
broken dialog from a slow one.

And none of the four gates could see it: `flutter analyze` is happy
because the types are right, the widget tests never pump this dialog,
and a release web build compiles it without complaint. The same shape
as the CSP and the captcha-token guards -- something only a browser
finds out, and only in front of somebody.

## What is checked

Inside an `actions:` list -- `AlertDialog`, `SimpleDialog`,
`CupertinoAlertDialog`, anything using that argument name -- a bare
`Spacer(` or `Expanded(` at the list's own bracket depth.

Not checked: a `Spacer` nested inside a `Row` that is itself an action.
That one has a Flex parent and is fine, which is why the depth matters
rather than the mere presence of the word.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIB = ROOT / 'app' / 'lib'

# `actions: [` and `actions: <Widget>[` both occur.
OPEN = re.compile(r'\bactions:\s*(?:<[^>]+>\s*)?\[')
BAD = re.compile(r'\b(Spacer|Expanded)\s*\(')


LINE_COMMENT = re.compile(r'//[^\n]*')
BLOCK_COMMENT = re.compile(r'/\*.*?\*/', re.S)


def without_comments(src: str) -> str:
    """Blank the comments, keeping every byte in place.

    Replaced with spaces rather than removed so line numbers and offsets
    still point at the real file. Found by this script reporting its own
    explanation of the bug as an instance of it.
    """
    def blank(m: re.Match) -> str:
        return ''.join(' ' if c != '\n' else '\n' for c in m.group(0))
    return BLOCK_COMMENT.sub(blank, LINE_COMMENT.sub(blank, src))


def offenders(src: str, path: Path):
    src = without_comments(src)
    out = []
    for m in OPEN.finditer(src):
        depth, i = 1, m.end()
        while i < len(src) and depth > 0:
            ch = src[i]
            if ch in '([{':
                depth += 1
            elif ch in ')]}':
                depth -= 1
                if depth == 0:
                    break
            elif depth == 1:
                # Only at the list's own level. A Spacer inside a Row
                # that is itself an action has a Flex parent and is
                # correct.
                b = BAD.match(src, i)
                if b:
                    line = src.count('\n', 0, i) + 1
                    out.append((line, b.group(1)))
            i += 1
    return out


def main() -> int:
    found = []
    for path in sorted(LIB.rglob('*.dart')):
        for line, what in offenders(path.read_text(), path):
            found.append((path.relative_to(ROOT), line, what))

    if found:
        print(f'FAIL: {len(found)} widget(s) asking for flex where there is '
              f'none.')
        print()
        print("`actions:` is laid out by an OverflowBar, not a Row. A Spacer")
        print('or an Expanded there throws at layout, and a release build')
        print('draws that as a featureless grey rectangle with no message.')
        print()
        for path, line, what in found:
            print(f'  {path}:{line}  {what}(...)')
        print()
        print('Drop it, or wrap the actions in a Row of your own.')
        return 1

    print('ok   no dialog action asks for a flex its parent cannot give')
    return 0


if __name__ == '__main__':
    sys.exit(main())
