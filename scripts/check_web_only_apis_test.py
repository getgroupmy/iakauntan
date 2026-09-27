#!/usr/bin/env python3
"""The web-only-API gate's own assertions.

    python3 scripts/check_web_only_apis_test.py

Beside the other gate tests, for the reason they all give: a gate that
is wrong is worse than no gate, because it is believed.

The three ways this one could lie: refusing a call that IS guarded,
refusing a member of `Uri.base` that is perfectly safe off the web, and
counting the API where it is only written about -- which matters here
more than usual, because the gate's own file and `safe_link.dart` both
name it many times in prose.
"""
import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    'check_web_only_apis',
    Path(__file__).with_name('check_web_only_apis.py'))
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)

REAL_APP = gate.APP


def run_on(files: dict[str, str]):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / 'app' / 'lib'
        for name, body in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body)
        saved = gate.APP
        gate.APP = root
        try:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = gate.main()
            return code, out.getvalue()
        finally:
            gate.APP = saved


class Refused(unittest.TestCase):
    def test_a_bare_call_is_refused(self):
        code, out = run_on(
            {'a.dart': "final url = '${Uri.base.origin}/#/share/$token';\n"})
        self.assertEqual(code, 1)
        self.assertIn('crash on a phone', out)
        self.assertIn('a.dart:1', out)

    def test_and_one_inside_a_build_method(self):
        code, _ = run_on({'a.dart': '''
Widget build(BuildContext context) {
  final url = menuLinkUrl(Uri.base.origin, token);
  return Text(url);
}
'''})
        self.assertEqual(code, 1)


class Allowed(unittest.TestCase):
    def test_a_kIsWeb_guard_on_the_same_line_is_enough(self):
        code, _ = run_on({'a.dart':
                          "emailRedirectTo: kIsWeb ? Uri.base.origin : null,\n"})
        self.assertEqual(code, 0)

    def test_and_a_guard_on_the_line_the_expression_started_on(self):
        code, _ = run_on({'a.dart': '''
await supabase.auth.signInWithOtp(
  email: email,
  emailRedirectTo: kIsWeb
      ? '${Uri.base.origin}/#/signin'
      : null,
);
'''})
        self.assertEqual(code, 0)

    def test_the_other_members_of_Uri_base_are_fine_off_the_web(self):
        # A file: URI has an empty host; it does not throw. Refusing
        # these would be refusing the workspace lookup, which reads
        # Uri.base.host on every start.
        code, _ = run_on({'a.dart': '''
final label = workspaceLabel(Uri.base.host);
final here = Uri.base.path;
'''})
        self.assertEqual(code, 0)

    def test_safe_link_itself_may_call_it(self):
        code, _ = run_on({'src/core/safe_link.dart': '''
String shareOrigin() {
  final base = Uri.base;
  if (base.isScheme('http')) return Uri.base.origin;
  return 'https://iakauntan.com';
}
'''})
        self.assertEqual(code, 0)


class ProseIsNotCode(unittest.TestCase):
    def test_a_doc_comment_naming_it_is_not_a_call(self):
        code, _ = run_on({'a.dart': '''
/// `Uri.base.origin` THROWS off the web, so this does not call it.
String shareOrigin() => 'https://iakauntan.com';
'''})
        self.assertEqual(code, 0)

    def test_nor_a_block_comment(self):
        code, _ = run_on({'a.dart': '''
/* Was: '${Uri.base.origin}/#/share/$token' */
final url = '${shareOrigin()}/#/share/$token';
'''})
        self.assertEqual(code, 0)

    def test_but_a_comment_does_not_hide_the_call_under_it(self):
        code, out = run_on({'a.dart': '''
// A note about Uri.base.origin
final url = '${Uri.base.origin}/#/share/$token';
'''})
        self.assertEqual(code, 1)
        self.assertIn(':3', out)


class TheRealTree(unittest.TestCase):
    def test_the_repository_passes_its_own_gate(self):
        self.assertTrue(REAL_APP.is_dir(), REAL_APP)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = gate.main()
        self.assertEqual(code, 0, out.getvalue())

    def test_and_the_gate_looked_at_more_than_nothing(self):
        self.assertGreater(len(list(REAL_APP.rglob('*.dart'))), 100)


if __name__ == '__main__':
    unittest.main(verbosity=2)
