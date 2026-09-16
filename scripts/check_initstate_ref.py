#!/usr/bin/env python3
"""`ref.invalidate` inside `initState`, which throws before the first frame.

    python3 scripts/check_initstate_ref.py

`ref.invalidate` reaches for the enclosing `ProviderScope`, and
depending on an inherited widget inside `initState` is exactly what
Flutter asserts against:

    dependOnInheritedWidgetOfExactType<UncontrolledProviderScope>() was
    called before _SalespeopleScreenState.initState() completed.

The build fails, the screen renders nothing, and -- because it is an
assertion -- a release build is unaffected. So a screen can ship
carrying this and only ever be broken for the people developing it.
That is the same shape as `check_setstate_futures.py`, and
`salespeople_screen.dart` carried it until the screen got its first
test and could not render at all.

`ref.read` in `initState` is fine and is not reported: it is the
documented way to reach a provider once, and three screens here do it.

## What is NOT a finding

A call inside a callback that runs LATER -- a `Timer.periodic`, a
`addPostFrameCallback`, a `then` -- has left `initState` long before it
fires. Four POS boards refresh themselves on a timer set up in
`initState`, and every one of them is correct:

    _tick = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) ref.invalidate(kitchenDisplayProvider(station));
    });

So this reads the STATEMENTS of `initState` and of any same-class
method it calls directly, and stops at the first `{` that opens a
closure. A first version matched the whole body lexically and reported
all four boards; the check has to know the difference between code that
runs now and code that runs later, or it is four false positives and a
gate people learn to scroll past.
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
APP = os.path.join(ROOT, "app", "lib")

INIT = re.compile(r"\n  void initState\(\)\s*\{")
CALL = re.compile(r"^\s*(_\w+)\s*\(([^)]*)\)\s*;", re.M)


def immediate(body: str) -> str:
    """The part of a body that runs now, with every closure removed.

    A closure begins at a `{` that follows `)` or `=>` on the same
    statement. Rather than parse Dart, drop everything from the first
    brace that opens after an arrow or a parenthesis close, which is
    where every callback in this repository starts.
    """
    out, depth, i = [], 0, 0
    while i < len(body):
        ch = body[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth = max(0, depth - 1)
        elif depth == 0:
            out.append(ch)
        i += 1
    return "".join(out)


def method_body(src: str, name: str) -> str:
    m = re.search(
        r"\n  (?:void|Future<[^>]*>)\s+" + re.escape(name) + r"\([^)]*\)\s*(?:async\s*)?\{",
        src,
    )
    if not m:
        return ""
    end = src.find("\n  }\n", m.end())
    return src[m.end() : end if end != -1 else len(src)]


def main() -> int:
    bad = []
    for root, _, files in os.walk(APP):
        for name in sorted(files):
            if not name.endswith(".dart"):
                continue
            path = os.path.join(root, name)
            src = open(path).read()
            for m in INIT.finditer(src):
                end = src.find("\n  }\n", m.end())
                body = src[m.end() : end if end != -1 else len(src)]
                now = immediate(body)
                reach = now
                for call in CALL.findall(body):
                    reach += immediate(method_body(src, call[0]))
                if "ref.invalidate" in reach:
                    line = src[: m.start()].count("\n") + 2
                    rel = os.path.relpath(path, ROOT)
                    bad.append(f"{rel}:{line}")

    if bad:
        print("ref.invalidate runs inside initState:")
        for b in bad:
            print(f"  {b}")
        print()
        print("This throws before the first frame -- the screen renders")
        print("nothing in any build with asserts on, and correctly in a")
        print("release build.")
        print()
        print("Move the invalidate to the places that actually change what")
        print("the provider holds. A first build has not read it yet, so")
        print("there is nothing to invalidate there in any case. A flag on")
        print("the shared method is NOT the fix: this check cannot see that")
        print("the flag is false at the call site, and would go on")
        print("reporting it.")
        return 1

    print("no initState invalidates a provider")
    return 0


if __name__ == "__main__":
    sys.exit(main())
