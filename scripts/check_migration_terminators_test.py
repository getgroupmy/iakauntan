#!/usr/bin/env python3
"""Tests for check_migration_terminators.py.

The first version reported NINE migrations and all nine were correct
code: their last line is a `comment on ...` whose prose contains a
double dash, and the naive comment stripper threw away the closing quote
and the semicolon with it. Those shapes are pinned as must-not-report,
because a gate that flags correct code is a gate somebody turns off, and
the mistake is easy to reintroduce while "simplifying" the stripper.
"""
from __future__ import annotations

import pathlib
import unittest

import check_migration_terminators as gate


class DropInlineComment(unittest.TestCase):
    def test_a_plain_trailing_comment_goes(self):
        self.assertEqual(gate.drop_inline_comment("select 1;  -- note"),
                         "select 1;")

    def test_a_double_dash_inside_a_literal_stays(self):
        self.assertEqual(
            gate.drop_inline_comment("comment on f is 'kept -- why';"),
            "comment on f is 'kept -- why';")

    def test_an_escaped_quote_does_not_end_the_literal(self):
        self.assertEqual(
            gate.drop_inline_comment("select 'it''s -- fine';"),
            "select 'it''s -- fine';")

    def test_a_comment_after_a_literal_still_goes(self):
        self.assertEqual(
            gate.drop_inline_comment("select 'a'; -- and a note"),
            "select 'a';")

    def test_a_line_that_is_only_a_comment_becomes_empty(self):
        self.assertEqual(gate.drop_inline_comment("-- just prose"), "")


class Faults(unittest.TestCase):
    def test_a_terminated_statement_is_clean(self):
        self.assertEqual(gate.faults("create table x (a int);\n"), [])

    def test_a_missing_terminator_is_reported(self):
        self.assertTrue(any("not terminated" in f
                            for f in gate.faults("create table x (a int)\n")))

    def test_a_function_body_without_its_semicolon_is_reported(self):
        # 0743's actual first version, reduced.
        text = ("create function f() returns int as $fn$ begin return 1; "
                "end $fn$\n")
        self.assertTrue(any("not terminated" in f for f in gate.faults(text)))

    def test_the_same_body_with_its_semicolon_is_clean(self):
        text = ("create function f() returns int as $fn$ begin return 1; "
                "end $fn$;\n")
        self.assertEqual(gate.faults(text), [])

    def test_an_unclosed_body_is_reported(self):
        self.assertTrue(any("left open" in f for f in gate.faults(
            "create function f() returns int as $fn$ begin\n")))

    def test_a_tag_discussed_only_in_prose_is_not_an_open_body(self):
        # 0165 and others mention $$ in a comment; counting it would
        # read as an unclosed body.
        self.assertEqual(gate.faults("-- the body is quoted $$ here\n"
                                     "select 1;\n"), [])

    def test_trailing_comment_lines_do_not_hide_the_terminator(self):
        self.assertEqual(gate.faults("select 1;\n\n-- a closing note\n"), [])

    def test_trailing_comments_do_not_excuse_a_missing_one(self):
        self.assertTrue(any("not terminated" in f for f in gate.faults(
            "select 1\n\n-- a closing note\n")))

    def test_a_terminator_on_its_own_line_counts(self):
        # pg_get_functiondef restatements put it there; 0504 is one.
        self.assertEqual(gate.faults(
            "create function f() returns int as $fn$ begin return 1; "
            "end\n$fn$\n;\n"), [])

    def test_a_file_with_no_sql_is_reported(self):
        self.assertTrue(any("no SQL" in f
                            for f in gate.faults("-- only prose\n")))


class Repository(unittest.TestCase):
    def test_head_is_clean(self):
        self.assertEqual(gate.offenders(), [])

    def test_it_read_a_plausible_number_of_migrations(self):
        files = sorted(gate.MIGRATIONS.glob("*.sql"))
        self.assertGreater(len(files), gate.LEAST_MIGRATIONS)

    def test_0540_is_the_only_allowance_and_it_still_needs_one(self):
        self.assertEqual(set(gate.ALLOWED),
                         {'0540_a_counter_sale_of_dated_stock.sql'})
        path = gate.MIGRATIONS / '0540_a_counter_sale_of_dated_stock.sql'
        self.assertTrue(gate.faults(path.read_text()),
                        '0540 is clean now; remove it from ALLOWED')

    def test_the_allowance_is_doing_work_rather_than_decorating(self):
        # Two halves, and both are needed: the file IS at fault, and
        # `offenders` skips it anyway. Asserting only the first would
        # pass even if the allowlist were ignored; only the second, even
        # if 0540 had been quietly fixed.
        path = gate.MIGRATIONS / '0540_a_counter_sale_of_dated_stock.sql'
        self.assertTrue(any("not terminated" in f
                            for f in gate.faults(path.read_text())),
                        '0540 is no longer at fault')
        self.assertEqual(gate.offenders([path]), [],
                         'the allowlist did not skip 0540')


class Plumbing(unittest.TestCase):
    def test_every_canary_is_reported(self):
        for label, snippet in gate.CANARIES.items():
            self.assertTrue(gate.faults(snippet), label)

    def test_no_must_not_report_shape_is_reported(self):
        for label, snippet in gate.NOT_FAULTS.items():
            self.assertEqual(gate.faults(snippet), [], label)

    def test_main_passes_at_head(self):
        self.assertEqual(gate.main(), 0)


if __name__ == '__main__':
    unittest.main()
