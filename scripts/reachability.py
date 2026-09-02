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
                and c.prosrc like '%' || p.proname || '%'
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

Two traps this avoids, both of which produced false positives on the
first hand-rolled pass:

  * searching only for 'quoted_name' misses PostgREST embeds, which
    appear as `contacts(name, code)` inside a select string;
  * a name that appears only inside a comment is not a reference.

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
        from_sql = len(row) > 3 and row[3].strip() == "sql"

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
