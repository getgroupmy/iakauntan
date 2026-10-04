#!/usr/bin/env python3
"""The Dart-test counter's own assertions.

    python3 scripts/check_flutter_test_count_test.py

A gate that counts is a gate that can count wrong, and counting wrong
HIGH is the dangerous direction: it clears its own floor for ever and
reports a number nobody checks. So the fixtures here are mostly about
what must NOT be counted -- the hidden `loading <path>` pseudo-test
every suite emits, a `testStart` with no `testDone`, a line that is not
JSON -- and about the three ways a short report is short for a reason
other than a short suite.
"""
import contextlib
import importlib.util
import io
import json
import os
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    'check_flutter_test_count',
    Path(__file__).with_name('check_flutter_test_count.py'))
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)

ROOT = Path(gate.ROOT)


def event(**kw) -> str:
    return json.dumps(kw)


def suite_loading(suite_id: int, test_id: int, path: str) -> list[str]:
    """What the reporter emits for a suite before any real test runs."""
    return [
        event(type='suite', suite={'id': suite_id, 'platform': 'vm',
                                   'path': path}),
        event(type='testStart',
              test={'id': test_id, 'name': f'loading {path}',
                    'suiteID': suite_id, 'groupIDs': []}),
        event(type='testDone', testID=test_id, result='success',
              skipped=False, hidden=True),
    ]


def real_test(test_id: int, name: str, result: str = 'success',
              skipped: bool = False) -> list[str]:
    return [
        event(type='testStart', test={'id': test_id, 'name': name,
                                      'suiteID': 0, 'groupIDs': []}),
        event(type='testDone', testID=test_id, result=result,
              skipped=skipped, hidden=False),
    ]


def report(lines: list[str], done: bool | None = True) -> str:
    out = [event(type='start', protocolVersion='0.1.1')] + lines
    if done is not None:
        out.append(event(type='done', success=done))
    return '\n'.join(out) + '\n'


def run_on(text: str | None, floor: str | None = '2',
           exists: bool = True) -> tuple[int, str]:
    """Run `main` over a made-up report and floor file."""
    with tempfile.TemporaryDirectory() as tmp:
        report_path = os.path.join(tmp, 'report.json')
        if exists and text is not None:
            with open(report_path, 'w', encoding='utf-8') as fh:
                fh.write(text)
        floor_path = os.path.join(tmp, 'flutter_test_floor')
        if floor is not None:
            with open(floor_path, 'w', encoding='utf-8') as fh:
                fh.write(floor)
        saved = gate.FLOOR_FILE
        gate.FLOOR_FILE = floor_path
        try:
            # Both streams. Every refusal in this gate writes to stderr
            # and the one pass writes to stdout; a harness capturing one
            # of them makes half its assertions vacuous.
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), \
                    contextlib.redirect_stderr(err):
                code = gate.main(['gate', report_path])
            return code, out.getvalue() + err.getvalue()
        finally:
            gate.FLOOR_FILE = saved


class Counting(unittest.TestCase):
    def test_two_tests_are_two(self):
        code, said = run_on(report(real_test(1, 'a') + real_test(2, 'b')))
        self.assertEqual(code, 0, said)
        self.assertIn('2 Dart tests ran', said)

    def test_the_hidden_loading_pseudo_test_is_not_counted(self):
        # Every suite emits one. Counting them would make this gate RISE
        # when a file with no tests in it is added, which is backwards.
        code, said = run_on(report(
            suite_loading(0, 10, 'test/a_test.dart') + real_test(1, 'a')
            + suite_loading(1, 11, 'test/b_test.dart') + real_test(2, 'b')))
        self.assertEqual(code, 0, said)
        self.assertIn('2 Dart tests ran', said)
        self.assertNotIn('4 Dart tests ran', said)

    def test_setUpAll_and_tearDownAll_are_not_counted_either(self):
        # Measured, not guessed. The real report holds 465 hidden events:
        # 457 `loading <path>` pseudo-tests, one per test file, and eight
        # more -- four `(setUpAll)` and four `(tearDownAll)`. They are
        # reported as tests, they pass, and they assert nothing. 457 was
        # the number I expected and 465 was the number there.
        lines = (suite_loading(0, 10, 'test/a_test.dart')
                 + [event(type='testStart',
                          test={'id': 20, 'name': '(setUpAll)',
                                'suiteID': 0, 'groupIDs': []}),
                    event(type='testDone', testID=20, result='success',
                          skipped=False, hidden=True)]
                 + real_test(1, 'a') + real_test(2, 'b')
                 + [event(type='testStart',
                          test={'id': 21, 'name': '(tearDownAll)',
                                'suiteID': 0, 'groupIDs': []}),
                    event(type='testDone', testID=21, result='success',
                          skipped=False, hidden=True)])
        code, said = run_on(report(lines))
        self.assertEqual(code, 0, said)
        self.assertIn('2 Dart tests ran', said)

    def test_a_test_that_started_and_never_finished_is_not_counted(self):
        started = event(type='testStart',
                        test={'id': 3, 'name': 'hung', 'suiteID': 0,
                              'groupIDs': []})
        code, said = run_on(report(real_test(1, 'a') + real_test(2, 'b')
                                   + [started]))
        self.assertEqual(code, 0, said)
        self.assertIn('2 Dart tests ran', said)

    def test_a_line_that_is_not_json_does_not_crash_it(self):
        # flutter interleaves nothing into the file reporter today, but a
        # gate that throws on a stray line is a gate that goes red for a
        # reason nobody can act on.
        lines = real_test(1, 'a') + ['{half an obj'] + real_test(2, 'b')
        code, said = run_on(report(lines))
        self.assertEqual(code, 0, said)
        self.assertIn('2 Dart tests ran', said)


class TheFloor(unittest.TestCase):
    def test_exactly_at_the_floor_passes(self):
        code, said = run_on(report(real_test(1, 'a') + real_test(2, 'b')),
                            floor='2')
        self.assertEqual(code, 0, said)

    def test_one_below_the_floor_is_refused(self):
        code, said = run_on(report(real_test(1, 'a')), floor='2')
        self.assertEqual(code, 1)
        self.assertIn('1 Dart tests ran', said)
        self.assertIn('floor is 2', said)

    def test_an_empty_run_is_refused_and_not_called_clean(self):
        # `flutter test` over a tree whose every test stopped registering
        # prints "All tests passed!" and exits 0.
        code, said = run_on(report([]), floor='2')
        self.assertEqual(code, 1)
        self.assertIn('0 Dart tests ran', said)

    def test_a_floor_file_with_no_integer_refuses_rather_than_passes(self):
        code, said = run_on(report(real_test(1, 'a') + real_test(2, 'b')),
                            floor='# a comment and nothing else\n')
        self.assertEqual(code, 2, said)
        self.assertIn('no bare integer', said)
        self.assertNotIn('Dart tests ran (floor', said)

    def test_a_missing_floor_file_too(self):
        code, said = run_on(report(real_test(1, 'a')), floor=None)
        self.assertEqual(code, 2, said)
        self.assertIn('no bare integer', said)

    def test_the_floor_is_read_from_the_file_not_from_this_module(self):
        # The number must live in one place, and `floor_from` must take
        # the path rather than default to it: a default argument is bound
        # when the function is DEFINED, so `floor_from()` ignored every
        # later assignment to FLOOR_FILE -- including the one this file's
        # harness makes, which left ten assertions below testing the real
        # floor file while claiming to test a fed one.
        self.assertIsNone(gate.floor_from(os.devnull))
        import inspect
        self.assertIs(
            inspect.signature(gate.floor_from).parameters['path'].default,
            inspect.Parameter.empty,
            'floor_from must take the path, not default to it')


class ShortForTheWrongReason(unittest.TestCase):
    def test_a_report_with_no_done_event_is_refused(self):
        code, said = run_on(report(real_test(1, 'a') + real_test(2, 'b'),
                                   done=None))
        self.assertEqual(code, 1)
        self.assertIn('no successful `done` event', said)

    def test_a_done_event_saying_failure_is_refused(self):
        code, said = run_on(report(real_test(1, 'a') + real_test(2, 'b'),
                                   done=False))
        self.assertEqual(code, 1)
        self.assertIn('no successful `done` event', said)

    def test_a_missing_report_file_is_not_a_count_of_zero(self):
        code, said = run_on(None, exists=False)
        self.assertEqual(code, 2)
        self.assertIn('does not exist', said)

    def test_no_argument_is_a_usage_error_not_a_pass(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = gate.main(['gate'])
        self.assertEqual(code, 2)
        self.assertIn('usage', out.getvalue() + err.getvalue())


class FailuresAndSkips(unittest.TestCase):
    def test_a_failing_test_is_named(self):
        code, said = run_on(report(
            real_test(1, 'a') + real_test(2, 'b', result='error')))
        self.assertEqual(code, 1)
        self.assertIn('b', said)
        self.assertIn('did not succeed', said)

    def test_a_skipped_test_is_refused_by_default(self):
        code, said = run_on(report(
            real_test(1, 'a') + real_test(2, 'b', skipped=True)))
        self.assertEqual(code, 1)
        self.assertIn('is skipped', said)

    def test_a_skipped_test_with_a_reason_is_allowed(self):
        lines = (suite_loading(0, 10, '/abs/app/test/a_test.dart')
                 + real_test(1, 'a') + real_test(2, 'b', skipped=True))
        saved = gate.SKIPPABLE
        gate.SKIPPABLE = {'test/a_test.dart: b': 'needs a device'}
        try:
            code, said = run_on(report(lines))
        finally:
            gate.SKIPPABLE = saved
        self.assertEqual(code, 0, said)

    def test_the_same_name_in_ANOTHER_file_is_not_covered_by_it(self):
        # The reason the keys carry a file. Names in this suite are group
        # prefixes joined with a space and several repeat across files.
        lines = (suite_loading(0, 10, '/abs/app/test/b_test.dart')
                 + real_test(1, 'a') + real_test(2, 'b', skipped=True))
        saved = gate.SKIPPABLE
        gate.SKIPPABLE = {'test/a_test.dart: b': 'needs a device'}
        try:
            code, said = run_on(report(lines))
        finally:
            gate.SKIPPABLE = saved
        self.assertEqual(code, 1, said)
        self.assertIn('test/b_test.dart: b', said)

    def test_a_failure_names_the_file_it_is_in(self):
        lines = (suite_loading(0, 10, '/abs/app/test/c_test.dart')
                 + real_test(1, 'a') + real_test(2, 'b', result='failure'))
        code, said = run_on(report(lines))
        self.assertEqual(code, 1)
        self.assertIn('test/c_test.dart: b', said)

    def test_an_absolute_suite_path_is_spelled_the_way_the_repo_does(self):
        self.assertEqual(
            gate.where('/home/runner/work/iak/iak/app/test/x.dart'),
            'test/x.dart')
        self.assertEqual(gate.where('/home/user/iakauntan/app/test/a/b.dart'),
                         'test/a/b.dart')
        # Nothing to cut: left alone rather than guessed at.
        self.assertEqual(gate.where('x.dart'), 'x.dart')

    def test_the_skip_list_holds_exactly_the_one_known_skip(self):
        # Pinned by name, not counted. A second skip added quietly is the
        # thing this gate is for: `flutter test` prints `~1` in a
        # progress line and exits 0, and a skipped test clears a floor
        # as well as a passing one does.
        self.assertEqual(
            sorted(gate.SKIPPABLE),
            ['test/xlsx_sample_test.dart: '
             'writes the sample workbook when asked'])
        for name, why in gate.SKIPPABLE.items():
            self.assertGreater(len(why), 60, name)

    def test_the_known_skip_is_the_one_in_the_tree(self):
        # And it is the test it says it is. A name in this list that
        # matches nothing would let a DIFFERENT test of that name be
        # skipped later, in another file, with this entry as its cover.
        source = (ROOT / 'app' / 'test' / 'xlsx_sample_test.dart').read_text(
            encoding='utf-8')
        self.assertIn("test('writes the sample workbook when asked'", source)
        self.assertIn('markTestSkipped', source)


class TheRealRepository(unittest.TestCase):
    def test_the_shipped_floor_is_a_positive_integer(self):
        floor = gate.floor_from(gate.FLOOR_FILE)
        self.assertIsNotNone(floor, gate.FLOOR_FILE)
        self.assertGreater(floor, 0)

    def test_the_floor_file_says_why_it_exists(self):
        text = Path(gate.FLOOR_FILE).read_text(encoding='utf-8')
        self.assertGreater(len(text.strip().split('\n')), 3,
                           'a bare number with no note is a number somebody '
                           'will lower without reading anything')

    def test_ci_runs_flutter_test_with_the_file_reporter(self):
        # The gate is useless if the workflow never writes the report it
        # reads. `- run: flutter test` was the whole step for 2250 runs.
        workflow = (ROOT / '.github' / 'workflows' / 'ci.yml').read_text(
            encoding='utf-8')
        self.assertIn('--file-reporter json:', workflow)
        self.assertIn('check_flutter_test_count.py', workflow)

    def test_ci_no_longer_has_a_bare_flutter_test_run(self):
        workflow = (ROOT / '.github' / 'workflows' / 'ci.yml').read_text(
            encoding='utf-8')
        self.assertNotIn('\n      - run: flutter test\n', workflow,
                         'an uncounted `flutter test` is the hole this '
                         'gate was written to close')


if __name__ == '__main__':
    unittest.main(verbosity=2)
