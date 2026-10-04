#!/usr/bin/env python3
"""Every assertion file must say something when it passes.

    python3 scripts/check_counted_assertions.py

`run_locally.sh` counts assertions that RAN, by counting the
`NOTICE:  ok ` lines psql prints. That count is the suite's only defence
against an assertion that silently stops being reached — a fixture moves,
a branch is never entered, and 383 files still report green over fewer
checks than yesterday.

A file written entirely in the OTHER idiom contributes nothing to it:

    if <the bad thing> then
      raise exception '<what went wrong>';
    end if;

That asserts perfectly well. It just says nothing on success, so a
skipped assertion inside it cannot move the number, and the floor in
`run_locally.sh` cannot see the file at all.

This gate does not forbid the bare form — 137 sites use it as a "this
should have been refused" marker inside a handler, which is the right
shape there. It forbids a file in which NOTHING is countable, and holds
the count of such files as a ratchet that may only fall.

## What this does NOT prove

That a file with a countable source actually runs it. `pg_temp.check_eq`
inside a helper function nobody calls reads as countable here and
contributes nothing at runtime. The runtime floor in `run_locally.sh` is
what catches that; this gate catches the narrower thing of a file that
could not contribute even in principle. Two mechanisms, neither
sufficient alone, and saying so is the point — `undocumented(db)`
returning 2 rather than 0 on a failed query is the same idea.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TESTS = ROOT / "supabase" / "tests"

#: What the runner itself runs: `supabase/tests/*.sql` less the
#: underscore-prefixed includes. Taken from ci.yml's own
#: `ls supabase/tests/*.sql | grep -cv '/_'` so the two cannot drift.
def assertion_files() -> list[pathlib.Path]:
    return sorted(f for f in TESTS.glob("*.sql") if not f.name.startswith("_"))


#: Empty, and it is a RATCHET AT ZERO rather than an empty list nobody
#: filled in. All five files that were written entirely in the bare-raise
#: idiom have been converted:
#:
#:   matter_on_a_document.sql     +19  check_eq / check_true
#:   scan_inbox.sql               +24  check_eq / check_true, and two
#:                                     refusal markers that keep their
#:                                     shape and tick in their handler
#:   attachment_content_hash.sql  +13  check_true on the catalog shapes
#:   tenant_foreign_keys.sql      +14  the probe counters became exact
#:                                     check_eq, not floors
#:   search_path.sql               +3  plain `raise notice 'ok ...'`,
#:                                     because that file has NO
#:                                     transaction and does not include
#:                                     _helpers.sql -- adding both to a
#:                                     read-only catalog test to gain a
#:                                     helper is a worse trade than a
#:                                     notice that cannot change what is
#:                                     asserted
#:
#: Every converted condition was then mutated, because converting a
#: comparison by hand is where an inversion hides and a green suite does
#: not show one. 67 mutants, 67 killed, controls clean.
#:
#: An entry here is still honoured, so a file that genuinely cannot tick
#: can be excused with a reason. But the floor is zero, and a zero floor
#: is the only kind nobody has to remember to lower.
UNCOUNTED: dict[str, str] = {}

def strip_comments(sql: str) -> str:
    """`--` to end of line, except inside a string literal.

    Needed because a comment NAMING the helper would otherwise make an
    uncounted file look counted — the mistake this repository has now
    made six times in other guises.
    """
    out, i, n, quoted = [], 0, len(sql), False
    while i < n:
        c = sql[i]
        if quoted:
            out.append(c)
            if c == "'":
                quoted = False
            i += 1
        elif c == "'":
            quoted = True
            out.append(c)
            i += 1
        elif sql.startswith("--", i):
            j = sql.find("\n", i)
            i = n if j < 0 else j
        else:
            out.append(c)
            i += 1
    return "".join(out)


#: A CALL of a helper that raises `ok` on success. `(?<!function )` keeps
#: a definition from counting as a use.
CALL = re.compile(r"(?<!function )pg_temp\.(check_\w+)\s*\(")

#: Or the notice written out by hand, which is what the refusal-marker
#: shape does in its handler.
NOTICE = re.compile(r"raise\s+notice\s+'ok\b")


def counted_sources(sql: str) -> int:
    """How many places in this file can print a `NOTICE:  ok ` line."""
    bare = strip_comments(sql)
    return len(CALL.findall(bare)) + len(NOTICE.findall(bare))


def uncounted(files: list[pathlib.Path]) -> list[str]:
    return [f.name for f in files if counted_sources(f.read_text()) == 0]


#: A floor under how many assertion files the sweep must have FOUND.
#:
#: This gate shipped without one and passed over an empty
#: `supabase/tests`, printing "every one of 0 assertion files says
#: something when it passes". Found by a sweep that ran every gate in a
#: tree with the source directories emptied -- and worth recording that
#: the gate's own self-test DID catch it (`test_it_looks_at_the_whole_suite`
#: asserts more than 300), so CI was covered while the gate alone was
#: not. A gate that only holds when its test runs beside it is weaker
#: than it reads.
#:
#: 383 files today. Well below that: this guards against the directory
#: moving, not against a file being added or removed.
LEAST_FILES = 300


def run(files: list[pathlib.Path] | None = None,
        reviewed: dict[str, str] | None = None) -> int:
    # Only the DEFAULT scope is floored. The self-tests feed two or three
    # files on purpose, and a floor of 300 over a fixture of two is not a
    # positive control, it is a broken test.
    swept_the_real_suite = files is None
    files = assertion_files() if files is None else files
    reviewed = UNCOUNTED if reviewed is None else reviewed

    if swept_the_real_suite and len(files) < LEAST_FILES:
        print("This sweep found %d assertion file(s) in %s, and there were "
              "%d or more when it was written. Either the directory moved "
              "or it is being read from the wrong place -- and a sweep with "
              "nothing to look at reports exactly what a clean suite "
              "reports." % (len(files), TESTS, LEAST_FILES), file=sys.stderr)
        return 2

    found = uncounted(files)

    problems = []
    for name in found:
        if name not in reviewed:
            problems.append(
                "%s prints nothing when it passes: no `pg_temp.check_*` "
                "call and no `raise notice 'ok ...'`. A skipped assertion "
                "in it cannot move the assertion count in "
                "run_locally.sh, so the suite's only guard against an "
                "assertion that quietly stops being reached does not cover "
                "this file. Assert with the helpers in _helpers.sql — and "
                "if the condition is converted by hand, mutate it "
                "afterwards, because an inverted comparison still reads "
                "green." % name)

    for name in sorted(reviewed):
        if name not in found:
            if name not in {f.name for f in files}:
                problems.append(
                    "%s is in UNCOUNTED but is not an assertion file any "
                    "more. Drop the entry." % name)
            else:
                problems.append(
                    "%s is in UNCOUNTED but now prints on success. Drop "
                    "the entry and let the ratchet fall — an excuse "
                    "nobody prunes is not evidence." % name)

    if problems:
        print("Counted assertions:\n", file=sys.stderr)
        for problem in problems:
            print("  %s\n" % problem, file=sys.stderr)
        return 1

    if not found and not reviewed:
        print("every one of %d assertion files says something when it "
              "passes; the ratchet is at zero." % len(files))
    else:
        print("%d assertion file(s) print nothing on success; every one is "
              "reviewed, and the ratchet may only fall." % len(found))
    return 0


def main() -> int:
    return run()


if __name__ == "__main__":
    raise SystemExit(main())
