#!/usr/bin/env python3
"""The analyser-coverage gate's own assertions.

    python3 scripts/check_analyzer_covers_the_app_test.py

Everything is fed -- the options text and the file list both -- so each
failure MESSAGE is exercised. A gate whose only tested path is the passing
one says nothing about what it prints when it fires, and what it prints is
the whole remedy.

The glob translation gets its own class. `fnmatch` would have been one
line and would have been wrong: it renders `*` as `.*`, so `build/*` and
`build/**` would exclude the same thing, and telling those apart is the
only reason this gate globs at all.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import pathlib
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "acta", HERE / "check_analyzer_covers_the_app.py")
acta = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(acta)

REAL = acta.OPTIONS.read_text()

#: Above LEAST_DART, so the floor is not what fires.
FILES = (["lib/src/a.dart", "test/a_test.dart"]
         + ["lib/x%d.dart" % i for i in range(500)])


def said(problems) -> str:
    return "\n".join(problems)


def feed(text: str, files=None):
    return acta.problems(text=text, files=FILES if files is None else files)[0]


class TheLiveRepository(unittest.TestCase):

    def test_it_passes_as_shipped(self):
        out, count = acta.problems()
        self.assertEqual(out, [], said(out))
        self.assertGreater(count, acta.LEAST_DART)

    def test_the_real_options_file_is_read_not_assumed(self):
        self.assertTrue(acta.OPTIONS.is_file(), acta.OPTIONS)
        self.assertIn("flutter_lints", REAL)

    def test_ci_still_runs_flutter_analyze_with_both_flags(self):
        # The gate is about what that command reads. If the command goes,
        # the gate is guarding a line nobody runs.
        workflow = (acta.ROOT / ".github" / "workflows" / "ci.yml").read_text()
        self.assertIn("flutter analyze --fatal-infos --fatal-warnings",
                      workflow)

    def test_every_allowed_exclusion_says_why(self):
        self.assertTrue(acta.ALLOWED_EXCLUDES)
        for name, why in acta.ALLOWED_EXCLUDES.items():
            with self.subTest(name):
                self.assertGreater(len(why), 10, name)


class TheThreeMeasuredHoles(unittest.TestCase):
    """Each of these was run before it was written about: a file with two
    hard type errors in `lib/src/`, which `flutter analyze` reported as
    "2 issues found. (ran in 70.6s)" and exit 1."""

    def test_excluding_app_code_is_refused(self):
        # Measured: "No issues found! (ran in 3.2s)", exit 0. Seventy
        # seconds became three and nothing read that either.
        out = feed(REAL.replace("    - build/**",
                                "    - build/**\n    - lib/src/**"))
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("lib/src/**", out[0])
        self.assertIn("3.2s", out[0])

    def test_downgrading_an_error_to_ignore_is_refused(self):
        # Measured: "No issues found! (ran in 18.2s)", exit 0, with
        # --fatal-infos --fatal-warnings both set.
        out = feed(REAL.replace(
            "analyzer:",
            "analyzer:\n  errors:\n    invalid_assignment: ignore"))
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("invalid_assignment", out[0])

    def test_downgrading_to_warning_is_refused_too(self):
        # --fatal-warnings makes a warning fatal again, so this one is
        # only safe while a flag in another file stays put.
        out = feed(REAL.replace(
            "analyzer:", "analyzer:\n  errors:\n    unused_import: warning"))
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("another file", out[0])

    def test_downgrading_to_error_is_allowed(self):
        out = feed(REAL.replace(
            "analyzer:", "analyzer:\n  errors:\n    unused_import: error"))
        self.assertEqual(out, [], said(out))

    def test_deleting_the_lint_include_is_refused(self):
        out = feed(REAL.replace("include: %s" % acta.INCLUDE, ""))
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("flutter_lints", out[0])
        self.assertIn("type system", out[0])

    def test_turning_one_lint_off_is_refused(self):
        out = feed(REAL + "linter:\n  rules:\n    prefer_const: false\n")
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("prefer_const", out[0])

    def test_turning_one_lint_ON_is_not_complained_about(self):
        out = feed(REAL + "linter:\n  rules:\n    always_declare: true\n")
        self.assertEqual(out, [], said(out))

    def test_a_list_style_rules_block_is_read_and_not_flagged(self):
        out = feed(REAL + "linter:\n  rules:\n    - always_declare\n")
        self.assertEqual(out, [], said(out))


class TheExcludeListGoesStale(unittest.TestCase):

    def test_an_exclusion_that_is_no_longer_made_is_reported(self):
        out = feed(REAL.replace("    - ios/**\n", ""))
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("ios/**", out[0])
        self.assertIn("harmless direction", out[0])

    def test_an_allowed_pattern_that_now_hides_app_dart_is_reported(self):
        # The pattern is unchanged and the TREE moved under it.
        out = acta.problems(text=REAL,
                            files=FILES + ["web/widgets/thing.dart"])[0]
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("web/**", out[0])
        self.assertIn("web/widgets/thing.dart", out[0])
        self.assertIn("no longer describes", out[0])

    def test_a_new_exclusion_is_refused_even_if_it_hides_nothing(self):
        out = feed(REAL.replace("    - build/**",
                                "    - build/**\n    - tool/**"))
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("tool/**", out[0])


class ItMustNotPassOverNothing(unittest.TestCase):

    def test_an_empty_app_is_refused(self):
        out = acta.problems(text=REAL, files=[])[0]
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("found only 0", out[0])

    def test_and_it_stops_there_rather_than_listing_configuration(self):
        # A floor failure is about the sweep, not about the file, and the
        # three holes below would all read as absent over no files.
        out = acta.problems(text=REAL.replace("include: %s" % acta.INCLUDE,
                                              ""), files=[])[0]
        self.assertEqual(len(out), 1, said(out))
        self.assertNotIn("flutter_lints", out[0])

    def test_a_missing_options_file_is_refused_rather_than_ignored(self):
        saved = acta.OPTIONS
        acta.OPTIONS = pathlib.Path("/nonexistent/analysis_options.yaml")
        try:
            out = acta.problems()[0]
        finally:
            acta.OPTIONS = saved
        self.assertEqual(len(out), 1, said(out))
        self.assertIn("could not look", out[0])


class TheGlobTranslation(unittest.TestCase):
    """`*` does not cross a path separator and `**` does. This is the
    whole reason the gate does not use fnmatch, which renders both as
    `.*`."""

    def one(self, pattern: str, path: str) -> bool:
        return bool(acta.glob_to_regex(pattern).match(path))

    def test_a_single_star_stays_in_its_segment(self):
        self.assertTrue(self.one("build/*", "build/b.dart"))
        self.assertFalse(self.one("build/*", "build/a/b.dart"))

    def test_a_double_star_crosses_them(self):
        self.assertTrue(self.one("build/**", "build/a/b.dart"))
        self.assertTrue(self.one("build/**", "build/b.dart"))

    def test_it_is_anchored_at_both_ends(self):
        self.assertFalse(self.one("web/**", "lib/web/a.dart"))
        self.assertFalse(self.one("lib/a", "lib/a.dart"))

    def test_a_question_mark_is_one_character_and_not_a_separator(self):
        self.assertTrue(self.one("lib/?.dart", "lib/a.dart"))
        self.assertFalse(self.one("lib/?.dart", "lib/ab.dart"))
        self.assertFalse(self.one("a?b", "a/b"))

    def test_a_dot_is_a_dot_and_not_any_character(self):
        self.assertFalse(self.one("lib/a.dart", "lib/axdart"))

    def test_fnmatch_would_have_got_the_first_one_wrong(self):
        # Pinned so the shortcut is not taken later. fnmatch says yes.
        import fnmatch
        self.assertTrue(fnmatch.fnmatch("build/a/b.dart", "build/*"))
        self.assertFalse(self.one("build/*", "build/a/b.dart"))


class TheParser(unittest.TestCase):

    def test_it_reads_the_real_file(self):
        conf = acta.parse(REAL)
        self.assertEqual(sorted(conf["exclude"]),
                         sorted(acta.ALLOWED_EXCLUDES))
        self.assertEqual(conf["include"], [acta.INCLUDE])
        self.assertEqual(conf["errors"], {})

    def test_a_comment_is_not_a_setting(self):
        conf = acta.parse(
            "analyzer:\n  exclude:\n    # - lib/**\n    - build/**\n")
        self.assertEqual(conf["exclude"], ["build/**"])

    def test_quotes_around_a_pattern_are_dropped(self):
        conf = acta.parse("analyzer:\n  exclude:\n    - 'build/**'\n")
        self.assertEqual(conf["exclude"], ["build/**"])

    def test_a_trailing_comment_on_a_pattern_is_dropped(self):
        conf = acta.parse(
            "analyzer:\n  exclude:\n    - build/**  # generated\n")
        self.assertEqual(conf["exclude"], ["build/**"])

    def test_a_section_ends_at_the_next_key(self):
        conf = acta.parse("analyzer:\n  exclude:\n    - build/**\n"
                          "  errors:\n    unused_import: ignore\n")
        self.assertEqual(conf["exclude"], ["build/**"])
        self.assertEqual(conf["errors"], {"unused_import": "ignore"})


class WhatItSaysWhenItPasses(unittest.TestCase):

    def test_the_success_line_carries_the_number(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = acta.main()
        self.assertEqual(code, 0, out.getvalue())
        self.assertRegex(out.getvalue(), r"all \d{3,} \.dart files")


if __name__ == "__main__":
    unittest.main(verbosity=2)
