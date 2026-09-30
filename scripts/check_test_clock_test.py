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

YEARS = """
do $$
begin
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date));
end $$;
"""


def run(files: dict[str, str], budget: int | None = None) -> tuple[int, str]:
    """Run the gate over a scratch tree, optionally with a new budget."""
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

    if failures:
        print("\n\n".join(failures), file=sys.stderr)
        return 1
    print("the clock gate still catches what it claims to")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
