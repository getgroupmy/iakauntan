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
import re
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


class NoGatePinsTheClientToOneFile(unittest.TestCase):
    """The regression, as a rule rather than three repairs.

    `check_write_doors`, `check_write_idempotency` and
    `check_idempotent_calls` each had their OWN copy of

        CLIENT = REPO / "app" / "lib" / "src" / "data" / "repository.dart"

    and each reported a clean sweep over it while claiming something about
    the client. A gate may legitimately pin a path under `app/lib` when
    its subject IS that one file -- the currency map, the route table, the
    document-type map are each declared in exactly one place. What it may
    not do is pin a path and then claim something about the CLIENT, which
    is eleven files.

    So: an allow-list with a reason each, failing both ways. A new pin
    fails until somebody says which kind it is, and a reason whose pin has
    gone fails too, because an excuse nobody prunes is not evidence.
    """

    #: gate -> why pinning one file is right for it. Each of these is the
    #: SINGLE declaration site of the thing the gate is about, and each
    #: docstring scopes its claim to that thing rather than to the client.
    ALLOWED = {
        "check_currency_decimals.py":
            "compares two KNOWN copies -- the const map in format.dart "
            "against the ref_currencies seed -- which is the whole point; "
            "there is no third copy to miss",
        "check_document_types.py":
            "`docTypes` in doc_types.dart is the one map the router builds "
            "every document address from; it is declared nowhere else",
        "check_routes.py":
            "pins router.dart for the route TABLE, which is the only file "
            "containing `GoRoute(`, and already globs lib/ for the call "
            "sites -- the input side was never narrow",
    }
    # Deliberately NOT here: `check_push_channels` (pins
    # supabase/functions/send-push/index.ts), `check_android_compile_sdk`
    # and `check_web_plugin_registrant` (both pin app/.dart_tool/
    # package_config.json). All three pin a single file for the same good
    # reason, but none of them pins a path under `app/lib`, so none is in
    # scope here -- and listing them anyway made the staleness assertion
    # below fail on the first run, which is what it is for.

    #: A module-level constant built from REPO/ROOT by path division.
    ASSIGN = re.compile(r"^[A-Z_][A-Z_0-9]*\s*=\s*(?:REPO|ROOT)\s*/(.+)$",
                        re.M)

    @staticmethod
    def _is_a_file_pin(rhs: str) -> bool:
        """A FILE pin, not a directory root.

        `LIB = ROOT / 'app' / 'lib'` and
        `AUTH = ROOT / 'app' / 'lib' / 'src' / 'features' / 'auth'` are
        directory roots that the gate then globs — the correct pattern, and
        ten gates use it. What this looks for is a path whose LAST segment
        names a file, because that is the one that cannot grow.
        """
        segments = re.findall(r"""['"]([^'"]+)['"]""", rhs)
        if not segments:
            return False
        last = segments[-1]
        # `app/lib/src/core/format.dart` may arrive as one segment.
        return "." in last.rsplit("/", 1)[-1]

    def pinned(self):
        found = {}
        for g in sorted(HERE.glob("check_*.py")):
            if g.name.endswith("_test.py"):
                continue
            for m in self.ASSIGN.finditer(g.read_text()):
                rhs = m.group(1)
                joined = "".join(re.findall(r"""['"]([^'"]+)['"]""", rhs))
                in_client = "app/lib" in joined or (
                    "app" in rhs and "lib" in rhs)
                if in_client and self._is_a_file_pin(rhs):
                    found[g.name] = True
        return found

    def test_every_gate_pinning_a_client_path_is_allowed_with_a_reason(self):
        unexplained = sorted(set(self.pinned()) - set(self.ALLOWED))
        self.assertEqual(
            unexplained, [],
            "%s pin a path under app/lib. If the gate's subject IS that one "
            "file, add it to ALLOWED here saying so. If the gate is about "
            "THE CLIENT, it must take its scope from client_surfaces.py "
            "instead -- that is the bug this list exists for." % unexplained)

    def test_no_reason_outlives_its_pin(self):
        stale = sorted(set(self.ALLOWED) - set(self.pinned()))
        self.assertEqual(
            stale, [],
            "%s are in ALLOWED but no longer pin a client path. Drop the "
            "entries." % stale)

    def test_the_three_repaired_gates_no_longer_pin_one_file(self):
        """Named, so the specific regression fails by name.

        The import AND a use of it, not the mere presence of the string:
        all three mention `client_surfaces.py` in a comment explaining the
        bug, so `assertIn("client_surfaces", text)` passes on a gate that
        has stopped importing it. A mutant that swapped the import for
        `import pathlib as client_surfaces_NOT` survived exactly that way.
        """
        for gate in ("check_write_doors.py", "check_write_idempotency.py",
                     "check_idempotent_calls.py"):
            text = (HERE / gate).read_text()
            self.assertRegex(text, r"(?m)^import client_surfaces\b", gate)
            self.assertRegex(text, r"client_surfaces\.\w+\(", gate)
            self.assertNotIn('"repository.dart"', text, gate)
            self.assertNotIn("'repository.dart'", text, gate)


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
