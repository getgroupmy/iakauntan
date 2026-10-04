#!/usr/bin/env python3
"""Self-test for check_counted_assertions.py.

The gate is a reviewed list with a staleness check, so it has to fail
BOTH ways: a new file that prints nothing on success, and an entry whose
file now prints. A list that only fails one way rots in the other
direction and nobody finds out.

The sharpest assertions here are about `strip_comments`. A gate that
looks for `pg_temp.check_eq` in raw text is satisfied by a COMMENT
naming it, and this repository has now had six separate defects of
exactly that shape — `assertIn("name", source)` matched a comment,
`corp_repository.dart` contains `repository.dart`,
`pg_get_functiondef(...) like '%1120%'` matched a comment and cost a
wrong recommendation. So the comment case is not an edge case here. It
is the failure mode.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import pathlib
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "cca", HERE / "check_counted_assertions.py")
cca = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(cca)


class Harness(unittest.TestCase):

    def gate(self, files, reviewed):
        """`files=None` means the real suite, which is the only scope the
        file floor applies to."""
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cca.run(files, reviewed)
        return code, out.getvalue() + err.getvalue()

    def write(self, name, body):
        d = pathlib.Path(self.enterContext(  # noqa: SIM115
            __import__("tempfile").TemporaryDirectory()))
        f = d / name
        f.write_text(body)
        return f


COUNTS = "perform pg_temp.check_true('it holds', true);\n"
SILENT = "if 1 = 2 then\n  raise exception 'it does not hold';\nend if;\n"


class TheRatchetBothWays(Harness):

    def test_a_silent_file_that_is_reviewed_passes(self):
        f = self.write("silent.sql", SILENT)
        code, said = self.gate([f], {"silent.sql": "a reason"})
        self.assertEqual(code, 0, said)
        self.assertIn("1 assertion file(s) print nothing", said)

    def test_a_new_silent_file_fails_and_names_itself(self):
        f = self.write("fresh.sql", SILENT)
        code, said = self.gate([f], {})
        self.assertEqual(code, 1, said)
        self.assertIn("fresh.sql", said)
        self.assertIn("prints nothing when it passes", said)

    def test_the_failure_says_what_to_do_about_it(self):
        """A gate that names a problem and no remedy gets worked around."""
        f = self.write("fresh.sql", SILENT)
        _, said = self.gate([f], {})
        self.assertIn("_helpers.sql", said)
        self.assertIn("mutate", said)

    def test_an_entry_whose_file_now_prints_fails(self):
        f = self.write("converted.sql", SILENT + COUNTS)
        code, said = self.gate([f], {"converted.sql": "a stale reason"})
        self.assertEqual(code, 1, said)
        self.assertIn("now prints on success", said)
        self.assertIn("nobody prunes", said)

    def test_an_entry_for_a_deleted_file_fails_differently(self):
        """Renamed and 'converted' are different repairs, so different text."""
        code, said = self.gate([], {"gone.sql": "a reason"})
        self.assertEqual(code, 1, said)
        self.assertIn("not an assertion file any more", said)

    def test_a_counted_file_is_not_in_the_list_at_all(self):
        f = self.write("loud.sql", COUNTS)
        code, said = self.gate([f], {})
        self.assertEqual(code, 0, said)
        self.assertIn("the ratchet is at zero", said)


class ACommentIsNotAnAssertion(Harness):

    def test_a_commented_out_helper_call_does_not_count(self):
        sql = "-- perform pg_temp.check_eq('once upon a time', 1, 1);\n" + SILENT
        self.assertEqual(cca.counted_sources(sql), 0)

    def test_a_comment_merely_naming_the_helper_does_not_count(self):
        sql = "-- assert this with pg_temp.check_true one day\n" + SILENT
        self.assertEqual(cca.counted_sources(sql), 0)

    def test_a_double_dash_inside_a_string_does_not_eat_the_line(self):
        """The strip must not swallow real code after a literal's `--`."""
        sql = ("raise notice 'a -- b';\n"
               "perform pg_temp.check_true('still here', true);\n")
        self.assertEqual(cca.counted_sources(sql), 1)

    def test_a_definition_is_not_a_use(self):
        """A file defining its own helper has not thereby asserted."""
        sql = ("create or replace function pg_temp.check_mine(p text)\n"
               "returns void language plpgsql as $$ begin end; $$;\n")
        self.assertEqual(cca.counted_sources(sql), 0)

    def test_a_hand_written_ok_notice_counts(self):
        """The refusal-marker shape ticks in its handler, not via a helper."""
        sql = "exception when foreign_key_violation then\n" \
              "  raise notice 'ok   it was refused';\n"
        self.assertEqual(cca.counted_sources(sql), 1)

    def test_a_notice_that_is_not_an_ok_does_not_count(self):
        """`run_locally.sh` greps `NOTICE:  ok `, so a banner is not one."""
        sql = "raise notice 'matter on a document: the paths carry it';\n"
        self.assertEqual(cca.counted_sources(sql), 0)


class ScopeIsTheSuitesOwn(Harness):

    def test_the_underscore_includes_are_not_assertion_files(self):
        """`_helpers.sql` defines the helpers; it asserts nothing itself,
        and ci.yml excludes it with `grep -cv '/_'`."""
        names = {f.name for f in cca.assertion_files()}
        self.assertNotIn("_helpers.sql", names)
        self.assertNotIn("_local_stack.sql", names)

    def test_it_looks_at_the_whole_suite(self):
        """Not one directory, not one file: the count CI prints is 383."""
        self.assertGreater(len(cca.assertion_files()), 300)

    def test_no_assertion_file_is_silent_any_more(self):
        """The shipped state: the ratchet is at ZERO.

        Asserted as both halves, because either alone rots. An empty
        `UNCOUNTED` with a silent file in the suite is a gate that fails
        CI; a non-empty `UNCOUNTED` with no silent files is an excuse
        nobody pruned. Neither is allowed to be the quiet one.
        """
        self.assertEqual(cca.uncounted(cca.assertion_files()), [])
        self.assertEqual(cca.UNCOUNTED, {})

    def test_the_five_converted_files_each_tick(self):
        """Named rather than counted, so a regression in any one of them
        is a failure here and not just a dip in a suite-wide number."""
        for name, least in (("matter_on_a_document.sql", 19),
                            ("scan_inbox.sql", 24),
                            ("attachment_content_hash.sql", 13),
                            ("tenant_foreign_keys.sql", 14),
                            ("search_path.sql", 3)):
            with self.subTest(name):
                got = cca.counted_sources((cca.TESTS / name).read_text())
                self.assertGreaterEqual(got, least, name)

    def test_an_empty_tests_directory_is_refused(self):
        """The gate shipped without this and passed over an empty
        `supabase/tests`, saying "every one of 0 assertion files says
        something when it passes". The self-test below caught it and the
        gate did not, which is a weaker arrangement than it reads."""
        import tempfile
        real = cca.TESTS
        with tempfile.TemporaryDirectory() as tmp:
            cca.TESTS = pathlib.Path(tmp)
            try:
                code, said = self.gate(None, {})
            finally:
                cca.TESTS = real
        self.assertEqual(code, 2, said)
        self.assertIn("found 0 assertion file(s)", said)
        self.assertIn("nothing to look at", said)

    def test_the_floor_does_not_fire_on_a_fed_fixture(self):
        """Only the default scope is floored, or every test above would
        fail on its two-file fixture."""
        f = self.write("loud.sql", COUNTS)
        code, said = self.gate([f], {})
        self.assertEqual(code, 0, said)

    def test_the_zero_floor_still_has_teeth(self):
        """A floor at zero has one failure mode that looks like success:
        it stops being able to find anything. So prove the finder still
        finds, with a fed file, at the same moment the real suite is
        clean."""
        f = self.write("regressed.sql", SILENT)
        code, said = self.gate([f], {})
        self.assertEqual(code, 1, said)
        self.assertIn("regressed.sql", said)


if __name__ == "__main__":
    unittest.main(verbosity=2)
