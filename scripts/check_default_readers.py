#!/usr/bin/env python3
"""Picking "the default" without asking whether it is still open.

Thirteen functions chose a default warehouse or pipeline with

    where org_id = ... and is_default limit 1

and no `is_active` -- eleven of them with no `order by` either, so not
even a stable arbitrary answer. A warehouse that is closed but still
flagged default is a second matching row, and whichever one the plan
reaches first is where a sale gets depleted from.

`0741` gave eight tables a partial unique index on
`(org_id) where is_default and is_active`, which makes the TEN readers
that do filter `is_active` provably single-rowed and does nothing for
the other thirteen. `0742` closed those by fixing the premise instead of
the thirteen bodies: a CHECK that a row cannot be default while
inactive, so `where is_default` and `where is_default and is_active`
select the same rows. Re-emitting a 27,407-character function body to
add one word is how, the same week, re-applying `0029` to restore one
function reverted `0404`'s `calc_statutory`; thirteen of those would be
thirteen chances at it.

So the rule this gate keeps, and it is a disjunction rather than a ban:

    a function may read `is_default` without `is_active` ONLY IF that
    table carries a `<table>_default_is_active` CHECK.

Either the query asks the question or the schema answers it in advance.
Adding a fourteenth bare reader on a table without the constraint is the
regression this exists to refuse, and so is dropping the constraint
while the bare readers remain.

Read from the LATEST definition of each function, never the first.
`0530` and `0691` write `CREATE OR REPLACE FUNCTION` in upper case, and
a case-sensitive grep for the lower-case form named `0446` as the latest
definition of `app.calc_pcb` and was wrong by RM6,000 of relief --
twice, because the first fix sampled four lines of the body and the two
versions differ by one number.
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MIGRATIONS = ROOT / "supabase" / "migrations"

# A floor, so a run that matched nothing cannot report a clean sweep.
# `check_sweeps_look.py` exists because a gate of mine passed over an
# empty list and turned CI green on two commits.
LEAST_FUNCTIONS = 600

# The flags that mean "there is one of these". Each is a plain boolean
# with nothing in the type system saying only one row may carry it.
SINGLETON_FLAGS = ('is_default', 'is_primary', 'is_lead')

# Any of these in the same fragment means the query asked whether the row
# is still live. Which one is right is the table's business, not this
# gate's: `payment_methods` uses `deleted_at is null` because a method
# can be switched off without being deleted and its charge account is
# still needed for last year's postings. The gate asks only whether the
# question was asked at all.
LIVENESS = ('is_active', 'deleted_at is null', 'not is_deleted',
            'deleted_at is not null')

# A floor on the SCOPE, not just on the function count. A parser that has
# stopped recognising `create table` finds no flagged tables, judges
# nothing, and reports a clean sweep.
LEAST_TABLES = 12

# Proof the gate is looking: each must be reported by `judge` when fed.
CANARIES = {
    'bare reader, unconstrained table': (
        "select id into v_x from public.tax_codes "
        "where org_id = p_org and is_default limit 1;",
        'tax_codes', 'is_default'),
}

COLUMN = r"(?:,|\(|^)\s*{}\s+bool"
CREATE_TABLE = re.compile(
    r"create\s+table\s+(?:if\s+not\s+exists\s+)?public\.([a-z_0-9]+)"
    r"\s*\((.*?)\n\);", re.S)
ADD_COLUMN = re.compile(
    r"alter\s+table\s+(?:if\s+exists\s+)?public\.([a-z_0-9]+)\s+"
    r"add\s+column\s+(?:if\s+not\s+exists\s+)?([a-z_0-9]+)\s+")


def _columns() -> dict[str, set[str]]:
    """table -> the column names the migrations declare on it.

    Derived rather than hand-kept, because the hand-kept version of this
    list was wrong within the hour of being written: it named
    `contact_addresses`, which has no liveness column at all and so
    cannot have this bug, and omitted `pos_modifiers`, which does. Two
    errors in fourteen entries, and the same staleness the `ci.yml`
    assertion-file list keeps a guard against.
    """
    out: dict[str, set[str]] = {}
    for path in sorted(MIGRATIONS.glob("*.sql")):
        low = path.read_text().lower()
        for m in CREATE_TABLE.finditer(low):
            table, body = m.group(1), m.group(2)
            for line in body.split("\n"):
                word = line.strip().split(" ")
                if len(word) >= 2:
                    out.setdefault(table, set()).add(word[0].strip('",'))
        for m in ADD_COLUMN.finditer(low):
            out.setdefault(m.group(1), set()).add(m.group(2))
    return out


def in_scope(columns: dict[str, set[str]] | None = None) -> dict[str, str]:
    """table -> its singleton flag, for tables where liveness can go stale.

    A table with no `is_active` and no `deleted_at` is excluded: every row
    is live, so there is no second matching row for a reader to pick by
    accident. Four of the eighteen flagged tables are in that position.
    """
    columns = _columns() if columns is None else columns
    scope = {}
    for table, cols in columns.items():
        flag = next((f for f in SINGLETON_FLAGS if f in cols), None)
        if flag is None:
            continue
        if not ({'is_active', 'deleted_at', 'is_deleted'} & cols):
            continue
        scope[table] = flag
    return scope

FUNCTION = re.compile(
    r"create\s+or\s+replace\s+function\s+([a-z_]+\.[a-z_0-9]+)\s*\(", re.I)


def latest_definitions() -> dict[str, tuple[str, str]]:
    """name -> (migration file, the body of its LATEST definition)."""
    found: dict[str, tuple[str, str]] = {}
    for path in sorted(MIGRATIONS.glob("*.sql")):
        text = path.read_text()
        for m in FUNCTION.finditer(text):
            found[m.group(1).lower()] = (path.name, _body(text, m.start()))
    return found


def _body(text: str, start: int) -> str:
    """From the signature to the closing dollar-quote tag."""
    tag = re.search(r"\$([a-z_0-9]*)\$", text[start:start + 4000])
    if tag is None:
        return text[start:start + 9000]
    opened = start + tag.end()
    closed = text.find(tag.group(0), opened)
    return text[start:closed if closed > 0 else start + 9000]


def constrained() -> set[str]:
    """Tables given a `<table>_<flag>_is_active` CHECK by a migration.

    `warehouses_default_is_active` for `is_default`;
    `<table>_primary_is_active` would serve `is_primary` the same way.
    """
    names = set()
    want = re.compile(r"([a-z_]+?)_(?:default|primary|lead)_is_active")
    for path in sorted(MIGRATIONS.glob("*.sql")):
        text = path.read_text().lower()
        for m in want.finditer(text):
            # A `drop constraint` of it takes the table back off the list,
            # so dropping the CHECK while bare readers remain is caught.
            before = text[max(0, m.start() - 80):m.start()]
            if 'drop constraint' in before:
                names.discard(m.group(1))
            else:
                names.add(m.group(1))
    return names


# Any of these in the same fragment means the query asked whether the row
# is still live. Which one is right is the table's business, not this
# gate's: `payment_methods` uses `deleted_at is null` because a method
# can be switched off without being deleted and its charge account is
# still needed for last year's postings. The gate asks only whether the
# question was asked at all.
LIVENESS = ('is_active', 'deleted_at is null', 'not is_deleted',
            'deleted_at is not null')


def judge(body: str, table: str, flag: str = "is_default") -> bool:
    """True if `body` PICKS one of `table`'s rows by `flag` alone.

    Deliberately structural, and deliberately blind to three things it
    would need judgement for:

      * `update ... set is_default = false` is not judged at all. Four of
        the five findings on the first run were that statement -- the
        clear-the-old-default half of a setter -- where NOT filtering on
        liveness is the correct behaviour, because a retired row holding
        a stale flag is exactly what wants clearing. A gate that flags
        the correct form of a write it does not understand is a gate
        somebody turns off.
      * which liveness column is the right one. See LIVENESS.
      * whether some unique index makes the pick single-rowed anyway.
        That needs knowing whether the query's filters imply the index's
        predicate, which is real work; `docs/handoff.md` records four
        gates thrown away on 4 October for needing judgement, and this
        would have been the fifth.
    """
    flat = re.sub(r"\s+", " ", body.lower())
    for m in re.finditer(
            r"(?:from|join)\s+public\." + table + r"\b(.{0,240}?)"
            r"(limit\s+1|;|\)\s*(?:into|loop|as))", flat):
        fragment, end = m.group(1), m.group(2)
        if flag not in fragment:
            continue
        if any(live in fragment for live in LIVENESS):
            continue
        # A pick of ONE row. `limit 1` says so outright; `select ... into`
        # takes the first row whether it says so or not.
        before = flat[max(0, m.start() - 140):m.start()]
        if end.startswith('limit') or ' into ' in before:
            return True
    return False


def offenders(definitions: dict[str, tuple[str, str]] | None = None,
              allowed: set[str] | None = None,
              scope: dict[str, str] | None = None) -> list[str]:
    definitions = latest_definitions() if definitions is None else definitions
    allowed = constrained() if allowed is None else allowed
    scope = in_scope() if scope is None else scope
    bad = []
    for name, (where, body) in sorted(definitions.items()):
        for table, flag in sorted(scope.items()):
            if table in allowed:
                continue
            if judge(body, table, flag):
                short = flag.removeprefix('is_')
                bad.append(f"{name} ({where}) picks one of public.{table}'s "
                           f"rows by {flag} alone, and {table} has no "
                           f"{table}_{short}_is_active CHECK to make that "
                           f"single-rowed")
    return bad


def main() -> int:
    definitions = latest_definitions()
    allowed = constrained()

    # Canaries before the floor: a gate whose matcher has stopped working
    # reports an empty list, which reads exactly like a pass.
    scope = in_scope()
    for label, (snippet, table, flag) in CANARIES.items():
        if not judge(snippet, table, flag):
            print(f"::error::the canary '{label}' was not reported; this "
                  f"gate is no longer looking at anything")
            return 1
        if table in allowed:
            print(f"::error::the canary '{label}' names {table}, which now "
                  f"HAS the CHECK -- pick a table that does not, or the "
                  f"canary proves nothing")
            return 1
        if table not in scope:
            print(f"::error::the canary '{label}' names {table}, which is no "
                  f"longer in scope, so it proves nothing about the sweep")
            return 1

    if len(scope) < LEAST_TABLES:
        print(f"::error::only {len(scope)} flagged tables were derived from "
              f"the migrations, fewer than the floor of {LEAST_TABLES}; the "
              f"`create table` parser has drifted and this gate is judging "
              f"almost nothing")
        return 1

    if len(definitions) < LEAST_FUNCTIONS:
        print(f"::error::only {len(definitions)} function definitions were "
              f"read, fewer than the floor of {LEAST_FUNCTIONS}; the "
              f"migrations were not found or the pattern has drifted")
        return 1

    bad = offenders(definitions, allowed, scope)
    if bad:
        print("::error::a default is read without asking whether the row is "
              "still active, on a table with no CHECK to make that safe:")
        for line in bad:
            print(f"  {line}")
        print("\nEither add `and is_active` to the query, or give the table "
              "a `<table>_default_is_active` CHECK the way 0742 did for "
              "warehouses and pipelines.")
        return 1

    print(f"::notice::{len(definitions)} function definitions checked "
          f"against {len(scope)} tables carrying a singleton flag and a "
          f"liveness column; every bare pick is on a table whose CHECK "
          f"makes it safe ({', '.join(sorted(allowed))})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
