#!/usr/bin/env python3
"""A test that catches `when others` and asserts nothing has not tested
anything.

A sweep of `create_withholding` found this doing real damage. The file
proved an unposted bill was refused by calling the function and catching
`22023` — and the assertion passed with the guard DELETED, because the
next guard along raises the same code for a different reason. `when
others` is worse again: it catches a typo in the statement under test
and reports it as a pass.

There are a hundred of these in the suite and they are not all wrong;
where only one thing can possibly raise, catching broadly is harmless.
But every one of them is a place where a future edit can break the
thing under test and nothing will say so, and the number should go DOWN
rather than up. So this is a ratchet, not a rule: it fails a build that
adds one.

`pg_temp.check_refused(label, statement, message_like)` in
`_helpers.sql` is what to write instead.
"""
import re
import sys
from collections import Counter
from pathlib import Path

# Lower this when you fix some. Never raise it.
#
# 97 for a long while. `invitations.sql` and `sst_registration.sql` gave
# up fifteen between them, and the conversion is mechanical once the
# refusal's own words are known: run the statement, read the message,
# assert on it.
#
# 82 to 69: `ledger_append_only.sql` and `name_purposes.sql`. The two
# files are the two shapes this budget contains, and they are not
# equally bad.
#
# `ledger_append_only.sql` was the shape in the docstring above --
# `exception when others then v_failed := true` and then
# `check_true('a posted journal cannot be edited', v_failed)`. That
# passes whatever went wrong. Renaming a column out from under the
# statement raises 42703 and reads as the ledger defending itself; so
# does a typo. All six are `42501 permission denied for table ...` and
# now say so, message and sqlstate. Checked by misspelling
# `total_debit`: it used to pass, and now fails naming the column.
#
# `name_purposes.sql` looked better and was the more interesting one.
# It captured `v_state := sqlstate` and asserted `= '22023'`, which is
# not nothing -- but SEVEN refusals in that file raise 22023 between
# FOUR different messages, so the assertion passes when the wrong guard
# fires, and passes with the guard under test deleted. Exactly what
# `create_withholding` did. They assert on the words now.
#
# 69 to 53: `module_surface.sql`, `branches_and_groups.sql`,
# `group_reporting.sql` and three of `chat.sql`'s five. One pattern
# runs through all of them -- a file raises 42501 for three or four
# DIFFERENT rules, so "it was refused" is not the claim any of those
# tests meant to make. `module_surface.sql` refuses an outsider as
# not-a-member for the read and as not-an-administrator for the write,
# one line apart.
#
# Two of them were not refusals at all. `branches_and_groups.sql`
# wrapped two INSERTS THAT ARE MEANT TO SUCCEED in
# `exception when others then v_ok := false`, and then asserted
# `v_ok` -- so a column renamed out from under either one reported the
# branch rule working. Both run unhandled now: if they raise, the real
# error stops the file and names itself.
#
# ---------------------------------------------------------------------
# What is deliberately still here
#
# 53 to 41: `org_login_page.sql`, `security_audit.sql`,
# `manufacturing.sql` and `invitations.sql`. Same story again --
# `security_audit.sql`'s three 42501s are two different rules, and
# `org_login_page.sql`'s three are two.
#
# `invitations.sql` was the one worth reading carefully, because its
# three were not the same thing as each other. Under row level
# security the `using` clause takes the owner's row out of reach, so
# demoting the owner and deleting them MATCH NOTHING and `found` is
# false -- no exception at all. Promoting yourself touches your OWN
# row, which `using` lets through, and it is the `with check` that
# stops it, so that one really does raise. Two filtered, one refused,
# all three behind the same `exception when others then v_x := false`.
# The two that cannot raise run bare now and the one that does asserts
# on what it said.
#
# ---------------------------------------------------------------------
# What is deliberately still here
#
# The docstring says these are not all wrong, and `chat.sql` has the
# clearest example of a right one. Two of its five are
# `exception when others then null` around a statement run under row
# level security, with the real assertion on the STATUS afterwards --
# because an UPDATE a policy filters out does not raise at all, it
# updates nothing. Its own comment says so, and says the first draft
# asserted "the statement was refused" and failed. Converting those
# would be worse tests for a smaller number.
BUDGET = 41

TESTS = Path(__file__).resolve().parent.parent / 'supabase' / 'tests'

# A handler that mentions any of these is looking at the error rather
# than assuming it.
INSPECTS = ('get stacked diagnostics', 'sqlerrm', 'check_')


def blind_sites():
    out = []
    for path in sorted(TESTS.glob('*.sql')):
        src = path.read_text()
        # Each `when others then ... end;` handler, with the line it is on.
        for m in re.finditer(r'exception\s+when\s+others\s+then(.*?)\n\s*end;',
                             src, re.S):
            body = m.group(1).lower()
            if any(k in body for k in INSPECTS):
                continue
            line = src.count('\n', 0, m.start()) + 1
            out.append((path.name, line))
    return out


def main():
    sites = blind_sites()
    n = len(sites)
    if n > BUDGET:
        print(f'FAIL: {n} blind `when others` handlers, budget is {BUDGET}.')
        print('A handler that asserts nothing about the error passes when the')
        print('guard it is testing is deleted, and when the statement under')
        print('test has a typo in it. Use pg_temp.check_refused instead.')
        print()
        for name, count in Counter(f for f, _ in sites).most_common():
            print(f'  {count:3}  {name}')
        return 1
    if n < BUDGET:
        print(f'{n} blind `when others` handlers, budget is {BUDGET}.')
        print(f'Lower BUDGET in {Path(__file__).name} to {n} to hold the ground.')
        return 1
    print(f'{n} blind `when others` handlers, at the budget.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
