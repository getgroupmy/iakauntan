#!/usr/bin/env python3
"""Refuse an edge function that calls an RPC its client cannot execute.

    python3 scripts/check_edge_rpc_grants.py <database-url>

A new function in `public` is executable by **postgres and nobody
else**. PostgreSQL grants EXECUTE to PUBLIC on creation and `0165`'s
event trigger revokes it, so every caller needs an explicit grant
written in the migration.

Forgetting that grant is invisible everywhere else in this repository.
The migration applies. `deno check` type-checks the call. The SQL
assertions never reach the edge function, and the Deno tests exercise
the pure helpers rather than the handler. At run time PostgREST answers
42501, the edge function catches it with everything else, and the
feature simply never happens -- no error anybody reads, no row anybody
misses.

It has already cost months. `0618` found ten functions whose callers
could not reach them, including both RPCs `send-push` needs to read its
recipients and retire dead tokens, which means no push notification had
ever been delivered; and both halves of a customer paying an invoice
they were sent. The pattern then spread by being copied: `0612` and
`0616` repeated it in migrations written two days and one day before
0618.

`function_grants.sql` asserts the other direction -- that nothing in
`public` is callable by nobody. That catches a function with no grant at
all and cannot catch the more specific fault: a function granted to
`authenticated` and called by the service role, or the reverse. This
does, because it reads the CALL rather than the catalog alone.

## What is checked

Every `<client>.rpc("<name>")` in every edge function. The client's
identifier says which role the call arrives as, and the function must be
executable by that role.

## Unknown client names fail rather than being guessed at

The mapping below is by identifier, which is a convention rather than a
fact about the code. So a name that is not in it is an ERROR and not a
skip: the author is asked to say which role the client carries, which is
one line here, rather than having the check quietly stop covering their
function. A guess in the other direction would report a false failure
on somebody else's correct code, and a guess in this one would go quiet
exactly where a new pattern is being introduced.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FUNCTIONS = ROOT / 'supabase' / 'functions'

# Which role a client identifier carries. `_shared/context.ts` builds
# `admin` from the service role key and `userClient` from the anon key
# plus the caller's Authorization header; the standalone functions use
# `db` for the first and `caller` for the second.
CLIENTS = {
    'admin': 'service_role',
    'db': 'service_role',
    'service': 'service_role',
    'userClient': 'authenticated',
    'caller': 'authenticated',
}

CALL = re.compile(r'\b(\w+)\.rpc\(\s*["\']([a-z_][a-z0-9_]*)["\']')


def sources():
    for path in sorted(FUNCTIONS.rglob('*.ts')):
        rel = path.relative_to(ROOT).as_posix()
        if '_test' in path.name or '_local_check' in rel:
            continue
        yield rel, path.read_text()


def grants(url, names):
    """Which of anon/authenticated/service_role may execute each name."""
    if not names:
        return {}
    values = ','.join(f"('{n}')" for n in sorted(names))
    query = f"""
    with called(name) as (values {values})
    select c.name, coalesce(nullif(concat_ws(',',
             case when bool_or(has_function_privilege('anon', p.oid, 'execute'))
                  then 'anon' end,
             case when bool_or(has_function_privilege('authenticated', p.oid, 'execute'))
                  then 'authenticated' end,
             case when bool_or(has_function_privilege('service_role', p.oid, 'execute'))
                  then 'service_role' end), ''), '')
      from called c
      left join pg_proc p on p.proname = c.name
           and p.pronamespace = 'public'::regnamespace
     group by c.name
    """
    out = subprocess.run(['psql', url, '-tAF', '|', '-c', query],
                         capture_output=True, text=True)
    if out.returncode != 0:
        print(out.stderr.strip(), file=sys.stderr)
        sys.exit(2)

    found = {}
    for line in out.stdout.splitlines():
        if not line.strip():
            continue
        name, _, roles = line.partition('|')
        found[name] = set(r for r in roles.split(',') if r)
    return found


def main() -> int:
    if len(sys.argv) < 2:
        print('usage: check_edge_rpc_grants.py <database-url>',
              file=sys.stderr)
        return 2
    url = sys.argv[1]

    calls = []       # (name, role, where)
    unknown = []     # (client, name, where)
    for rel, text in sources():
        for m in CALL.finditer(text):
            client, name = m.group(1), m.group(2)
            line = text[:m.start()].count('\n') + 1
            where = f'{rel}:{line}'
            role = CLIENTS.get(client)
            if role is None:
                unknown.append((client, name, where))
            else:
                calls.append((name, role, where))

    if unknown:
        print(f'FAIL: {len(unknown)} RPC call(s) go through a client this '
              f'check does not know the role of.')
        print()
        print('Add the identifier to CLIENTS in '
              f'{Path(__file__).name}, saying which role it carries.')
        print('Guessing would either report a false failure or go quiet')
        print('exactly where a new pattern is being introduced.')
        print()
        for client, name, where in unknown:
            print(f'  {where}: {client}.rpc("{name}")')
        return 1

    held = grants(url, {name for name, _, _ in calls})

    missing = []
    for name, role, where in sorted(set(calls)):
        roles = held.get(name)
        if roles is None or not roles:
            # Either the function does not exist under that name, or it
            # is granted to nobody. Both are the same failure to a
            # caller and the message says which.
            missing.append((name, role, where, 'is granted to nobody'
                            if name in held else 'does not exist in public'))
        elif role not in roles:
            missing.append((name, role, where,
                            'is granted to ' + ', '.join(sorted(roles))))

    if missing:
        print(f'FAIL: {len(missing)} RPC call(s) cannot execute as the role '
              f'they arrive as.')
        print()
        print('PostgREST answers 42501, the edge function catches it with')
        print('everything else, and the feature never happens. Write the')
        print('grant in a migration:')
        print()
        print('  grant execute on function public.<name>(<args>) to <role>;')
        print()
        for name, role, where, why in missing:
            print(f'  {where}: {name} called as {role}, but it {why}')
        return 1

    print(f'All {len(set((n, r) for n, r, _ in calls))} RPC calls from the '
          f'edge functions can execute as the role they arrive as.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
