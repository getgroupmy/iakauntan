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


def ci_step(text: str) -> str:
    """The body of the counting step, by name rather than by line number."""
    at = text.find("- name: %s" % STEP)
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

    helpers = ((ROOT / "supabase" / "tests" / "_helpers.sql").read_text()
               if helpers is None else helpers)
    if "raise notice 'ok" not in helpers:
        out.append(
            "_helpers.sql no longer says `raise notice 'ok ...'`, so "
            "nothing either runner counts is being printed. The count "
            "would read zero, which looks like a broken runner rather "
            "than a renamed notice.")
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
