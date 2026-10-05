#!/usr/bin/env python3
"""That the gate fails when the two lines come back.

    python3 scripts/check_capture_is_kept_test.py

A gate that passes on a repository where the fault is present reports a
clean sweep about nothing. So this builds the fault and checks it is
seen, builds the opposite fault and checks that is seen too, and checks
the shapes that are NOT findings.
"""
import contextlib
import io
import pathlib
import atexit
import shutil
import tempfile
import unittest

import check_capture_is_kept as gate


def _throwaway() -> str:
    """A temp dir that goes away when the process does.

    These call sites were a bare `mkdtemp` with no cleanup, which never
    removed anything: the three test files that used it leaked 28
    directories between them on EVERY run, locally and in CI. That is
    invisible until the day the disk fills, and a full disk does not
    present as a full disk -- it presents as a test that has gone quiet.
    One did, for fifteen minutes, and was first diagnosed as a slow test
    file.

    `atexit` rather than `addCleanup` because the callers are module-level
    helpers with no TestCase in scope, and rather than
    `TemporaryDirectory` because the directory has to outlive the
    function that builds it.
    """
    root = tempfile.mkdtemp()
    atexit.register(shutil.rmtree, root, True)
    return root


def tree(flow: str, sheet: str = 'await repo.deleteAttachmentById(id);'):
    root = pathlib.Path(_throwaway())
    for rel, body in ((gate.FLOW, flow), (gate.ASKED, sheet)):
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(body)
    return root


def run(root: pathlib.Path) -> tuple[str, int]:
    """The real `main`, over a built tree, with BOTH streams captured.

    Both, because the "cannot see the files" message goes to stderr
    where a failure belongs, and a harness that captures only stdout
    makes an assertion about it vacuous in the dangerous direction: an
    `assertIn` on the empty string fails loudly, but an `assertNotIn`
    passes for the wrong reason.
    """
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = gate.main(root)
    return out.getvalue() + err.getvalue(), code


class TheGate(unittest.TestCase):
    def test_the_reported_fault_is_seen(self):
        root = tree(
            'if (chosen == null) {\n'
            '  await ref.read(repoProvider)?.deleteAttachmentById(x);\n'
            '  return;\n'
            '}\n')
        found = gate.offenders(root)
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0][1], 2)

    def test_both_of_them(self):
        root = tree(
            'await repo.deleteAttachmentById(a);\n'
            'something();\n'
            'await repo.deleteAttachmentById(b);\n')
        self.assertEqual(len(gate.offenders(root)), 2)

    def test_the_fixed_flow_is_clean(self):
        root = tree('// The file stays. Removing it is deliberate now.\n'
                    'return;\n')
        self.assertEqual(gate.offenders(root), [])

    def test_a_comment_naming_the_method_is_not_a_finding(self):
        # The decision is written down in the file it was made in, and
        # writing it down names the method. A gate that reported its own
        # explanation is one somebody deletes the explanation to satisfy.
        root = tree('// It used to call deleteAttachmentById(id) here.\n')
        self.assertEqual(gate.offenders(root), [])

    def test_a_missing_flow_file_is_not_a_finding(self):
        # Renamed or moved. That is not this gate's business to guess at,
        # and inventing a failure would block the rename.
        root = pathlib.Path(_throwaway())
        self.assertEqual(gate.offenders(root), [])

    def test_the_deliberate_remove_going_missing_fails_too(self):
        # The other half of the rule. "A file can never be removed" is
        # not what was asked for either.
        root = tree('return;\n', sheet='// nothing here any more\n')
        out, code = run(root)
        self.assertEqual(code, 1)
        self.assertIn('no longer calls', out)

    def test_a_repository_with_both_halves_right_passes(self):
        out, code = run(tree('return;\n'))
        self.assertEqual(code, 0)
        self.assertIn('ok ', out)

    def test_main_refuses_to_tick_when_it_cannot_see_the_files(self):
        # The distinction `offenders()` above does NOT make, and should
        # not: a missing flow file is not a FINDING, because the file may
        # have been renamed and inventing a defect would block the
        # rename. But `main()` printing "ok a capture is kept until
        # somebody asks for it to go" over a tree with neither file is a
        # claim about something it never read. Both halves used to skip
        # quietly -- `offenders()` returns [] and the canary was guarded
        # by `asked.exists() and ...`.
        root = pathlib.Path(_throwaway())
        out, code = run(root)
        self.assertEqual(code, 2, out)
        self.assertIn('checked nothing', out)
        self.assertIn(gate.FLOW, out)
        self.assertIn(gate.ASKED, out)

    def test_it_says_that_is_not_a_defect_in_the_app(self):
        # A red build with no explanation gets the gate deleted. This one
        # has to say "the file moved" and not imply the rule was broken.
        root = pathlib.Path(_throwaway())
        out, _ = run(root)
        self.assertIn('NOT a defect in the app', out)
        self.assertIn('FLOW and ASKED', out)

    def test_one_missing_file_is_enough(self):
        """Either half alone being unreadable leaves the rule unenforced."""
        for drop in (gate.FLOW, gate.ASKED):
            with self.subTest(drop):
                root = tree('return;\n')
                (root / drop).unlink()
                out, code = run(root)
                self.assertEqual(code, 2, out)
                self.assertIn(drop, out)

    def test_the_fault_makes_main_fail_and_name_the_line(self):
        out, code = run(tree('await repo.deleteAttachmentById(a);\n'))
        self.assertEqual(code, 1)
        self.assertIn(gate.FLOW, out)
        self.assertIn('deletes the file it just made', out)


if __name__ == '__main__':
    unittest.main()
