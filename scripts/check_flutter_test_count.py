#!/usr/bin/env python3
"""How many Dart tests actually ran.

    flutter test --file-reporter json:report.json
    python3 scripts/check_flutter_test_count.py report.json

`flutter test` exits 0 when it runs every test it found and they all
pass. It also exits 0 when it finds FEWER tests than it did yesterday,
and says so only in a number nothing compares: the `+N` at the head of
its last line.

That is the same hole the SQL assertions had (`supabase/tests/assertion_floor`)
and the same hole the edge tests had (`supabase/functions/deno_test_floor`),
and it is reached here the same way. A `test(` or `testWidgets(` block
stops registering -- moved inside an `if` that is false, left after an
early `return`, nested in a group whose body throws before reaching it,
or in a file renamed out of the `*_test.dart` glob -- and the suite runs
the rest, passes, and the count drops. Nothing in `ci.yml` read it:
line 113 was a bare `- run: flutter test`.

## What it reads

The JSON report, not the console line. `package:test`'s json reporter
emits one `testDone` event per test, and the count it keeps is the count
flutter prints -- but as a field rather than as text inside a progress
line that also carries a clock, a plus sign and a test name. Scraping
`+1800` out of `03:45 +1800: All tests passed!` works until a test name
contains `+` and a number, which no gate should depend on.

`hidden` is the field that matters. Every suite contributes one hidden
pseudo-test named `loading <path>`; counting those would mean the gate
rises when a file is ADDED with no tests in it, which is the opposite of
what it is for.

## What it refuses

* fewer than the floor -- tests stopped registering
* a report with no `done` event -- the run was killed, and a truncated
  report is not a short run
* a `done` event saying `success: false` -- belt and braces; flutter
  has already exited non-zero, and a gate that disagrees with its own
  subject is the gate that gets deleted
* a skipped test. There are none today and a skip is invisible in an
  exit code. If one is ever wanted, it goes in `SKIPPABLE` with a
  reason, the way every other list in `scripts/` works.
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FLOOR_FILE = os.path.join(ROOT, 'app', 'test', 'flutter_test_floor')

#: Tests allowed to be skipped, `<file>: <name>` -> why.
#:
#: A skipped test is COUNTED, reports `success`, and asserts nothing, so
#: a floor on its own would be cleared by skipping every test in the
#: suite. One entry today, and it is the only one that should ever be
#: added without an argument about it.
#:
#: Keyed by FILE AND NAME. Test names in this suite are group prefixes
#: concatenated with a space and several are not unique across files, so
#: a name-only key would let a different test of the same name be
#: skipped later with this entry as its cover.
SKIPPABLE: dict[str, str] = {
    'test/xlsx_sample_test.dart: writes the sample workbook when asked':
        'a FIXTURE GENERATOR that happens to be a test -- the only '
        'runner here that can compile code importing package:flutter is '
        '`flutter test`. It calls markTestSkipped when XLSX_SAMPLE_OUT '
        'is unset, which is every ordinary run; scripts/check_xlsx.py '
        'sets it and then the same test writes the workbook the Python '
        'gate reads back. Counted either way, so the floor does not '
        'move between the two.',
}


def where(suite_path: str) -> str:
    """A suite path as this repository spells it.

    The reporter emits an absolute path, which differs between this
    machine and the runner, so neither the keys above nor a failure
    message can use it as given.
    """
    at = suite_path.rfind('/test/')
    return suite_path[at + 1:] if at >= 0 else suite_path


def floor_from(path: str) -> int | None:
    """The one definition of the floor, or None if it cannot be read.

    NO DEFAULT, and that is not style. It was `path: str = FLOOR_FILE`,
    and a default argument is bound once when the function is DEFINED --
    so `floor_from()` read the module-level constant's value from import
    time and ignored every later assignment to it. The self-test patches
    `gate.FLOOR_FILE` to a temporary file, and ten assertions about
    floors were therefore made against whatever the real file held.

    They all passed, too, for the whole time the real file did not yet
    exist: `floor_from()` returned None, `main` exited 2, and the tests
    that expected a refusal got one for the wrong reason. The moment the
    real floor was written they went red in a batch. A fed parameter the
    callee can ignore is not a fed parameter.
    """
    try:
        with open(path, encoding='utf-8') as fh:
            text = fh.read()
    except OSError:
        return None
    for line in text.split('\n'):
        if line.strip().isdigit():
            return int(line.strip())
    return None


def read_report(path: str) -> tuple[int, list[str], list[str], bool]:
    """(ran, skipped, failed, finished) from a json test report.

    `ran` counts non-hidden `testDone` events. `finished` is whether a
    `done` event arrived at all AND said success: without it the file is
    a prefix of a run that was killed, and a prefix is short for a
    reason that has nothing to do with how many tests exist.

    Skipped and failed tests are named `<file>: <name>`, which is both
    what `SKIPPABLE` is keyed on and what somebody reading a red build
    needs in order to open the right file.
    """
    suites: dict[int, str] = {}
    names: dict[int, str] = {}
    ran = 0
    skipped: list[str] = []
    failed: list[str] = []
    finished = False
    ok = True
    with open(path, encoding='utf-8') as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                # The reporter writes one object per line. A half-written
                # last line means the run was cut off, which `finished`
                # already reports.
                continue
            kind = event.get('type')
            if kind == 'suite':
                suite = event.get('suite') or {}
                suites[suite.get('id')] = where(suite.get('path') or '?')
            elif kind == 'testStart':
                test = event.get('test') or {}
                names[test.get('id')] = '%s: %s' % (
                    suites.get(test.get('suiteID'), '?'),
                    test.get('name') or '?')
            elif kind == 'testDone':
                if event.get('hidden'):
                    continue
                ran += 1
                name = names.get(event.get('testID'), '?')
                if event.get('skipped'):
                    skipped.append(name)
                if event.get('result') != 'success':
                    failed.append('%s [%s]' % (name, event.get('result')))
            elif kind == 'done':
                finished = True
                ok = bool(event.get('success'))
    return ran, skipped, failed, finished and ok


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print('usage: check_flutter_test_count.py <report.json>',
              file=sys.stderr)
        return 2
    report = argv[1]
    if not os.path.exists(report):
        print(f'::error::{report} does not exist. `flutter test '
              f'--file-reporter json:<path>` writes it; a missing report '
              f'means the run never started, which is not a count of zero.',
              file=sys.stderr)
        return 2

    floor = floor_from(FLOOR_FILE)
    if floor is None:
        print(f'::error::{FLOOR_FILE} holds no bare integer, so there is '
              f'no floor to compare against and this check cannot do its '
              f'job. It is not allowed to pass instead.', file=sys.stderr)
        return 2

    ran, skipped, failed, finished = read_report(report)

    if not finished:
        print(f'::error::{report} has no successful `done` event. The run '
              f'was killed or failed, and a truncated report is a short '
              f'file, not a short suite.', file=sys.stderr)
        return 1

    if failed:
        for f in failed:
            print(f'::error::a test did not succeed: {f}', file=sys.stderr)
        return 1

    unexpected = [s for s in skipped if s not in SKIPPABLE]
    if unexpected:
        for s in unexpected:
            print(f'::error::{s} is skipped. A skipped test is counted, '
                  f'passes, and asserts nothing -- so the floor below '
                  f'cannot tell it from a test that ran. Give it a reason '
                  f'in SKIPPABLE or unskip it.', file=sys.stderr)
        return 1

    if ran < floor:
        print(f'::error::{ran} Dart tests ran; the floor is {floor}. '
              f'`flutter test` exits 0 when tests stop REGISTERING -- a '
              f'block moved inside a false `if`, left after an early '
              f'return, or in a file renamed out of the *_test.dart glob. '
              f'Find the tests that went missing. If they were deliberately '
              f'deleted, lower {os.path.relpath(FLOOR_FILE, ROOT)} in the '
              f'same commit and say which ones in the message.',
              file=sys.stderr)
        return 1

    print(f'{ran} Dart tests ran (floor {floor})')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
