#!/usr/bin/env python3
"""A value this database computes in a function body and throws away.

    python3 scripts/check_discarded_values.py "$DATABASE_URL"

`0601` was found by one of these, and not by reading the function. Its
second line was

    select n.org_id, n.kind::text into v_org, v_kind
      from public.deposit_notes n where n.id = p_id;

and `v_kind` was never looked at again. That variable was the whole
access check somebody meant to write: without it, a company whose
Purchases module had lapsed could still read a supplier deposit's
history -- its events, their amounts, and the free-text reason
somebody typed -- while both sibling list functions had already
stopped showing it.

An unused variable is usually nothing. An unused variable holding a
row's KIND, in a function that decides what a caller may see, is a
missing `if`.

## What it looks for, and what it does not

Narrow on purpose: a variable declared in `declare`, ASSIGNED somewhere
in the body (an `into` target or a `:=` target), and READ nowhere.

A constant initialised in the DECLARE and used once is not this, which
a first draft got wrong: it reported all eleven of `app.normal_z`'s
polynomial coefficients, which are initialised where they are declared
and read once in the expression they exist for. Counting "appears once
in the body" finds arithmetic; counting "assigned and never read" finds
the missing `if`.

## The allowlist is the triage, not an exemption

Every name below was read. Most are a return value a caller genuinely
does not want, and two are the stranded half of a method that was
CORRECTLY REPLACED -- where the comment beside the dead variable is the
one explaining why the new method is better. Those are the pleasant
kind: the fix landed and the declaration did not.

They are listed rather than filtered by a rule, because the whole value
of this check is that the signal is rare. A dead variable left
unexplained is noise, and enough noise turns the tell that found `0601`
back into a thing nobody looks at.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from sql_call_graph import load, clean  # noqa: E402

# (function, variable): why it is fine. Read before adding to this.
KNOWN = {
    # Leftovers from a method that was replaced, and replaced correctly.
    # The comment beside each one explains the better method that made
    # the variable redundant.
    ('app.build_revenue_schedule', 'v_from'):
        'the naive per-period allocation; the cumulative one supersedes it',
    ('public.settlement_discount_available', 'v_total'):
        'the discount is on the balance, not the total -- see the comment',

    # Looked up beside two that matter and never needed: there are no
    # org-level AR/AP columns, only per-contact overrides, and posting
    # resolves 1210/2110 by code.
    ('public.create_organization', 'v_ar_id'): 'nothing stores an org AR default',
    ('public.create_organization', 'v_ap_id'): 'nothing stores an org AP default',

    # `app.custom_fields_guard.v_id` used to be here, described as "casts
    # to validate, discards the result". That was never true: the cast
    # validates AND the value is then looked up --
    # `execute ... into v_ok using v_id, new.org_id`. The entry existed
    # only because this gate could not see through `using`, which is
    # fixed below. An allowlist entry is a decision somebody made; this
    # one was a false positive wearing a reason.

    # A return value nothing needs.
    ('public.import_opening_balances', 'v_entry_id'): 'the journal id is not used',

    # Demo seeding. These call a real function for its effect and drop
    # what it returns.
    ('app.demo_crm_sinar', 'v_l1'): 'demo seed',
    ('app.demo_amanah_time', 'v_inv'): 'demo seed',
    ('app.demo_legal_guaman', 'v_inv2'): 'demo seed',
    ('app.demo_warung', 'v_dapur'): 'demo seed',
    ('app.demo_warung', 'v_kshift'): 'demo seed',
    ('app.demo_warung', 'v_wshift'): 'demo seed',
    ('app.demo_time_sinar', 'v_inv'): 'demo seed',
    ('app.demo_pos_sale_sinar', 'v_cash'): 'demo seed',
}


def discarded(rows):
    """Every (function, variable) assigned in the body and never read."""
    out = []
    for r in rows:
        body = clean(r['src'])
        m = re.search(r'\bdeclare\b(.*?)\bbegin\b', body, re.S | re.I)
        if not m:
            continue
        decls, rest = m.group(1), body[m.end():]
        names = set()
        for chunk in decls.split(';'):
            dm = re.match(r'\s*([a-z_][a-z0-9_]*)\s', chunk, re.I)
            if dm:
                names.add(dm.group(1).lower())

        low = rest.lower()
        for n in sorted(names):
            assigned = read = 0
            for mm in re.finditer(rf'\b{re.escape(n)}\b', low):
                after = low[mm.end():mm.end() + 40]
                before = low[max(0, mm.start() - 220):mm.start()]
                if re.match(r'\s*:=', after):
                    assigned += 1
                    continue
                # An `into` list: only names and commas between the
                # `into` and this occurrence.
                #
                # `using` has to be excluded explicitly, and it is not a
                # nicety: `execute ... into v_a using v_b, v_c` leaves
                # `v_a using ` between the `into` and `v_b`, which is
                # nothing but names and spaces and so read as an `into`
                # list. Every argument passed to a dynamic statement was
                # therefore reported as written and never read --
                # `app.attachment_is_evidence` was the first function to
                # use that form and the gate called both its arguments
                # dead.
                tail = before.rsplit(' into ', 1)
                if (len(tail) == 2
                        and re.fullmatch(r'[\sa-z0-9_,]*', tail[1])
                        and not re.search(r'\busing\b', tail[1])):
                    assigned += 1
                    continue
                read += 1
            if assigned and not read:
                line = next((ln.strip() for ln in rest.splitlines()
                             if re.search(rf'\b{n}\b', ln.lower())), '')
                out.append((f"{r['sch']}.{r['name']}", n, line[:78]))
    return out


def main() -> int:
    if len(sys.argv) < 2:
        print('usage: check_discarded_values.py <database-url>',
              file=sys.stderr)
        return 2
    try:
        rows = load(sys.argv[1])
    except RuntimeError as e:
        print(str(e), file=sys.stderr)
        return 2

    found = discarded(rows)
    new = [(fn, var, line) for fn, var, line in found if (fn, var) not in KNOWN]
    gone = [k for k in KNOWN if k not in {(f, v) for f, v, _ in found}]

    if gone:
        print('These are in the allowlist and no longer in the schema.')
        print('Take them out of KNOWN so the list stays a list of real')
        print('decisions rather than of old ones:')
        print()
        for fn, var in sorted(gone):
            print(f'    {fn}  {var}')
        return 1

    if not new:
        print(f'ok   no value is computed and thrown away '
              f'({len(KNOWN)} known, each with a reason)')
        return 0

    print('A value computed in a function body and never read.')
    print()
    print('Usually nothing. Sometimes the whole check somebody meant to')
    print('write -- `0601` was exactly this, and the variable held the')
    print('row kind that decided what a caller could see.')
    print()
    for fn, var, line in new:
        print(f'    {fn}')
        print(f'        {var}   <-  {line}')
    print()
    print('Read it. If it is fine, add it to KNOWN with the reason.')
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
