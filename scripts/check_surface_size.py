#!/usr/bin/env python3
"""A widget test makes the window narrow with `tester.view.physicalSize`.

    python3 scripts/check_surface_size.py

There are two ways to resize a widget test's window and only one of them
works. `docs/widget-tests.md` sets out why, and the short version is
that `tester.binding.setSurfaceSize` moves the RENDER SURFACE and leaves
`MediaQuery` reporting 800x600:

    await tester.binding.setSurfaceSize(const Size(393, 852));  // trap

    tester.view.devicePixelRatio = 1.0;                         // this
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.reset);

So it DOES catch a `RenderFlex` overflow, and it does NOT move the
breakpoint: every `MediaQuery.sizeOf(context).width < 700` in the app
still takes the desktop branch. 25 places in `app/lib` branch on a width
threshold. A test that resizes the surface and then asserts the narrow
layout is asserting against a layout that is not on the screen — and it
passes, because the widgets it names are there.

Five test files already carry a hand-written comment saying to use the
other call. That is the decision written down five times and enforced
nowhere, which is what this replaces: a comment is advice to whoever
reads the file, and nobody reads a file before writing a new one.

## The one real use, and why it was converted rather than excused

`scan_all_data_test.dart` resized to 1000x2400 so that a lazily-built
list would construct every row, with a comment explaining it. Nothing
there asserted a narrow layout, so the trap was not sprung — but the
test was one `MediaQuery`-sized sheet away from silently building only
the rows that fit 600 while believing it had 2400. It would not have
failed. It would have stopped looking at the rows it names.
`tester.view.physicalSize` drives both and cost two lines.

## The shape of this gate

Zero-expected, and its pattern matches ONLY offenders, so a floor on
matches would demand that offenders exist. Two controls on the sweep
instead, which is the shape `check_current_org.py` uses:

  * LEAST_FILES -- how many test files were read.
  * THE CANARY -- `tester.view.physicalSize` must still appear. It is the
    call this gate exists to prefer; if it vanished, either the API was
    renamed (and this pattern now matches nothing) or the sweep is not
    reading `app/test` at all. Both look like success.
"""

from __future__ import annotations

import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TESTS = ROOT / "app" / "test"

#: The trap.
TRAP = re.compile(r"\bsetSurfaceSize\s*\(")

#: The call that drives MediaQuery as well as the surface.
RIGHT = re.compile(r"\btester\.view\.physicalSize\b")

#: 457 test files today; 117 already use the right call. Floored well
#: below both: this guards against the sweep going blind, not against a
#: file being added or removed.
LEAST_FILES = int(os.environ.get("IAK_LEAST_SITES", "250"))
LEAST_CANARY = 1

#: A test that genuinely needs the render surface moved WITHOUT moving
#: `MediaQuery` would go here, with the reason. Empty, and a reviewed
#: list at zero beats a convention: there is no such test today, and the
#: one that looked like it wanted it did not.
ALLOWED: dict[str, str] = {}

LINE_COMMENT = re.compile(r"//[^\n]*")


def without_comments(text: str) -> str:
    """`//` and `///` to end of line.

    Five files name `setSurfaceSize` in a comment saying NOT to use it,
    and a gate that reported its own explanation is one somebody deletes
    the explanation to satisfy. Matching a comment is the mistake this
    repository has made more than any other.

    Precisely, though: those five write the name in prose without a
    paren -- "not `setSurfaceSize`:" -- and `TRAP` wants the call form,
    so the tree as it stands does not exercise this. It is load-bearing
    for a COMMENTED-OUT call, which the self-test covers directly rather
    than inferring from a passing sweep.
    """
    return LINE_COMMENT.sub("", text)


def dart_tests() -> list[pathlib.Path]:
    return sorted(TESTS.rglob("*.dart"))


def census() -> tuple[int, int]:
    """(test files read, files using the right call)."""
    files = dart_tests()
    right = sum(1 for f in files if RIGHT.search(without_comments(f.read_text())))
    return len(files), right


def offenders() -> list[str]:
    out = []
    for path in dart_tests():
        # `relative_to` raises for a path outside ROOT, which is every
        # path the self-test feeds. A gate that cannot be pointed at a
        # fed tree can only be tested against the real one, and then its
        # failure paths are never exercised at all.
        try:
            rel = path.relative_to(ROOT).as_posix()
        except ValueError:
            rel = path.as_posix()
        text = without_comments(path.read_text())
        for m in TRAP.finditer(text):
            if rel in ALLOWED:
                continue
            line = text.count("\n", 0, m.start()) + 1
            out.append("  %s:%d" % (rel, line))
    return out


def run() -> int:
    files, right = census()
    if files < LEAST_FILES:
        print("This sweep read %d test file(s) under %s, and there were %d "
              "or more when it was written. A sweep with nothing to read "
              "reports exactly what a clean test suite reports."
              % (files, TESTS, LEAST_FILES), file=sys.stderr)
        return 2
    if right < LEAST_CANARY:
        print("`tester.view.physicalSize` appears in none of the %d test "
              "files read. That is the call this gate exists to prefer, so "
              "either it was renamed -- in which case this gate now matches "
              "nothing and is blind rather than satisfied -- or it is not "
              "reading app/test. This is the canary, not a defect in the "
              "tests." % files, file=sys.stderr)
        return 2

    bad = offenders()
    for name in sorted(ALLOWED):
        if not any(line.strip().startswith(name) for line in bad):
            print("%s is in ALLOWED and no longer calls setSurfaceSize. "
                  "Drop the entry." % name, file=sys.stderr)
            return 1

    if bad:
        print("A widget test resizes the surface without moving "
              "MediaQuery:\n", file=sys.stderr)
        for line in bad:
            print(line, file=sys.stderr)
        print(
            "\n`setSurfaceSize` moves the render surface and leaves "
            "`MediaQuery` reporting 800x600, so every "
            "`MediaQuery.sizeOf(context).width < 700` in the app still "
            "takes the desktop branch -- and a test asserting the narrow "
            "one is asserting against a layout that is not on the screen. "
            "It passes, because the widgets it names are there.\n\n"
            "    tester.view.devicePixelRatio = 1.0;\n"
            "    tester.view.physicalSize = const Size(393, 852);\n"
            "    addTearDown(tester.view.reset);\n\n"
            "See docs/widget-tests.md. If a test genuinely needs the "
            "surface moved and MediaQuery left alone, put it in ALLOWED "
            "in %s with the reason." % pathlib.Path(__file__).name,
            file=sys.stderr)
        return 1

    print("every widget test that resizes its window moves MediaQuery with "
          "it (%d test files read, %d using tester.view.physicalSize)"
          % (files, right))
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
