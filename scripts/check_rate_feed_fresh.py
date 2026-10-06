#!/usr/bin/env python3
"""Is the exchange rate table still being fed?

    curl ... /rest/v1/exchange_rates?select=rate_date&order=rate_date.desc&limit=1 \\
      | python3 scripts/check_rate_feed_fresh.py
    python3 scripts/check_rate_feed_fresh.py --newest 2026-09-25

## Why this exists, which is not the obvious reason

`.github/workflows/exchange-rates.yml` already fails when the fetch
fails, so a gate on top of it looks redundant. It is not, because that
workflow answers a different question. **It reports on the ATTEMPT. This
reports on the OUTCOME.**

Between 28 September and 6 October 2026 the feed was dead for eleven
days -- a TLS handshake failure against Bank Negara -- and the workflow
did fail loudly every weekday, which is the design working. Nobody was
reading it. What nothing anywhere asked was the only question that
matters to the ledger: *is the rate table current?*

And the attempt can succeed while the outcome is wrong. That workflow
has **two paths that exit 0 having stored nothing**:

  * no `SCHEDULER_SECRET` and no `SUPABASE_SERVICE_ROLE_KEY` -- it
    prints a warning and exits 0, by design, so that a repository
    without the secret does not show a permanent red cross;
  * a 404 from Bank Negara, which means "nothing published today" and
    is the honest answer on a public holiday.

Either can persist for weeks as a green badge. A third way is outside
the repository entirely: **GitHub disables scheduled workflows on a
repository with no recent activity**, and a disabled schedule looks
exactly like a schedule with nothing to report.

So this asks the table, not the job.

## Why it is not a SQL assertion in `supabase/tests/`

Those run against a throwaway cluster built by `run_locally.sh` from the
migrations, and the rate feed has never run there: `exchange_rates` is
empty, and a freshness assertion would either fail every run or be
written to pass on an empty table -- which is the same bug as the two
empty schema dumps that compared clean (see `docs/handoff.md`).

## Why it is not a step in `ci.yml`

`exchange-rates.yml` says it best, about itself: "a scheduled job that
fails because Bank Negara is down should not sit in the same run as the
thing that decides whether code reaches production." The same applies
here, and more so -- this one fails when NOTHING has changed in the
repository. It is an operations timer and it gets its own file.

`ci.yml` runs the self-test beside this file, because the THRESHOLD
logic is code and code that cannot be wrong has not been written yet.

## The thresholds

Bank Negara publishes on business days. The feed runs on weekdays, and
those are not the same set, so the age of the newest row is routinely
more than one day:

    Friday publication, read on Monday evening          3 days
    ... with Monday a public holiday, read Tuesday       4 days
    ... with a two-day festival beside a weekend         5 days

`WARN_DAYS = 4` is therefore a notice and not a failure: it is reachable
by an ordinary long weekend. `STALE_DAYS = 7` cannot be reached by any
combination of Malaysian weekends and holidays, so seven days means the
feed has stopped.

## An empty table is the WORST case, not the best

A gate that reads "no rows" as "nothing to complain about" is a gate
that passes hardest when the thing it guards has failed completely. The
empty answer, the malformed answer and the absent column all exit 1
here. So does a date in the FUTURE, which is not freshness but a clock
or a publisher getting it wrong, and which would otherwise sail through
every threshold above.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import sys

# See "The thresholds" above. Not a tuned pair: 4 is the longest an
# ordinary holiday weekend reaches, 7 is past anything the calendar can
# produce.
WARN_DAYS = 4
STALE_DAYS = 7

FRESH, WARN, STALE, BROKEN = "fresh", "warn", "stale", "broken"


def verdict(newest: dt.date | None, today: dt.date) -> tuple[str, int | None, str]:
    """(verdict, age in days, the sentence to print).

    `newest` is None when the table is empty or the answer could not be
    read -- deliberately the same branch, because neither is evidence
    that the feed is working.
    """
    if newest is None:
        return (BROKEN, None,
                "The rate table has no readable newest date. An empty "
                "`exchange_rates` is the worst case, not the best: "
                "`revalue_foreign_balances` refuses a currency it cannot "
                "price, so month end does not fail -- it does not happen.")
    age = (today - newest).days
    if age < 0:
        return (BROKEN, age,
                f"The newest rate is dated {newest}, which is {-age} day(s) "
                f"in the FUTURE. That is a clock or a publisher wrong, not a "
                f"fresh feed, and every threshold below would have passed it.")
    if age >= STALE_DAYS:
        return (STALE, age,
                f"The newest rate is dated {newest}, {age} days ago. No "
                f"combination of weekends and Malaysian public holidays "
                f"reaches {STALE_DAYS} days, so the feed has stopped. Read "
                f"the last `Exchange rates` run, and the `fetch-rates` "
                f"function logs for a `fetch-rates.unreachable` event.")
    if age >= WARN_DAYS:
        return (WARN, age,
                f"The newest rate is dated {newest}, {age} days ago. A long "
                f"weekend with a public holiday reaches this, so it is a "
                f"notice rather than a failure -- but if it is still here "
                f"tomorrow it is not the calendar.")
    return (FRESH, age, f"The newest rate is dated {newest}, {age} day(s) ago.")


def newest_from_rows(payload: str) -> dt.date | None:
    """The newest `rate_date` in a PostgREST reply, or None.

    None for every shape that is not a date, including PostgREST's own
    error object -- `{"message": ...}` is not a rate.
    """
    try:
        rows = json.loads(payload)
    except (ValueError, TypeError):
        return None
    if not isinstance(rows, list) or not rows:
        return None
    dates = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        raw = row.get("rate_date")
        if not isinstance(raw, str):
            continue
        try:
            dates.append(dt.date.fromisoformat(raw[:10]))
        except ValueError:
            continue
    return max(dates) if dates else None


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--newest", help="a date, instead of reading stdin")
    ap.add_argument("--today", help="override today, for the self-test")
    args = ap.parse_args(argv)

    today = (dt.date.fromisoformat(args.today) if args.today
             else dt.date.today())
    if args.newest:
        try:
            newest = dt.date.fromisoformat(args.newest)
        except ValueError:
            newest = None
    else:
        newest = newest_from_rows(sys.stdin.read())

    state, age, sentence = verdict(newest, today)
    print(f"{state}: {sentence}")
    if state == FRESH:
        return 0
    # `::warning::` and `::error::` put it on the run summary rather than
    # only in the log, which is the difference between a person seeing
    # this and not.
    print(f"::{'warning' if state == WARN else 'error'}::{sentence}")
    return 0 if state == WARN else 1


if __name__ == "__main__":
    sys.exit(main())
