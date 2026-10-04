#!/usr/bin/env python3
"""Refuse a token rotation from inside a widget's build or initState.

    python3 scripts/check_token_rotators.py

Two calls in the Supabase SDK rotate the access token:

  * `auth.refreshSession()`, which says so in its name;
  * `auth.mfa.listFactors()`, which does NOT. Its own doc comment is
    "Returns the list of MFA factors enabled for this user" and its
    first line is `await _client.refreshSession()`. It reads like a
    getter. (Checked against gotrue 2.25.0's `gotrue_mfa_api.dart`; it
    is the only method in that package with an implicit refresh.)

Either one emits `AuthChangeEvent.tokenRefreshed`. From `initState` or
`build` that is a loop with one more step in it than anybody can see:

    initState -> listFactors -> tokenRefreshed -> providers reload
      -> widget disposed and re-created -> initState -> ...

Which is what happened. The Settings page reloaded itself every 1.5 to
2 seconds, 17 token refreshes in one visit against a JWT with 57
minutes left on it, and then `/auth/v1/token`'s rate limit -- 150 in
five minutes -- returned 429, GoTrue treated that as fatal, dropped the
session and signed the person out. `core/providers.dart` carries the
other half of the fix and `app/test/token_refresh_loop_test.dart` the
assertions.

`userIdentityProvider` stops the amplification, so this would no longer
loop. It is still wrong: a screen that rotates the token every time it
is drawn spends a rate limit shared by every tab and every device on
that IP, for a list that arrives with the session anyway.

Nothing else catches it. The analyzer has no opinion about what a
method does, the widget tests never reach GoTrue, and the symptom is a
network log.

## What is allowed

The same calls from a button, a submit handler, or after enrolling or
removing a factor. Those genuinely need a new token -- the JWT's `aal`
and `amr` claims change -- and they happen when somebody presses
something, not on every frame.
"""

from __future__ import annotations

import os
import pathlib
import re
import sys

# The calls that rotate. Matched on the method name and its receiver's
# tail, so `auth.mfa.listFactors()` and `client.auth.refreshSession()`
# are both caught however the receiver is spelled.
ROTATORS = re.compile(r"\b(?:mfa\.listFactors|auth\.refreshSession)\s*\(")

#: This gate expects to find NOTHING, so a floor on matches would demand
#: that offenders exist. A clean codebase and a blind sweep give the same
#: answer, and it passed over an empty tree.
#:
#: Two controls on the sweep itself instead:
#:
#:   * LEAST_DRAW_PATHS -- how many build/draw methods ON_DRAW must have
#:     found. 1,386 today under app/lib; floored well below.
#:   * THE CANARY -- ROTATORS must still match SOMEWHERE in app/lib. The
#:     app does rotate the token, just not on a draw path, so if this
#:     pattern matches nothing then either the calls were renamed or the
#:     sweep is blind -- and both look like success. 3 sites today.
LEAST_DRAW_PATHS = int(os.environ.get("IAK_LEAST_SITES", "600"))
LEAST_ROTATORS = 1

# Where a rotation must not happen: a method that runs because the
# framework drew something, rather than because somebody pressed
# something.
ON_DRAW = re.compile(
    r"^\s*(?:@override\s*\n\s*)?"
    r"(?:void|Widget|Future<void>)\s+(initState|build|didChangeDependencies)"
    r"\s*\(",
    re.M,
)


def body_after(text: str, at: int) -> tuple[str, int]:
    """The braced body starting at or after `at`, and where it ends.

    Counts braces rather than matching a regex, because a build method
    is full of nested ones and the first `}` is never the right one.
    """
    start = text.find("{", at)
    if start < 0:
        return "", at
    depth, i = 0, start
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start : i + 1], i + 1
        i += 1
    return text[start:], len(text)


def problems(root: pathlib.Path) -> list[str]:
    out = []
    for path in sorted(root.rglob("*.dart")):
        text = path.read_text()
        if not ROTATORS.search(text):
            continue
        for found in ON_DRAW.finditer(text):
            method = found.group(1)
            body, _ = body_after(text, found.end())
            for call in ROTATORS.finditer(body):
                # The line the call is on, not the line the method
                # opened on: a build method can be two hundred lines
                # and the offender is one of them.
                line = (
                    text.count("\n", 0, found.end() + call.start()) + 1
                )
                out.append(
                    f"{path}:{line}\n"
                    f"    `{call.group(0)[:-1]}()` inside `{method}`.\n"
                    f"    That rotates the access token and emits "
                    f"`tokenRefreshed`, so the widget is re-created and "
                    f"calls it again.\n"
                    f"    Read what is already on the session, or call "
                    f"`auth.getUser()`, which is a plain GET. Keep the "
                    f"rotation for after enrol, verify or unenrol."
                )
    return out


def census(root: pathlib.Path) -> tuple[int, int]:
    """(draw-path methods found, rotator call sites found anywhere)."""
    draws = rotators = 0
    for path in root.rglob("*.dart"):
        text = path.read_text()
        draws += len(ON_DRAW.findall(text))
        rotators += len(ROTATORS.findall(text))
    return draws, rotators


def main() -> int:
    root = pathlib.Path("app/lib")
    draws, rotators = census(root)
    if draws < LEAST_DRAW_PATHS:
        print(
            f"This sweep found {draws} draw-path method(s) under {root}, "
            f"and there were {LEAST_DRAW_PATHS} or more when it was "
            f"written. A sweep with no draw paths to read reports exactly "
            f"what a clean app reports.", file=sys.stderr)
        return 2
    if rotators < LEAST_ROTATORS:
        print(
            f"`mfa.listFactors` and `auth.refreshSession` appear nowhere "
            f"under {root}. The app does rotate the token, just not while "
            f"drawing, so either they were renamed -- in which case this "
            f"pattern matches nothing and the gate is blind rather than "
            f"satisfied -- or the sweep is not reading app/lib. This is "
            f"the canary, not a defect in the app.", file=sys.stderr)
        return 2

    found = problems(root)
    if found:
        print(f"{len(found)} token rotation(s) on a draw path:\n")
        for p in found:
            print(f"  * {p}\n")
        return 1
    print(f"No widget rotates the access token while being drawn "
          f"({draws} draw-path methods examined, {rotators} rotator "
          f"call sites elsewhere).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
