#!/usr/bin/env python3
"""The screens-built gate's own assertions.

    python3 scripts/check_screens_built_test.py

Beside `check_async_skeletons_test.py` and the rest, for the reason
they all give: a gate that is wrong is worse than no gate, because it
is believed.

Two of these are about the specific way THIS gate could lie. It looks
for a class name followed by `(` in the test tree, which is crude on
purpose — judging whether a test asserts anything useful would be
judging taste. The crudeness has exactly one failure mode worth
naming: this codebase explains itself in doc comments, and those
comments are full of screen names. Without stripping them, a screen
nobody had ever built would read as built because somebody wrote a
sentence about it.

The other is the staleness half. An exemption for a screen that is
built now, or that has been renamed away, is a line that has stopped
meaning anything — and a list of what is missing that nobody revisits
is how `docs/gaps-against-autocount.md` came to be wrong about four of
its own entries.
"""
import contextlib
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    'check_screens_built',
    Path(__file__).with_name('check_screens_built.py'))
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


def run_on(lib: dict[str, str], tests: dict[str, str],
           exempt: dict[str, str] | None = None):
    """Run `main` over a made-up app, returning (code, output)."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for name, body in lib.items():
            path = root / 'lib' / 'src' / 'features' / name
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


SCREEN = 'class %s extends StatelessWidget {}\n'


class FindingScreens(unittest.TestCase):
    def test_a_screen_nothing_builds_is_refused(self):
        code, out = run_on({'a.dart': SCREEN % 'ThingScreen'}, {})
        self.assertEqual(code, 1)
        self.assertIn('ThingScreen', out)
        self.assertIn('never constructed', out)

    def test_a_screen_a_test_builds_passes(self):
        code, _ = run_on(
            {'a.dart': SCREEN % 'ThingScreen'},
            {'a_test.dart': 'void main() { ThingScreen(); }'})
        self.assertEqual(code, 0)

    def test_building_it_with_arguments_counts(self):
        code, _ = run_on(
            {'a.dart': SCREEN % 'ThingScreen'},
            {'a_test.dart': 'void main() { const ThingScreen(id: "x"); }'})
        self.assertEqual(code, 0)

    def test_a_class_that_is_not_a_screen_is_not_asked_about(self):
        code, _ = run_on({'a.dart': 'class Thing extends StatelessWidget {}'},
                         {})
        self.assertEqual(code, 0)


class CommentsDoNotBuildAnything(unittest.TestCase):
    """The one way the crude match would lie.

    Every file in this codebase explains itself, and those explanations
    name screens constantly. A gate that counted a sentence as a test
    would pass over exactly the screens somebody had written about and
    not got round to building.
    """

    def test_a_screen_only_named_in_a_line_comment_is_still_unbuilt(self):
        code, out = run_on(
            {'a.dart': SCREEN % 'ThingScreen'},
            {'a_test.dart': '// ThingScreen() is tested elsewhere.\n'
                            'void main() {}'})
        self.assertEqual(code, 1)
        self.assertIn('ThingScreen', out)

    def test_nor_in_a_doc_comment(self):
        code, out = run_on(
            {'a.dart': SCREEN % 'ThingScreen'},
            {'a_test.dart': '/// Covers ThingScreen(...) in passing.\n'
                            'void main() {}'})
        self.assertEqual(code, 1)

    def test_nor_in_a_block_comment(self):
        code, out = run_on(
            {'a.dart': SCREEN % 'ThingScreen'},
            {'a_test.dart': '/* ThingScreen() */\nvoid main() {}'})
        self.assertEqual(code, 1)

    def test_a_screen_DEFINED_inside_a_comment_is_not_a_screen(self):
        # The same stripping on the other side, or a commented-out
        # class would be demanded of somebody forever.
        code, _ = run_on({'a.dart': '// class GhostScreen extends X {}\n'}, {})
        self.assertEqual(code, 0)


class ExemptionsGoStale(unittest.TestCase):
    def test_an_exempted_screen_is_allowed_to_be_unbuilt(self):
        code, _ = run_on(
            {'a.dart': SCREEN % 'ThingScreen'}, {},
            exempt={'ThingScreen': 'lib/a.dart'})
        self.assertEqual(code, 0)

    def test_an_exemption_for_a_screen_that_is_built_now_is_refused(self):
        # The point of the backlog is that it shrinks. An entry nobody
        # removes when the work is done is how the list rots.
        code, out = run_on(
            {'a.dart': SCREEN % 'ThingScreen'},
            {'a_test.dart': 'void main() { ThingScreen(); }'},
            exempt={'ThingScreen': 'lib/a.dart'})
        self.assertEqual(code, 1)
        self.assertIn('IS built by a test now', out)

    def test_an_exemption_for_a_screen_that_is_gone_is_refused(self):
        code, out = run_on(
            {'a.dart': SCREEN % 'OtherScreen'},
            {'a_test.dart': 'void main() { OtherScreen(); }'},
            exempt={'GhostScreen': 'lib/gone.dart'})
        self.assertEqual(code, 1)
        self.assertIn('no longer exists', out)


class TheRealTree(unittest.TestCase):
    def test_the_repository_passes_its_own_gate(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = gate.main()
        self.assertEqual(code, 0, out.getvalue())

    def test_the_exemptions_are_not_empty_and_not_everything(self):
        # If the backlog ever reaches zero this assertion is the thing
        # that says so -- delete it and the EXEMPT dict together.
        self.assertGreater(len(gate.EXEMPT), 0)
        self.assertLess(len(gate.EXEMPT), len(gate.screens()))


if __name__ == '__main__':
    unittest.main(verbosity=2)
