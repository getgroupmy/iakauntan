#!/usr/bin/env python3
"""A table with two doors must not have a weaker rule on the second one.

    python3 scripts/check_write_doors.py "$DATABASE_URL"

`repository.dart` reaches the database two ways: through an RPC, and
through PostgREST straight onto a table — `client.from('t').insert(...)`.
There are 171 of the second kind over 82 tables. That is not a defect:
most are reference data where a row policy is exactly the right guard,
and a draft that a posting function later posts is a normal shape.

It becomes a defect when the FUNCTION that writes a table demands a
stronger permission than the table's own write POLICIES do, because then
the direct door is the weaker one and the function's guard is optional.

`0740` is the case this was written for. `client_account_transactions` —
a solicitor's client account ledger — had an insert policy asking for
`app.can_write`, while `receive_client_money` and
`pay_from_client_account` both demand `app.can_post`, saying
"Insufficient privileges to move client money". `recordClientTransaction`
used the weaker door, so a member who may write but not post could record
a movement of client money; `post_client_transaction` would then refuse
it and leave an UNPOSTED trust row — money shown against a client and
absent from the accounts.

## Why this is a reviewed list and not a count

The same mechanical signal fires on five other tables and NONE of them is
a defect, which is the whole reason the list carries a reason per entry
rather than a number:

  * `expenses` and `stock_adjustments` insert with `status = 'draft'` and
    then call `post_expense` / `post_stock_adjustment`. The function needs
    `can_post` because POSTING needs `can_post`; drafting does not. A
    draft is meant to be visible and unposted.
  * `time_entries` is somebody recording their own hours, which is a
    `can_write` act. Both `can_post` writers act on hours already
    recorded: `app.bill_time_internal` marks entries billed when the
    invoice is raised, and `close_project` marks the unbilled ones
    unbillable.
  * `property_statutory_charges` is a charge DEFINITION;
    `bill_statutory_charge` needs `can_post` because billing it is
    posting.
  * `accounts` and `tax_codes` reach `can_admin` in one writer each —
    `setup_legal_module` enabling a module, `set_sst_registration`
    registering a company for SST. That is a DIFFERENT operation, not a
    stronger guard on the same one.

So a hit here means "read both sides and say which of those this is". It
does not mean a bug. What it does mean is that nobody can add a weaker
second door to a table silently, which is what happened to client money.
"""

from __future__ import annotations

import collections
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CLIENT = ROOT / "app" / "lib" / "src" / "data" / "repository.dart"

#: Strongest first. This is the ladder the schema's guards actually use.
LADDER = ["can_admin", "can_post", "can_manage_hr", "can_write_module",
          "can_write"]

#: Fixture seeders are not a production path.
DEMO = re.compile(r"^app\.demo_|_teardown$|_rebuild$")

DIRECT = re.compile(
    r"\.from\('([a-z0-9_]+)'\)"
    r"((?:\s|\.[a-zA-Z_]+\([^()]*\))*?)"
    r"\.(insert|update|upsert|delete)\b"
)

#: Each entry is a table whose functions demand more than its policies,
#: with the reason it is not the `0740` shape. An entry that stops having
#: the gap fails below, because an excuse nobody prunes is not evidence.
REVIEWED: dict[str, str] = {
    "expenses":
        "draft-then-post: the insert sets status 'draft' and the next line "
        "calls post_expense, which needs can_post because posting does",
    "stock_adjustments":
        "draft-then-post: the insert sets status 'draft' explicitly and "
        "post_stock_adjustment needs can_post for the posting",
    "time_entries":
        "recording your own hours is a can_write act; the two can_post "
        "writers do a billing act on hours already recorded -- "
        "app.bill_time_internal marks entries billed when the invoice is "
        "raised, close_project marks the unbilled ones unbillable",
    "property_statutory_charges":
        "a charge DEFINITION, not a billing; bill_statutory_charge needs "
        "can_post because billing it is posting",
    "accounts":
        "the policies already require can_post for ordinary chart "
        "maintenance; the one can_admin writer is setup_legal_module, which "
        "inserts three is_system accounts while ENABLING a module -- a "
        "different act, not a stronger guard on the same one",
    "tax_codes":
        "the policies already require can_post; set_sst_registration needs "
        "can_admin because registering a company for SST is an admin act",
}


def psql(db: str, sql: str) -> str:
    return subprocess.run(["psql", db, "-At", "-F", "\t", "-c", sql],
                          capture_output=True, text=True,
                          check=True).stdout


def direct_writes(text: str) -> dict[str, set[str]]:
    """Tables `repository.dart` writes without going through an RPC."""
    found: dict[str, set[str]] = collections.defaultdict(set)
    for m in DIRECT.finditer(text):
        verb = m.group(3)
        found[m.group(1)].add("insert" if verb == "upsert" else verb)
    return dict(found)


def guards(body: str) -> set[str]:
    return {g for g in LADDER if re.search(r"app\." + g + r"\s*\(", body)}


def rank(names: set[str]) -> int:
    """How strong the strongest of these is. Lower is stronger."""
    return min([LADDER.index(n) for n in names], default=len(LADDER) + 1)


def gaps(db: str, text: str) -> dict[str, tuple[set[str], set[str]]]:
    """Table -> (what its policies ask, what its functions ask)."""
    tables = direct_writes(text)

    by_function = psql(db, """
        select n.nspname || '.' || p.proname,
               replace(pg_get_functiondef(p.oid), E'\\n', ' ')
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname in ('public', 'app') and p.prokind = 'f'
           and p.prosecdef
         order by 1;""")

    needs: dict[str, set[str]] = collections.defaultdict(set)
    for row in by_function.strip().split("\n"):
        if not row or "\t" not in row:
            continue
        name, body = row.split("\t", 1)
        if DEMO.search(name):
            continue
        low = body.lower()
        for table in tables:
            if any(re.search(rx, low) for rx in (
                    r"insert\s+into\s+(?:public\.)?" + table + r"\b",
                    r"update\s+(?:public\.)?" + table + r"\b",
                    r"delete\s+from\s+(?:public\.)?" + table + r"\b")):
                needs[table] |= guards(low)

    by_policy = psql(db, """
        select c.relname,
               replace(coalesce(pg_get_expr(p.polqual, p.polrelid), '') || ' '
                       || coalesce(pg_get_expr(p.polwithcheck, p.polrelid),
                                   ''), E'\\n', ' ')
          from pg_policy p
          join pg_class c on c.oid = p.polrelid
          join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'public' and p.polcmd in ('a', 'w', 'd', '*');""")

    allows: dict[str, set[str]] = collections.defaultdict(set)
    for row in by_policy.strip().split("\n"):
        parts = row.split("\t", 1)
        if len(parts) != 2:
            continue
        table, expr = parts
        allows[table] |= guards(expr)

    out = {}
    for table in tables:
        fn, pol = needs.get(table, set()), allows.get(table, set())
        # No write policy at all means the direct door is SHUT, which is
        # what 0740 did: there is nothing weaker to find.
        if fn and pol and rank(fn) < rank(pol):
            out[table] = (pol, fn)
    return out


def run(db: str, text: str | None = None,
        reviewed: dict[str, str] | None = None) -> int:
    text = CLIENT.read_text() if text is None else text
    reviewed = REVIEWED if reviewed is None else reviewed
    found = gaps(db, text)

    problems = []
    for table in sorted(found):
        if table not in reviewed:
            pol, fn = found[table]
            problems.append(
                "%s is written directly by repository.dart under a policy "
                "asking only for %s, while a function that writes it demands "
                "%s. The direct door is then the weaker one and the "
                "function's guard is optional — which is how a member who "
                "may not post could write on a client's ledger before 0740. "
                "Read both sides and either revoke the grant, or add it to "
                "REVIEWED in %s saying which shape it is."
                % (table, ", ".join(sorted(pol)), ", ".join(sorted(fn)),
                   pathlib.Path(__file__).name))

    for table in sorted(reviewed):
        if table not in found:
            problems.append(
                "%s is in REVIEWED but no longer has the gap. Drop the "
                "entry — an excuse nobody prunes is not evidence." % table)

    if problems:
        print("Write doors:\n", file=sys.stderr)
        for problem in problems:
            print("  %s\n" % problem, file=sys.stderr)
        return 1

    print("%d table(s) are written both directly and by a function that asks "
          "for more; every one is reviewed." % len(found))
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: check_write_doors.py <database-url>", file=sys.stderr)
        return 2
    return run(sys.argv[1])


if __name__ == "__main__":
    raise SystemExit(main())
