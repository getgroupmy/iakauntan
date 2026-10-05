#!/usr/bin/env python3
"""Self-test for `mutate_sql.preflight`, the harness's own pre-flight.

Written because the check was WRONG TWICE on the afternoon it was
added, in both directions, and a pre-flight that is wrong is worse than
none: it either passes a mutant that will abort a whole file, or it
refuses a mutant that was fine and sends the reader looking for a bug
in good code.

Both mistakes are pinned below:

  * `re.search('--[^\\n]*$', new)` -- Python's `$` also matches just
    BEFORE a trailing newline, so a replacement ending `-- marker\\n`,
    which is the FIX for the swallow problem, was reported as having
    the problem. The fix looked like it had not taken.
  * comparing bracket COUNTS rather than asking whether the two deltas
    agree -- a mutant that drops a subquery removes an open and a close
    together and is perfectly well formed. Seven good mutants were
    flagged.
"""

from __future__ import annotations

import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import mutate_sql  # noqa: E402

# A migration with one function in it, whose body carries the two shapes
# that matter: a CALL WHOSE ARGUMENTS CONTINUE ON THE SAME LINE after a
# comma, and a subquery in brackets.
#
# The first version of this fixture put the remaining arguments on the
# NEXT line -- and then the swallow test failed, because a replacement
# that stops at the end of a line has nothing to swallow. The fixture
# was wrong, not the check. A pre-flight test needs a source line that
# really does continue.
MIGRATION = """
create or replace function app.pretend(p_id uuid)
returns uuid
language plpgsql
as $$
declare
  v_x numeric := 0;
begin
  select coalesce(a.one,
                  (select b.two from public.other b
                    where b.org = p_id and b.is_default limit 1))
    into v_x from public.thing a where a.id = p_id;
  perform app.post(p_id, 'stock_movement', v_x, 'Narrative ' || p_id, 'thing', p_id);
  -- Another company's rows are not this company's, and the apostrophes
  -- in this very sentence are what defeated the parity check.
  if v_x is null then
    raise exception 'No thing configured. Run the setup first.'
      using errcode = 'P0002';
  end if;
  return p_id;
end;
$$;
"""


def one(label, old, new, marker, name="pretend"):
    return mutate_sql.preflight(MIGRATION, [(label, name, old, new, marker)])


class Preflight(unittest.TestCase):

    def test_a_clean_mutant_is_silent(self):
        self.assertEqual(
            one("ok", "  return p_id;", "  return null;  -- returned null",
                "-- returned null"),
            [])

    # --- the swallow, which is what this exists to catch --------------
    def test_a_marker_that_swallows_the_rest_of_the_line_is_reported(self):
        got = one("swallows",
                  "  perform app.post(p_id, 'stock_movement', v_x,",
                  "  perform app.post(p_id, 'manual', v_x,  -- source lied",
                  "-- source lied")
        self.assertEqual(len(got), 1, got)
        self.assertIn("comment out the rest of the line", got[0])
        # And it must QUOTE the text that would be lost, or the reader
        # has to go and find it.
        self.assertIn("Narrative", got[0])

    def test_the_same_mutant_with_the_whole_line_is_silent(self):
        self.assertEqual(
            one("whole line",
                "  perform app.post(p_id, 'stock_movement', v_x, "
                "'Narrative ' || p_id, 'thing', p_id);",
                "  perform app.post(p_id, 'manual', v_x, "
                "'Narrative ' || p_id, 'thing', p_id);  -- source lied",
                "-- source lied"),
            [])

    def test_a_marker_followed_by_a_newline_is_silent(self):
        """The first version of the check reported THIS as the problem.

        `$` in Python matches before a trailing newline, so a
        replacement that correctly terminates its comment looked exactly
        like one that did not.
        """
        self.assertEqual(
            one("newline-terminated",
                "    into v_x from public.thing a where a.id = p_id;\n",
                "    into v_x from public.thing a  -- id filter dropped\n",
                "-- id filter dropped"),
            [])

    # --- brackets ----------------------------------------------------
    def test_dropping_a_subquery_is_not_a_bracket_problem(self):
        """Balanced removal. The first version flagged seven of these."""
        self.assertEqual(
            one("subquery dropped",
                "  select coalesce(a.one,\n"
                "                  (select b.two from public.other b\n"
                "                    where b.org = p_id and b.is_default limit 1))",
                "  select a.one  -- fallback dropped",
                "-- fallback dropped"),
            [])

    def test_unbalanced_brackets_are_reported(self):
        got = one("unbalanced",
                  "  return p_id;",
                  "  return coalesce(p_id;  -- bracket left open",
                  "-- bracket left open")
        self.assertTrue(any("unbalanced" in g for g in got), got)

    # --- the landed check --------------------------------------------
    def test_a_marker_already_in_the_original_is_reported(self):
        got = one("already there", "  return p_id;", "  return null;",
                  "declare")
        self.assertTrue(any("in the ORIGINAL" in g for g in got), got)

    def test_a_marker_absent_from_the_mutant_is_reported(self):
        got = one("absent", "  return p_id;", "  return null;",
                  "-- never written")
        self.assertTrue(any("not in the mutant" in g for g in got), got)

    # --- the anchor --------------------------------------------------
    def test_an_old_string_matching_twice_is_reported(self):
        got = one("twice", "p_id", "q_id", "q_id")
        self.assertTrue(any("matches" in g for g in got), got)

    def test_an_old_string_matching_nothing_is_reported(self):
        got = one("never", "  return p_other;", "  return null;", "null")
        self.assertTrue(any("matches 0 times" in g for g in got), got)

    def test_a_function_not_in_this_migration_is_reported(self):
        """The POS recipe pair's case: two halves, two migrations.

        Without this the harness exits inside `block()` with a message
        about the migration, which reads like the migration is wrong
        rather than like the pair needs two files.
        """
        got = one("elsewhere", "  return p_id;", "  return null;", "null",
                  name="somewhere_else")
        self.assertEqual(len(got), 1, got)
        self.assertIn("not in this migration", got[0])

    # --- several at once ---------------------------------------------
    def test_every_problem_is_reported_not_just_the_first(self):
        """The whole point of a pre-flight over the mid-run guard.

        The guard aborts the file at the first bad mutant, so a second
        one is not seen until the first is fixed and the file is run
        again -- and a file run is minutes.
        """
        got = mutate_sql.preflight(MIGRATION, [
            ("first", "pretend", "  perform app.post(p_id, 'stock_movement', v_x,",
             "  perform app.post(p_id, 'manual', v_x,  -- a", "-- a"),
            # A DIFFERENT kind of problem, so this also proves the two
            # are not one check reported twice. The first draft used a
            # second swallow-shaped mutant that turned out to be
            # perfectly fine -- its line ended where the replacement
            # did -- and the test failed for that reason rather than
            # for the one it was written about.
            ("second", "pretend", "  return p_id;",
             "  return coalesce(p_id;  -- b", "-- b"),
        ])
        self.assertEqual(len(got), 2, got)
        self.assertTrue(got[0].startswith("first"), got)
        self.assertTrue(got[1].startswith("second"), got)

    # --- string context ----------------------------------------------
    def test_a_boundary_inside_a_string_literal_is_not_a_swallow(self):
        """Inside `'...'` a `--` is message text, not a comment.

        The check shipped without this and reported five mutants in
        already-measured files -- four of them splitting a
        `raise exception '...'` message exactly as below. A pre-flight
        with false positives is the kind of gate somebody turns off, and
        this one sent the session off to re-verify five committed kill
        sheets that were never in doubt.
        """
        self.assertEqual(
            one("inside a literal",
                "  if v_x is null then\n"
                "    raise exception 'No thing configured.",
                "  if false then\n"
                "    raise exception 'No thing configured."
                "  -- refusal dropped",
                "-- refusal dropped"),
            [])

    def test_a_boundary_in_CODE_is_still_a_swallow(self):
        """The other side of the same coin: the check must still fire.

        Proven separately so that fixing the false positive cannot
        quietly disable the true one.
        """
        got = one("in code",
                  "  perform app.post(p_id, 'stock_movement', v_x,",
                  "  perform app.post(p_id, 'manual', v_x,  -- source lied",
                  "-- source lied")
        self.assertEqual(len(got), 1, got)
        self.assertIn("comment out the rest of the line", got[0])

    def test_an_apostrophe_in_a_comment_does_not_fool_the_literal_check(self):
        """The bug that made the parity version wrong twice over.

        The fixture above carries two apostrophes in a prose comment,
        BEFORE the `raise exception`. A quote-parity check sees them as
        opening and closing a literal and gets the answer to every
        later question backwards. This schema's bodies are full of
        "another company's rows", so the scanner has to skip comments.
        """
        self.assertFalse(mutate_sql.in_string_literal(
            MIGRATION, MIGRATION.index("if v_x is null")))
        self.assertTrue(mutate_sql.in_string_literal(
            MIGRATION, MIGRATION.index("Run the setup first")))
        # And the mutant that splits that message is still not reported.
        self.assertEqual(
            one("after two apostrophes",
                "  if v_x is null then\n"
                "    raise exception 'No thing configured.",
                "  if false then\n"
                "    raise exception 'No thing configured."
                "  -- refusal dropped",
                "-- refusal dropped"),
            [])

    def test_an_escaped_quote_does_not_end_the_literal(self):
        """`''` inside a literal is one quote, not two delimiters."""
        src = "create or replace function app.q() returns void as $$\n"
        src += "begin raise exception 'it''s here. and more'; end;\n$$;\n"
        self.assertTrue(mutate_sql.in_string_literal(src, src.index("and more")))
        self.assertFalse(mutate_sql.in_string_literal(src, src.index("end;")))

    def test_the_docstring_says_what_a_harness_error_costs(self):
        """Because the reason to prefer this over the guard is the cost."""
        doc = mutate_sql.preflight.__doc__ or ""
        self.assertIn("aborts the whole file", doc)


if __name__ == "__main__":
    unittest.main(verbosity=2)
