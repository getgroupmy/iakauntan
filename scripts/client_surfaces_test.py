#!/usr/bin/env python3
"""Self-test for client_surfaces.py.

This module exists because three gates independently pinned their scope
to `repository.dart`, so the assertions that matter most here are about
the SCOPE rather than the regexes: that it is more than one file, and
more than one directory. A narrowed scope does not look like a failure
from the outside — every gate downstream goes on reporting a clean sweep
over whatever it can still see. That is the only reason this file exists.
"""

from __future__ import annotations

import importlib.util
import pathlib
import unittest

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
SPEC = importlib.util.spec_from_file_location("cs", HERE / "client_surfaces.py")
cs = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(cs)


class TheScopeIsWiderThanOneFile(unittest.TestCase):
    """Every assertion here would have passed before the bug and fails
    if the scope is narrowed back."""

    def setUp(self):
        self.touching = cs.surfaces_that_touch_the_database(ROOT)

    def test_many_dart_files_are_found_at_all(self):
        self.assertGreater(len(cs.dart_files(ROOT)), 300)

    def test_more_than_one_surface_touches_the_database(self):
        self.assertGreater(len(self.touching), 1, self.touching)

    def test_repository_dart_is_not_the_only_surface(self):
        """The exact regression. `repository.dart` holds most of it, which
        is what made reading only that file look sufficient for months."""
        names = {f.name for f in self.touching}
        self.assertIn("repository.dart", names)
        self.assertGreater(len(names - {"repository.dart"}), 5, sorted(names))

    def test_the_surfaces_span_more_than_one_directory(self):
        """`app/lib/src/data` is a convention, not a boundary:
        `settings_screen.dart` updates `organizations` directly, and a
        glob of the data directory alone would not see it."""
        dirs = {f.parent.relative_to(ROOT).as_posix() for f in self.touching}
        self.assertGreater(len(dirs), 1, sorted(dirs))
        self.assertTrue(
            any(not d.endswith("src/data") for d in dirs),
            "every surface is in src/data, so this test cannot tell a "
            "whole-app glob from a data-directory one: %s" % sorted(dirs))

    def test_a_screen_writing_a_table_directly_is_in_scope(self):
        """Named, because these four are the ones a directory glob missed
        and they are the reason the scope is `app/lib`."""
        writes = cs.DIRECT.findall(cs.client_text(ROOT))
        tables = {m[0] for m in writes}
        for table in ("inbound_emails", "organizations", "firm_members",
                      "profiles"):
            self.assertIn(table, tables)


class JoiningTheFiles(unittest.TestCase):

    def test_a_pattern_cannot_match_across_two_files(self):
        """`client_text` newline-joins. The write pattern spans lines on
        purpose, so a file ending mid-expression would otherwise splice
        onto the start of the next one and invent a write that is in
        neither file."""
        tmp = pathlib.Path(self.enterContext(
            __import__("tempfile").TemporaryDirectory()))
        lib = tmp / "app" / "lib"
        lib.mkdir(parents=True)
        (lib / "a.dart").write_text("client.from('invented')")
        (lib / "b.dart").write_text(".insert({'x': 1})")
        self.assertEqual(cs.DIRECT.findall(cs.client_text(tmp)), [])

    def test_each_file_is_still_readable_on_its_own(self):
        tmp = pathlib.Path(self.enterContext(
            __import__("tempfile").TemporaryDirectory()))
        lib = tmp / "app" / "lib"
        (lib / "deep" / "deeper").mkdir(parents=True)
        (lib / "one.dart").write_text("callRpc('a')")
        (lib / "deep" / "deeper" / "two.dart").write_text("callRpcOnce('b')")
        got = {f.name: t for f, t in cs.by_file(tmp).items()}
        self.assertEqual(set(got), {"one.dart", "two.dart"})

    def test_the_glob_reaches_nested_directories(self):
        tmp = pathlib.Path(self.enterContext(
            __import__("tempfile").TemporaryDirectory()))
        deep = tmp / "app" / "lib" / "src" / "features" / "x"
        deep.mkdir(parents=True)
        (deep / "screen.dart").write_text("client.from('t').delete()")
        self.assertEqual([f.name for f in cs.dart_files(tmp)], ["screen.dart"])


class ReadingTheCalls(unittest.TestCase):

    def test_both_rpc_wrappers_are_found(self):
        self.assertEqual(
            sorted(cs.RPC.findall("callRpc('a'); callRpcOnce('b')")),
            ["a", "b"])

    def test_whitespace_after_the_paren_does_not_hide_a_call(self):
        self.assertEqual(cs.RPC.findall("callRpc(\n    'a',\n)"), ["a"])

    def test_a_dynamic_name_is_not_matched(self):
        """Deliberately narrow: the gate must be certain what it reports,
        and `callRpc(name)` names nothing it could check."""
        self.assertEqual(cs.RPC.findall("callRpc(name)"), [])

    def test_the_four_write_verbs_and_not_select(self):
        found = cs.DIRECT.findall(
            "client.from('a').insert({}); client.from('b').update({}); "
            "client.from('c').delete(); client.from('d').upsert({}); "
            "client.from('e').select('*')")
        self.assertEqual({(m[0], m[2]) for m in found},
                         {("a", "insert"), ("b", "update"),
                          ("c", "delete"), ("d", "upsert")})

    def test_a_write_split_across_lines_is_found(self):
        found = cs.DIRECT.findall("client\n    .from('t')\n    .update({})")
        self.assertEqual([(m[0], m[2]) for m in found], [("t", "update")])


class TheRealCountsAreMeasuredNotPinned(unittest.TestCase):
    """Floors, not equalities. A floor does not need editing every time a
    screen is added, and still fails if the scope collapses."""

    def test_the_direct_writes_outnumber_what_one_file_holds(self):
        """169 across the app, 144 in `repository.dart`. Asserted as a
        floor above the one-file figure so that reverting the scope fails
        here rather than quietly reporting less."""
        self.assertGreater(len(cs.DIRECT.findall(cs.client_text(ROOT))), 150)

    def test_the_rpc_calls_outnumber_what_one_file_holds(self):
        """597 across the app, 576 in `repository.dart`."""
        self.assertGreater(len(set(cs.RPC.findall(cs.client_text(ROOT)))), 590)


if __name__ == "__main__":
    unittest.main(verbosity=2)
