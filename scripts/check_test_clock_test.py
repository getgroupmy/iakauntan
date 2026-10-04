#!/usr/bin/env python3
"""Does the clock gate still catch what it claims to?

    python3 scripts/check_test_clock_test.py

A gate that has stopped matching passes everything and says so
cheerfully. This writes the bug back into a scratch tree and requires
the gate to find it, writes the fix and requires it not to, and checks
that the pinned budget is a ratchet in both directions.
"""
from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
GATE = HERE / "check_test_clock.py"

BUG = """
do $$
declare
  v_start date := date_trunc('month', current_date)::date;
begin
  perform 1;
end $$;
"""

FIXED = """
do $$
declare
  v_start date := date_trunc('month',
    (now() at time zone 'Asia/Kuala_Lumpur')::date)::date;
begin
  perform 1;
end $$;
"""

WEEKLY = """
do $$
begin
  perform date_trunc('week', current_date);
end $$;
"""

ONLY_A_COMMENT = """
do $$
begin
  -- date_trunc('month', current_date) is what this file used to do.
  perform 1;
end $$;
"""

#: The real 383e505d bug: a timestamptz cast in the session's time zone
#: minus a Kuala Lumpur date, inside ONE statement. Run 2213 went red on
#: this on a commit that changed one markdown file.
TWO_CLOCK_STATEMENT = """
do $$
begin
  perform pg_temp.check_eq('a null share window takes 30 days',
    (select (expires_at::date - pg_temp.today())
       from public.document_share_links where document_id = v_fresh), 30);
end $$;
"""

#: The fix: both sides on the same clock, so no clock is in it at all.
ONE_CLOCK_STATEMENT = """
do $$
begin
  perform pg_temp.check_eq('a null share window takes 30 days',
    (select (expires_at::date - created_at::date)
       from public.document_share_links where document_id = v_fresh), 30);
end $$;
"""

#: The granularity that matters. A `_at::date` in one assertion and a
#: Kuala Lumpur date in an UNRELATED one are two facts, not a
#: comparison -- a per-file rule would cry wolf on this and a per-file
#: rule is what the mixed count already is.
TWO_STATEMENTS_NOT_ONE = """
do $$
begin
  perform pg_temp.check_true('the link expired', (select expires_at::date
    from public.document_share_links where document_id = v_a) is not null);
  perform pg_temp.check_eq('and the year is open',
    (select count(*) from public.fiscal_years
      where start_date = date_trunc('year', pg_temp.today())::date), 1);
end $$;
"""

#: `app.today()` is the product's Kuala Lumpur helper and counts too.
APP_TODAY_STATEMENT = """
do $$
begin
  perform pg_temp.check_true('started on the day it was paid for',
    (select started_on from public.pos_membership_subscriptions s
      where s.id = v_sub) = (v_sale.completed_at::date - app.today()));
end $$;
"""

YEARS = """
do $$
begin
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date));
end $$;
"""

#: Both clocks in one file -- the shape that took run 2178 red on a file
#: that had just been made MORE correct.
MIXED = """
do $$
declare
  v_to date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  perform pg_temp.entry(v_org, current_date);
end $$;
"""

ONE_CLOCK = """
do $$
declare
  v_to date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  perform pg_temp.entry(v_org, v_to);
end $$;
"""


def run(
    files: dict[str, str],
    budget: int | None = None,
    mixed: int | None = None,
) -> tuple[int, str]:
    """Run the gate over a scratch tree, optionally with new budgets."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        tests = root / "supabase" / "tests"
        tests.mkdir(parents=True)
        for name, body in files.items():
            (tests / name).write_text(body, encoding="utf-8")

        scripts = root / "scripts"
        scripts.mkdir()
        source = GATE.read_text(encoding="utf-8")
        if budget is not None:
            source = re.sub(
                r"^YEAR_BUDGET = \d+$",
                f"YEAR_BUDGET = {budget}",
                source,
                flags=re.M,
            )
        source = re.sub(
            r"^MIXED_BUDGET = \d+$",
            f"MIXED_BUDGET = {0 if mixed is None else mixed}",
            source,
            flags=re.M,
        )
        # The scratch tree holds one file called a.sql, so the real
        # EXEMPT entry would fail its own staleness check on every run.
        source = re.sub(
            r"^EXEMPT = \{[^}]*\}$", "EXEMPT = set()", source, flags=re.M,
        )
        copy = scripts / "check_test_clock.py"
        copy.write_text(source, encoding="utf-8")

        done = subprocess.run(
            [sys.executable, str(copy)], capture_output=True, text=True
        )
        return done.returncode, done.stdout + done.stderr


def main() -> int:
    failures: list[str] = []

    def expect(label: str, got: int, want: int, output: str) -> None:
        if got != want:
            failures.append(f"{label}: exit {got}, wanted {want}\n{output}")

    code, out = run({"a.sql": BUG}, budget=0)
    expect("a monthly bucket on the session clock is refused", code, 1, out)
    if code == 1 and "a.sql:4" not in out:
        failures.append(f"the refusal does not name the line:\n{out}")

    code, out = run({"a.sql": FIXED}, budget=0)
    expect("and the Kuala Lumpur form is not", code, 0, out)

    code, out = run({"a.sql": WEEKLY}, budget=0)
    expect("a weekly bucket is refused too", code, 1, out)

    code, out = run({"a.sql": ONLY_A_COMMENT}, budget=0)
    expect("a file may describe the bug it fixed", code, 0, out)

    # The budget is a ratchet. One over is refused; one under is refused
    # as well, because a budget nobody lowers stops being a ratchet.
    code, out = run({"a.sql": YEARS}, budget=0)
    expect("a fiscal year over budget is refused", code, 1, out)

    code, out = run({"a.sql": YEARS}, budget=1)
    expect("and exactly at budget is allowed", code, 0, out)

    code, out = run({"a.sql": YEARS}, budget=2)
    expect("and under budget asks for the pin to be lowered", code, 1, out)

    # Both clocks in one file. A ratchet, like the year budget: a file
    # may already mix them and no NEW file may start to.
    code, out = run({"a.sql": MIXED}, budget=0)
    expect("a file naming both clocks is refused over budget", code, 1, out)
    if code == 1 and "a.sql" not in out:
        failures.append(f"the refusal does not name the file:\n{out}")

    code, out = run({"a.sql": MIXED}, budget=0, mixed=1)
    expect("and allowed exactly at budget", code, 0, out)

    code, out = run({"a.sql": MIXED}, budget=0, mixed=2)
    expect("and under budget asks for the pin to be lowered", code, 1, out)

    code, out = run({"a.sql": ONE_CLOCK}, budget=0)
    expect("one clock throughout is not mixing", code, 0, out)

    # Both clocks in ONE STATEMENT, which neither rule above can see:
    # the file names only the Kuala Lumpur one, so the mixed count stays
    # clean. Refused outright rather than counted -- there are none left,
    # and a ratchet at zero cannot drift.
    code, out = run({"a.sql": TWO_CLOCK_STATEMENT}, budget=0)
    expect("a timestamptz cast beside a KL date is refused", code, 1, out)
    if code == 1 and "expires_at::date" not in out:
        failures.append(f"the refusal does not quote the expression:\n{out}")

    code, out = run({"a.sql": ONE_CLOCK_STATEMENT}, budget=0)
    expect("and measuring against created_at is not", code, 0, out)

    code, out = run({"a.sql": TWO_STATEMENTS_NOT_ONE}, budget=0)
    expect("two unrelated statements are two facts, not a comparison",
           code, 0, out)

    code, out = run({"a.sql": APP_TODAY_STATEMENT}, budget=0)
    expect("app.today() counts as the Kuala Lumpur clock too", code, 1, out)

    if failures:
        print("\n\n".join(failures), file=sys.stderr)
        return 1
    print("the clock gate still catches what it claims to")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
