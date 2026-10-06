#!/usr/bin/env python3
"""A sweep that found nothing must not be able to mean it looked at nothing.

    python3 scripts/check_sweeps_look.py

Most gates in this directory are sweeps: they glob a tree, apply a
pattern, and report what matched. Every one of them has a failure mode
that is invisible from outside — the glob returns nothing, or the pattern
stops matching — and then the gate prints its success line and the build
goes green. "Looked and found nothing" and "could not look" are the same
output.

This runs each gate in a tree holding `scripts/` and EMPTY source
directories, and requires it to fail. Nineteen gates did not, found in
two sweeps, and the ratchet below has since taken one of them:

  * six by redirecting a module-level scope constant at an empty
    directory (`check_or_filters`, which guards a user's name going raw
    into a PostgREST `or()`, was one);
  * thirteen more by this fuller method, which reaches gates that build
    their paths inside functions.

**Printing a count is not checking one.** That is the correction worth
carrying out of it: `check_money_is_numeric` says "742 migrations, 0
allowed floats" and over an empty tree says "0 migrations, 0 allowed
floats" and exits 0. A number in the output looked like a positive
control and is not one unless something compares it.

## Why a gate rather than nineteen fixes

Nineteen is too many to fix in one change, and a per-gate fix does
nothing for the twentieth gate somebody writes next week. A gate makes
the property the default: a new sweep must fail over nothing, or be
named here with a reason.

## What it cannot do

Prove a gate's pattern is right, only that something reaches it. A
pattern matching the wrong thing in a full tree passes here.

And it cannot drive a gate that needs something the skeleton tree has
not got — a database, or one named file. Those are listed below rather
than skipped silently, because a sweep that quietly covers 44 of 62 and
reports "all clear" is the defect this gate is about.
"""

from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"

#: The directory skeletons a source sweep globs. Created EMPTY: that is
#: the whole experiment. A gate that needs one NAMED file inside them is
#: in NEEDS_A_FILE below, because a missing file raises and a raise is
#: already a loud failure.
SKELETON = ("app/lib", "app/web", "app/test", "app/android", "app/ios",
            "supabase/tests", "supabase/migrations", "supabase/functions",
            ".github/workflows", "deploy", "docs")

#: Seconds per gate. A gate that hangs is reported, not waited for.
TIMEOUT = 60

#: Takes a database URL and says so. An empty SOURCE tree is no test of
#: a gate that reads `pg_proc`: it exits 2 on usage, which is non-zero
#: for the wrong reason, and counting that as a pass would be the
#: vacuous-success shape this gate exists to refuse.
NEEDS_A_DATABASE = """
check_ambiguous_overloads check_bank_account_types check_discarded_values
check_module_gates check_overload_assertions check_query_columns
check_rpc_grants check_stable_writers check_undocumented_writes
check_write_doors
""".split()

#: Takes a path on the command line that an empty tree cannot supply --
#: not a source tree to sweep but an ARTEFACT produced by the step
#: before it. Same shape as NEEDS_A_DATABASE: it exits 2 on a `usage:`
#: line, which is non-zero for the wrong reason, and the entry names
#: what it wants so a gate that changes shape is read rather than
#: assumed.
NEEDS_AN_ARGUMENT = {
    "check_flutter_test_count":
        "the json report `flutter test --file-reporter` writes",
}

#: Opens ONE named file rather than globbing a tree, so an empty skeleton
#: makes it raise FileNotFoundError. That raise IS its positive control:
#: the file is either there or the gate stops. Each entry names the file,
#: so an entry that stops being true is visible.
NEEDS_A_FILE = {
    "check_app_icons":
        "app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json",
    "check_csp_allows": "deploy/vercel-output-config.json",
    "check_currency_decimals": "supabase/migrations/0011_seed_reference.sql",
    "check_document_types": "docs/api/openapi.json",
    "check_ios_purpose_strings": "app/ios/Runner/Info.plist",
    "check_release_choices": "supabase/functions/_shared/release.ts",
    "check_settings_are_read":
        "supabase/migrations/0018_platform_admin_modules_and_permissions.sql",
    "check_spa_fallback": "deploy/vercel-output-config.json",
}

#: Gates that still pass over nothing. A RATCHET, and it has reached the
#: bottom: all nineteen are done, so this is EMPTY and every gate must
#: now fail over an empty source tree or be excused above with a reason.
#:
#: An entry here is still honoured, so a gate that genuinely cannot be
#: driven can be parked with a note. But a floor at zero is the only kind
#: nobody has to remember to lower.
#:
#: Four shapes came out of closing it, and which one a gate needs depends
#: on what it reports:
#:
#:   * a CENSUS gate reports "N sites, all compliant" -- floor N.
#:     check_captcha_tokens, check_edge_cors, check_dialogs_built,
#:     check_money_is_numeric.
#:   * a ZERO-EXPECTED gate whose pattern matches every site, compliant
#:     or not -- floor the sites examined. check_date_arguments,
#:     check_initstate_ref, check_loading_spinners, check_narrow_rows,
#:     check_order_direction, and the six given site floors earlier.
#:   * a ZERO-EXPECTED gate whose pattern matches ONLY offenders -- a
#:     floor on matches would demand that offenders exist, so floor what
#:     it READ and add a CANARY: a place the pattern must still match.
#:     check_current_org (the declaration in providers.dart),
#:     check_token_rotators (the legitimate rotations off the draw path).
#:   * a gate reading NAMED FILES that skipped them when absent -- remove
#:     the `exists()` escape and say "could not look" rather than tick.
#:     check_capture_is_kept, check_order_direction.
PASSES_OVER_NOTHING: dict[str, str] = {
}


def skeleton_tree(into: pathlib.Path) -> pathlib.Path:
    shutil.copytree(SCRIPTS, into / "scripts")
    for d in SKELETON:
        (into / d).mkdir(parents=True, exist_ok=True)
    return into


def drive(gate: str, tree: pathlib.Path) -> tuple[object, str]:
    env = dict(os.environ)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    try:
        # stdin closed: a gate that reads its input from stdin -- as
        # `check_rate_feed_fresh` does without `--newest` -- would
        # otherwise inherit whatever this process was given and wait on
        # it until TIMEOUT. In CI that is nothing and it reports at once;
        # in a shell left open it is a hang, and a hang reads "timeout"
        # rather than "reported".
        done = subprocess.run(
            [sys.executable, "-B", "scripts/%s.py" % gate],
            capture_output=True, text=True, cwd=tree, env=env,
            stdin=subprocess.DEVNULL, timeout=TIMEOUT)
        return done.returncode, done.stdout + done.stderr
    except subprocess.TimeoutExpired:
        return "timeout", ""


#: This gate drives every other one, so driving itself recurses until
#: the timeout. It said so about itself on the first run, which is the
#: shape of self-check worth keeping: it reported rather than hung.
SELF = pathlib.Path(__file__).stem


def gates() -> list[str]:
    return sorted(p.stem for p in SCRIPTS.glob("check_*.py")
                  if not p.stem.endswith("_test") and p.stem != SELF)


def verdicts(tree: pathlib.Path,
             names: list[str] | None = None) -> dict[str, str]:
    """gate -> how it behaved over an empty tree.

    FOUR outcomes, not two, and the distinction is the point. A gate that
    exits 2 saying `usage: ... <database-url>` is non-zero for the WRONG
    reason: it never looked at anything, and counting that as "reported a
    problem" would be the vacuous success this gate exists to refuse. The
    first version of this did exactly that and called all ten database
    gates drivable.
    """
    out = {}
    for gate in (gates() if names is None else names):
        code, said = drive(gate, tree)
        if code == "timeout":
            out[gate] = "timeout"
        elif "Traceback (most recent call last)" in said:
            out[gate] = "crashed"
        elif "usage:" in said.lower():
            out[gate] = "needs_argument"
        elif code == 0:
            out[gate] = "passed_over_nothing"
        else:
            out[gate] = "reported"
    return out


def run(found: dict[str, str] | None = None) -> int:
    if found is None:
        with tempfile.TemporaryDirectory() as tmp:
            found = verdicts(skeleton_tree(pathlib.Path(tmp)))

    excused = (set(NEEDS_A_DATABASE) | set(NEEDS_A_FILE)
               | set(NEEDS_AN_ARGUMENT))
    problems = []

    for gate, verdict in sorted(found.items()):
        if gate in excused:
            continue
        if verdict == "passed_over_nothing" and gate not in PASSES_OVER_NOTHING:
            problems.append(
                "%s passes over an EMPTY source tree. It cannot tell "
                "'looked and found nothing' from 'could not look', and "
                "those are the same success line and the same green "
                "build. Count what it examined and refuse a count below "
                "a floor -- on sites matched rather than files read, "
                "because a pattern that stops matching is the failure "
                "that actually happens. Printing the number is not "
                "enough: something has to compare it." % gate)
        if verdict == "timeout":
            problems.append(
                "%s did not finish in %ds over an empty tree, so nothing "
                "is known about it either way." % (gate, TIMEOUT))
        # The hole the summary line hid. `counted` was
        # len(found) - len(excused), ARITHMETIC rather than a tally, so a
        # gate that exited 2 on a `usage:` line was counted among those
        # that "report a problem over an empty source tree" -- which is
        # the one thing this gate's own docstring says must never count
        # as looking. check_flutter_test_count was the first gate to fall
        # in, and the sentence happily said 46 of 64.
        if verdict not in ("reported", "passed_over_nothing", "timeout"):
            problems.append(
                "%s neither reported a problem over an empty tree nor is "
                "excused for a named reason: it %s. Non-zero for the "
                "wrong reason is not looking. Either it takes an argument "
                "an empty tree cannot supply -- say so in "
                "NEEDS_AN_ARGUMENT or NEEDS_A_DATABASE -- or it reads one "
                "named file, which belongs in NEEDS_A_FILE, or it has a "
                "bug." % (gate, verdict.replace("_", " ")))

    for gate in sorted(PASSES_OVER_NOTHING):
        got = found.get(gate)
        if got is None:
            problems.append(
                "%s is in PASSES_OVER_NOTHING but is not a gate any more. "
                "Drop the entry." % gate)
        elif got != "passed_over_nothing":
            problems.append(
                "%s is in PASSES_OVER_NOTHING and no longer does. Drop the "
                "entry and let the ratchet fall -- a backlog nobody prunes "
                "stops being a backlog." % gate)

    # An excuse names the behaviour it expects, so it fails BOTH ways.
    for gate, want, why in (
            [(g, "needs_argument",
              "exits with a `usage:` line because it takes a database URL")
             for g in NEEDS_A_DATABASE]
            + [(g, "crashed",
                "raises FileNotFoundError for %s" % NEEDS_A_FILE[g])
               for g in NEEDS_A_FILE]
            + [(g, "needs_argument",
                "exits with a `usage:` line because it takes %s"
                % NEEDS_AN_ARGUMENT[g])
               for g in NEEDS_AN_ARGUMENT]):
        got = found.get(gate)
        if got is None:
            problems.append(
                "%s is excused here but is not a gate any more. Drop it "
                "from NEEDS_A_DATABASE, NEEDS_A_FILE or "
                "NEEDS_AN_ARGUMENT." % gate)
        elif got == "passed_over_nothing":
            problems.append(
                "%s is excused on the grounds that it %s, and it PASSED "
                "over an empty tree instead. The excuse is wrong and the "
                "gate is not looking." % (gate, why))
        elif got != want:
            problems.append(
                "%s is excused on the grounds that it %s, and over an "
                "empty tree it %s instead. Either the excuse is stale or "
                "the gate changed shape -- read it and move it."
                % (gate, why, got.replace("_", " ")))

    if problems:
        print("Sweeps that may not be looking:\n", file=sys.stderr)
        for problem in problems:
            print("  %s\n" % problem, file=sys.stderr)
        return 1

    # TALLIED, not subtracted. The previous version computed this as
    # len(found) - len(excused) - len(PASSES_OVER_NOTHING), which is a
    # sentence about arithmetic rather than about verdicts: it would say
    # "46 of 64 gates report a problem" with one of the 46 having exited
    # 2 on a usage line. Printing a count is not checking one, and the
    # count printed here was the one not checked.
    counted = sum(1 for g, v in found.items()
                  if g not in excused and v == "reported")
    print("%d of %d gates report a problem over an empty source tree, as "
          "they must. %d exit on a missing database URL, %d raise on a "
          "missing named file, %d exit on a missing argument, and %d "
          "still pass over nothing -- a ratchet that may only fall."
          % (counted, len(found), len(NEEDS_A_DATABASE), len(NEEDS_A_FILE),
             len(NEEDS_AN_ARGUMENT), len(PASSES_OVER_NOTHING)))
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
