#!/usr/bin/env python3
"""A migration whose last statement has no semicolon, which psql allows.

`0743`'s body was extracted from `0739` programmatically and the
extraction stopped at the closing `$function$`, dropping the statement's
`;`. `psql -f` applied it and printed `CREATE FUNCTION` anyway, because
psql sends whatever is left in its buffer at EOF. So the tool that
applies migrations cannot see this defect, and nor can a green CI run.

It was caught by `scripts/mutate_sql.py`, whose pattern for a function
block requires a trailing `;` -- the stricter tool noticed what the real
one accepted. This gate exists so the next one is caught by something
that runs on every push instead of by luck.

It is latent rather than live, and the distinction is worth keeping
straight: migrations are applied ONE FILE AT A TIME, so nothing is
broken today. A tool that ever concatenated them would produce

    end $function$ CREATE TABLE ...

and fail with a syntax error pointing at the wrong migration.
`supabase/tests/run_locally.sh` already concatenates them to take an md5
of the set, which is harmless, and the shape is one step away from not
being.

Two structural questions, both yes-or-no, neither needing judgement:

  * does the last line that is not blank and not a comment end in `;`?
  * does every dollar-quote tag appear an even number of times, so no
    function body is left open?

The second is what catches a file truncated inside a body, where the
last code line may well end in a semicolon and still be broken.
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MIGRATIONS = ROOT / "supabase" / "migrations"

# A floor, so a run that found no migrations cannot report a clean sweep.
LEAST_MIGRATIONS = 600

# `0540_a_counter_sale_of_dated_stock.sql` ends `end;\n$function$` with no
# semicolon. It is APPLIED, and `supabase/migrations/` is append-only --
# CLAUDE.md's first rule -- so it is named here rather than fixed. If it
# ever needs to matter, a later migration restates the function.
#
# Nothing else belongs on this list. A migration not yet applied is
# fixed, not excused.
ALLOWED = {
    '0540_a_counter_sale_of_dated_stock.sql':
        'applied before this gate existed; append-only, so not edited',
}

# Proof the gate is looking. Each must be reported by `faults`.
CANARIES = {
    'no terminator at all': "create table x (a int)\n",
    'terminator missing after a function body':
        "create function f() returns int as $fn$ begin return 1; end $fn$\n",
    'a body left open': "create function f() returns int as $fn$ begin\n",
}

# And the shape that must NOT be reported, because the first version of
# this gate reported nine of them and all nine were correct code.
NOT_FAULTS = {
    'a double dash inside the prose of a comment on':
        "comment on function f() is\n  'kept -- what was written off.';\n",
    'an escaped quote before a double dash':
        "comment on function f() is 'it''s fine -- really';\n",
}

TAG = re.compile(r"\$[a-z_0-9]*\$", re.I)


def drop_inline_comment(line: str) -> str:
    """`line` up to its first `--` that is OUTSIDE a string literal.

    The naive `re.sub(r"--.*$", "", line)` reported NINE migrations as
    unterminated on this gate's first run, every one of them a false
    positive, because their last line is a `comment on ...` whose prose
    contains a double dash:

        'The lines are kept -- they are what was written off.';

    Stripping from that `--` throws away the closing quote and the
    semicolon with it. A gate that flags correct code is a gate somebody
    turns off, so the shape is pinned in the tests as must-not-report.

    `''` inside a literal is an escaped quote, not the end of one.
    """
    out = []
    i = 0
    in_string = False
    while i < len(line):
        pair = line[i:i + 2]
        if in_string:
            if pair == "''":
                out.append(pair)
                i += 2
                continue
            if line[i] == "'":
                in_string = False
            out.append(line[i])
            i += 1
            continue
        if line[i] == "'":
            in_string = True
            out.append(line[i])
            i += 1
            continue
        if pair == "--":
            break
        out.append(line[i])
        i += 1
    return "".join(out).strip()


def last_code_line(text: str) -> str:
    """The last line that is not blank and not wholly a comment.

    Trailing block comments are dropped first: `0722` ends with a ruled
    line inside one, and six other migrations end in `--` prose whose
    statement was terminated properly further up.
    """
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    for line in reversed(text.split("\n")):
        bare = line.strip()
        if not bare or bare.startswith("--"):
            continue
        return drop_inline_comment(bare)
    return ""


def unbalanced_tags(text: str) -> list[str]:
    """Dollar-quote tags appearing an odd number of times.

    Counted on the text with line comments removed, because `0165` and
    others discuss `$$` in prose, and a tag mentioned once in a comment
    would read as an unclosed body.
    """
    code = re.sub(r"--.*$", "", text, flags=re.M)
    code = re.sub(r"/\*.*?\*/", "", code, flags=re.S)
    counts: dict[str, int] = {}
    for tag in TAG.findall(code):
        counts[tag.lower()] = counts.get(tag.lower(), 0) + 1
    return sorted(t for t, n in counts.items() if n % 2)


def faults(text: str) -> list[str]:
    """What is wrong with one migration's text, if anything."""
    out = []
    last = last_code_line(text)
    if not last:
        out.append("holds no SQL at all")
    elif not last.endswith(";"):
        out.append(f"last statement is not terminated: ...{last[-48:]!r}")
    odd = unbalanced_tags(text)
    if odd:
        out.append(f"dollar-quote tag(s) left open: {', '.join(odd)}")
    return out


def offenders(files: list[pathlib.Path] | None = None) -> list[str]:
    files = sorted(MIGRATIONS.glob("*.sql")) if files is None else files
    bad = []
    for path in files:
        if path.name in ALLOWED:
            continue
        for fault in faults(path.read_text()):
            bad.append(f"{path.name}: {fault}")
    return bad


def main() -> int:
    files = sorted(MIGRATIONS.glob("*.sql"))

    # Canaries before the floor: a matcher that has stopped working
    # reports an empty list, which reads exactly like a pass.
    for label, snippet in CANARIES.items():
        if not faults(snippet):
            print(f"::error::the canary '{label}' was not reported; this "
                  f"gate is no longer looking at anything")
            return 1

    # And the allowlist has to still be describing something real. An
    # entry for a file that has been fixed, renamed or removed is an
    # excuse nobody is using, and the next person reads it as a rule.
    for name in ALLOWED:
        path = MIGRATIONS / name
        if not path.exists():
            print(f"::error::{name} is on the allowlist and does not exist; "
                  f"remove the entry")
            return 1
        if not faults(path.read_text()):
            print(f"::error::{name} is on the allowlist but is now clean; "
                  f"remove the entry so the gate covers it")
            return 1

    for label, snippet in NOT_FAULTS.items():
        if faults(snippet):
            print(f"::error::'{label}' was reported as a fault, and it is "
                  f"correct SQL; the comment stripper has broken again")
            return 1

    if len(files) < LEAST_MIGRATIONS:
        print(f"::error::only {len(files)} migrations were found, fewer than "
              f"the floor of {LEAST_MIGRATIONS}; the directory was not read")
        return 1

    bad = offenders(files)
    if bad:
        print("::error::a migration's SQL does not end where it should. "
              "psql -f flushes its buffer at EOF, so it applies anyway and "
              "says nothing -- but a tool that concatenates migrations runs "
              "the next file's first statement into this one:")
        for line in bad:
            print(f"  {line}")
        print("\nTerminate the last statement with `;`, or close the body's "
              "dollar quote. If the file is already applied, say so in "
              "ALLOWED in this script with the reason, and restate the "
              "function in a LATER migration instead of editing it.")
        return 1

    print(f"::notice::{len(files)} migrations checked, every one ends in a "
          f"terminated statement with no open dollar quote "
          f"({len(ALLOWED)} allowed by name)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
