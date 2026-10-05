#!/usr/bin/env python3
"""Which SQL function to mutate next, ranked rather than guessed.

    python3 scripts/mutation_targets.py [how-many]

`scripts/mutate_sql.py` breaks one function on purpose and reports which
assertions notice. Choosing WHICH function was guesswork until
`public.transfer_between_matters` was picked on three signals and came
back with the worst score measured -- 19 mutants, EIGHT survived, one of
them a real defect. The three signals were:

  * it had been redefined FIVE times, so five chances for a behaviour to
    drift away from the assertions written for the first version;
  * exactly ONE test file reached it, so no second file could cover
    what the first missed -- the per-file-score trap in reverse; and
  * what it governs is regulated.

The first two are countable. This ranks every function that MOVES MONEY
by them, so the next session does not have to guess either. It is a
reporting tool and not a gate: it is never red, nothing in CI runs it,
and it is deliberately not named `check_*` so `check_sweeps_look.py`
does not take it for one.

Read from the LATEST definition of each function. `0530`, `0691` and
`0739` write `CREATE OR REPLACE FUNCTION` in upper case, and a
case-sensitive grep for the lower-case form named `0446` as the latest
`app.calc_pcb` and was wrong by RM6,000 of relief.

The ranking is a prompt, not a verdict. A function with one calling file
may be perfectly covered by it -- `record_group_payment` scored 15 of 17
with no gaps across three files -- and the only way to know is to run
the mutants.

**The file count is a LOWER BOUND and is not a coverage claim.** SQL
here is reached three ways and this tool can follow two of them:

  * named directly in a test -- counted;
  * called by something named in a test -- counted, transitively, which
    the first version of this tool did not do and so put four internal
    functions at the top reading as untested;
  * fired by a TRIGGER on an insert or update -- NOT counted, because a
    test fires those by writing a row and never names anything. Such
    functions are marked `fires on <table>` instead of showing a count,
    so a zero is never read as "nothing tests this". `pos_fnb.sql`
    exercises `app.pos_deplete_recipes` thoroughly without mentioning
    it once.

A fourth way exists and is not handled at all: `execute format(...)`
builds a call out of a string, and nothing static will see it.
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MIGRATIONS = ROOT / "supabase" / "migrations"
TESTS = ROOT / "supabase" / "tests"
MUTANTS = TESTS / "mutants"

FUNCTION = re.compile(
    r"create\s+or\s+replace\s+function\s+([a-z_]+\.[a-z_0-9]+)\s*\(", re.I)

# What counts as moving money or stock: the tables an entry lands in, and
# the ledger-posting helpers. A function that writes none of these is not
# what this ranking is for -- a view, a report or a lookup can be wrong
# without anybody's balance being wrong.
MOVES = (
    "app.create_gl_entry_internal",
    "insert into public.gl_lines",
    "insert into public.gl_entries",
    "insert into public.stock_movements",
    "insert into public.client_account_transactions",
    "insert into public.receipts",
    "insert into public.purchase_payments",
    "public.post_receipt",
    "public.post_client_transaction",
    "public.post_purchase_payment",
)

# Every signature above has to match SOMETHING, or the ranking narrows
# without saying so. The first version of this list contained
# `app.post_journal`, which exists nowhere in the repository -- the name
# was invented. The real helper is `app.create_gl_entry_internal`, which
# TWENTY-NINE functions call, so the single most important signature in
# the list was dead and the ranking covered 26 functions where it should
# have covered far more. That is the same failure as a gate whose
# matcher has stopped matching, in a tool built to find exactly that,
# and it went unnoticed through five functions' worth of use because the
# ones it DID rank were real.
LEAST_PER_SIGNATURE = 1


def definitions() -> dict[str, list[str]]:
    """name -> every migration that defines it, in order."""
    out: dict[str, list[str]] = {}
    for path in sorted(MIGRATIONS.glob("*.sql")):
        text = path.read_text()
        for m in FUNCTION.finditer(text):
            out.setdefault(m.group(1).lower(), []).append(path.name)
    return out


def body_of(name: str, where: str) -> str:
    text = (MIGRATIONS / where).read_text()
    m = re.search(r"create\s+or\s+replace\s+function\s+[a-z_]+\."
                  + re.escape(name.split(".", 1)[1]) + r"\s*\(", text, re.I)
    if m is None:
        return ""
    tag = re.search(r"\$([a-z_0-9]*)\$", text[m.start():m.start() + 4000])
    if tag is None:
        return text[m.start():m.start() + 9000]
    o = m.start() + tag.end()
    c = text.find(tag.group(0), o)
    return text[m.start():c if c > 0 else m.start() + 9000]


CALL = re.compile(r"\b([a-z_][a-z_0-9]*)\s*\(", re.I)


def _calls(text: str, known: frozenset[str]) -> set[str]:
    """The known function names `text` calls.

    One pass over the text, intersected with the known names -- not a
    regex per candidate. The first version did the latter and was
    O(functions squared): 1,354 names against 1,354 bodies is 1.8
    million searches, and it ran past two minutes without finishing.
    """
    return {m.group(1).lower() for m in CALL.finditer(text)} & known


def call_graph(defs: dict[str, list[str]]) -> dict[str, set[str]]:
    """bare name -> the bare names of functions that CALL it.

    Needed because the first version of this ranking counted only test
    files that NAME the function, and put four internal functions at the
    top with "no test file names it at all" -- which reads as untested
    and was wrong. `app.pos_deplete_recipes` is called by
    `public.complete_pos_sale`, which `pos_fnb.sql` and others exercise
    thoroughly. An internal function reached through a public wrapper is
    covered by whatever covers the wrapper.
    """
    bodies = {name.split(".", 1)[1]: body_of(name, wheres[-1]).lower()
              for name, wheres in defs.items()}
    known = frozenset(bodies)
    called_by: dict[str, set[str]] = {b: set() for b in bodies}
    for caller, body in bodies.items():
        for callee in _calls(body, known):
            if callee != caller:
                called_by[callee].add(caller)
    return called_by


def reachers(bare: str, called_by: dict[str, set[str]]) -> set[str]:
    """`bare` plus every function that reaches it, transitively."""
    seen = {bare}
    stack = [bare]
    while stack:
        here = stack.pop()
        for up in called_by.get(here, ()):
            if up not in seen:
                seen.add(up)
                stack.append(up)
    return seen


def test_calls(known: frozenset[str]) -> dict[str, set[str]]:
    """test file -> the known functions it calls. One pass per file."""
    out = {}
    for path in sorted(TESTS.glob("*.sql")):
        if path.name.startswith("_"):
            continue
        out[path.name] = _calls(path.read_text().lower(), known)
    return out


def callers(bare: str, called_by: dict[str, set[str]],
            per_file: dict[str, set[str]]) -> list[str]:
    """Test files that reach the function, by name or through a caller."""
    names = reachers(bare, called_by)
    return [f for f, called in per_file.items() if called & names]


TRIGGER = re.compile(
    r"create\s+trigger\s+[a-z_0-9]+\s+(.*?)\s+on\s+(?:public\.)?"
    r"([a-z_0-9]+)(.*?)execute\s+(?:function|procedure)\s+"
    r"(?:[a-z_]+\.)?([a-z_0-9]+)\s*\(", re.I | re.S)


def trigger_tables() -> dict[str, set[str]]:
    """trigger-function bare name -> the tables whose DML fires it."""
    out: dict[str, set[str]] = {}
    for path in sorted(MIGRATIONS.glob("*.sql")):
        for m in TRIGGER.finditer(path.read_text()):
            out.setdefault(m.group(4).lower(), set()).add(m.group(2).lower())
    return out


def fired_by(bare: str, called_by: dict[str, set[str]],
             tables: dict[str, set[str]]) -> set[str]:
    """Tables whose DML reaches `bare`, through a trigger function.

    A function is trigger-reached if it, or anything that calls it, is
    wired to a trigger. `app.pos_deplete_recipes` is three steps from an
    `insert into public.pos_sales`, and no test names any of them.
    """
    hit: set[str] = set()
    for name in reachers(bare, called_by):
        hit |= tables.get(name, set())
    return hit


STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')


def measured(known: frozenset[str]) -> set[str]:
    """Bare function names that some mutants file already mutates.

    Read from the FILES' CONTENTS, not their names. The first version
    matched `supabase/tests/mutants/*.py` stems against function names,
    and so could not see `client_money_crossing.py` -- named after the
    test file it runs against, like `bank_rules.py` -- which mutates
    three functions. It reported `pay_from_client_account` as unmeasured
    immediately after 21 mutants had been run against it.

    Each mutant is `m(label, function, old, new, marker)`, so the second
    string argument is the function. Found by splitting on the calls and
    taking the second quoted string of each, rather than by matching a
    layout: the first attempt required `m(` alone on a line, which none
    of these files do, and it recognised nothing but the filenames --
    reporting `pay_from_client_account` as unmeasured immediately after
    21 mutants had been run against it.

    Read with a regex rather than by importing, because these files call
    a global `m` that the harness injects and are not importable alone.

    Intersected with `known`, the real function names, because "the
    second quoted string" is only the function when the LABEL fits on
    one line. Where a label is split across two lines the second string
    is the rest of the label, and where an `old` fragment is split it is
    SQL -- the unfiltered version returned eight lines of payroll
    journal as function names. Intersecting is exact rather than a
    guess about what an identifier looks like.
    """
    if not MUTANTS.is_dir():
        return set()
    names = set()
    for path in MUTANTS.glob("*.py"):
        text = path.read_text()
        for chunk in text.split("\nm(")[1:]:
            found = STRING.findall(chunk)
            if len(found) >= 2:
                names.add(found[1])
        # The stem too, for a file named after its one function.
        names.add(path.stem)
    return names & known


def rank() -> list[tuple]:
    defs = definitions()
    called_by = call_graph(defs)
    done = measured(frozenset(called_by))
    per_file = test_calls(frozenset(called_by))
    tables = trigger_tables()
    rows = []
    for name, wheres in defs.items():
        bare = name.split(".", 1)[1]
        body = body_of(name, wheres[-1]).lower()
        if not any(sig in body for sig in MOVES):
            continue
        files = callers(bare, called_by, per_file)
        fires = fired_by(bare, called_by, tables)
        # A trigger-reached function sorts AFTER the ones this tool can
        # actually count, because a zero there means "not measurable
        # here", not "not tested".
        rows.append((1000 if fires else len(files), -len(wheres), name,
                     wheres[-1], len(wheres), files, sorted(fires),
                     bare in done or name in done))
    # Fewest calling files first, then most redefinitions.
    return sorted(rows)


def dead_signatures() -> list[str]:
    """MOVES entries that match no function at all."""
    defs = definitions()
    bodies = [body_of(n, w[-1]).lower() for n, w in defs.items()]
    return [sig for sig in MOVES
            if sum(1 for b in bodies if sig in b) < LEAST_PER_SIGNATURE]


def main() -> int:
    how_many = int(sys.argv[1]) if len(sys.argv) > 1 else 20

    dead = dead_signatures()
    if dead:
        print("WARNING: these MOVES signatures match no function, so the "
              "ranking below is narrower than it looks:")
        for sig in dead:
            print(f"  {sig!r}")
        print("Fix the name or drop the entry.\n")

    rows = rank()
    unmeasured = [r for r in rows if not r[7]]
    n_trg = sum(1 for r in rows if r[6])
    print(f"{len(rows)} functions move money or stock; "
          f"{len(rows) - len(unmeasured)} already have a mutants file, and "
          f"{n_trg} are reached only by a trigger, where this tool cannot "
          f"count files.\n")
    print(f"{'files':>5}  {'defs':>4}  {'function':46}  latest")
    print(f"{'-'*5}  {'-'*4}  {'-'*46}  {'-'*44}")
    for row in unmeasured[:how_many]:
        n_files, _, name, latest, n_defs, files, fires, _done = row
        shown = '  trg' if fires else f"{n_files:>5}"
        print(f"{shown}  {n_defs:>4}  {name:46}  {latest}")
        if fires:
            print(f"{'':>13}fires on {', '.join(fires)} -- "
                  f"not countable here; look for tests writing those rows")
        elif files:
            print(f"{'':>13}{', '.join(files)}")
        else:
            print(f"{'':>13}(nothing names it and no trigger fires it)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
