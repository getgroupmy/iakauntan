#!/usr/bin/env python3
"""Break the code on purpose and see whether the test notices.

    python3 scripts/mutate.py <source.dart> <test.dart> <mutants.py>

A test that passes proves nothing about the code; it proves the test
ran. What proves something is a test that FAILS when the behaviour it
describes is removed. This applies each change in `mutants.py` to the
source in turn, runs the test file against it, and reports which
changes the test noticed.

`mutants.py` is a list of calls:

    m("cancel hours unclamped",
      "(doc.cancelWindowLeft?.inHours ?? 0).clamp(0, 72);",
      "(doc.cancelWindowLeft?.inHours ?? 0);")

Each is an exact string replacement, applied once, to a copy of the
source. The original is restored afterwards, and restoring it is
checked by running the test one last time.

## Always include a control

Its description must BEGIN with the word `CONTROL` — that is how one is
recognised, and a mutant that merely mentions the word somewhere in its
description is an ordinary mutant.

The last mutant should be a no-op — a type annotation, a pair of
brackets, a comment — that CANNOT change behaviour. If the control is
reported killed, the harness is broken and every other line of the
output is worthless.

That is not hypothetical. It has happened twice: once because the test
path was built by appending to the source path, so every run failed on
a missing file, and once because a bash heredoc mangled the Dart
quoting so no mutant applied at all. Both runs reported a clean sweep.

A mutant the harness could not apply is reported as HARNESS ERROR
rather than silently skipped, for the same reason.

## Survivors are not always gaps

A surviving mutant is either a missing assertion or an EQUIVALENT
mutant — a change that cannot be observed. Both exist here:

  * `if (r['warehouse'] != null)` above a `.where((e) => e != null)`
    that already drops the null.
  * the second half of `clockIn != null && clockOut == null`, where
    every use of the result sits behind a `done` check.

Where a survivor is equivalent, say so in the test file next to the
assertion it belongs to, so the next person does not go hunting for a
test that cannot be written.

## One file at a time

The harness mutates the file it is given. Logic in `app/lib/src/data/
models.dart` -- `LeaveBalance.available`, `Todo.isOverdue`,
`EinvoiceDocument.canCancel` -- needs its own run against that file
with the same test.

See `docs/widget-tests.md` for the ten ways a widget test passes while
asserting nothing, every one of which this harness found.
"""

from __future__ import annotations

import json
import os
import shutil
import re
import subprocess
import sys
import tempfile

ROOT = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
)
APP = os.path.join(ROOT, "app")


def pinned_version() -> str | None:
    """The `flutter-version` the workflow pins, or None."""
    ci = os.path.join(ROOT, ".github", "workflows", "ci.yml")
    try:
        with open(ci) as handle:
            found = re.findall(r"^\s*flutter-version:\s*([0-9][0-9.]*)\s*$",
                               handle.read(), re.M)
    except OSError:
        return None
    return found[0] if found else None


def _flutter_bin(opt: str = "/opt") -> str:
    """Where to find the `flutter` this project is pinned to.

    This used to be the literal string `/opt/flutter-sdk/bin`, and the
    day the pin moved from 3.32.0 to 3.47.4 that became the WRONG SDK
    while still existing -- so every mutant ran against a compiler the
    repository no longer uses, the baseline failed, and the run reported
    six mutants killed and the control killed with them.

    The control is what caught it, which is the whole argument for
    insisting on one. But a harness that needs its own control to notice
    it is pointed at the wrong toolchain should be told where to look.

    [opt] is where SDKs live, a parameter only so this can be tested
    against a throwaway tree -- the default is the real one, and no
    caller passes anything else.

    Order: an SDK whose DIRECTORY NAME is the pinned version, because
    the name is the evidence and needs no file read; then
    `/opt/flutter-sdk`, but only if it reports that version, because its
    name says nothing about which SDK is inside it; then whatever
    `flutter` is on PATH. Nothing is prepended when none is found, so
    the ordinary `flutter` resolves and fails on its own terms rather
    than this guessing.
    """
    version = pinned_version()

    if version:
        named = os.path.join(opt, "flutter-%s" % version, "bin")
        if os.path.exists(os.path.join(named, "flutter")):
            return named

    generic = os.path.join(opt, "flutter-sdk", "bin")
    if os.path.exists(os.path.join(generic, "flutter")):
        if version is None or _version_of(generic) == version:
            return generic

    on_path = shutil.which("flutter")
    return os.path.dirname(on_path) if on_path else ""


def _version_of(bin_dir: str) -> str | None:
    """The version an SDK reports, from whichever file it keeps it in.

    Two places, because Flutter moved it: up to 3.32 a plain `version`
    file at the SDK root, and after that `bin/cache/flutter.version.json`.
    Reading only the first made a 3.47 SDK look like an SDK of unknown
    version, which is the same answer as the wrong version and led here
    by a different route.
    """
    root = os.path.dirname(bin_dir)

    plain = os.path.join(root, "version")
    try:
        with open(plain) as handle:
            text = handle.read().strip()
            if text:
                return text
    except OSError:
        pass

    try:
        with open(os.path.join(root, "bin", "cache",
                               "flutter.version.json")) as handle:
            return json.load(handle).get("flutterVersion")
    except (OSError, ValueError):
        return None


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2

    source, test, spec = argv[1], argv[2], argv[3]
    source_path = os.path.join(APP, source)
    for path in (source_path, os.path.join(APP, test), spec):
        if not os.path.isfile(path):
            print(f"not a file: {path}", file=sys.stderr)
            return 2

    mutants: list[tuple[str, str, str]] = []

    def m(name: str, old: str, new: str) -> None:
        mutants.append((name, old, new))

    with open(spec) as handle:
        exec(compile(handle.read(), spec, "exec"), {"m": m})

    if not mutants:
        print(f"{spec} declared no mutants", file=sys.stderr)
        return 2

    env = dict(os.environ)
    env["PATH"] = _flutter_bin() + os.pathsep + env.get("PATH", "")

    def run() -> str:
        done = subprocess.run(
            ["flutter", "test", test],
            capture_output=True,
            text=True,
            cwd=APP,
            env=env,
        )
        out = done.stdout + done.stderr
        return "passed" if "All tests passed!" in out else "FAILED"

    backup = os.path.join(tempfile.gettempdir(), os.path.basename(source) + ".orig")
    shutil.copy(source_path, backup)

    print(f"baseline: {run()}")
    survivors: list[str] = []
    controls: list[tuple[str, str]] = []
    try:
        for name, old, new in mutants:
            shutil.copy(backup, source_path)
            with open(source_path) as handle:
                text = handle.read()
            if old not in text:
                print(f"{name:<44} HARNESS ERROR: pattern not found")
                continue
            with open(source_path, "w") as handle:
                handle.write(text.replace(old, new, 1))
            result = run()
            print(f"{name:<44} {result}")
            # STARTS WITH, not contains. A mutant whose description
            # happens to use the word -- "the role control unbounded",
            # "both controls are offered" -- was read as a no-op and
            # counted among the controls. That fails loudly when such a
            # mutant is killed, which is how it was found; the direction
            # that matters is the other one, where a real mutant with
            # "control" in its name SURVIVES and is filed as a healthy
            # control instead of as a gap in the test.
            #
            # Every mutant file in this repository writes its control as
            # `CONTROL -- ...`, which is what the docstring above asks
            # for, so this is the convention rather than a new rule.
            if name.strip().upper().startswith("CONTROL"):
                controls.append((name, result))
            elif result == "passed":
                survivors.append(name)
    finally:
        shutil.copy(backup, source_path)

    print(f"restored: {run()}")
    print()

    # The control is the whole reason to trust the rest of the output. A
    # control that DIED means the harness is broken and every "killed"
    # above is meaningless; no control at all means nothing was checked.
    if not controls:
        print("NO CONTROL. Add a no-op mutant -- a type annotation, a pair")
        print("of brackets -- that cannot change behaviour. Without one, a")
        print("harness that errors on every run reports a clean sweep.")
        return 1
    dead = [name for name, result in controls if result != "passed"]
    if dead:
        print("CONTROL KILLED: " + ", ".join(dead))
        print("The harness is broken. Every result above is worthless --")
        print("check the test path and the mutant strings before reading it.")
        return 1

    if survivors:
        print("survived (a missing assertion, or an equivalent mutant "
              "worth writing down):")
        for name in survivors:
            print(f"  {name}")
    else:
        print("every mutant killed, control survived.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
