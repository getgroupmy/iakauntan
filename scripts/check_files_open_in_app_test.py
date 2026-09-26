#!/usr/bin/env python3
"""The private-file sweep's own assertions.

    python3 scripts/check_files_open_in_app_test.py

A gate that is wrong is worse than no gate, because it is believed.

THE FIRST VERSION OF THIS SWEEP WAS TOO NARROW, and its own self-test
said it was fine. It matched the two helpers that happened to exist --
`attachmentUrl` and `chatFileUrl` -- and there were two more it had
never heard of, on the mail and feedback buckets, each handing a signed
URL to the external browser. A rename would have left it matching
nothing while still printing `ok`.

It matches `createSignedUrl` now: the primitive, which comes from the
Supabase client and which nothing in this repository can rename.
"""
import importlib.util
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    'check_files_open_in_app',
    Path(__file__).with_name('check_files_open_in_app.py'))
sweep = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sweep)


class ItRecognisesACall(unittest.TestCase):
    def test_a_plain_call(self):
        self.assertTrue(
            sweep.CALL.search("client.storage.from('x').createSignedUrl(p, 60)"))

    def test_across_a_line_break(self):
        # Every real one in this repository was wrapped by the
        # formatter, and a pattern anchored to `.createSignedUrl` on the
        # same line as its receiver would have missed all of them.
        self.assertTrue(sweep.CALL.search(
            "client.storage\n    .from('x')\n    .createSignedUrl(p, 60);"))

    def test_with_a_space_before_the_bracket(self):
        self.assertTrue(sweep.CALL.search('createSignedUrl (p, 60)'))

    def test_but_not_a_name_that_merely_ends_the_same_way(self):
        self.assertIsNone(sweep.CALL.search('myCreateSignedUrl(p)'))

    def test_and_not_a_public_url_which_is_public_on_purpose(self):
        # Logos are served publicly by design; this sweep is about
        # PRIVATE objects and must not start refusing those.
        self.assertIsNone(sweep.CALL.search("from('logos').getPublicUrl(p)"))

    def test_and_not_the_viewer_that_replaced_it(self):
        self.assertIsNone(sweep.CALL.search('await showFileInApp(context, ref)'))


class TheRealTree(unittest.TestCase):
    """And the app it guards actually passes it.

    Run here as well as in the sweep, because a self-test over synthetic
    strings alone would go on passing after somebody pointed the sweep
    at a directory that does not exist.
    """

    def test_nothing_mints_one(self):
        self.assertEqual(sweep.main(), 0)

    def test_the_allowlist_is_empty_and_that_is_the_point(self):
        # Every private file is read as bytes now, so there is no
        # legitimate caller left. A future one goes in WITH ITS REASON.
        self.assertEqual(sweep.ALLOWED, set())

    def test_and_the_viewer_exists_to_send_them_to(self):
        root = Path(__file__).resolve().parent.parent
        viewer = root / 'app/lib/src/features/shared/file_viewer.dart'
        self.assertTrue(viewer.exists())
        self.assertIn('showFileInApp', viewer.read_text())


if __name__ == '__main__':
    unittest.main()
