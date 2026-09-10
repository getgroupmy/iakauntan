#!/usr/bin/env python3
"""Refuse an `.order()` that does not say which way.

    python3 scripts/check_order_direction.py

postgrest-dart declares

    PostgrestTransformBuilder<T> order(String column, {bool ascending = false, ...})

so `.order('name')` is name DESC. Not a default anybody guesses from the
call, and not what a single one of the 117 sites that had it meant.

It was reported as a country picker that opened on Viet Nam, the United
States and the United Kingdom, and it was never only the country picker.
Every alphabetical list in the application was reversed: contacts,
items, accounts, departments, states, MSIC codes. Worse than backwards
alphabetical, `sort_order` -- a column whose whole purpose is that
somebody chose the order -- was reversed in twenty-four places, along
with `weekday` (Sunday first, Monday last), `line_no` on a document,
`step_no` in an approval chain, and `min_quantity` on a price break.

None of it fails, none of it logs, and none of it looks broken enough to
report: a list is in an order, and the wrong order reads as an odd one.
It went unnoticed through five hundred migrations.

The Dart analyzer cannot help -- omitting an optional named argument is
legal, which is the whole trap -- and no test catches it, because a test
that asserts three rows come back gets three rows. So the rule is
mechanical and lives here: every `.order()` in the client and in the
edge functions states its direction, and reading the call tells you what
it does.

The same default is in the JS client that the edge functions use, so
both trees are read.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Where PostgREST queries are written. The Flutter client is the one the
# report came from; the edge functions ask the same questions of the
# same API through `@supabase/supabase-js`, whose `order` defaults to
# `ascending: true` -- the opposite -- which is its own reason to say it
# out loud rather than remember which tree you are in.
TREES = (
    ROOT / 'app' / 'lib',
    ROOT / 'supabase' / 'functions',
)

SUFFIXES = ('.dart', '.ts', '.js')

# `.order(` up to its closing bracket. Every call in both trees is on
# one line; a call that is not would be reported as unchecked below
# rather than passing silently.
CALL = re.compile(r"\.order\(([^)]*)\)")
OPENED = re.compile(r"\.order\(")


def offenders():
    """(path, line number, the call) for every order with no direction."""
    out = []
    unreadable = []
    for tree in TREES:
        if not tree.exists():
            continue
        for path in sorted(tree.rglob('*')):
            if path.suffix not in SUFFIXES:
                continue
            rel = path.relative_to(ROOT)
            for n, line in enumerate(path.read_text().splitlines(), 1):
                # A comment explaining the rule is not a call.
                code = line.split('//', 1)[0]
                calls = CALL.findall(code)
                if len(calls) != len(OPENED.findall(code)):
                    unreadable.append((rel, n, line.strip()))
                    continue
                for args in calls:
                    if 'ascending' not in args:
                        out.append((rel, n, f'.order({args})'))
    return out, unreadable


def main():
    out, unreadable = offenders()

    for rel, n, line in unreadable:
        print(f'FAIL: {rel}:{n} has an `.order(` this check cannot read.')
        print(f'  {line}')
        print('  Put the call on one line so its direction can be read.')

    for rel, n, call in out:
        print(f'FAIL: {rel}:{n}  {call}')

    if out:
        print()
        print(f'{len(out)} ordering(s) do not say which direction they mean.')
        print('postgrest-dart defaults `ascending` to FALSE, so an order with')
        print('no direction is Z to A -- and supabase-js defaults it to true,')
        print('so the same call means the opposite in the edge functions.')
        print('Write `ascending: true` or `ascending: false` on every one.')

    if out or unreadable:
        return 1

    print('every ordering says which direction it means')
    return 0


if __name__ == '__main__':
    sys.exit(main())
