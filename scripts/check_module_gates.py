#!/usr/bin/env python3
"""A function that checks two modules must say so in its description.

    python3 scripts/check_module_gates.py "$DATABASE_URL"

`docs/api/` files every function under one module, taken from the first
`can_read_module` or `can_write_module` in its body. For most of them
that is the whole truth. For thirteen it is at best half, and the half
that is missing is the half a caller acts on:

  * `create_contra` requires `sales` AND `purchases`. Somebody who
    reads "sales", switches Sales on and retries still gets 42501, with
    nothing in the published description to tell them why.

  * `pdc_list` requires EITHER, and then filters the rows by which one
    you have. Somebody with only Purchases reads "sales" and concludes
    the function is shut to them, when it would have returned their
    outgoing cheques.

  * `module_dashboard` names seven, requires none of them, and shows
    the section for each module the company has.

Those are three different relationships and a list of names cannot
tell them apart. The description can, so this insists on one: a
function whose body checks more than one module must carry a
`comment on function` that NAMES EVERY ONE of them.

It does not try to work out the relationship itself. `not A or not B`
and `not A and not B` are one character apart and mean opposite things,
and a check that guessed would be wrong silently -- which is how
`0601`'s hole survived: `deposit_history`'s guard could never fire,
because `sales` is a core module, and nothing was reading the body
closely enough to notice.

Naming them is the floor, not the ceiling. Say which are required.
"""
import re
import sys
import json
import subprocess

QUERY = r"""
select coalesce(json_agg(row_to_json(t)), '[]'::json) from (
  select p.proname as name,
         pg_get_function_identity_arguments(p.oid) as args,
         coalesce(d.description, '') as description,
         (select coalesce(array_agg(distinct m[1]), '{}')
            from regexp_matches(
                   p.prosrc,
                   'can_(?:read|write)_module\([^,]+,\s*''([a-z_]+)''',
                   'g') as m) as modules
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    left join pg_description d on d.objoid = p.oid and d.objsubid = 0
   where n.nspname = 'public'
     and p.prokind = 'f'
     and has_function_privilege('authenticated', p.oid, 'execute')
     and not exists (select 1 from pg_depend dp
                      where dp.objid = p.oid and dp.deptype = 'e')
) t;
"""


def main() -> int:
    if len(sys.argv) < 2:
        print('usage: check_module_gates.py <database-url>', file=sys.stderr)
        return 2

    out = subprocess.run(['psql', sys.argv[1], '-tAc', QUERY],
                         capture_output=True, text=True)
    if out.returncode != 0:
        print(out.stderr.strip(), file=sys.stderr)
        return 2

    offenders = []
    for row in json.loads(out.stdout):
        mods = sorted(set(row['modules'] or []))
        if len(mods) < 2:
            continue
        text = row['description']
        # Word boundaries, so `sales` is not found inside `wholesales`
        # and `pos` is not found inside `position`.
        missing = [m for m in mods
                   if not re.search(rf'\b{re.escape(m)}\b', text)]
        if missing:
            offenders.append((f"{row['name']}({row['args']})", mods, missing,
                              bool(text.strip())))

    if not offenders:
        print('ok   every function checking two modules names them both')
        return 0

    print('A function that checks more than one module must name every')
    print('one of them in its `comment on function`, and say whether all')
    print('are needed or any one will do. `docs/api/` files it under the')
    print('first, and the first is not the answer:')
    print()
    for sig, mods, missing, described in offenders:
        print(f'    {sig}')
        print(f'        checks:  {", ".join(mods)}')
        print(f'        missing: {", ".join(missing)}'
              + ('' if described else '   (no description at all)'))
    print()
    print('Write it in the migration, beside the guard. See 0602.')
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
