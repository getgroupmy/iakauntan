#!/usr/bin/env python3
"""Does the or() gate still catch what it claims to?

    python3 scripts/check_or_filters_test.py

A gate that has stopped matching passes everything and says so
cheerfully. This writes the bug back into a scratch tree and requires
the gate to find it, and writes the fix and requires it not to.
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
GATE = HERE / "check_or_filters.py"

RAW = """
class Repo {
  Future<void> contacts(String search) async {
    final q = search.trim();
    query = query.or('name.ilike.%$q%,code.ilike.%$q%');
  }
}
"""

ESCAPED = """
class Repo {
  Future<void> contacts(String search) async {
    final q = search.trim();
    query = query.or([
      Repo.orLike('name', q),
      Repo.orLike('code', q),
    ].join(','));
  }
}
"""

LITERAL = """
class Repo {
  Future<void> open() async {
    query = query.or('closed_at.is.null,status.eq.open');
  }
}
"""


def run(source: str) -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        lib = root / "app" / "lib" / "src" / "data"
        lib.mkdir(parents=True)
        (lib / "repository.dart").write_text(source, encoding="utf-8")
        # The gate reads ROOT from its own location, so it is copied in.
        copy = root / "scripts"
        copy.mkdir()
        (copy / "check_or_filters.py").write_text(
            GATE.read_text(encoding="utf-8"), encoding="utf-8"
        )
        return subprocess.run(
            [sys.executable, str(copy / "check_or_filters.py")],
            capture_output=True,
            text=True,
        ).returncode


def main() -> int:
    failures = []

    if run(RAW) == 0:
        failures.append(
            "the gate passed a raw interpolation -- it has stopped "
            "matching, and would have passed the live PGRST100 bug"
        )
    if run(ESCAPED) != 0:
        failures.append(
            "the gate failed an ESCAPED filter -- a gate that refuses "
            "the fix is a gate somebody turns off"
        )
    if run(LITERAL) != 0:
        failures.append(
            "the gate failed a literal or() over fixed values -- those "
            "carry no user input and are the common case"
        )

    if failures:
        for f in failures:
            print(f"FAIL: {f}")
        return 1
    print("The or() gate catches a raw value, and only a raw value.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
