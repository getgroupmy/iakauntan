#!/usr/bin/env python3
"""No money column is a floating-point type.

    python3 scripts/check_money_is_numeric.py

Every money column in this database is `numeric`, and until now that was
true by convention and enforced by nothing. One `double precision`
column added by somebody in a hurry would be indistinguishable from the
rest until a figure came out wrong, and it would come out wrong in the
place where it is hardest to notice: a ledger that is off by a sen and
still balances against itself.

## What a float actually costs here

Not the tiny error. `numeric(18, 2)` rounds on insert, so a double's
~1e-13 error is far below half a sen and is absorbed -- that is why the
Dart side's `double` has never corrupted a stored figure. A COLUMN typed
`double precision` has no such scale. It stores the error, sums it with
the next one, and compares it: `where balance = 0` stops matching rows
whose balance is 0.00000000000001, and a document that is paid in full
stays forever on the aged listing.

## What it looks for

Column declarations inside `create table`, plus `add column` in an
`alter table`, whose name looks like money and whose type is
`double precision`, `real`, `float`, `float4` or `float8`.

The name test is deliberately generous -- `amount`, `total`, `price`,
`cost`, `balance`, `paid`, `due`, `debit`, `credit`, `subtotal`, `tax`,
`charge`, `fee`, `salary`, `wage`, `pay`, `value` -- because a false
alarm here is a one-line change to the census below and a miss is a
figure nobody checks.

## What it deliberately does NOT look for

A float that is not money. `quantity` may legitimately be one; so may a
percentage, a latitude, a confidence score, a duration. Those are not
money and are not this gate's business. Anything that is genuinely a
float and matches the name test goes in `ALLOWED` with a line saying
why, which is the same arrangement every other gate here uses -- and the
staleness check below refuses an entry that no longer matches anything,
so the list cannot quietly become a backlog.
"""

from __future__ import annotations

import pathlib
import os
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MIGRATIONS = ROOT / "supabase/migrations"

# Anything whose name contains one of these is money until said otherwise.
MONEY_WORDS = (
    "amount", "total", "price", "cost", "balance", "paid", "due",
    "debit", "credit", "subtotal", "tax", "charge", "fee",
    "salary", "wage", "pay", "value",
)

# The floating-point spellings Postgres accepts. `float(n)` is included
# because `float(24)` IS `real` -- a column that looks precise and is not.
FLOAT_TYPES = re.compile(
    r"^(double\s+precision|real|float\s*(\(\s*\d+\s*\))?|float4|float8)\b",
    re.I,
)

# A column that matches MONEY_WORDS, is genuinely a float, and is not
# money. Each entry is `(migration stem, column)` with a reason.
#
# Empty, and that is the honest state: every money-shaped column in this
# database is numeric today. An entry added here has to say why.
ALLOWED: dict[tuple[str, str], str] = {}

#: A floor under how many MONEY-NAMED columns the sweep must have found.
#:
#: This gate used to pass over an empty `supabase/migrations`, printing
#: "every money column is numeric (0 migrations, 0 allowed floats)". The
#: number was there and nothing compared it -- which is the whole lesson:
#: printing a count is not checking one.
#:
#: The floor is on money-NAMED columns rather than on migrations read,
#: because that is downstream of all three ways this can go quiet: the
#: glob returning nothing, `declarations()` drifting so it extracts no
#: columns, or `is_money_name()` drifting so none of them looks like
#: money. A floor on files would catch only the first.
#:
#: 453 of them over 742 migrations and 5,419 column declarations. Set
#: well below that: it guards against the sweep going blind, not against
#: a column being renamed.
LEAST_MONEY_COLUMNS = int(os.environ.get("IAK_LEAST_SITES", "250"))


def strip_comments(sql: str) -> str:
    """`--` to end of line, and `/* */` spans.

    Without this, a migration that explains in prose why a column is
    *not* a double precision one -- which several of them do -- reads as
    a declaration of exactly the thing it is warning against.
    """
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.S)
    return re.sub(r"--[^\n]*", "", sql)


def is_money_name(column: str) -> bool:
    return any(word in column.lower() for word in MONEY_WORDS)


def declarations(sql: str) -> list[tuple[str, str]]:
    """Every `(column, type)` this file declares.

    Two shapes: the body of a `create table`, and `add column` on an
    `alter table`. A `create table` body is taken to the first line that
    is only `);`, which is how every migration here closes one -- reading
    to the first `)` instead would stop inside `numeric(18, 2)`.
    """
    found: list[tuple[str, str]] = []

    for body in re.findall(
        r"create\s+table\s+(?:if\s+not\s+exists\s+)?[\w.]+\s*\((.*?)\n\s*\)\s*;",
        sql, re.S | re.I,
    ):
        for line in body.split("\n"):
            line = line.strip().rstrip(",")
            # `column type ...`, and nothing that starts with a
            # constraint keyword, which is a table constraint and not a
            # column at all.
            m = re.match(r"^([a-z_][a-z0-9_]*)\s+(.+)$", line, re.I)
            if not m:
                continue
            name, rest = m.group(1), m.group(2)
            if name.lower() in (
                "primary", "unique", "check", "foreign", "constraint",
                "exclude", "like",
            ):
                continue
            found.append((name, rest))

    for name, rest in re.findall(
        r"add\s+column\s+(?:if\s+not\s+exists\s+)?([a-z_][a-z0-9_]*)\s+([^,;\n]+)",
        sql, re.I,
    ):
        found.append((name, rest))

    return found


def offenders() -> tuple[list[str], set[tuple[str, str]], int]:
    problems: list[str] = []
    matched: set[tuple[str, str]] = set()
    money_named = 0

    for path in sorted(MIGRATIONS.glob("*.sql")):
        sql = strip_comments(path.read_text())
        for column, rest in declarations(sql):
            if not is_money_name(column):
                continue
            money_named += 1
            if not FLOAT_TYPES.match(rest.strip()):
                continue
            key = (path.stem, column)
            if key in ALLOWED:
                matched.add(key)
                continue
            problems.append(
                f"  {path.name}: `{column}` is "
                f"{rest.strip().split(' ')[0]}, and its name says it holds "
                f"money. Money is `numeric` here -- a float stores the "
                f"rounding error rather than absorbing it, and `= 0` stops "
                f"matching a balance that is 0.00000000000001."
            )

    return problems, matched, money_named


def main() -> int:
    problems, matched, money_named = offenders()

    if money_named < LEAST_MONEY_COLUMNS:
        print(
            f"This sweep found {money_named} money-named column(s) in "
            f"{MIGRATIONS}, and there were {LEAST_MONEY_COLUMNS} or more "
            f"when it was written. Either the migrations are not being "
            f"read, or `declarations()` or `is_money_name()` no longer "
            f"matches how they are written. A sweep with nothing to look "
            f"at reports exactly what a clean schema reports.",
            file=sys.stderr)
        return 2

    # An allowance that matches nothing is an allowance somebody wrote
    # for a column that has since been renamed or dropped, and leaving it
    # there is how the list becomes a backlog nobody reads. The same rule
    # `check_async_skeletons.py` enforces on its exemptions.
    stale = sorted(set(ALLOWED) - matched)
    for stem, column in stale:
        problems.append(
            f"  ALLOWED names {stem}.{column} and nothing matches it. "
            f"Take it off the list in {pathlib.Path(__file__).name}."
        )

    if problems:
        print("FAIL: a money column is a floating-point type.")
        print("\n".join(problems))
        return 1

    print(
        f"every money column is numeric "
        f"({money_named} money-named columns over "
        f"{len(list(MIGRATIONS.glob('*.sql')))} migrations, "
        f"{len(ALLOWED)} allowed floats)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
