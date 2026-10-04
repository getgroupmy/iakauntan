#!/usr/bin/env python3
"""Self-test for check_idempotent_calls.py.

The gate had none until the day its scope changed. It was verified by
hand — a `callRpcOnce` planted in `corp_repository.dart`, reported as
`corp_repository.dart:450` — and a verification done by hand once is a
verification nobody will do again.

Four rules are asserted here, and so is the thing the hand check proved:
that a fault is reported against the FILE it is in. Before the scope
widened there was one file, so a wrong filename was impossible; now there
are eleven and it is the obvious way for this gate to mislead.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import pathlib
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "cic", HERE / "check_idempotent_calls.py")
cic = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(cic)


class Harness(unittest.TestCase):
    """Runs the real `run()` over fake surfaces and a fake catalogue."""

    def gate(self, files: dict[str, str],
             protected: dict[str, set[str]] | None = None,
             by_other_name: dict[str, str] | None = None):
        tmp = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory()))
        paths = []
        for name, body in files.items():
            f = tmp / name
            f.write_text(body)
            paths.append(f)
        real = (cic.wrappers, cic.CLIENTS, dict(cic.BY_OTHER_NAME))
        cic.wrappers = lambda db: (
            {"pay_invoice": {"p_invoice", "p_amount", "p_idempotency_key"}}
            if protected is None else protected)
        cic.CLIENTS = paths
        cic.BY_OTHER_NAME.clear()
        cic.BY_OTHER_NAME.update({} if by_other_name is None else by_other_name)
        out, err = io.StringIO(), io.StringIO()
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = cic.run("db")
        finally:
            cic.wrappers, cic.CLIENTS = real[0], real[1]
            cic.BY_OTHER_NAME.clear()
            cic.BY_OTHER_NAME.update(real[2])
        return code, out.getvalue() + err.getvalue()

    #: A call that names every parameter of the wrapper above.
    GOOD = ("await callRpcOnce('pay_invoice', params: "
            "{'p_invoice': i, 'p_amount': a});")


class TheFourRules(Harness):

    def test_a_correct_call_passes(self):
        code, said = self.gate({"a.dart": self.GOOD})
        self.assertEqual(code, 0, said)

    def test_a_key_sent_to_a_function_with_no_wrapper_fails(self):
        code, said = self.gate(
            {"a.dart": self.GOOD + "\ncallRpcOnce('no_such', params: {});"})
        self.assertEqual(code, 1)
        self.assertIn("no_such", said)
        self.assertIn("no idempotency-key overload", said)

    def test_a_call_omitting_one_parameter_fails(self):
        """The silent one: the wrapper has no defaults, so this resolves to
        the UNPROTECTED original and returns a plausible id."""
        code, said = self.gate(
            {"a.dart": "callRpcOnce('pay_invoice', params: {'p_invoice': i});"})
        self.assertEqual(code, 1)
        self.assertIn("does not name p_amount", said)

    def test_reaching_a_protected_function_both_ways_fails(self):
        code, said = self.gate({"a.dart": self.GOOD,
                                "b.dart": "callRpc('pay_invoice', params: {});"})
        self.assertEqual(code, 1)
        self.assertIn("reached through plain", said)

    def test_a_wrapper_no_caller_uses_fails(self):
        """0307 built the protection; a wrapper nobody calls is protection
        that is not in force."""
        code, said = self.gate({"a.dart": "// nothing calls anything"})
        self.assertEqual(code, 1)
        self.assertIn("no caller uses", said)
        self.assertIn("pay_invoice", said)

    def test_a_key_under_another_name_must_still_be_sent(self):
        code, said = self.gate(
            {"a.dart": self.GOOD + "\ncallRpc('open_pos_sale', params: "
                                   "{'p_org': o});"},
            by_other_name={"open_pos_sale": "p_client_uuid"})
        self.assertEqual(code, 1)
        self.assertIn("p_client_uuid", said)
        self.assertIn("IS this function's idempotency key", said)

    def test_sending_the_other_name_passes(self):
        code, said = self.gate(
            {"a.dart": self.GOOD + "\ncallRpc('open_pos_sale', params: "
                                   "{'p_client_uuid': u});"},
            by_other_name={"open_pos_sale": "p_client_uuid"})
        self.assertEqual(code, 0, said)

    def test_an_entry_for_a_function_nobody_calls_fails(self):
        """An excuse nobody prunes is not evidence, here as elsewhere."""
        code, said = self.gate({"a.dart": self.GOOD},
                               by_other_name={"gone": "p_key"})
        self.assertEqual(code, 1)
        self.assertIn("no client surface calls it", said)


class TheFaultIsReportedAgainstItsOwnFile(Harness):
    """What the hand check proved, kept.

    The gate reported `repository.dart:<line>` for everything while it read
    one file. Sending a reader to the wrong line of the wrong file is
    worse than giving no line at all, and with eleven surfaces it is the
    obvious way for this gate to mislead."""

    def test_the_offending_file_is_named(self):
        code, said = self.gate({
            "repository.dart": self.GOOD,
            "corp_repository.dart": "callRpcOnce('no_such', params: {});"})
        self.assertEqual(code, 1)
        self.assertIn("corp_repository.dart:1:", said)
        # `corp_repository.dart` CONTAINS "repository.dart", so a substring
        # check passes on the right answer and the wrong one alike -- that
        # mistake is why this compares the start of the reported line.
        reported = [ln.strip() for ln in said.splitlines() if ".dart:" in ln]
        self.assertTrue(reported)
        for line in reported:
            self.assertFalse(line.startswith("repository.dart:"), line)

    def test_the_line_is_the_line_within_that_file(self):
        code, said = self.gate({
            "a.dart": self.GOOD,
            "b.dart": "\n\n\ncallRpcOnce('no_such', params: {});"})
        self.assertEqual(code, 1)
        self.assertIn("b.dart:4:", said)

    def test_two_surfaces_are_both_read(self):
        """A gate that stopped after the first file would pass this input."""
        code, said = self.gate({
            "a.dart": self.GOOD,
            "b.dart": "callRpcOnce('also_missing', params: {});"})
        self.assertEqual(code, 1)
        self.assertIn("also_missing", said)


class ReadingACallSite(unittest.TestCase):

    def test_nested_structures_do_not_truncate_the_keys(self):
        """`p_lines` is a list of maps. A lazy match to the first `}` would
        stop inside it and report keys that are not there."""
        fn, keys, line = cic.call_sites(
            "callRpcOnce('f', params: {'p_lines': [{'a': 1}], 'p_x': 2});",
            "callRpcOnce")[0]
        self.assertEqual(fn, "f")
        self.assertEqual(keys, {"p_lines", "p_x"})

    def test_only_p_prefixed_keys_count(self):
        _, keys, _ = cic.call_sites(
            "callRpcOnce('f', params: {'p_a': 1, 'notaparam': 2});",
            "callRpcOnce")[0]
        self.assertEqual(keys, {"p_a"})

    def test_the_line_number_is_one_based(self):
        sites = cic.call_sites("\ncallRpcOnce('f', params: {});", "callRpcOnce")
        self.assertEqual(sites[0][2], 2)

    def test_callrpconce_is_not_matched_by_the_plain_opener(self):
        """`callRpc` is a prefix of `callRpcOnce`, so the plain scan must
        not count the keyed calls as unprotected ones."""
        self.assertEqual(
            cic.call_sites("callRpcOnce('f', params: {});", "callRpc"), [])

    def test_a_call_with_no_params_map_is_not_a_site(self):
        self.assertEqual(cic.call_sites("callRpcOnce('f');", "callRpcOnce"), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
