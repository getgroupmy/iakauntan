#!/usr/bin/env python3
"""The loading-spinner gate's own assertions.

    python3 scripts/check_loading_spinners_test.py

Beside `check_document_types_test.py`, `check_orphan_columns_test.py`
and the rest, for the reason they all give: a gate that is wrong is
worse than no gate, because it is believed.

This one has a specific reason as well. Its predecessor was a `grep -A3
'loading: ('`, which is how the three spinners it was written to
replace were counted -- and that count was WRONG. A fourth was
`AsyncView(loading: const Padding(...))` with the spinner four lines
down and no paren after the colon, so neither the pattern nor the
window matched it. A three-line window over a language with no line
limit is not a reader; this one balances brackets, and these assertions
are what say it does.
"""
import contextlib
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    'check_loading_spinners',
    Path(__file__).with_name('check_loading_spinners.py'))
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


def run_on(files: dict[str, str], exempt: dict[str, str] | None = None):
    """Run `main` over a made-up `app/lib`, returning (code, output)."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for name, body in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body)
        saved_lib, saved_exempt = gate.LIB, gate.EXEMPT
        gate.LIB = root
        gate.EXEMPT = {} if exempt is None else exempt
        try:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = gate.main()
            return code, out.getvalue()
        finally:
            gate.LIB, gate.EXEMPT = saved_lib, saved_exempt


SPIN = 'CircularProgressIndicator'


class Blanking(unittest.TestCase):
    def test_it_keeps_every_offset(self):
        # Offsets are what the line numbers are counted from. A blanker
        # that shortened the source would report the wrong line for
        # every finding after the first comment.
        for src in [
            "a // b\nc",
            "a /* b */ c",
            "a 'b' c",
            'a "b" c',
            "a '''b\nc''' d",
            r"a 'b\'c' d",
        ]:
            self.assertEqual(len(gate.blanked(src)), len(src), src)

    def test_a_spinner_in_a_comment_is_not_a_spinner(self):
        self.assertNotIn(SPIN, gate.blanked(f'// {SPIN}\n'))
        self.assertNotIn(SPIN, gate.blanked(f'/* {SPIN} */'))

    def test_and_neither_is_one_in_a_string(self):
        self.assertNotIn(SPIN, gate.blanked(f"const s = '{SPIN}';"))

    def test_but_the_code_around_them_survives(self):
        blank = gate.blanked("loading: // no\nwidget(),")
        self.assertIn('loading:', blank)
        self.assertIn('widget()', blank)


class ReadingTheArm(unittest.TestCase):
    def arm(self, src):
        return [text for _, text in gate.loading_arms(src)]

    def test_it_stops_at_the_end_of_the_argument(self):
        # Not at the first comma: that is the second character of most
        # widgets, and a reader that stopped there would find nothing
        # in any arm that builds anything.
        got = self.arm('x(loading: Foo(a, b, c), builder: Bar())')
        self.assertEqual(got, ['Foo(a, b, c)'])

    def test_and_does_not_run_on_into_the_next_argument(self):
        got = self.arm(f'x(loading: const Bar(), builder: {SPIN}())')
        self.assertNotIn(SPIN, got[0])

    def test_and_finds_one_several_lines_down(self):
        # The case the grep missed, verbatim in shape: no paren after
        # the colon and the spinner on the third line.
        src = (
            'AsyncView(\n'
            '  value: v,\n'
            '  loading: const Padding(\n'
            '    padding: EdgeInsets.all(16),\n'
            f'    child: Center(child: {SPIN}()),\n'
            '  ),\n'
            '  builder: (x) => Text("$x"),\n'
            ')'
        )
        got = self.arm(src)
        self.assertEqual(len(got), 1)
        self.assertIn(SPIN, got[0])

    def test_and_reports_the_line_the_arm_starts_on(self):
        src = f'a\nb\nx(loading: {SPIN}())'
        self.assertEqual([line for line, _ in gate.loading_arms(src)], [3])


class WhatItRefuses(unittest.TestCase):
    def test_the_real_tree_passes(self):
        # The gate's whole claim, against the app as it stands.
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = gate.main()
        self.assertEqual(code, 0, out.getvalue())

    def test_a_spinner_in_a_loading_arm_is_refused(self):
        code, out = run_on({'a/b.dart': f'x(loading: const {SPIN}())'})
        self.assertEqual(code, 1)
        self.assertIn('a/b.dart:1', out)

    def test_a_bar_is_not_a_circle(self):
        # Forty-five of these, and none is the thing the rule is about:
        # a two-pixel bar under a heading that is already drawn says
        # more is coming without claiming a shape.
        code, _ = run_on({
            'a/b.dart': 'x(loading: const LinearProgressIndicator())'})
        self.assertEqual(code, 0)

    def test_a_spinner_somewhere_else_is_not_refused(self):
        # In a button, which `skeletons.dart` says keeps its spinner:
        # it is about time passing, not about a shape.
        code, _ = run_on({
            'a/b.dart': f'FilledButton(child: {SPIN}(), onPressed: f)'})
        self.assertEqual(code, 0)

    def test_and_neither_is_one_only_mentioned(self):
        code, _ = run_on({'a/b.dart': f'// loading: {SPIN}()\n'})
        self.assertEqual(code, 0)


class TheExemptions(unittest.TestCase):
    def test_one_suppresses_its_own_file_and_nothing_else(self):
        code, out = run_on(
            {'a/b.dart': f'x(loading: {SPIN}())',
             'a/c.dart': f'x(loading: {SPIN}())'},
            exempt={'a/b.dart': 'the payload decides the shape'})
        self.assertEqual(code, 1)
        self.assertIn('a/c.dart', out)
        self.assertNotIn('a/b.dart:', out)

    def test_one_that_no_longer_matches_anything_is_refused(self):
        # The lesson `docs/gaps-against-autocount.md` cost: a list of
        # what is missing, left behind after the missing part was
        # built, reads as a gap to everyone who finds it.
        code, out = run_on(
            {'a/b.dart': 'x(loading: const LinearProgressIndicator())'},
            exempt={'a/b.dart': 'the payload decides the shape'})
        self.assertEqual(code, 1)
        self.assertIn('Remove the exemption', out)

    def test_and_the_reason_is_printed_when_it_goes_stale(self):
        _, out = run_on({'a/b.dart': 'nothing'},
                        exempt={'a/b.dart': 'a very particular reason'})
        self.assertIn('a very particular reason', out)

    def test_there_are_none_today(self):
        # Said out loud, so adding the first one is a deliberate act
        # with this assertion to change.
        self.assertEqual(gate.EXEMPT, {})


if __name__ == '__main__':
    unittest.main(verbosity=0, buffer=True)
