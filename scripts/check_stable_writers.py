#!/usr/bin/env python3
"""A function that writes must not promise Postgres that it does not.

STABLE and IMMUTABLE are promises: the planner may cache the result, and
-- the reason this check exists -- PostgREST runs such a function in a
READ ONLY transaction. A write inside one fails with

    cannot execute INSERT in a read-only transaction   (25006)

which is what "What people told us" did for the whole life of the
platform console. `public.platform_feedback` was STABLE and wrote a
security-audit row through `app.note_read`.

The SQL suite cannot catch this on its own: it calls functions from
psql, where nothing is read-only and the write succeeds. The
declaration is only load bearing at the PostgREST door. So this is a
STATIC check against the applied schema, run in CI beside the
assertions.

Usage:  check_stable_writers.py "$DATABASE_URL"

## What it used to ask, and why that was not enough

Until `0600` this looked for three names in the body:

    p.prosrc ~* '(note_read|note_export|record_security_event)'

which is the list of writers somebody had been bitten by, not the list
of writers. It answers correctly for `platform_feedback`, the one that
broke, and says nothing about a STABLE function that calls anything
else -- or that writes with its own `update`.

Two mutants, neither caught by that regex and both caught now:

  * a STABLE function whose own body updates a table;
  * a STABLE function that calls a VOLATILE one that updates a table,
    where nothing in the caller's body mentions a write at all.

The second is the shape that matters, because the thin wrapper over an
`_internal` writer is how half this schema is built --
`post_sales_document`, `next_document_number`, `open_pos_sale`,
`transition_ticket` and a dozen more. Any one of them declared STABLE
by a future migration would have passed.

`sql_call_graph.py` does the reading, and its docstring carries the
other half: a body cannot be scanned by blanking comments and then
blanking strings, because a `--` inside a refusal message eats the
write it was written for.
"""
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from sql_call_graph import load, mark_writers, why  # noqa: E402



#: A floor under how many functions the catalogue query must return the sweep must have EXAMINED.
#:
#: Found by running every database-backed gate against a database
#: that EXISTS and has an empty schema -- the case the empty-tree
#: sweep in `check_sweeps_look.py` cannot reach, and says it
#: cannot. Four of the ten passed, this among them.
#:
#: 1,653 today. Set well below that: it guards against the query coming
#: back empty, not against a function being added or removed.
LEAST = int(os.environ.get("IAK_LEAST_SITES", "800"))


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: check_stable_writers.py <database-url>", file=sys.stderr)
        return 2

    try:
        rows = load(sys.argv[1])
    except RuntimeError as e:
        print(str(e), file=sys.stderr)
        return 2

    if len(rows) < LEAST:
        print(
            f"The catalogue query returned {len(rows)} function(s), and "
            f"there were {LEAST} or more when this was written. Either "
            f"the database is not the one with the schema in it, or the "
            f"query no longer matches -- and a gate with no functions to "
            f"read says `ok nothing declared STABLE or IMMUTABLE can "
            f"reach a write`, which is what a correct schema says.",
            file=sys.stderr)
        return 2

    writes = mark_writers(rows)
    offenders = [
        i for i, r in enumerate(rows)
        if r["kind"] == "f" and r["vol"] in ("i", "s") and not r["ext"]
        and writes[i]
    ]

    if not offenders:
        print(f"ok   nothing declared STABLE or IMMUTABLE can reach a "
              f"write ({len(rows)} functions examined)")
        return 0

    print("A function that writes must not be STABLE or IMMUTABLE.")
    print("PostgREST runs those in a READ ONLY transaction, so the write")
    print("fails with 25006 and the whole call fails with it:")
    print()
    for i in offenders:
        kind = "IMMUTABLE" if rows[i]["vol"] == "i" else "STABLE"
        print(f"    {rows[i]['signature']}  [{kind}]")
        print(f"        writes through: {why(rows, writes, i)}")
    print()
    print("Declare it VOLATILE, or take the write out. See 0531.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
