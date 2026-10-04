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


def fed(**kw):
    """`problems` over made-up inputs, with the `--self-test` set empty.

    Every argument has to be fed or none is. The flag check reads the real
    `scripts/` directory by default, so a case that feeds a made-up
    workflow and leaves that alone reports the REAL tree's facts into a
    made-up world -- three extra findings on every assertion below, which
    is how this helper came to exist.
    """
    kw.setdefault("flagged", set())
    return cst.problems(**kw)[0]


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
        out = fed(on_disk=on_disk,
                                   workflow=runs(sorted(enough())))
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("check_brand_new_test.py", out[0])
        self.assertIn("never run by CI", out[0])
        # The remedy names where to put it, not just that it is missing.
        self.assertIn("beside the gate it tests", out[0])

    def test_a_workflow_line_with_no_file_is_reported(self):
        out = fed(
            on_disk=enough(),
            workflow=runs(sorted(enough()) + ["check_renamed_test.py"]))
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("check_renamed_test.py", out[0])
        self.assertIn("rename moved one end only", out[0])

    def test_both_at_once(self):
        out = fed(
            on_disk=enough() | {"check_added_test.py"},
            workflow=runs(sorted(enough()) + ["check_gone_test.py"]))
        self.assertEqual(len(out), 2, said(out))
        self.assertIn("check_added_test.py", said(out))
        self.assertIn("check_gone_test.py", said(out))


class TheOtherConvention(unittest.TestCase):
    """`schema_drift.py` keeps its control behind a `--self-test` flag
    rather than in a separate file, because what it tests is a normaliser
    aggressive enough to drop everything and report a clean comparison --
    a control like that belongs beside the filter. This gate's NAME claims
    every self-test, and it covered one convention when it was written.

    These call `cst.problems` directly rather than `fed`: the flag set is
    what is under test, so it must be the real one.
    """

    def setUp(self):
        self.on_disk = {p.name for p in cst.SCRIPTS.glob("*_test.py")}
        self.workflow = cst.WORKFLOW.read_text()

    def test_the_real_tree_runs_the_flag(self):
        self.assertIn("scripts/schema_drift.py --self-test", self.workflow)
        self.assertIn("schema_drift.py", cst.flag_scripts())
        out, _f, _n = cst.problems()
        self.assertEqual(out, [], said(out))

    def test_one_that_answers_the_flag_and_is_not_run_is_reported(self):
        out, _f, _n = cst.problems(
            on_disk=self.on_disk,
            workflow=self.workflow.replace(
                "scripts/schema_drift.py --self-test", "true"))
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("schema_drift.py", out[0])
        self.assertIn("written and never run", out[0])

    def test_the_flag_named_only_in_a_comment_does_not_count(self):
        out, _f, _n = cst.problems(
            on_disk=self.on_disk,
            workflow=self.workflow.replace(
                "          python3 scripts/schema_drift.py --self-test",
                "          # python3 scripts/schema_drift.py --self-test"))
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("schema_drift.py", out[0])

    def test_running_the_flag_on_one_that_ignores_it_is_reported(self):
        out, _f, _n = cst.problems(
            on_disk=self.on_disk,
            workflow=self.workflow
            + "\n        run: python3 scripts/check_xlsx.py --self-test\n")
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("does not answer to the flag", out[0])

    def test_the_flag_is_found_in_the_TREE_not_in_the_text(self):
        # A comparison in the syntax tree cannot be satisfied by prose,
        # which is the whole reason this is parsed rather than grepped.
        self.assertTrue(cst.answers_to_the_flag(
            'def main(argv):\n'
            '    if argv[1] == "--self-test":\n'
            '        pass\n'))
        # Either side of the comparison, and however the argument is
        # reached: the anchor is the constant, not the spelling of argv.
        self.assertTrue(cst.answers_to_the_flag(
            'if "--self-test" == sys.argv[-1]:\n    pass\n'))

    def test_prose_naming_the_flag_does_not_answer_to_it(self):
        # The first version of this scan was a regex over the text, and it
        # matched -- in order -- this file, where the comparison is a
        # FIXTURE, and then the gate's own docstring, where it is an
        # EXAMPLE in the sentence explaining the first mistake. Twice in
        # five minutes, in the file about it.
        self.assertFalse(cst.answers_to_the_flag(
            '"""Run it with --self-test to check the normaliser."""\n'))
        self.assertFalse(cst.answers_to_the_flag(
            '# if argv[1] == "--self-test": is how that is spelled\n'))
        self.assertFalse(cst.answers_to_the_flag(
            'DOC = \'if argv[1] == "--self-test":\'\n'))

    def test_a_file_that_does_not_parse_is_not_claimed_either_way(self):
        self.assertFalse(cst.answers_to_the_flag("def ???:\n"))

    def test_neither_test_files_nor_the_gate_itself_are_scanned(self):
        # THIS file holds the comparison as a fixture above, and the gate
        # holds it in a docstring. Both would be reported as scripts whose
        # self-test nobody runs.
        found = cst.flag_scripts()
        self.assertNotIn(pathlib.Path(__file__).name, found)
        self.assertNotIn("check_self_tests_run.py", found)
        self.assertEqual(found, {"schema_drift.py"})


class ProseIsNotAStep(unittest.TestCase):
    """ci.yml is full of comments naming scripts, this gate among them."""

    def test_a_name_in_a_comment_does_not_count_as_run(self):
        workflow = (runs(sorted(enough()))
                    + "\n      # python3 scripts/check_commented_test.py\n")
        out = fed(
            on_disk=enough() | {"check_commented_test.py"},
            workflow=workflow)
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("check_commented_test.py", out[0])

    def test_an_indented_comment_too(self):
        workflow = (runs(sorted(enough()))
                    + "\n          #   python3 scripts/check_c_test.py\n")
        out = fed(on_disk=enough() | {"check_c_test.py"},
                                   workflow=workflow)
        self.assertEqual(len(out), 1, said(out))

    def test_but_a_real_line_with_a_trailing_comment_does_count(self):
        # Stripping WHOLE-LINE comments only. A step that runs the thing
        # and then says why on the same line is still running it.
        workflow = runs(sorted(enough())) + (
            "\n        run: python3 scripts/check_c_test.py  # and why\n")
        out = fed(on_disk=enough() | {"check_c_test.py"},
                                   workflow=workflow)
        self.assertEqual(out, [], said(out))

    def test_a_dash_B_invocation_counts(self):
        workflow = runs(sorted(enough())) + (
            "\n        run: python3 -B scripts/check_c_test.py\n")
        out = fed(on_disk=enough() | {"check_c_test.py"},
                                   workflow=workflow)
        self.assertEqual(out, [], said(out))


class ItMustNotPassOverNothing(unittest.TestCase):
    """The floor, and the two ways this gate could stop looking."""

    def test_an_empty_scripts_directory_is_refused(self):
        out = fed(on_disk=set(), workflow=runs([]))
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("could not look", out[0].replace("nothing to look at",
                                                       "could not look"))

    def test_a_handful_is_refused_too_because_there_were_37(self):
        out = fed(on_disk={"check_one_test.py"},
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
            out = fed(on_disk=enough())
        finally:
            cst.WORKFLOW = saved
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("could not look", out[0])

    def test_a_missing_scripts_directory_too(self):
        saved = cst.SCRIPTS
        cst.SCRIPTS = pathlib.Path("/nonexistent/scripts")
        try:
            out = fed()
        finally:
            cst.SCRIPTS = saved
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("not a directory", out[0])


class ExemptionsGoStale(unittest.TestCase):

    def test_an_exempted_self_test_is_allowed_to_be_unrun(self):
        saved = cst.EXEMPT
        cst.EXEMPT = {"check_parked_test.py": "needs a device"}
        try:
            out = fed(
                on_disk=enough() | {"check_parked_test.py"},
                workflow=runs(sorted(enough())))
        finally:
            cst.EXEMPT = saved
        self.assertEqual(out, [], said(out))

    def test_an_exemption_for_one_ci_does_run_is_refused(self):
        saved = cst.EXEMPT
        cst.EXEMPT = {"check_parked_test.py": "needs a device"}
        try:
            out = fed(
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
            out = fed(on_disk=enough(),
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
