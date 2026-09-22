#!/usr/bin/env python3
"""The dialogs-built gate's own assertions.

    python3 scripts/check_dialogs_built_test.py

Beside the other gate tests, for the reason they all give: a gate that
is wrong is worse than no gate, because it is believed.

The ways THIS one could lie are mostly about deciding what a function's
own body is. It reads Dart with a regular expression and a bracket
counter, and the two shapes it must get right are a braced block and an
expression body -- `showFsMapping` is the second kind, and an earlier
version that read a fixed window of characters would have credited a
short function with the NEXT function's dialog.

The rest is the same crudeness `check_screens_built_test.py` covers:
prose naming an opener is not a test opening one, and an exemption
that has gone stale must be refused in both directions.
"""
import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    'check_dialogs_built',
    Path(__file__).with_name('check_dialogs_built.py'))
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)

REAL_APP = gate.APP


def run_on(lib: dict[str, str], tests: dict[str, str],
           exempt: dict[str, str] | None = None):
    """Run `main` over a made-up app, returning (code, output)."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for name, body in lib.items():
            path = root / 'lib' / 'src' / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body)
        (root / 'test').mkdir(parents=True, exist_ok=True)
        for name, body in tests.items():
            (root / 'test' / name).write_text(body)
        saved_app, saved_exempt = gate.APP, gate.EXEMPT
        gate.APP = root
        gate.EXEMPT = {} if exempt is None else exempt
        try:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = gate.main()
            return code, out.getvalue()
        finally:
            gate.APP, gate.EXEMPT = saved_app, saved_exempt


BRACED = '''
Future<bool> showThing(BuildContext context) async {
  return await showDialog<bool>(context: context, builder: (_) => X()) ?? false;
}
'''

ARROW = '''
Future<bool> showThing(BuildContext context) async =>
    await showDialog<bool>(context: context, builder: (_) => X()) ?? false;
'''


class FindingOpeners(unittest.TestCase):
    def test_a_braced_opener_nothing_calls_is_refused(self):
        code, out = run_on({'a.dart': BRACED}, {})
        self.assertEqual(code, 1)
        self.assertIn('showThing', out)
        self.assertIn('no test ever calls it', out)

    def test_an_expression_bodied_opener_too(self):
        # `showFsMapping` is this shape, and so are several others.
        code, out = run_on({'a.dart': ARROW}, {})
        self.assertEqual(code, 1)
        self.assertIn('showThing', out)

    def test_a_modal_bottom_sheet_counts_as_well(self):
        code, _ = run_on({'a.dart': '''
Future<void> showThing(BuildContext context) async {
  await showModalBottomSheet<void>(context: context, builder: (_) => X());
}
'''}, {})
        self.assertEqual(code, 1)

    def test_one_a_test_calls_passes(self):
        code, _ = run_on({'a.dart': BRACED},
                         {'a_test.dart': 'await showThing(context);'})
        self.assertEqual(code, 0)

    def test_and_one_a_test_passes_as_a_TEAR_OFF_passes(self):
        # `opened(tester, overrides, showThing)` is the cleanest way to
        # hand an opener to a helper and it never appears followed by a
        # bracket. The first version of this gate required `name(` and
        # reported four openers as untested in the commit that tested
        # them.
        code, out = run_on({'a.dart': BRACED},
                           {'a_test.dart': 'opened(tester, [], showThing);'})
        self.assertEqual(code, 0, out)


class NotOpeners(unittest.TestCase):
    def test_a_function_that_opens_nothing_is_not_asked_about(self):
        code, _ = run_on({'a.dart': '''
Future<int> countThings(BuildContext context) async {
  return 4;
}
'''}, {})
        self.assertEqual(code, 0)

    def test_a_private_function_is_not_asked_about(self):
        # It cannot be called from a test in another library, which is
        # the whole reason this gate is keyed on public openers.
        code, _ = run_on({'a.dart': '''
Future<bool> _showThing(BuildContext context) async {
  return await showDialog<bool>(context: context, builder: (_) => X()) ?? false;
}
'''}, {})
        self.assertEqual(code, 0)

    def test_nor_a_method_inside_a_class(self):
        # Indented, so it belongs to a widget and is reached by
        # building that widget rather than by being called.
        code, _ = run_on({'a.dart': '''
class Thing extends StatelessWidget {
  Future<void> open(BuildContext context) async {
    await showDialog<void>(context: context, builder: (_) => X());
  }
}
'''}, {})
        self.assertEqual(code, 0)

    def test_and_a_neighbours_dialog_is_not_credited_to_it(self):
        # The bug an earlier version had: a fixed window after the
        # signature reached into the function below.
        code, out = run_on({'a.dart': '''
Future<int> countThings(BuildContext context) async {
  return 4;
}

Future<bool> showThing(BuildContext context) async {
  return await showDialog<bool>(context: context, builder: (_) => X()) ?? false;
}
'''}, {'a_test.dart': 'await showThing(context);'})
        self.assertEqual(code, 0, out)
        self.assertNotIn('countThings', out)


class ProseIsNotATest(unittest.TestCase):
    def test_a_comment_naming_the_opener_is_not_a_test(self):
        code, _ = run_on(
            {'a.dart': BRACED},
            {'a_test.dart': '// showThing(context) is not covered yet.\n'})
        self.assertEqual(code, 1)

    def test_nor_a_doc_comment(self):
        code, _ = run_on(
            {'a.dart': BRACED},
            {'a_test.dart': '/// Related to showThing(context).\n'})
        self.assertEqual(code, 1)

    def test_and_a_comment_in_the_SOURCE_does_not_make_an_opener(self):
        code, _ = run_on({'a.dart': '''
// This one used to call showDialog and no longer does.
Future<int> countThings(BuildContext context) async => 4;
'''}, {})
        self.assertEqual(code, 0)


class ExemptionsGoStale(unittest.TestCase):
    def test_an_exempted_opener_is_allowed_to_be_untested(self):
        code, _ = run_on({'a.dart': BRACED}, {},
                         exempt={'showThing': 'src/a.dart'})
        self.assertEqual(code, 0)

    def test_an_exemption_for_one_that_is_tested_now_is_refused(self):
        code, out = run_on({'a.dart': BRACED},
                           {'a_test.dart': 'await showThing(context);'},
                           exempt={'showThing': 'src/a.dart'})
        self.assertEqual(code, 1)
        self.assertIn('IS opened by a test now', out)

    def test_an_exemption_for_one_that_is_gone_is_refused(self):
        code, out = run_on({'a.dart': 'Future<int> f() async => 1;'}, {},
                           exempt={'showThing': 'src/a.dart'})
        self.assertEqual(code, 1)
        self.assertIn('no longer an opener', out)


class TheRealTree(unittest.TestCase):
    def test_the_repository_passes_its_own_gate(self):
        self.assertTrue((REAL_APP / 'lib' / 'src').is_dir(), REAL_APP)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = gate.main()
        self.assertEqual(code, 0, out.getvalue())

    def test_the_exemptions_are_not_empty_and_not_everything(self):
        # Empty means the backlog is done and this assertion should be
        # deleted along with the list. Everything means the gate found
        # nothing and is passing by doing nothing.
        found = gate.openers()
        self.assertGreater(len(gate.EXEMPT), 0)
        self.assertLess(len(gate.EXEMPT), len(found))

    def test_and_it_looked_at_more_than_nothing(self):
        self.assertGreater(len(gate.openers()), 100)


if __name__ == '__main__':
    unittest.main(verbosity=2)
