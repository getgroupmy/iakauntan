#!/usr/bin/env python3
"""Self-test for check_assertion_floor.py.

The gate asserts plumbing, so its own failure modes are all of the
"looks fine from outside" kind, and the assertions below are grouped by
which one they cover.

The sharpest is `APipeIsNotALogicalOr`. The first version of this gate
flagged the very step it describes, because `psql ... | tee` and
`out="$(psql ...)" || {` both contain a `|` and the pattern asked for
nothing more. That is the eighth time in this session that matching text
has stood in for checking meaning, and the only reason it cost nothing is
that the gate was run against the file it was written about before being
believed. So both directions are pinned here: a real pipe is caught, and
a logical OR is not.
"""

from __future__ import annotations

import importlib.util
import pathlib
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "caf", HERE / "check_assertion_floor.py")
caf = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(caf)

REAL_STEP = caf.ci_step(caf.WORKFLOW.read_text())
REAL_RUNNER = caf.RUNNER.read_text()
OK_HELPERS = "raise notice 'ok   % = %', p_label, p_actual;"


def said(problems):
    return "\n".join(problems)


class TheLiveRepository(unittest.TestCase):

    def test_the_plumbing_is_sound_as_shipped(self):
        self.assertEqual(caf.problems(), [])

    def test_the_step_is_found_by_name(self):
        """If the step is renamed, the gate must say so rather than
        quietly check an empty string."""
        self.assertIn("Run the database assertions", REAL_STEP)
        self.assertIn("asserted=0", REAL_STEP)

    def test_the_step_body_stops_at_the_next_step(self):
        """A greedy slice would drag in later steps and make every
        'does it contain X' assertion below pass for the wrong reason."""
        self.assertNotIn("- name: Check every assertion file", REAL_STEP)
        self.assertLess(len(REAL_STEP), len(caf.WORKFLOW.read_text()))

    def test_both_runners_count_the_same_thing(self):
        self.assertIn(caf.PATTERN, REAL_RUNNER)
        self.assertIn(caf.PATTERN, REAL_STEP)

    def test_the_pattern_is_what_the_helpers_actually_print(self):
        """psql renders `raise notice 'ok   X'` as `NOTICE:  ok   X`.
        Two spaces after the colon, and the gate's pattern has to be a
        prefix of that or it counts nothing."""
        self.assertTrue("NOTICE:  ok   X".startswith(caf.PATTERN))
        self.assertIn("raise notice 'ok",
                      (caf.ROOT / "supabase/tests/_helpers.sql").read_text())


class TheFloorFile(unittest.TestCase):

    def test_one_bare_integer_is_the_value(self):
        self.assertEqual(caf.floor_value("# a comment\n14330\n"), "14330")

    def test_no_bare_integer_is_not_a_value(self):
        """`grep -Ex` over this yields the empty string, and an empty
        string is not a floor that fails loudly."""
        self.assertIsNone(caf.floor_value("# only prose\nfloor = 14330\n"))

    def test_two_bare_integers_are_ambiguous(self):
        """Both readers take the first match; a second number is somebody
        editing the wrong line."""
        self.assertIsNone(caf.floor_value("14330\n14276\n"))

    def test_a_malformed_floor_file_is_reported(self):
        out = caf.problems(floor_text="# nothing but prose\n")
        self.assertIn("exactly one bare integer", said(out))
        self.assertIn("EMPTY STRING", said(out))

    def test_a_zero_floor_is_reported(self):
        out = caf.problems(floor_text="0\n")
        self.assertIn("A floor at zero", said(out))


class NeitherRunnerKeepsItsOwnCopy(unittest.TestCase):

    def test_a_runner_that_stops_reading_the_file_is_reported(self):
        out = caf.problems(runner="ASSERTION_FLOOR=14330\n" + caf.PATTERN)
        self.assertIn("does not read supabase/tests/assertion_floor",
                      said(out))

    def test_a_hardcoded_default_is_reported_as_a_second_copy(self):
        out = caf.problems(
            runner=REAL_RUNNER.replace(
                "ASSERTION_FLOOR=\"${IAK_ASSERTION_FLOOR:-$(grep",
                "ASSERTION_FLOOR=\"${IAK_ASSERTION_FLOOR:-14330}\" # $(grep"))
        self.assertIn("second copy", said(out))

    def test_a_ci_step_that_stops_reading_the_file_is_reported(self):
        out = caf.problems(workflow=REAL_STEP.replace(
            "grep -Ex '[0-9]+' supabase/tests/assertion_floor", "echo 14330"))
        self.assertIn("does not read supabase/tests/assertion_floor",
                      said(out))

    def test_a_renamed_step_is_reported_rather_than_skipped(self):
        out = caf.problems(workflow="      - name: Something else\n        run: true\n")
        self.assertIn("makes the gate check nothing", said(out))


class APipeIsNotALogicalOr(unittest.TestCase):

    def test_the_real_capture_is_not_flagged(self):
        self.assertNotIn("PIPES psql", said(caf.problems()))

    def test_a_pipe_into_grep_is_flagged(self):
        out = caf.problems(workflow=REAL_STEP.replace(
            'out="$(psql "$DB" -v ON_ERROR_STOP=1 -f "$f" 2>&1)" || {',
            'psql "$DB" -v ON_ERROR_STOP=1 -f "$f" | grep ok || {'))
        self.assertIn("PIPES psql", said(out))
        self.assertIn("reads as a pass", said(out))

    def test_a_pipe_with_no_or_at_all_is_flagged(self):
        out = caf.problems(workflow=REAL_STEP.replace(
            'out="$(psql "$DB" -v ON_ERROR_STOP=1 -f "$f" 2>&1)" || {',
            'psql "$DB" -f "$f" | tee /tmp/o'))
        self.assertIn("PIPES psql", said(out))

    def test_a_missing_counter_is_flagged(self):
        out = caf.problems(workflow=REAL_STEP.replace("asserted=0", "true"))
        self.assertIn("does not initialise its counter", said(out))


class TheFloorIsComparedAndNotJustPrinted(unittest.TestCase):
    """The step shipped read-only for exactly one run, to measure CI's
    count before gating on it. A step that prints a number nobody checks
    reads identically to one that gates on it, so the difference is
    pinned here."""

    def test_the_real_step_compares(self):
        self.assertNotIn("never compares the count", said(caf.problems()))
        self.assertRegex(REAL_STEP, r'"\$asserted"\s+-lt\s+"\$floor"')

    def test_a_step_that_only_prints_the_floor_is_flagged(self):
        out = caf.problems(workflow=REAL_STEP.replace(
            'if [ "$asserted" -lt "$floor" ]; then', 'if false; then'))
        self.assertIn("never compares the count", said(out))
        self.assertIn("not a floor", said(out))

    def test_the_unreadable_floor_guard_is_in_the_step(self):
        """`[ 14330 -lt "" ]` fails as a shell error rather than as a
        statement about the suite, so the step says it plainly."""
        self.assertIn("holds no bare", REAL_STEP)
        self.assertIn("grep -Exq", REAL_STEP)


class TheHelpersStillPrintIt(unittest.TestCase):

    def test_a_renamed_success_notice_is_reported(self):
        out = caf.problems(helpers="raise notice 'PASS %', p_label;")
        self.assertIn("no longer says", said(out))
        self.assertIn("renamed notice", said(out))

    def test_the_real_helpers_satisfy_it(self):
        self.assertNotIn("no longer says", said(caf.problems()))
        self.assertIn("ok", OK_HELPERS)



REAL_DENO_STEP = caf.ci_step(caf.WORKFLOW.read_text(), caf.DENO_STEP)


def deno_said(problems):
    return "\n".join(problems)


class TheEdgeTestFloor(unittest.TestCase):
    """The second floor, on the same pattern.

    `deno test` over a file that defines no tests prints
    "ok | 0 passed | 0 failed" and EXITS 0 -- verified on deno 2.9.6 --
    so a `Deno.test` block that stopped registering takes its assertions
    with it and all 40 of CI's per-file steps stay green.
    """

    def feed(self, step):
        return caf.deno_problems(
            workflow="      - name: %s\n        run: |\n%s" % (
                caf.DENO_STEP,
                "\n".join("          " + l for l in step.splitlines())))

    def test_the_plumbing_is_sound_as_shipped(self):
        self.assertEqual(caf.deno_problems(), [])

    def test_a_piped_deno_test_is_flagged(self):
        out = self.feed(REAL_DENO_STEP.replace(
            'out="$(deno test --allow-env --allow-read $files 2>&1)" || {',
            'deno test --allow-env --allow-read $files | tee /tmp/o || {'))
        self.assertIn("PIPES", deno_said(out))

    def test_the_steps_own_comments_are_not_read_as_faults(self):
        """That step's comments QUOTE both things they forbid while
        explaining them. The first version of these assertions matched
        the explanation and reported two live faults that were prose."""
        self.assertIn("| tee", REAL_DENO_STEP)
        self.assertIn("supabase/functions/[^ ]*_test", REAL_DENO_STEP)
        self.assertEqual(self.feed(REAL_DENO_STEP), [])

    def test_a_grep_pattern_is_not_a_piped_command(self):
        """The step's file list comes from a grep whose PATTERN contains
        the words `deno test`, piped to awk. That is not a piped
        `deno test`, and it was read as one."""
        self.assertRegex(REAL_DENO_STEP, r"grep -oE 'deno test")
        self.assertNotIn("PIPES", deno_said(self.feed(REAL_DENO_STEP)))

    def test_a_narrow_file_list_is_flagged(self):
        """The bug this floor shipped with for ten minutes: 37 of 40
        files, so a floor over a subset that passes."""
        out = self.feed(REAL_DENO_STEP.replace(
            "grep -oE 'deno test( +--[a-z-]+)* +[^ ]*_test\\.(ts|js)' \\",
            "grep -oE 'supabase/functions/[^ ]*_test\\.ts' \\"))
        self.assertIn("SUBSET", deno_said(out))
        self.assertIn("cloudflare", deno_said(out))

    def test_a_step_that_only_prints_the_count_is_flagged(self):
        out = self.feed(REAL_DENO_STEP.replace(
            'if [ "$ran" -lt "$floor" ]; then', 'if false; then'))
        self.assertIn("never compares", deno_said(out))

    def test_both_runners_read_the_file(self):
        self.assertIn("deno_test_floor", caf.DENO_RUNNER.read_text())
        self.assertIn("deno_test_floor", REAL_DENO_STEP)

    def test_a_malformed_floor_file_is_reported(self):
        out = caf.deno_problems(floor_text="# prose only\n")
        self.assertIn("exactly one bare integer", deno_said(out))

    def test_a_zero_floor_is_reported(self):
        out = caf.deno_problems(floor_text="0\n")
        self.assertIn("every test stopped registering", deno_said(out))

    def test_the_floor_is_the_measured_number(self):
        """503 over 40 files, which is 467 in supabase/functions plus the
        three outside it."""
        self.assertEqual(caf.floor_value(caf.DENO_FLOOR_FILE.read_text()),
                         "503")


if __name__ == "__main__":
    unittest.main(verbosity=2)
