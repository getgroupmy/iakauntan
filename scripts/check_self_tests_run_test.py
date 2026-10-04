#!/usr/bin/env python3
"""The self-test-completeness gate's own assertions.

    python3 scripts/check_self_tests_run_test.py

The joke is deliberate: this file is the thing its subject checks for, so
if it ever stops being named in `ci.yml` its own gate says so.

Everything is fed, so the failure MESSAGES are exercised. A gate whose
only tested path is the passing one tells you nothing about what it says
when it fires, and what it says is the whole remedy.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import pathlib
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "cst", HERE / "check_self_tests_run.py")
cst = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(cst)


def said(problems) -> str:
    return "\n".join(problems)


def enough(n: int = 30) -> set[str]:
    """A plausible set of self-tests, above the floor."""
    return {"check_%02d_test.py" % i for i in range(n)}


def runs(names) -> str:
    return "\n".join("        run: python3 scripts/%s" % n for n in names)


class TheLiveRepository(unittest.TestCase):

    def test_it_passes_as_shipped(self):
        out, _found, _named = cst.problems()
        self.assertEqual(out, [], said(out))

    def test_this_very_file_is_one_of_them(self):
        """If it is not, the gate is checking a set this file is not in --
        and the gate's own self-test going unrun is exactly the hole."""
        on_disk = {p.name for p in cst.SCRIPTS.glob("*_test.py")}
        self.assertIn(pathlib.Path(__file__).name, on_disk)

    def test_and_ci_runs_it(self):
        workflow = cst.WORKFLOW.read_text()
        self.assertIn("python3 scripts/check_self_tests_run_test.py",
                      workflow)

    def test_there_are_more_than_the_floor(self):
        on_disk = {p.name for p in cst.SCRIPTS.glob("*_test.py")}
        self.assertGreaterEqual(len(on_disk), cst.LEAST)

    def test_the_exemption_list_is_empty_and_that_is_a_claim(self):
        self.assertEqual(cst.EXEMPT, {})


class BothDirections(unittest.TestCase):

    def test_a_self_test_ci_never_runs_is_reported(self):
        on_disk = enough() | {"check_brand_new_test.py"}
        out, _f, _n = cst.problems(on_disk=on_disk,
                                   workflow=runs(sorted(enough())))
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("check_brand_new_test.py", out[0])
        self.assertIn("never run by CI", out[0])
        # The remedy names where to put it, not just that it is missing.
        self.assertIn("beside the gate it tests", out[0])

    def test_a_workflow_line_with_no_file_is_reported(self):
        out, _f, _n = cst.problems(
            on_disk=enough(),
            workflow=runs(sorted(enough()) + ["check_renamed_test.py"]))
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("check_renamed_test.py", out[0])
        self.assertIn("rename moved one end only", out[0])

    def test_both_at_once(self):
        out, _f, _n = cst.problems(
            on_disk=enough() | {"check_added_test.py"},
            workflow=runs(sorted(enough()) + ["check_gone_test.py"]))
        self.assertEqual(len(out), 2, said(out))
        self.assertIn("check_added_test.py", said(out))
        self.assertIn("check_gone_test.py", said(out))


class ProseIsNotAStep(unittest.TestCase):
    """ci.yml is full of comments naming scripts, this gate among them."""

    def test_a_name_in_a_comment_does_not_count_as_run(self):
        workflow = (runs(sorted(enough()))
                    + "\n      # python3 scripts/check_commented_test.py\n")
        out, _f, _n = cst.problems(
            on_disk=enough() | {"check_commented_test.py"},
            workflow=workflow)
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("check_commented_test.py", out[0])

    def test_an_indented_comment_too(self):
        workflow = (runs(sorted(enough()))
                    + "\n          #   python3 scripts/check_c_test.py\n")
        out, _f, _n = cst.problems(on_disk=enough() | {"check_c_test.py"},
                                   workflow=workflow)
        self.assertEqual(len(out), 1, said(out))

    def test_but_a_real_line_with_a_trailing_comment_does_count(self):
        # Stripping WHOLE-LINE comments only. A step that runs the thing
        # and then says why on the same line is still running it.
        workflow = runs(sorted(enough())) + (
            "\n        run: python3 scripts/check_c_test.py  # and why\n")
        out, _f, _n = cst.problems(on_disk=enough() | {"check_c_test.py"},
                                   workflow=workflow)
        self.assertEqual(out, [], said(out))

    def test_a_dash_B_invocation_counts(self):
        workflow = runs(sorted(enough())) + (
            "\n        run: python3 -B scripts/check_c_test.py\n")
        out, _f, _n = cst.problems(on_disk=enough() | {"check_c_test.py"},
                                   workflow=workflow)
        self.assertEqual(out, [], said(out))


class ItMustNotPassOverNothing(unittest.TestCase):
    """The floor, and the two ways this gate could stop looking."""

    def test_an_empty_scripts_directory_is_refused(self):
        out, found, _n = cst.problems(on_disk=set(), workflow=runs([]))
        self.assertEqual(found, 0)
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("could not look", out[0].replace("nothing to look at",
                                                       "could not look"))

    def test_a_handful_is_refused_too_because_there_were_37(self):
        out, _f, _n = cst.problems(on_disk={"check_one_test.py"},
                                   workflow=runs([]))
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("found only 1", out[0])
        # And it stops there rather than listing the one as missing: a
        # floor failure is about the sweep, not about the code.
        self.assertNotIn("never run by CI", said(out))

    def test_a_missing_workflow_is_refused_rather_than_ignored(self):
        saved = cst.WORKFLOW
        cst.WORKFLOW = pathlib.Path("/nonexistent/ci.yml")
        try:
            out, _f, _n = cst.problems(on_disk=enough())
        finally:
            cst.WORKFLOW = saved
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("could not look", out[0])

    def test_a_missing_scripts_directory_too(self):
        saved = cst.SCRIPTS
        cst.SCRIPTS = pathlib.Path("/nonexistent/scripts")
        try:
            out, _f, _n = cst.problems()
        finally:
            cst.SCRIPTS = saved
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("not a directory", out[0])


class ExemptionsGoStale(unittest.TestCase):

    def test_an_exempted_self_test_is_allowed_to_be_unrun(self):
        saved = cst.EXEMPT
        cst.EXEMPT = {"check_parked_test.py": "needs a device"}
        try:
            out, _f, _n = cst.problems(
                on_disk=enough() | {"check_parked_test.py"},
                workflow=runs(sorted(enough())))
        finally:
            cst.EXEMPT = saved
        self.assertEqual(out, [], said(out))

    def test_an_exemption_for_one_ci_does_run_is_refused(self):
        saved = cst.EXEMPT
        cst.EXEMPT = {"check_parked_test.py": "needs a device"}
        try:
            out, _f, _n = cst.problems(
                on_disk=enough() | {"check_parked_test.py"},
                workflow=runs(sorted(enough()) + ["check_parked_test.py"]))
        finally:
            cst.EXEMPT = saved
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("Drop the exemption", out[0])

    def test_an_exemption_for_one_that_is_gone_is_refused(self):
        saved = cst.EXEMPT
        cst.EXEMPT = {"check_deleted_test.py": "needs a device"}
        try:
            out, _f, _n = cst.problems(on_disk=enough(),
                                       workflow=runs(sorted(enough())))
        finally:
            cst.EXEMPT = saved
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("does not exist", out[0])


class WhatItSaysWhenItPasses(unittest.TestCase):

    def test_the_success_line_carries_the_number(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cst.main()
        self.assertEqual(code, 0, out.getvalue())
        on_disk = len({p.name for p in cst.SCRIPTS.glob("*_test.py")})
        self.assertIn("all %d self-tests" % on_disk, out.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
