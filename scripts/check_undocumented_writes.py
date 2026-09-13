#!/usr/bin/env python3
"""A write nobody wrote down, in an API that is now published.

`docs/api/` describes every function a tenant's token can reach, and
generating it made this database's silence countable: of the functions
in that surface, most carry no `comment on function`, so the published
description prints a name and an argument list and nothing else.

That is worst for the writes. A read somebody misunderstands returns
the wrong rows; a write somebody misunderstands moves money, and
`0570` is a list of thirteen where the refusals ARE the accounting --
`void_sales_document` will not void an invoice with a payment against
it, `apply_deposit` will not settle across currencies, `create_deposit`
has an unprotected overload that takes the money twice on a retry.
None of that was written anywhere a caller would look.

    python3 scripts/check_undocumented_writes.py "$DATABASE_URL"

## A ratchet, not a rule

`check_blind_catches.py` carries a budget for the same reason and says
it plainly: "the number should go DOWN rather than up". Two hundred
odd comments is a body of work, not a commit, and a gate that failed
until all of them were written would be turned off within the week.

So this fails a build that ADDS one, and fails a build that removes
some without lowering the budget -- which is what keeps the number
honest. `0569`, `0570` and `0571` took it from 278.

## Why the comment and not a document

`comment on function` lives in the catalog beside the rule and travels
with it; `scripts/generate_api_description.py` reads it and publishes
it on the next run. A paragraph in a markdown file does neither, and
`docs/gaps-against-akaunting.md` spent months claiming three built
features were missing.

## Two things deliberately outside this

Functions granted only to `service_role`, which are reachable solely by
the secret key and are not part of the described surface. And the
`anon`-reachable ones, which are not a budget at all: `statutory.sql`
requires a comment on every one of those, and there is no allowance.
"""
import signal
import subprocess
import sys
from pathlib import Path

# A reader that stops early -- `| head`, a CI log tail -- closes the
# pipe, and Python's default is to turn that into a BrokenPipeError
# traceback after the output the reader asked for. The traceback then
# reads as the check having crashed. Restoring the default disposition
# makes an early close what it is: nothing.
if hasattr(signal, 'SIGPIPE'):
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)

# Lower this when you write some. Never raise it.
#
# 278 when this was written. `0569` took the open doors, `0570` the
# thirteen that move money, `0571` the posting and creating verbs,
# `0572` the twenty-one that undo something, and `0573` the whole
# `set_*` family.
BUDGET = 199

QUERY = r"""
select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  left join pg_description d on d.objoid = p.oid and d.objsubid = 0
 where n.nspname = 'public'
   and p.prokind = 'f'
   -- VOLATILE. A function that only reads cannot be the expensive kind
   -- of misunderstanding, and the reads are their own slice.
   and p.provolatile = 'v'
   and coalesce(btrim(d.description), '') = ''
   and has_function_privilege('authenticated', p.oid, 'execute')
   -- `citext`, `btree_gist` and `pg_trgm` install into `public` and
   -- carry EXECUTE to PUBLIC. They are reachable and they are not ours
   -- to document.
   and not exists (select 1 from pg_depend dp
                    where dp.objid = p.oid and dp.deptype = 'e')
 order by p.proname;
"""


def main() -> int:
    if len(sys.argv) < 2:
        print('usage: check_undocumented_writes.py <database-url>',
              file=sys.stderr)
        return 2

    out = subprocess.run(['psql', sys.argv[1], '-tAc', QUERY],
                         capture_output=True, text=True)
    if out.returncode != 0:
        print(out.stderr.strip(), file=sys.stderr)
        return 2

    names = [ln for ln in out.stdout.splitlines() if ln.strip()]
    n = len(names)

    if n > BUDGET:
        print(f'FAIL: {n} writes a signed-in user can reach carry no '
              f'`comment on function`, budget is {BUDGET}.')
        print()
        print('A published description that prints a name and an argument')
        print('list has told a caller nothing about what the function')
        print('refuses -- and for a write, the refusals are the rule.')
        print()
        print('Write it as `comment on function` in the migration, not in a')
        print('document: the generator reads the catalog, so it reaches')
        print('docs/api/ on the next run.')
        print()
        for name in names[:20]:
            print(f'  {name}')
        if n > 20:
            print(f'  … and {n - 20} more')
        return 1

    if n < BUDGET:
        print(f'{n} undocumented writes, budget is {BUDGET}.')
        print(f'Lower BUDGET in {Path(__file__).name} to {n} to hold the '
              f'ground.')
        return 1

    print(f'{n} undocumented writes, at the budget.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
