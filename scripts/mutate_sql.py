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

## The number of files that CALL a function is not its coverage

`app.run_recurring_journals` is called from FIVE test files, which
looks like the best-covered money mover in the schema. Two of the five
cannot kill a single mutant of it:

  * `scheduled_work.sql` asserts that something SCHEDULES it. It walks
    `cron.job` commands and function source text and never runs the
    function at all.
  * `app_writers_are_not_a_client_surface.sql` asserts that a stranger
    cannot EXECUTE it. The refusal comes from the EXECUTE privilege,
    not from the body, so every mutant raises the same
    `insufficient_privilege`.

Both are good files and neither is about what the function DOES. Zero
of 34 mutants died in `scheduled_work.sql`; measured, not assumed.

So when picking the files to sweep a function against, read what each
one asserts about it, and expect a reachability check or a privilege
check to contribute nothing. The sweep still has to be run against
them -- a file that cannot kill anything is a fact worth having in the
kill sheet -- but a count of callers is not a coverage figure.

## While this runs, it OWNS the database -- do not read the test in
## another window

The harness replaces the live function with a mutant, runs the file,
and puts the original back; between those two moments `pg_proc` holds
code that is deliberately wrong. Anything else connected to the same
cluster is therefore running against a broken function and does not
know it.

That is not a theoretical hazard. On 5 October a sweep of
`app.run_recurring_journals` was still working through its fourth test
file in the background while the same session ran
`recurring_shapes.sql` by hand to check a block it had just written.
The new block passed; a block ABOVE it, untouched for days, failed with

    FAIL the schedule that ran moved on: expected 2026-02-28,
         got 2026-03-31

which is exactly what the mutant "advanced from the run day" does, and
reads like a test this session had just broken. Three more runs gave
three different answers, because each one landed on whichever mutant
was live at that second.

A sweep and a hand-run of the same suite cannot share a cluster. Wait
for `restored:`, or give the second one its own `IAK_PGPORT`.

## Read the column before writing a mutant for a `coalesce`

By 5 October this sweep had proven FIVE equivalent mutants of one
shape, and two of them cost a fixture the database then refused:

    purchase_payments.exchange_rate   NOT NULL DEFAULT 1
    purchase_payments.bank_charges    NOT NULL DEFAULT 0
    withholding_certificates.exchange_rate
                                      NOT NULL DEFAULT 1, check (> 0)
    mo_components.quantity_required   check (quantity_required > 0)
    bank_accounts.account_id          NOT NULL, references accounts

Every one of those sits under a `coalesce(col, x)` or an
`if <lookup> is null then raise`, and every one of those guards is
unreachable: the schema will not hold the row the guard is for. The
guards are belt-and-braces and right to keep -- a later migration that
relaxed the column would make them load-bearing the same day -- but no
fixture can distinguish them, and trying to build one gets a not-null
violation rather than a survivor.

So before writing a mutant that removes a `coalesce` fallback or a
null-check, ask the column:

    select is_nullable, column_default
      from information_schema.columns
     where table_name = '<t>' and column_name = '<c>';
    select pg_get_constraintdef(oid) from pg_constraint
     where conrelid = 'public.<t>'::regclass;

If it is NOT NULL, or a CHECK already excludes the value, write the
mutant anyway -- the kill sheet should record WHY it cannot die -- but
note the equivalence beside it and do not spend a fixture on it. The
same question answers faster than the fixture fails.
"""

from __future__ import annotations

import os
import pathlib
import re
import subprocess
import sys

# The cluster `supabase/tests/run_locally.sh` builds, and the same three
# environment variables it reads -- because the section above tells you
# to give a second run its own `IAK_PGPORT`, and until 5 October this
# line was hardcoded, so that advice could not be followed.
DB = (
    "postgresql://postgres@/postgres"
    f"?host={os.environ.get('IAK_PGSOCK', '/var/tmp')}"
    f"&port={os.environ.get('IAK_PGPORT', '5599')}"
)
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


def settings(name: str) -> dict[str, str]:
    """Each overload's `proconfig` -- its `SET` clauses -- by signature.

    The restore re-runs the function's `create or replace` from its
    defining migration, and `create or replace` REPLACES the SET clauses
    with whatever that statement carries. A setting a LATER migration
    added with `alter function ... set` is therefore lost on restore, and
    nothing the test file checks will notice. That happened on 6 October:
    `app.set_einvoice_cancel_deadline` is defined in `0007` with no
    search_path, `0023` pinned it by `alter function`, and a sweep's
    restore left it unpinned -- found by `search_path.sql`, which no
    sweep of that function runs. Snapshotted before the first mutant and
    re-applied after every restore.
    """
    out = subprocess.run(
        ["psql", DB, "-tAc",
         "select p.oid::regprocedure::text || chr(30) || "
         "coalesce(array_to_string(p.proconfig, chr(31)), '') "
         f"from pg_proc p where p.proname = '{name}'"],
        capture_output=True, text=True).stdout
    return parse_settings(out)


def parse_settings(out: str) -> dict[str, str]:
    """`signature \x1e config` rows, one per line, into a dict.

    `split("\\n")`, not `splitlines()`: splitlines also breaks on \x1e,
    the record separator between the two halves, and gave an empty
    snapshot that re-applied nothing -- the fix for dropped SET clauses
    did nothing at all until mutate_sql_test.py said so.
    """
    found = {}
    for line in out.split("\n"):
        if chr(30) in line:
            sig, conf = line.split(chr(30), 1)
            found[sig] = conf
    return found


def reapply(snapshot: dict[str, str]) -> None:
    """Put back the SET clauses a restore dropped. A no-op when none did."""
    statements = []
    for sig, conf in snapshot.items():
        for item in filter(None, conf.split(chr(31))):
            key, value = item.split("=", 1)
            # search_path is a list and is written bare; anything else is
            # one value and is quoted.
            if key != "search_path":
                value = "'" + value.replace("'", "''") + "'"
            statements.append(f"alter function {sig} set {key} = {value};")
    if statements:
        psql("\n".join(statements))


def arity(statement: str, at: int = 0) -> int:
    """How many IN arguments the `create ... function` at `at` declares.

    Counted at the top level of its parentheses and outside quotes, so a
    `numeric(18, 2)` or a default of `'x, y'` is one argument, and `OUT` arguments
    are left out because they are not part of the signature.
    """
    start = statement.index("(", at)
    depth, i, parts, cur, quoted = 0, start, [], "", False
    while True:
        ch = statement[i]
        if ch == "'":
            # A default of 'x, y' is one argument: commas inside a string
            # are not boundaries ('' inside one toggles twice, harmlessly).
            quoted = not quoted
            cur += ch
        elif quoted:
            cur += ch
        elif ch == "(":
            depth += 1
            if depth > 1:
                cur += ch
        elif ch == ")":
            depth -= 1
            if depth == 0:
                parts.append(cur)
                break
            cur += ch
        elif ch == "," and depth == 1:
            parts.append(cur)
            cur = ""
        elif depth >= 1:
            cur += ch
        i += 1
    return sum(1 for one in parts
               if one.strip() and not re.match(r"\s*out\s", one, re.I))


def latest_defining(name: str, args: int | None = None) -> pathlib.Path | None:
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
    # `args`: only definitions of the SAME overload count. 0737 gave
    # `submit_leave_request` an idempotent 11-argument wrapper, and a
    # name-only guard then refused every sweep of the 10-argument one in
    # 0507 -- the overload that does the work -- and pointed at the
    # wrapper. Two overloads with the same number of arguments are still
    # told apart by nothing, which is the old behaviour and the safe one.
    found = []
    for p in sorted(MIGRATIONS.glob("*.sql")):
        text = p.read_text()
        if any(args is None or arity(text, hit.start()) == args
               for hit in define.finditer(text)):
            found.append(p)
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


def in_string_literal(source: str, at: int) -> bool:
    """Is `source[at]` inside a single-quoted SQL literal?

    Counting quotes does not answer this, and the version that tried
    was wrong in the most ordinary way possible: **an apostrophe in a
    prose comment.** This schema's function bodies are full of them --
    "another company's rows", "the firm's money" -- and each one flips
    the parity of every quote count after it. Five mutants in
    already-measured files were reported as hazardous twice over before
    that was the obvious answer.

    So the source is scanned, skipping what SQL skips: `--` to the end
    of the line, `/* ... */`, and `''` as an escaped quote inside a
    literal rather than the end of one.
    """
    i, n, literal = 0, len(source), False
    while i < at and i < n:
        ch = source[i]
        if literal:
            if ch == "'":
                if source[i + 1:i + 2] == "'":
                    i += 2
                    continue
                literal = False
            i += 1
            continue
        if ch == "'":
            literal = True
            i += 1
            continue
        if source.startswith("--", i):
            j = source.find("\n", i)
            i = n if j < 0 else j + 1
            continue
        if source.startswith("/*", i):
            j = source.find("*/", i)
            i = n if j < 0 else j + 2
            continue
        i += 1
    return literal


def preflight(original: str, mutants: list[tuple]) -> list[str]:
    """Every way a mutant can be malformed, found BEFORE anything runs.

    The HARNESS ERROR guard below is the backstop, and it works -- it
    reports a mutant that did not land and puts the function back. What
    it cannot do is come cheap. It fires one mutant at a time, in the
    middle of a run, and **a HARNESS ERROR aborts the whole file**, so
    the mutants after it go unmeasured. On 5 October a single malformed
    mutant in each half of the POS recipe pair cost ten file-runs: five
    per half, every one of them stopping early and reporting a partial
    kill sheet that looked complete.

    So the same questions are asked up front, about every mutant, and
    all the answers are printed together.

    ## The marker must not swallow the rest of the line

    Both of that day's failures had one shape: the replacement stopped
    in the MIDDLE of a source line and the marker comment was appended
    there, so it commented out whatever followed. In one case that was
    two call arguments and a closing bracket:

        'Recipe consumption ' || v_sale.sale_no, 'pos_sales', p_sale);

    replaced up to `sale_no,` -- "mismatched parentheses at or near ;".
    In the other it was the `order by` of the query above it. Two more
    of the same shape were then found in the same pair by this check,
    before they could cost anything:

        select a.id into v_cogs from public.accounts a

    So: if the character after `old` in the source is not a newline, the
    replacement must not end in a comment.

    ## The brackets must BALANCE, which is not the same as counting them

    The first version of this flagged seven good mutants because it
    compared bracket COUNTS: a mutant that drops a subquery removes an
    open and a close together and is perfectly well formed. What matters
    is whether the two deltas agree.
    """
    problems: list[str] = []
    for label, name, old, new, marker in mutants:
        try:
            source = block(original, name)
        except SystemExit:
            problems.append(f"{label}: names {name}, which is not in this "
                            f"migration -- the pair may live in two")
            continue
        count = source.count(old)
        if count != 1:
            problems.append(f"{label}: its `old` matches {count} times")
            continue
        after = source[source.index(old) + len(old):][:1]
        # Not `re.search('--[^\n]*$', new)`: in Python `$` also matches
        # just before a trailing newline, so a replacement that ENDS
        # `-- marker\n` -- which is the fix for this very problem --
        # was reported as hazardous and the fix looked like it had not
        # taken.
        tail = new.rsplit("\n", 1)[-1]
        # Inside a SQL STRING LITERAL `--` is message text, not a
        # comment, so a boundary there is harmless. Without this the
        # check reported five mutants in already-measured files, four of
        # them splitting a `raise exception '...'` message, as in
        #
        #     raise exception 'No client account configured. Run
        #                      setup_legal_module first.'
        #
        # and sent this session off to re-verify five committed kill
        # sheets that were never in doubt. The first fix counted quotes
        # for parity and was defeated by an APOSTROPHE IN A PROSE
        # COMMENT, of which this schema has hundreds. See
        # `in_string_literal`.
        inside_literal = in_string_literal(
            source, source.index(old) + len(old))
        if (after != "\n" and not new.endswith("\n")
                and "--" in tail and not inside_literal):
            rest = source[source.index(old) + len(old):]
            problems.append(
                f"{label}: the marker would comment out the rest of the "
                f"line -- {rest.split(chr(10))[0]!r}")
        mutated = source.replace(old, new)
        if marker in source:
            problems.append(f"{label}: its marker is in the ORIGINAL, so "
                            f"the landed check cannot fail")
        if marker not in mutated:
            problems.append(f"{label}: its marker is not in the mutant, so "
                            f"the landed check cannot pass")
        opened = mutated.count("(") - source.count("(")
        closed = mutated.count(")") - source.count(")")
        if opened != closed:
            problems.append(f"{label}: brackets unbalanced, "
                            f"{opened:+d} open and {closed:+d} close")
    return problems


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

    # Before the cluster is touched at all. See `preflight` for what a
    # malformed mutant costs when it is found mid-run instead.
    malformed = preflight(original, mutants)
    if malformed:
        print(f"HARNESS ERROR: {len(malformed)} malformed mutant(s), and "
              f"nothing has been run:", file=sys.stderr)
        for one in malformed:
            print(f"  {one}", file=sys.stderr)
        return 2

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
        last = latest_defining(name, arity(block(original, name)))
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
    snapshots = {}
    for _, one, *_rest in mutants:
        snapshots.setdefault(one, settings(one))
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
            reapply(snapshots[_name])
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
        reapply(snapshots[name])

    after = run(test)
    if after is None:
        drifted = [one for one, snap in snapshots.items()
                   if settings(one) != snap]
        if drifted:
            after = ("a function's SET clauses differ from before the run: "
                     + ", ".join(drifted))
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
