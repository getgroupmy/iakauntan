#!/usr/bin/env python3
"""The destinations the console offers are the ones the workflow takes.

    python3 scripts/check_release_choices.py

Each release workflow declares its destination as a `choice` input with
a fixed list of options — `lane` for iOS, `track` for Android.
`_shared/release.ts` holds the same list again, because the function
checks the value against an allow-list before it ever reaches GitHub.

Two copies, and both ways they can drift are bad in a way nobody sees
until somebody presses a button:

  * **Offered and not accepted.** The console shows a destination, the
    function passes it, and GitHub answers

        422 {"message":"Unexpected inputs provided"}

    which names neither the input nor the value. `dispatchRefusal`
    deliberately does NOT translate that one, because the same 422 is
    also what a genuinely missing workflow produces, so the sentence
    would be wrong half the time.

  * **Accepted and not offered.** A destination the workflow supports
    that nobody can pick. Harmless until somebody needs the beta track
    and concludes the pipeline cannot do it.

The input NAME is checked too, and that is the one worth having: `lane`
and `track` are interchangeable-looking strings, and sending the wrong
one produces the same unreadable 422.
"""
import re
import sys
from pathlib import Path

import yaml

WORKFLOWS = Path(".github/workflows")
RELEASE_TS = Path("supabase/functions/_shared/release.ts")

# The record in release.ts -> the workflow it dispatches.
PLATFORMS = {
    "IOS": "ios-release.yml",
    "ANDROID": "android-release.yml",
}


def declared() -> dict[str, tuple[str, list[str]]]:
    """Each platform's input name and choices, read out of release.ts."""
    source = RELEASE_TS.read_text()
    out: dict[str, tuple[str, list[str]]] = {}
    for name in PLATFORMS:
        block = re.search(
            rf"export const {name}: ReleasePlatform = \{{(.*?)\n\}};",
            source, re.S,
        )
        if not block:
            sys.exit(f"{RELEASE_TS}: no `export const {name}` — if the "
                     "platform records moved, move this gate too.")
        body = block.group(1)
        input_name = re.search(r'input:\s*"([^"]+)"', body)
        choices = re.search(r"choices:\s*\[(.*?)\]", body, re.S)
        if not input_name or not choices:
            sys.exit(f"{RELEASE_TS}: {name} has no `input` or `choices`.")
        out[name] = (
            input_name.group(1),
            re.findall(r'"([^"]+)"', choices.group(1)),
        )
    return out


def accepted(workflow: str) -> tuple[str, list[str]]:
    """The workflow's `choice` input: its name, and its options."""
    path = WORKFLOWS / workflow
    if not path.exists():
        sys.exit(f"{path} does not exist, and release.ts dispatches it.")
    # `on` is parsed by PyYAML as the boolean True, which is a trap
    # worth knowing about rather than working around blindly.
    doc = yaml.safe_load(path.read_text())
    trigger = doc.get("on") or doc.get(True) or {}
    inputs = (trigger.get("workflow_dispatch") or {}).get("inputs") or {}
    for name, spec in inputs.items():
        if (spec or {}).get("type") == "choice":
            return name, list((spec or {}).get("options") or [])
    sys.exit(f"{path} has no `choice` input, and release.ts expects one.")


def main() -> None:
    problems: list[str] = []
    checked = 0

    for platform, workflow in PLATFORMS.items():
        want_input, want_choices = declared()[platform]
        got_input, got_choices = accepted(workflow)
        checked += 1

        if want_input != got_input:
            problems.append(
                f"  {platform} sends `{want_input}` and {workflow} declares "
                f"`{got_input}` — GitHub answers 422 'Unexpected inputs', "
                "which names neither"
            )

        for value in sorted(set(want_choices) - set(got_choices)):
            problems.append(
                f"  {platform} offers '{value}' and {workflow} does not "
                "accept it — the button fails with an unreadable 422"
            )
        for value in sorted(set(got_choices) - set(want_choices)):
            problems.append(
                f"  {workflow} accepts '{value}' and {platform} never "
                "offers it — nobody can release there"
            )

        # Order matters too: it is the order the console draws them in,
        # and the first is the default.
        if want_choices != got_choices and \
                set(want_choices) == set(got_choices):
            problems.append(
                f"  {platform} and {workflow} list the same destinations "
                f"in a different order ({want_choices} vs {got_choices}). "
                "The first is the default, so this changes what a careless "
                "press does"
            )

    if problems:
        print("release destinations disagree:")
        print("\n".join(problems))
        sys.exit(1)

    print(f"every release destination is offered and accepted "
          f"({checked} platforms)")


if __name__ == "__main__":
    main()
