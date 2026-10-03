#!/usr/bin/env python3
"""An overload is invisible to the gates and NOT to `pg_proc` by name.

Three assertion files have now been broken by an idempotency-key
overload, one tranche at a time, each found by a red suite rather than
before the push:

  * `outbound_email.sql` -- "there is exactly one email_document";
  * `ai_assistant.sql` -- a SCALAR subquery over `proname`, which started
    raising "more than one row returned by a subquery used as an
    expression" the moment `report_feedback` had two forms;
  * `leave_requests.sql` -- "there is one submit_leave_request, not two",
    which `0395` wrote on purpose and `0737` broke.

All three read `pg_proc` by NAME. There is nothing wrong with that --
`leave_requests.sql` was protecting against an ambiguous call, which is
a real hazard -- but a name is not a function, and a wrapper added later
is a second row under the same name.

This gate crosses the two lists. Every function that HAS a keyed
overload and IS asserted by bare name somewhere in `supabase/tests/`
must be named in REVIEWED below, which is a statement that the
assertion was read and made two-form aware. A fourth one fails here,
with the file and the name, instead of in a twenty-minute CI run.

It does NOT try to parse the assertion. A gate that guessed whether
`count(*) = 1` was the intent would be wrong about
`and 'p_idempotency_key' = any (proargnames)`, which is a by-name
assertion that SHOULD say 1. Reading it is the person's job; noticing
that it needs reading is this gate's.

    python3 scripts/check_overload_assertions.py "$DB"
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TESTS = ROOT / "supabase" / "tests"

# Each of these is asserted by name AND has a keyed overload, and the
# assertion has been read and rewritten to expect both forms.
REVIEWED: dict[str, str] = {
    "email_document":
        "outbound_email.sql asserts two forms and that one takes the key",
    "report_feedback":
        "ai_assistant.sql uses bool_and over every form, not a scalar "
        "subquery",
    "submit_leave_request":
        "leave_requests.sql asserts two forms, that one takes the key, and "
        "that the keyed one has no defaults -- which is what 0395 was "
        "really protecting",
}

KEYED_SQL = """
select distinct p.proname
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and pg_get_function_identity_arguments(p.oid) like '%p_idempotency_key%'
 order by 1;
"""

BY_NAME = re.compile(r"proname\s*=\s*'([a-z0-9_]+)'")


def keyed(db: str) -> set[str]:
    out = subprocess.run(["psql", db, "-At", "-c", KEYED_SQL],
                         capture_output=True, text=True, check=True)
    return {line for line in out.stdout.split("\n") if line}


def asserted_by_name(tests: pathlib.Path = TESTS) -> dict[str, list[str]]:
    """Every `proname = '...'` in the assertion files, by function."""
    found: dict[str, list[str]] = {}
    for path in sorted(tests.glob("*.sql")):
        text = path.read_text()
        for name in set(BY_NAME.findall(text)):
            found.setdefault(name, []).append(path.name)
    return found


def run(db: str, tests: pathlib.Path = TESTS,
        reviewed: dict[str, str] | None = None) -> int:
    reviewed = REVIEWED if reviewed is None else reviewed
    by_name = asserted_by_name(tests)
    overlap = sorted(keyed(db) & set(by_name))

    problems = []
    for name in overlap:
        if name not in reviewed:
            problems.append(
                "%s has an idempotency-key overload and is asserted by name "
                "in %s. Read that assertion: a count or a scalar subquery "
                "over proname sees TWO rows now. Then name it in REVIEWED "
                "in %s." % (name, ", ".join(sorted(by_name[name])),
                            pathlib.Path(__file__).name))

    # A reviewed name that is no longer either is an excuse left behind.
    for name in sorted(reviewed):
        if name not in overlap:
            problems.append(
                "%s is in REVIEWED but is no longer both keyed and asserted "
                "by name. Drop the entry." % name)

    if problems:
        print("Overload assertions:\n", file=sys.stderr)
        for problem in problems:
            print("  %s\n" % problem, file=sys.stderr)
        return 1

    print("%d function(s) are asserted by name and carry a keyed overload; "
          "every one of those assertions has been made two-form aware."
          % len(overlap))
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: check_overload_assertions.py <database-url>",
              file=sys.stderr)
        return 2
    return run(sys.argv[1])


if __name__ == "__main__":
    raise SystemExit(main())
