#!/usr/bin/env python3
"""Self-test for check_overload_assertions.py.

The gate it tests exists because three assertions were broken by an
overload one tranche at a time. These assertions are what stop the gate
from being the fourth thing in that chain.
"""

from __future__ import annotations

import importlib.util
import pathlib
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "coa", HERE / "check_overload_assertions.py")
coa = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(coa)


class FindingByNameAssertions(unittest.TestCase):

    def files(self, **files: str) -> pathlib.Path:
        tmp = pathlib.Path(tempfile.mkdtemp())
        for name, body in files.items():
            (tmp / name).write_text(body)
        return tmp

    def test_a_plain_equality_is_found(self):
        tests = self.files(**{"a.sql": "where p.proname = 'email_document'"})
        self.assertEqual(coa.asserted_by_name(tests),
                         {"email_document": ["a.sql"]})

    def test_whitespace_around_the_equals_does_not_hide_it(self):
        tests = self.files(**{"a.sql": "proname='x_y'  and proname  =  'z'"})
        self.assertEqual(set(coa.asserted_by_name(tests)), {"x_y", "z"})

    def test_two_files_asserting_one_name_are_both_reported(self):
        tests = self.files(**{"a.sql": "proname = 'f'", "b.sql": "proname = 'f'"})
        self.assertEqual(sorted(coa.asserted_by_name(tests)["f"]),
                         ["a.sql", "b.sql"])

    def test_a_name_matched_some_other_way_is_not_found(self):
        """Deliberately narrow. `proname in (...)` and `proname like` are
        not matched, because the gate's job is to be certain about what it
        reports rather than to guess at every spelling."""
        tests = self.files(**{"a.sql": "where p.proname in ('f', 'g')"})
        self.assertEqual(coa.asserted_by_name(tests), {})


class TheRatchet(unittest.TestCase):

    def files(self, body: str) -> pathlib.Path:
        tmp = pathlib.Path(tempfile.mkdtemp())
        (tmp / "a.sql").write_text(body)
        return tmp

    def run_with(self, keyed, body, reviewed):
        tests = self.files(body)
        original = coa.keyed
        coa.keyed = lambda db: set(keyed)
        try:
            return coa.run("ignored", tests, reviewed)
        finally:
            coa.keyed = original

    def test_a_new_overload_on_a_named_function_fails(self):
        """The bug this gate exists after, three times over."""
        self.assertEqual(
            self.run_with(["submit_leave_request"],
                          "proname = 'submit_leave_request'", {}), 1)

    def test_and_passes_once_the_assertion_has_been_read(self):
        self.assertEqual(
            self.run_with(["submit_leave_request"],
                          "proname = 'submit_leave_request'",
                          {"submit_leave_request": "made two-form aware"}), 0)

    def test_a_keyed_function_nobody_asserts_by_name_is_not_a_problem(self):
        self.assertEqual(
            self.run_with(["settle_deposit"], "proname = 'something_else'",
                          {}), 0)

    def test_a_named_function_with_no_overload_is_not_a_problem(self):
        self.assertEqual(
            self.run_with([], "proname = 'report_who_is_away'", {}), 0)

    def test_a_reviewed_entry_that_no_longer_applies_fails(self):
        """An excuse left behind. The same failure mode the `unique:` and
        `state:` verdicts in check_write_idempotency.py have a check for:
        a list of exemptions nobody prunes stops being evidence."""
        self.assertEqual(
            self.run_with([], "proname = 'nothing'",
                          {"email_document": "stale"}), 1)

    def test_the_real_lists_agree(self):
        """Against the repository itself: every REVIEWED name really is
        asserted by name in supabase/tests/."""
        found = coa.asserted_by_name()
        for name in coa.REVIEWED:
            self.assertIn(name, found, name)


if __name__ == "__main__":
    unittest.main(verbosity=2)
