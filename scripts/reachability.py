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

    select 'table', table_name, '' from information_schema.tables
     where table_schema = 'public' and table_type = 'BASE TABLE'
    union all
    select 'rpc', p.proname, pg_get_function_identity_arguments(p.oid)
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and has_function_privilege('authenticated', p.oid, 'execute');

save it as CSV (kind,name,args) and run:

    python3 scripts/reachability.py inventory.csv

Two traps this avoids, both of which produced false positives on the
first hand-rolled pass:

  * searching only for 'quoted_name' misses PostgREST embeds, which
    appear as `contacts(name, code)` inside a select string;
  * a name that appears only inside a comment is not a reference.

Extension functions (citext, pg_trgm) are filtered out — they are
granted to authenticated because that is how extensions are installed,
not because anything should call them.
"""

import csv
import os
import re
import sys

SOURCE_ROOTS = ["app/lib", "supabase/functions"]
SOURCE_SUFFIXES = (".dart", ".ts", ".js")

# Installed by extensions, not by us.
EXTENSION_PREFIXES = (
    "citext", "gtrgm", "gin_", "word_similarity", "strict_word_similarity",
    "similarity", "regexp_", "textic", "show_trgm", "set_limit", "show_limit",
)
EXTENSION_EXACT = {"replace", "split_part", "strpos", "translate",
                   "rls_auto_enable"}


def is_extension(name):
    return name.startswith(EXTENSION_PREFIXES) or name in EXTENSION_EXACT


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
    for row in csv.reader(open(sys.argv[1])):
        if len(row) < 2:
            continue
        kind, name = row[0].strip(), row[1].strip()
        if kind not in unreachable or is_extension(name):
            continue

        pattern = re.compile(r"\b" + re.escape(name) + r"\b")
        where = [os.path.basename(p) for p, body in files if pattern.search(body)]
        if not where:
            unreachable[kind].append(name)

    for kind in ("table", "rpc"):
        print(f"\n{len(unreachable[kind])} {kind}s nothing references:")
        for name in sorted(unreachable[kind]):
            print(f"  {name}")

    print("\nNot every one is a gap — some are written by triggers or read "
          "through an RPC that is called. docs/unreachable.md has the "
          "triage.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
