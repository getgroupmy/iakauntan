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

And the hole that let one through anyway: a `.from()` whose table is a
VARIABLE. `client.from(kind.table).select('*, contacts(name, code)')`
reads the same to a person and is invisible here, because the table name
is not in the source to be matched — the scanner kept whatever literal
table it had seen last and checked the embed against the wrong one. That
is how the invoice list shipped broken while this script said the app
was clean. A dynamic `.from()` is now tracked as UNKNOWN, and a bare
embed under one is refused whenever the embedded table can be joined
more than one way to anything at all: not knowing which table we are on
is not a reason to allow it, it is a reason the constraint must be
named.
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

# Every foreign key by name, and the two tables it joins.
#
# Naming a constraint is not the same as naming the RIGHT one, and that
# is the second half this script used to miss entirely. `profiles!
# payslip_access_requests_requested_by_fkey` named a constraint that
# existed -- and pointed at `auth.users`. PostgREST can only embed
# `profiles` through a constraint whose target IS `profiles`, so the
# screen answered PGRST200 on every database built from these
# migrations, while the hosted project had been quietly given a second
# constraint of that name pointing the right way. The script waved it
# through because a name was present.
CONSTRAINTS_SQL = """
select c.conname,
       c.conrelid::regclass::text,
       c.confrelid::regclass::text
  from pg_constraint c
  join pg_namespace n on n.oid = c.connamespace
 where c.contype = 'f' and n.nspname = 'public';
"""

# Both of these are searched over the WHOLE FILE rather than line by
# line. A `.select(` whose string sits on the NEXT line -- which is what
# `dart format` does to a long one -- was invisible to a line-at-a-time
# scanner, and that is how the second PGRST201 of the day reached a live
# screen with this script reporting the app clean.
FROM_RE = re.compile(r"\.from\(\s*'([a-z_]+)'")
# `.from(` with anything that is not a quoted literal: a variable, a
# getter, an interpolation. The table cannot be known here.
DYNAMIC_FROM_RE = re.compile(r"\.from\(\s*(?!')\S", re.S)
SELECT_RE = re.compile(r"\.select\(", re.S)
# One string literal, so a run of them can be walked.
STRING_RE = re.compile(r"'([^']*)'")
# An embedded resource: an optional `alias:`, the name, an optional
# `!constraint` disambiguator, then the opening bracket of its column list.
EMBED_RE = re.compile(r"(?:^|,)\s*(?:\w+:)?([a-z_]+)\s*((?:!\w+)*)\s*\(")
# An embedded resource whose NAME is interpolated: `${kind.lineTable}(*)`.
# The table cannot be read here, so it cannot be checked -- which is how
# the second PGRST201 of the day reached a live screen. The convention
# that makes it checkable is that the expression must name an EMBED
# rather than a TABLE: `${kind.lineEmbed}` carries its own `!constraint`
# and `${kind.lineTable}` does not.
INTERPOLATED_EMBED_RE = re.compile(r"\$\{([^}]+)\}\s*\(")


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


def constraints(db_url: str) -> dict[str, set[tuple[str, str]]]:
    """Constraint name -> the (source, target) pairs it joins.

    A name can repeat across tables, so this is a set rather than one
    pair: `..._org_id_fkey` exists on nearly every table.
    """
    raw = subprocess.run(
        ["psql", db_url, "-t", "-A", "-c", CONSTRAINTS_SQL],
        capture_output=True, text=True, check=True,
    ).stdout
    out: dict[str, set[tuple[str, str]]] = {}
    for line in raw.splitlines():
        parts = line.strip().split("|")
        if len(parts) != 3:
            continue
        name, src, tgt = parts
        out.setdefault(name, set()).add((strip_schema(src), strip_schema(tgt)))
    return out


def select_literal(text: str, at: int) -> str | None:
    """Join the string literals making up one .select() argument.

    Dart concatenates adjacent literals, and every long select in this
    app is written over several lines that way:

        .select(
          '*, items!bills_of_materials_item_id_fkey(code, name), '
          'bom_lines(*, items!bom_lines_item_id_fkey(code, name)), '
          'bom_operations(*, work_centres(code, name, cost_per_hour))',
        )

    Reading only the first literal -- which is what this script did
    until the whole of `bom_lines`, `mo_components`, `mo_operations`,
    `appraisal_cycles`, `onboarding_tasks`, `warehouses`, `contacts` and
    `pos_memberships` went past it -- checks the first line of a
    three-line select and reports the app clean. Nine ambiguous embeds
    were live behind that, and the docstring above already tells the
    story of the same hole one level up: the `.select(` spanning lines
    was fixed, the STRING spanning lines was not.

    `scripts/check_query_columns.py` has had this since it was written.
    That is where the shape is from.

    Stops at the first top-level comma, which is where the column list
    ends and `.select()`'s second argument begins -- adjacent literals
    are never separated by one.
    """
    depth, i, parts = 1, at, []
    while i < len(text) and depth > 0:
        ch = text[i]
        if ch == "'":
            m = STRING_RE.match(text, i)
            if not m:
                return None
            parts.append(m.group(1))
            i = m.end()
            continue
        if ch == "," and depth == 1:
            break
        if ch in "({[":
            depth += 1
        elif ch in ")}]":
            depth -= 1
        i += 1
    return "".join(parts) if parts else None


def strip_schema(name: str) -> str:
    """`public.contacts` and `contacts` are the same table; `auth.users`
    is not `users`, and keeping its schema is what makes the difference
    visible in the message."""
    return name[len("public."):] if name.startswith("public.") else name



def scan(
    root: pathlib.Path,
    pairs: set[frozenset[str]],
    fks: dict[str, set[tuple[str, str]]],
) -> list[str]:
    # Every table that is joinable more than one way to SOMETHING. An
    # embed of one of these under an unknown `.from()` cannot be cleared.
    ambiguous_anywhere = {name for pair in pairs for name in pair}

    problems = []
    for path in sorted(root.rglob("*.dart")):
        text = path.read_text()

        # Every `.from(...)` in the file, with the offset it starts at,
        # so the table for a `.select(` is the nearest one BEFORE it --
        # which is what the chain `client.from(x).select(y)` means, on
        # one line or on five.
        froms: list[tuple[int, str | None]] = []
        for found in FROM_RE.finditer(text):
            froms.append((found.start(), found.group(1)))
        for found in DYNAMIC_FROM_RE.finditer(text):
            froms.append((found.start(), None))
        froms.sort()

        def table_before(offset: int) -> str | None:
            table = None
            for at, name in froms:
                if at > offset:
                    break
                table = name
            return table

        for select in SELECT_RE.finditer(text):
            columns = select_literal(text, select.end())
            if columns is None:
                continue
            number = text.count("\n", 0, select.start()) + 1
            table = table_before(select.start())

            # An interpolated embed name, which no regex can resolve to
            # a table. Held to the naming convention instead: an
            # expression ending in `Embed` is one that carries its own
            # `!constraint`; anything else is a bare table name and is
            # exactly the mistake this catches.
            for expression in INTERPOLATED_EMBED_RE.findall(columns):
                if expression.strip().endswith('Embed'):
                    continue
                problems.append(
                    f"{path}:{number}\n"
                    f"    embeds '${{{expression}}}', a name this script "
                    f"cannot resolve to a table.\n"
                    f"    If the relationship is ambiguous PostgREST "
                    f"answers PGRST201 and the screen fails, and nothing "
                    f"here can tell whether it is.\n"
                    f"    Put the whole embed -- name AND !constraint -- "
                    f"on the expression, and name it `...Embed`.\n"
                    f"    {columns[:90]}"
                )

            for embedded, constraint in EMBED_RE.findall(columns):
                # `!inner` and `!left` are PostgREST's join-type
                # modifiers, not constraint names, and they can sit
                # beside one: `contacts!contacts_org_fkey!inner`. Only
                # what is left after taking them out is a constraint.
                hints = [h for h in constraint.split("!") if h]
                named = [h for h in hints if h not in ("inner", "left")]
                if named:
                    # Named -- but named WHAT. A constraint that exists
                    # and points somewhere else cannot carry this embed,
                    # and PostgREST answers PGRST200 rather than
                    # guessing. This is the half that let
                    # `profiles!payslip_access_requests_requested_by_fkey`
                    # through for as long as it took a schema dump of
                    # the deployed project to notice.
                    name = named[0]
                    joins = fks.get(name)
                    if joins is None:
                        problems.append(
                            f"{path}:{number}\n"
                            f"    embeds '{embedded}!{name}' and there is "
                            f"no constraint of that name in `public`.\n"
                            f"    PostgREST answers PGRST200 and the whole "
                            f"request fails.\n"
                            f"    {columns[:90]}"
                        )
                        continue
                    reaches = {tgt for src, tgt in joins} | {
                        src for src, tgt in joins
                    }
                    if embedded not in reaches:
                        went = ", ".join(
                            sorted(f"{src} -> {tgt}" for src, tgt in joins))
                        problems.append(
                            f"{path}:{number}\n"
                            f"    embeds '{embedded}!{name}', and that "
                            f"constraint joins {went}.\n"
                            f"    It cannot reach '{embedded}', so "
                            f"PostgREST answers PGRST200.\n"
                            f"    {columns[:90]}"
                        )
                    continue
                if table is None:
                    if embedded not in ambiguous_anywhere:
                        continue
                    problems.append(
                        f"{path}:{number}\n"
                        f"    embeds '{embedded}' from a table this script "
                        f"cannot read -- the `.from()` takes a variable.\n"
                        f"    '{embedded}' is joinable more than one way "
                        f"to at least one table, so this may be PGRST201 "
                        f"at run time on some of the tables it is called "
                        f"with.\n"
                        f"    Name the constraint, and if the table varies "
                        f"put the whole embed on the enum that varies "
                        f"with it.\n"
                        f"    {columns[:90]}"
                    )
                    continue
                if frozenset((table, embedded)) not in pairs:
                    continue
                problems.append(
                    f"{path}:{number}\n"
                    f"    '{table}' embeds '{embedded}', which can be "
                    f"joined more than one way.\n"
                    f"    PostgREST will refuse this with PGRST201 at run "
                    f"time and the screen will fail.\n"
                    f"    Name the constraint -- {embedded}!"
                    f"{table}_<column>_fkey(...) -- or drop the embed if "
                    f"nothing reads it.\n"
                    f"    {columns[:90]}"
                )
    return problems


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    pairs = ambiguous_pairs(sys.argv[1])
    fks = constraints(sys.argv[1])
    problems = scan(pathlib.Path("app/lib"), pairs, fks)

    if problems:
        print(f"{len(problems)} PostgREST embed problem(s):\n")
        for problem in problems:
            print(problem + "\n")
        return 1

    print(f"Every embed resolves. ({len(pairs)} pairs of tables are "
          f"joinable more than one way; {len(fks)} named constraints "
          f"checked.)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
