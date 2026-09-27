#!/usr/bin/env python3
"""A date formatter handed a JSON string, which is a grey rectangle.

    python3 scripts/check_date_arguments.py

`Fmt.date`, `Fmt.dateTime` and `Fmt.longDate` take a `DateTime?`. A
`timestamptz` or a `date` column arrives from PostgREST as a JSON
STRING, and the rows this app reads are `Map<String, dynamic>` -- so

    Fmt.dateTime(provider['key_set_at'])

COMPILES. `dynamic` accepts anything, the analyzer says nothing, and at
runtime it throws

    type 'String' is not a subtype of type 'DateTime?'

A throw during `build` is replaced by an `ErrorWidget`, and a release
web build draws an `ErrorWidget` as A PLAIN GREY RECTANGLE filling
whatever space it was given. No message, no red, nothing in the console
a person would find.

It was reported as "why when key added it goes grey", and the reason it
had never been seen is that both instances sat behind `if (hasKey ...)`
-- code that only runs once somebody has done the thing.

## What this looks for

A call to one of the formatters whose argument is a SUBSCRIPT of
something -- `row['x']`, `s['y']`, `widget.data['z']` -- with no
`DateTime.parse` or `DateTime.tryParse` around it. That is the shape of
the bug and it is a shape, not a type: the analyzer cannot help because
`dynamic` is exactly what it is told to accept.

Not a general "did you parse this" check. A local already typed
`DateTime?` is fine and common, and flagging it would make the gate
noise somebody learns to ignore.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, 'app', 'lib')

# `Fmt.dateTime(` ... up to the matching close, non-greedy to the first
# `)` that is not inside a nested call. Balanced scanning below rather
# than a regex, because `Fmt.dateTime(DateTime.tryParse('$x'))` has two.
CALL = re.compile(r'\bFmt\.(date|dateTime|longDate|time)\s*\(')

# The argument is a map read BY STRING KEY, and nothing else: it ends
# with `['...']`. That is the shape a JSON row is read with.
#
# Two things this deliberately does NOT match, both of which the first
# draft did:
#
#   * `list[i].requestedAt` — a LIST index and then a typed field. The
#     field is already a `DateTime?` and the analyzer is watching it.
#   * anything that merely starts with a subscript. The bug is the
#     value that comes OUT of a JSON map, not the act of indexing.
SUBSCRIPT = re.compile(
    r"""^[A-Za-z_][\w.]*            # row, s, widget.data
        (?:\[[^\]]*\])*             # any earlier subscripts
        \[\s*['"][^'"]*['"]\s*\]$   # ...ending in a STRING key
    """,
    re.VERBOSE,
)

SAFE = ('DateTime.parse', 'DateTime.tryParse')


def strip_comments(source: str) -> str:
    """Blank out `//` comments, keeping line numbers.

    Not cosmetic. The two sites this gate was written for now carry doc
    comments QUOTING the broken call, so a scan of the raw text reports
    the fix as the fault -- which is a gate that cries wolf on the
    commit that fixed the thing.

    Line comments only. A `//` inside a string is rare here and the
    worst it costs is a missed call, which the next one of these will
    catch anyway; blanking a URL out of a string literal would be the
    more expensive mistake.
    """
    out = []
    for line in source.split('\n'):
        stripped = line.lstrip()
        out.append('' if stripped.startswith('//') else line)
    return '\n'.join(out)


def argument_of(source: str, open_paren: int) -> str:
    """The text between the parens of a call whose `(` is at [open_paren]."""
    depth = 0
    for i in range(open_paren, len(source)):
        c = source[i]
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return source[open_paren + 1:i]
    return ''


def offenders(root: str = LIB) -> list[str]:
    found: list[str] = []
    for dirpath, _dirs, files in os.walk(root):
        for name in sorted(files):
            if not name.endswith('.dart'):
                continue
            path = os.path.join(dirpath, name)
            with open(path, encoding='utf-8') as fh:
                source = strip_comments(fh.read())
            for m in CALL.finditer(source):
                arg = argument_of(source, m.end() - 1).strip()
                if not arg or any(s in arg for s in SAFE):
                    continue
                if not SUBSCRIPT.match(arg):
                    continue
                line = source.count('\n', 0, m.start()) + 1
                found.append(
                    f'{os.path.relpath(path, ROOT)}:{line}: '
                    f'Fmt.{m.group(1)}({arg}) is handed a map value. A '
                    f'timestamptz arrives as a JSON string and this throws '
                    f'at build, which a release web build draws as a plain '
                    f'grey rectangle. Wrap it in DateTime.tryParse.')
    return found


def main() -> int:
    bad = offenders()
    if bad:
        for b in bad:
            print(f'::error::{b}')
        return 1
    print('every date formatter is handed a date, not a row value')
    return 0


if __name__ == '__main__':
    sys.exit(main())
