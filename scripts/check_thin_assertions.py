#!/usr/bin/env python3
"""A widget test whose only check is that it did not throw.

    python3 scripts/check_thin_assertions.py

`expect(tester.takeException(), isNull)` and nothing else. It is a real
check -- a thrown exception, a `RenderFlex` overflow, a `setState` during
build all land in the test's pending exception, and `takeException()` is
what collects it -- and it is the WEAKEST one a widget test can make. It
says the screen was built. It says nothing about what the screen says.

That distinction has been expensive here. `dialogs_build_batch2_test.dart`
opened fifty dialogs with that one line, and eighteen of them were fed a
row shape the database never sends: a title that read "What null bills", a
subtitle whose code was the four characters n-u-l-l, a live modifier group
drawn as retired, a filing fixture that was a row from another table
entirely. None of it threw. All of it passed.

So: a CEILING, which may only fall, on how many such bodies there are. Not
a ban -- a ban would be wrong, see the excuses below -- and not a floor,
because the only direction worth allowing is downward.

## What this does NOT prove

That a body with assertions in it asserts anything worth having.
`expect(find.textContaining('x'), findsWidgets)` is not thin by this
measure and pins almost nothing; so does an assertion on a string two
sections of the screen can both produce. This gate catches the bodies that
assert nothing at all, which is the floor of the floor.

## The hole in an excuse list, stated rather than hidden

Nothing here stops somebody adding a thin test and an `ALLOWED` entry in
the same commit. The ceiling does not move and the gate passes. That is the
inherent limit of every excuse list in this directory, and the two things
that narrow it are both small: the self-test refuses an excuse shorter than
twenty characters, so "because" does not pass, and an excuse that stops
being needed is reported as a problem of its own, so the list cannot
quietly accumulate.

What it does buy is that the backlog has a NUMBER on it. 34 unexamined
bodies in one file were invisible until they were counted.

## One level of helper, and why only one

A body with no `expect` in it is not a body with no assertion in it. Seven
tests in `shell_survives_a_failed_provider_test.dart` call
`expectShellStandsUp(tester)`; three in `call_screen_test.dart` call
`allInsideTheStage(tiles(tester), screen)`. Both helpers assert, and a
detector that read only the body reported seventeen findings that were not
findings.

So a call to a function DEFINED IN THE SAME FILE whose own body asserts
counts as an assertion. One level, because that is what the measurement
needed and a transitive walk would be a worse thing to get wrong quietly:
a cycle, or a helper in another file, would have to fail safe, and "fail
safe" for a detector means reporting nothing.
"""

from __future__ import annotations

import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TESTS = ROOT / "app" / "test"
CEILING_FILE = os.path.join(ROOT, "app", "test", "thin_assertion_ceiling")

#: Bodies where "it did not throw" IS the assertion, each with the reason.
#:
#: Keyed `<path under app/>: <test name>`, which is what the json test
#: reporter calls them and what `check_flutter_test_count.py` already
#: keys its skips by.
#:
#: The overflow ones are not a loophole and they were proved rather than
#: argued: an unflexed wide `Row` put inside `NewOrganizationDialog` made
#: `the new-company dialog fits` FAIL, with a comment-only control
#: surviving the same run. A `RenderFlex` overflow becomes the pending
#: exception, so that one line is the whole of the check and it bites.
ALLOWED: dict[str, str] = {
    'test/asset_register_test.dart: '
    'the register totals do not overflow a phone':
        'an overflow test: the framework raises on RenderFlex and '
        '`takeException` is what collects it',
    'test/platform_people_test.dart: the new-company dialog fits':
        'an overflow test, and the one a mutant was run against',
    'test/platform_people_test.dart: '
    'the edit-company dialog fits, with a long name':
        'an overflow test, at the longest name the dialog can be given',
    'test/platform_people_test.dart: the support-access dialog fits':
        'an overflow test, on a dialog whose body is one long org name',
    'test/platform_people_test.dart: the assign-access dialog fits':
        'an overflow test, on the same long name through another dialog',
    'test/platform_people_test.dart: the register of people fits':
        'an overflow test over a LIST rather than a dialog, which is '
        'where an unflexed trailing figure shows',
    'test/platform_people_test.dart: '
    'and so does the record of support sessions':
        'an overflow test over the audit list, whose rows carry a '
        'timestamp and a reason side by side',
    'test/platform_people_test.dart: '
    'and the banner, which is drawn on a phone most of all':
        'an overflow test on the support banner, which is the one widget '
        'that is always on screen while it exists',
    'test/section_header_action_test.dart: '
    'and the header reports no overflow':
        'an overflow test, and the name says so',
    'test/two_factor_test.dart: '
    'and renders without throwing at the size it is drawn':
        'an overflow test, and the name says so',
    'test/two_factor_test.dart: a long account name still fits':
        'an overflow test on the authenticator label, which is built from '
        'an e-mail address and has no length limit',
    'test/entity_types_for_companies_test.dart: '
    'and the dialog opens before the list has arrived':
        'the whole claim is that opening it against an empty list does '
        'not throw, which is what the first version of that screen did',
    'test/xlsx_sample_test.dart: writes the sample workbook when asked':
        'writes a file for a person to open; `check_xlsx.py` is what '
        'reads it back, and it runs in CI beside this',
}

#: `testWidgets(` or `test(`, and nothing else that ends in those letters:
#: `\b` after `_` is not a boundary, so `_test(` does not match.
OPEN = re.compile(r"\b(testWidgets|test)\s*\(")

ASSERT = re.compile(r"\b(expect|expectLater|expectSync|fail)\s*\(")

#: The thin form itself. Written out rather than matched loosely, because
#: `expect(tester.takeException(), isNotNull)` is the opposite claim and a
#: perfectly good assertion.
TAKE = re.compile(r"expect\s*\(\s*tester\.takeException\(\)\s*,\s*isNull\s*\)")

#: A top-level or nested function definition, for the one level of helper
#: resolution. Deliberately loose on the return type: what matters is the
#: NAME and that a brace body follows.
DEF = re.compile(
    r"^(?:[A-Za-z_<>,\s\[\]\?]+\s)?([a-z_][A-Za-z0-9_]*)\s*\([^;]*?\)"
    r"\s*(?:async\s*)?\{",
    re.M,
)


def blanked(src: str) -> str:
    """`src` with every string body and comment turned to spaces.

    Same length as the input, so an offset in one is an offset in the
    other. It exists because a `{` inside a string breaks brace matching
    -- Dart's `${...}` and a JavaScript template literal both -- and
    because a comment NAMING `expect` would otherwise make a thin body
    read as a thick one. Both of those have been got wrong here before.
    """
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "/" and src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
            continue
        if c == "/" and src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, min(j, n)):
                if src[k] != "\n":
                    out[k] = " "
            i = j
            continue
        if c in ('"', "'"):
            triple = src[i:i + 3] in ('"""', "'''")
            quote = src[i:i + 3] if triple else c
            j = i + len(quote)
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src.startswith(quote, j):
                    j += len(quote)
                    break
                j += 1
            for k in range(i, min(j, n)):
                if src[k] != "\n":
                    out[k] = " "
            i = j
            continue
        i += 1
    return "".join(out)


def _matching(blank: str, start: int) -> int:
    """Index of the bracket closing the one at `start`, or -1."""
    depth = 0
    for j in range(start, len(blank)):
        if blank[j] in "([{":
            depth += 1
        elif blank[j] in ")]}":
            depth -= 1
            if depth == 0:
                return j
    return -1


def helpers_that_assert(blank: str) -> set[str]:
    """Names defined in this file whose own body asserts."""
    found: set[str] = set()
    for m in DEF.finditer(blank):
        open_brace = blank.find("{", m.end() - 1)
        if open_brace < 0:
            continue
        close = _matching(blank, open_brace)
        if close < 0:
            continue
        if ASSERT.search(blank[open_brace:close]):
            found.add(m.group(1))
    return found


def name_at(src: str, call_start: int) -> str:
    """The quoted first argument of a `test(`/`testWidgets(` call."""
    head = src[call_start:call_start + 400]
    m = re.search(r"\(\s*(['\"])", head)
    if not m:
        return ""
    k = call_start + m.end() - 1
    quote = src[k]
    e = k + 1
    while e < len(src):
        if src[e] == "\\":
            e += 2
            continue
        if src[e] == quote:
            break
        e += 1
    return src[k + 1:e]


def bodies(src: str):
    """Every test body in this source, as (name, blanked text)."""
    blank = blanked(src)
    for m in OPEN.finditer(blank):
        start = m.end() - 1
        close = _matching(blank, start)
        if close < 0:
            continue
        yield name_at(src, m.start()), blank[start:close + 1]


def key_for(path: pathlib.Path, name: str) -> str:
    """The `<file>: <name>` key, relative to `app/`.

    `relative_to` RAISES for a path outside the tree, and that has been
    written, hit and fixed twice in this directory already
    (`check_self_tests_run.py`, then `check_analyzer_covers_the_app.py` an
    hour later). A path from somewhere else is not a reason to crash --
    the key is a label, so it falls back to the path as given.
    """
    try:
        return "%s: %s" % (path.relative_to(TESTS.parent).as_posix(), name)
    except ValueError:
        return "%s: %s" % (path.as_posix(), name)


def thin_bodies(files=None) -> tuple[list[str], int, int]:
    """(keys of thin bodies, bodies read, files read)."""
    paths = (sorted(TESTS.rglob("*_test.dart")) if files is None
             else [pathlib.Path(f) for f in files])
    keys: list[str] = []
    bodies_read = 0
    for path in paths:
        src = path.read_text()
        blank = blanked(src)
        asserting = helpers_that_assert(blank)
        for name, body in bodies(src):
            bodies_read += 1
            total = len(ASSERT.findall(body))
            takes = len(TAKE.findall(body))
            if total != takes:
                continue
            if any(re.search(r"\b%s\s*\(" % re.escape(h), body)
                   for h in asserting):
                continue
            keys.append(key_for(path, name))
    return keys, bodies_read, len(paths)


def ceiling_from(path: str) -> int | None:
    """The one definition of the ceiling, or None if unreadable.

    NO DEFAULT ARGUMENT, and that is not a style choice.
    `check_flutter_test_count.py` had `def floor_from(path=FLOOR_FILE)`;
    Python binds a default at definition, so its self-test's patched
    module constant was ignored and ten assertions silently tested the
    real file. Repeated here as a comment because the next gate written
    in this style will be tempted the same way.
    """
    try:
        text = pathlib.Path(path).read_text()
    except OSError:
        return None
    for line in text.splitlines():
        line = line.strip()
        if line.isdigit():
            return int(line)
    return None


#: Under how many files and bodies the sweep is not a sweep. This gate's
#: pattern matches only OFFENDERS, so a ceiling on its own is satisfied by
#: finding nothing -- including by reading nothing at all. Both controls
#: are the shape `check_surface_size.py` uses.
LEAST_FILES = 300
LEAST_BODIES = 5000


def problems(files=None, ceiling_file: str | None = None) -> list[str]:
    keys, bodies_read, files_read = thin_bodies(files)

    if files_read < LEAST_FILES or bodies_read < LEAST_BODIES:
        return [
            'read %s test file(s) and %s test bodies under app/test, which '
            'is below the %s files and %s bodies this sweep needs to mean '
            'anything. The pattern here matches only offenders, so finding '
            'none is also what reading nothing looks like.'
            % (files_read, bodies_read, LEAST_FILES, LEAST_BODIES)
        ]

    out: list[str] = []
    excused = [k for k in keys if k in ALLOWED]
    counted = [k for k in keys if k not in ALLOWED]

    stale = sorted(set(ALLOWED) - set(keys))
    if stale:
        out.append(
            '%s excused test(s) no longer check only `takeException`, or no '
            'longer exist under that name: %s. An excuse nobody needs is an '
            'excuse that will be reused for something else -- take it out.'
            % (len(stale), ', '.join(stale))
        )

    ceiling = ceiling_from(ceiling_file or CEILING_FILE)
    if ceiling is None:
        out.append(
            'could not read a number out of %s, so there is nothing to '
            'compare %s thin test bodies against and this check cannot do '
            'its job.' % (ceiling_file or CEILING_FILE, len(counted))
        )
        return out

    if len(counted) > ceiling:
        out.append(
            '%s test bodies check nothing but `expect(tester.takeException(), '
            'isNull)`, and the ceiling is %s. A screen built without '
            'throwing is not a screen that says the right thing -- eighteen '
            'wrong-shape fixtures passed that check while drawing the four '
            'characters n-u-l-l. Assert what the row says, or excuse the '
            'test in ALLOWED with a reason. New: %s'
            % (len(counted), ceiling,
               ', '.join(sorted(counted)[:8]) or '(none named)')
        )
    elif len(counted) < ceiling:
        out.append(
            'only %s thin test bodies remain and the ceiling still says %s. '
            'This is a RATCHET: lower the number in %s so the ground that '
            'was won cannot be given back.'
            % (len(counted), ceiling, ceiling_file or CEILING_FILE)
        )

    if not out:
        print('%s of %s test bodies check only that nothing threw '
              '(ceiling %s, %s excused with a reason), over %s files and '
              '%s bodies.'
              % (len(counted), bodies_read, ceiling, len(excused),
                 files_read, bodies_read))
    return out


def main() -> int:
    out = problems()
    for line in out:
        print('::error::%s' % line, file=sys.stderr)
    return 1 if out else 0


if __name__ == '__main__':
    sys.exit(main())
