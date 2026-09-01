#!/usr/bin/env python3
"""Refuse a column name this schema does not have.

    python3 scripts/check_query_columns.py "$DATABASE_URL"

`client.from('statutory_schedules').select('id').eq('schedule_type', 'pcb')`
reads fine, analyzes clean, and fails at run time with 42703 — there is
no `schedule_type` column, a schedule's body is `body`. PostgREST refuses
the whole request, so one wrong word takes out everything the screen
needed.

That one shipped. It filled the dropdown of reliefs an employee may
declare on a TP1, the provider turned the failure into an empty list
with `valueOrNull ?? const []`, and `onPressed: types.isEmpty ? null :
...` left the Add button greyed out. Nobody could declare a relief, and
nothing anywhere said why: `employee_tax_reliefs` was empty on the
hosted project in every organization, which is what a feature that has
never once worked looks like from the database.

`check_embeds.py` is the same idea one level up — it refuses an embed
the database cannot resolve — and says of that class "Nothing else
catches this. It is inside a string literal, so the Dart analyzer cannot
see it." A plain column name is inside the same string literal.

So: read every column the database has, then read every
`.from('table')` chain in the app and fail on any column name that table
does not carry.

## What is checked, and what is deliberately not

Checked, for a chain whose `.from()` names a table this schema has:

  * every top-level name in a `.select()` list;
  * the first argument of every filter and ordering — `.eq`, `.neq`,
    `.gt`, `.gte`, `.lt`, `.lte`, `.like`, `.ilike`, `.order` and the
    rest;
  * every top-level key of an `.insert()`, `.update()` or `.upsert()`
    map. A key the table does not have comes back PGRST204, "column not
    found in the schema cache", and the write does not happen;
  * the `onConflict:` of an upsert, which must name the columns of a
    unique constraint or unique index exactly. PostgREST passes it to
    `ON CONFLICT` and Postgres answers 42P10 when no unique index
    matches, so an upsert that has drifted from its constraint fails
    every time rather than inserting a duplicate.

Not checked:

  * anything inside an embed's brackets. Those columns belong to the
    embedded table, and which table that is depends on the relationship
    — `check_embeds.py` is what reads embeds.
  * a name containing `.`, `(`, `->` or `::`. Those are an embedded
    path, an aggregate, a JSON traversal or a cast, and none of them is
    a bare column of this table.
  * a spread — `{...values, 'org_id': orgId}`. What `values` holds is
    not visible here; the literal keys beside it still are, and are
    checked.
  * `.rpc()`. A function's parameters are `check_idempotent_calls.py`'s
    ground, not this one's.

A chain ends at the first `;`, which is what a Dart statement ends at.
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

COLUMNS_SQL = """
select c.relname || ':' || string_agg(a.attname, ',' order by a.attnum)
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  join pg_attribute a
    on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
 where n.nspname = 'public' and c.relkind in ('r','p','v','m','f')
 group by c.relname;
"""

# Every set of columns an ON CONFLICT could name: unique indexes, which
# is what Postgres actually looks for, and which covers the primary key
# and every unique constraint because each is backed by one.
UNIQUE_SQL = """
select c.relname || ':' || string_agg(a.attname, ',' order by a.attname)
  from pg_index i
  join pg_class c on c.oid = i.indrelid
  join pg_namespace n on n.oid = c.relnamespace
 cross join lateral unnest(i.indkey) with ordinality as k(att, ord)
  join pg_attribute a on a.attrelid = c.oid and a.attnum = k.att
 where n.nspname = 'public' and i.indisunique
 group by i.indexrelid, c.relname;
"""

APP = pathlib.Path(__file__).resolve().parent.parent / "app" / "lib"

FROM_RE = re.compile(r"\.from\(\s*'([a-z_0-9]+)'\s*\)")
# `client.storage.from('logos')` names a bucket, not a relation, and the
# `.uploadBinary()` and `.remove()` that follow are not PostgREST at all.
# Written as a lookbehind first, which missed every one of them: the
# chains are formatted `client.storage` then `.from(` on the next line,
# so what precedes the dot is a newline and eight spaces.
STORAGE_RE = re.compile(r"storage\s*$")
STRING_RE = re.compile(r"'((?:[^'\\]|\\.)*)'")
SELECT_RE = re.compile(r"\.select\(")
FILTER_RE = re.compile(
    r"\.(eq|neq|gt|gte|lt|lte|like|ilike|likeAllOf|likeAnyOf|ilikeAllOf"
    r"|ilikeAnyOf|contains|containedBy|overlaps|rangeGt|rangeGte|rangeLt"
    r"|rangeLte|rangeAdjacent|order|isFilter|inFilter)\(\s*'([^']*)'"
)
WRITE_RE = re.compile(r"\.(insert|update|upsert)\(\s*\{")
KEY_RE = re.compile(r"'([a-z_0-9]+)'\s*:")
ON_CONFLICT_RE = re.compile(r"onConflict\s*:\s*'([^']*)'")

# A chain runs to the end of its Dart statement.
CHAIN_LIMIT = 8000


def columns(database_url: str) -> dict[str, set[str]]:
    out = subprocess.run(
        ["psql", database_url, "-t", "-A", "-c", COLUMNS_SQL],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    found: dict[str, set[str]] = {}
    for line in out.splitlines():
        line = line.strip()
        if not line or ":" not in line:
            continue
        table, names = line.split(":", 1)
        found[table] = set(names.split(","))
    if len(found) < 100:
        sys.exit(
            f"only {len(found)} relations in public — the catalogue query "
            "cannot have reached the schema this checks against"
        )
    return found


def unique_sets(database_url: str) -> dict[str, set[str]]:
    out = subprocess.run(
        ["psql", database_url, "-t", "-A", "-c", UNIQUE_SQL],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    found: dict[str, set[str]] = {}
    for line in out.splitlines():
        line = line.strip()
        if not line or ":" not in line:
            continue
        table, names = line.split(":", 1)
        found.setdefault(table, set()).add(names)
    return found


def select_literal(chain: str, at: int) -> str | None:
    """Join the string literals making up one .select() argument.

    Dart concatenates adjacent literals, and the long selects in this
    app are written over several lines that way.
    """
    depth, i, parts = 1, at, []
    while i < len(chain) and depth > 0:
        ch = chain[i]
        if ch == "'":
            m = STRING_RE.match(chain, i)
            if not m:
                return None
            parts.append(m.group(1))
            i = m.end()
            continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        i += 1
    return "".join(parts) if parts else None


def top_level(select: str) -> list[str]:
    """The select list split on commas outside any embed's brackets."""
    out, depth, cur = [], 0, ""
    for ch in select:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    out.append(cur)
    return [t.strip() for t in out if t.strip()]


def written_keys(chain: str, at: int) -> list[str]:
    """The top-level keys of the map literal starting at `at`.

    Depth 1 only: a nested map or list belongs to a jsonb column and its
    keys are not columns. A string literal only counts as a key when it
    follows the opening brace or a comma — without that,
    `'kind': voice ? 'voice' : 'file'` reads its own ternary branch as a
    second key, which is how the first draft of this reported a `voice`
    column on `chat_messages`.
    """
    depth, i = 0, at
    while i < len(chain):
        if chain[i] == "{":
            depth += 1
        elif chain[i] == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    body = chain[at: i + 1]

    keys, depth, j = [], 0, 0
    while j < len(body):
        ch = body[j]
        if ch in "{[(":
            depth += 1
        elif ch in "}])":
            depth -= 1
        elif ch == "'" and depth == 1:
            before = body[:j].rstrip()
            km = KEY_RE.match(body, j)
            if km and (before.endswith("{") or before.endswith(",")):
                keys.append(km.group(1))
                j = km.end()
                continue
        j += 1
    return keys


def bare_column(token: str) -> str | None:
    """The column a select token names, or None if it names none."""
    if "(" in token or token == "*":
        return None
    name = token.split(":")[-1] if ":" in token else token
    name = name.split("::")[0].split("->")[0].strip()
    name = name.replace("!inner", "").replace("!left", "").strip()
    return name if re.fullmatch(r"[a-z_0-9]+", name) else None


def main() -> int:
    if len(sys.argv) != 2:
        sys.exit("usage: check_query_columns.py DATABASE_URL")

    known = columns(sys.argv[1])
    unique = unique_sets(sys.argv[1])
    problems: list[str] = []
    checked = 0

    for path in sorted(APP.rglob("*.dart")):
        text = path.read_text()
        for m in FROM_RE.finditer(text):
            if STORAGE_RE.search(text[max(0, m.start() - 40): m.start()]):
                continue
            table = m.group(1)
            line = text.count("\n", 0, m.start()) + 1
            where = f"{path.relative_to(APP.parent.parent)}:{line}"

            if table not in known:
                problems.append(f"{where}  from('{table}') — no such relation")
                continue

            rest = text[m.end(): m.end() + CHAIN_LIMIT]
            end = rest.find(";")
            chain = rest if end == -1 else rest[:end]

            sm = SELECT_RE.search(chain)
            if sm:
                literal = select_literal(chain, sm.end())
                if literal:
                    for token in top_level(literal):
                        name = bare_column(token)
                        if name is None:
                            continue
                        checked += 1
                        if name not in known[table]:
                            problems.append(
                                f"{where}  select '{name}' — "
                                f"{table} has no such column"
                            )

            for fm in FILTER_RE.finditer(chain):
                column = fm.group(2)
                if not re.fullmatch(r"[a-z_0-9]+", column):
                    continue          # an embedded path, a cast, an expression
                checked += 1
                if column not in known[table]:
                    problems.append(
                        f"{where}  .{fm.group(1)}('{column}') — "
                        f"{table} has no such column"
                    )

            for wm in WRITE_RE.finditer(chain):
                for key in written_keys(chain, wm.end() - 1):
                    checked += 1
                    if key not in known[table]:
                        problems.append(
                            f"{where}  .{wm.group(1)}() writes '{key}' — "
                            f"{table} has no such column"
                        )

            for cm in ON_CONFLICT_RE.finditer(chain):
                spec = ",".join(
                    sorted(c.strip() for c in cm.group(1).split(",") if c.strip())
                )
                checked += 1
                if spec not in unique.get(table, set()):
                    problems.append(
                        f"{where}  onConflict '{cm.group(1)}' — {table} has "
                        "no unique index on exactly those columns, so the "
                        "upsert fails 42P10"
                    )

    if checked < 600:
        # A rewrite of the client that this stopped matching would
        # otherwise pass by checking nothing at all.
        problems.append(
            f"only {checked} column references were found in the client — "
            "this check has stopped reading it"
        )

    if problems:
        print("Column names the schema does not have:\n")
        for p in problems:
            print("  " + p)
        print(
            "\nPostgREST refuses the whole request for each of these — "
            "42703 on a read, PGRST204 on a write, 42P10 on an upsert — "
            "so each one takes out everything the screen needed."
        )
        return 1

    print(f"ok  {checked} column references, every one of them real")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
