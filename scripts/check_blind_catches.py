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
BUDGET = 82

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
