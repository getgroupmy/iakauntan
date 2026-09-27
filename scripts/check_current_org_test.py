#!/usr/bin/env python3
"""The switcher-selection gate's own assertions.

    python3 scripts/check_current_org_test.py

Beside `check_document_types_test.py` and the rest, for the reason they
all give: a gate that is wrong is worse than no gate, because it is
believed.

This one in particular. The rule it enforces turns on a NEGATIVE
lookahead -- `currentOrgIdProvider` is fine with `.notifier` after it
and not otherwise -- and a lookahead that is slightly wrong reports a
clean sweep over a codebase full of the bug.
"""
import contextlib
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    'check_current_org',
    Path(__file__).with_name('check_current_org.py'))
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


def scan(source: str, name: str = 'thing.dart') -> list[str]:
    """Run the gate over one file of Dart written here."""
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / name
        path.write_text(source, encoding='utf-8')
        return gate.offenders(tmp)


class WhatCounts(unittest.TestCase):
    def test_a_plain_read_is_an_offence(self):
        bad = scan('final org = ref.read(currentOrgIdProvider);\n')
        self.assertEqual(len(bad), 1)
        self.assertIn('orgIdProvider', bad[0])

    def test_a_watch_is_an_offence_too(self):
        # `ea_form_repository.dart` watched it and handed back a null
        # repository, so every EA form screen was empty.
        self.assertEqual(
            len(scan('final org = ref.watch(currentOrgIdProvider);\n')), 1)

    def test_selecting_is_what_the_provider_is_for(self):
        self.assertEqual(
            scan('ref.read(currentOrgIdProvider.notifier).select(id);\n'), [])

    def test_clearing_too(self):
        self.assertEqual(
            scan('ref.read(currentOrgIdProvider.notifier).clear();\n'), [])

    def test_the_notifier_across_a_line_break_is_still_the_notifier(self):
        # `practice_screen.dart` writes it wrapped:
        #     ref
        #         .read(currentOrgIdProvider.notifier)
        # and a lookahead that forgot the whitespace would fail it.
        self.assertEqual(
            scan('ref.read(currentOrgIdProvider\n    .notifier)\n'), [])

    def test_the_explanation_is_not_the_fault(self):
        # The fix documents the bug by quoting the line that had it.
        self.assertEqual(
            scan('// final org = ref.read(currentOrgIdProvider);\n'), [])

    def test_the_line_number_is_the_offending_line(self):
        bad = scan('\n\n\nfinal org = ref.read(currentOrgIdProvider);\n')
        self.assertIn(':4:', bad[0])

    def test_a_file_that_does_not_mention_it_is_silent(self):
        self.assertEqual(scan('final org = ref.watch(orgIdProvider);\n'), [])


class AgainstTheRealTree(unittest.TestCase):
    def test_the_app_is_clean(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(gate.main(), 0)

    def test_the_declaring_file_is_exempt(self):
        # `currentOrgProvider` reads the selection in order to honour
        # it, which is the one legitimate read in the codebase.
        source = (Path(gate.ROOT) / gate.DECLARED_IN).read_text(
            encoding='utf-8')
        self.assertIn('ref.watch(currentOrgIdProvider)', source)


if __name__ == '__main__':
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
