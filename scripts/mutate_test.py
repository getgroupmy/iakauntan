#!/usr/bin/env python3
"""Which SDK the mutation harness reaches for.

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


if __name__ == '__main__':
    unittest.main(verbosity=2)
