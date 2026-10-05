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
MIGRATIONS = pathlib.Path(__file__).resolve().parent.parent / "supabase" / "migrations"


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


# `\x1e`, the ASCII record separator: a byte that cannot occur in SQL
# source, so the overloads can be split apart again afterwards.
SEP = "\x1e"


def live(name: str) -> list[str]:
    """Every OVERLOAD's source for `name`, one per entry.

    This returned a single string until 5 October, concatenating the
    overloads -- and `public.create_contra` has two: the 5-argument one
    in `0421` and a 6-argument idempotent wrapper in `0734`. The body
    comparison below could therefore never match, and reported

        A LATER migration almost certainly redefines it

    which is wrong and sends the reader hunting a migration that does
    not exist. **Forty-six functions in this schema are overloaded**, so
    the bug was waiting for any of them.

    Applying a mutant was never affected: the `create or replace` comes
    from the migration and carries its own argument list, so it replaces
    the right overload. Only the check was wrong.
    """
    out = subprocess.run(
        ["psql", DB, "-tAc",
         f"select string_agg(prosrc, '{SEP}') from pg_proc "
         f"where proname = '{name}'"],
        capture_output=True, text=True).stdout
    return [part for part in out.split(SEP) if part.strip()]


def latest_defining(name: str) -> pathlib.Path | None:
    """The LAST migration that defines `name`, found case-insensitively.

    A repository fact, and that is the point: the body comparison below
    asks whether the file matches the DATABASE, which silently assumes
    the database is right. Once a previous run has already restored an
    old body, file and database agree and that check goes quiet. This one
    cannot: it reads the migrations.

    Case-insensitively because `0530` writes `CREATE OR REPLACE FUNCTION`
    where `0446` writes it in lower case, so `grep -ln "create or replace
    function app.calc_pcb"` names `0446` as the latest and is wrong.

    `create ... function`, not a bare `function <name>(`. The first
    version matched the bare form and so counted

        comment on function public.post_stock_adjustment(uuid) is ...
        revoke all on function public.post_stock_adjustment(uuid) ...
        grant execute on function public.post_stock_adjustment(uuid) ...

    as definitions. It refused a legitimate run against `0087` and sent
    the operator to `0571`, which only comments on the function and
    holds no body at all -- a FALSE refusal, and a worse failure than
    the one this guard exists to prevent, because the instruction it
    prints is wrong and looks authoritative.
    """
    define = re.compile(
        r"\bcreate\s+(?:or\s+replace\s+)?function\s+[a-z_]*\.?"
        + re.escape(name) + r"\s*\(", re.I)
    found = [p for p in sorted(MIGRATIONS.glob("*.sql"))
             if define.search(p.read_text())]
    return found[-1] if found else None


def body_of(statement: str) -> str:
    """Just the body, between the dollar-quote tags."""
    found = re.search(r"\bas\s+(\$[a-z_]*\$)(.*)\1", statement, re.S | re.I)
    return found.group(2) if found else ""


def squash(text: str) -> str:
    """Whitespace-insensitive, because `prosrc` is not a byte copy."""
    return re.sub(r"\s+", " ", text).strip()


def differing(body: str, got: str) -> list[str]:
    """Lines of the FILE that are not in the live function, for the report.

    A sampling probe is not good enough and that is not a guess: the
    first version of this check took four long lines from the file and
    asked whether the live source contained them. `0446` and `0530`
    differ by ONE number, so all four matched, the check passed, and the
    run went on to downgrade the database a second time.
    """
    live_lines = {l.strip() for l in got.splitlines()}
    out = []
    for line in body.splitlines():
        bare = line.strip()
        if len(bare) > 8 and bare not in live_lines:
            out.append("in the file but not live: " + bare[:68])
    return out or ["the bodies differ but no single line does; "
                   "check whitespace and the dollar-quote tag"]


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    migration, test, spec = sys.argv[1:4]
    if not pathlib.Path(migration).is_file():
        sys.exit(f"HARNESS ERROR: no such migration: {migration}\n"
                 f"  (a mistyped filename used to come back as a raw "
                 f"FileNotFoundError traceback, which reads like the "
                 f"harness is broken rather than the argument)")
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

    # Is the migration you named the one the DATABASE is running?
    #
    # This is not a nicety. The restore at the end of a run re-applies
    # the body from THE FILE YOU NAMED, so naming a superseded migration
    # does not merely report nonsense -- it leaves the local database on
    # an OLDER definition of the function, and every later run of the
    # suite fails for a reason that is in neither the code nor the test.
    #
    # It happened on 5 October. `grep -ln "create or replace function
    # app.calc_pcb"` named `0446` as the latest, because `0530` writes
    # the same statement in a different case and a case-sensitive grep
    # does not see it. So the sweep ran against `0446`, restored `0446`,
    # and left `calc_pcb` paying RM8,000 for a disabled child in higher
    # education where `0530` pays RM14,000. The control was reported
    # KILLED, which is what stopped the run being believed, and the
    # database had to be repaired by hand.
    #
    # The check is one `prosrc` comparison, and the harness already reads
    # `prosrc` to confirm a mutation landed, so this costs nothing.
    named = pathlib.Path(migration).resolve()
    for _, name, *_ in mutants:
        last = latest_defining(name)
        if last and last.resolve() != named:
            print(f"HARNESS ERROR: {name} is last defined in "
                  f"{last.name}, not {named.name}.", file=sys.stderr)
            print("Mutating a SUPERSEDED migration restores its OLD body "
                  "at the end of the run and leaves the database wrong.",
                  file=sys.stderr)
            print(f"  use: {last}", file=sys.stderr)
            return 2

    for _, name, *_ in mutants:
        body = body_of(block(original, name))
        overloads = live(name)
        # ANY overload matching is enough: the migration defines one of
        # them, and the others are wrappers with their own bodies.
        if body and overloads and not any(
                squash(body) == squash(one) for one in overloads):
            print(f"HARNESS ERROR: {name} in the database does not match "
                  f"{migration}.", file=sys.stderr)
            if len(overloads) > 1:
                print(f"  ({len(overloads)} overloads of {name} exist; none "
                      f"of them matches this file)", file=sys.stderr)
            print("A LATER migration almost certainly redefines it, so this "
                  "file is superseded. Find it CASE-INSENSITIVELY:",
                  file=sys.stderr)
            print(f'  grep -lin "function .*{name}" '
                  f'supabase/migrations/*.sql | tail -3', file=sys.stderr)
            print("Running anyway would restore the OLD body and leave the "
                  "database wrong for every later run.", file=sys.stderr)
            closest = max(overloads, key=lambda one: len(
                set(squash(one).split()) & set(squash(body).split())))
            for line in differing(body, closest)[:3]:
                print(f"  {line}", file=sys.stderr)
            return 2

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

        def bail(why: str, _name: str = name, _keep: str = keep) -> None:
            """Put the function back, THEN stop.

            Every exit inside this loop goes through here. On 5 October
            the landed-check below exited directly, after a mutant had
            already been applied -- so `create_contra` was left carrying
            `-- purchases guard dropped` in the live database, under a
            message that began "applied cleanly". The next run's body
            comparison caught it, which is the defence working, but the
            message it printed blamed a later migration and sent the
            reader looking for one that does not exist.

            An error path that leaves the subject broken is the one
            failure this harness exists to prevent, so it may not have
            one.
            """
            back = block(original, _name)
            if _keep:
                back += "\n" + _keep
            psql(back)
            sys.exit(f"HARNESS ERROR: {why}\n"
                     f"  ({_name} was put back before stopping)")

        if old not in source:
            bail(f"{label} -- the anchor is not in {name}")
        applied = psql(source.replace(old, new, 1))
        if applied.returncode != 0:
            # The apply failed, so nothing was replaced -- PostgreSQL
            # refuses a `create or replace` atomically. Restoring anyway
            # costs one statement and removes the need to reason about
            # it.
            bail(f"{label} -- "
                 f"{applied.stderr.strip().splitlines()[0][:120]}")
        # `any(... in one ...)`, not `marker not in live(name)`: since
        # live() began returning one entry per OVERLOAD, a bare `in`
        # tests list MEMBERSHIP -- is the marker equal to a whole body
        # -- which is false for every real marker. That turned the first
        # mutant of an overloaded function into a spurious
        # "applied cleanly and the marker is not in the live function".
        if not any(marker in one for one in live(name)):
            bail(f"{label} -- applied cleanly and the marker {marker!r} "
                 f"is not in the live function")

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
