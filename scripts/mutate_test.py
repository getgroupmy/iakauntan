#!/usr/bin/env python3
"""The mutation harnesses' own assertions.

    python3 scripts/mutate_test.py

Small, and worth having, because of how this went wrong. `mutate.py`
prepended the literal string `/opt/flutter-sdk/bin` to PATH. When the
repository's pin moved from Flutter 3.32.0 to 3.47.4 that path still
EXISTED and still held a working `flutter` -- just the wrong one. So
every mutant ran against a compiler the project no longer uses, the
baseline failed, and the run printed six mutants killed and the control
killed along with them.

The control caught it, which is the argument for insisting on one. This
is so the next toolchain move does not need the control to catch it.
"""
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    'mutate', Path(__file__).with_name('mutate.py'))
mutate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mutate)

SQL_SPEC = importlib.util.spec_from_file_location(
    'mutate_sql', Path(__file__).with_name('mutate_sql.py'))
mutate_sql = importlib.util.module_from_spec(SQL_SPEC)
SQL_SPEC.loader.exec_module(mutate_sql)


class SdkResolution(unittest.TestCase):
    """`_flutter_bin`, against SDK directories built in a temp tree."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def sdk(self, name, version=None, style='plain'):
        """An SDK directory, with a runnable `flutter` in it."""
        bin_dir = self.root / name / 'bin'
        bin_dir.mkdir(parents=True)
        (bin_dir / 'flutter').write_text('#!/bin/sh\n')
        if version and style == 'plain':
            (self.root / name / 'version').write_text(version + '\n')
        elif version and style == 'json':
            cache = bin_dir / 'cache'
            cache.mkdir()
            (cache / 'flutter.version.json').write_text(
                json.dumps({'flutterVersion': version}))
        return bin_dir

    def resolve(self, pinned):
        """`_flutter_bin` looking in the temp tree instead of /opt.

        Passed rather than monkeypatched. The first version of this test
        replaced `os.path.join` and proved nothing: the generic path was
        a literal in the source, so the replacement never saw it and the
        test failed for a reason of its own making.
        """
        mutate.pinned_version = lambda: pinned
        return mutate._flutter_bin(opt=str(self.root))

    def test_an_sdk_named_after_the_pin_wins(self):
        want = self.sdk('flutter-3.47.4')
        self.sdk('flutter-sdk', '3.32.0')
        self.assertEqual(self.resolve('3.47.4'), str(want))

    def test_and_needs_no_version_file_to_do_it(self):
        # The 3.47 SDK ships no `version` file at all -- Flutter moved
        # it to bin/cache/flutter.version.json. Requiring one made a
        # correct SDK look like an SDK of unknown version, which is the
        # same answer as the wrong one.
        want = self.sdk('flutter-3.47.4')
        self.assertFalse((self.root / 'flutter-3.47.4' / 'version').exists())
        self.assertEqual(self.resolve('3.47.4'), str(want))

    def test_the_generic_path_is_taken_only_when_it_matches(self):
        want = self.sdk('flutter-sdk', '3.47.4')
        self.assertEqual(self.resolve('3.47.4'), str(want))

    def test_and_refused_when_it_holds_a_different_version(self):
        # THE BUG. `/opt/flutter-sdk` held 3.32.0 while the pin said
        # 3.47.4, and the old code took it because the path existed.
        self.sdk('flutter-sdk', '3.32.0')
        self.assertNotEqual(
            self.resolve('3.47.4'),
            str(self.root / 'flutter-sdk' / 'bin'))

    def test_a_json_version_file_is_read_too(self):
        want = self.sdk('flutter-sdk', '3.47.4', style='json')
        self.assertEqual(self.resolve('3.47.4'), str(want))

    def test_nothing_suitable_prepends_nothing(self):
        # Rather than prepending a path that does not exist, which
        # would leave `flutter` unresolvable for a reason this script
        # invented.
        self.sdk('flutter-sdk', '3.32.0')
        resolved = self.resolve('3.47.4')
        self.assertNotIn(str(self.root), resolved)


class PinnedVersion(unittest.TestCase):
    """The pin is read from the workflow, not repeated here."""

    def test_this_repository_pins_something(self):
        version = mutate.pinned_version()
        self.assertIsNotNone(
            version, 'no flutter-version found in .github/workflows/ci.yml')
        self.assertRegex(version, r'^\d+\.\d+\.\d+$')

    def test_and_the_harness_finds_a_flutter_for_it(self):
        # Not an assertion about which SDK, because a contributor's
        # machine may keep it anywhere. Only that the answer is not the
        # silent empty string on a machine that does have one.
        import shutil
        if not shutil.which('flutter') and not os.path.exists(
                '/opt/flutter-sdk/bin/flutter'):
            self.skipTest('no Flutter SDK on this machine')
        self.assertTrue(mutate._flutter_bin() or shutil.which('flutter'))


class PatternMustBeUnique(unittest.TestCase):
    """`apply_once`, and the survivor that was never a survivor.

    `statement_import.dart` holds two statement parsers, and both of
    them contain, verbatim:

        if (date == null) {
          problems.add(

    A mutant anchored on those two lines and aimed at the second landed
    in the first, because the replacement takes the first match. The
    test file under it does not reach the first parser, so the mutant
    survived -- and was reported under the name of the function whose
    assertion was there and correct all along.

    The control cannot catch this one: the control applied cleanly and
    the baseline passed. Only refusing the ambiguous pattern catches it.
    """

    SOURCE = """void first() {
  if (date == null) {
    problems.add('one');
  }
}

void second() {
  if (date == null) {
    problems.add('two');
  }
}
"""

    def test_a_unique_pattern_is_applied(self):
        out, why = mutate.apply_once(
            self.SOURCE, "problems.add('two');", "return;")
        self.assertIsNone(why)
        self.assertIn("return;", out)
        # And only there. The first function is untouched.
        self.assertIn("problems.add('one');", out)

    def test_a_pattern_matching_twice_is_refused(self):
        out, why = mutate.apply_once(
            self.SOURCE,
            "  if (date == null) {\n    problems.add(",
            "  if (date == null) {\n    if (true) return;\n    problems.add(")
        self.assertIsNotNone(why)
        self.assertIn('2 places', why)
        # Refused, not half-applied. Returning the mutated text with a
        # warning would leave the caller free to write it out.
        self.assertEqual(out, self.SOURCE)

    def test_a_pattern_that_is_not_there_is_refused(self):
        out, why = mutate.apply_once(self.SOURCE, 'nothing like this', 'x')
        self.assertEqual(why, 'pattern not found')
        self.assertEqual(out, self.SOURCE)

    def test_extending_the_pattern_by_one_line_is_the_fix(self):
        # What the docstring tells the author to do, asserted so the
        # advice stays true.
        out, why = mutate.apply_once(
            self.SOURCE,
            "  if (date == null) {\n    problems.add('two');",
            "  if (date == null) {\n    if (true) return;\n"
            "    problems.add('two');")
        self.assertIsNone(why)
        self.assertIn("if (true) return;", out)
        self.assertIn("problems.add('one');", out)


class GrantsCarriedWithTheBlock(unittest.TestCase):
    """`mutate_sql.grants`, and why it exists.

    A function's privileges do not always survive a replace here. When
    `open_shared_document` is restated, `proacl` comes back without
    `anon`, which is why the migrations that restate it re-grant on the
    next line.

    `mutate_sql.py` applies the BLOCK ALONE, so before this the sweep
    took that privilege away for its whole run. `document_share.sql`
    asserts it, so every mutant was reported killed -- and so was the
    control, which is the only reason anybody found out. Worse, the
    restore did not put it back: the harness left the database with a
    share link that no longer opened for the customer it was emailed to.
    """

    MIGRATION = """
create or replace function public.open_shared_document(p_token text)
 returns jsonb
 language plpgsql
as $function$
begin
  return jsonb_build_object('state', 'open');
end;
$function$;

grant execute on function public.open_shared_document(text)
  to anon, authenticated;

create or replace function app.calc_document_line()
 returns trigger
 language plpgsql
as $function$
begin
  return new;
end;
$function$;
"""

    def test_a_granted_function_carries_its_grant(self):
        keep = mutate_sql.grants(self.MIGRATION, 'open_shared_document')
        self.assertIn('grant execute', keep)
        self.assertIn('anon', keep)

    def test_a_trigger_function_carries_nothing(self):
        # Nothing is granted on a trigger function and nothing should be
        # invented. `calc_document_line` is the one 0641 swept.
        self.assertEqual(
            mutate_sql.grants(self.MIGRATION, 'calc_document_line'), '')

    def test_another_function_s_grant_is_not_taken(self):
        # The regex has to be anchored on the NAME. Carrying one
        # function's grant onto another would hand a privilege to a
        # role during a sweep, which is the opposite failure and a
        # worse one.
        migration = self.MIGRATION + (
            '\ngrant execute on function public.share_document(uuid)'
            ' to authenticated;\n')
        keep = mutate_sql.grants(migration, 'open_shared_document')
        self.assertNotIn('share_document', keep)

    def test_a_revoke_is_not_mistaken_for_a_grant(self):
        migration = (
            'revoke execute on function public.open_shared_document(text)'
            ' from anon;\n')
        self.assertEqual(
            mutate_sql.grants(migration, 'open_shared_document'), '')

    def test_the_real_migration_this_came_out_of(self):
        # 0642 restates `open_shared_document` and re-grants it. If a
        # later edit drops that line, this fails here rather than by
        # killing a control on somebody's next sweep.
        path = (Path(__file__).parent.parent / 'supabase' / 'migrations'
                / '0642_the_other_number_a_hotel_has_to_print.sql')
        keep = mutate_sql.grants(path.read_text(), 'open_shared_document')
        self.assertIn('anon', keep)


if __name__ == '__main__':
    unittest.main(verbosity=2)
