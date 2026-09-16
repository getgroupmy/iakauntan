#!/usr/bin/env python3
"""Refuse a list row that cannot fit on a phone, from either end.

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

## And the same row from the other end

The rule above asks whether the TRAILING leaves room for the words. It
says nothing about what those words are, and that is the gap that let
three overflows ship: two on `receipts_screen.dart` and one on
`document_list_screen.dart`, where every line of every list lost its
status chip off the right edge on a phone.

The shape is always the same. A `title:` that is a `Row` of
`Text(number)`, a gap and a `StatusChip` CANNOT SHRINK -- a Row lays
its children out at their natural size and overflows the rest -- while
the box it is given shrinks to whatever the trailing left.

## An `Expanded` is not a get-out, and this check said it was

The first version of this rule skipped any title Row containing an
`Expanded` or a `Flexible`, on the reasoning that such a Row can
shrink. It can -- but only down to the width of its INFLEXIBLE
children, and if those alone do not fit it overflows exactly as before.

`exchange_rates_screen.dart` is the counter-example, and it was found
by rendering the screen rather than by this script: a title of
`SizedBox(width: 56)`, an `Expanded` name, and `1 USD = 4.2500 MYR`,
against a trailing "Override" button. The `Expanded` collapsed to
nothing and the row still went 68 pixels off a 412px phone, while this
check passed it on the strength of that `Expanded`.

So what is measured is the inflexible children only. A Row whose
children are all flexible measures zero and passes, which is correct;
one with a fixed `SizedBox` and a fixed label is measured on those.

`Wrap` is the fix, not an ellipsis: the thing being truncated would be
the document number, which is what somebody came to the list to read.

THE ESTIMATE IS DELIBERATELY ROUGH, at both ends. It is not trying to
lay out text; it is trying to notice a row whose two ends together want
more than a phone has. The numbers below are Material's own metrics
rounded to something a reader can check.
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

# A `leading:` -- a checkbox, an avatar, an icon -- comes off the front
# before the title sees anything. The widest of them is a Checkbox at
# its 48px tap target plus the gap ListTile puts after it.
LEADING = 56.0

# `StatusChip(..., compact: true)` is 6px of padding each side around a
# word like "outstanding" in a small style. Measured at the longest
# status this app has.
CHIP = 78.0

# One `${...}` in a title. A document number, a person's name, a unit
# number: eight characters is generous for the short ones and far too
# little for a name, which is exactly why a title holding one should
# not be a rigid Row in the first place.
INTERPOLATION = 64.0

# A bare `Icon` in a title -- the e-Invoice mark, a lock, a warning.
ICON_GLYPH = 24.0

BUTTON = re.compile(
    r"\b(TextButton|OutlinedButton|FilledButton|ElevatedButton)"
    r"(?:\.icon|\.tonal|\.tonalIcon)?\(")
ICON = re.compile(r"\bIconButton\(")
MONEY_WIDGET = re.compile(r"\bMoney\(")
LABEL = re.compile(r"(?:child|label):\s*(?:const\s+)?Text\(\s*'([^']*)'")

# A row that has been made narrow-aware says so, and says it where the
# next person will read it.
EXEMPT = re.compile(r"narrow-ok", re.IGNORECASE)

# Every tile whose title gets what the trailing did not take.
TILE = re.compile(
    r"\b(ListTile|ExpansionTile|CheckboxListTile|SwitchListTile"
    r"|RadioListTile)\(")

# A child of a title Row that yields when the box is small. One of
# these anywhere in the Row is the whole difference: 49 titles here
# have one and none of them can overflow.
FLEX = re.compile(r"\b(Expanded|Flexible|Spacer)\(")

TEXT_WIDGET = re.compile(r"\bText\(")
CHIP_WIDGET = re.compile(r"\b(StatusChip|Chip|Badge)\(")
ICON_WIDGET = re.compile(r"\bIcon\(")
GAP = re.compile(r"\bSizedBox\(width:\s*(?:Space\.(\w+)|([\d.]+))")

# `Space` in the app's theme, for the gaps a title Row puts between its
# pieces.
SPACE = {'xs': 4, 'sm': 8, 'md': 16, 'lg': 24, 'xl': 32}


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


def text_width(expr: str) -> float:
    """Roughly what one `Text(...)` will ask for.

    A literal is counted by its characters. An interpolation is counted
    at [INTERPOLATION] each, which is generous for a document number
    and nowhere near enough for a person's name -- and a title holding
    a name should not be a rigid Row at all, which is the finding
    rather than a shortcoming of the estimate.
    """
    inner = balanced(expr, expr.index('(')) if '(' in expr else expr
    holes = len(re.findall(r"\$\{|\$\w", inner))
    literal = sum(len(m) for m in re.findall(r"'([^']*)'", inner))
    # The `${` and the text inside it are already counted as a hole.
    literal = max(0, literal - holes * 2)
    return holes * INTERPOLATION + literal * CHAR


def flex_spans(expr: str) -> list[tuple[int, int]]:
    """Where the `Expanded`/`Flexible` children of this Row sit.

    Anything inside one of these yields when the box is small, so it
    contributes nothing to what the Row demands.
    """
    spans = []
    for m in FLEX.finditer(expr):
        own = balanced(expr, m.end() - 1)
        spans.append((m.start(), m.start() + len(own) + (m.end() - 1 - m.start())))
    return spans


def outside(spans: list[tuple[int, int]], at: int) -> bool:
    return not any(a <= at < b for a, b in spans)


def title_width(expr: str) -> float:
    """What a title Row asks for that it cannot give back.

    Only the INFLEXIBLE children. An `Expanded` shrinks to nothing when
    the box is small; a `SizedBox(width: 56)` and a `Text('1 USD =
    4.2500 MYR')` do not, and if those two alone exceed the box the Row
    overflows however many `Expanded`s sit beside them.
    """
    spans = flex_spans(expr)
    total = 0.0
    for m in at_depth(expr, TEXT_WIDGET, MAX_DEPTH):
        if outside(spans, m.start()):
            total += text_width(balanced(expr, m.end() - 1))
    for m in at_depth(expr, CHIP_WIDGET, MAX_DEPTH):
        if outside(spans, m.start()):
            total += CHIP
    for m in at_depth(expr, ICON_WIDGET, MAX_DEPTH):
        if outside(spans, m.start()):
            total += ICON_GLYPH
    for gap in GAP.finditer(expr):
        if not outside(spans, gap.start()):
            continue
        total += SPACE.get(gap.group(1), 0) if gap.group(1) else float(
            gap.group(2))
    return total


def slot(expr: str, name: str) -> str | None:
    """The bracketed value of `name:` directly inside this tile."""
    for m in at_depth(expr, re.compile(rf"\b{name}:\s*"), 2):
        rest = expr[m.end():]
        if '(' not in rest[:40]:
            return None
        return balanced(expr, m.end() + rest.index('('))
    return None


def scan_titles(path: str, source: str) -> list[str]:
    """Tiles whose title cannot shrink into what the trailing left."""
    problems = []
    for m in TILE.finditer(source):
        expr = balanced(source, m.end() - 1)
        head = source[max(0, m.start() - 400):m.start()]
        if EXEMPT.search(head) or EXEMPT.search(expr):
            continue

        # Only a Row can fail this way. A bare Text is given a box and
        # ellipsises inside it; a Wrap moves the chip to a second line.
        start = expr.find('title:')
        if start == -1:
            continue
        if not expr[start + len('title:'):].lstrip().startswith('Row('):
            continue
        title = balanced(expr, expr.index('Row(', start) + 3)

        trailing = slot(expr, 'trailing')
        taken = TILE_PADDING
        taken += width_of(trailing) if trailing else 0.0
        if slot(expr, 'leading') is not None:
            taken += LEADING

        wants = title_width(title)
        room = PHONE - taken
        if wants > room:
            line = source[:m.start()].count('\n') + 1
            problems.append(
                f'{os.path.relpath(path, ROOT)}:{line}: a title Row wants '
                f'~{wants:.0f}px and the trailing and leading leave ~'
                f'{room:.0f}px on a {PHONE}px phone. Only the INFLEXIBLE '
                f'children are counted -- an Expanded gives its space back '
                f'and these do not -- so the last of them goes off the right '
                f'edge. Use a Wrap, or give the widest child a Flexible and '
                f'an ellipsis -- or mark the row narrow-ok and say why.')
    return problems


def scan(path: str, source: str) -> list[str]:
    problems = []
    for m in re.finditer(r"\btrailing:\s*", source):
        rest = source[m.end():]
        # A conditional trailing is still a trailing. This used to
        # require the value to START with `Row(`, `Wrap(` or a private
        # widget, which skipped every `pending ? Row(...) : Row(...)` --
        # and `claims_screen.dart` puts Money, "Reject" and "Approve" in
        # exactly that shape. The arithmetic below is what decides; a
        # bare Icon or a single button measures under the threshold and
        # is not reported.
        if '(' not in rest[:80]:
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
                source = fh.read()
            problems += scan(path, source)
            problems += scan_titles(path, source)

    if problems:
        print('Rows that cannot fit on a phone:\n')
        for p in problems:
            print(f'  {p}')
        print(f'\n{len(problems)} row(s). See the header of this script.')
        return 1

    print('Every list row leaves room for its own words, at both ends.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
