#!/usr/bin/env python3
"""Every screen is CONSTRUCTED by at least one test.

    python3 scripts/check_screens_built.py

Not covered. Not asserted about. Constructed — somebody, somewhere,
calls `ThingScreen(...)` in a test and the widget tree is built. That
is a low bar and it is the bar nothing was enforcing.

## Why this exists

Five screens were written in one stretch — the tax computation, the
estimate, the calendar, Form B and Form P — with a full set of tests
underneath them. Every one of those tests was on the MODELS. Nothing
anywhere called any of the five constructors, so nothing knew whether
they built at all.

They did. That is luck rather than evidence, and the same stretch had
already spent the evidence: sixteen tests passed over a report button
that threw on every tap, because nothing put it where the real app
puts it. `docs/widget-tests.md` lists ten ways a green suite covers a
broken screen and this is the plainest of them — the screen is never
run.

A model test cannot catch a screen that throws in `build`, reads a
field nobody set, or puts a `Positioned` somewhere a `Stack` is not.
Only building it can.

## What counts

Any file under `app/test` that names the class followed by `(`. That
is deliberately crude: it does not care whether the test asserts
anything useful, because a gate that tried to judge that would be
judging taste. It cares that the constructor is reached.

Comments are stripped before looking, so a screen mentioned in prose
does not count as built — which is the one way the crude version
would otherwise lie.

## The exemptions ARE a backlog, and say so

Unlike `check_async_skeletons.py`, where the seven exemptions share a
reason and are a decision, these thirty-eight are simply screens
nobody has got to yet. They are listed so the gate can refuse the
thirty-ninth, and the number should go down. An entry whose screen has
since been built is refused, for the reason `check_loading_spinners.py`
gives: a list of what is missing that nobody revisits is how
`docs/gaps-against-autocount.md` came to be wrong about four of its
own entries.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / 'app'

# Screens nobody has written a build test for yet. A BACKLOG, not a
# decision -- see the docstring. The value is the file, so a reader can
# go straight to it.
EXEMPT: dict[str, str] = {
    'FilingScreen': 'lib/src/features/financials/filing_screen.dart',
    'HrSetupScreen': 'lib/src/features/hr/hr_setup_screen.dart',
    'PayrollRunScreen': 'lib/src/features/hr/payroll_screen.dart',
    'PayrollScreen': 'lib/src/features/hr/payroll_screen.dart',
    'ScalesScreen': 'lib/src/features/pos/scales_screen.dart',
    'StallsScreen': 'lib/src/features/pos/stalls_screen.dart',
    'TicketScreen': 'lib/src/features/ticketing/ticket_screen.dart',
    # Private, so no test outside its own library can name it at all.
    # Listed rather than skipped so the count is honest about them.
    '_PreviewScreen': 'lib/src/features/admin/landing_cms.dart',
    '_RequestAccessScreen': 'lib/src/features/hr/payroll_screen.dart',
}

_LINE_COMMENT = re.compile(r'//.*')
_BLOCK_COMMENT = re.compile(r'/\*.*?\*/', re.S)


def strip_comments(source: str) -> str:
    """Comments do not build anything.

    A screen named in a doc comment -- which happens constantly in this
    codebase, because the comments explain what they are about -- would
    otherwise read as a screen somebody had tested.
    """
    return _LINE_COMMENT.sub('', _BLOCK_COMMENT.sub('', source))


def screens() -> dict[str, str]:
    found: dict[str, str] = {}
    for path in sorted((APP / 'lib' / 'src' / 'features').rglob('*.dart')):
        body = strip_comments(path.read_text())
        for match in re.finditer(r'class\s+(\w*Screen)\s+extends', body):
            found[match.group(1)] = str(path.relative_to(APP))
    return found


def built() -> set[str]:
    names: set[str] = set()
    for path in sorted((APP / 'test').rglob('*.dart')):
        body = strip_comments(path.read_text())
        for match in re.finditer(r'\b(\w*Screen)\s*\(', body):
            names.add(match.group(1))
    return names


def main() -> int:
    all_screens = screens()
    constructed = built()
    problems: list[str] = []

    unbuilt = {n: p for n, p in all_screens.items() if n not in constructed}

    for name, path in sorted(unbuilt.items()):
        if name not in EXEMPT:
            problems.append(
                f'  {path}\n'
                f'    {name} is never constructed by a test, so nothing '
                f'knows it builds.\n'
                f'    Write one that puts it in a MaterialApp and pumps '
                f'it, or add it to\n'
                f'    EXEMPT in this script with the file beside it.'
            )

    # An exemption for a screen that is built now, or has been renamed
    # away, is a line that stopped meaning anything.
    for name in sorted(EXEMPT):
        if name not in all_screens:
            problems.append(
                f'  {EXEMPT[name]}\n'
                f'    {name} is exempted here and no longer exists. '
                f'Remove the entry.'
            )
        elif name in constructed:
            problems.append(
                f'  {EXEMPT[name]}\n'
                f'    {name} is exempted here and IS built by a test now. '
                f'Remove the entry.'
            )

    if problems:
        print('Screens that nothing builds:\n')
        print('\n\n'.join(problems))
        print(
            f'\n{len(all_screens)} screens, '
            f'{len(all_screens) - len(unbuilt)} built by a test, '
            f'{len(EXEMPT)} exempted.'
        )
        return 1

    print(
        f'All {len(all_screens)} screens are constructed by a test, '
        f'or named as a backlog ({len(EXEMPT)}).'
    )
    return 0


if __name__ == '__main__':
    sys.exit(main())
