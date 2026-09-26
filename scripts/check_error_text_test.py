#!/usr/bin/env python3
"""Assertions on `check_error_text.py`.

    python3 scripts/check_error_text_test.py

A gate that is wrong is worse than no gate, because it is believed.
This one had two ways to be wrong and both are held here:

  * FLAGGING what is not a defect. `repository.dart` maps a list with
    `(e) => '$e'` in one place and catches an error called `e` in
    another. A scan that matched the NAME rather than the BINDING'S
    SCOPE called the map a defect -- and a gate that cries wolf three
    times gets switched off.

  * MISSING what is. The whole point is `Text('$e')` inside a `catch`,
    and a scanner that read a comment or a `//`-apostrophe as a string
    would run past it.

The last test runs the real tree, because a gate that matched nothing
after somebody renamed `errorText` would go on printing `ok`.
"""

import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import check_error_text as G  # noqa: E402


def names(src):
    return sorted(n for _off, n in G.offenders(src))


class TheDefect(unittest.TestCase):
    def test_a_snackbar_showing_a_caught_error(self):
        self.assertEqual(names("""
          try { save(); } catch (e) {
            messenger.showSnackBar(SnackBar(content: Text('$e')));
          }
        """), ['e'])

    def test_the_exact_line_that_was_wrong(self):
        # `runWithFeedback`, as it stood.
        self.assertEqual(names("""
          } catch (err) {
            messenger..hideCurrentSnackBar()..showSnackBar(
                SnackBar(content: Text('$err'), backgroundColor: danger));
            return false;
          }
        """), ['err'])

    def test_an_async_view_error_branch(self):
        self.assertEqual(names(
            "AsyncView(value: v, builder: b, error: (e, _) => Text('\$e'))"),
            ['e'])

    def test_an_error_embedded_in_a_longer_sentence(self):
        self.assertEqual(names("""
          try { go(); } catch (e) { _say('Could not save it: $e'); }
        """), ['e'])

    def test_an_exception_built_around_the_wrapper(self):
        # One step further from the screen, same defect: whatever shows
        # this later shows the envelope inside it.
        self.assertEqual(names("""
          try { read(); } catch (e) {
            throw OcrException('Could not read it here: $e');
          }
        """), ['e'])

    def test_an_escaped_dollar_prints_the_variable_name_itself(self):
        # `'... \$e'` shows a literal "$e" to a person. Worse, not
        # better, than the wrapper.
        self.assertEqual(names(r"""
          try { go(); } catch (e) { _say('Could not create it: \$e'); }
        """), ['e'])


class NotTheDefect(unittest.TestCase):
    def test_a_field_named_on_purpose_is_left_alone(self):
        self.assertEqual(names("""
          try { save(); } catch (e) { _say('${e.message} (${e.code})'); }
        """), [])

    def test_errortext_is_what_the_gate_wants(self):
        self.assertEqual(names("""
          try { save(); } catch (e) { _say(errorText(e)); }
        """), [])

    def test_a_log_line_may_hold_the_whole_object(self):
        self.assertEqual(names("""
          try { save(); } catch (e) { debugPrint('not saved: $e'); }
        """), [])

    def test_a_list_element_called_e_in_another_scope(self):
        # The false positive that a name-matching scan produced, and
        # the reason this walks the binding's block instead.
        self.assertEqual(names("""
          List<String> read(rows) => rows.map((e) => '$e').toList();
          void save() { try { go(); } catch (e) { report(errorText(e)); } }
        """), [])

    def test_a_variable_called_e_before_any_catch(self):
        self.assertEqual(names("""
          final e = 3;
          String show() => 'value $e';
          void save() { try { go(); } catch (e) { report(errorText(e)); } }
        """), [])

    def test_an_apostrophe_in_a_comment_does_not_open_a_string(self):
        # `check_routes.py` lost seventeen routes to exactly this.
        self.assertEqual(names("""
          // the company's own handler
          try { save(); } catch (e) { report(errorText(e)); }
        """), [])

    def test_a_comment_mentioning_the_defect_is_not_the_defect(self):
        self.assertEqual(names("""
          try { save(); } catch (e) {
            // Was Text('$e'), which showed the wrapper.
            report(errorText(e));
          }
        """), [])

    def test_the_catch_block_ends_where_it_ends(self):
        # `$e` after the block belongs to something else.
        self.assertEqual(names("""
          void save() {
            try { go(); } catch (e) { report(errorText(e)); }
          }
          void other(String e) { print2('later $e'); }
        """), [])


class TheRealTree(unittest.TestCase):
    def test_the_gate_still_finds_the_files_it_checks(self):
        files = list(G.LIB.rglob('*.dart'))
        self.assertGreater(len(files), 200, 'lib/ moved or is not being read')

    def test_the_helper_the_gate_sends_people_to_exists(self):
        helper = G.ROOT / 'app/lib/src/core/error_text.dart'
        self.assertTrue(helper.exists(), 'errorText has moved; fix the gate')
        self.assertIn('String errorText(', helper.read_text())

    def test_the_tree_is_clean(self):
        found = []
        for path in G.LIB.rglob('*.dart'):
            for off, name in G.offenders(path.read_text()):
                found.append(f'{path}:{off}:${name}')
        self.assertEqual(found, [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
