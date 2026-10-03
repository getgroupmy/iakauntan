#!/usr/bin/env python3
"""Every client-reachable write is accounted for, or the count must not rise.

    python3 scripts/check_write_idempotency.py "$DATABASE_URL"

`0307` gave four money-writing functions an idempotency key.
`docs/mcp-server.md` recorded the position as "4 of 482", which reads as a
478-function backlog and is the wrong denominator three times over. This
gate replaces that number with an enumeration the database is asked to
confirm on every run.

## What it asks

Of the `public` VOLATILE functions `authenticated` may execute, only
those `repository.dart` actually calls can be retried by a client, so
those are the population. Each one is then one of:

  * **key** — it has a `p_idempotency_key` overload. Checked in the
    catalog, not claimed here.
  * **inserts nothing** — neither it nor what it calls contains an
    `insert`, so there is no row for a retry to duplicate. These are the
    `retire_*`, `delete_*`, `mark_*`, `reopen_*`, `set_*` family: a
    second call writes the state the first one wrote.
  * **replaced** — every `insert` in its own body either carries an
    `on conflict`, or inserts `where not exists`, or targets a table the
    same body deletes from first. Checked per INSERT STATEMENT, not per
    function: a body with one guarded insert and one unguarded one is not
    safe, and a flag that looked anywhere in the text would call it safe.
  * **guarded** — its own transitive definition refuses a repeat by name:
    "Adjustment % is already posted", "That contra is already void.".
    This is `0307`'s argument for leaving the `post_*(p_id uuid)` family
    alone — the state is the guard and the record is the natural key.
  * **decided** — a verdict in `VERDICTS` below, each carrying the
    evidence that makes it true, which this gate re-checks.
  * **undecided** — everything else.

## Why a ratchet rather than zero

Because the honest number today is not zero and pretending otherwise
would mean writing 100+ verdicts nobody had read. `BACKLOG` is the
undecided count as measured; the gate fails if it goes UP, and the
number is meant to come down. A new write that inserts something and
refuses nothing cannot arrive quietly.

## The mistake this gate is built to not repeat

The first census of the client's writes was taken with
`grep -oE "callRpc\\(\\s*'([a-z0-9_]+)'"` and found 192 functions. grep
matches within one line, and a quarter of `repository.dart`'s call sites
put the name on the line AFTER `await callRpc(`. The real figure is 577.
So the scan here is deliberately multi-line, and
`check_write_idempotency_test.py` asserts that a call site split across
lines is still found — the assertion that would have caught it.

A second lesson is in `VERDICTS`: `save_payment_method` and
`create_layout_from_builtin` read like duplicate-on-retry defects in
their bodies and are not, because a UNIQUE INDEX refuses the second tap.
Neither index is in its table definition or in `pg_constraint`, so a
verdict of `unique:<index name>` is re-checked against `pg_indexes`
rather than believed.
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
CLIENT = REPO / "app" / "lib" / "src" / "data" / "repository.dart"

# The undecided count as measured. It may fall; it may not rise.
BACKLOG = 99

# Functions whose idempotency has been decided by reading them, with the
# evidence. Three kinds, and each is re-checked:
#
#   unique:<index>  a unique index refuses the second write
#   natural:<why>   repeating it writes the state the first call wrote
#   repeats:<why>   it is MEANT to repeat; a key would be a bug
#
# `natural` and `repeats` are prose and cannot be machine-checked, so
# they are few and each names what was read.
VERDICTS: dict[str, str] = {
    "save_payment_method":
        "unique:payment_methods_name_key",
    "create_layout_from_builtin":
        "unique:report_layouts_name_key",
    "upsert_mia_credential":
        "natural:on conflict (subject_type, subject_id, kind) do update",
    "setup_legal_module":
        "natural:inserts its accounts on conflict do nothing and its client "
        "account where not exists",
    "send_order_to_kitchen":
        "natural:loops over lines where sent_to_kitchen_at is null, so a "
        "second send sends nothing",
    "save_layout_rows":
        "natural:replaces every row of the layout",
    "refresh_pos_sale_promotions":
        "natural:recomputes the sale's promotions from the lines",
    "expire_loyalty_points":
        "natural:expires what is past its date, and a retry finds none left",
    "add_pos_sale_line":
        "repeats:two taps are two lines on the bill, which is the feature",
    "add_line_modifier":
        "repeats:a second helping is a second modifier",
    "add_line_free_modifier":
        "repeats:as add_line_modifier",
    "add_ticket_comment":
        "repeats:somebody saying the same thing twice said it twice",
    "audit_list_payslips":
        "repeats:an access log, and a log that drops a repeated access is "
        "worse than one that records it twice",
    "audit_view_payslip":
        "repeats:as audit_list_payslips",
    "log_document_download":
        "repeats:as audit_list_payslips -- a download log",
    "open_tax_computation":
        "unique:tax_computations_org_id_fiscal_year_id_key",
}

VOLATILE_SQL = """
select p.proname
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.prokind = 'f'
   and p.provolatile = 'v'
   and has_function_privilege('authenticated', p.oid, 'execute')
 group by p.proname
 order by p.proname;
"""

KEYED_SQL = """
select distinct p.proname
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.prokind = 'f'
   and 'p_idempotency_key' = any (p.proargnames);
"""

# Every public and app function's definition, newlines flattened, so one
# query answers "what does this function and the things it calls say".
DEFS_SQL = r"""
select n.nspname || '.' || p.proname || E'\x01'
       || replace(pg_get_functiondef(p.oid), E'\n', ' ')
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname in ('public', 'app')
   and p.prokind = 'f';
"""

INDEXES_SQL = """
select indexname from pg_indexes
 where schemaname = 'public' and indexdef like 'CREATE UNIQUE%';
"""

# "already posted", "already void", "has already been reversed". Only a
# refusal the function RAISES counts, which is why the word is looked for
# beside `raise exception`'s own text rather than anywhere in the body.
GUARD = re.compile(
    r"already\s+(?:been\s+)?(?:posted|paid|recorded|submitted|issued|"
    r"approved|reconciled|closed|used|void|voided|reversed|sent|cancelled|"
    r"canceled|settled|claimed|started|enrolled|lodged|deleted|expired|"
    r"applied|returned|cleared)",
    re.I)

INSERTS = re.compile(r"\binsert\s+into\b", re.I)
INSERT_TARGET = re.compile(r"insert\s+into\s+(?:public\.)?([a-z0-9_]+)", re.I)


def insert_statements(body: str) -> list[tuple[str, str]]:
    """Each `insert into T ...`, as (table, the statement up to its `;`).

    Per statement rather than per function. `chat_create_group` inserts a
    conversation with no guard and then participants `on conflict`, and a
    check that looked for `on conflict` anywhere in the body would call
    the whole function safe while the conversation doubles.
    """
    out = []
    for m in INSERT_TARGET.finditer(body):
        end = body.find(";", m.end())
        out.append((m.group(1), body[m.start(): end if end > 0 else len(body)]))
    return out


def every_insert_is_covered(body: str) -> bool:
    """Whether a second call writes no second row, read from the SQL.

    Three shapes count, and all three are in this schema:
    `on conflict` on the statement, `where not exists` on the statement,
    and a `delete from` the same table earlier in the body -- the
    replace-the-lot shape `set_budget_lines` and `upsert_pos_recipe` use.
    """
    statements = insert_statements(body)
    if not statements:
        # It inserts through something it calls, and this function cannot
        # see which statement that is. Undecided, not safe.
        return False
    for table, statement in statements:
        if re.search(r"on conflict", statement, re.I):
            continue
        if re.search(r"where not exists", statement, re.I):
            continue
        if re.search(r"delete\s+from\s+(?:public\.)?" + re.escape(table) + r"\b",
                     body, re.I):
            continue
        return False
    return True


def psql(db: str, sql: str) -> list[str]:
    out = subprocess.run(["psql", db, "-At", "-c", sql],
                         capture_output=True, text=True, check=True).stdout
    return [line for line in out.splitlines() if line.strip()]


def client_calls(text: str) -> set[str]:
    """Every function named by callRpc or callRpcOnce.

    `re.DOTALL` is not needed but `\\s*` crossing a newline is the whole
    point: `await callRpc(\\n  'email_receipt',` is the shape a line-based
    grep missed, and with it 385 of 577 call sites.
    """
    return set(re.findall(r"callRpc(?:Once)?\(\s*'([a-z0-9_]+)'", text))


def transitive(defs: dict[str, list[str]], name: str) -> str:
    """A function's text plus the text of what it names, one level down."""
    own = defs.get(name, [])
    text = " ".join(own)
    for called in set(re.findall(r"\b(?:app|public)\.([a-z0-9_]+)\s*\(", text)):
        if called != name:
            text += " " + " ".join(defs.get(called, []))
    return text


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.splitlines()[2].strip(), file=sys.stderr)
        return 2
    return run(sys.argv[1])


def run(db: str) -> int:
    """The gate itself, taking the database rather than reading `argv`.

    Separated so `check_write_idempotency_test.py` can swap `psql`,
    `CLIENT` and `BACKLOG` and exercise the classification and the
    ratchet themselves rather than a copy of them. A gate whose test
    reimplements its logic asserts that the copy works.
    """
    volatile = set(psql(db, VOLATILE_SQL))
    keyed = set(psql(db, KEYED_SQL))
    uniques = set(psql(db, INDEXES_SQL))

    defs: dict[str, list[str]] = {}
    for line in psql(db, DEFS_SQL):
        full, _, body = line.partition("\x01")
        defs.setdefault(full.split(".", 1)[1], []).append(body)

    called = client_calls(CLIENT.read_text())
    population = sorted(volatile & called)

    problems: list[str] = []

    # A verdict whose evidence has gone is worse than no verdict.
    for name, verdict in sorted(VERDICTS.items()):
        kind, _, detail = verdict.partition(":")
        if name not in volatile:
            problems.append(
                f"VERDICTS names '{name}', which is not a volatile function "
                f"authenticated may execute. Stale verdicts are how a census "
                f"stops describing the schema.")
            continue
        if kind == "unique" and detail not in uniques:
            problems.append(
                f"'{name}' is excused because the unique index '{detail}' "
                f"refuses the second write, and there is no such index any "
                f"more. Either it was renamed or the protection is gone.")
        if kind not in ("unique", "natural", "repeats"):
            problems.append(
                f"'{name}' has verdict kind '{kind}', which is not one of "
                f"unique, natural, repeats.")

    guarded, decided, inert, replaced, undecided = [], [], [], [], []
    for name in population:
        if name in keyed:
            continue
        text = transitive(defs, name)
        own = " ".join(defs.get(name, []))
        if name in VERDICTS:
            decided.append(name)
        elif not INSERTS.search(text):
            # Nothing to duplicate. The strongest of these categories and
            # the only one that needs no judgement at all.
            inert.append(name)
        elif GUARD.search(text):
            guarded.append(name)
        elif every_insert_is_covered(own):
            replaced.append(name)
        else:
            undecided.append(name)

    protected = sorted(set(population) & keyed)

    if len(undecided) > BACKLOG:
        problems.append(
            f"{len(undecided)} client-reachable writes are undecided, and "
            f"BACKLOG is {BACKLOG}. Something new inserts and refuses "
            f"nothing. Give it a key, a state guard, or a verdict:\n    "
            + "\n    ".join(undecided))

    if problems:
        print("Write idempotency:\n", file=sys.stderr)
        for p in problems:
            print(f"  {p}\n", file=sys.stderr)
        return 1

    print(f"{len(population)} client-reachable writes: {len(protected)} hold "
          f"an idempotency key, {len(inert)} insert nothing, "
          f"{len(replaced)} guard or replace every row they insert, "
          f"{len(guarded)} refuse a repeat by name, {len(decided)} carry a "
          f"verdict, {len(undecided)} undecided (backlog {BACKLOG}).")
    if len(undecided) < BACKLOG:
        print(f"The backlog has fallen to {len(undecided)}. Lower BACKLOG in "
              f"{pathlib.Path(__file__).name} so it cannot drift back up.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
