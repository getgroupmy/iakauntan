#!/usr/bin/env python3
"""A setState whose callback returns a Future.

`setState(() => _board = repo.exchangeRateBoard(_asAt));` is an arrow
body, so the callback RETURNS the value of the assignment -- a Future.
Flutter asserts against exactly that:

    setState() callback argument returned a Future.

which means the widget throws, on every load and every refresh, in any
build with asserts enabled. That is every `flutter run`, every debug
build, and every widget test. It is invisible in a release build, so a
screen can ship this and only ever fail for the people developing it --
which is how `exchange_rates_screen.dart` carried it until the screen
got its first test and could not render at all.

The fix is braces instead of an arrow, so the callback returns void.

Only assignments to a FUTURE-TYPED FIELD are reported. `setState(() =>
_busy = true)` is an arrow body too and is perfectly correct: the
callback returns a bool, which Flutter does not mind. A first version of
this check looked for Future-typed names anywhere in the file and
reported 185 of those, nearly all of them `_busy` and `_saving` bools
that happened to share a file with some unrelated Future. The
declaration has to be found and read.

A method declaration is not a field: `Future<void> _start() async` is
followed by `(`, and `setState(() => _start = picked)` beside it is
assigning a DateTime to a different `_start` entirely. That one was in
the first version's output too.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIB = ROOT / "app" / "lib"

# `Future<...> _name;` or `= ...`, optionally late/final. NOT followed by
# `(`, which would make it a method.
FIELD = r"^\s*(?:late\s+)?(?:final\s+)?Future<.*?>\??\s+{name}\s*[;=]"
ASSIGN = re.compile(r"setState\(\(\)\s*=>\s*(_\w+)\s*=")


def main() -> int:
    bad = []
    for path in sorted(LIB.rglob("*.dart")):
        src = path.read_text()
        for match in ASSIGN.finditer(src):
            name = match.group(1)
            if not re.search(FIELD.format(name=re.escape(name)), src, re.M):
                continue
            line = src[: match.start()].count("\n") + 1
            bad.append(f"{path.relative_to(ROOT)}:{line}  {match.group(0)}...)")

    if bad:
        print("setState with an arrow body assigning a Future:")
        for b in bad:
            print(f"  {b}")
        print()
        print("The callback returns the assigned value, so Flutter throws")
        print('"setState() callback argument returned a Future." on every')
        print("build with asserts on. Use braces:")
        print()
        print("    setState(() {")
        print("      _board = repo.exchangeRateBoard(_asAt);")
        print("    });")
        return 1

    print("no setState returns a Future")
    return 0


if __name__ == "__main__":
    sys.exit(main())
