#!/usr/bin/env python3
"""Break a SQL function on purpose and see whether the test notices.

    python3 scripts/mutate_sql.py <migration.sql> <test.sql> <mutants.py>

`scripts/mutate.py` does this for Dart. This is the same idea for the
half of the product that matters most -- CLAUDE.md's first rule is that
the database IS the application, and `supabase/tests/*.sql` is where its
behaviour is asserted. A SQL test that passes proves the file ran.

`mutants.py` is a list of calls:

    m("an inactive rule still fires",
      "bank_rule_matches",
      "  select p_rule.is_active\\n     and (p_rule.bank_account_id is null",
      "  select true\\n     and (p_rule.bank_account_id is null",
      "select true")

  label    what was broken, for the report
  function the function to mutate, by bare name
  old/new  an exact string replacement inside that function's block
  marker   a string that appears in the MUTATED source and NOT in the
           original -- see "the landed check" below

## Why it applies one function rather than re-running the migration

The obvious harness edits the migration and re-applies the file. That
does not work on a migration that CREATES anything: `create table`
raises "already exists" on the second run, psql stops there, and every
function below it keeps its original body. The test then passes and the
sweep reports a clean kill sheet about code that was never changed.

That happened here, on the first run of the sweep this script came out
of. So this extracts exactly the one `create or replace function`
block, applies THAT, and then reads the function back out of `pg_proc`
to confirm the mutation is really in the database before running
anything. A mutation that did not land is reported as a HARNESS ERROR
rather than as a survivor.

## The landed check needs a marker

Checking that the first line of the replacement appears in the live
source is not a check: for a mutant that changes `limit 1` to `limit
10`, the line above it is unchanged and the test passes whether or not
anything happened. Hence an explicit `marker` that exists only in the
mutated form.

## A dead test is a killed mutant

A mutation that makes the file ERROR -- a scalar subquery that suddenly
returns two rows, a type that stopped matching -- has been caught just
as surely as one that trips an assertion. Grepping only for the word
`FAIL` scored one of those as a survivor twice before this was written.
So both `FAIL` and `ERROR:` count.

An error is a weaker kill than an assertion, though: it says the test
noticed, not that it knows why. Where one shows up, consider asking the
same question as an assertion instead -- `check_eq` on a count reads as
an expectation, `more than one row returned by a subquery` reads as a
crash.

## Always include a control

Its description must BEGIN with `CONTROL`, and it must be a change that
CANNOT alter behaviour -- a comment inside the function block, not one
in the migration's header, because only the block is applied. If the
control is reported killed, the harness is broken and every other line
of the output is worthless.
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

DB = "postgresql://postgres@/postgres?host=/var/tmp&port=5599"


def block(src: str, name: str) -> str:
    """The one `create or replace function` statement, header to its end.

    The body's dollar-quote tag is whatever the file used, not always
    `$$`. A function restated from `pg_get_functiondef` comes back
    quoted `$function$`, which is how 0504, 0538 and 0636 are written --
    and a harness that only knew `$$` reported those as "no such
    function in the migration", which reads like the name is wrong.

    `\\s*;` because the same restatements put the statement's semicolon
    on a line of its own after the closing tag.
    """
    found = re.search(
        r"create or replace function [a-z_]*\.?" + re.escape(name)
        + r"\(.*?\bas\s+(\$[a-z_]*\$).*?\1\s*;", src, re.S | re.I)
    if not found:
        sys.exit(f"HARNESS ERROR: no `create or replace function {name}` "
                 f"in the migration")
    return found.group(0)


def grants(src: str, name: str) -> str:
    """The migration's own `grant ... on function <name>` statements.

    Replacing a function does not always keep its privileges here. On
    `open_shared_document`, `proacl` reads
    `{postgres=X/postgres,authenticated=X/postgres}` the moment the
    function is restated -- `anon` is gone -- which is why `0413` and
    `0642` both re-grant on the line after the restatement.

    A harness that applies the BLOCK ALONE therefore takes that
    privilege away for the whole sweep. `document_share.sql` asserts it,
    so every mutant was reported killed and so was the control: a sweep
    whose output says nothing, and it only says so because there was a
    control. Then `restored:` failed too, because putting the original
    block back does not put the grant back either -- so the harness left
    the database with a share link that no longer opens for the
    customer it was emailed to.

    So the grants ride along with the block, both ways.
    """
    found = re.findall(
        r"^grant\s+execute\s+on\s+function\s+[a-z_]*\.?"
        + re.escape(name) + r"\s*\([^)]*\)\s+to\s+[^;]+;",
        src, re.M | re.I)
    return "\n".join(found)


def psql(sql: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["psql", DB, "-q", "-v", "ON_ERROR_STOP=1", "-c", sql],
        capture_output=True, text=True)


def run(test: str) -> str | None:
    out = subprocess.run(["psql", DB, "-v", "ON_ERROR_STOP=1", "-f", test],
                         capture_output=True, text=True)
    lines = (out.stdout + out.stderr).splitlines()
    bad = [line for line in lines if "FAIL" in line or "ERROR:" in line]
    if not bad:
        return None
    first = bad[0]
    return (first.split("FAIL ", 1)[-1] if "FAIL" in first
            else first.split("ERROR:", 1)[-1].strip())[:70]


def live(name: str) -> str:
    return subprocess.run(
        ["psql", DB, "-tAc",
         f"select prosrc from pg_proc where proname = '{name}'"],
        capture_output=True, text=True).stdout


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    migration, test, spec = sys.argv[1:4]
    original = pathlib.Path(migration).read_text()

    mutants: list[tuple] = []
    exec(compile(pathlib.Path(spec).read_text(), spec, "exec"),
         {"m": lambda *a: mutants.append(a)})
    if not mutants:
        sys.exit("HARNESS ERROR: no mutants")
    if not mutants[-1][0].startswith("CONTROL"):
        sys.exit("HARNESS ERROR: the last mutant must be the CONTROL")

    carried = {name: grants(original, name)
               for _, name, *_ in mutants}
    for name, keep in carried.items():
        if keep:
            print(f"carrying {len(keep.splitlines())} grant(s) on {name}, "
                  f"which a replace does not keep")

    before = run(test)
    print(f"baseline: {'passed' if before is None else 'FAILED ' + before}")
    if before is not None:
        sys.exit("the test does not pass before anything is broken")

    survivors, control_died = [], False
    for label, name, old, new, marker in mutants:
        source = block(original, name)
        keep = grants(original, name)
        if keep:
            source += "\n" + keep
        if old not in source:
            sys.exit(f"HARNESS ERROR: {label} -- the anchor is not in {name}")
        applied = psql(source.replace(old, new, 1))
        if applied.returncode != 0:
            sys.exit(f"HARNESS ERROR: {label} -- "
                     f"{applied.stderr.strip().splitlines()[0][:120]}")
        if marker not in live(name):
            sys.exit(f"HARNESS ERROR: {label} -- applied cleanly and the "
                     f"marker {marker!r} is not in the live function")

        verdict = run(test)
        print(f"{'killed  ' if verdict else 'SURVIVED'}  {label}"
              f"{'  -- ' + verdict if verdict else ''}")
        if verdict is None:
            if label.startswith("CONTROL"):
                pass
            else:
                survivors.append(label)
        elif label.startswith("CONTROL"):
            control_died = True
        restore = block(original, name)
        if keep:
            restore += "\n" + keep
        psql(restore)

    after = run(test)
    print(f"restored: {'passed' if after is None else 'FAILED ' + after}")

    if control_died:
        print("\nTHE CONTROL WAS KILLED. The harness is broken and nothing "
              "above means anything.")
        return 1
    if survivors:
        print(f"\n{len(survivors)} survived. Each is a missing assertion or "
              f"an equivalent mutant; say which, in the test file, next to "
              f"the assertion it belongs to.")
        return 1
    print("\nevery mutant killed, control survived.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
