#!/usr/bin/env python3
"""The release workflows check for the secrets they actually use.

    python3 scripts/check_release_secrets.py

Both release workflows open with a step that lists the secrets they
need and STOPS -- politely, with a summary -- when one is missing. That
step is hand-written, and it is a second copy of a list that already
exists implicitly in the `env:` blocks further down.

Two ways the copies drift, and neither announces itself:

  * **Checked and never used.** A secret in the readiness list that
    nothing reads. Somebody is asked to create it, does, and it makes
    no difference. Harmless until it is the thing they think they got
    wrong when the build fails for another reason.

  * **Used and never checked.** The worse direction. The workflow
    reports itself ready, builds for twenty minutes, and fails at the
    step that needed the missing value -- which is the exact failure
    the readiness gate was written to prevent. On the iOS side that
    build costs ten times an Ubuntu one.

The third check is narrower and is about Android only: the keys the
workflow writes into `key.properties` have to be the keys
`build.gradle.kts` reads out of it. A mismatch there does not fail the
build. It falls back to the DEBUG key and produces a bundle that Play
refuses after the upload.
"""
import re
import sys

import yaml
from pathlib import Path

WORKFLOWS = Path(".github/workflows")
GRADLE = Path("app/android/app/build.gradle.kts")

# Secrets a workflow may use WITHOUT gating on them, with the reason.
# Anything not listed here is either gated or reported.
OPTIONAL = {
    "WEB_PUSH_PUBLIC_KEY":
        "the build passes it as a dart-define and the app degrades to "
        "no web push without it, so a release should not stop for it",
}


def readiness_list(path: Path) -> set[str]:
    """The secrets the readiness step can see.

    Read from the step's `env:` block rather than from the shell inside
    it. The shell is the wrong thing to parse: the Android gate builds
    its list conditionally, because the Play credential is needed only
    to SEND and a build-only run must not demand it. An earlier version
    of this function matched a literal `for name in A B C; do` and went
    silently blind the moment that loop grew an `if`.

    The `env:` block is the real contract in any case. A step cannot
    check a secret it was not given, whatever its shell says.
    """
    doc = yaml.safe_load(path.read_text())
    for job in (doc.get("jobs") or {}).values():
        for step in job.get("steps") or []:
            if step.get("id") == "creds":
                return {
                    name for name, value in (step.get("env") or {}).items()
                    if "secrets." in str(value)
                }
    return set()


def used(text: str) -> set[str]:
    """Every `secrets.NAME` the workflow mentions."""
    return set(re.findall(r"secrets\.([A-Z][A-Z0-9_]+)", text))


def check_workflow(path: Path) -> list[str]:
    text = path.read_text()
    gated, reads = readiness_list(path), used(text)
    if not gated:
        return [f"  {path.name}: no step with `id: creds` carrying secrets "
                "in its env — either the readiness gate went, or it was "
                "renamed and this gate was not"]

    problems = []
    for name in sorted(gated - reads):
        problems.append(
            f"  {path.name}: {name} is checked for but never used — "
            "somebody is asked to create a secret that does nothing"
        )
    for name in sorted(reads - gated - set(OPTIONAL)):
        problems.append(
            f"  {path.name}: {name} is used but not checked for — the "
            "workflow will report itself ready and then fail on it, "
            "after the build"
        )
    return problems


def check_key_properties() -> list[str]:
    """The Android keystore keys, written in one file and read in another."""
    wf = WORKFLOWS / "android-release.yml"
    if not wf.exists():
        return []

    written = re.search(
        r"cat > android/key\.properties <<PROPS\n(.*?)\n\s*PROPS",
        wf.read_text(), re.S,
    )
    if not written:
        return ["  android-release.yml: the key.properties heredoc is not "
                "where this gate looks for it. If it moved, move this too."]

    keys = set(re.findall(r"^\s*([a-zA-Z]+)=", written.group(1), re.M))
    read = set(re.findall(r'keyProperties\.getProperty\("(\w+)"\)',
                          GRADLE.read_text()))

    problems = []
    for name in sorted(keys - read):
        problems.append(
            f"  key.properties carries '{name}' and build.gradle.kts never "
            "reads it"
        )
    for name in sorted(read - keys):
        problems.append(
            f"  build.gradle.kts reads '{name}' and the workflow never "
            "writes it — the release build falls back to the DEBUG key, "
            "and Play refuses that AFTER the upload"
        )
    return problems


def main() -> None:
    problems: list[str] = []
    found = 0
    for path in sorted(WORKFLOWS.glob("*-release.yml")):
        found += 1
        problems += check_workflow(path)
    if not found:
        sys.exit("no *-release.yml workflows found — this gate is looking "
                 "in the wrong place")
    problems += check_key_properties()

    if problems:
        print("the release workflows and their secrets disagree:")
        print("\n".join(problems))
        sys.exit(1)

    print(f"every release secret is both checked and used "
          f"({found} workflows)")


if __name__ == "__main__":
    main()
