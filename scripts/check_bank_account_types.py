#!/usr/bin/env python3
"""The kinds of bank account the app offers are the kinds the database takes.

    python3 scripts/check_bank_account_types.py "$DATABASE_URL"

`bank_accounts.account_type` is guarded by a CHECK constraint.
`bankAccountTypes` in `app/lib/src/features/banking/new_bank_account_dialog.dart`
is what the Kind dropdown offers. They have to be the same set, and a
mismatch is silent in both directions:

  * **Offered and not permitted** is a save that fails. `fixed_deposit`
    sat on that dropdown from the day it was written and appears in no
    migration, so the one person who picked it got a constraint
    violation and no explanation of which field caused it.

  * **Permitted and not offered** is a feature nobody can reach.
    `cash` and `ewallet` were accepted by the database from the
    beginning and were on no dropdown, so paying a supplier out of
    petty cash was impossible through the product while being
    perfectly possible in the schema. It was reported as "no bank
    accounts to select from", which is what it looks like from the
    outside.

Neither direction produces an error anybody can act on, which is why
this is a gate rather than a comment.
"""
import re
import subprocess
import sys
from pathlib import Path

DART = Path("app/lib/src/features/banking/new_bank_account_dialog.dart")


def permitted(db_url: str) -> set[str]:
    """The values the CHECK constraint allows, read from the catalog.

    Read rather than restated: a list written here would be a third
    copy to keep in step, and this gate exists because two were already
    one too many.
    """
    out = subprocess.run(
        [
            "psql", db_url, "-t", "-A", "-c",
            "select pg_get_constraintdef(oid) from pg_constraint "
            "where conname = 'bank_accounts_account_type_check';",
        ],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    if not out:
        sys.exit("no CHECK constraint on bank_accounts.account_type — "
                 "either it was dropped or this gate is looking for the "
                 "wrong name")
    return set(re.findall(r"'([a-z_]+)'::text", out))


def offered() -> set[str]:
    """The keys of the Dart map, which is what the dropdown iterates."""
    source = DART.read_text()
    block = re.search(
        r"const bankAccountTypes = <String, String>\{(.*?)\};",
        source, re.S,
    )
    if not block:
        sys.exit(f"{DART}: bankAccountTypes is not where this gate looks "
                 "for it. If it moved, move this too.")
    return set(re.findall(r"'([a-z_]+)'\s*:", block.group(1)))


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit("usage: check_bank_account_types.py <database url>")

    db = permitted(sys.argv[1])
    ui = offered()

    problems = []
    for value in sorted(ui - db):
        problems.append(
            f"  the dialog offers '{value}' and the database refuses it — "
            "choosing it fails on save"
        )
    for value in sorted(db - ui):
        problems.append(
            f"  the database takes '{value}' and the dialog never offers "
            "it — nobody can create one"
        )

    if problems:
        print("bank account kinds disagree:")
        print("\n".join(problems))
        print(f"\n  database: {', '.join(sorted(db))}")
        print(f"  dialog:   {', '.join(sorted(ui))}")
        sys.exit(1)

    print(f"the dialog offers every account kind the database takes "
          f"({len(db)}): {', '.join(sorted(db))}")


if __name__ == "__main__":
    main()
