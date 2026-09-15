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
# `0572` the twenty-one that undo something, `0573` the whole `set_*`
# family, `0574` the whole `upsert_*` family, `0575` the whole
# `platform_*` family and `0576` the whole `chat_*` family. With the
# named families closed, `0577` took the first slice chosen by what the
# functions do rather than what they are called: the seventeen acts a
# regulator reads. `0580` took the second such slice, the twenty-eight
# the restaurant runs on -- where the interesting thing written down is
# not the arithmetic but WHICH REFUSALS ARE HARD, because a refusal a
# cashier cannot act on instantly is a queue. `0581` took the thirteen
# approval gates, where the only question worth publishing is who may
# say yes -- and three of them refuse self-approval while two
# deliberately do not. `0582` took the eleven that do a lot at once,
# where the only question is what happens if you run it twice -- and
# `run_depreciation` charges nothing the second time while
# `raise_rent_invoices` bills every tenant again. `0583` took the ten by
# which data reaches somebody outside the company -- where the surprise
# is that `audit_trail` and `security_log` are reads that WRITE, because
# a log that does not record who read it is the one record an insider
# has no reason to avoid. `0587` took the nine that write into a
# person's employment record, where almost every refusal exists to stop
# a record meaning something it should not -- and `clock_in` upserts
# the wrong way round on purpose, keeping the EARLIEST punch. `0588`
# took the eight that carry work from a name somebody wrote down to an
# invoice, where `close_project` turns out to be a refusal with money
# in it rather than the tidy-up its name suggests. `0592` took the
# seven about something that has left one place and not arrived at the
# other -- a post-dated cheque, an unmatched statement line, a van of
# stock -- where the question a caller cannot answer from the signature
# is WHEN this moves the money and when it only moves the record of it.
# Two of the seven deliberately post nothing, and `deposit_pdc` is the
# whole argument in one function: an entry on the day a cheque is paid
# in would put the money in the bank three days early.
#
# It also turned up the failure mode this check cannot see. `record_pdc`
# has two overloads; the unprotected one carried the only description
# and the idempotent one, which is the one a client should call, had
# none. The query below counts functions, so a documented sibling does
# nothing for the signature beside it.
#
# `0593` took the four whose names promise a tidy-up. Three really
# delete, and each takes something unmentioned with it: a conversion's
# outputs by cascade, a barcode format a label already on a package
# still needs, and the pack size that is the only thing turning "3 CT"
# on an old invoice into a quantity. The fourth,
# `retire_cash_forecast_item`, is a soft delete wearing an honest name.
#
# Writing the test for that slice found the worse half of the pack
# case, which reading the function had not: where the unit HAS a
# standard factor, deleting the pack does not raise at all. The line
# re-derives against the standard dozen, thirty becomes thirty-six, and
# nothing says a word.
BUDGET = 27

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
