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
import tempfile
import unittest

import check_capture_is_kept as gate


def tree(flow: str, sheet: str = 'await repo.deleteAttachmentById(id);'):
    root = pathlib.Path(tempfile.mkdtemp())
    for rel, body in ((gate.FLOW, flow), (gate.ASKED, sheet)):
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(body)
    return root


def run(root: pathlib.Path) -> tuple[str, int]:
    """The real `main`, over a built tree, with its output captured."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = gate.main(root)
    return buf.getvalue(), code


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
        root = pathlib.Path(tempfile.mkdtemp())
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

    def test_the_fault_makes_main_fail_and_name_the_line(self):
        out, code = run(tree('await repo.deleteAttachmentById(a);\n'))
        self.assertEqual(code, 1)
        self.assertIn(gate.FLOW, out)
        self.assertIn('deletes the file it just made', out)


if __name__ == '__main__':
    unittest.main()
