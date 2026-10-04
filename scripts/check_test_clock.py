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

## The third shape, and the one neither rule above can see

The two rules above compare the test's clock with the product's. There
is a worse case where BOTH clocks are inside one expression and neither
is `current_date`:

    expires_at::date - pg_temp.today()

`expires_at` is a `timestamptz` and `::date` casts it in the SESSION's
time zone, which is UTC in CI. `pg_temp.today()` is Kuala Lumpur. So this
is a UTC date minus a KL date: right for sixteen hours a day and short by
one for the other eight, and the file names only ONE clock, so the mixed
count stays clean.

It has happened twice:

  * `0424`, on the PRODUCT side -- `completed_at::date` gave the
    session's day, so a membership bought at half past midnight began the
    day before and lost a day at the far end. `pos_service.sql` still
    describes it.
  * `383e505d`, 3 October 2026, in `idempotency.sql`. A 30-day share
    window measured as `expires_at::date - pg_temp.today()` read 30 for
    sixteen hours and 29 for the other eight. Every run of the tranche
    that wrote it was inside the sixteen; **run 2213 then went red at
    16:10 UTC on a commit that changed one markdown file.**

So this is refused too, per STATEMENT rather than per file: a `::date`
cast of a `_at` column in the same statement as a Kuala Lumpur date.
There are none left, which is the point of adding it -- a ratchet at zero
is the only kind that cannot drift.

The fix is to measure against a column on the same clock. The share
window became `expires_at::date - created_at::date`: both are `now()` in
one transaction, cast in one time zone, so their difference is exact at
any hour, and no clock appears in the assertion at all.
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
YEAR_BUDGET = 0

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
#: On 4 October the whole suite moved onto `pg_temp.today()`, defined
#: once in `_helpers.sql`, and this went to ZERO. Keeping the rule costs
#: nothing and a ratchet at zero cannot drift.
#:
#: It read 27 until the KL side of the test learnt to recognise
#: `app.today()` and `pg_temp.today()` as well as the raw expression.
#: Twelve files were pairing the HELPER with a bare `current_date` and
#: the gate could not see them, so the pin had been under-counting the
#: real backlog by nearly a third.
MIXED_BUDGET = 0

#: The one file that must keep a bare `current_date`, with the reason.
#:
#: `malaysian_clock.sql` is the file that tests this very rule. It builds
#: the regex `'(\mcurrent_date\M)|(\mlocaltimestamp\M)'` and feeds it
#: `'select current_date + 1'` to prove it matches, and
#: `'select current_date_of_birth from x'` to prove it does not. Those
#: are inputs inside string literals, not dates being evaluated.
#:
#: Named here rather than excused by a rule that ignores quoted text,
#: because dynamic SQL -- `execute 'select ... current_date ...'` -- IS
#: evaluated, and a gate that skipped every quoted occurrence would hold
#: the door open for it.
EXEMPT = {
    # Tests this very rule: it builds the regex
    # '(\mcurrent_date\M)|(\mlocaltimestamp\M)' and feeds it
    # 'select current_date + 1' to prove it matches, and
    # 'select current_date_of_birth from x' to prove it does not. Inputs
    # inside string literals, not dates being evaluated.
    #
    # Named here rather than excused by a rule that ignores quoted text,
    # because dynamic SQL -- execute 'select ... current_date ...' -- IS
    # evaluated, and a gate that skipped every quoted occurrence would
    # hold the door open for it.
    "malaysian_clock.sql",
    # The one place in the suite where a BARE current_date is correct.
    # The block sets the session's time zone to somewhere that is not
    # Malaysia and then asserts the session's date really differs, to
    # prove corp_upcoming_filings reads deadlines on Malaysian time
    # whatever the server's zone is. pg_temp.today() is always Kuala
    # Lumpur, so asking it there compares Malaysia with Malaysia and the
    # assertion can never pass -- the 4 October sweep did that and the
    # suite caught it. The file names both clocks because it is ABOUT
    # both clocks.
    "corp_deadlines.sql",
}

#: A Kuala Lumpur date, however it is spelt: the raw expression, the
#: product's helper, or the fixture helper this suite uses.
_KL_DATE = re.compile(
    r"at time zone 'Asia/Kuala_Lumpur'|\bapp\.today\(\)|\bpg_temp\.today\(\)"
)

#: `something_at::date` or `(something_at)::date` -- a timestamptz cast
#: to a date in the session's time zone.
_AT_DATE = re.compile(r"\b\w*_at\s*\)?\s*::\s*date\b")

_REFUSED = re.compile(
    r"date_trunc\(\s*'(" + "|".join(REFUSED) + r")'\s*,\s*current_date\s*\)"
)
_YEAR = re.compile(r"date_trunc\(\s*'year'\s*,\s*current_date\s*\)")
_BARE = re.compile(r"\bcurrent_date\b")


def offenders(root: Path) -> tuple[list[str], int, list[str], list[str]]:
    """Short buckets, year-bucket count, two-clock files, two-clock
    STATEMENTS."""
    bad: list[str] = []
    years = 0
    mixed: list[str] = []
    mixed_expr: list[str] = []
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
            if _KL_DATE.search(line):
                kl += 1
            if _BARE.search(line):
                bare += 1
        if kl and bare and path.name not in EXEMPT:
            mixed.append(path.name)

        # The third shape: both clocks inside ONE statement, neither of
        # them `current_date`. Split on `;` after dropping comment
        # lines -- a plpgsql statement ends with one, so this is the
        # right granularity: a `_at::date` in one assertion and a KL
        # date in an unrelated one are two facts, not a comparison.
        body = "\n".join(
            line for line in path.read_text(encoding="utf-8").splitlines()
            if not line.lstrip().startswith("--")
        )
        for statement in body.split(";"):
            if _AT_DATE.search(statement) and _KL_DATE.search(statement):
                first = next(
                    (ln.strip() for ln in statement.splitlines()
                     if _AT_DATE.search(ln) or _KL_DATE.search(ln)), ""
                )
                mixed_expr.append(
                    f"{path.relative_to(root.parent.parent)}: {first[:88]}"
                )
    return bad, years, mixed, mixed_expr


def main() -> int:
    if not TESTS.is_dir():
        print(f"no such directory: {TESTS}", file=sys.stderr)
        return 2

    bad, years, mixed, mixed_expr = offenders(TESTS)
    problems = []

    if mixed_expr:
        problems.append(
            "These put BOTH clocks in one statement: a timestamptz cast to a\n"
            "date in the session's time zone, beside a Kuala Lumpur date. The\n"
            "difference is right for sixteen hours a day and wrong for eight,\n"
            "and the file names only one clock so the mixed count stays\n"
            "clean. Run 2213 went red on exactly this, on a commit that\n"
            "changed one markdown file:\n\n"
            + "\n".join(f"  {m}" for m in mixed_expr)
            + "\n\nMeasure against a column on the SAME clock -- the share\n"
            "window became expires_at::date - created_at::date, which has no\n"
            "clock in it at all."
        )

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

    for name in sorted(EXEMPT):
        path = TESTS / name
        if not path.is_file():
            problems.append(
                f"{name} is EXEMPT but no longer exists. Drop the entry."
            )
            continue
        body = "\n".join(
            line for line in path.read_text(encoding="utf-8").splitlines()
            if not line.lstrip().startswith("--")
        )
        if not (_KL_DATE.search(body) and _BARE.search(body)):
            problems.append(
                f"{name} is EXEMPT from the two-clock rule but no longer "
                f"names both clocks. Drop the entry -- an exemption nobody "
                f"prunes stops being evidence."
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
