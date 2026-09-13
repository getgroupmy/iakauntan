#!/usr/bin/env python3
"""Describe the API this database already has.

`docs/gaps-against-rillet.md` is the argument for this file. Rillet
publishes thirty OpenAPI documents and an `llms.txt`; iAkauntan
publishes nothing, and yet Supabase has been exposing 662 functions
over PostgREST to any holder of a tenant's token since the first
migration. The API is not missing. It is undescribed -- which is worse,
because it is reachable either way.

So this documents what exists rather than building anything new, and it
is generated from `pg_proc` rather than written by hand, because a
description maintained by hand is a description that drifts. The same
discipline `scripts/check_embeds.py` applies to the client's queries:
the schema is the authority, and the artifact is checked against it in
CI.

    python3 scripts/generate_api_description.py "$DATABASE_URL"
    python3 scripts/generate_api_description.py "$DATABASE_URL" --check

`--check` regenerates into memory and compares. A schema change that
moves the surface without regenerating fails the build, and the message
says which line moved.

## What is described, and what is deliberately not

Every function in `public` that `anon` or `authenticated` may execute.
That is the surface a tenant's own token reaches, which is the surface
worth describing.

Functions granted only to `service_role` are left out on purpose. They
are reachable solely by the secret key, which never leaves the edge
functions and the workflows -- `docs/schedulers.md` says why -- so a map
of them helps nobody building against this and is a list of the most
dangerous entry points in the system. `record_bank_feed_run` is the
shape: it writes a feed's result and trusts its caller completely.

The `app` schema is not described either, and cannot be reached: it is
not in PostgREST's exposed schemas, and `0165`'s event trigger strips
EXECUTE from PUBLIC on everything in it.
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'docs' / 'api'
OPENAPI = OUT / 'openapi.json'
LLMS = OUT / 'llms.txt'

# The roles a tenant's own token carries. `service_role` is deliberately
# absent -- see the module header.
PUBLIC_ROLES = ('anon', 'authenticated')

# Postgres type -> JSON Schema. PostgREST speaks JSON over HTTP, so what
# matters is the shape on the wire, not the storage type: `numeric`
# crosses as a number, `uuid` and every date/time type as a string with
# the format that says how to read it.
SCALARS = {
    'boolean': {'type': 'boolean'},
    'smallint': {'type': 'integer', 'format': 'int16'},
    'integer': {'type': 'integer', 'format': 'int32'},
    'bigint': {'type': 'integer', 'format': 'int64'},
    'numeric': {'type': 'number'},
    'double precision': {'type': 'number', 'format': 'double'},
    'real': {'type': 'number', 'format': 'float'},
    'text': {'type': 'string'},
    'citext': {'type': 'string'},
    'character varying': {'type': 'string'},
    'character': {'type': 'string'},
    'uuid': {'type': 'string', 'format': 'uuid'},
    'date': {'type': 'string', 'format': 'date'},
    'timestamp with time zone': {'type': 'string', 'format': 'date-time'},
    'timestamp without time zone': {'type': 'string', 'format': 'date-time'},
    'time without time zone': {'type': 'string'},
    'interval': {'type': 'string'},
    'json': {},
    'jsonb': {},
    'bytea': {'type': 'string', 'format': 'byte'},
    'inet': {'type': 'string', 'format': 'ipv4'},
    'tsvector': {'type': 'string'},
    'void': {'type': 'null'},
    'record': {'type': 'object'},
}

FUNCTIONS_SQL = r"""
with granted as (
  select p.oid
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prokind = 'f'
     -- `citext`, `btree_gist` and `pg_trgm` install into `public` and
     -- their several hundred functions carry EXECUTE to PUBLIC, which
     -- anon inherits. They are reachable and they are not this API;
     -- `gbt_int4_penalty` in a published description is noise that
     -- makes the real surface harder to find.
     and not exists (select 1 from pg_depend d
                      where d.objid = p.oid and d.deptype = 'e')
     -- `has_function_privilege` rather than reading `proacl`, because
     -- the two differ: a grant to PUBLIC reaches anon, and appears in
     -- the ACL as grantee 0 rather than as the anon role. Today they
     -- agree here only because `0165`'s event trigger strips PUBLIC
     -- from everything in `public` and `app` -- so reading the ACL
     -- would be right by accident, and would go quietly wrong if that
     -- trigger were ever dropped. This asks the question the door
     -- asks.
     and (has_function_privilege('anon', p.oid, 'execute')
       or has_function_privilege('authenticated', p.oid, 'execute'))
)
select coalesce(json_agg(x order by x->>'name', x->>'signature'), '[]'::json)
  from (
    select json_build_object(
      'name', p.proname,
      'signature', pg_get_function_identity_arguments(p.oid),
      'returns', pg_get_function_result(p.oid),
      'returns_set', p.proretset,
      'volatility', p.provolatile,
      'description', d.description,
      -- The module guard the function carries in its own body. 0231
      -- moved these with the same regexp, and it is the only statement
      -- of a function's subject that lives in the code rather than in
      -- somebody's naming convention. Null means the function is not
      -- module-gated at all, which is itself worth knowing.
      'module', (regexp_match(
          p.prosrc, 'can_(?:read|write)_module\([^,]+,\s*''([a-z_]+)'''))[1],
      'roles', (
        select array_agg(r order by r)
          from unnest(%(roles)s::text[]) r
         where has_function_privilege(r, p.oid, 'execute')),
      'args', (
        select coalesce(json_agg(json_build_object(
                 'name', a.argname,
                 'type', format_type(a.argtype, null),
                 'optional', a.pos > p.pronargs - p.pronargdefaults
               ) order by a.pos), '[]'::json)
          from unnest(
                 p.proargtypes,
                 coalesce(p.proargnames[1:p.pronargs], array[]::text[]))
               with ordinality as a(argtype, argname, pos))
    ) as x
    from granted g
    join pg_proc p on p.oid = g.oid
    left join pg_description d on d.objoid = p.oid and d.objsubid = 0
  ) s;
"""

ENUMS_SQL = r"""
select coalesce(json_object_agg(name, labels), '{}'::json) from (
  -- Keyed the way `format_type` spells it. Keying on the bare
  -- `typname` is the bug this comment exists to stop repeating: every
  -- one of the hundred-odd enums then failed to resolve, silently, and
  -- the document described `app.doc_status` as "a Postgres type" --
  -- losing the list of labels, which is the most useful thing in it.
  -- A caller guessing at a status gets 22P02 and no list of what would
  -- have been accepted.
  select n.nspname || '.' || t.typname as name,
         array_agg(e.enumlabel order by e.enumsortorder) as labels
    from pg_type t
    join pg_enum e on e.enumtypid = t.oid
    join pg_namespace n on n.oid = t.typnamespace
   where n.nspname in ('public', 'app')
   group by 1
) s;
"""

# A table is in the surface if a tenant role may read it. Whether RLS is
# on is reported rather than assumed: a granted table with RLS off is
# the whole tenant's data, and that would be a finding, not a footnote.
TABLES_SQL = r"""
select coalesce(json_agg(x order by x->>'name'), '[]'::json) from (
  select json_build_object(
    'name', c.relname,
    'kind', c.relkind,
    'rls', c.relrowsecurity,
    -- A view has no RLS of its own. `security_invoker` decides whose
    -- rights it runs with, and therefore whether the underlying
    -- tables' policies apply to the caller -- so "RLS off" said about
    -- a view is meaningless without it. `v_lot_balances` is the
    -- specimen: RLS off, invoker rights, every policy underneath it
    -- still in force.
    'security_invoker', coalesce(
        (c.reloptions @> array['security_invoker=true']), false),
    'description', d.description,
    'privileges', (
      select array_agg(pr order by pr)
        from unnest(%(roles)s::text[]) r
        cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) priv
        cross join lateral (select priv || ':' || r as pr) x
       where has_table_privilege(r, c.oid, priv)),
    'columns', (
      select coalesce(json_agg(json_build_object(
               'name', att.attname,
               'type', format_type(att.atttypid, att.atttypmod),
               -- Required on INSERT: declared NOT NULL and carrying no
               -- default. A NOT NULL column with a default (every
               -- `id`, every `created_at`) is not something a caller
               -- has to send, and listing it as required would be
               -- wrong in the direction that costs somebody an hour.
               'required', att.attnotnull and not att.atthasdef
             ) order by att.attnum), '[]'::json)
        from pg_attribute att
       where att.attrelid = c.oid and att.attnum > 0 and not att.attisdropped)
  ) as x
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  left join pg_description d on d.objoid = c.oid and d.objsubid = 0
 where n.nspname = 'public'
   and c.relkind in ('r', 'v', 'm', 'p')
   and not exists (select 1 from pg_depend d
                    where d.objid = c.oid and d.deptype = 'e')
   and (has_table_privilege('anon', c.oid, 'select')
     or has_table_privilege('authenticated', c.oid, 'select'))
) s;
"""


def query(db: str, sql: str) -> object:
    """One psql round trip, returning parsed JSON.

    `-tAc` rather than a driver because every other check in `scripts/`
    does the same and CI has psql but installs no Python packages.
    """
    roles = '{' + ','.join(PUBLIC_ROLES) + '}'
    out = subprocess.run(
        ['psql', db, '-tAc', sql % {'roles': repr(roles)}],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        raise SystemExit(f'psql failed:\n{out.stderr.strip()}')
    return json.loads(out.stdout.strip() or 'null')


def schema_for(pg_type: str, enums: dict,
               tables: frozenset = frozenset()) -> dict:
    """One Postgres type as JSON Schema.

    Arrays are spelled `type[]` by `format_type`, which is the only
    shape this has to unwrap. An enum becomes a string with its labels,
    and those labels are the most useful thing in the whole document: a
    caller guessing at `adjustment_type` gets a 22P02 from the database
    and no list of what it would have accepted.
    """
    t = pg_type.strip()
    if t.endswith('[]'):
        return {'type': 'array', 'items': schema_for(t[:-2], enums, tables)}
    # `character varying(64)` and friends: the length is not a JSON
    # Schema concern and PostgREST does not enforce it at the door.
    bare = re.sub(r'\(.*\)$', '', t).strip()
    if bare in SCALARS:
        return dict(SCALARS[bare])
    # `format_type` schema-qualifies anything not on the search path, so
    # an enum arrives as `app.doc_status` and a table as `organizations`.
    for key in (bare, f'app.{bare}', f'public.{bare}'):
        if key in enums:
            return {'type': 'string', 'enum': list(enums[key])}
    # `returns setof organizations` names a table, and that table's row
    # is already a schema in this document.
    plain = bare.split('.')[-1]
    if plain in tables:
        return {'$ref': f'#/components/schemas/{plain}'}
    # A composite or domain this script has not met. Described as "we do
    # not know" rather than guessed at: a wrong type in a published
    # description is worse than an absent one, because it is believed.
    return {'description': f'Postgres type `{bare}`'}


RETURNS_TABLE = re.compile(r'^TABLE\((.*)\)$', re.S)
RETURNS_SETOF = re.compile(r'^SETOF\s+(.*)$', re.S)


def split_columns(body: str) -> list[tuple[str, str]]:
    """`a uuid, b numeric` -> [(a, uuid), (b, numeric)].

    Split on commas at bracket depth zero, because `numeric(12,2)` is
    one column and a naive split makes it two.
    """
    out, depth, cur = [], 0, ''
    for ch in body:
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        if ch == ',' and depth == 0:
            out.append(cur)
            cur = ''
        else:
            cur += ch
    out.append(cur)
    columns = []
    for piece in out:
        piece = piece.strip()
        if not piece:
            continue
        name, _, typ = piece.partition(' ')
        columns.append((name, typ.strip()))
    return columns


def response_schema(fn: dict, enums: dict, tables: frozenset) -> dict:
    """What comes back, from `pg_get_function_result`."""
    returns = fn['returns'].strip()
    m = RETURNS_TABLE.match(returns)
    if m:
        cols = split_columns(m.group(1))
        row = {
            'type': 'object',
            'properties': {n: schema_for(t, enums, tables)
                           for n, t in cols},
        }
        return {'type': 'array', 'items': row}
    m = RETURNS_SETOF.match(returns)
    if m:
        return {'type': 'array',
                'items': schema_for(m.group(1), enums, tables)}
    one = schema_for(returns, enums, tables)
    # `returns setof uuid` without the word SETOF cannot happen, but
    # `proretset` is the authority either way.
    return {'type': 'array', 'items': one} if fn['returns_set'] else one


def operation(fn: dict, enums: dict, tables: frozenset) -> dict:
    """One function as an OpenAPI operation.

    Everything is POST. PostgREST will serve a STABLE function over GET
    as well, and this document does not say so, because the client in
    this repository has never used it and a description should describe
    the door people actually walk through. The volatility is reported
    instead, which is the fact underneath it.
    """
    props, required = {}, []
    for arg in fn['args']:
        name = arg['name'] or f'arg{len(props) + 1}'
        props[name] = schema_for(arg['type'], enums, tables)
        if not arg['optional']:
            required.append(name)

    reads = fn['volatility'] in ('s', 'i')
    described = fn['description'] or ''
    summary = (described.split('.')[0][:110] if described
               else fn['name'].replace('_', ' ').capitalize())

    body = {'type': 'object', 'properties': props}
    if required:
        body['required'] = required

    note = [
        f"`public.{fn['name']}({fn['signature']})`",
        'Reads only.' if reads else 'Writes.',
        ('Reachable without signing in.' if 'anon' in (fn['roles'] or [])
         else 'Requires a signed-in user.'),
    ]
    if fn['module']:
        note.append(
            f"Refused unless the company has the `{fn['module']}` module "
            'and the caller may use it.')

    return {
        'operationId': fn['name'],
        'summary': summary,
        'description': '\n\n'.join([described] if described else []) +
                       ('\n\n' if described else '') + ' '.join(note),
        'tags': [fn['module'] or 'general'],
        'x-volatility': 'stable' if reads else 'volatile',
        'x-roles': fn['roles'] or [],
        'requestBody': {
            'required': bool(required),
            'content': {'application/json': {'schema': body}},
        },
        'responses': {
            '200': {
                'description': 'The function returned.',
                'content': {
                    'application/json': {
                        'schema': response_schema(fn, enums, tables)}},
            },
            '401': {'$ref': '#/components/responses/Unauthenticated'},
            '403': {'$ref': '#/components/responses/Refused'},
            '404': {'$ref': '#/components/responses/NotFound'},
        },
    }


def schema_version() -> str:
    """The highest applied migration number.

    A version that changes when, and only when, the schema does. A
    timestamp would change on every run and make the CI check useless;
    a hand-kept semver would drift, which is the failure this whole
    file exists to prevent.
    """
    numbered = sorted(
        p.name for p in (ROOT / 'supabase' / 'migrations').glob('*.sql')
        if re.match(r'^\d{4}_', p.name))
    return numbered[-1][:4] if numbered else '0000'


def build_openapi(fns: list, tables: list, enums: dict) -> dict:
    # The row schemas this document will carry, so a function returning
    # `setof organizations` can point at one instead of describing it
    # again in different words.
    known = frozenset(t['name'] for t in tables)
    modules = sorted({f['module'] for f in fns if f['module']})
    paths = {}
    for fn in fns:
        # Overloads share a path. PostgREST picks between them on the
        # argument names it is given, which OpenAPI cannot express --
        # so the longest signature wins the slot and the operation
        # description names the others. `0307`'s idempotency wrappers
        # are all of this case.
        key = f"/rpc/{fn['name']}"
        op = operation(fn, enums, known)
        if key in paths:
            existing = paths[key]['post']
            existing.setdefault('x-overloads', []).append(fn['signature'])
            if len(fn['args']) <= len(existing['requestBody']['content']
                                      ['application/json']['schema']
                                      .get('properties', {})):
                continue
            op['x-overloads'] = existing.get('x-overloads', [])
        paths[key] = {'post': op}

    # Said in the prose as well as in the extension. `x-overloads` is
    # machine-readable and most viewers hide it, and this is the one
    # subtlety in the whole document that a reader must not miss: the
    # shorter overload of a protected write is the UNPROTECTED one, and
    # PostgREST chooses between them on the argument names it is given.
    for key, item in paths.items():
        op = item.get('post')
        if not op or 'x-overloads' not in op:
            continue
        others = ', '.join(f'`({sig})`' for sig in op['x-overloads'])
        op['description'] += (
            f"\n\nThis function is overloaded. Described above is the "
            f"longest form; also defined: {others}. PostgREST picks "
            f"between them on the argument names in the request body, "
            f"so omitting one merely-optional argument can resolve to a "
            f"different function than the one intended — for the "
            f"idempotency-protected writes, to the unprotected original.")

    for t in tables:
        paths[f"/{t['name']}"] = {
            'get': {
                'operationId': f"select_{t['name']}",
                'summary': f"Read {t['name']}",
                'description': (t['description'] or '') + (
                    '\n\n' if t['description'] else '') +
                    ('Row-level security is on: a request returns the rows '
                     'this caller is allowed to see, and an empty list is a '
                     'real answer rather than an error.'
                     if t['rls'] else
                     'A view running with the caller\'s own rights, so the '
                     'policies on the tables underneath it apply.'
                     if t['security_invoker'] else
                     'No row-level security.'),
                'tags': ['tables'],
                'parameters': [
                    {'name': 'select', 'in': 'query', 'required': False,
                     'schema': {'type': 'string'},
                     'description':
                         'PostgREST column list, e.g. `id,name`. Embeds '
                         'are resolved against the foreign keys.'},
                    {'name': 'limit', 'in': 'query', 'required': False,
                     'schema': {'type': 'integer'}},
                    {'name': 'offset', 'in': 'query', 'required': False,
                     'schema': {'type': 'integer'}},
                    {'name': 'order', 'in': 'query', 'required': False,
                     'schema': {'type': 'string'},
                     'description': 'e.g. `created_at.desc`.'},
                ],
                'responses': {
                    '200': {
                        'description': 'Matching rows.',
                        'content': {'application/json': {'schema': {
                            'type': 'array',
                            'items': {'$ref':
                                      f"#/components/schemas/{t['name']}"}}}},
                    },
                    '401': {'$ref': '#/components/responses/Unauthenticated'},
                },
            }
        }

    schemas = {}
    for t in tables:
        props = {c['name']: schema_for(c['type'], enums, known)
                 for c in t['columns']}
        required = [c['name'] for c in t['columns'] if c['required']]
        schemas[t['name']] = {'type': 'object', 'properties': props,
                              **({'required': required} if required else {})}

    return {
        'openapi': '3.1.0',
        'info': {
            'title': 'iAkauntan',
            'version': schema_version(),
            'summary': 'Accounting, CRM, HR and payroll, corporate '
                       'secretarial and LHDN e-Invoice for Malaysian '
                       'businesses.',
            'description': INFO_DESCRIPTION,
            'license': {'name': 'Proprietary'},
        },
        'servers': [{
            'url': 'https://{project}.supabase.co/rest/v1',
            'description': 'The tenant\'s own Supabase project.',
            'variables': {'project': {
                'default': 'ewwcgtnniwqndrzukksm',
                'description': 'The project ref this app is built against.'}},
        }],
        'security': [{'bearerAuth': [], 'apiKey': []}],
        'tags': (
            [{'name': 'general',
              'description': 'Not gated on any module.'}] +
            [{'name': m,
              'description': f'Refused unless the company has the `{m}` '
                             'module switched on.'} for m in modules] +
            [{'name': 'tables',
              'description': 'Read directly through PostgREST, under RLS.'}]),
        'paths': dict(sorted(paths.items())),
        'components': {
            'securitySchemes': {
                'bearerAuth': {
                    'type': 'http', 'scheme': 'bearer', 'bearerFormat': 'JWT',
                    'description':
                        'The signed-in user\'s access token. Every policy '
                        'and every `app.can_*` guard reads the claims in '
                        'it, so this is what decides the answer.'},
                'apiKey': {
                    'type': 'apiKey', 'in': 'header', 'name': 'apikey',
                    'description':
                        'The project\'s anon key. It identifies the '
                        'project and grants nothing on its own. The '
                        'service role key is not an alternative to it '
                        'here: that key bypasses RLS and belongs only in '
                        'the edge functions.'},
            },
            'responses': {
                'Unauthenticated': {
                    'description': 'No usable token.'},
                'Refused': {
                    'description':
                        'A guard said no — SQLSTATE 42501. The message is '
                        'the guard\'s own words and is meant to be shown.'},
                'NotFound': {
                    'description':
                        'No such function, or no such row — SQLSTATE '
                        'P0002. Under RLS these are the same answer on '
                        'purpose: whether a row exists is itself '
                        'something a caller may not be entitled to know.'},
            },
            'schemas': dict(sorted(schemas.items())),
        },
    }


INFO_DESCRIPTION = """\
Generated from `pg_proc` by `scripts/generate_api_description.py` and
checked against the schema in CI. Do not edit by hand: the next run
will overwrite it, and the check will fail before that.

**The database is the application.** Business rules are SQL — RLS
policies plus `app.can_*` guards inside SECURITY DEFINER functions —
so a refusal here is the rule itself talking, not a validation layer in
front of it. There is no way to reach this API that skips them.

**Every call carries a company.** Most functions take `p_org_id` or
`p_org` and check membership of that company before anything else.
Passing a company you are not a member of is a 42501, not an empty
result.

**Writes that must not happen twice take a key.** `post_manual_journal`,
`create_contra`, `create_deposit` and `record_pdc` each have an overload
whose first argument is an idempotency key. A retry with the same key
returns the first call's answer; the same key with different arguments
is refused. The key parameter has no default on purpose — a call that
omits it resolves to the unprotected original.

**Errors are Postgres errors.** PostgREST returns the SQLSTATE and the
message. 42501 is a guard refusing, 23514 a check constraint, 23505 a
unique violation, P0002 a missing row. The messages are written to be
shown to a person.
"""


def llms_txt(fns: list, tables: list, version: str) -> str:
    """The same surface, for something that reads prose.

    `llms.txt` is a convention, not a schema: an H1, a blockquote that
    says what this is, and then the facts in the order somebody needs
    them. What an agent gets wrong about this API is never the JSON
    shape — the OpenAPI has that — it is the three things above it:
    that a company is an argument, that a refusal is the rule speaking,
    and that a write which must not repeat takes a key.
    """
    by_module: dict[str, list] = {}
    for fn in fns:
        by_module.setdefault(fn['module'] or 'general', []).append(fn)

    reads = sum(1 for f in fns if f['volatility'] in ('s', 'i'))
    anon = sorted(f['name'] for f in fns if 'anon' in (f['roles'] or []))
    described = sum(1 for f in fns if f['description'])

    lines = [
        '# iAkauntan',
        '',
        '> Accounting, CRM, HR and payroll, corporate secretarial and LHDN',
        '> e-Invoice for Malaysian businesses. The HTTP surface is',
        '> PostgREST over Postgres: every endpoint below is a function or a',
        '> table in one database, and the authorization is that database\'s',
        '> own row-level security rather than a layer in front of it.',
        '',
        f'Schema version `{version}` (the highest applied migration).',
        f'{len(fns)} functions and {len(tables)} readable tables, of which',
        f'{reads} functions only read.',
        '',
        'Generated from the catalog by',
        '`scripts/generate_api_description.py` and checked in CI, so this',
        'file cannot drift from what the database will actually do.',
        '',
        f'**{described} of {len(fns)} functions carry a `comment on',
        'function`**, and those are the only ones described here in',
        'words. The rest show their name, their arguments and their',
        'types, which is what the catalog knows about them. A function',
        'with no line of prose here is not a function that does nothing',
        'surprising — it is one nobody has written down yet, and the',
        'name is a worse guide than it looks.',
        '',
        '## Before anything else',
        '',
        '- **Base URL** `https://<project>.supabase.co/rest/v1`. Functions',
        '  are `POST /rpc/<name>` with a JSON object of the named',
        '  arguments; tables are `GET /<table>` with PostgREST\'s query',
        '  syntax.',
        '- **Two headers, both needed.** `apikey` is the project\'s anon',
        '  key and grants nothing on its own. `Authorization: Bearer',
        '  <token>` is the signed-in user, and it is what every policy',
        '  reads. The service role key bypasses RLS entirely and belongs',
        '  only in server-side code.',
        '- **A company is an argument, not a session.** Most functions take',
        '  `p_org_id` or `p_org`. A company you are not a member of is a',
        '  42501, never an empty list.',
        '- **A refusal is the rule speaking.** 42501 messages are written',
        '  to be shown to a person. Do not paraphrase them; the guard',
        '  knows why it said no and a paraphrase drifts.',
        '- **Writes that must not repeat take a key.** See the idempotency',
        '  overloads below.',
        '',
        '## Idempotent writes',
        '',
        'Four money writes have an overload whose first argument is',
        '`p_idempotency_key`. A retry with the same key returns the first',
        'call\'s answer; the same key with different arguments is refused',
        'rather than quietly answered. The key has no default, because a',
        'call that omits one merely-optional argument would otherwise',
        'resolve to the unprotected original and return a plausible id.',
        '',
    ]

    protected = sorted(
        f['name'] for f in fns if 'p_idempotency_key' in f['signature'])
    for name in protected:
        lines.append(f'- `{name}`')
    if not protected:
        lines.append('- none found in this schema')

    lines += [
        '',
        '## Reachable without signing in',
        '',
        f'{len(anon)} functions are granted to `anon`. Everything else',
        'needs a user token.',
        '',
    ]
    lines += [f'- `{n}`' for n in anon]

    lines += ['', '## The functions, by module', '']
    for module in sorted(by_module, key=lambda m: (m == 'general', m)):
        group = sorted(by_module[module], key=lambda f: f['name'])
        if module == 'general':
            lines.append(f'### general ({len(group)})')
            lines.append('')
            lines.append('Not gated on any module.')
        else:
            lines.append(f'### {module} ({len(group)})')
            lines.append('')
            lines.append(
                f'Refused unless the company has the `{module}` module '
                'switched on and the caller may use it.')
        lines.append('')
        for fn in group:
            mark = '' if fn['volatility'] in ('s', 'i') else ' *(writes)*'
            summary = ''
            if fn['description']:
                first = fn['description'].split('. ')[0].strip().rstrip('.')
                summary = f' — {first}.'
            lines.append(f"- `{fn['name']}({fn['signature']})`{mark}{summary}")
        lines.append('')

    lines += [
        '## Tables',
        '',
        'Read with `GET /<table>`. Row-level security decides which rows',
        'come back, so an empty list is a real answer and not an error.',
        'Writing through the table endpoints is not described here: the',
        'functions above carry the business rules, and an INSERT that',
        'bypasses them is refused by a policy or leaves the books',
        'inconsistent.',
        '',
    ]
    for t in tables:
        note = '' if t['rls'] else (
            ' *(view, caller\'s own rights)*' if t['security_invoker']
            else ' *(no row-level security)*')
        lines.append(f"- `{t['name']}`{note}")

    lines.append('')
    return '\n'.join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('database_url')
    ap.add_argument('--check', action='store_true',
                    help='regenerate into memory and fail if the committed '
                         'files differ')
    args = ap.parse_args()

    enums = query(args.database_url, ENUMS_SQL)
    fns = query(args.database_url, FUNCTIONS_SQL)
    tables = query(args.database_url, TABLES_SQL)
    version = schema_version()

    openapi = json.dumps(build_openapi(fns, tables, enums),
                         indent=2, sort_keys=False) + '\n'
    llms = llms_txt(fns, tables, version)

    if args.check:
        stale = []
        for path, fresh in ((OPENAPI, openapi), (LLMS, llms)):
            on_disk = path.read_text(encoding='utf-8') if path.exists() else ''
            if on_disk != fresh:
                stale.append((path, on_disk, fresh))
        if not stale:
            print(f'ok   the API description matches the schema '
                  f'({len(fns)} functions, {len(tables)} tables, '
                  f'version {version})')
            return 0
        print('FAIL the API description no longer matches the schema.\n',
              file=sys.stderr)
        for path, on_disk, fresh in stale:
            rel = path.relative_to(ROOT)
            old_lines = on_disk.splitlines()
            new_lines = fresh.splitlines()
            print(f'  {rel}: {len(old_lines)} lines on disk, '
                  f'{len(new_lines)} regenerated', file=sys.stderr)
            for i, (a, b) in enumerate(zip(old_lines, new_lines), 1):
                if a != b:
                    print(f'    first difference at line {i}:', file=sys.stderr)
                    print(f'      on disk:      {a[:120]}', file=sys.stderr)
                    print(f'      regenerated:  {b[:120]}', file=sys.stderr)
                    break
            else:
                shorter = min(len(old_lines), len(new_lines))
                print(f'    identical to line {shorter}, then one ends',
                      file=sys.stderr)
        print('\n  Regenerate and commit the result:\n'
              '    python3 scripts/generate_api_description.py "$DB"',
              file=sys.stderr)
        return 1

    OUT.mkdir(parents=True, exist_ok=True)
    OPENAPI.write_text(openapi, encoding='utf-8')
    LLMS.write_text(llms, encoding='utf-8')
    print(f'wrote {OPENAPI.relative_to(ROOT)} and {LLMS.relative_to(ROOT)} '
          f'({len(fns)} functions, {len(tables)} tables, version {version})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
