#!/usr/bin/env python3
"""Does the RTP capabilities gate still catch the one-line regression?

    python3 scripts/check_rtp_capabilities_test.py

The bug the gate guards is silent — the call connects, audio and video
flow, and only the picture's orientation says anything is wrong — and
nothing in the widget suite can reach the call site. So a gate that has
stopped matching is indistinguishable from an engine that is correct.

This builds a scratch tree, puts the lossy call back in each of the
shapes somebody would write it, and requires the gate to find it. Then
it checks the other direction: that the gate also fails when nothing
calls the complete serialiser at all, which is the failure a gate has
instead of a bug. And it checks that a COMMENT naming the lossy call is
not mistaken for one, because the real engine carries exactly such a
comment explaining why it does not call it.
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
GATE = HERE / "check_rtp_capabilities.py"

ENGINE = "app/lib/src/features/chat/call_engine.dart"
HELPER = "app/lib/src/features/chat/call_rtp.dart"

GOOD_ENGINE = """
import 'call_rtp.dart';

class RealCallEngine {
  Future<void> join() async {
    // `rtpCapabilitiesToMap`, not `device.rtpCapabilities.toMap()`,
    // which drops every header extension.
    await _request('join', {
      'rtpCapabilities': rtpCapabilitiesToMap(device.rtpCapabilities),
    });
  }
}
"""

HELPER_SRC = """
Map<String, dynamic> rtpCapabilitiesToMap(RtpCapabilities caps) => {};
"""


def run(tree: Path) -> subprocess.CompletedProcess:
    """Runs the COPY inside the scratch tree, not the real gate.

    The gate finds the repository from its own `__file__`, so invoking
    the real path would have it check the real files no matter what this
    tree contains. Every case here would then report the same answer and
    the run would look like a clean sweep over nothing -- which is what
    happened on the first draft, and is why `scripts/mutate.py` insists
    on a control.
    """
    return subprocess.run(
        [sys.executable, str(tree / "scripts" / GATE.name)],
        cwd=tree,
        capture_output=True,
        text=True,
    )


def build(tmp: Path, engine: str, helper: str | None = HELPER_SRC) -> Path:
    tree = tmp / "tree"
    scripts = tree / "scripts"
    scripts.mkdir(parents=True, exist_ok=True)
    (scripts / GATE.name).write_text(GATE.read_text())
    path = tree / ENGINE
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(engine)
    helper_path = tree / HELPER
    if helper is None:
        if helper_path.exists():
            helper_path.unlink()
    else:
        helper_path.write_text(helper)
    return tree


def main() -> int:
    failures: list[str] = []

    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw)

        # 1. The real shape passes.
        result = run(build(tmp, GOOD_ENGINE))
        if result.returncode != 0:
            failures.append(
                "the gate fails the CORRECT engine, so every other result "
                f"here is worthless:\n{result.stdout}{result.stderr}"
            )

        # 2. The regression, in the shapes somebody writes it.
        for label, call in [
            ("the plain revert", "device.rtpCapabilities.toMap()"),
            ("a different receiver", "_device!.rtpCapabilities.toMap()"),
            ("spaced out by a formatter", "device.rtpCapabilities\n        .toMap()"),
            ("spaces inside the call", "device.rtpCapabilities.toMap( )"),
        ]:
            bad = GOOD_ENGINE.replace(
                "rtpCapabilitiesToMap(device.rtpCapabilities)", call
            )
            result = run(build(tmp, bad))
            if result.returncode == 0:
                failures.append(f"{label} was not caught: {call!r}")
            elif "ninety degrees" not in result.stdout:
                failures.append(
                    f"{label} was caught without saying what it costs; a gate "
                    "that only says NO teaches nobody why"
                )

        # 3. A comment naming it is not a call. The real engine has one.
        commented = """
import 'call_rtp.dart';
class RealCallEngine {
  Future<void> join() async {
    // NOT device.rtpCapabilities.toMap(), which drops the extensions.
    /* and not rtpCapabilities.toMap() in a block comment either */
    await _request('join', {
      'rtpCapabilities': rtpCapabilitiesToMap(device.rtpCapabilities),
    });
  }
}
"""
        result = run(build(tmp, commented))
        if result.returncode != 0:
            failures.append(
                "a comment naming the lossy call was read as a call, so the "
                "engine cannot explain itself without failing the gate:\n"
                f"{result.stdout}{result.stderr}"
            )

        # 4. Nothing calling the complete serialiser fails too. Without
        #    this the gate passes a file that sends no capabilities at
        #    all, which has the identical symptom.
        silent = """
class RealCallEngine {
  Future<void> join() async {
    await _request('join', {'displayName': 'somebody'});
  }
}
"""
        result = run(build(tmp, silent))
        if result.returncode == 0:
            failures.append(
                "an engine that never serialises its capabilities passed; "
                "that has the same symptom as the bug"
            )

        # 5. A missing helper is reported rather than passed over.
        result = run(build(tmp, GOOD_ENGINE, helper=None))
        if result.returncode == 0:
            failures.append("a missing call_rtp.dart passed")

    if failures:
        for failure in failures:
            print(f"FAIL {failure}")
        return 1

    print("check_rtp_capabilities.py catches the revert, in four shapes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
