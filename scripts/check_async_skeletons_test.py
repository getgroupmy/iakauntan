#!/usr/bin/env python3
"""The AsyncView-skeleton gate's own assertions.

    python3 scripts/check_async_skeletons_test.py

Beside `check_loading_spinners_test.py` and the rest, for the reason
they all give: a gate that is wrong is worse than no gate, because it
is believed.

This one has its own reason, and it is recent. The first version of
the gate matched the type argument with `<[^>]*>`, which stops at the
first `>`. The commonest type argument in this app is
`AsyncView<List<Map<String, dynamic>>>` -- three closers in a row --
so the gate was blind to five call sites and reported a clean sweep
over a file with five bare ones in it.

It was caught only because the same five were in EXEMPT, and the
staleness half of the gate refused exemptions that matched nothing.
Had those screens not needed exempting, the gate would have passed
while doing nothing, which is the failure mode every one of these test
files exists to prevent. `test_nested_generics` is that bug, written
down.
"""
import contextlib
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    'check_async_skeletons',
    Path(__file__).with_name('check_async_skeletons.py'))
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


def screen(body: str) -> str:
    return 'Widget build(BuildContext c) {\n  return %s;\n}\n' % body


class FindingTheCallSites(unittest.TestCase):
    def test_a_bare_one_is_refused(self):
        code, out = run_on({'a.dart': screen(
            'AsyncView(value: rows, builder: (r) => Text("$r"))')})
        self.assertEqual(code, 1)
        self.assertIn('a.dart:2', out)
        self.assertIn('value: rows', out)

    def test_a_skeleton_passes(self):
        code, _ = run_on({'a.dart': screen(
            'AsyncView(value: rows, skeleton: const ListSkeleton(), '
            'builder: (r) => Text("$r"))')})
        self.assertEqual(code, 0)

    def test_an_explicit_loading_passes(self):
        # Choosing something else IS choosing. `matter_detail_screen`
        # passes a Text for an app bar title, which no skeleton in
        # `core/skeletons.dart` is or should be.
        code, _ = run_on({'a.dart': screen(
            'AsyncView(value: rows, loading: const Text("Matter"), '
            'builder: (r) => Text("$r"))')})
        self.assertEqual(code, 0)

    def test_nested_generics(self):
        # THE BUG. `<[^>]*>` matches `<List<Map<String, dynamic>` and
        # then wants a `(`, finds `>`, and gives up silently -- so a
        # file full of bare call sites reported clean.
        code, out = run_on({'a.dart': screen(
            'AsyncView<List<Map<String, dynamic>>>('
            'value: registers, builder: (r) => Text("$r"))')})
        self.assertEqual(code, 1, 'a nested type argument hid the call site')
        self.assertIn('value: registers', out)

    def test_a_single_type_argument(self):
        code, out = run_on({'a.dart': screen(
            'AsyncView<Map<String, dynamic>?>('
            'value: filing, builder: (f) => Text("$f"))')})
        self.assertEqual(code, 1)
        self.assertIn('value: filing', out)

    def test_a_nested_call_site_is_its_own(self):
        # The pipeline screen waits twice, one inside the other's
        # builder, and the outer one having a skeleton says nothing
        # about the inner one.
        code, out = run_on({'a.dart': screen(
            'AsyncView(value: stages, skeleton: const BoardSkeleton(), '
            'builder: (s) => AsyncView(value: deals, '
            'builder: (d) => Text("$d")))')})
        self.assertEqual(code, 1)
        self.assertIn('value: deals', out)

    def test_the_definition_file_is_not_a_call_site(self):
        # `core/widgets.dart` declares the class, names `skeleton` as a
        # field and extends `State<AsyncView<T>>`. None of that is a
        # screen deciding anything.
        code, _ = run_on({gate.DEFINITION: (
            'class AsyncView<T> extends StatefulWidget {\n'
            '  const AsyncView({this.skeleton});\n'
            '  final Widget? skeleton;\n'
            '  State<AsyncView<T>> createState() => _AsyncViewState<T>();\n'
            '}\n')})
        self.assertEqual(code, 0)

    def test_a_mention_in_prose_is_not_a_call_site(self):
        code, _ = run_on({'a.dart': (
            '/// Prefer AsyncView here. AsyncView, generally.\n'
            'const x = 1;\n')})
        self.assertEqual(code, 0)


class ReadingTheArguments(unittest.TestCase):
    def test_a_comma_inside_the_value_does_not_end_it(self):
        code, out = run_on({'a.dart': screen(
            'AsyncView(value: ref.watch(p((a: 1, b: 2))), '
            'builder: (r) => Text("$r"))')})
        self.assertEqual(code, 1)
        self.assertIn('b: 2', out, 'the value expression was cut at a comma')

    def test_a_skeleton_word_in_a_comment_does_not_count(self):
        # The gate's own error message says "pass `skeleton:`". A gate
        # that read its own advice back out of a comment would clear
        # every screen somebody had thought about and not fixed.
        code, _ = run_on({'a.dart': screen(
            'AsyncView(value: rows, // TODO skeleton: bones here\n'
            '  builder: (r) => Text("$r"))')})
        self.assertEqual(code, 1)

    def test_a_skeleton_word_in_a_string_does_not_count(self):
        code, _ = run_on({'a.dart': screen(
            'AsyncView(value: rows, '
            'builder: (r) => Text("skeleton: soon"))')})
        self.assertEqual(code, 1)

    def test_the_line_number_survives_blanking(self):
        # Blanking replaces in place so offsets hold. A blanker that
        # shortened the source would point at the wrong line, which is
        # worse than no line at all.
        code, out = run_on({'a.dart': (
            '// one\n/* two */\nfinal s = "three";\n'
            + screen('AsyncView(value: rows, builder: (r) => Text("$r"))'))})
        self.assertEqual(code, 1)
        self.assertIn('a.dart:5', out)


class Exemptions(unittest.TestCase):
    def test_an_exemption_clears_its_own_site(self):
        code, _ = run_on(
            {'a.dart': screen(
                'AsyncView(value: registers, builder: (r) => Text("$r"))')},
            exempt={'a.dart::registers': 'a branch, not a shape'})
        self.assertEqual(code, 0)

    def test_an_exemption_does_not_clear_a_second_site(self):
        # Keyed on the value, so a file with two bare waits needs two
        # answers. `till_screen` has four.
        code, out = run_on(
            {'a.dart': screen(
                'AsyncView(value: registers, builder: (r) => AsyncView('
                'value: shift, builder: (s) => Text("$s")))')},
            exempt={'a.dart::registers': 'a branch, not a shape'})
        self.assertEqual(code, 1)
        self.assertIn('value: shift', out)

    def test_a_stale_exemption_is_refused(self):
        code, out = run_on(
            {'a.dart': screen(
                'AsyncView(value: rows, skeleton: const ListSkeleton(), '
                'builder: (r) => Text("$r"))')},
            exempt={'a.dart::rows': 'was a branch once'})
        self.assertEqual(code, 1)
        self.assertIn('no longer an AsyncView there', out)

    def test_an_exemption_for_a_deleted_file_is_refused(self):
        code, out = run_on(
            {'a.dart': 'const x = 1;\n'},
            exempt={'gone.dart::rows': 'a screen that was removed'})
        self.assertEqual(code, 1)
        self.assertIn('gone.dart::rows', out)


class AgainstTheRealTree(unittest.TestCase):
    def test_the_repository_passes(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = gate.main()
        self.assertEqual(code, 0, out.getvalue())

    def test_it_is_looking_at_a_real_number_of_screens(self):
        # A gate whose reader breaks reports a clean sweep over zero
        # files, and zero is the number this is guarding against. The
        # app had 309 call sites when this was written; the bound is
        # loose on purpose, because the count is not the point.
        total = sum(
            1
            for path in gate.LIB.rglob('*.dart')
            if str(path.relative_to(gate.LIB)) != gate.DEFINITION
            for _ in gate.call_sites(path.read_text()))
        self.assertGreater(total, 250, 'the reader has stopped reading')

    def test_every_exemption_names_a_file_that_exists(self):
        for key in gate.EXEMPT:
            rel = key.split('::')[0]
            self.assertTrue((gate.LIB / rel).exists(), rel)

    def test_every_exemption_gives_a_reason(self):
        # A one-word exemption is a shrug with a key on it.
        for key, reason in gate.EXEMPT.items():
            self.assertGreater(len(reason.split()), 12, key)


if __name__ == '__main__':
    unittest.main(verbosity=1)
