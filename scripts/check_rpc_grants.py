#!/usr/bin/env python3
"""Refuse a caller that names an RPC it cannot execute.

    python3 scripts/check_rpc_grants.py <database-url>

Two surfaces, one rule. The edge functions call RPCs as the service role
or as the signed-in caller depending on which client they build; the
Flutter app calls them as whoever is using it.

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
recipients and retire dead tokens, and both halves of a customer paying
an invoice they were sent. The pattern then spread by being copied:
`0612` and `0616` repeated it in migrations written two days and one
day before 0618.

0618 said of those ten that no push notification had ever been
delivered. That went further than its evidence: it measured `supabase
start`, and the functions run in the linked hosted project, which
carries a default privilege granting `service_role` EXECUTE on
everything created in `public`. Whether the outage happened is not
settled here and does not need to be -- a feature that works only
because of a default nobody in this repository wrote down is a feature
waiting to stop. The explicit grants are the fix either way.
`supabase/tests/_local_stack.sql` carries the argument and the three
hosted observations behind it.

`function_grants.sql` asserts the other direction -- that nothing in
`public` is callable by nobody, and that nothing is reachable by a
stranger unless it is on a named list. That catches a function with no
grant at all and cannot catch the more specific fault: a function
granted to `authenticated` and called by the service role, or the
reverse. This does, because it reads the CALL rather than the catalog
alone.

## What is checked

**The edge functions.** Every `<client>.rpc("<name>")` under
`supabase/functions`. The client's identifier says which role the call
arrives as, and the function must be executable by that role.

**The app.** Every call under `app/lib` whose name ends in `rpc` or
`Rpc` -- `.rpc('x')`, `callRpc('x')`, `LandingAdmin._rpc('x')` -- which
is the bigger surface by far: 667 distinct names against 26.

It was `callRpc` and `.rpc` alone until the landing console was read
properly, and that pattern missed three kinds of call at once: a
wrapper of its own (`_rpc`), a name chosen by a ternary
(`receivable ? 'report_ar_ageing' : 'report_ap_ageing'`), and a name
declared elsewhere (`kind.postRpc`). Twenty-eight names in total, none
of them ungranted -- luck rather than coverage, and the same shape of
hole `check_embeds.py` had: a scanner that reads one form of a thing
and reports the app clean about the rest. The rule there is looser and deliberately so: the call must
be executable by `authenticated` OR by `anon`, because the app makes
some of these before anybody has signed in (the landing page, the
sign-in screen, a shared payment link). Requiring `authenticated` alone
would fail a legitimately anonymous RPC; requiring only "somebody" would
pass a service-role-only function the app should never be naming.

That looser rule is why the app half cannot replace
`function_grants.sql`, which asserts the role exactly for the entry
points where exactness matters.

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


APP = ROOT / 'app' / 'lib'

# Any call whose name ends in `rpc` or `Rpc`, with a literal first
# argument: `.rpc('x')` is the raw client, `callRpc('x')` the
# repository's wrapper, `_rpc('x')` the landing console's own. All
# arrive as whoever is signed in, or as `anon` if nobody is.
#
# It was `(?:callRpc|\.rpc)\(` until the landing console was read
# properly. `LandingAdmin._rpc` is a one-line wrapper over `client.rpc`
# and it matched neither alternative, so twelve platform RPCs -- every
# write the landing page editor makes -- were outside this gate
# entirely. None of them turned out to be ungranted, which is luck
# rather than coverage.
APP_CALL = re.compile(r"""\b\w*[Rr]pc\(\s*'([a-z_][a-z0-9_]*)'""")

# The same call with a first argument that is NOT a literal, and the
# name expression that follows it.
#
# Three shapes turn up in this app and only one of them is a hole:
#
#   callRpc(receivable ? 'report_ar_ageing' : 'report_ap_ageing', ...)
#       -- a ternary between two literals. Both are RPC names, both are
#       checked, and neither was visible to this gate before: the old
#       pattern required a quote immediately after the bracket.
#
#   callRpc(rpc ?? kind.postRpc, ...)
#       -- no literal here at all. The name is declared elsewhere, and
#       the convention that makes it findable is `check_embeds.py`'s:
#       an expression named for what it holds. `LITERAL_RPC_NAME` picks
#       up `String get postRpc => ... 'post_sales_document' ...` and
#       `postRpc: 'post_goods_received'` wherever they are written.
#
#   client.rpc(fn, params: params)
#       -- a wrapper passing its own parameter through. Its callers are
#       what get checked, and the body carries no name to check. Named
#       below, because three of them is a list and not a pattern: a rule
#       of the shape "a bare identifier is fine" would excuse the next
#       real hole as well.
DYNAMIC_APP_CALL = re.compile(r"""\b\w*[Rr]pc\(\s*(?!\s)""")

# A name ending in `Rpc` BOUND to something -- `=>`, `=` or `:` -- which
# is how a dynamic call site's name is declared when it is not written
# inline:
#
#     String get postRpc =>
#         isSales ? 'post_sales_document' : 'post_purchase_document';
#     postRpc: 'post_goods_received',
#
# The binding operator is load-bearing. Without it this matched the CALL
# site as well -- `rpc(` followed by any literal within a couple of
# lines -- so `client.rpc(kind == 'subdomain' ? ...)` reported
# `subdomain` as a function granted to nobody. A gate that fails on
# something that was never a call is worse than one that stays quiet.
RPC_BINDING = re.compile(r"""\w*[Rr]pc\b\s*(?:=>|=|:)""")

# The one-line wrappers over `client.rpc`. Each takes the name as a
# parameter and every one of its callers is read by `APP_CALL`, so the
# body itself carries no name to check. Written out rather than matched
# by shape: three is a list, and a shape would excuse the next real
# hole as well.
# Keyed by file, and the value is the PARAMETER the wrapper passes
# through -- `client.rpc(fn, ...)` inside `Repo.callRpc(String fn, ...)`
# and inside `LandingAdmin._rpc(String fn, ...)`.
WRAPPERS = {
    'app/lib/src/data/repository.dart': ('fn',),
    'app/lib/src/data/landing_repository.dart': ('fn',),
}


def name_expression(text: str, at: int) -> str:
    """The first argument of a call whose bracket has just been passed."""
    depth, i, out = 1, at, []
    while i < len(text) and depth > 0:
        ch = text[i]
        if ch == ',' and depth == 1:
            break
        if ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
            if depth == 0:
                break
        out.append(ch)
        i += 1
    return ''.join(out)


def bound_expression(text: str, at: int) -> str:
    """What a binding binds, up to the first `;` or top-level `,`."""
    depth, i, out = 1, at, []
    while i < len(text):
        ch = text[i]
        if ch == ';':
            break
        if ch == ',' and depth == 1:
            break
        if ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
            if depth == 0:
                break
        out.append(ch)
        i += 1
    return ''.join(out)


def is_declaration(expression: str) -> bool:
    """`Future<dynamic> _rpc(String fn, ...)` is not a call site."""
    return re.match(r'^\s*(?:final\s+)?[A-Z]\w*[<>\w,\s?]*\s+\w+\s*$',
                    expression) is not None


def sources():
    for path in sorted(FUNCTIONS.rglob('*.ts')):
        rel = path.relative_to(ROOT).as_posix()
        if '_test' in path.name or '_local_check' in rel:
            continue
        yield rel, path.read_text()


def app_sources():
    for path in sorted(APP.rglob('*.dart')):
        yield path.relative_to(ROOT).as_posix(), path.read_text()


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

    # The app's calls. One per name is enough -- 639 names across
    # hundreds of files, and the first site is as good as the last for
    # saying where to look.
    app_calls = {}
    unreadable = []
    for rel, text in app_sources():
        for m in APP_CALL.finditer(text):
            name = m.group(1)
            if name in app_calls:
                continue
            line = text[:m.start()].count('\n') + 1
            app_calls[name] = f'{rel}:{line}'

        # A name declared for a dynamic call site. `String get postRpc =>
        # isSales ? 'post_sales_document' : ...` is two RPC names and no
        # call site this script can read; they are checked here instead.
        for m in RPC_BINDING.finditer(text):
            line = text[:m.start()].count('\n') + 1
            bound = bound_expression(text, m.end())
            for name in re.findall(r"'([a-z_][a-z0-9_]*)'", bound):
                app_calls.setdefault(name, f'{rel}:{line}')

        # A call whose name is an expression. Every literal inside it
        # is an RPC name and is checked; an expression with no literal
        # at all falls back on the naming convention, and one with
        # neither cannot be checked and is refused.
        for m in DYNAMIC_APP_CALL.finditer(text):
            expression = name_expression(text, m.end())
            if expression.lstrip().startswith("'"):
                continue        # APP_CALL has it
            if is_declaration(expression):
                continue        # the wrapper's own declaration
            passed = re.match(r'\s*(\w+)\s*$', expression)
            if passed and passed.group(1) in WRAPPERS.get(rel, ()):
                continue
            line = text[:m.start()].count('\n') + 1
            # Only the branches of a ternary, never its condition:
            #
            #   kind == 'subdomain' ? 'decide_subdomain' : 'decide_mailbox'
            #
            # has three literals and two RPC names, and reading all
            # three reported `subdomain` as a function granted to
            # nobody -- a gate failing on something that was never a
            # call, which is worse than one that stays quiet.
            branches = expression.split('?', 1)[-1]
            literals = re.findall(r"'([a-z_][a-z0-9_]*)'", branches)
            if literals:
                for name in literals:
                    app_calls.setdefault(name, f'{rel}:{line}')
                continue
            if re.search(r'\w*[Rr]pc\b', expression):
                continue        # named for what it holds; declared
                                # elsewhere and found by LITERAL_RPC_NAME
            unreadable.append((f'{rel}:{line}', expression.strip()[:40]))

    if unreadable:
        print(f'FAIL: {len(unreadable)} RPC call(s) name something this '
              f'script cannot read.')
        print()
        print('An RPC whose name is an expression cannot be checked, and a')
        print('call this gate cannot see is how twelve of them stayed')
        print('outside it. Name the expression for what it holds -- ending')
        print('in `Rpc` -- so the literal behind it is found where it is')
        print('declared, the way `kind.postRpc` is.')
        print()
        for where, expression in unreadable:
            print(f'  {where}: rpc({expression}...)')
        return 1

    held = grants(url, {name for name, _, _ in calls} | set(app_calls))

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

    for name, where in sorted(app_calls.items()):
        roles = held.get(name)
        if roles is None or not roles:
            missing.append((name, 'the app', where, 'is granted to nobody'
                            if name in held else 'does not exist in public'))
        elif not roles & {'authenticated', 'anon'}:
            # Reachable by the service role alone. The app cannot
            # present that key and must never be able to.
            missing.append((name, 'the app', where,
                            'is granted only to ' + ', '.join(sorted(roles))))

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
          f'edge functions and {len(app_calls)} from the app can execute '
          f'as the role they arrive as.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
