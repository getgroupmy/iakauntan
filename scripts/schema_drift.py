"""Does the hosted project's schema match the one these migrations build?

    python3 scripts/schema_drift.py LOCAL.sql HOSTED.sql
    python3 scripts/schema_drift.py --self-test

CI already proves the *migrations* are good: every run builds a throwaway
stack from them and runs the whole assertion suite against it. What
nothing proved until now is that the hosted project matches those files.

The two can part company. A migration applied by hand — typed into a SQL
console rather than pushed from the file — records itself as applied,
and `supabase db push` skips it forever afterwards. Whatever the console
actually ran is what production has, and the file is only what everyone
reads. That is not hypothetical here: migrations 0159 to 0173 were
applied exactly that way, and at least one of them was corrected in the
file *after* it had already run on the hosted project.

So: dump both, and compare.

## Why a plain `diff` will not do

Two `pg_dump` outputs of the same logical schema differ constantly for
reasons that are not drift, and a check that is red every morning is a
check that gets ignored by lunchtime. This normalises away four
categories, and each exclusion is a decision worth being able to defend:

  * **Comments, blank lines and `SET`/`SELECT set_config` preamble.**
    Session furniture. Says nothing about the schema.

  * **`ALTER ... OWNER TO`.** The hosted project's objects belong to
    `postgres`; the local stack's belong to whoever the CLI ran as.
    Never meaningful, always different.

  * **`GRANT`, `REVOKE` and `ALTER DEFAULT PRIVILEGES`.** The one
    exclusion that costs something, so
    it is the one worth explaining. Supabase's hosted projects ship
    `alter default privileges ... grant all ... to anon, authenticated`,
    which a stack built from these migrations alone does not have — so
    the hosted dump carries grant lines on essentially every object and
    the local one does not. Including them would drown the signal
    entirely. The property that actually matters — that every policy has
    the table privilege it needs to run — is asserted directly, against
    the built-from-migrations stack, by `supabase/tests/table_grants.sql`.
    That test is what caught `0168` handing the API write policies on the
    depreciation tables; it is a better instrument for grants than a diff
    would be.

    `ALTER DEFAULT PRIVILEGES` belongs with them and was missed on the
    first pass — it does not begin with the word `GRANT`, so the anchor
    let it through and the first live run opened with seventeen findings
    that were all Supabase's own defaults.

  * **Statement order.** `pg_dump` emits in dependency order, and two
    databases whose objects were created in a different sequence get
    different orderings of identical DDL. What is being asked here is
    whether the two schemas contain the same set of statements, not
    whether they were built in the same order, so they are compared as
    multisets and the leftovers on each side are what gets reported.

Everything else — tables, columns, types, defaults, constraints,
indexes, functions, triggers, policies, enums, views — is compared.

## Two tiers, and why

A first version of this compared statements verbatim and would have
opened with thirty-five findings against this repository, every one of
them a comment.

That number is measured, not guessed. All 47 functions that migrations
0159 to 0173 define were compared against the hosted project: 35 differed
textually, and **none differed in behaviour**. The explanation is dull
and will recur — applying a migration by hand means pasting it into a
console, and the explanatory comments get dropped on the way. Formatting
drifts for the same reason, and SQL's adjacent-string-literal
continuation (`'a ' 'b'` across two lines is one string) means the same
text can be written two ways.

So each statement gets two identities:

  * its **code** — comments removed, string continuation resolved,
    whitespace discarded. Two statements with the same code do the same
    thing.
  * its **text** — what was actually stored.

A difference in code is drift and fails. A difference in text alone is
reported as a count and does not, because a check that fails on a
missing comment is a check that gets switched off in a fortnight.
"""

from __future__ import annotations

import pathlib
import re
import sys

# Statements dropped before comparing. Anchored at the start so a table
# called `grants` or a function body mentioning `set` is not caught by
# accident.
_IGNORED = re.compile(
    r"""^(
        SET\s
      | SELECT\s+pg_catalog\.set_config
      | ALTER\s+.*\sOWNER\s+TO\s
      | ALTER\s+DEFAULT\s+PRIVILEGES\s
      | GRANT\s
      | REVOKE\s
      | COMMENT\s+ON\s+EXTENSION\s
      | CREATE\s+EXTENSION\s
    )""",
    re.IGNORECASE | re.VERBOSE,
)


def statements(sql: str) -> list[str]:
    """The dump as a list of statements, newlines intact.

    Deliberately not a SQL parser. `pg_dump` output is machine-written
    and regular: statements end with `;` at the end of a line, and the
    only place a stray `;` appears mid-statement is inside a
    dollar-quoted function body, which is why those are tracked.

    **The newlines are load-bearing and must not be collapsed here.** An
    earlier version joined each statement onto one line before anything
    else looked at it, which turned every `--` inside a function body
    into a comment running to the end of the statement — so `code()`
    discarded the entire body after the first comment. Both sides were
    truncated the same way, so they agreed, and a detector that agrees
    about nothing reports no drift. Its own self-test caught it.
    """
    out: list[str] = []
    buf: list[str] = []
    dollar_tag: str | None = None

    for raw in sql.splitlines():
        line = raw.rstrip()

        # Comments and blank lines, but only outside a function body —
        # a `--` inside one is part of the code being compared, and
        # dropping it would hide a real difference.
        if dollar_tag is None:
            if not line.strip() or line.lstrip().startswith("--"):
                continue

        buf.append(line)

        # Dollar quoting. `$$`, `$fn$`, `$_$` all appear in these dumps.
        for tag in re.findall(r"\$[A-Za-z_0-9]*\$", line):
            if dollar_tag is None:
                dollar_tag = tag
            elif tag == dollar_tag:
                dollar_tag = None

        if dollar_tag is None and line.endswith(";"):
            statement = "\n".join(buf)
            buf = []
            if not _IGNORED.match(statement.lstrip()):
                out.append(statement)

    # A dump that ends mid-statement is a truncated dump, and comparing
    # it would report the truncation as drift. Better to say so.
    if buf:
        raise ValueError(
            "the dump ends in the middle of a statement — it is truncated:\n"
            + oneline("\n".join(buf), 200)
        )
    return out


def oneline(statement: str, limit: int = 400) -> str:
    """For printing only. Never fed back into a comparison."""
    return " ".join(statement.split())[:limit]


def code(statement: str) -> str:
    """What a statement *does*, with everything cosmetic removed.

    Comments go, then SQL's adjacent-literal continuation is resolved so
    that `'a ' 'b'` split over two lines matches the same string written
    once, then whitespace goes entirely. Two statements sharing this have
    the same effect on the database.
    """
    s = re.sub(r"--[^\n]*", "", statement)
    s = re.sub(r"'\s+'", "", s)
    return re.sub(r"\s", "", s)


def compare(
    local: str, hosted: str
) -> tuple[list[str], list[str], list[tuple[str, str]]]:
    """Returns (only in the migrations, only on the hosted project, cosmetic).

    Matched on `code`, so a statement that differs only in its comments
    or its line breaks lands in the third list and not the first two.
    """
    a = statements(local)
    b = statements(hosted)

    by_code: dict[str, list[str]] = {}
    for s in b:
        by_code.setdefault(code(s), []).append(s)

    only_local: list[str] = []
    cosmetic: list[tuple[str, str]] = []
    for s in a:
        bucket = by_code.get(code(s))
        if bucket:
            counterpart = bucket.pop(0)
            if counterpart != s:
                cosmetic.append((s, counterpart))
        else:
            only_local.append(s)

    only_hosted = [s for bucket in by_code.values() for s in bucket]
    return sorted(only_local), sorted(only_hosted), cosmetic


def _self_test() -> None:
    """The normaliser's own positive control.

    A filter this aggressive can silently drop everything and report a
    clean comparison, which looks exactly like agreement. So: the things
    it must ignore, and — the half that matters — a real difference it
    must still catch.
    """
    noise = """
--
-- Name: whatever; Type: SCHEMA
--
SET statement_timeout = 0;
SELECT pg_catalog.set_config('search_path', '', false);
ALTER TABLE public.invoices OWNER TO postgres;
GRANT SELECT ON TABLE public.invoices TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
REVOKE ALL ON FUNCTION public.f() FROM PUBLIC;

CREATE TABLE public.invoices (
    id uuid NOT NULL,
    total numeric(18,2) DEFAULT 0
);
"""
    hosted_same_facts_different_furniture = """
SET default_tablespace = '';
CREATE TABLE public.invoices (
    id uuid NOT NULL,
    total numeric(18,2) DEFAULT 0
);
ALTER TABLE public.invoices OWNER TO supabase_admin;
"""
    only_local, only_hosted, _ = compare(
        noise, hosted_same_facts_different_furniture)
    assert not only_local and not only_hosted, (only_local, only_hosted)

    # One statement, and it is not noise: the table has to survive the
    # filter, or the assertion above passes by comparing nothing.
    assert len(statements(noise)) == 1, statements(noise)
    assert oneline(statements(noise)[0]) == (
        "CREATE TABLE public.invoices ( id uuid NOT NULL, "
        "total numeric(18,2) DEFAULT 0 );"
    ), oneline(statements(noise)[0])

    # A real difference, of the kind this exists to find: a function body
    # that was corrected in the file after it ran on the hosted project.
    a = """
CREATE FUNCTION public.f() RETURNS integer LANGUAGE plpgsql AS $$
begin
  -- the fixed version
  return 2;
end $$;
"""
    b = a.replace("return 2;", "return 1;")
    only_local, only_hosted, _ = compare(a, b)
    assert len(only_local) == 1 and len(only_hosted) == 1, (only_local, only_hosted)
    assert "return 2;" in only_local[0]
    assert "return 1;" in only_hosted[0]

    # And the difference this must *not* fail on, because it is the one
    # that actually occurs: the hosted copy was pasted into a console
    # without the comment. Same code, different text.
    c = a.replace("  -- the fixed version\n", "")
    only_local, only_hosted, cosmetic = compare(a, c)
    assert not only_local and not only_hosted, (only_local, only_hosted)
    assert len(cosmetic) == 1, cosmetic

    # Nor on SQL's adjacent-literal continuation, which is one string
    # written two ways.
    one = "CREATE FUNCTION f() RETURNS text AS $$ select 'ab cd'; $$;\n"
    two = "CREATE FUNCTION f() RETURNS text AS $$ select 'ab '\n'cd'; $$;\n"
    only_local, only_hosted, cosmetic = compare(one, two)
    assert not only_local and not only_hosted, (only_local, only_hosted)
    assert len(cosmetic) == 1, cosmetic

    # Ordering is not drift.
    x = "CREATE TABLE a (i int);\nCREATE TABLE b (i int);\n"
    y = "CREATE TABLE b (i int);\nCREATE TABLE a (i int);\n"
    assert compare(x, y) == ([], [], [])

    # A truncated dump is reported, not silently compared.
    try:
        statements("CREATE TABLE a (\n  i int\n")
    except ValueError:
        pass
    else:
        raise AssertionError("a truncated dump compared clean")

    print("schema_drift self-test passed")


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[1] == "--self-test":
        _self_test()
        return 0
    if len(argv) != 3:
        print(__doc__)
        return 2

    local = pathlib.Path(argv[1]).read_text()
    hosted = pathlib.Path(argv[2]).read_text()
    only_local, only_hosted, cosmetic = compare(local, hosted)

    total = len(statements(local))
    note = ""
    if cosmetic:
        # Worth saying out loud rather than hiding: these are objects the
        # hosted project got from somewhere other than the file, and the
        # only reason they are not a failure is that what they do is
        # identical. A number climbing here means more is being applied
        # by hand.
        note = (f"\n{len(cosmetic)} statement(s) differ in comments or "
                f"formatting only — same code, so not drift. The first:\n"
                f"    migrations: {oneline(cosmetic[0][0], 200)}\n"
                f"    hosted:     {oneline(cosmetic[0][1], 200)}")

    if not only_local and not only_hosted:
        print(f"No drift: {total} statements, and the hosted project has "
              f"every one of them.{note}")
        return 0
    if note:
        print(note.strip())
        print()

    print("SCHEMA DRIFT — the hosted project does not match these migrations.")
    print()
    print("This is not something `supabase db push` will fix: every")
    print("migration below is already recorded as applied, so a push skips")
    print("it. Reconcile with a new migration.")
    print()
    if only_local:
        print(f"In the migrations, missing from the hosted project "
              f"({len(only_local)}):")
        for s in only_local:
            print(f"  - {oneline(s)}")
        print()
    if only_hosted:
        print(f"On the hosted project, not in the migrations "
              f"({len(only_hosted)}):")
        for s in only_hosted:
            print(f"  + {oneline(s)}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
