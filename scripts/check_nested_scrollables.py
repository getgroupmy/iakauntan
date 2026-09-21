#!/usr/bin/env python3
"""Refuse a scroll view nested inside another on the same axis.

    python3 scripts/check_nested_scrollables.py

A viewport expands to fill its container along the axis it scrolls. So
a horizontal scroll view inside another horizontal scroll view is
offered unbounded width, and Flutter does not lay it out badly -- it
ASSERTS, in `performResize`, before anything is drawn:

    Horizontal viewport was given unbounded width.

The screen throws on every build, and in a release build it renders a
grey error box where the widget was. There is no partial success and
no gradual degradation, which is what makes this worth a gate rather
than a review comment.

It shipped. `leads_screen.dart` put a horizontally scrolling `ListView`
of filter chips inside a `FilterBar`, which IS a horizontal
`SingleChildScrollView` -- so the leads filter bar threw on every
single build and had never once drawn. Nothing caught it: the analyzer
sees a valid tree, and no test had ever put `LeadsScreen` on a surface.
That is two gates missing the same defect from different sides, which
is why both now exist.

The vertical direction is the same fault and is included: a `ListView`
inside a `SingleChildScrollView` is the single most common way a
Flutter screen throws, and it throws for exactly this reason.

## What counts as a scroll view

The widgets that create a viewport: `ListView`, `GridView`,
`SingleChildScrollView`, `CustomScrollView`, `PageView`,
`ReorderableListView`, `NestedScrollView`, `TabBarView` -- plus the
wrappers in this repository that are one underneath, which are named
here because a caller cannot see through them. `FilterBar` is the
whole reason for that list.

## What does not count

A scroll view nested on the OTHER axis is fine and ordinary -- a
vertical list of horizontally scrolling rows is a carousel, not a bug.
The axis is read from `scrollDirection:`, defaulting to vertical, which
is Flutter's own default.

`shrinkWrap: true` also makes it fine in the vertical case: the inner
list measures its children instead of expanding. It does NOT help the
horizontal case if the outer is horizontal, because the outer still
offers unbounded width -- but Flutter accepts a shrink-wrapped inner
viewport under an unbounded constraint, so it is allowed here. A
`SizedBox`/`Container` with an explicit extent on the shared axis is
the other escape, and is honoured for the same reason: the constraint
is bounded again by the time the inner viewport sees it.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

APP = Path(__file__).resolve().parent.parent / 'app'

#: Widgets that create a viewport, and the axis they scroll when
#: `scrollDirection:` is not given.
SCROLLERS: dict[str, str] = {
    'ListView': 'vertical',
    'GridView': 'vertical',
    'SingleChildScrollView': 'vertical',
    'CustomScrollView': 'vertical',
    'PageView': 'horizontal',
    'ReorderableListView': 'vertical',
    'NestedScrollView': 'vertical',
    'TabBarView': 'horizontal',
}

#: This repository's own wrappers, which are a scroll view underneath.
#: A caller reading `FilterBar(child: ...)` has no way to know, so the
#: knowledge lives here.
WRAPPERS: dict[str, str] = {
    'FilterBar': 'horizontal',
}

_LINE_COMMENT = re.compile(r'//[^\n]*')
_BLOCK_COMMENT = re.compile(r'/\*.*?\*/', re.S)
_STRING = re.compile(r"'(?:\\.|[^'\\\n])*'|\"(?:\\.|[^\"\\\n])*\"")


def blank_out(source: str) -> str:
    """Replace comments and string bodies with spaces of equal length.

    Spaces rather than nothing so every offset in the result is the
    offset in the original, and a line number computed from it is the
    line the reader will open.

    A comment matters here more than usual: this check is ABOUT nested
    scroll views, so the paragraphs explaining the rule -- including the
    ones in this file -- name every widget it looks for.
    """

    def spaces(match: re.Match[str]) -> str:
        return re.sub(r'[^\n]', ' ', match.group(0))

    return _STRING.sub(spaces, _BLOCK_COMMENT.sub(spaces, _LINE_COMMENT.sub(spaces, source)))


def matching(source: str, open_paren: int) -> int:
    """The index just past the `)` that closes the `(` at [open_paren]."""
    depth = 0
    for i in range(open_paren, len(source)):
        if source[i] == '(':
            depth += 1
        elif source[i] == ')':
            depth -= 1
            if depth == 0:
                return i + 1
    return len(source)


def own_arguments(source: str, open_paren: int, end: int) -> str:
    """The call's OWN arguments, with everything nested blanked out.

    The first version read a fixed 400 characters after the `(` and
    called that the arguments, which is wrong the moment a child is
    long enough to reach into the window: a vertical `ListView` holding
    a horizontal one read as horizontal itself, matched its own child,
    and reported the ordinary carousel as a fault. Its own test caught
    it, which is the entire reason gates here have tests.

    Spaces rather than deletion so offsets still line up with [source].
    """
    out: list[str] = []
    depth = 0
    for i in range(open_paren, end):
        char = source[i]
        if char == '(':
            depth += 1
        elif char == ')':
            depth -= 1
        keep = depth == 1 or (depth == 0 and char == ')')
        out.append(char if keep else (char if char == '\n' else ' '))
    return ''.join(out)


def axis_of(head: str, default: str) -> str:
    """The axis a scroll view scrolls, from its own arguments."""
    if 'scrollDirection: Axis.horizontal' in head:
        return 'horizontal'
    if 'scrollDirection: Axis.vertical' in head:
        return 'vertical'
    return default


def bounded(head: str, axis: str) -> bool:
    """Whether this call re-bounds the shared axis for what is inside.

    `shrinkWrap` makes the inner viewport measure rather than expand.
    A fixed `width:`/`height:` on the axis does the same from outside.
    Either way the assertion cannot fire, so neither is a finding.
    """
    if 'shrinkWrap: true' in head:
        return True
    extent = 'width:' if axis == 'horizontal' else 'height:'
    return bool(re.search(rf'\b{extent}\s*\d', head))


def findings() -> list[str]:
    out: list[str] = []
    known = {**SCROLLERS, **WRAPPERS}
    names = '|'.join(sorted(known, key=len, reverse=True))
    call = re.compile(rf'\b({names})\s*\(')

    for path in sorted((APP / 'lib').rglob('*.dart')):
        source = path.read_text()
        code = blank_out(source)

        for match in call.finditer(code):
            name = match.group(1)
            start = match.end() - 1
            end = matching(code, start)
            axis = axis_of(own_arguments(code, start, end), known[name])
            body = code[start:end]

            for inner in call.finditer(body):
                if inner.start() == 0:
                    continue
                inner_name = inner.group(1)
                inner_start = inner.end() - 1
                inner_end = matching(body, inner_start)
                inner_head = own_arguments(body, inner_start, inner_end)
                if axis_of(inner_head, known[inner_name]) != axis:
                    continue
                # Anything between the two that pins the shared axis
                # hands the inner a bounded constraint again.
                between = body[:inner.start()]
                if bounded(between, axis) or bounded(inner_head, axis):
                    continue
                line = source[:match.start()].count('\n') + 1
                inner_line = source[:start + inner.start()].count('\n') + 1
                out.append(
                    f'  {path.relative_to(APP.parent)}:{inner_line}\n'
                    f'    {inner_name} scrolls {axis} inside the {name} '
                    f'at line {line}, which scrolls {axis} too.\n'
                    f'    The inner one is given an unbounded '
                    f'{"width" if axis == "horizontal" else "height"} and '
                    f'throws in performResize,\n'
                    f'    so this never draws. Use a '
                    f'{"Row" if axis == "horizontal" else "Column"} inside '
                    f'the outer scroll view, or give the\n'
                    f'    inner one shrinkWrap: true or a fixed extent.'
                )
                break

    return out


def main() -> int:
    problems = findings()
    if problems:
        print('Scroll views nested on the same axis:\n')
        print('\n\n'.join(problems))
        print(
            f'\n{len(problems)} of them. A viewport expands along the axis '
            f'it scrolls, so one\ninside another on that axis is offered '
            f'infinity and asserts before it draws.'
        )
        return 1
    print('No scroll view is nested inside another on the same axis.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
