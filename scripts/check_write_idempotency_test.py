#!/usr/bin/env python3
"""The write-idempotency gate's own assertions.

    python3 scripts/check_write_idempotency_test.py

Beside the other gate tests, for the reason they all give: a gate that is
wrong is worse than no gate, because it is believed.

The ways THIS one could lie are specific, and the first is not
hypothetical — it is the bug the gate was written after. A census of the
client's writes was taken with a line-based `grep` and found 192 of 577
call sites, because `await callRpc(` and the function name are on
different lines a quarter of the time. So the first test here is a call
site split across lines, and it fails against that grep.

The rest: a verdict must stop excusing a function when the evidence for
it goes (a renamed unique index), a function must not be counted as
"inserts nothing" when something it calls inserts, and the ratchet must
actually ratchet in both directions.
"""
import importlib.util
import io
import contextlib
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    'check_write_idempotency',
    Path(__file__).with_name('check_write_idempotency.py'))
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


class FindingCallSites(unittest.TestCase):
    def test_one_line(self):
        self.assertEqual(
            gate.client_calls("await callRpc('post_expense', params: {})"),
            {'post_expense'})

    def test_split_across_lines(self):
        """The bug this gate exists after."""
        src = """
    final data = await callRpc(
      'email_receipt',
      params: {
        'p_receipt_id': receiptId,
      },
    );
"""
        self.assertEqual(gate.client_calls(src), {'email_receipt'})

    def test_callRpcOnce_counts_too(self):
        self.assertEqual(
            gate.client_calls("await callRpcOnce(\n  'email_document',"),
            {'email_document'})

    def test_the_real_client_has_far_more_than_192(self):
        """The measurement, against the file itself.

        Pinned as a floor rather than a number: what matters is that it is
        nowhere near the 192 a line-based scan reported, and a floor does
        not need editing every time a function is added.
        """
        found = gate.client_calls(gate.CLIENT.read_text())
        self.assertGreater(len(found), 400)


class ReadingAFunction(unittest.TestCase):
    def test_transitive_reaches_one_level_down(self):
        defs = {
            'post_thing': ['begin perform app.do_the_insert(p_id); end'],
            'do_the_insert': ['begin insert into public.things values (1); end'],
        }
        text = gate.transitive(defs, 'post_thing')
        self.assertTrue(gate.INSERTS.search(text),
                        'an insert in what it calls is still an insert')

    def test_a_function_that_only_updates_inserts_nothing(self):
        defs = {'retire_thing': ['begin update public.things set x = 1; end']}
        self.assertFalse(
            gate.INSERTS.search(gate.transitive(defs, 'retire_thing')))

    def test_recursion_does_not_hang(self):
        defs = {'a': ['begin perform public.a(1); end']}
        self.assertEqual(gate.transitive(defs, 'a').count('perform'), 1)


class TheGuardPhrase(unittest.TestCase):
    def test_the_refusals_this_schema_actually_writes(self):
        for phrase in ("Adjustment % is already posted",
                       "That contra is already void.",
                       "Journal % has already been reversed",
                       "That transfer is already sent.",
                       "Certificate % is already posted"):
            self.assertTrue(gate.GUARD.search(phrase), phrase)

    def test_and_not_any_sentence_with_already_in_it(self):
        self.assertIsNone(
            gate.GUARD.search('the figures already agree with the statement'))


class Verdicts(unittest.TestCase):
    """Every verdict names evidence, and the shipped ones are well formed."""

    def test_every_shipped_verdict_has_a_known_kind(self):
        for name, verdict in gate.VERDICTS.items():
            kind, sep, detail = verdict.partition(':')
            self.assertEqual(sep, ':', f'{name} has no kind')
            self.assertIn(kind, ('unique', 'natural', 'repeats'), name)
            self.assertTrue(detail.strip(), f'{name} names no evidence')

    def test_a_unique_verdict_names_an_index_not_a_table(self):
        for name, verdict in gate.VERDICTS.items():
            if verdict.startswith('unique:'):
                self.assertIn('_key', verdict.split(':', 1)[1], name)


class TheRatchet(unittest.TestCase):
    """main(), with psql replaced, because the ratchet is the whole point."""

    def run_gate(self, *, volatile, keyed, defs, uniques, client, backlog,
                 verdicts=None):
        """The gate over a made-up schema.

        `VERDICTS` is swapped too — the shipped ones name real functions
        and would all read as stale against a two-function fake, which is
        the staleness check working rather than a test failure.
        """
        answers = {
            gate.VOLATILE_SQL: volatile,
            gate.KEYED_SQL: keyed,
            gate.INDEXES_SQL: uniques,
            gate.DEFS_SQL: [f'public.{n}\x01{b}' for n, b in defs.items()],
        }
        real_psql, real_backlog, real_client = (
            gate.psql, gate.BACKLOG, gate.CLIENT)
        real_verdicts = dict(gate.VERDICTS)
        gate.VERDICTS.clear()
        gate.VERDICTS.update(verdicts or {})
        tmp = Path(self.enterContext(__import__('tempfile').TemporaryDirectory()))
        path = tmp / 'repository.dart'
        path.write_text(client)
        gate.psql = lambda db, sql: answers[sql]
        gate.BACKLOG = backlog
        gate.CLIENT = path
        out, err = io.StringIO(), io.StringIO()
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = gate.run("db")
        finally:
            gate.psql, gate.BACKLOG, gate.CLIENT = (
                real_psql, real_backlog, real_client)
            gate.VERDICTS.clear()
            gate.VERDICTS.update(real_verdicts)
        return code, out.getvalue() + err.getvalue()

    def test_a_new_undecided_write_fails(self):
        code, out = self.run_gate(
            volatile=['make_thing'], keyed=[],
            defs={'make_thing': 'begin insert into public.things values (1); end'},
            uniques=[], client="callRpc('make_thing', params: {})", backlog=0)
        self.assertEqual(code, 1)
        self.assertIn('make_thing', out)

    def test_and_passes_once_it_is_within_the_backlog(self):
        code, out = self.run_gate(
            volatile=['make_thing'], keyed=[],
            defs={'make_thing': 'begin insert into public.things values (1); end'},
            uniques=[], client="callRpc('make_thing', params: {})", backlog=1)
        self.assertEqual(code, 0, out)

    def test_a_function_the_client_never_calls_is_not_in_the_population(self):
        code, out = self.run_gate(
            volatile=['nightly_sweep'], keyed=[],
            defs={'nightly_sweep': 'begin insert into public.logs values (1); end'},
            uniques=[], client="// nothing here calls it", backlog=0)
        self.assertEqual(code, 0, out)

    def test_a_stale_unique_verdict_fails(self):
        """The index renamed, the excuse left behind."""
        code, out = self.run_gate(
            volatile=['make_thing'], keyed=[],
            defs={'make_thing': 'begin insert into public.t values (1); end'},
            uniques=['things_other_key'],
            client="callRpc('make_thing', params: {})", backlog=99,
            verdicts={'make_thing': 'unique:things_name_key'})
        self.assertEqual(code, 1)
        self.assertIn('things_name_key', out)

    def test_and_a_verdict_for_something_that_is_not_there_any_more(self):
        code, out = self.run_gate(
            volatile=['make_thing'], keyed=[],
            defs={'make_thing': 'begin update public.t set x = 1; end'},
            uniques=[], client="callRpc('make_thing', params: {})",
            backlog=0, verdicts={'gone_away': 'natural:it used to upsert'})
        self.assertEqual(code, 1)
        self.assertIn('gone_away', out)

    def test_a_keyed_write_is_protected_not_undecided(self):
        code, out = self.run_gate(
            volatile=['make_thing'], keyed=['make_thing'],
            defs={'make_thing': 'begin insert into public.t values (1); end'},
            uniques=[], client="callRpcOnce('make_thing', params: {})",
            backlog=0)
        self.assertEqual(code, 0, out)
        self.assertIn('1 hold an idempotency key', out)


if __name__ == '__main__':
    unittest.main(verbosity=2)
