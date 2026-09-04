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
"""
import subprocess
import sys

# A function is suspect if it is STABLE or IMMUTABLE and its body
# mentions something that writes. Deliberately generous: a false
# positive is a comment away from being fixed, and a false negative is
# a page that does not load.
QUERY = r"""
select n.nspname || '.' || p.proname
       || '(' || pg_get_function_identity_arguments(p.oid) || ')'
       || '  [' || case p.provolatile when 'i' then 'IMMUTABLE'
                                      else 'STABLE' end || ']'
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname in ('public', 'app')
   and p.prokind = 'f'
   and p.provolatile in ('i', 's')
   and p.prosrc ~* '(note_read|note_export|record_security_event)'
   and p.proname <> 'note_read'
 order by 1;
"""


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: check_stable_writers.py <database-url>", file=sys.stderr)
        return 2

    out = subprocess.run(
        ["psql", sys.argv[1], "-tAc", QUERY],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        print(out.stderr.strip(), file=sys.stderr)
        return 2

    offenders = [line for line in out.stdout.splitlines() if line.strip()]
    if not offenders:
        print("ok   no STABLE or IMMUTABLE function records a read")
        return 0

    print("A function that writes must not be STABLE or IMMUTABLE.")
    print("PostgREST runs those in a READ ONLY transaction, so the write")
    print("fails with 25006 and the whole call fails with it:")
    print()
    for line in offenders:
        print(f"    {line}")
    print()
    print("Declare it VOLATILE, or take the write out. See 0531.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
