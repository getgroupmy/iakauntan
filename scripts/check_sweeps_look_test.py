#!/usr/bin/env python3
"""Self-test for check_sweeps_look.py.

The gate's own first run found two defects in it, and both are pinned
below:

  * it drove ITSELF, so it recursed until the timeout -- and reported
    that about itself rather than hanging, which is why it cost two
    minutes instead of an afternoon;
  * it read `usage: ... <database-url>` plus exit 2 as "reported a
    problem", so all ten database gates looked drivable. Non-zero for
    the wrong reason is the vacuous success this gate exists to refuse,
    and the gate committed it.

`run()` takes a fed verdict map, so every branch is reachable without
building a tree or running a subprocess.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import pathlib
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "csl", HERE / "check_sweeps_look.py")
csl = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(csl)


def shipped() -> dict[str, str]:
    """The verdict map the live repository produces, without running it."""
    found = {g: "reported" for g in csl.gates()}
    found.update({g: "needs_argument" for g in csl.NEEDS_A_DATABASE})
    found.update({g: "crashed" for g in csl.NEEDS_A_FILE})
    found.update({g: "passed_over_nothing" for g in csl.PASSES_OVER_NOTHING})
    return found


class Harness(unittest.TestCase):

    def gate(self, found):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = csl.run(found)
        return code, out.getvalue() + err.getvalue()


class TheShippedState(Harness):

    def test_the_expected_map_passes(self):
        code, said = self.gate(shipped())
        self.assertEqual(code, 0, said)
        self.assertIn("a ratchet that may only fall", said)

    def test_the_counts_add_up_to_every_gate(self):
        """If they did not, some gate would be in no bucket and checked by
        nothing -- which is this gate's own failure mode."""
        found = shipped()
        buckets = (len(csl.NEEDS_A_DATABASE) + len(csl.NEEDS_A_FILE)
                   + len(csl.PASSES_OVER_NOTHING))
        self.assertEqual(len(found) - buckets,
                         sum(1 for v in found.values() if v == "reported"))

    def test_it_does_not_drive_itself(self):
        """The first run recursed until the timeout."""
        self.assertNotIn(csl.SELF, csl.gates())
        self.assertNotIn("check_sweeps_look", csl.gates())

    def test_the_skeleton_is_empty_directories_only(self):
        self.assertIn("app/lib", csl.SKELETON)
        self.assertIn("supabase/migrations", csl.SKELETON)


class AUsageLineIsNotAFinding(Harness):
    """Exit 2 on a missing argument means the gate never looked."""

    def test_usage_is_classified_apart_from_reporting(self):
        """Drives `verdicts` with a faked subprocess result, because the
        first version of this test asserted on the DOCSTRING -- which a
        mutant deleting the usage branch left intact. A test that reads
        prose about the behaviour is not a test of the behaviour, and
        this is the gate whose whole subject is that mistake.
        """
        cases = {
            "usage, exit 2": (2, "usage: check_x.py <database-url>\n",
                              "needs_argument"),
            "usage on stdout, exit 1": (1, "usage: check_x.py DATABASE_URL",
                                        "needs_argument"),
            "a real finding": (1, "3 problem(s):\n  ...", "reported"),
            "a clean pass": (0, "ok   nothing to report",
                             "passed_over_nothing"),
            "a crash": (1, "Traceback (most recent call last):\n ...",
                        "crashed"),
            "a hang": ("timeout", "", "timeout"),
        }
        real = csl.drive
        try:
            for label, (code, said, want) in cases.items():
                with self.subTest(label):
                    csl.drive = lambda g, t, _c=code, _s=said: (_c, _s)
                    got = csl.verdicts(pathlib.Path("."), ["check_x"])
                    self.assertEqual(got, {"check_x": want}, label)
        finally:
            csl.drive = real

    def test_a_crash_is_not_read_as_a_usage_line(self):
        """Order matters: a traceback that happens to print usage text
        is a crash, not a gate politely asking for an argument."""
        real = csl.drive
        try:
            csl.drive = lambda g, t: (
                1, "usage: x\nTraceback (most recent call last):\n ...")
            self.assertEqual(csl.verdicts(pathlib.Path("."), ["check_x"]),
                             {"check_x": "crashed"})
        finally:
            csl.drive = real

    def test_a_database_gate_that_reports_instead_is_flagged(self):
        found = shipped()
        found[csl.NEEDS_A_DATABASE[0]] = "reported"
        code, said = self.gate(found)
        self.assertEqual(code, 1, said)
        self.assertIn("stale", said)

    def test_a_database_gate_that_passes_is_flagged_harder(self):
        found = shipped()
        found[csl.NEEDS_A_DATABASE[0]] = "passed_over_nothing"
        code, said = self.gate(found)
        self.assertEqual(code, 1, said)
        self.assertIn("the gate is not looking", said)

    def test_a_file_gate_that_stops_crashing_is_flagged(self):
        found = shipped()
        found[sorted(csl.NEEDS_A_FILE)[0]] = "reported"
        code, said = self.gate(found)
        self.assertEqual(code, 1, said)
        self.assertIn("FileNotFoundError", said)

    def test_every_file_excuse_names_the_file(self):
        for gate, path in csl.NEEDS_A_FILE.items():
            with self.subTest(gate):
                self.assertRegex(path, r"[\w./-]+\.\w+$", gate)


class TheRatchetBothWays(Harness):

    def test_a_new_gate_passing_over_nothing_is_flagged(self):
        found = shipped()
        found["check_something_new"] = "passed_over_nothing"
        code, said = self.gate(found)
        self.assertEqual(code, 1, said)
        self.assertIn("check_something_new", said)
        self.assertIn("could not look", said)

    def test_the_remedy_says_to_compare_the_count_not_print_it(self):
        """The correction this whole sweep turned on: three gates printed
        a number and passed over nothing anyway."""
        found = shipped()
        found["check_something_new"] = "passed_over_nothing"
        _, said = self.gate(found)
        # The specific clause, not the prefix. A mutant truncating this to
        # "Printing the number is not enough." survived the first version
        # of this assertion, because the prefix was all it checked.
        self.assertIn("something has to compare it", said)
        self.assertIn("sites matched rather than files read", said)

    def test_an_entry_that_now_reports_must_be_pruned(self):
        found = shipped()
        found[sorted(csl.PASSES_OVER_NOTHING)[0]] = "reported"
        code, said = self.gate(found)
        self.assertEqual(code, 1, said)
        self.assertIn("let the ratchet fall", said)

    def test_an_entry_for_a_deleted_gate_is_flagged(self):
        found = shipped()
        del found[sorted(csl.PASSES_OVER_NOTHING)[0]]
        code, said = self.gate(found)
        self.assertEqual(code, 1, said)
        self.assertIn("not a gate any more", said)

    def test_a_timeout_is_reported_rather_than_assumed_either_way(self):
        found = shipped()
        found["check_routes"] = "timeout"
        code, said = self.gate(found)
        self.assertEqual(code, 1, said)
        self.assertIn("nothing is known about it either way", said)

    def test_every_backlog_entry_says_what_it_needs(self):
        for gate, why in csl.PASSES_OVER_NOTHING.items():
            with self.subTest(gate):
                self.assertGreater(len(why), 40, gate)

    def test_the_backlog_is_only_gates_that_exist(self):
        names = set(csl.gates())
        for gate in csl.PASSES_OVER_NOTHING:
            self.assertIn(gate, names, gate)


if __name__ == "__main__":
    unittest.main(verbosity=2)
