#!/usr/bin/env python3
"""The assertion floor has one definition, and both runners read it.

    python3 scripts/check_assertion_floor.py

`supabase/tests/assertion_floor` holds the number of `NOTICE:  ok ` lines
the SQL suite is known to print. Two things read it:
`supabase/tests/run_locally.sh` and the "Run the database assertions"
step in `.github/workflows/ci.yml`.

It is worth a gate because every way this arrangement can rot is silent:

  * **A second copy of the number.** The floor lived in `run_locally.sh`
    alone, and CI -- the authoritative runner -- counted nothing. Copy
    the number into ci.yml and the two drift the first time one is
    raised, which shows up as a green CI over a stale floor.
  * **The grep drifting from what the helpers print.** The count is of
    `NOTICE:  ok `. Change `_helpers.sql` to say anything else and the
    count goes to zero -- and a floor compared against zero is a floor
    that passes nothing and fails everything, or worse, a count that
    nobody looks at.
  * **Someone piping psql again.** CI's step runs under `bash -e` with NO
    `pipefail`, so `psql ... | grep` hands the shell grep's status and a
    FAILING ASSERTION READS AS A PASS. That is why the step captures
    output in a command substitution. A later simplification back to a
    pipe would be invisible: the build stays green, which is exactly what
    it would look like if everything were fine.
  * **An unreadable floor file.** `grep -Ex '[0-9]+'` over a malformed
    file yields the empty string, and `[ "$n" -lt "" ]` is not a
    comparison that fails loudly. Both readers check for a bare integer
    before using it.

So this asserts the plumbing, not the number. The number's own guard is
the comparison in `run_locally.sh` and the zero-check in CI.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FLOOR_FILE = ROOT / "supabase" / "tests" / "assertion_floor"
RUNNER = ROOT / "supabase" / "tests" / "run_locally.sh"

#: The SECOND floor, on the same pattern and for the same reason.
#: `deno test` over a file that defines no tests prints
#: "ok | 0 passed | 0 failed" and exits 0, so a `Deno.test` block that
#: stopped registering takes its assertions with it and all 40 of CI's
#: per-file steps stay green.
DENO_FLOOR_FILE = (ROOT / "supabase" / "functions" / "_local_check"
                   / "deno_test_floor")
DENO_RUNNER = (ROOT / "supabase" / "functions" / "_local_check"
               / "check_locally.sh")
DENO_STEP = "Count the edge tests that ran"

#: `supabase start` walks `supabase/functions/` and, for every entry it
#: finds, reaches for `<entry>/index.ts`. A DIRECTORY with no index.ts is
#: skipped quietly -- `_shared` and `_local_check` have always been
#: there. A plain FILE is not: the stat returns "not a directory", the
#: CLI does not expect that, and it dies with
#:
#:     BadResource: FileSystem.access (.../deno_test_floor/index.ts)
#:
#: naming a path that does not exist and a function nobody wrote. The
#: edge-test floor was committed there and took `supabase start` down on
#: the next run -- the SQL assertion job, which is the one job whose red
#: is this project's real failure signal.
FUNCTIONS_DIR = ROOT / "supabase" / "functions"
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"

#: What psql prints for `raise notice 'ok   <label>'`, and therefore what
#: both runners must count. Two spaces after NOTICE:, one after ok.
PATTERN = "NOTICE:  ok "

#: How either runner is allowed to get the number: by reading the file.
READS_THE_FILE = re.compile(r"grep -Ex '\[0-9\]\+' [^\n]*assertion_floor")

#: The CI step whose loop does the counting.
STEP = "Run the database assertions"


def floor_value(text: str) -> str | None:
    """The bare integer in the floor file, if there is exactly one."""
    found = [ln for ln in text.splitlines() if re.fullmatch(r"[0-9]+", ln)]
    return found[0] if len(found) == 1 else None


def ci_step(text: str, name: str = STEP) -> str:
    """The body of a step, by name rather than by line number."""
    at = text.find("- name: %s" % name)
    if at < 0:
        return ""
    nxt = text.find("\n      - name:", at + 1)
    return text[at:nxt if nxt > 0 else len(text)]


def problems(floor_text: str | None = None, runner: str | None = None,
             workflow: str | None = None,
             helpers: str | None = None) -> list[str]:
    """Every argument defaults to the real file, and is fed in the tests.

    Fed rather than monkeypatched so the failure MESSAGES are exercised:
    a gate whose only tested path is the passing one tells you nothing
    about what it says when it fires, and what it says is the whole
    remedy.
    """
    out: list[str] = []

    if floor_text is None and not FLOOR_FILE.exists():
        return ["%s does not exist. It is where the number lives."
                % FLOOR_FILE.relative_to(ROOT)]

    floor_text = FLOOR_FILE.read_text() if floor_text is None else floor_text
    value = floor_value(floor_text)
    if value is None:
        out.append(
            "supabase/tests/assertion_floor must hold exactly one bare "
            "integer on a line of its own; both readers anchor on "
            "`^[0-9]+$` and a malformed file reads as the EMPTY STRING, "
            "which is not a floor and does not fail like one.")
    elif int(value) <= 0:
        out.append(
            "the floor is %s. A floor at zero passes any suite at all, "
            "including one where every assertion stopped running." % value)

    runner = RUNNER.read_text() if runner is None else runner
    if not READS_THE_FILE.search(runner):
        out.append(
            "run_locally.sh does not read supabase/tests/assertion_floor. "
            "The number has one definition or it drifts the first time it "
            "is raised.")
    if re.search(r"ASSERTION_FLOOR=\"?\$?\{?IAK_ASSERTION_FLOOR:-[0-9]",
                 runner):
        out.append(
            "run_locally.sh hardcodes a floor as its default instead of "
            "reading the file. That is the second copy this gate exists "
            "to prevent.")
    if PATTERN not in runner:
        out.append(
            "run_locally.sh does not count %r. That is what psql prints "
            "for the helpers' success notice." % PATTERN)

    step = ci_step(WORKFLOW.read_text() if workflow is None
                   else workflow)
    if not step:
        out.append(
            'ci.yml has no step named "%s". This gate finds the counting '
            "loop by that name; renaming the step without updating this "
            "makes the gate check nothing." % STEP)
    else:
        if not READS_THE_FILE.search(step):
            out.append(
                '"%s" does not read supabase/tests/assertion_floor.' % STEP)
        if PATTERN not in step:
            out.append('"%s" does not count %r.' % (STEP, PATTERN))
        # `\|(?!\|)` and not `\|`: the capture line ends in `|| {`, and
        # a bare `\|` matches the first bar of a LOGICAL OR. The first
        # version of this gate failed on the very step it describes.
        if re.search(r"psql \"\$DB\"[^\n|]*\|(?!\|)", step):
            out.append(
                '"%s" PIPES psql. That step runs under `bash -e` with no '
                "`pipefail`, so the shell takes the exit status of the "
                "right-hand side and a failing assertion reads as a pass. "
                "Capture the output in a command substitution and keep "
                "psql's own status, the way it does now." % STEP)
        if "asserted=0" not in step:
            out.append('"%s" does not initialise its counter.' % STEP)
        # Reading the floor and COMPARING it are different things, and a
        # step that reads it to print it is indistinguishable from one
        # that gates on it unless this is checked. It shipped read-only
        # on purpose for one run, to measure CI's count before gating on
        # it; that measurement came back 14330 against a local 14330, so
        # the comparison is now expected to be there.
        if not re.search(r'"\$asserted"\s+-lt\s+"\$floor"', step):
            out.append(
                '"%s" reads the floor but never compares the count '
                "against it. Printing a number nobody checks is not a "
                "floor. The comparison was added once run 2239 measured "
                "CI at the same 14330 the local runner reports." % STEP)

    helpers = ((ROOT / "supabase" / "tests" / "_helpers.sql").read_text()
               if helpers is None else helpers)
    if "raise notice 'ok" not in helpers:
        out.append(
            "_helpers.sql no longer says `raise notice 'ok ...'`, so "
            "nothing either runner counts is being printed. The count "
            "would read zero, which looks like a broken runner rather "
            "than a renamed notice.")

    out += deno_problems()
    out += functions_dir_problems()
    return out


def functions_dir_problems(entries: list[str] | None = None) -> list[str]:
    """Nothing but directories sits directly under supabase/functions/.

    Not a question about floors, and here because this is the gate that
    would have caught it: the file it exists to protect was put in the
    one directory where a loose file breaks the local stack. The rule is
    the general one rather than "do not put the floor there", because the
    next loose file will be a README or a `.gitkeep` and will fail
    identically -- with a message naming neither.
    """
    if entries is None:
        if not FUNCTIONS_DIR.is_dir():
            return ["%s is not a directory." % FUNCTIONS_DIR.relative_to(ROOT)]
        loose = sorted(p.name for p in FUNCTIONS_DIR.iterdir()
                       if not p.is_dir())
    else:
        loose = sorted(entries)
    if not loose:
        return []
    return [
        "supabase/functions/ holds %s directly: %s. `supabase start` "
        "reaches for `<entry>/index.ts` for every entry it finds there. "
        "A directory without one is skipped quietly; a FILE makes the "
        "stat fail with `BadResource: FileSystem.access` naming a path "
        "nobody wrote, and the local stack never comes up -- which takes "
        "the SQL assertion job down with it. Put it in a subdirectory; "
        "`_local_check/` is where the edge-test floor ended up."
        % ("a file" if len(loose) == 1 else "files", ", ".join(loose))]


def deno_problems(floor_text: str | None = None,
                  runner: str | None = None,
                  workflow: str | None = None) -> list[str]:
    """The same questions of the edge-test floor.

    Separate function, same shape, because the two floors fail the same
    ways: a second copy of the number, a runner that hardcodes one, a
    piped `deno test` whose status the shell throws away, and -- the one
    this floor actually got wrong first -- a FILE LIST that covers less
    than it claims.
    """
    out: list[str] = []
    if floor_text is None and not DENO_FLOOR_FILE.exists():
        return ["%s does not exist. It is where the edge-test number "
                "lives." % DENO_FLOOR_FILE.relative_to(ROOT)]
    floor_text = (DENO_FLOOR_FILE.read_text() if floor_text is None
                  else floor_text)
    value = floor_value(floor_text)
    if value is None:
        out.append(
            "supabase/functions/_local_check/deno_test_floor must hold "
            "exactly one bare integer on a line of its own; both "
            "readers anchor on "
            "`^[0-9]+$` and a malformed file reads as the EMPTY STRING.")
    elif int(value) <= 0:
        out.append("the edge-test floor is %s, which passes a suite where "
                   "every test stopped registering." % value)

    runner = DENO_RUNNER.read_text() if runner is None else runner
    if "deno_test_floor" not in runner:
        out.append(
            "check_locally.sh does not read "
            "supabase/functions/_local_check/deno_test_floor. The "
            "number has one definition or it drifts the first time it "
            "is raised.")

    step = ci_step(WORKFLOW.read_text() if workflow is None else workflow,
                   DENO_STEP)
    # Comments stripped before the two checks below, and not for tidiness:
    # that step's own comments QUOTE both things they forbid -- the
    # `deno test ... | tee` it must not do and the
    # `supabase/functions/...` glob it used to do -- while explaining
    # them. The first version of these assertions matched the explanation
    # and reported both as live faults. A gate that reads its subject's
    # prose is the mistake this repository has made more often than any
    # other, and it was made here while writing a gate about it.
    code = re.sub(r"(?<!\$)#[^\n]*", "", step)
    # And single-quoted strings, for the same reason one layer down: the
    # step builds its file list with
    #     grep -oE 'deno test( +--[a-z-]+)* +...' ci.yml | awk ...
    # so the literal `deno test` sits inside a grep PATTERN that is
    # piped to awk. The pipe check matched that and called it a piped
    # `deno test`. Three false positives in these assertions, all the
    # same family: a string that MENTIONS the thing is not the thing.
    #
    # But ONLY for the pipe check. The glob this gate forbids legitimately
    # lives inside a quoted grep pattern, so blanking quotes blinds that
    # one -- which it did, and the mutant putting the narrow glob back
    # went unflagged until the two checks were given different text. One
    # "cleaned" string cannot answer two different questions.
    runnable = re.sub(r"'[^'\n]*'", "''", code)
    if not step:
        out.append(
            'ci.yml has no step named "%s". This gate finds the counting '
            "step by that name." % DENO_STEP)
    else:
        if "deno_test_floor" not in step:
            out.append('"%s" does not read '
                       "supabase/functions/_local_check/deno_test_floor."
                       % DENO_STEP)
        if not re.search(r'"\$ran"\s+-lt\s+"\$floor"', step):
            out.append('"%s" reads the floor but never compares the count '
                       "against it." % DENO_STEP)
        if re.search(r"deno test[^\n|]*\|(?!\|)", runnable):
            out.append(
                '"%s" PIPES `deno test`. Under `bash -e` with no '
                "`pipefail` the shell takes the right-hand side's status "
                "and a failing test reads as a pass." % DENO_STEP)
        # The bug this floor shipped with for ten minutes: a list that
        # covered 37 of 40 files, so the floor was a floor over a subset.
        if "supabase/functions/[^ ]*_test" in code:
            out.append(
                '"%s" takes its file list from a '
                "`supabase/functions/...` glob, which drops the three "
                "test files outside that directory -- two under "
                "cloudflare/ and one under scripts/, one of them a .js "
                "file. The floor would then cover a SUBSET and pass. Read "
                "the list off the `deno test` command lines, as "
                "check_locally.sh does." % DENO_STEP)
        if "deno test" not in runnable:
            out.append('"%s" does not run `deno test`.' % DENO_STEP)
    return out


def run() -> int:
    found = problems()
    if found:
        print("Assertion floor:\n", file=sys.stderr)
        for problem in found:
            print("  %s\n" % problem, file=sys.stderr)
        return 1
    value = floor_value(FLOOR_FILE.read_text())
    print("the assertion floor is %s, defined once and read by both "
          "run_locally.sh and ci.yml." % value)
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
