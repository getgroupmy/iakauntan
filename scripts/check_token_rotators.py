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

import pathlib
import re
import sys

# The calls that rotate. Matched on the method name and its receiver's
# tail, so `auth.mfa.listFactors()` and `client.auth.refreshSession()`
# are both caught however the receiver is spelled.
ROTATORS = re.compile(r"\b(?:mfa\.listFactors|auth\.refreshSession)\s*\(")

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


def main() -> int:
    found = problems(pathlib.Path("app/lib"))
    if found:
        print(f"{len(found)} token rotation(s) on a draw path:\n")
        for p in found:
            print(f"  * {p}\n")
        return 1
    print("No widget rotates the access token while being drawn.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
