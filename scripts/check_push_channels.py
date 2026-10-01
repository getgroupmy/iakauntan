#!/usr/bin/env python3
"""Every notification channel the sender names must exist on the handset.

    python3 scripts/check_push_channels.py

From Android 8, a notification whose `channel_id` names a channel the
app has not created is **dropped**. Not shown quietly, not shown without
sound — dropped, and nothing anywhere reports it:

  * `send-push` posts to FCM and gets a `200` with a message name back,
    so the sender believes it sent;
  * the handset is registered, permission is granted, the token is
    live, so the settings card says notifications are on;
  * and nothing arrives, forever.

That is the most expensive shape of bug this project has: a system that
reports success at every layer and does nothing. It happens from one
side renaming a string — `chat` to `messages`, say, or a channel split
in two — with the other side a different language in a different
directory.

So the two lists are compared here instead:

  * the `channel_id` values `supabase/functions/send-push/index.ts`
    puts in an Android payload, plus the `default_notification_channel_id`
    in `AndroidManifest.xml`, plus the channel `PushService` draws a
    call on;
  * against the channels `Push.ensureChannels` actually creates.

Anything named and not created fails. Anything created and never named
is reported but does not fail — a channel with no sender yet is a
channel somebody is in the middle of adding, and Android keeps it
harmlessly.

Comments are stripped from both languages first, so a file may describe
a channel it no longer uses.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

SENDER = ROOT / "supabase" / "functions" / "send-push" / "index.ts"
PUSH_KT = (
    ROOT / "app" / "android" / "app" / "src" / "main" / "kotlin"
    / "my" / "iakauntan" / "iakauntan" / "Push.kt"
)
SERVICE_KT = PUSH_KT.parent / "PushService.kt"
MANIFEST = ROOT / "app" / "android" / "app" / "src" / "main" / "AndroidManifest.xml"

_BLOCK = re.compile(r"/\*.*?\*/", re.S)
_LINE = re.compile(r"^\s*//.*$", re.M)
_XML_COMMENT = re.compile(r"<!--.*?-->", re.S)

#: `const val MESSAGES = "chat"`
_CONST = re.compile(r'const\s+val\s+(\w+)\s*(?::\s*String\s*)?=\s*"([^"]+)"')

#: `NotificationChannel(\n    MESSAGES,` or `NotificationChannel("chat",`
_CREATED = re.compile(r'NotificationChannel\(\s*(?:"([^"]+)"|([\w.]+))\s*,')

#: `channel_id: "chat"`
_SENT = re.compile(r'channel_id:\s*"([^"]+)"')

#: `NotificationCompat.Builder(this, Push.CALLS)`
_DRAWN = re.compile(r'(?:NotificationCompat|Notification)\.Builder\([^,]+,\s*([\w."]+)\s*\)')

_DEFAULT_CHANNEL = re.compile(
    r'android:name="com\.google\.firebase\.messaging\.'
    r'default_notification_channel_id"\s*\n?\s*android:value="([^"]+)"'
)


def strip_code_comments(text: str) -> str:
    return _LINE.sub("", _BLOCK.sub("", text))


def resolve(name: str, consts: dict[str, str]) -> str | None:
    """A literal, a bare const, or `Push.CONST`. None if unresolvable."""
    if name.startswith('"') and name.endswith('"'):
        return name[1:-1]
    bare = name.rsplit(".", 1)[-1]
    return consts.get(bare)


def main() -> int:
    missing: list[str] = []
    for path in (SENDER, PUSH_KT, SERVICE_KT, MANIFEST):
        if not path.exists():
            missing.append(str(path.relative_to(ROOT)))
    if missing:
        for path in missing:
            print(f"::error::{path} is missing, so this gate cannot check it.")
        print()
        print("Both halves of push have to exist for the channels to be")
        print("comparable. If a file moved, move this gate with it.")
        return 1

    push_kt = strip_code_comments(PUSH_KT.read_text())
    service_kt = strip_code_comments(SERVICE_KT.read_text())
    sender = strip_code_comments(SENDER.read_text())
    manifest = _XML_COMMENT.sub("", MANIFEST.read_text())

    consts = dict(_CONST.findall(push_kt))

    created: set[str] = set()
    for literal, identifier in _CREATED.findall(push_kt):
        value = resolve(f'"{literal}"' if literal else identifier, consts)
        if value is None:
            print(
                f"::error::Push.kt creates a channel named `{identifier}`, "
                "which this gate cannot resolve to a string."
            )
            print()
            print("It reads `const val NAME = \"value\"` out of the same")
            print("file. A channel id built at run time cannot be compared")
            print("with the sender's, so it would have to be checked some")
            print("other way.")
            return 1
        created.add(value)

    if not created:
        print("::error::Push.kt creates no notification channels at all.")
        print()
        print("Either `ensureChannels` has gone, or this gate's parser has")
        print("stopped matching it — and a gate that matches nothing")
        print("passes everything. Both need looking at.")
        return 1

    # Everything that names a channel, and where it does it.
    named: list[tuple[str, str]] = []
    for channel in _SENT.findall(sender):
        named.append((channel, "supabase/functions/send-push/index.ts"))
    for identifier in _DRAWN.findall(service_kt):
        value = resolve(identifier, consts)
        named.append((
            value if value is not None else identifier,
            "PushService.kt",
        ))
    for channel in _DEFAULT_CHANNEL.findall(manifest):
        named.append((channel, "AndroidManifest.xml"))

    if not named:
        print("::error::Nothing names a notification channel any more.")
        print()
        print("`send-push` names one for every message it sends, so either")
        print("that stopped being true or this gate's parser has. A gate")
        print("with nothing to compare reports a clean sweep.")
        return 1

    unknown = [(c, where) for c, where in named if c not in created]
    if unknown:
        for channel, where in unknown:
            print(
                f"::error::{where} sends to notification channel "
                f"`{channel}`, which the app never creates."
            )
        print()
        print("Android DROPS a notification naming a channel that does not")
        print("exist. The sender still gets a 200 from FCM and the settings")
        print("card still says notifications are on, so nothing reports it:")
        print("the notification simply never arrives.")
        print()
        print("Created by `Push.ensureChannels`: " + ", ".join(sorted(created)))
        print()
        print("Fix it in whichever place is wrong — but in BOTH places if")
        print("the channel is being renamed, and remember that Android")
        print("keeps a channel somebody has already seen: a rename leaves")
        print("the old one on every handset that has run the old build.")
        return 1

    spoken = {channel for channel, _ in named}
    print(f"Notification channels created and used: {', '.join(sorted(spoken))}")
    for channel in sorted(created - spoken):
        print(f"  {channel}: created, and nothing sends to it yet")
    return 0


if __name__ == "__main__":
    sys.exit(main())
