#!/usr/bin/env python3
"""Self-test for check_undocumented_writes.py.

The gate is a ratchet that reached the bottom: `BUDGET = 0`, after
`0569`–`0599` wrote two hundred odd comments. A ratchet at zero has
three ways to stop working and none of them looks like a failure:

  * the budget gets RAISED to make a red build go green, which is the
    one thing its own comment forbids;
  * it stops being able to ask the database and reports nothing found,
    which reads exactly like nothing to find;
  * the query drifts so it looks at fewer functions than it claims.

So the assertions below are about the ratchet and the floor, not about
counting.
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
    "cuw", HERE / "check_undocumented_writes.py")
cuw = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(cuw)


class Harness(unittest.TestCase):

    def gate(self, names, budget=None, seen=None):
        """Run the real `run()` over a fed list instead of a cluster.

        `candidate_writes` is stubbed as well as `undocumented`. It is
        the DENOMINATOR -- how many writes were in scope at all -- and
        `run()` now refuses below a floor on it, because the query
        succeeding over an empty schema used to report that every write
        carries a comment. The earlier control here covered psql
        FAILING, which is a different hole.

        `seen=None` feeds a healthy denominator so the cases below
        exercise what they are about; `TheDenominator` feeds it directly.
        """
        real_q, real_b = cuw.undocumented, cuw.BUDGET
        real_c = cuw.candidate_writes
        cuw.undocumented = lambda db: names
        cuw.candidate_writes = lambda db: (
            cuw.LEAST if seen is None else seen)
        if budget is not None:
            cuw.BUDGET = budget
        out, err = io.StringIO(), io.StringIO()
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = cuw.run("db")
        finally:
            cuw.undocumented, cuw.BUDGET = real_q, real_b
            cuw.candidate_writes = real_c
        return code, out.getvalue() + err.getvalue()


class TheRatchetBothWays(Harness):

    def test_nothing_undocumented_at_zero_passes(self):
        code, said = self.gate([], budget=0)
        self.assertEqual(code, 0, said)
        self.assertIn("carries a `comment on function`", said)

    def test_one_new_undocumented_write_fails_and_names_it(self):
        code, said = self.gate(["void_sales_document(p_id uuid)"], budget=0)
        self.assertEqual(code, 1)
        self.assertIn("void_sales_document(p_id uuid)", said)
        self.assertIn("budget is 0", said)

    def test_fewer_than_the_budget_also_fails(self):
        """The other direction, and the one that keeps the number honest:
        ground gained without lowering the budget is ground that can be
        given back silently."""
        code, said = self.gate([], budget=3)
        self.assertEqual(code, 1)
        self.assertIn("Lower BUDGET", said)

    def test_exactly_at_a_nonzero_budget_passes(self):
        code, said = self.gate(["a(x int)", "b(y int)"], budget=2)
        self.assertEqual(code, 0, said)
        self.assertIn("at the budget", said)

    def test_a_long_list_is_truncated_and_says_how_many_more(self):
        code, said = self.gate(["f%02d(x int)" % i for i in range(25)],
                               budget=0)
        self.assertEqual(code, 1)
        self.assertIn("f00(x int)", said)
        self.assertIn("and 5 more", said)
        self.assertNotIn("f24(x int)", said)


class ADatabaseItCannotAskIsNotACleanSurface(Harness):

    def test_a_failed_query_returns_2_rather_than_0(self):
        """`undocumented` returns None when psql fails. Reporting that as
        zero undocumented writes is how a gate goes quiet for a reason
        that has nothing to do with the schema."""
        code, said = self.gate(None, budget=0)
        self.assertEqual(code, 2, said)
        self.assertNotIn("carries a `comment on function`", said)


class TheFloorIsNotNegotiable(unittest.TestCase):

    def test_the_budget_in_the_file_is_zero(self):
        """`0599` took it to zero and the comment above it says never
        raise. A raise is the easy way to make a red build green, so it
        fails here by name."""
        self.assertEqual(cuw.BUDGET, 0)

    def test_the_file_still_says_not_to_raise_it(self):
        text = (HERE / "check_undocumented_writes.py").read_text()
        self.assertIn("Never raise it.", text)


class WhatTheQueryLooksAt(unittest.TestCase):
    """The three properties the docstring claims for the surface.

    Asserted on NON-COMMENT lines: `QUERY` explains itself in `--` lines
    that contain the very words being looked for, so a plain substring
    check passes on a query that only mentions them.
    """

    def setUp(self):
        self.sql = " ".join(
            line.split("--", 1)[0] for line in cuw.QUERY.splitlines())

    def test_only_volatile_functions(self):
        """A read somebody misunderstands returns the wrong rows; a write
        somebody misunderstands moves money."""
        self.assertRegex(self.sql, r"provolatile\s*=\s*'v'")

    def test_only_what_a_signed_in_user_can_execute(self):
        self.assertRegex(
            self.sql, r"has_function_privilege\(\s*'authenticated'")

    def test_extension_owned_functions_are_excluded(self):
        """`citext`, `btree_gist` and `pg_trgm` install into `public` and
        carry EXECUTE to PUBLIC. Reachable, and not ours to document.

        The NEGATION is the assertion. A mutant that changed
        `and not exists (select 1 from pg_depend ...)` to
        `and true or exists (...)` kept every word this test first looked
        for -- `pg_depend`, `deptype = 'e'` -- and survived. Naming the
        tables a clause mentions says nothing about what it does with
        them."""
        self.assertRegex(
            self.sql,
            r"not\s+exists\s*\(\s*select\s+1\s+from\s+pg_depend")
        self.assertRegex(self.sql, r"deptype\s*=\s*'e'")
        self.assertNotRegex(self.sql, r"true\s+or\s+exists")

    def test_it_asks_for_the_identity_arguments(self):
        """A name alone cannot identify an overload, and this schema has
        36 of them."""
        self.assertIn("pg_get_function_identity_arguments", self.sql)

    def test_the_comment_test_is_for_blank_as_well_as_null(self):
        """A `comment on function f is ''` is not a description."""
        self.assertRegex(self.sql, r"btrim\(d\.description\)")



class TheDenominator(Harness):
    """The hole the earlier control did not cover.

    `undocumented(db)` returning None on a psql failure was added first
    and shuts one door: the connection breaking. A query that SUCCEEDS
    over a schema with no functions in it is a different door, and this
    gate went through it -- found by pointing every database-backed gate
    at a database that exists and is empty.
    """

    def test_an_empty_schema_is_refused(self):
        code, said = self.gate([], budget=0, seen=0)
        self.assertEqual(code, 2, said)
        self.assertIn("found 0 write(s)", said)
        self.assertIn("every write carries a comment", said)

    def test_a_denominator_below_the_floor_is_refused(self):
        code, said = self.gate([], budget=0, seen=cuw.LEAST - 1)
        self.assertEqual(code, 2, said)

    def test_a_healthy_denominator_passes(self):
        code, said = self.gate([], budget=0, seen=cuw.LEAST)
        self.assertEqual(code, 0, said)

    def test_psql_failing_on_the_census_is_also_refused(self):
        """The connection half, which must keep working: a census that
        cannot be taken is not a census of zero, and `None` has to be
        refused rather than compared."""
        import contextlib
        import io
        real_q, real_c = cuw.undocumented, cuw.candidate_writes
        try:
            cuw.undocumented = lambda db: []
            cuw.candidate_writes = lambda db: None
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), \
                    contextlib.redirect_stderr(err):
                code = cuw.run("db")
            said = out.getvalue() + err.getvalue()
        finally:
            cuw.undocumented, cuw.candidate_writes = real_q, real_c
        self.assertEqual(code, 2, said)
        self.assertIn("found no write(s)", said)

    def test_the_floor_is_below_the_census_but_not_zero(self):
        self.assertGreater(cuw.LEAST, 0)
        self.assertLess(cuw.LEAST, 525)


if __name__ == "__main__":
    unittest.main(verbosity=2)
