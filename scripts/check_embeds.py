#!/usr/bin/env python3
"""Refuse PostgREST embeds that the database cannot resolve.

    python3 scripts/check_embeds.py "$DATABASE_URL"

`client.from('employees').select('*, departments(name)')` reads fine and
analyzes clean, and then fails at run time with PGRST201 because there is
more than one way to join the two tables — an employee belongs to a
department, and a department has a head employee. PostgREST refuses the
whole request rather than guessing, so one ambiguous embed takes out the
entire screen.

Nothing else catches this. It is inside a string literal, so the Dart
analyzer cannot see it; the widget tests do not talk to a database; and
the SQL tests do not know what the client asks for. It reaches the
browser, which is exactly how it reached ours — twice, on two different
screens, on a live site.

So: ask the database which pairs of tables are joinable more than one
way, counting both directions the way PostgREST does, then read every
.select() in the app and fail if any of them embeds across such a pair
without naming the constraint.
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

# Every ordered pair of distinct tables with more than one foreign key
# between them, in either direction. Both directions matter: a reverse
# key makes an embed ambiguous just as surely as a second forward one,
# which is the half we missed the first time round.
AMBIGUOUS_PAIRS_SQL = """
with fk as (
  select c.conrelid::regclass::text as src,
         c.confrelid::regclass::text as tgt
  from pg_constraint c
  join pg_namespace n on n.oid = c.connamespace
  where c.contype = 'f' and n.nspname = 'public'
)
select least(src, tgt) || ' ' || greatest(src, tgt)
from fk
where src <> tgt
group by 1
having count(*) > 1;
"""

FROM_RE = re.compile(r"\.from\(\s*'([a-z_]+)'")
SELECT_RE = re.compile(r"\.select\(\s*'([^']*)'")
# An embedded resource: an optional `alias:`, the name, an optional
# `!constraint` disambiguator, then the opening bracket of its column list.
EMBED_RE = re.compile(r"(?:^|,)\s*(?:\w+:)?([a-z_]+)\s*(!\w+)?\s*\(")


def ambiguous_pairs(database_url: str) -> set[frozenset[str]]:
    out = subprocess.run(
        ["psql", database_url, "-t", "-A", "-c", AMBIGUOUS_PAIRS_SQL],
        capture_output=True, text=True, check=True,
    ).stdout
    pairs = set()
    for line in out.splitlines():
        parts = line.strip().split()
        if len(parts) == 2:
            pairs.add(frozenset(parts))
    return pairs


def scan(root: pathlib.Path, pairs: set[frozenset[str]]) -> list[str]:
    problems = []
    for path in sorted(root.rglob("*.dart")):
        table = None
        for number, line in enumerate(path.read_text().splitlines(), 1):
            found = FROM_RE.search(line)
            if found:
                table = found.group(1)
            select = SELECT_RE.search(line)
            if not (select and table):
                continue
            for embedded, constraint in EMBED_RE.findall(select.group(1)):
                if constraint or frozenset((table, embedded)) not in pairs:
                    continue
                problems.append(
                    f"{path}:{number}\n"
                    f"    '{table}' embeds '{embedded}', which can be joined "
                    f"more than one way.\n"
                    f"    PostgREST will refuse this with PGRST201 at run "
                    f"time and the screen will fail.\n"
                    f"    Name the constraint — {embedded}!"
                    f"{table}_<column>_fkey(...) — or drop the embed if "
                    f"nothing reads it.\n"
                    f"    {select.group(1)[:90]}"
                )
    return problems


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    pairs = ambiguous_pairs(sys.argv[1])
    problems = scan(pathlib.Path("app/lib"), pairs)

    if problems:
        print(f"{len(problems)} ambiguous PostgREST embed(s):\n")
        for problem in problems:
            print(problem + "\n")
        return 1

    print(f"No ambiguous embeds. ({len(pairs)} pairs of tables are joinable "
          f"more than one way.)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
