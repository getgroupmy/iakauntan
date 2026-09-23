#!/usr/bin/env python3
"""Two functions one named call could mean.

    python3 scripts/check_ambiguous_overloads.py "$DATABASE_URL"

PostgREST calls every function BY NAME. So two overloads of one public
function are fine right up until the set of named arguments a caller
sends fits both, and then every client gets

    ERROR:  function public.x(p_a => uuid, ...) is not unique
    HINT:   Could not choose a best candidate function.

## The one this was written for

`0690` added `transfer_between_matters(uuid, uuid, numeric, text, date,
text)` to a database that had carried `transfer_between_matters(uuid,
uuid, numeric, date, text)` since `0358`. Different signatures, so
`create or replace` replaced nothing -- it made a second function.

`p_reference` on the newer one had a default, so the five names the app
sent fitted both, and the matter screen's transfer stopped working the
moment it applied. `0696` removed it.

Nothing caught it. `matter_transfer.sql` calls POSITIONALLY --
`transfer_between_matters(v_sale, v_lease, 3000)` -- which Postgres
resolves without complaint, so a whole file of assertions stayed green
over a feature that was dead in every client.

## What counts as ambiguous

Not "two functions share a name": that is ordinary and often right --
one taking a uuid and one taking a text are told apart by what is
passed.

The hazard is narrower and is about NAMES. For each pair of overloads,
work out the argument names each can be called with, and the names each
REQUIRES. If some set of names satisfies both -- every required name of
each is present in the other's callable set -- then a caller sending
that set gets `is not unique`, whatever the types are, because
PostgREST is choosing before the types are looked at.

Types are deliberately ignored. Postgres does use them to break a tie,
but only when the values it is given have unambiguous types, and a
client sending JSON does not: `100` arrives as `integer` and matches
`numeric` and `double precision` equally, which is exactly how the
`0690` call came out ambiguous rather than resolved.
"""

from __future__ import annotations

import subprocess
import sys


# Tab separated, with the names joined by commas: `psql -tA` is how
# every other gate here reads the catalog, and it keeps this runnable
# against a throwaway Postgres with nothing installed.
QUERY = """
select p.proname
       || E'\t' || p.oid::regprocedure::text
       || E'\t' || array_to_string(coalesce(p.proargnames, '{}'), ',')
       || E'\t' || p.pronargs
       || E'\t' || p.pronargdefaults
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.prokind = 'f'
   -- What a signed-in user can actually reach. A function only the
   -- service role may call is never named by PostgREST on a tenant's
   -- behalf, so two of those cannot collide for anybody.
   and has_function_privilege('authenticated', p.oid, 'execute')
   -- Ours, not an extension's. `citext` installs a dozen overloads of
   -- `regexp_replace` and friends, and they are not this repository's
   -- to drop or rename.
   and not exists (
     select 1 from pg_depend d
      where d.objid = p.oid
        and d.deptype = 'e')
   -- Callable BY NAME at all. A function whose arguments have no names
   -- can only be called positionally, so PostgREST cannot reach it and
   -- two of them cannot collide the way this gate is about. Every
   -- `citext` operator function is one of these.
   and p.proargnames is not null
   and array_length(p.proargnames, 1) > 0
 order by p.proname
"""


def callable_names(argnames: list[str], nargs: int) -> set[str]:
    """Every argument name a caller may supply.

    `proargnames` includes OUT names on a function that has them; only
    the first `pronargs` are inputs.
    """
    return {a for a in argnames[:nargs] if a}


def required_names(argnames: list[str], nargs: int, ndefaults: int) -> set[str]:
    """The names with no default, which a caller must supply."""
    return {a for a in argnames[: nargs - ndefaults] if a}


def collides(a: dict, b: dict) -> bool:
    """Whether one set of named arguments could mean either."""
    a_all = callable_names(a["argnames"], a["nargs"])
    b_all = callable_names(b["argnames"], b["nargs"])
    a_need = required_names(a["argnames"], a["nargs"], a["ndefaults"])
    b_need = required_names(b["argnames"], b["nargs"], b["ndefaults"])

    # A caller has to satisfy both at once, so the set they send is at
    # least the union of what each requires -- and every name in it has
    # to be one both will accept.
    wanted = a_need | b_need
    return wanted <= a_all and wanted <= b_all


def main(dsn: str) -> int:
    if not dsn:
        print("usage: check_ambiguous_overloads.py <database-url>",
              file=sys.stderr)
        return 2

    out = subprocess.run(["psql", dsn, "-tAc", QUERY],
                         capture_output=True, text=True)
    if out.returncode != 0:
        print(out.stderr.strip(), file=sys.stderr)
        return 2

    rows = []
    for line in out.stdout.splitlines():
        if not line.strip():
            continue
        name, signature, argnames, nargs, ndefaults = line.split("\t")
        rows.append({
            "name": name,
            "signature": signature,
            "argnames": [a for a in argnames.split(",") if a],
            "nargs": int(nargs),
            "ndefaults": int(ndefaults),
        })

    by_name: dict[str, list[dict]] = {}
    for r in rows:
        by_name.setdefault(r["name"], []).append(r)

    bad: list[tuple[str, str, set[str]]] = []
    for name, group in by_name.items():
        if len(group) < 2:
            continue
        for i in range(len(group)):
            for j in range(i + 1, len(group)):
                a, b = group[i], group[j]
                if collides(a, b):
                    wanted = (
                        required_names(a["argnames"], a["nargs"], a["ndefaults"])
                        | required_names(b["argnames"], b["nargs"], b["ndefaults"])
                    )
                    bad.append((a["signature"], b["signature"], wanted))

    if bad:
        print(
            f"FAIL: {len(bad)} pair(s) of overloads a named call cannot "
            f"choose between.\n"
        )
        print(
            "PostgREST calls by NAME, so a client sending these names gets\n"
            "`function ... is not unique` and the feature is dead in every\n"
            "client while positional SQL tests go on passing. That is what\n"
            "`0690` did to `0358`; `0696` removed it.\n"
        )
        for a, b, wanted in bad:
            names = ", ".join(sorted(wanted)) or "(no required arguments)"
            print(f"  {a}")
            print(f"  {b}")
            print(f"    both answer to: {names}\n")
        print(
            "Drop one, or rename it. An overload that differs only in a\n"
            "type a JSON client cannot express is not an overload anybody\n"
            "can reach on purpose."
        )
        return 1

    overloaded = sum(1 for g in by_name.values() if len(g) > 1)
    print(
        f"no two functions answer to one set of named arguments "
        f"({len(rows)} reachable, {overloaded} overloaded by name)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else ""))
