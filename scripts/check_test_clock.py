#!/usr/bin/env python3
"""Refuse an assertion that buckets a date on the wrong clock.

    python3 scripts/check_test_clock.py

`current_date` is the SESSION's date. In CI the session is UTC. The
product's date is `app.today()`, which is `app.malaysian_day(now())` —
Kuala Lumpur, UTC+8. From 16:00 UTC the two disagree, every single day,
for eight hours.

That difference is invisible until something buckets on it. Then one day
of skew becomes a whole bucket:

    run 2176, 17:04 UTC, 30 September 2026

    current_date                       2026-09-30
    app.today()                        2026-10-01
    date_trunc('month', current_date)  2026-09-01  <- the test asked
    date_trunc('month', app.today())   2026-10-01  <- the product filed

`supabase/tests/pos.sql` asked `pos_einvoice_outstanding` for the
September period while the three POS sales it had just made were filed
under October. `sales_waiting` came back NULL against an expected 3, and
the commit that went red contained no SQL whatsoever.

## What is refused, and what is only counted

Refused outright: `month`, `week` and `quarter` over `current_date`.
Their fuses are short — one evening a month, one evening a week — and
every one of them is a test that will go red on somebody else's diff.

Counted rather than refused: `year`. There are far too many to convert
in the change that found this, they are almost all
`create_fiscal_year(v_org, date_trunc('year', current_date))`, and their
fuse burns one evening a year. The number is PINNED below: it may fall,
it may not rise. Adding one is then a decision somebody makes on
purpose rather than a habit that spreads.

The fix in every case is the same. Ask the clock the product asks:

    (now() at time zone 'Asia/Kuala_Lumpur')::date

Comment lines are ignored, so a file may describe the bug it fixed.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TESTS = ROOT / "supabase" / "tests"

#: Buckets whose fuse is short enough that the assertion is simply wrong.
REFUSED = ("month", "week", "quarter")

#: `date_trunc('year', current_date)`, which is nearly always a fiscal
#: year being created for a fixture. It may fall; it may not rise.
YEAR_BUDGET = 148

#: Files that name BOTH clocks in code -- the Kuala Lumpur expression
#: somewhere and a bare `current_date` somewhere else.
#:
#: Mostly harmless: a `current_date + 7` beside a KL-derived fiscal year
#: is two independent facts, not a comparison. What is not harmless is
#: HALF A FIX, and that is what this counts.
#:
#: Run 2178. `group_trial_balance_shapes.sql` had its report window
#: moved to Kuala Lumpur and its fixture dates left on `current_date`.
#: On 30 September the window then closed on the 30th while the entry
#: that must fall OUTSIDE it was dated the 30th, so the assertion
#: "money that moved after the period is not in the report" failed --
#: on a file that had just been made more correct. Leaving both clocks
#: alone would have passed.
#:
#: So: a file may already mix them, and no NEW file may start to. It
#: may fall; it may not rise.
MIXED_BUDGET = 27

_REFUSED = re.compile(
    r"date_trunc\(\s*'(" + "|".join(REFUSED) + r")'\s*,\s*current_date\s*\)"
)
_YEAR = re.compile(r"date_trunc\(\s*'year'\s*,\s*current_date\s*\)")
_KL = re.compile(r"at time zone 'Asia/Kuala_Lumpur'")
_BARE = re.compile(r"\bcurrent_date\b")


def offenders(root: Path) -> tuple[list[str], int, list[str]]:
    """Short buckets, how many use the year one, and files with two clocks."""
    bad: list[str] = []
    years = 0
    mixed: list[str] = []
    for path in sorted(root.glob("*.sql")):
        kl = bare = 0
        for n, line in enumerate(
            path.read_text(encoding="utf-8").splitlines(), start=1
        ):
            # A file is allowed to write down the bug it fixed.
            if line.lstrip().startswith("--"):
                continue
            if _REFUSED.search(line):
                bad.append(f"{path.relative_to(root.parent.parent)}:{n}: {line.strip()}")
            years += len(_YEAR.findall(line))
            if _KL.search(line):
                kl += 1
            if _BARE.search(line):
                bare += 1
        if kl and bare:
            mixed.append(path.name)
    return bad, years, mixed


def main() -> int:
    if not TESTS.is_dir():
        print(f"no such directory: {TESTS}", file=sys.stderr)
        return 2

    bad, years, mixed = offenders(TESTS)
    problems = []

    if bad:
        problems.append(
            "These bucket a date on the session's clock, which is UTC in CI,\n"
            "while the product buckets on Kuala Lumpur. From 16:00 UTC they\n"
            "are different days, and across a boundary a different bucket:\n\n"
            + "\n".join(f"  {b}" for b in bad)
            + "\n\nUse (now() at time zone 'Asia/Kuala_Lumpur')::date instead."
        )

    if len(mixed) > MIXED_BUDGET:
        problems.append(
            f"{len(mixed)} files in supabase/tests name BOTH clocks in code,\n"
            f"and the pinned budget is {MIXED_BUDGET}. A file that derives one\n"
            "date from Kuala Lumpur and another from the session is a file\n"
            "whose two dates move apart for eight hours a day -- which is how\n"
            "run 2178 went red on a file that had just been made more\n"
            "correct. Put the whole file on\n"
            "(now() at time zone 'Asia/Kuala_Lumpur')::date.\n\n"
            + "\n".join(f"  {m}" for m in mixed)
        )

    if years > YEAR_BUDGET:
        problems.append(
            f"date_trunc('year', current_date) is used {years} times in\n"
            f"supabase/tests, and the pinned budget is {YEAR_BUDGET}. It may\n"
            "fall and may not rise. Use\n"
            "(now() at time zone 'Asia/Kuala_Lumpur')::date in the new one."
        )

    if problems:
        print("\n\n".join(problems), file=sys.stderr)
        return 1

    if years < YEAR_BUDGET:
        print(
            f"date_trunc('year', current_date) is down to {years} from "
            f"{YEAR_BUDGET}.\nLower YEAR_BUDGET in this file so it cannot "
            "climb back."
        )
        return 1

    if len(mixed) < MIXED_BUDGET:
        print(
            f"files naming both clocks are down to {len(mixed)} from "
            f"{MIXED_BUDGET}.\nLower MIXED_BUDGET in this file so it cannot "
            "climb back."
        )
        return 1

    print(
        f"the clock is the product's, with {years} fiscal years and "
        f"{len(mixed)} two-clock files still to go"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
