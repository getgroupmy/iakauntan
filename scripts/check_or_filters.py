#!/usr/bin/env python3
"""Nothing a person typed goes raw into a PostgREST `or(...)`.

    python3 scripts/check_or_filters.py

`or` is not a parameter, it is a little language: commas separate the
branches, dots separate column from operator from value, parentheses
nest. A value interpolated into it is read as syntax.

This was live. A supplier called

    SHAHARUDIN, SHAM SUNDER & PARTNERS

typed into the contact search produced

    PostgrestException(message: "failed to parse logic tree
    ((name.ilike.%SHAHARUDIN, SHAM SUNDER & PARTNERS%, ...", PGRST100)

on somebody's phone, and every Malaysian firm with a comma or an
ampersand in its name was unsearchable. Five call sites had it.

The quieter half is worse. `resolveSupplier` wraps that lookup in a
`catch` and treats a failure as "no supplier found", so the parse error
became a missing-supplier dialog with an empty list of near-misses --
which is exactly how a second contact record for a company already on
file gets created.

`Repo.orValue` double-quotes the value and escapes what has to be
escaped, which is PostgREST's own answer. `Repo.orLike(column, q)`
builds one `ilike` branch with it.

## What is flagged

A `.or('...')` whose string carries a Dart interpolation (`$`) that is
not already going through `Repo.orValue` or `Repo.orLike`. A literal
`or()` over fixed column names and constants is fine and common --
`effective_to.is.null,effective_to.gt.2026-01-01` is not user input.

## What it cannot see

A value that reaches `.eq()`, `.ilike()` or `.contains()` on its own.
Those are sent as separate query parameters and are encoded by
postgrest-dart, so the grammar above does not apply to them. It is only
the logic tree that parses its own argument.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIB = ROOT / "app" / "lib"

# `.or(` followed by anything up to the closing paren of that call. Dart
# string interpolation inside it is what matters.
CALL = re.compile(r"\.or\(\s*(?P<body>.*?)\)\s*[;,)\]]", re.S)


def offenders() -> list[str]:
    bad: list[str] = []
    for path in sorted(LIB.rglob("*.dart")):
        text = path.read_text(encoding="utf-8")
        for m in CALL.finditer(text):
            body = m.group("body")
            if "$" not in body:
                continue  # a literal tree over fixed values
            if "orValue" in body or "orLike" in body:
                continue  # escaped, which is the whole point
            line = text.count("\n", 0, m.start()) + 1
            rel = path.relative_to(ROOT)
            snippet = " ".join(body.split())[:70]
            bad.append(f"  {rel}:{line}: {snippet}")
    return bad


def main() -> int:
    bad = offenders()
    if not bad:
        print("No PostgREST or() filter interpolates an unescaped value.")
        return 0
    print("Values interpolated raw into a PostgREST or() filter:\n")
    print("\n".join(bad))
    print(
        "\n`or` parses its own argument: a comma starts another branch, "
        "a dot is a delimiter, and `&` ends the query string. A name "
        "like `SHAHARUDIN, SHAM SUNDER & PARTNERS` becomes PGRST100.\n"
        "Use `Repo.orLike(column, q)`, or `Repo.orValue(v)` for anything "
        "that is not an ilike. See the header of this script."
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
