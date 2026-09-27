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
#: Screens nobody has written a build test for yet.
#:
#: **EMPTY.** Thirty-eight when this gate went in, and every one of them
#: was work somebody had not got to. Keep it that way: a screen added
#: without a test that builds it belongs here with a reason, and "nobody
#: got to it" is what the other thirty-eight said.
EXEMPT: dict[str, str] = {}

#: Private screens, built THROUGH the widget that shows them.
#:
#: A private class cannot be named by a test in another library, so the
#: name-matching above can never see these two however much effort goes
#: in. Listing them as a backlog said something false — that nothing
#: builds them — when in both cases something does, by the same door the
#: app uses.
#:
#: So each one names the test and the PUBLIC host it is reached through,
#: and the check below refuses an entry whose test file has gone or no
#: longer mentions that host. A prose claim nobody revisits is how
#: `docs/gaps-against-autocount.md` came to be wrong about four of its
#: own entries; this one is checked.
#:
#: screen -> (source file, test file, the public widget that builds it)
COVERED_VIA: dict[str, tuple[str, str, str]] = {
    # Pushed by the Preview button on the landing CMS tab — which was
    # itself built by nothing, being neither a `*Screen` nor a dialog
    # opener, and so fell between both gates.
    '_PreviewScreen': (
        'lib/src/features/admin/landing_cms.dart',
        'test/landing_cms_preview_test.dart',
        'LandingCmsTab',
    ),
    # What an auditor with no live grant sees instead of an empty list
    # they cannot explain. Same route, different screen.
    '_RequestAccessScreen': (
        'lib/src/features/hr/payroll_screen.dart',
        'test/screens_build_batch_test.dart',
        'PayrollScreen',
    ),
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
        if name not in EXEMPT and name not in COVERED_VIA:
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

    # And a private screen covered through its host: the entry has to
    # still point at a test that still builds that host.
    for name, (source, test, host) in sorted(COVERED_VIA.items()):
        if name not in all_screens:
            problems.append(
                f'  {source}\n'
                f'    {name} is recorded as covered through {host} and no '
                f'longer exists. Remove the entry.'
            )
            continue
        if name in constructed:
            problems.append(
                f'  {source}\n'
                f'    {name} is named by a test directly now, so it does '
                f'not need this entry. Remove it.'
            )
            continue
        path = APP / test
        if not path.exists():
            problems.append(
                f'  {source}\n'
                f'    {name} is recorded as covered by {test}, which is '
                f'not there.'
            )
            continue
        # WORD BOUNDARIES, not `in`. A substring check passed a test
        # that had renamed the host to `LandingCmsTabX` — which builds
        # nothing — because the old name is still inside the new one.
        # Caught by breaking this check on purpose.
        if not re.search(rf'\b{re.escape(host)}\b',
                         strip_comments(path.read_text())):
            problems.append(
                f'  {source}\n'
                f'    {name} is recorded as covered through {host} by '
                f'{test},\n'
                f'    and that test no longer builds {host}. The private '
                f'screen behind it\n'
                f'    is unbuilt again, silently, which is the whole '
                f'failure this gate is for.'
            )

    if problems:
        print('Screens that nothing builds:\n')
        print('\n\n'.join(problems))
        print(
            f'\n{len(all_screens)} screens, '
            f'{len(all_screens) - len(unbuilt)} built by a test, '
            f'{len(COVERED_VIA)} through a host, '
            f'{len(EXEMPT)} exempted.'
        )
        return 1

    print(
        f'All {len(all_screens)} screens are constructed by a test '
        f'({len(COVERED_VIA)} of them through the widget that shows them), '
        f'backlog {len(EXEMPT)}.'
    )
    return 0


if __name__ == '__main__':
    sys.exit(main())
