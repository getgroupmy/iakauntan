#!/usr/bin/env python3
"""Refuse a broadcast topic no client subscribes to.

    python3 scripts/check_realtime_topic.py

The platform console tells every open client what it changed by
broadcasting the NAME of the changed table — `app.landing_touched()`,
put there by `0322` and extended to `site_pages` by `0647`. The app
answers it in `core/platform_live.dart`.

The two have to agree on one string, and for 330 migrations they did
not. The trigger sent to the topic `landing`; the app subscribed with
`client.channel('platform')`, which `realtime_client` turns into the
topic `realtime:platform`. Every nudge since `0322` went to a topic
with nobody on it.

## Why nothing noticed

A broadcast to an empty topic is not an error at either end. The
trigger succeeds. The socket stays connected. `channel.onBroadcast`
simply never fires, forever, and the screen shows what it was told when
it started. It was masked further by the second path —
`onPostgresChanges`, which DOES work for tables a subscriber may read —
so the only people who saw the fault were the ones RLS excluded from
that path: signed-out visitors on the front page, and every user who is
not a platform administrator looking at anything from `site_pages`.

They reported it as "the mobile app only updates when I relaunch it",
which is what a cache with no invalidation looks like from outside.

## Why a script and not a test

Neither half is wrong on its own, so neither half can be asserted on
its own. A SQL test can only say the function names some topic; a Dart
test can only say the channel has some name. The defect lives in the
gap between two languages, and this is the only place that reads both.
"""

from __future__ import annotations

import pathlib
import re
import sys

DART = pathlib.Path("app/lib/src/core/platform_live.dart")
MIGRATIONS = pathlib.Path("supabase/migrations")

#: `client.channel('platform')` — the topic the app listens on.
CHANNEL = re.compile(r"""\.channel\(\s*['"]([^'"]+)['"]""")

#: The third argument of `realtime.send(payload, event, topic, private)`,
#: which is the topic it goes to. Matched across newlines because the
#: call is written over four lines.
#:
#: `perform` is required, and that is not cosmetic. The function guards
#: the call with
#:
#:     if to_regprocedure('realtime.send(jsonb, text, text, boolean)')
#:
#: so the literal string `realtime.send(` appears BEFORE the real call.
#: Without the anchor the regex matched that one, read `text` as the
#: topic, and reported that no topic could be found -- on a file with a
#: perfectly good one.
SEND = re.compile(
    r"perform\s+realtime\.send\s*\((?P<args>[^;]*?)\)\s*;",
    re.S,
)


def without_comments(text: str) -> str:
    """The SQL with whole-line `--` comments removed.

    Not decoration. The first version of this script read the topic out
    of the migration's own PROSE: `0652`'s header quotes the call it is
    fixing, old topic and all, and the regex found that before it found
    the code. It reported the fault it had just been written to fix, on
    a file that fixes it.

    That is the second gate in this repository to fail on its own
    documentation -- `check_passkey_association.py` refused an
    entitlement for the words in a comment warning against them. The
    lesson both times is the same: a gate that reads source has to read
    the CODE.

    Whole-line comments only. Stripping a trailing `--` from a code line
    would have to know whether it is inside a string literal, and the
    calls this reads are not written that way.
    """
    return "\n".join(
        line for line in text.splitlines()
        if not line.lstrip().startswith("--")
    )


def latest_definition() -> tuple[pathlib.Path, str] | None:
    """The last migration to define `app.landing_touched`.

    Migrations are append-only and applied in order, so the highest
    numbered one that defines the function is what the database has.
    Reading the earliest would have this script pass against a fault
    somebody has already fixed — and, worse, fail against a fix.
    """
    found: list[tuple[str, pathlib.Path, str]] = []
    for path in sorted(MIGRATIONS.glob("*.sql")):
        text = without_comments(path.read_text())
        if "function app.landing_touched" in text:
            found.append((path.name, path, text))
    if not found:
        return None
    _, path, text = found[-1]
    return path, text


def broadcast_topic(text: str) -> str | None:
    """The topic `realtime.send` is called with, or None."""
    for match in SEND.finditer(text):
        args = match.group("args")
        # Split on the commas that separate top-level arguments. The
        # first argument is `jsonb_build_object(...)`, which contains
        # commas of its own, so the depth is tracked.
        parts: list[str] = []
        depth = 0
        current = ""
        for ch in args:
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            if ch == "," and depth == 0:
                parts.append(current)
                current = ""
            else:
                current += ch
        parts.append(current)
        if len(parts) >= 3:
            topic = parts[2].strip()
            m = re.fullmatch(r"'([^']*)'", topic)
            if m:
                return m.group(1)
    return None


def main() -> int:
    if not pathlib.Path("app/pubspec.yaml").exists():
        print("run this from the repository root")
        return 2

    problems: list[str] = []

    if not DART.exists():
        print(f"{DART} is missing")
        return 1

    channels = CHANNEL.findall(DART.read_text())
    if not channels:
        problems.append(
            f"{DART} opens no channel. If the subscription moved, this "
            "script has to move with it — it is the only thing checking "
            "the two ends agree."
        )

    found = latest_definition()
    if found is None:
        problems.append(
            "No migration defines app.landing_touched(). If the nudge "
            "was removed, remove this gate deliberately rather than "
            "leaving it passing against nothing."
        )
        topic = None
        source = None
    else:
        source, text = found
        topic = broadcast_topic(text)
        if topic is None:
            problems.append(
                f"{source} defines app.landing_touched() but no "
                "`realtime.send` with a literal topic could be read out "
                "of it. A topic built at run time cannot be checked "
                "here, and an unchecked topic is how this broke."
            )

    if topic is not None and channels and topic not in channels:
        problems.append(
            f"The broadcast goes to the topic {topic!r} ({source.name}) "
            f"and the app subscribes to {channels!r} ({DART}).\n"
            "    A broadcast to a topic nobody is on is silent at both "
            "ends: the trigger succeeds, the socket stays up, and "
            "onBroadcast never fires.\n"
            "    That is exactly what happened between 0322 and 0652, "
            "and what a signed-out visitor or a non-admin user sees is "
            "a screen that never updates until the app is relaunched."
        )

    if problems:
        print("realtime topic problem(s):\n")
        for p in problems:
            print(f"  * {p}\n")
        return 1

    print(
        f"The nudge and the subscription agree on {topic!r} "
        f"({source.name} and {DART.name})."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
