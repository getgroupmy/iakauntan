#!/usr/bin/env python3
"""The document-type gate's own assertions.

    python3 scripts/check_document_types_test.py

Beside `check_orphan_columns_test.py`, `mutate_test.py` and the rest,
and for the reason they all give: a gate that is wrong is worse than no
gate, because it is believed.

This one exists because a DOCUMENT was believed for months —
`docs/gaps-against-autocount.md` named five document types as having no
screen while four of them had one, and called the fifth "the one that
will be missed" when returning goods to a supplier was never missing.
"""
import importlib.util
import io
import contextlib
import sys
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    'check_document_types',
    Path(__file__).with_name('check_document_types.py'))
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


def run(**patch):
    """Run `main` with some of the module's globals replaced."""
    saved = {k: getattr(gate, k) for k in patch}
    for k, v in patch.items():
        setattr(gate, k, v)
    try:
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            with contextlib.redirect_stdout(io.StringIO()):
                code = gate.main()
        return code, err.getvalue()
    finally:
        for k, v in saved.items():
            setattr(gate, k, v)


class ReadingTheTwoSides(unittest.TestCase):
    def test_the_enums_come_out_of_the_description(self):
        values = gate.enum_values()
        self.assertIn('invoice', values['sales_doc_type'])
        self.assertIn('bill', values['purchase_doc_type'])

    def test_the_screens_come_out_of_doc_types_dart(self):
        have = gate.screened()
        self.assertIn('invoice', have)
        self.assertIn('goods_received', have)

    def test_a_type_named_only_in_a_comment_is_not_a_screen(self):
        # `doc_types.dart` explains each entry at length, and several
        # comments name a type that has no entry of its own. Counting
        # those would clear exactly the gap this looks for — the same
        # trap `check_orphan_columns.py`, `check_web_plugin_registrant`
        # and `check_android_compile_sdk` each fell into.
        self.assertNotIn('purchase_return', gate.screened())


class ItRefusesEachWayItCanBeWrong(unittest.TestCase):
    """Four failures, proved by causing each."""

    def test_a_type_with_no_screen(self):
        code, said = run(NO_SCREEN={})
        self.assertEqual(code, 1)
        self.assertIn('purchase_return', said)
        self.assertIn('nobody can open', said)

    def test_a_screen_for_a_type_the_database_has_not(self):
        # The quieter one: the list offers a document the insert
        # refuses, with a check constraint's message rather than a
        # sentence.
        invented = '_'.join(['type', 'that', 'does', 'not', 'exist'])
        # The real function is captured BEFORE it is replaced. A lambda
        # that called `gate.screened()` would be calling itself by the
        # time `main` runs, which is a RecursionError rather than a
        # test.
        real = gate.screened
        code, said = run(screened=lambda: real() | {invented})
        self.assertEqual(code, 1)
        self.assertIn(invented, said)

    def test_an_exemption_for_a_type_that_is_gone(self):
        gone = '_'.join(['type', 'since', 'dropped'])
        code, said = run(
            NO_SCREEN={**gate.NO_SCREEN,
                       gone: 'a reason long enough to read'})
        self.assertEqual(code, 1)
        self.assertIn(gone, said)

    def test_an_exemption_for_a_type_that_has_a_screen_now(self):
        # Then the file reads as a list of what is missing while
        # describing something that is not.
        code, said = run(
            NO_SCREEN={**gate.NO_SCREEN,
                       'invoice': 'left behind after a screen was built'})
        self.assertEqual(code, 1)
        self.assertIn('on the list of screens now', said)


class EveryExemptionSaysWhy(unittest.TestCase):
    def test_each_entry_carries_a_sentence(self):
        for name, reason in gate.NO_SCREEN.items():
            self.assertTrue(reason and len(reason) > 20,
                            f'{name} is exempt without a reason')

    def test_and_the_one_there_is_names_what_does_the_job(self):
        # `purchase_return` is exempt because a purchase CREDIT NOTE
        # does it. If that ever stops being true the reason has to
        # change with it.
        self.assertIn('credit note', gate.NO_SCREEN['purchase_return'])


class AgainstThisRepository(unittest.TestCase):
    def test_it_passes(self):
        code, _ = run()
        self.assertEqual(code, 0)

    def test_and_the_four_types_it_was_wrong_about_have_screens(self):
        # `docs/gaps-against-autocount.md` named these as unreachable
        # for months after they were built. If one is ever removed,
        # this says which rather than the document going stale again.
        have = gate.screened()
        for name in ('proforma', 'refund_note', 'purchase_request',
                     'purchase_debit_note'):
            self.assertIn(name, have)


if __name__ == '__main__':
    sys.exit(unittest.main(verbosity=2))
