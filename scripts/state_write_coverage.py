#!/usr/bin/env python3
"""Which columns a money mover WRITES that no test file ever names.

    DATABASE_URL=... python3 scripts/state_write_coverage.py
    DATABASE_URL=... python3 scripts/state_write_coverage.py record_pdc

This is a SURVEY, not a gate: it exits 0 whatever it finds, and it is
run by hand to decide where the next mutation sweep should look. It is
in `scripts/` rather than in the gate list on purpose -- what it
reports is a strong hint and not a defect, and CLAUDE.md's rule is that
a gate which flags correct code is a gate somebody turns off.

## Why it exists

Two mutation sweeps on 5 October produced the same finding four hours
apart, and the second one said it in one sentence:

  * `clear_pdc` -- "a balance is one number, and it is the same number
    whether the cheque remembers what settled it, through which account,
    or on what day". NINE of 26 mutants died on its own dedicated file.
    `set status = 'cleared'` survived the whole of it.
  * `run_recurring_journals_for` -- ALL THIRTEEN survivors were inside
    the loop. The run's return value and the posted journal were
    asserted; the three columns the loop writes on its way out --
    `last_run_date`, `next_run_date`, `last_error` -- were not.

**A file that watches the money does not watch the state.** A posting
function's journal is what its test file is about, so the journal gets
asserted and the row the function stamps afterwards does not -- and a
stamp is invisible to every balance check there is.

So: pull each function's `update ... set <col> = ...` targets out of
`pg_proc`, and report the ones whose NAME appears in no test file that
calls the function. A column nobody names cannot be asserted.

## What a finding means, and what it does not

A reported column is a column no test file mentions by name. That is
suggestive and not conclusive, in both directions:

  * A column can be asserted without being named -- through a view, a
    report function, or `select *` into a record. `received_by` was
    reported here and `stock_transfers.sql` did assert it, through
    `(select received_by from ...)` -- which names it, so that one was
    a true finding; but `report_matter_ledger` reading `matter_id`
    would not be.
  * A column can be named without being asserted. `status` appears in
    nearly every file.

**Its measured precision, since a tool nobody can calibrate is a tool
nobody should believe.** On the first full run it reported 25 columns
across 16 functions. Checked against the mutation sweeps already done:

  * `bounce_pdc`'s `bounce_entry_id`/`bounced_on`, `send_stock_transfer`'s
    `sent_at`/`sent_by`, `post_stock_adjustment`'s `posted_at` and the
    `posted_at`/`posted_by` pairs -- genuinely unasserted, and the kind
    of thing the sweeps kept finding.
  * `dispose_fixed_asset`'s `disposal_date` and `disposal_entry_id` --
    FALSE. Both mutants die: `depreciation_schedule.sql` and
    `asset_disposal_shapes.sql` catch them through a report function and
    a journal description, without naming either column.

So read a finding as "point a sweep here", never as "this is
unasserted". The second kind is why this is not a gate: it would fail
CI over code that is covered.

## The function list

Taken from `scripts/mutation_targets.py` so the two tools cannot
disagree about what moves money.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TESTS = ROOT / "supabase" / "tests"

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mutation_targets as mt  # noqa: E402

# Columns every table has and every file mentions. Reporting them is
# noise: they are maintained by `app.set_updated_at` and nobody asserts
# a timestamp nobody chose.
BORING = {"updated_at", "created_at", "updated_by", "created_by"}

# `update <table> [alias] set <assignments>` up to the clause that ends
# the SET list. Non-greedy so a body with several updates yields each
# one rather than everything between the first and the last.
SET_CLAUSE = re.compile(
    r"\bupdate\s+(?:only\s+)?[a-z_]*\.?[a-z_]+(?:\s+(?!set\b)[a-z_]+)?"
    r"\s+set\s+(.*?)(?=\n\s*(?:where|from|returning)\b|;)",
    re.S | re.I,
)
ASSIGN = re.compile(r"(?:^|,)\s*([a-z_][a-z_0-9]*)\s*=", re.M)


def written(body: str) -> set[str]:
    """Every column name assigned in an UPDATE ... SET in this body."""
    cols: set[str] = set()
    for clause in SET_CLAUSE.findall(body):
        cols.update(ASSIGN.findall(clause))
    return cols - BORING


def callers(bare: str, called_by, per_file) -> list[str]:
    """Test files that REACH the function, directly or through a caller.

    `mutation_targets.callers` rather than a grep for the bare name,
    which is the difference between a useful survey and a noisy one. On
    the first run this script used the grep, and it reported four
    `app.*` functions as having NO TEST FILE AT ALL --
    `app.post_goods_received_internal`, `app.pos_deplete_recipes`,
    `app.move_document_bundles`, `app.pos_return_recipes`. Every one of
    them is reached through its public wrapper and thoroughly tested.
    Four false findings out of sixteen, on a tool whose whole value is
    that somebody believes its output.
    """
    return mt.callers(bare, called_by, per_file)


def survey(only: list[str]):
    """(reportable rows, functions a trigger reaches and this cannot measure)."""
    defs = mt.definitions()
    called_by = mt.call_graph(defs)
    per_file = mt.test_calls(frozenset(called_by))
    tables = mt.trigger_tables()
    rows, by_trigger = [], []
    for row in mt.rank():
        name, where = row[2], row[3]
        bare = name.split(".", 1)[-1]
        if only and bare not in only and name not in only:
            continue
        cols = written(mt.body_of(name, where))
        if not cols:
            continue
        files = callers(bare, called_by, per_file)
        if not files:
            # Reached by DML rather than by a call. `mutation_targets`
            # says why a zero here is not a finding: "a zero there means
            # 'not measurable here', not 'not tested'". The first run of
            # this script reported three such functions as having NO
            # TEST FILE AT ALL -- app.pos_deplete_recipes,
            # app.move_document_bundles and app.pos_return_recipes --
            # and every one is fired by a trigger on a table the suite
            # writes to constantly.
            fires = mt.fired_by(bare, called_by, tables)
            if fires:
                by_trigger.append((name, sorted(cols), sorted(fires)))
                continue
        text = "\n".join((TESTS / f).read_text(errors="replace")
                         for f in files if (TESTS / f).is_file())
        unnamed = sorted(c for c in cols
                         if not re.search(r"\b" + re.escape(c) + r"\b", text))
        if unnamed:
            rows.append((name, unnamed, files))
    return rows, by_trigger


def main() -> int:
    only = sys.argv[1:]
    if not mt.definitions():
        print("state_write_coverage: no migrations found under "
              f"{mt.MIGRATIONS} -- nothing to survey, and that is a problem "
              "with the tree rather than a clean result.")
        return 1

    rows, by_trigger = survey(only)
    wide = max([len(n) for n, _, _ in rows + by_trigger], default=10)
    for name, unnamed, files in rows:
        where = (f"{len(files)} file(s): " + ", ".join(files)
                 if files else "NO TEST FILE REACHES IT")
        print(f"{name:<{wide}}  {', '.join(unnamed)}")
        print(f"{'':<{wide}}    ({where})")

    if by_trigger:
        print()
        print("Reached by a TRIGGER rather than by a call, so this tool "
              "cannot count their files and says nothing about them:")
        for name, cols, fires in by_trigger:
            print(f"{name:<{wide}}  writes {', '.join(cols)}")
            print(f"{'':<{wide}}    (fired by DML on {', '.join(fires)})")

    print()
    print(f"{sum(len(u) for _, u, _ in rows)} written column(s) across "
          f"{len(rows)} function(s) are named in no test file that reaches "
          f"them; {len(by_trigger)} further function(s) not measurable here.")
    print("A reported column is a place to point a sweep, not a defect: "
          "this script's docstring says both ways it can be wrong.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
