#!/usr/bin/env python3
"""Self-test for check_write_doors.py.

The gate reads a live database, so these assertions feed it the two
`psql` answers instead of a cluster. That is the only thing stubbed: the
regexes, the ladder, the comparison and the ratchet are the real ones.

What is being proved is that the gate BITES. A gate over a reviewed list
has two ways to be useless — passing a table it should report, and
holding an excuse for a gap that has since been closed — and both of
them look exactly like success from the outside.
"""

from __future__ import annotations

import importlib.util
import io
import pathlib
import unittest
from contextlib import redirect_stderr, redirect_stdout

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "cwd", HERE / "check_write_doors.py")
cwd = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(cwd)


def fake_psql(functions: list[tuple[str, str]],
              policies: list[tuple[str, str]]):
    """Stand in for `psql`, answering by which query it was handed.

    The real function returns tab-separated rows, so these do too —
    including the detail that a body with no guard at all is still a row
    with an empty second field.
    """
    def answer(db: str, sql: str) -> str:
        rows = policies if "pg_policy" in sql else functions
        return "".join("%s\t%s\n" % row for row in rows)
    return answer


#: The shape 0740 was written for, as it stood before 0740: the ledger's
#: insert policy asks for `can_write`, both writers demand `can_post`.
CLIENT_MONEY_FUNCTIONS = [
    ("public.receive_client_money",
     "begin if not app.can_post(v_org) then raise exception 'Insufficient "
     "privileges to move client money'; end if; insert into "
     "client_account_transactions (org_id) values (v_org); end"),
    ("public.pay_from_client_account",
     "begin if not app.can_post(v_org) then raise exception 'x'; end if; "
     "insert into public.client_account_transactions (org_id) values (v_org); "
     "end"),
]
CLIENT_MONEY_POLICIES = [
    ("client_account_transactions", "app.can_write(org_id)"),
]
CLIENT_MONEY_DART = (
    "await client.from('client_account_transactions').insert({'org_id': o});")


class _Stubbed(unittest.TestCase):

    def setUp(self):
        self._real = cwd.psql
        self.addCleanup(lambda: setattr(cwd, "psql", self._real))

    def stub(self, functions, policies):
        cwd.psql = fake_psql(functions, policies)

    def run_gate(self, dart, reviewed, functions=None, policies=None):
        self.stub(CLIENT_MONEY_FUNCTIONS if functions is None else functions,
                  CLIENT_MONEY_POLICIES if policies is None else policies)
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = cwd.run("ignored", text=dart, reviewed=reviewed)
        return code, out.getvalue() + err.getvalue()


class TheHarnessIsWired(_Stubbed):
    """A stub that answered nothing would make every other test here
    pass, so one test asserts the stub reaches the comparison at all."""

    def test_the_client_money_shape_is_found(self):
        self.stub(CLIENT_MONEY_FUNCTIONS, CLIENT_MONEY_POLICIES)
        found = cwd.gaps("ignored", CLIENT_MONEY_DART)
        self.assertEqual(found, {"client_account_transactions":
                                 ({"can_write"}, {"can_post"})})


class TheGateBites(_Stubbed):

    def test_a_weaker_second_door_fails(self):
        code, said = self.run_gate(CLIENT_MONEY_DART, {})
        self.assertEqual(code, 1)
        self.assertIn("client_account_transactions", said)
        self.assertIn("can_post", said)

    def test_the_same_door_with_a_reason_passes(self):
        code, said = self.run_gate(
            CLIENT_MONEY_DART,
            {"client_account_transactions": "reviewed: it is a draft"})
        self.assertEqual(code, 0, said)

    def test_an_excuse_for_a_closed_gap_fails(self):
        """0740's own fix must make its REVIEWED entry illegal."""
        code, said = self.run_gate(
            CLIENT_MONEY_DART,
            {"client_account_transactions": "reviewed", "gone": "stale"})
        self.assertEqual(code, 1)
        self.assertIn("gone is in REVIEWED but no longer has the gap", said)

    def test_the_fix_0740_actually_made_closes_the_finding(self):
        """0740 dropped the write policies rather than tightening them.
        With no write policy the direct door is shut, so there is no
        weaker door to find and no entry to carry."""
        code, said = self.run_gate(
            CLIENT_MONEY_DART, {},
            policies=[("client_account_transactions", "app.can_read(org_id)")])
        self.assertEqual(code, 0, said)
        self.assertIn("0 table(s)", said)


class WhatIsNotAGap(_Stubbed):

    def test_a_policy_as_strong_as_the_function_is_not_reported(self):
        self.stub(CLIENT_MONEY_FUNCTIONS,
                  [("client_account_transactions", "app.can_post(org_id)")])
        self.assertEqual(cwd.gaps("ignored", CLIENT_MONEY_DART), {})

    def test_a_policy_stronger_than_the_function_is_not_reported(self):
        self.stub(CLIENT_MONEY_FUNCTIONS,
                  [("client_account_transactions", "app.can_admin(org_id)")])
        self.assertEqual(cwd.gaps("ignored", CLIENT_MONEY_DART), {})

    def test_a_table_the_client_never_writes_directly_is_not_reported(self):
        """The gap only matters because a second door exists."""
        self.stub(CLIENT_MONEY_FUNCTIONS, CLIENT_MONEY_POLICIES)
        self.assertEqual(
            cwd.gaps("ignored", "client.from('client_account_transactions')"
                                ".select('*')"), {})

    def test_a_demo_seeder_does_not_count_as_a_writer(self):
        self.stub([("app.demo_client_money",
                    "begin if not app.can_admin(v) then raise; end if; "
                    "insert into client_account_transactions values (1); end")],
                  CLIENT_MONEY_POLICIES)
        self.assertEqual(cwd.gaps("ignored", CLIENT_MONEY_DART), {})

    def test_a_function_with_no_guard_at_all_is_not_a_gap(self):
        self.stub([("public.receive_client_money",
                    "begin insert into client_account_transactions "
                    "values (1); end")],
                  CLIENT_MONEY_POLICIES)
        self.assertEqual(cwd.gaps("ignored", CLIENT_MONEY_DART), {})


class ReadingTheClient(unittest.TestCase):

    def test_the_four_verbs_are_found(self):
        self.assertEqual(
            cwd.direct_writes(
                "client.from('a').insert({}); client.from('b').update({}); "
                "client.from('c').delete(); client.from('d').upsert({});"),
            {"a": {"insert"}, "b": {"update"}, "c": {"delete"},
             "d": {"insert"}})

    def test_an_upsert_counts_as_an_insert(self):
        """Because it can create the row, which is what the policy on
        INSERT is there to decide."""
        self.assertEqual(cwd.direct_writes("client.from('a').upsert({})"),
                         {"a": {"insert"}})

    def test_filters_between_the_table_and_the_verb_do_not_hide_it(self):
        self.assertEqual(
            cwd.direct_writes(
                "client.from('a').update({'x': 1}).eq('id', i).eq('org', o)"),
            {"a": {"update"}})

    def test_a_chain_broken_across_lines_is_still_found(self):
        """75 of the 171 direct writes in `repository.dart` put the verb
        on its own line. A pattern that only matched `.from('t').insert`
        adjacently would miss 44% of them and report a shorter list as a
        cleaner one."""
        self.assertEqual(
            cwd.direct_writes("await client\n"
                              "    .from('client_account_transactions')\n"
                              "    .insert({'org_id': o});"),
            {"client_account_transactions": {"insert"}})

    def test_a_call_between_the_table_and_the_verb_does_not_hide_it(self):
        self.assertEqual(
            cwd.direct_writes("client.from('a').limit(1).delete()"),
            {"a": {"delete"}})

    def test_a_read_is_not_a_write(self):
        self.assertEqual(
            cwd.direct_writes("client.from('a').select('*').eq('id', i)"), {})

    def test_an_rpc_is_not_a_direct_write(self):
        self.assertEqual(cwd.direct_writes("callRpc('receive_client_money')"),
                         {})


class TheLadder(unittest.TestCase):

    def test_guards_reads_only_the_names_on_the_ladder(self):
        self.assertEqual(
            cwd.guards("app.can_post(o) and app.can_read(o) "
                       "and app.can_write(o)"),
            {"can_post", "can_write"})

    def test_a_guard_named_without_a_call_is_not_a_guard(self):
        self.assertEqual(cwd.guards("-- can_post is checked by the caller"),
                         set())

    def test_rank_takes_the_strongest(self):
        self.assertLess(cwd.rank({"can_write", "can_post"}),
                        cwd.rank({"can_write"}))

    def test_nothing_ranks_weaker_than_anything(self):
        self.assertGreater(cwd.rank(set()), cwd.rank({"can_write"}))


class TheRealListIsHonest(unittest.TestCase):
    """REVIEWED carries a reason per entry, not a bare name, because the
    whole point is that a hit has to be read rather than counted."""

    def test_every_entry_has_a_reason(self):
        for table, reason in cwd.REVIEWED.items():
            self.assertGreater(len(reason), 40, table)


if __name__ == "__main__":
    unittest.main(verbosity=2)
