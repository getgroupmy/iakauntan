#!/usr/bin/env python3
"""Every `AsyncView` has made the choice between bones and a circle.

    python3 scripts/check_async_skeletons.py

`core/skeletons.dart` argues where a skeleton is honest and
`core/page_waiting.dart` argues the opposite case, and both are right
about the screens they are about. `AsyncView` is where the argument is
settled one screen at a time: pass `skeleton:` and the screen outlines
what is coming, pass `loading:` and it draws whatever you chose
instead, pass neither and it falls back to the circle.

The fallback is the problem this gate is about. It is silent. A new
screen gets the circle by doing nothing, which is exactly how the last
thirty-seven arrived -- not by anybody deciding a circle was right for
them, but by the question never being asked. `check_loading_spinners.py`
catches a spinner written out by hand; nothing caught a spinner nobody
wrote.

So: an `AsyncView` must pass `skeleton:`, or pass `loading:`, or be
named below with the reason the circle is the right answer there. The
third is a real answer and several screens give it -- what is refused
is giving no answer at all.

## The exemptions, and why they are not a backlog

Seven, and they have one shape between them: a lookup whose whole job
is to decide WHICH surface to show. Bones cannot outline a branch. A
till waiting on its registers is about to draw a till, or an empty
state, or the offline surface, and a skeleton of any one of them is a
claim about which -- wrong two times in three, and wrong in the
direction that looks like content that vanished.

The landing preview is the other kind, and `core/page_waiting.dart`
made the argument first: an operator-edited page whose layout the
payload decides. Guessing it is a guess in fainter grey.

An exemption whose screen no longer has a bare `AsyncView` is refused
too, for the reason `check_loading_spinners.py` gives: a list of what
is missing that nobody revisits is how `docs/gaps-against-autocount.md`
came to be wrong about four of its own entries.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIB = ROOT / 'app' / 'lib'

# The class itself lives here, so its constructor and its own `build`
# are not call sites. Every other file under `app/lib` is.
DEFINITION = 'src/core/widgets.dart'

# "path::the value: argument" -> why the circle is the right answer.
#
# Keyed on the value expression rather than a line number so the entry
# survives the file being edited above it, and reads as what it is: the
# screen, and the thing it is waiting for.
EXEMPT: dict[str, str] = {
    'src/features/admin/landing_cms.dart::preview':
        'The landing page as a visitor sees it, rendered from the '
        'operator-edited payload. core/page_waiting.dart argues this '
        'case: how many bullets, whether there is a panel at all and '
        'what the headline says are all decided by what is arriving, '
        'so an outline is a guess and a wrong guess is the same '
        'flicker in fainter grey.',
    'src/features/admin/platform_console_screen.dart::isAdmin':
        'A permission, not a payload. What follows is either the lock '
        'notice or whichever console section was picked -- and that '
        'section draws its own skeleton. Outlining here would be an '
        'outline of a page this widget has not chosen yet.',
    'src/features/pos/diary_screen.dart::registers':
        'The register lookup that decides whether there is a diary to '
        'draw at all. Either the day sheet (which has its own '
        'skeleton) or the no-tills empty state.',
    'src/features/pos/floor_plan_screen.dart::registers':
        'The same lookup ahead of the floor plan, and the same branch: '
        'either the plan or the no-tills empty state. The plan itself '
        'would be the worst of the four to outline in any case -- it '
        'is tables at the positions somebody dragged them to, so its '
        'layout is the payload, and bones in a grid would say the room '
        'is laid out in rows.',
    'src/features/pos/kiosk_board_screen.dart::registers':
        'Same lookup again, ahead of the board -- which has its own '
        'skeleton once a register is settled on.',
    'src/features/pos/till_screen.dart::registers':
        'The widest branch of the four. A till waiting on its '
        'registers is about to draw the till, the no-tills empty '
        'state, or the offline surface, which share almost nothing. '
        'The panes inside the till outline themselves.',
    'src/features/pos/till_screen.dart::shift':
        'Whether the drawer is open. A closed drawer is the normal '
        'condition of a till before the shop opens and draws a card '
        'inviting somebody to open it; an open one draws the sale. '
        'Not two shapes of the same thing.',
}


def blanked(src: str) -> str:
    """The source with comments and string bodies turned into spaces.

    Same length, so every offset still points where it did. Lifted from
    `check_loading_spinners.py`, which needed it for the same reason:
    without it a bracket inside a string throws the depth count off, and
    `// pass skeleton: here` in a comment reads as passing one. Both
    appear in this repository, and the second is in this gate's own
    error message.
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
            while i < n and not (src[i] == '*' and i + 1 < n
                                 and src[i + 1] == '/'):
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


def _argument(blank: str, src: str, start: int) -> str:
    """One named argument's text, from `start` to its own comma.

    To the next comma AT THE DEPTH IT STARTED, because reading to the
    next comma full stop would stop at the first comma inside the
    widget being passed -- which is a few characters into most of them.
    """
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
    return src[start:i]


def _after_type_args(blank: str, i: int) -> int | None:
    """The index of the `(` that opens an `AsyncView` argument list.

    `i` is just past the name. What may sit between there and the paren
    is a type argument list, and the only safe way past it is to count
    the angle brackets: `<List<Map<String, dynamic>>>` closes three
    times and a reader that stops at the first `>` lands in the middle
    of it. Returns None where this `AsyncView` is not a call at all --
    a doc comment reference, or the `State<AsyncView<T>>` in its own
    declaration.
    """
    n = len(blank)
    while i < n and blank[i].isspace():
        i += 1
    if i < n and blank[i] == '<':
        depth = 0
        while i < n:
            if blank[i] == '<':
                depth += 1
            elif blank[i] == '>':
                depth -= 1
                if depth == 0:
                    i += 1
                    break
            i += 1
        while i < n and blank[i].isspace():
            i += 1
    return i if i < n and blank[i] == '(' else None


def call_sites(src: str):
    """Every `AsyncView(...)` in a file, as (line, value expr, args).

    `AsyncView<Foo>(` counts and so does `AsyncView(`; the type
    argument is noise here. It is skipped by balancing the angle
    brackets rather than by a pattern, because the pattern that reads
    `<[^>]*>` stops at the first `>` -- and the commonest type argument
    in this app is `AsyncView<List<Map<String, dynamic>>>`, which has
    three of them in a row. The first version of this gate used that
    pattern and was blind to five call sites; what noticed was its own
    refusal of the five exemptions that then matched nothing. The argument list is read by balancing
    brackets from the opening paren, which is what makes a nested
    `AsyncView` inside another one's `builder:` come out as its own
    site -- the pipeline screen has exactly that, and both halves of it
    needed answering separately.
    """
    blank = blanked(src)
    for match in re.finditer(r'\bAsyncView\b', blank):
        open_paren = _after_type_args(blank, match.end())
        if open_paren is None:
            continue
        depth, i, n = 0, open_paren, len(blank)
        while i < n:
            if blank[i] == '(':
                depth += 1
            elif blank[i] == ')':
                depth -= 1
                if depth == 0:
                    break
            i += 1
        args = blank[open_paren:i]
        value = ''
        found = re.search(r'\bvalue:\s*', args)
        if found:
            value = _argument(args, args, found.end()).strip()
        yield src.count('\n', 0, match.start()) + 1, value, args


def main() -> int:
    problems: list[str] = []
    seen: set[str] = set()

    for path in sorted(LIB.rglob('*.dart')):
        rel = str(path.relative_to(LIB))
        if rel == DEFINITION:
            continue
        src = path.read_text()
        if 'AsyncView' not in src:
            continue
        for line, value, args in call_sites(src):
            if re.search(r'\bskeleton:', args) or re.search(r'\bloading:',
                                                            args):
                continue
            key = f'{rel}::{value}'
            seen.add(key)
            if key in EXEMPT:
                continue
            problems.append(
                f'{rel}:{line}: this AsyncView (value: {value or "?"}) '
                f'passes neither `skeleton:` nor `loading:`, so it falls '
                f'back to a circle without anybody having chosen one. '
                f'Pass a shape from core/skeletons.dart where the layout '
                f'is already decided, pass `loading:` where something '
                f'else belongs there, or add "{key}" to EXEMPT in '
                f'scripts/check_async_skeletons.py with the reason.')

    for key, reason in sorted(EXEMPT.items()):
        if key not in seen:
            problems.append(
                f'{key}: exempted ("{reason[:60]}...") but there is no '
                f'longer an AsyncView there waiting on that value with no '
                f'skeleton. Remove the exemption rather than leaving it to '
                f'read as a gap somebody still has to close.')

    if problems:
        for p in problems:
            print(f'::error::{p}')
        return 1

    total = sum(
        1
        for path in LIB.rglob('*.dart')
        if str(path.relative_to(LIB)) != DEFINITION
        for _ in call_sites(path.read_text()))
    print(f'every AsyncView has chosen ({total} call sites, '
          f'{len(EXEMPT)} keeping the circle on purpose)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
