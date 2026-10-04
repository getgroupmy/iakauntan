#!/usr/bin/env python3
"""Self-test for check_surface_size.py.

The gate refuses `tester.binding.setSurfaceSize` in favour of
`tester.view.physicalSize`, because the first moves the render surface
and leaves `MediaQuery` reporting 800x600 -- so a test asserting the
narrow layout is asserting against a layout that is not on the screen,
and it passes, because the widgets it names are there.

Two things here are deliberately not inferred from the live tree:

  * the COMMENT STRIPPING. The five files that name the trap write it in
    prose without a paren, so a passing sweep says nothing about whether
    a commented-out CALL would be flagged. Covered directly below. My
    first attempt at this used prose as the sample and reported 0 raw
    matches -- the sample never hit the pattern, so it proved nothing in
    either direction.
  * the CANARY, which cannot fire while the right call is in 106 files.

One mutant is EQUIVALENT and is left alive on purpose: widening `TRAP`
from `setSurfaceSize\s*\(` to the bare name `setSurfaceSize\b`. In this
tree it changes nothing -- the only places that write the bare name are
comments, which are stripped either way -- and in code a reference to
the method without calling it is arguably worth flagging too. `mutate.py`
is explicit that a survivor is either a missing assertion or a change
that cannot be observed, and this is the second kind.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import pathlib
import re
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "css", HERE / "check_surface_size.py")
css = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(css)


def gate():
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = css.run()
    return code, out.getvalue() + err.getvalue()


class TheLiveTree(unittest.TestCase):

    def test_no_test_resizes_the_surface_without_media_query(self):
        code, said = gate()
        self.assertEqual(code, 0, said)

    def test_it_reads_the_whole_test_tree(self):
        files, right = css.census()
        self.assertGreater(files, 400, "app/test has 457 files")
        self.assertGreaterEqual(files, css.LEAST_FILES)

    def test_the_right_call_is_in_wide_use(self):
        """The canary's subject. If this ever reaches zero the gate is
        blind, not satisfied."""
        _, right = css.census()
        self.assertGreater(right, 50)

    def test_the_allowance_list_is_empty(self):
        """A reviewed list at zero beats a convention. Asserted, because
        an empty dict satisfies every per-entry check below it."""
        self.assertEqual(css.ALLOWED, {})


class ACommentIsNotACall(unittest.TestCase):

    def flagged(self, text):
        return len(css.TRAP.findall(css.without_comments(text)))

    def test_a_commented_out_call_is_not_flagged(self):
        text = "  // await tester.binding.setSurfaceSize(const Size(1, 1));\n"
        self.assertEqual(len(css.TRAP.findall(text)), 1,
                         "the sample must hit the pattern before stripping, "
                         "or it proves nothing either way")
        self.assertEqual(self.flagged(text), 0)

    def test_a_doc_comment_with_the_call_form_is_not_flagged(self):
        text = "  /// `tester.binding.setSurfaceSize(const Size(9, 9))` lies.\n"
        self.assertEqual(len(css.TRAP.findall(text)), 1)
        self.assertEqual(self.flagged(text), 0)

    def test_a_real_call_is_flagged(self):
        text = "  await tester.binding.setSurfaceSize(const Size(1, 1));\n"
        self.assertEqual(self.flagged(text), 1)

    def test_code_after_a_comment_on_an_earlier_line_survives(self):
        text = ("  // not setSurfaceSize\n"
                "  await tester.binding.setSurfaceSize(const Size(1, 1));\n")
        self.assertEqual(self.flagged(text), 1)

    def test_the_right_call_is_not_counted_from_a_comment_either(self):
        text = "  /// use tester.view.physicalSize here one day\n"
        self.assertEqual(len(css.RIGHT.findall(css.without_comments(text))), 0)


class ThroughTheRealFunctions(unittest.TestCase):
    """The same cases as above, but driven through `offenders()` and
    `census()` over a fed tree.

    `ACommentIsNotACall` calls `without_comments` and `TRAP` directly,
    so it passes whether or not the SWEEP uses them -- two mutants that
    stripped nothing inside `offenders()` and `census()` survived it.
    Asserting a helper works is not asserting the caller calls it.
    """

    def tree(self, **files):
        import tempfile
        tmp = tempfile.mkdtemp()
        for name, body in files.items():
            (pathlib.Path(tmp) / (name + ".dart")).write_text(body)
        real = css.TESTS
        css.TESTS = pathlib.Path(tmp)
        self.addCleanup(lambda: setattr(css, "TESTS", real))

    def test_offenders_ignores_a_commented_out_call(self):
        self.tree(a="// await tester.binding.setSurfaceSize(const Size(1,1));\n")
        self.assertEqual(css.offenders(), [])

    def test_offenders_finds_a_real_call(self):
        self.tree(a="await tester.binding.setSurfaceSize(const Size(1,1));\n")
        found = css.offenders()
        self.assertEqual(len(found), 1, found)
        self.assertIn("a.dart", found[0])

    def test_offenders_reports_the_line_number(self):
        self.tree(a="void x() {}\n\n"
                    "await tester.binding.setSurfaceSize(const Size(1,1));\n")
        self.assertTrue(css.offenders()[0].endswith(":3"), css.offenders())

    def test_the_census_does_not_count_the_right_call_from_a_comment(self):
        self.tree(a="/// one day: tester.view.physicalSize\n")
        files, right = css.census()
        self.assertEqual(files, 1)
        self.assertEqual(right, 0, "a comment is not a use")

    def test_the_census_counts_a_real_use(self):
        self.tree(a="tester.view.physicalSize = const Size(1,1);\n")
        self.assertEqual(css.census(), (1, 1))


class TheControlsOnTheSweep(unittest.TestCase):

    def test_an_empty_tree_is_refused(self):
        import tempfile
        real = css.TESTS
        with tempfile.TemporaryDirectory() as tmp:
            css.TESTS = pathlib.Path(tmp)
            try:
                code, said = gate()
            finally:
                css.TESTS = real
        self.assertEqual(code, 2, said)
        self.assertIn("nothing to read", said)

    def test_the_canary_fires_when_the_right_call_is_renamed(self):
        real = css.RIGHT
        try:
            css.RIGHT = re.compile(r"\btester\.view\.physicalSizeV2\b")
            code, said = gate()
        finally:
            css.RIGHT = real
        self.assertEqual(code, 2, said)
        self.assertIn("blind rather than satisfied", said)
        self.assertIn("not a defect in the tests", said)

    def test_the_failure_names_the_replacement(self):
        """A red build with no remedy gets the gate deleted."""
        real = css.TRAP
        try:
            css.TRAP = re.compile(r"\btester\.view\.physicalSize\b")
            code, said = gate()
        finally:
            css.TRAP = real
        self.assertEqual(code, 1, said)
        self.assertIn("tester.view.physicalSize = const Size(393, 852);", said)
        self.assertIn("docs/widget-tests.md", said)


if __name__ == "__main__":
    unittest.main(verbosity=2)
