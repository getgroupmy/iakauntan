#!/usr/bin/env python3
"""The thin-assertion ceiling's own assertions.

    python3 scripts/check_thin_assertions_test.py

Everything is FED -- the sources and the ceiling file both -- so each
failure message is exercised. A gate whose only tested path is the passing
one says nothing about what it prints when it fires, and what it prints is
the whole remedy.

The blanking class is the one that matters most. `${...}` inside a Dart
string and a `{` inside any string literal have both broken brace matching
in this repository before, and the second time it swallowed seventeen
following tests into one mis-matched body -- which showed up as a COUNT
that was too low, not as an error.
"""

from __future__ import annotations

import contextlib
import importlib.util
import inspect
import io
import pathlib
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "thin", HERE / "check_thin_assertions.py")
thin = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(thin)

THICK = """
void main() {
  testWidgets('says something', (tester) async {
    await tester.pumpWidget(const Thing());
    expect(find.text('Ramli'), findsOneWidget);
  });
}
"""

THIN = """
void main() {
  testWidgets('says nothing', (tester) async {
    await tester.pumpWidget(const Thing());
    expect(tester.takeException(), isNull);
  });
}
"""


def said(problems) -> str:
    return "\n".join(problems)


class Fed:
    """A temporary `app/test` with the sweep controls lowered.

    `ALLOWED` is emptied for the duration unless a test supplies its own.
    The first version of this did not, so the real repository's thirteen
    excuses were stale against a two-file temporary tree and twenty-four
    of thirty assertions failed on the same unrelated message -- which is
    the harness being wrong, not the gate.
    """

    def __init__(self, sources: dict[str, str], ceiling: str | None = "0",
                 allowed: dict[str, str] | None = None):
        self.sources = sources
        self.ceiling = ceiling
        self.allowed = allowed or {}

    def __enter__(self):
        self.dir = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.dir.name)
        (root / "test").mkdir()
        self.paths = []
        for name, text in self.sources.items():
            p = root / "test" / name
            p.write_text(text)
            self.paths.append(str(p))
        self.saved = (thin.TESTS, thin.LEAST_FILES, thin.LEAST_BODIES,
                      thin.ALLOWED.copy())
        thin.TESTS = root / "test"
        thin.LEAST_FILES = 1
        thin.LEAST_BODIES = 1
        thin.ALLOWED.clear()
        thin.ALLOWED.update(self.allowed)
        self.ceiling_file = str(root / "ceiling")
        if self.ceiling is not None:
            pathlib.Path(self.ceiling_file).write_text(self.ceiling + "\n")
        return self

    def run(self):
        return thin.problems(files=self.paths,
                             ceiling_file=self.ceiling_file)

    def __exit__(self, *exc):
        (thin.TESTS, thin.LEAST_FILES, thin.LEAST_BODIES,
         allowed) = self.saved
        thin.ALLOWED.clear()
        thin.ALLOWED.update(allowed)
        self.dir.cleanup()
        return False


class TheLiveRepository(unittest.TestCase):

    def test_it_passes_as_shipped(self):
        out = thin.problems()
        self.assertEqual(out, [], said(out))

    def test_the_ceiling_file_exists_and_holds_a_number(self):
        self.assertIsNotNone(thin.ceiling_from(thin.CEILING_FILE))

    def test_every_excuse_says_why(self):
        self.assertTrue(thin.ALLOWED)
        for key, why in thin.ALLOWED.items():
            with self.subTest(key):
                self.assertGreater(len(why), 20, key)

    def test_every_excuse_names_a_file_and_a_test(self):
        for key in thin.ALLOWED:
            with self.subTest(key):
                self.assertIn('.dart: ', key)
                self.assertTrue(key.startswith('test/'), key)

    def test_the_real_sweep_reads_the_whole_suite(self):
        _, bodies, files = thin.thin_bodies()
        self.assertGreater(files, 400)
        self.assertGreater(bodies, 6000)


class WhatCountsAsThin(unittest.TestCase):

    def test_a_body_with_a_real_assertion_is_not_thin(self):
        with Fed({'a_test.dart': THICK}) as fed:
            self.assertEqual(fed.run(), [])

    def test_a_body_with_only_take_exception_is(self):
        with Fed({'a_test.dart': THIN}) as fed:
            out = fed.run()
            self.assertEqual(len(out), 1, said(out))
            self.assertIn('says nothing', out[0])
            self.assertIn('the ceiling is 0', out[0])

    def test_take_exception_beside_a_real_assertion_is_not_thin(self):
        with Fed({'a_test.dart': """
void main() {
  testWidgets('both', (tester) async {
    expect(tester.takeException(), isNull);
    expect(find.text('x'), findsOneWidget);
  });
}
"""}) as fed:
            self.assertEqual(fed.run(), [])

    def test_the_opposite_claim_is_a_real_assertion(self):
        # `isNotNull` says the screen SHOULD have thrown, which is a
        # claim. Matching `takeException` loosely would have called it
        # thin.
        with Fed({'a_test.dart': """
void main() {
  testWidgets('it throws', (tester) async {
    expect(tester.takeException(), isNotNull);
  });
}
"""}) as fed:
            self.assertEqual(fed.run(), [])

    def test_a_plain_test_counts_too_not_only_testWidgets(self):
        with Fed({'a_test.dart': """
void main() {
  test('plain', () {
    expect(tester.takeException(), isNull);
  });
}
"""}) as fed:
            out = fed.run()
            self.assertEqual(len(out), 1, said(out))
            self.assertIn('plain', out[0])

    def test_a_name_ending_in_test_is_not_a_test_call(self):
        with Fed({'a_test.dart': """
void main() {
  final x = my_test(1);
  testWidgets('real', (tester) async {
    expect(find.text('x'), findsOneWidget);
  });
}
"""}) as fed:
            self.assertEqual(fed.run(), [])


class OneLevelOfHelper(unittest.TestCase):
    """Seventeen findings that were not findings, before this existed."""

    def test_a_helper_that_asserts_makes_the_body_thick(self):
        with Fed({'a_test.dart': """
void expectItStandsUp(WidgetTester tester) {
  expect(find.byType(Shell), findsOneWidget);
}

void main() {
  testWidgets('through a helper', (tester) async {
    await show(tester);
    expectItStandsUp(tester);
  });
}
"""}) as fed:
            self.assertEqual(fed.run(), [])

    def test_a_helper_that_asserts_nothing_does_not(self):
        with Fed({'a_test.dart': """
void pumpIt(WidgetTester tester) {
  tester.pumpWidget(const Thing());
}

void main() {
  testWidgets('through a helper that does nothing', (tester) async {
    pumpIt(tester);
    expect(tester.takeException(), isNull);
  });
}
"""}) as fed:
            out = fed.run()
            self.assertEqual(len(out), 1, said(out))
            self.assertIn('through a helper that does nothing', out[0])

    def test_a_helper_in_another_file_does_not_count(self):
        # Stated as a limitation rather than discovered as one: the
        # resolution is same-file, and a body relying on an imported
        # helper reads as thin and has to be excused.
        with Fed({
            'helpers.dart': """
void expectItStandsUp(WidgetTester tester) {
  expect(find.byType(Shell), findsOneWidget);
}
""",
            'a_test.dart': """
void main() {
  testWidgets('imported helper', (tester) async {
    expectItStandsUp(tester);
    expect(tester.takeException(), isNull);
  });
}
""",
        }) as fed:
            out = fed.run()
            self.assertEqual(len(out), 1, said(out))
            self.assertIn('imported helper', out[0])


class TheBlanking(unittest.TestCase):

    def test_a_brace_inside_a_string_does_not_break_matching(self):
        with Fed({'a_test.dart': """
void main() {
  testWidgets('interpolated', (tester) async {
    final s = 'RM ${total.toStringAsFixed(2)} paid';
    expect(find.text(s), findsOneWidget);
  });
  testWidgets('the one after it', (tester) async {
    expect(tester.takeException(), isNull);
  });
}
"""}) as fed:
            out = fed.run()
            # The second body must be SEEN. A mis-matched first body
            # swallows it, and the count comes out too low with no error.
            self.assertEqual(len(out), 1, said(out))
            self.assertIn('the one after it', out[0])

    def test_a_comment_naming_expect_does_not_make_a_body_thick(self):
        with Fed({'a_test.dart': """
void main() {
  testWidgets('commented', (tester) async {
    // expect(find.text('x'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
"""}) as fed:
            out = fed.run()
            self.assertEqual(len(out), 1, said(out))
            self.assertIn('commented', out[0])

    def test_a_block_comment_too(self):
        with Fed({'a_test.dart': """
void main() {
  testWidgets('block commented', (tester) async {
    /* expect(find.text('x'), findsOneWidget); */
    expect(tester.takeException(), isNull);
  });
}
"""}) as fed:
            out = fed.run()
            self.assertEqual(len(out), 1, said(out))
            self.assertIn('block commented', out[0])

    def test_a_path_outside_the_tree_does_not_crash_the_key(self):
        # `relative_to` raises for a path outside its argument, and this
        # repository has written that bug twice in this directory.
        key = thin.key_for(pathlib.Path('/elsewhere/a_test.dart'), 'a name')
        self.assertIn('a name', key)
        self.assertIn('a_test.dart', key)

    def test_blanking_keeps_the_length(self):
        src = "a 'bb' // cc\nd"
        self.assertEqual(len(thin.blanked(src)), len(src))
        self.assertEqual(thin.blanked(src).count('\n'), 1)


class TheExcuses(unittest.TestCase):

    def test_an_excused_body_is_not_counted(self):
        with Fed({'a_test.dart': THIN},
                 allowed={'test/a_test.dart: says nothing': 'because it is'},
                 ) as fed:
            self.assertEqual(fed.run(), [])

    def test_an_excuse_nobody_needs_is_reported(self):
        with Fed({'a_test.dart': THICK},
                 allowed={'test/a_test.dart: gone': 'because it was'}) as fed:
            out = fed.run()
            self.assertEqual(len(out), 1, said(out))
            self.assertIn('test/a_test.dart: gone', out[0])
            self.assertIn('no longer', out[0])


class TheRatchet(unittest.TestCase):

    def test_at_the_ceiling_it_passes(self):
        with Fed({'a_test.dart': THIN}, ceiling='1') as fed:
            self.assertEqual(fed.run(), [])

    def test_over_it_the_gate_fires(self):
        with Fed({'a_test.dart': THIN}, ceiling='0') as fed:
            out = fed.run()
            self.assertEqual(len(out), 1, said(out))
            self.assertIn('n-u-l-l', out[0])

    def test_UNDER_it_the_gate_fires_TOO(self):
        # The direction a ratchet exists for. Ground won and not written
        # down is ground that gets given back.
        with Fed({'a_test.dart': THICK}, ceiling='3') as fed:
            out = fed.run()
            self.assertEqual(len(out), 1, said(out))
            self.assertIn('RATCHET', out[0])
            self.assertIn('lower the number', out[0])

    def test_a_missing_ceiling_file_is_refused_not_ignored(self):
        with Fed({'a_test.dart': THIN}, ceiling=None) as fed:
            out = fed.run()
            self.assertEqual(len(out), 1, said(out))
            self.assertIn('could not read a number', out[0])

    def test_a_ceiling_file_with_no_number_is_refused(self):
        with Fed({'a_test.dart': THIN}, ceiling='prose only') as fed:
            out = fed.run()
            self.assertEqual(len(out), 1, said(out))
            self.assertIn('could not read a number', out[0])

    def test_the_ceiling_reader_has_no_default_argument(self):
        # `check_flutter_test_count.py` had one, Python bound it at
        # definition, and ten of its floor assertions silently tested the
        # real file instead of the patched one. Pinned so the same hole
        # cannot be dug twice.
        default = inspect.signature(thin.ceiling_from).parameters[
            'path'].default
        self.assertIs(default, inspect.Parameter.empty)

    def test_prose_around_the_number_is_allowed(self):
        with Fed({'a_test.dart': THIN},
                 ceiling='1\n\nand here is why') as fed:
            self.assertEqual(fed.run(), [])


class ItMustNotPassOverNothing(unittest.TestCase):

    def test_an_empty_sweep_is_refused(self):
        saved = (thin.LEAST_FILES, thin.LEAST_BODIES)
        try:
            with Fed({'a_test.dart': THIN}) as fed:
                thin.LEAST_FILES = 300
                thin.LEAST_BODIES = 5000
                out = fed.run()
                self.assertEqual(len(out), 1, said(out))
                self.assertIn('below the 300 files', out[0])
                self.assertIn('matches only offenders', out[0])
        finally:
            thin.LEAST_FILES, thin.LEAST_BODIES = saved

    def test_and_it_stops_there_rather_than_reporting_a_clean_sweep(self):
        saved = (thin.LEAST_FILES, thin.LEAST_BODIES)
        try:
            with Fed({'a_test.dart': THICK}, ceiling='9') as fed:
                thin.LEAST_FILES = 300
                thin.LEAST_BODIES = 5000
                out = fed.run()
                self.assertEqual(len(out), 1, said(out))
                self.assertNotIn('RATCHET', out[0])
        finally:
            thin.LEAST_FILES, thin.LEAST_BODIES = saved


class WhatItSaysWhenItPasses(unittest.TestCase):

    def test_the_success_line_carries_both_numbers(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = thin.main()
        self.assertEqual(code, 0, out.getvalue())
        self.assertRegex(out.getvalue(),
                         r'\d+ of \d{4,} test bodies check only that nothing '
                         r'threw \(ceiling \d+, \d+ excused')


if __name__ == '__main__':
    unittest.main(verbosity=2)
