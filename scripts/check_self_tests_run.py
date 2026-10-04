#!/usr/bin/env python3
"""Every self-test in scripts/ is run by CI.

    python3 scripts/check_self_tests_run.py

There are 37 `*_test.py` files under `scripts/`, and they are what makes
the gates believable: a gate that is wrong is worse than no gate, because
it is believed. They are run as ordinary workflow steps, one `python3`
line at a time, in a hand-kept list.

A hand-kept list goes stale silently, and this one did on the commit that
added the newest gate: `check_flutter_test_count_test.py` was written,
passed locally, and was never named in `ci.yml`. 36 of 37 were run and
nothing said which one was not. The same shape as the SQL file list --
which has a step asserting its completeness -- and as the edge-function
deploy list, which reads the directory for the same reason.

## Both directions

A missing file means a self-test nobody runs. A name in the workflow with
no file behind it means a step that quietly does nothing useful: the
`python3` call would fail, so that direction is loud -- but it is cheap
to say so here, and it catches a rename where only one end moved.

## Comments are stripped first

`ci.yml` is full of prose naming scripts, including this one. A grep over
the raw text counts a mention in a comment as "run", which is the
`check_counted_assertions` mistake and the mistake the deno floor made
twice in one afternoon: a string that MENTIONS the thing is not the
thing. The names must sit on a line that actually runs python3.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"

#: A self-test CI deliberately does not run, name -> why. Empty, and an
#: empty list here is a claim.
EXEMPT: dict[str, str] = {}

#: A floor under how many self-tests must have been FOUND. The gate
#: expects no offenders, so a clean repository and an empty `scripts/`
#: read the same -- and the second is what a sweep that cannot look
#: reports. 37 today.
LEAST = 25

RUNS = re.compile(r"python3\s+(?:-B\s+)?scripts/(\w+_test\.py)")


def without_comments(text: str) -> str:
    """Blank whole-line `#` comments, keeping line count."""
    return "\n".join(
        "" if line.lstrip().startswith("#") else line
        for line in text.split("\n"))


def problems(on_disk: set[str] | None = None,
             workflow: str | None = None) -> tuple[list[str], int, int]:
    """(problems, found on disk, named by the workflow)."""
    if on_disk is None:
        if not SCRIPTS.is_dir():
            return (["%s is not a directory, so this check could not look. "
                     "That is not the same as finding nothing wrong."
                     % SCRIPTS], 0, 0)
        on_disk = {p.name for p in SCRIPTS.glob("*_test.py")}

    if workflow is None:
        if not WORKFLOW.exists():
            # `relative_to(ROOT)` and not a bare `%s`: nicer to read. But
            # it RAISES for a path outside ROOT, and this gate's own test
            # points WORKFLOW at /nonexistent to reach this branch -- so
            # the fallback is the absolute path rather than a traceback.
            # The same thing happened to check_surface_size.offenders().
            try:
                where = WORKFLOW.relative_to(ROOT)
            except ValueError:
                where = WORKFLOW
            return (["%s does not exist, so this check could not look at "
                     "what CI runs. A sweep with nothing to read reports "
                     "exactly what a clean repository reports."
                     % where], len(on_disk), 0)
        workflow = WORKFLOW.read_text()

    named = set(RUNS.findall(without_comments(workflow)))
    out: list[str] = []

    if len(on_disk) < LEAST:
        out.append(
            "found only %d self-test(s) under scripts/, and there were %d "
            "or more when this was written. A sweep with nothing to look "
            "at reports what clean code reports."
            % (len(on_disk), LEAST))
        return out, len(on_disk), len(named)

    for name in sorted(on_disk - named - set(EXEMPT)):
        out.append(
            "scripts/%s is never run by CI. It passes on somebody's "
            "machine and says nothing about any build. Add a `python3 "
            "scripts/%s` line to a step in ci.yml -- beside the gate it "
            "tests, in the job that can run it." % (name, name))

    for name in sorted(set(EXEMPT) & named):
        out.append(
            "scripts/%s is exempted here on the grounds that CI does not "
            "run it (%s), and ci.yml runs it. Drop the exemption."
            % (name, EXEMPT[name]))

    for name in sorted(set(EXEMPT) - on_disk):
        out.append(
            "scripts/%s is exempted here and does not exist. Drop the "
            "exemption." % name)

    for name in sorted(named - on_disk):
        out.append(
            "ci.yml runs scripts/%s and there is no such file. A rename "
            "moved one end only." % name)

    return out, len(on_disk), len(named)


def main() -> int:
    found, on_disk, named = problems()
    if found:
        print("Self-tests CI does not run:\n", file=sys.stderr)
        for problem in found:
            print("  %s\n" % problem, file=sys.stderr)
        return 1
    print("all %d self-tests under scripts/ are run by CI (%d named)"
          % (on_disk, named))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
