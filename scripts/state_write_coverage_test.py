#!/usr/bin/env python3
"""Self-test for scripts/state_write_coverage.py.

    python3 scripts/state_write_coverage_test.py

The survey's whole value is that somebody reads its output and believes
it, so what this pins is mostly the three ways its FIRST RUN was wrong.
Each of those was a false finding, and a tool with four false findings
out of sixteen is a tool that gets ignored on the fifth.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import state_write_coverage as swc  # noqa: E402


class ColumnsWritten(unittest.TestCase):
    def test_a_plain_update(self):
        self.assertEqual(
            swc.written("update public.t set status = 'x', n = 1 where id = p;"),
            {"status", "n"})

    def test_an_alias_is_not_mistaken_for_a_column(self):
        # `update public.t x set ...` -- the alias sits between the
        # table and SET, and a pattern that allowed anything there would
        # swallow the word `set` itself.
        self.assertEqual(
            swc.written("update public.stock_movements sm set gl_entry_id = v\n"
                        " where sm.id = p;"),
            {"gl_entry_id"})

    def test_several_updates_in_one_body(self):
        body = ("update a set one = 1 where x;\n"
                "do_something();\n"
                "update b set two = 2, three = 3 where y;\n")
        self.assertEqual(swc.written(body), {"one", "two", "three"})

    def test_the_boring_columns_are_dropped(self):
        self.assertEqual(
            swc.written("update t set updated_at = now(), status = 'x' where i;"),
            {"status"})

    def test_a_from_clause_ends_the_set_list(self):
        body = ("update t set amount = s.amount\n"
                "  from other s\n"
                " where s.id = t.id;\n")
        self.assertEqual(swc.written(body), {"amount"})

    def test_a_returning_clause_ends_it_too(self):
        body = ("update t set paid = true\n"
                "returning id into v;\n")
        self.assertEqual(swc.written(body), {"paid"})

    def test_a_body_with_no_update_writes_nothing(self):
        self.assertEqual(swc.written("select 1; insert into t values (1);"), set())

    def test_an_equals_in_a_where_is_not_a_written_column(self):
        # The SET list ends at `where`, so `id` must not be collected.
        self.assertEqual(
            swc.written("update t set status = 'x' where id = p_id and n = 2;"),
            {"status"})


class WhatItRefusesToGuess(unittest.TestCase):
    """The three false findings of the first run, pinned as must-not-report."""

    def test_it_follows_the_call_graph_rather_than_grepping_the_name(self):
        # `app.post_goods_received_internal` is reached through its
        # public wrapper. The first run grepped test files for the bare
        # name, found none, and printed "NO TEST FILE CALLS IT" -- about
        # a function `goods_received.sql` exercises line by line.
        rows, by_trigger = swc.survey(["post_goods_received_internal"])
        for name, _, files in rows:
            self.assertTrue(
                files,
                f"{name} was reported with no test file at all; it is "
                "reached through a wrapper and the survey must follow the "
                "call graph to see that.")

    def test_a_trigger_reached_function_is_not_reported_as_uncovered(self):
        # app.pos_deplete_recipes, app.move_document_bundles and
        # app.pos_return_recipes are fired by DML. A zero file count
        # there means "not measurable here", not "not tested" -- which
        # is what mutation_targets.py's own comment says.
        rows, by_trigger = swc.survey([])
        named = {n for n, _, _ in rows}
        fired = {n for n, _, _ in by_trigger}
        self.assertTrue(
            fired, "no trigger-reached mover was recognised at all, so the "
                   "branch that keeps them out of the findings is dead")
        self.assertFalse(
            named & fired,
            "a function appears both as a finding and as trigger-reached")

    def test_every_reported_function_has_at_least_one_file(self):
        rows, _ = swc.survey([])
        for name, cols, files in rows:
            self.assertTrue(
                files,
                f"{name} is reported with no reaching file; either the call "
                "graph missed it or it is trigger-reached, and in both cases "
                "the survey cannot say anything about its columns")

    def test_it_says_in_its_own_output_that_a_finding_is_not_a_defect(self):
        # The docstring records that dispose_fixed_asset's disposal_date
        # and disposal_entry_id are reported and ARE asserted -- through
        # a report function and a journal description, without either
        # column being named. A tool that cannot be calibrated should
        # not be believed, so it has to say so where it is read.
        doc = swc.__doc__ or ""
        self.assertIn("FALSE", doc)
        self.assertIn("point a sweep", doc)


class ItSaysSomethingOverAnEmptyTree(unittest.TestCase):
    def test_no_migrations_is_reported_rather_than_passing(self):
        # check_sweeps_look.py's ratchet: a tool that reports a clean
        # result over an empty source tree is worse than no tool.
        real = swc.mt.MIGRATIONS
        try:
            swc.mt.MIGRATIONS = Path("/nonexistent-migrations")
            self.assertEqual(swc.main(), 1)
        finally:
            swc.mt.MIGRATIONS = real


if __name__ == "__main__":
    unittest.main(verbosity=2)
