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

    def test_both_runners_read_it_where_it_actually_IS(self):
        # It moved. The first version of this floor sat at
        # `supabase/functions/deno_test_floor` and broke `supabase
        # start`; a substring assertion on the basename would not have
        # noticed either the move or a stale path left behind.
        self.assertTrue(caf.DENO_FLOOR_FILE.is_file(), caf.DENO_FLOOR_FILE)
        where = str(caf.DENO_FLOOR_FILE.relative_to(caf.ROOT))
        self.assertEqual(where,
                         "supabase/functions/_local_check/deno_test_floor")
        self.assertIn(where, caf.DENO_RUNNER.read_text())
        self.assertIn(where, REAL_DENO_STEP)

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


REAL_DART_STEP = caf.ci_step(caf.WORKFLOW.read_text(), caf.DART_STEP)


class TheDartTestFloor(unittest.TestCase):
    """The third floor. Line 113 of ci.yml was a bare
    `- run: flutter test` for 2251 runs: it exits 0 over a suite that
    shrank, and the only number that would have said so is inside a
    progress line nothing reads.
    """

    def feed(self, step=None, **kw):
        step = REAL_DART_STEP if step is None else step
        return caf.dart_problems(
            workflow="      - name: %s\n        run: |\n%s" % (
                caf.DART_STEP,
                "\n".join("          " + l for l in step.splitlines())),
            **kw)

    def test_the_plumbing_is_sound_as_shipped(self):
        self.assertEqual(caf.dart_problems(), [])

    def test_a_piped_flutter_test_is_flagged(self):
        out = self.feed(REAL_DART_STEP.replace(
            'flutter test --file-reporter "json:$RUNNER_TEMP'
            '/flutter_tests.json"',
            'flutter test --file-reporter json:/tmp/r.json | tee /tmp/o'))
        self.assertIn("PIPES", said(out))

    def test_the_prose_around_the_step_is_not_read_as_code(self):
        # Two different pieces of prose, in two different places, and
        # finding that out is why this test is worded the way it is.
        #
        # The comments explaining this step sit ABOVE its `- name:` line,
        # so they are in the workflow but NOT in the slice `ci_step`
        # returns -- `assertIn("- run: flutter test", REAL_DART_STEP)`
        # failed on exactly that. They quote both the bare
        # `- run: flutter test` they replaced and the piped form they
        # forbid, and `dart_problems` must not report either.
        whole = caf.WORKFLOW.read_text()
        self.assertIn("# `- run: flutter test` was this step", whole)
        self.assertIn("flutter test | python3", whole)
        self.assertEqual(caf.dart_problems(), [])

        # And `ci_step`'s slice runs to the NEXT `- name:`, so it carries
        # the comment block introducing the step after this one -- which
        # happens to say "the script itself runs `flutter test` from
        # `app`". That is prose inside the slice, which is what the
        # comment stripping in `dart_problems` is for.
        self.assertIn("runs\n      # `flutter test` from `app`",
                      REAL_DART_STEP)
        self.assertEqual(self.feed(), [])

    def test_a_step_that_writes_no_report_is_flagged(self):
        out = self.feed(
            REAL_DART_STEP.replace("--file-reporter", "--reporter"))
        self.assertIn("--file-reporter", said(out))

    def test_a_step_that_never_reads_the_report_is_flagged(self):
        out = self.feed(REAL_DART_STEP.replace(
            "python3 ../scripts/check_flutter_test_count.py",
            "true # was: the counter"))
        self.assertIn("written and never read", said(out))

    def test_a_floor_passed_as_an_argument_is_a_second_copy(self):
        out = self.feed(
            'flutter test --file-reporter json:/tmp/r.json\n'
            'python3 ../scripts/check_flutter_test_count.py /tmp/r.json 6638')
        self.assertIn("second copy", said(out))

    def test_a_renamed_step_is_reported_rather_than_skipped(self):
        out = caf.dart_problems(workflow="      - name: Something else\n")
        self.assertIn("has no step named", said(out))

    def test_a_surviving_bare_flutter_test_run_is_flagged(self):
        out = caf.dart_problems(
            workflow=caf.WORKFLOW.read_text()
            + "\n      - run: flutter test\n")
        self.assertIn("uncounted run", said(out))

    def test_the_live_workflow_has_no_bare_flutter_test_run(self):
        self.assertNotIn("\n      - run: flutter test\n",
                         caf.WORKFLOW.read_text())

    def test_a_reader_with_a_fallback_floor_is_flagged(self):
        out = caf.dart_problems(reader="floor = floor_from() or 4000\n")
        self.assertIn("invent a number", said(out))

    def test_a_reader_that_does_not_name_the_file_is_flagged(self):
        out = caf.dart_problems(reader="floor = 6638\n")
        self.assertIn("one definition", said(out))

    def test_a_malformed_floor_file_is_reported(self):
        out = caf.dart_problems(floor_text="# prose only\n")
        self.assertIn("exactly one bare integer", said(out))

    def test_two_numbers_in_the_floor_file_is_two_floors(self):
        out = caf.dart_problems(floor_text="6638\n6000\n")
        self.assertIn("exactly one bare integer", said(out))

    def test_a_zero_floor_is_reported(self):
        out = caf.dart_problems(floor_text="0\n")
        self.assertIn("every test stopped registering", said(out))

    def test_the_reader_exists_and_is_the_one_named(self):
        self.assertTrue(caf.DART_READER.is_file(), caf.DART_READER)
        self.assertIn("flutter_test_floor", caf.DART_READER.read_text())


REAL_NODE_STEP = caf.ci_step(caf.WORKFLOW.read_text(), caf.NODE_STEP)


class TheCallServersFloor(unittest.TestCase):
    """The fourth floor, and the one with the most to lose. The sfu job's
    whole step was `- run: npm test`, and the package script is
    `node --test test/*.test.js`. Probed on node v22.22.2: over a glob
    that matches NOTHING it prints `# tests 0` and EXITS 0 -- so
    emptying or renaming server/sfu/test/ takes all 33 assertions about
    the call server's protocol and token handling with it and the job
    stays green. Proved by moving the two files to `*.spec.js` and
    running the extracted step: 0 ran, exit 1.
    """

    def feed(self, step=None, **kw):
        step = REAL_NODE_STEP if step is None else step
        return caf.node_problems(
            workflow="      - name: %s\n        run: |\n%s" % (
                caf.NODE_STEP,
                "\n".join("          " + l for l in step.splitlines())),
            **kw)

    def test_the_plumbing_is_sound_as_shipped(self):
        self.assertEqual(caf.node_problems(), [])

    def test_a_piped_npm_test_is_flagged(self):
        out = self.feed(REAL_NODE_STEP.replace(
            'out="$(npm test 2>&1)" || {', 'npm test | tee /tmp/o || {'))
        self.assertIn("PIPES", said(out))

    def test_the_steps_own_comments_are_not_read_as_faults(self):
        # Its prose quotes the bare `- run: npm test` it replaced and the
        # piped form it forbids.
        whole = caf.WORKFLOW.read_text()
        self.assertIn("# `- run: npm test` was the whole step", whole)
        self.assertIn("`npm test | grep`", whole)
        self.assertEqual(caf.node_problems(), [])

    def test_a_step_that_only_prints_the_count_is_flagged(self):
        out = self.feed(REAL_NODE_STEP.replace(
            'if [ "$ran" -lt "$floor" ]; then', 'if false; then'))
        self.assertIn("never compares", said(out))

    def test_a_step_that_stops_running_the_tests_is_flagged(self):
        out = self.feed(REAL_NODE_STEP.replace("npm test", "true"))
        self.assertIn("does not run `npm test`", said(out))

    def test_a_renamed_step_is_reported_rather_than_skipped(self):
        out = caf.node_problems(workflow="      - name: Something else\n")
        self.assertIn("has no step named", said(out))

    def test_a_surviving_bare_npm_test_run_is_flagged(self):
        out = caf.node_problems(
            workflow=caf.WORKFLOW.read_text() + "\n      - run: npm test\n")
        self.assertIn("uncounted run", said(out))

    def test_the_live_workflow_has_no_bare_npm_test_run(self):
        self.assertNotIn("\n      - run: npm test\n",
                         caf.WORKFLOW.read_text())

    def test_an_unpinned_reporter_is_flagged(self):
        # node picks `tap` off a terminal and `spec` on one, and `spec`
        # spells the summary `i tests 33` rather than `# tests 33`. The
        # count would read zero on a runner that allocates a tty.
        out = caf.node_problems(
            package='{"scripts": {"test": "node --test test/*.test.js"}}')
        self.assertIn("--test-reporter=tap", said(out))

    def test_the_real_package_pins_it(self):
        self.assertIn("--test-reporter=tap", caf.NODE_PACKAGE.read_text())

    def test_a_malformed_floor_file_is_reported(self):
        out = caf.node_problems(floor_text="# prose only\n")
        self.assertIn("exactly one bare integer", said(out))

    def test_a_zero_floor_is_reported(self):
        out = caf.node_problems(floor_text="0\n")
        self.assertIn("every test stopped registering", said(out))

    def test_the_floor_is_the_measured_number(self):
        """33: 23 in protocol.test.js and 10 in token.test.js, subtests
        inside a describe included and the four suites not counted."""
        self.assertEqual(caf.floor_value(caf.NODE_FLOOR_FILE.read_text()),
                         "33")


class NothingLooseUnderFunctions(unittest.TestCase):
    """`supabase start` walks `supabase/functions/` and reaches for
    `<entry>/index.ts` for every entry. A directory without one is
    skipped; a FILE is not -- the stat fails with

        BadResource: FileSystem.access (.../deno_test_floor/index.ts)

    and the local stack never comes up, which takes the SQL assertion
    job with it. Run 2251 went red that way, on the commit that added
    the edge-test floor, and the message named a path that does not
    exist and a function nobody wrote.
    """

    def test_the_tree_is_clean_as_shipped(self):
        self.assertEqual(caf.functions_dir_problems(), [])

    def test_a_loose_file_is_refused(self):
        out = caf.functions_dir_problems(["deno_test_floor"])
        self.assertEqual(len(out), 1)
        self.assertIn("deno_test_floor", out[0])
        self.assertIn("BadResource", out[0])
        self.assertIn("a file", out[0])

    def test_several_are_listed_and_the_sentence_still_reads(self):
        out = caf.functions_dir_problems(["README.md", ".gitkeep"])
        self.assertIn("holds files directly", out[0])
        self.assertIn(".gitkeep, README.md", out[0])

    def test_the_remedy_names_where_to_put_it_instead(self):
        out = caf.functions_dir_problems(["x"])
        self.assertIn("_local_check/", out[0])

    def test_the_real_directory_holds_only_directories(self):
        # The same fact from the data rather than the exit code: an
        # assertion on `functions_dir_problems() == []` passes if the
        # function ever learns to return nothing.
        loose = sorted(p.name for p in caf.FUNCTIONS_DIR.iterdir()
                       if not p.is_dir())
        self.assertEqual(loose, [])
        self.assertGreater(len(list(caf.FUNCTIONS_DIR.iterdir())), 15)

    def test_it_is_wired_into_the_gate_and_not_merely_defined(self):
        # A checker nothing calls is a checker that passes everything.
        # Fed a tree with a loose file through `problems()` is the only
        # way to see that; so instead, assert the live call site.
        source = pathlib.Path(caf.__file__).read_text()
        self.assertIn("out += functions_dir_problems()", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
