#!/usr/bin/env python3
"""Assertions for check_embeds.py.

    python3 scripts/check_embeds_test.py

The gate had three holes before this file existed, and every one of them
was found from a browser rather than from here: a `.select(` on the next
line, a string literal split across lines, and a NESTED embed checked
against the `.from()` table instead of its parent. Each time, the gate
reported the app clean while a screen answered PGRST201 on load.

A gate with no test is a gate that reports what it reports. These
assertions break it on purpose -- each of the three holes, from both
sides -- so that the next hole is a failing assertion rather than a
network log.

No database. `scan()` takes the ambiguous pairs and the constraint map
as arguments, which is what makes it testable at all.
"""

from __future__ import annotations

import pathlib
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).parent))

from check_embeds import UNKNOWN, scan, walk_embeds  # noqa: E402

# `gl_lines` and `accounts` are joinable two ways, which is the real
# schema: `gl_lines_account_id_fkey` and the composite
# `gl_lines_account_same_org` that 0160 added. `gl_entries` and
# `accounts` are NOT, which is the whole reason the flat check passed.
PAIRS = {
    frozenset(("gl_lines", "accounts")),
    frozenset(("employees", "departments")),
}

FKS = {
    "gl_lines_entry_id_fkey": {("gl_lines", "gl_entries")},
    "gl_lines_account_id_fkey": {("gl_lines", "accounts")},
    "gl_lines_account_same_org": {("gl_lines", "accounts")},
    "employees_department_id_fkey": {("employees", "departments")},
    "bills_of_materials_item_id_fkey": {("bills_of_materials", "items")},
    "payslip_access_requests_requested_by_fkey": {
        ("payslip_access_requests", "auth.users")
    },
}

failures: list[str] = []


def check(label: str, got, want) -> None:
    if got != want:
        failures.append(f"{label}\n      got:  {got}\n      want: {want}")


def problems_for(dart: str) -> list[str]:
    """Run the scanner over one throwaway Dart file."""
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        (root / "q.dart").write_text(dart)
        return scan(root, PAIRS, FKS)


def count(label: str, dart: str, want: int) -> None:
    found = problems_for(dart)
    if len(found) != want:
        failures.append(
            f"{label}\n      got {len(found)} problem(s), want {want}\n"
            + "".join(f"      | {line}\n" for p in found
                      for line in p.splitlines())
        )


# ---------------------------------------------------------------------
# walk_embeds: the parent of each embed
# ---------------------------------------------------------------------

check(
    "a top-level embed hangs off the .from() table",
    list(walk_embeds("*, accounts(code)", "gl_entries")),
    [("gl_entries", "accounts", "")],
)

check(
    "a NESTED embed hangs off its parent, not the .from()",
    list(walk_embeds("*, gl_lines!fk(*, accounts(code))", "gl_entries")),
    [("gl_entries", "gl_lines", "!fk"), ("gl_lines", "accounts", "")],
)

check(
    "a sibling after a nested one is back at the root",
    # `c` and `e` are COLUMNS, not embeds -- what makes something an
    # embed is the bracket after it, which is the whole basis of the
    # walk. My first version of this assertion expected them as embeds
    # and the walk was right.
    list(walk_embeds("*, a(b(c)), d(e)", "root")),
    [("root", "a", ""), ("a", "b", ""), ("root", "d", "")],
)

check(
    "an embed opening straight after a bracket is still found",
    # No comma before `accounts`. The old regex anchored on one.
    list(walk_embeds("*, gl_lines!fk(accounts(code))", "gl_entries")),
    [("gl_entries", "gl_lines", "!fk"), ("gl_lines", "accounts", "")],
)

check(
    "an embed at the very start of the list is found",
    list(walk_embeds("accounts(code), other", "gl_entries")),
    [("gl_entries", "accounts", "")],
)

check(
    "an alias does not become the table",
    list(walk_embeds("*, head:employees(name)", "departments")),
    [("departments", "employees", "")],
)

check(
    "join-type hints ride along with the constraint",
    list(walk_embeds("*, contacts!contacts_org_fkey!inner(name)", "docs")),
    [("docs", "contacts", "!contacts_org_fkey!inner")],
)

check(
    "children of an interpolated embed have an unknown parent",
    list(walk_embeds(r"*, ${k.lineEmbed}(*, accounts(code))", "docs")),
    [("docs", None, ""), (UNKNOWN, "accounts", "")],
)

check(
    "an unknown .from() makes the root unknown, not the nesting",
    list(walk_embeds("*, gl_lines!fk(*, accounts(code))", None)),
    [(None, "gl_lines", "!fk"), ("gl_lines", "accounts", "")],
)

check(
    "a stray closing bracket does not unwind past the root",
    # Defensive: the walk must not empty its own stack and raise.
    list(walk_embeds(")))*, accounts(code)", "gl_entries")),
    [("gl_entries", "accounts", "")],
)

# ---------------------------------------------------------------------
# scan: what is refused, and what is not
# ---------------------------------------------------------------------

count(
    "THE REPORTED DEFECT: a nested ambiguous embed is refused",
    """
    client.from('gl_entries').select(
        '*, gl_lines!gl_lines_entry_id_fkey(*, accounts(code, name))');
    """,
    1,
)

count(
    "and passes once the constraint is named",
    """
    client.from('gl_entries').select(
        '*, gl_lines!gl_lines_entry_id_fkey('
        '*, accounts!gl_lines_account_id_fkey(code, name))');
    """,
    0,
)

count(
    "the composite constraint is an acceptable name for it too",
    # Either one reaches the same row. The gate's job is to insist that
    # ONE of them is named, not to choose.
    """
    client.from('gl_entries').select(
        '*, gl_lines!gl_lines_entry_id_fkey('
        '*, accounts!gl_lines_account_same_org(code, name))');
    """,
    0,
)

count(
    "a nested embed whose own pair is unambiguous is left alone",
    # The other half of checking the PARENT. `gl_entries` -> `accounts`
    # is joinable one way only, so nesting is not by itself a reason to
    # refuse -- and a gate that refused all nesting would pass the
    # assertion above for the wrong reason.
    "client.from('gl_lines').select('*, gl_entries(*, accounts(code))');",
    0,
)

count(
    "a top-level ambiguous embed is still refused",
    "client.from('employees').select('*, departments(name)');",
    1,
)

count(
    "a named constraint that points elsewhere is still refused",
    # PGRST200 rather than PGRST201, and the second hole this gate grew.
    """
    client.from('payslip_access_requests').select(
        '*, profiles!payslip_access_requests_requested_by_fkey(full_name)');
    """,
    1,
)

count(
    "a constraint that does not exist is refused",
    "client.from('employees').select('*, departments!no_such_fkey(name)');",
    1,
)

count(
    "a select split across string literals is read whole",
    # The hole that let nine ambiguous embeds past: only the FIRST
    # literal was read.
    """
    client.from('gl_entries').select(
      '*, gl_lines!gl_lines_entry_id_fkey(id), '
      'accounts(code, name), '
      'contacts(name)',
    );
    """,
    0,  # gl_entries -> accounts is not ambiguous; this asserts the
        # multi-literal read does not CRASH or double-report.
)

count(
    "a nested embed in a later literal is checked against its parent",
    """
    client.from('bills_of_materials').select(
      '*, items!bills_of_materials_item_id_fkey(code), '
      'gl_lines!gl_lines_entry_id_fkey(*, accounts(code, name))',
    );
    """,
    1,
)

count(
    "a bare nested embed under an unknown .from() is refused",
    "client.from(kind.table).select('*, x!fk(*, accounts(code))');",
    1,
)

count(
    "a bare embed under an interpolated embed is refused",
    r"""
    client.from('docs').select('*, ${kind.lineEmbed}(*, accounts(code))');
    """,
    1,
)

# ---------------------------------------------------------------------

if failures:
    print(f"{len(failures)} assertion(s) failed:\n")
    for f in failures:
        print(f"  * {f}\n")
    sys.exit(1)

print("check_embeds.py: every assertion passed.")
