#!/usr/bin/env python3
"""Refuse a list row whose trailing widget cannot fit on a phone.

    python3 scripts/check_narrow_rows.py

`ListTile` hands its `trailing` widget the width it asks for and gives
the title and subtitle whatever is left. Nothing warns when that is
nothing: the text is not overflowing its box, it has been GIVEN a box
two pixels wide, and it wraps the only way it can — one letter per
line, a tall column of single characters, pushing the next row most of
a screen down.

That is not a hypothetical. It shipped, on the items list, where a row
carried a price and four text buttons — Stock card, Prices, Variants,
Packs — wanting about 600 logical pixels on a screen that gives about
440. The service row above it looked perfect, because a service offers
one button, which is exactly why nobody caught it.

Nothing else catches this either. The analyzer sees a valid widget
tree. The widget tests pass, because a test surface is 800 wide by
default and everything fits. Flutter's own overflow banner never
appears, because nothing overflows: the text was allotted two pixels
and used them.

So: read every `trailing:` in the app, add up what its buttons and
money will ask for, and fail if that leaves too little for the words
beside it — unless the row says, in a comment, that it has been made
narrow-aware.

THE ESTIMATE IS DELIBERATELY ROUGH. It is not trying to lay out text;
it is trying to notice a row that has three or four labelled buttons in
its trailing, which is the shape that fails. The numbers below are
Material's own metrics rounded to something a reader can check.
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
APP = os.path.join(ROOT, 'app', 'lib')

# A phone's shortest sensible width, and what a ListTile takes off it
# before the title sees any. 360 is the narrowest Android in common use;
# the horizontal padding is this app's `Space.lg` on each side.
PHONE = 360
TILE_PADDING = 48

# What is left for the title and subtitle after the trailing. Below
# this, a code like "ITM-130 · Stock · 29 SET on hand" has nowhere to
# go. It is not a rendering rule, it is the line past which a row stops
# being readable.
MIN_TEXT = 120

# And the rule that does most of the work. THE FAILURE IS LABELLED
# BUTTONS, not trailing widgets in general.
#
# An icon button is 40 pixels and carries no text; a row of two of them
# is the correct compact affordance on a phone and flagging it teaches
# people to ignore this script. A price is unavoidable and belongs at
# the end of the row. What does not fit is WORDS in the trailing: three
# of them, or two long ones, and the title has nowhere left to go.
#
# 160 is about two medium labels or three short ones — measured against
# the rows this app already has, where it flags the three that are
# genuinely broken and none of the ones that are merely tight.
MAX_LABELLED = 160

# Material's text button: 8px per character at the default label size,
# plus 16px of padding each side, and a 64px minimum.
CHAR = 8.0
BUTTON_PADDING = 32.0
BUTTON_MIN = 64.0

# `Money` renders something like "RM 1,450.00" in a bold body style.
MONEY = 110.0

# An icon button is 40 and does not carry a label, so a row of them is
# not the failure this looks for. Counted, because four of them still
# add up.
ICON_BUTTON = 40.0

BUTTON = re.compile(
    r"\b(TextButton|OutlinedButton|FilledButton|ElevatedButton)"
    r"(?:\.icon|\.tonal|\.tonalIcon)?\(")
ICON = re.compile(r"\bIconButton\(")
MONEY_WIDGET = re.compile(r"\bMoney\(")
LABEL = re.compile(r"(?:child|label):\s*(?:const\s+)?Text\(\s*'([^']*)'")

# A row that has been made narrow-aware says so, and says it where the
# next person will read it.
EXEMPT = re.compile(r"narrow-ok", re.IGNORECASE)


def balanced(source: str, open_at: int) -> str:
    """The text of the bracketed expression starting at `open_at`.

    Brackets only, and DELIBERATELY no attempt to skip string literals.
    An earlier version skipped them and desynchronised on Dart's string
    interpolation — `'${row['id']}'` has a quote inside a quote, so the
    skip ran to the next quote in the file and the matcher read hundreds
    of lines past the widget. It reported a two-button row as wanting
    872 pixels, which is how a checker teaches people to ignore it.

    Braces inside interpolation are balanced, so counting them is right.
    A bracket inside a LABEL would not be, and none of this app has one.
    """
    depth = 0
    for i in range(open_at, len(source)):
        c = source[i]
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
            if depth == 0:
                return source[open_at:i + 1]
    return source[open_at:]


# How deep inside the trailing a widget may sit and still be PART of
# the row. `Row(children: [Button(` is two brackets; an `if` and a
# spread add one or two more. Anything deeper is inside a callback —
# the confirm dialog an icon opens, with its own "Keep it" and "Remove"
# — and belongs to a different screen entirely.
#
# Counting those was the first thing this script got wrong: it read a
# category row of two icon buttons as having 168 pixels of words on it,
# because the delete handler opens an AlertDialog three levels down.
MAX_DEPTH = 4


def at_depth(expr: str, pattern: re.Pattern[str], limit: int):
    """Matches of `pattern` no deeper than `limit` brackets in."""
    depth = 0
    out = []
    i = 0
    while i < len(expr):
        c = expr[i]
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
        m = pattern.match(expr, i)
        if m and depth <= limit:
            out.append(m)
        i += 1
    return out


def labelled_width(expr: str) -> float:
    """What the buttons WITH WORDS ON THEM, in this row, ask for."""
    total = 0.0
    for m in at_depth(expr, BUTTON, MAX_DEPTH):
        own = balanced(expr, m.end() - 1)
        label = LABEL.search(own)
        text = label.group(1) if label else ''
        total += max(BUTTON_MIN, len(text) * CHAR + BUTTON_PADDING)
    return total


def width_of(expr: str) -> float:
    """Roughly what this trailing will ask for, all of it.

    Each button is measured from ITS OWN label, found inside its own
    bracketed expression. Collecting every label in the row and pairing
    them positionally was wrong the moment anything else in the row —
    a `Chip`, a `Tooltip` — carried a `Text` of its own.
    """
    return (labelled_width(expr)
            + ICON_BUTTON * len(at_depth(expr, ICON, MAX_DEPTH))
            + MONEY * len(at_depth(expr, MONEY_WIDGET, MAX_DEPTH)))


def scan(path: str, source: str) -> list[str]:
    problems = []
    for m in re.finditer(r"\btrailing:\s*", source):
        rest = source[m.end():]
        # Only a composite trailing can be wide. A bare Icon or one
        # button is what `trailing` is for.
        if not rest.startswith(('Row(', 'Wrap(', '_')):
            continue
        start = m.end() + rest.index('(')
        expr = balanced(source, start)

        # The widget itself may be narrow-aware, in which case the
        # marker is on the class rather than here.
        head = source[max(0, m.start() - 400):m.start()]
        if EXEMPT.search(head) or EXEMPT.search(expr):
            continue
        if rest.startswith('_'):
            name = re.match(r"(_\w+)", rest).group(1)
            klass = re.search(rf"class {name}\b.*?(?=\nclass |\Z)", source,
                              re.S)
            if klass and EXEMPT.search(klass.group(0)):
                continue

        wide = width_of(expr)
        words = labelled_width(expr)
        left = PHONE - TILE_PADDING - wide
        if words > MAX_LABELLED or left < MIN_TEXT:
            line = source[:m.start()].count('\n') + 1
            problems.append(
                f'{os.path.relpath(path, ROOT)}:{line}: a trailing with '
                f'~{words:.0f}px of labelled buttons, ~{wide:.0f}px in all, '
                f'leaves ~{left:.0f}px for the title on a {PHONE}px phone. '
                f'Use `RowActions`, which turns them into one menu below a '
                f'breakpoint — or mark the row narrow-ok and say why.')
    return problems


def main() -> int:
    problems = []
    for root, _, files in os.walk(APP):
        for f in files:
            if not f.endswith('.dart'):
                continue
            path = os.path.join(root, f)
            with open(path) as fh:
                problems += scan(path, fh.read())

    if problems:
        print('Rows that cannot fit on a phone:\n')
        for p in problems:
            print(f'  {p}')
        print(f'\n{len(problems)} row(s). See the header of this script.')
        return 1

    print('Every list row leaves room for its own words.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
