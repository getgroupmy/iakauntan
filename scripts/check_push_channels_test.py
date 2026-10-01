#!/usr/bin/env python3
"""Does the channel gate still catch a renamed channel?

    python3 scripts/check_push_channels_test.py

The bug this gate exists for is silent at every layer — FCM answers
200, the register says the handset is live, and nothing arrives — so a
gate that has stopped matching is indistinguishable from a system that
works. This builds a scratch tree with the four files in it, renames
one side of the channel in each direction, and requires the gate to
find it; then checks that it also notices its own parsers matching
nothing, which is the failure a gate has instead of a bug.
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
GATE = HERE / "check_push_channels.py"

PUSH_KT = """
package my.iakauntan.iakauntan

object Push {
    const val MESSAGES = "chat"
    const val CALLS = "calls"

    fun ensureChannels(context: Context) {
        manager.createNotificationChannel(
            NotificationChannel(
                MESSAGES,
                "Chat messages",
                NotificationManager.IMPORTANCE_HIGH,
            ),
        )
        manager.createNotificationChannel(
            NotificationChannel(
                CALLS,
                "Calls",
                NotificationManager.IMPORTANCE_HIGH,
            ),
        )
    }
}
"""

SERVICE_KT = """
package my.iakauntan.iakauntan

class PushService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        val notification = NotificationCompat.Builder(this, Push.CALLS)
            .setContentTitle("Incoming call")
            .build()
    }
}
"""

SENDER = """
function buildMessage(target, body) {
  return {
    android: {
      priority: "high",
      notification: {
        title: body.title,
        channel_id: "chat",
      },
    },
  };
}
"""

MANIFEST = """<manifest>
    <application>
        <meta-data
            android:name="com.google.firebase.messaging.default_notification_channel_id"
            android:value="chat"/>
    </application>
</manifest>
"""

#: The whole point. A file may describe a channel it no longer sends to.
SENDER_WITH_A_COMMENT = """
// It used to be `channel_id: "messages"` before the rename.
/* and this block comment names channel_id: "ancient" as well. */
function buildMessage(target, body) {
  return { android: { notification: { channel_id: "chat" } } };
}
"""


def run(
    *,
    push_kt: str = PUSH_KT,
    service_kt: str = SERVICE_KT,
    sender: str = SENDER,
    manifest: str = MANIFEST,
) -> tuple[int, str]:
    """Run the gate over a scratch tree holding the four files."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        kotlin = (
            root / "app" / "android" / "app" / "src" / "main" / "kotlin"
            / "my" / "iakauntan" / "iakauntan"
        )
        kotlin.mkdir(parents=True)
        (kotlin / "Push.kt").write_text(push_kt, encoding="utf-8")
        (kotlin / "PushService.kt").write_text(service_kt, encoding="utf-8")

        android = root / "app" / "android" / "app" / "src" / "main"
        (android / "AndroidManifest.xml").write_text(manifest, encoding="utf-8")

        function = root / "supabase" / "functions" / "send-push"
        function.mkdir(parents=True)
        (function / "index.ts").write_text(sender, encoding="utf-8")

        scripts = root / "scripts"
        scripts.mkdir()
        copy = scripts / "check_push_channels.py"
        copy.write_text(GATE.read_text(encoding="utf-8"), encoding="utf-8")

        done = subprocess.run(
            [sys.executable, str(copy)], capture_output=True, text=True
        )
        return done.returncode, done.stdout + done.stderr


def main() -> int:
    failures: list[str] = []

    def expect(label: str, got: int, want: int, output: str) -> None:
        if got != want:
            failures.append(f"{label}: exit {got}, wanted {want}\n{output}")

    code, out = run()
    expect("the two sides as they are agree", code, 0, out)

    # The rename, from the sender's side. This is the real bug: one
    # string in TypeScript, and every Android notification silently
    # stops arriving.
    code, out = run(sender=SENDER.replace('"chat"', '"messages"'))
    expect("a channel the sender invents is refused", code, 1, out)
    if code == 1 and "messages" not in out:
        failures.append(f"the refusal does not name the channel:\n{out}")

    # And from the app's side, which is the same bug approached from the
    # other direction: the channel is renamed where it is created and
    # the sender is left alone.
    code, out = run(push_kt=PUSH_KT.replace('MESSAGES = "chat"', 'MESSAGES = "msg"'))
    expect("a channel the app renames is refused", code, 1, out)

    # The manifest's fallback names one too, and it is the one nobody
    # thinks to change.
    code, out = run(manifest=MANIFEST.replace('value="chat"', 'value="general"'))
    expect("and so is the manifest's default channel", code, 1, out)

    # The call channel, which is drawn in Kotlin rather than named by
    # the sender, and resolves through `Push.CALLS`.
    code, out = run(service_kt=SERVICE_KT.replace("Push.CALLS", 'Push.RINGING'))
    expect("an unresolvable channel in the service is refused", code, 1, out)

    # A literal in the service instead of the shared constant, which is
    # the way the call channel can actually drift.
    code, out = run(service_kt=SERVICE_KT.replace("Push.CALLS", '"ring"'))
    expect("a hardcoded channel the app does not create is refused", code, 1, out)

    # Renaming the constant moves both sides at once, because both read
    # it. Allowed, and worth asserting: it is the reason the service
    # names `Push.CALLS` rather than a string.
    code, out = run(push_kt=PUSH_KT.replace('CALLS = "calls"', 'CALLS = "ringing"'))
    expect("renaming the shared constant moves both sides", code, 0, out)

    code, out = run(sender=SENDER_WITH_A_COMMENT)
    expect("a file may describe a channel it no longer sends to", code, 0, out)

    # A gate whose parsers match nothing reports a clean sweep, which is
    # the one failure it cannot be allowed to have quietly.
    code, out = run(push_kt="object Push { }")
    expect("a parser that finds no channels says so", code, 1, out)

    code, out = run(
        sender="function buildMessage() { return {}; }",
        service_kt="class PushService { }",
        manifest="<manifest/>",
    )
    expect("and so does one that finds nothing naming them", code, 1, out)

    # A channel created before anything sends to it is somebody midway
    # through adding one, and Android keeps it harmlessly.
    code, out = run(
        push_kt=PUSH_KT.replace(
            'const val CALLS = "calls"',
            'const val CALLS = "calls"\n    const val LATER = "later"',
        ).replace(
            "    }\n}",
            "        manager.createNotificationChannel(\n"
            "            NotificationChannel(LATER, \"Later\", 3),\n"
            "        )\n    }\n}",
        )
    )
    expect("a channel with no sender yet is allowed", code, 0, out)
    if code == 0 and "nothing sends to it yet" not in out:
        failures.append(f"but it is not reported either:\n{out}")

    if failures:
        print("\n\n".join(failures), file=sys.stderr)
        return 1
    print("the push-channel gate still catches a renamed channel")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
