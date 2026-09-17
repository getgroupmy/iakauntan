#!/usr/bin/env python3
"""Which tables and RPCs can nothing in the app reach?

Schema lands ahead of behaviour in this codebase — of the eleven
capabilities built before this script existed, nine were already in the
database with nothing able to call them. That gap is invisible to every
other check: the migrations apply, the tests pass, the analyzer is clean,
and every screen that exists works.

Usage
-----
Get the inventory out of the database:

    select 'table', table_name, '', ''
      from information_schema.tables
     where table_schema = 'public' and table_type = 'BASE TABLE'
    union all
    select 'rpc', p.proname, pg_get_function_identity_arguments(p.oid),
           case when exists (
             select 1 from pg_proc c
              where c.oid <> p.oid
                -- \m and \M, not like '%...%'. A substring match says
                -- `create_gl_entry` is called by every body that
                -- mentions `create_gl_entry_internal`, which moves a
                -- dead function into the quiet bucket -- the direction
                -- this whole script exists to prevent. It still counts
                -- a bare identifier: a COLUMN named `clock_out` reads
                -- as a call to the function `clock_out`, and so does a
                -- name in a comment. Pass --database-url below to have
                -- the bodies read properly instead.
                and c.prosrc ~ ('\m' || p.proname || '\M')
                and c.pronamespace in ('public'::regnamespace,
                                       'app'::regnamespace))
                then 'sql' else '' end
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and has_function_privilege('authenticated', p.oid, 'execute')
       -- Extension-owned functions are granted because that is how an
       -- extension installs, not because anything should call them.
       -- Asking pg_depend beats a list of prefixes, which is what this
       -- used to do and which went stale the day btree_gist was
       -- installed: 37 of its internals were being reported as gaps.
       and not exists (
         select 1 from pg_depend d
          where d.objid = p.oid and d.classid = 'pg_proc'::regclass
            and d.deptype = 'e');

save it as CSV (kind,name,args,called_from_sql) and run:

    python3 scripts/reachability.py inventory.csv

or, better, hand it the database as well and let it work the SQL half
out for itself:

    python3 scripts/reachability.py inventory.csv "$DATABASE_URL"

which reads the bodies through `sql_call_graph`: comments out, and a
CALL SHAPE required rather than a bare identifier. Both matter, and the
second more than expected -- `attendance.clock_out` is a column, and
`r.clock_out is null` is not a call to `public.clock_out`, which is the
sort of thing that quietly keeps a dead function looking alive.

Two traps this avoids, both of which produced false positives on the
first hand-rolled pass:

  * searching only for 'quoted_name' misses PostgREST embeds, which
    appear as `contacts(name, code)` inside a select string;
  * a name that appears only inside a comment is not a reference.

That second rule was applied to Dart and never to SQL, where the
inventory query used `prosrc like '%name%'` -- which counts a mention
in a comment AND matches `create_gl_entry` inside every body naming
`create_gl_entry_internal`. Measured: the substring rule calls 32
functions reachable that a word-boundary match does not, `audit_trail`
inside `platform_audit_trail` among them. Every one of those pushes a
possibly-dead function into the quiet "only SQL calls it" bucket.

The query now uses `\m...\M`, and `--database-url` goes further,
requiring a call shape rather than a bare identifier -- because
`r.clock_out is null` reads a COLUMN and is not a call to
`public.clock_out`.

A function nothing in the app calls is not necessarily unreachable:
this codebase writes through functions that call other functions, so
`shared_payment_options` is reached by `open_shared_document` and
`pos_line_modifier_gaps` by `send_order_to_kitchen`. Those are listed
apart, because they are a different question and a real one — a
function only SQL calls does not need its grant to `authenticated`,
since inside a SECURITY DEFINER function the caller is the owner.
"""

import csv
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

SOURCE_ROOTS = ["app/lib", "supabase/functions"]
SOURCE_SUFFIXES = (".dart", ".ts", ".js")

# Nothing here any more. Which functions belong to an extension is a
# question the database answers exactly, and the inventory query above
# now asks it. The prefix list this replaces was written when citext
# and pg_trgm were the only extensions installed and was never revised;
# by the time it was measured it was missing every one of btree_gist's
# gbt_*, gbtreekey* and *_dist functions, so a third of the report was
# noise the filter was meant to remove. A hand-kept list of what the
# database already knows goes stale in one migration.


def read_sources():
    """Every source file, with line comments stripped.

    Comments are stripped because a table named only in a docstring is
    not reachable, and the first pass of this check was fooled by
    exactly that: `create_gl_entry` appeared three times in app/lib and
    every one was prose.
    """
    files = []
    for root in SOURCE_ROOTS:
        for dirpath, _, names in os.walk(root):
            for n in names:
                if not n.endswith(SOURCE_SUFFIXES):
                    continue
                path = os.path.join(dirpath, n)
                with open(path, errors="ignore") as fh:
                    body = "\n".join(
                        re.sub(r"//.*$", "", line) for line in fh.read().split("\n"))
                files.append((path, body))
    return files


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2

    # The SQL half, worked out here rather than taken from the CSV, so
    # a name appearing only in a comment does not count as a call.
    #
    # `_CALL` wants `name(`, so a column called `clock_out` is not a
    # call to the function `clock_out` -- which the `\m...\M` query
    # above cannot tell apart.
    #
    # `clean` blanks string literals as well as comments, so a call made
    # through `execute 'select foo()'` is not seen. That UNDER-counts,
    # which is the safe direction here: an under-count reports a gap a
    # person then triages, and an over-count hides a dead function in
    # silence.
    sql_callers = None
    if len(sys.argv) > 2:
        from sql_call_graph import load, _CALL
        rows = load(sys.argv[2])
        sql_callers = set()
        for row in rows:
            for m in _CALL.finditer(row['clean']):
                nm = m.group(1).lower()
                if nm != row['name'].lower():
                    sql_callers.add(nm)

    files = read_sources()
    if not files:
        print("No sources found — run this from the repository root.",
              file=sys.stderr)
        return 1

    unreachable = {"table": [], "rpc": []}
    sql_only = []
    for row in csv.reader(open(sys.argv[1])):
        if len(row) < 2:
            continue
        kind, name = row[0].strip(), row[1].strip()
        if kind not in unreachable:
            continue
        if sql_callers is None:
            from_sql = len(row) > 3 and row[3].strip() == "sql"
        else:
            from_sql = name.lower() in sql_callers

        pattern = re.compile(r"\b" + re.escape(name) + r"\b")
        where = [os.path.basename(p) for p, body in files if pattern.search(body)]
        if where:
            continue
        if from_sql:
            sql_only.append(name)
        else:
            unreachable[kind].append(name)

    for kind in ("table", "rpc"):
        print(f"\n{len(unreachable[kind])} {kind}s nothing references:")
        for name in sorted(unreachable[kind]):
            print(f"  {name}")

    print(f"\n{len(sql_only)} rpcs no source file calls, but another "
          f"routine does:")
    for name in sorted(sql_only):
        print(f"  {name}")
    print("  (reachable, so not a gap — but each one holds an execute "
          "grant it may not need)")

    print("\nNot every one is a gap — some are written by triggers or read "
          "through an RPC that is called. docs/unreachable.md has the "
          "triage.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
