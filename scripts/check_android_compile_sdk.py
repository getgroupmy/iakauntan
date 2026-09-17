#!/usr/bin/env python3
"""Every plugin in the tree compiles against the API the app needs.

    cd app && flutter pub get
    python3 scripts/check_android_compile_sdk.py

## What it would have caught

`flutter_plugin_android_lifecycle` requires anything depending on it to
compile against API 36. Five plugins in this tree pin a lower one in
their own `build.gradle`, and Gradle refuses the FIRST one it reaches:

    Execution failed for task ':file_picker:checkDebugAarMetadata'.
    > Dependency ':flutter_plugin_android_lifecycle' requires libraries
      and applications that depend on it to compile against version 36
      or later of the Android APIs.
      :file_picker is currently compiled against android-34.

Then it stops. So finding them by pushing is one CI round trip per
plugin, each one five minutes of Gradle, and the message only ever
names one of them.

`app/android/build.gradle.kts` raises them all with a floor, so this is
not a gate that has to pass for the build to work -- it is the thing
that tells you the floor is doing something, and WHICH plugins are
relying on it. The distinction matters when a plugin is bumped: if the
new version compiles against 36 on its own, this stops listing it, and
that is how the floor eventually becomes unnecessary rather than
permanent.

It also refuses a plugin pinned ABOVE the floor, which is the failure
the floor cannot fix: `compileSdk` is a raise-only floor by design, so
a plugin wanting 37 needs the floor moved, and nothing else would say
so until Gradle failed on it.

## Why the pub cache and not a Gradle run

Because there is no Android SDK on most machines this repository is
worked on, and `dl.google.com` is not reachable from some of them. The
`build.gradle` of every resolved plugin is on disk after `pub get`, and
reading them needs nothing but a file handle.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / 'app' / '.dart_tool' / 'package_config.json'
GRADLE = ROOT / 'app' / 'android' / 'build.gradle.kts'

COMPILE_SDK = re.compile(r'compileSdk(?:Version)?\s*[= ]\s*([0-9]+)')
FLOOR = re.compile(r'^\s*val floor = ([0-9]+)\s*$', re.M)

# The floor is applied from an `afterEvaluate` hook, and the same file
# later calls `evaluationDependsOn(":app")`, which evaluates eagerly.
# A hook registered AFTER that is refused outright --
#
#     Cannot run Project.afterEvaluate(Action) when the project is
#     already evaluated.
#
# -- which is how the first version of the floor failed: in ninety
# seconds, with a message that says nothing about compileSdk. Order is
# therefore part of the contract and not a matter of taste.
AFTER_EVALUATE = re.compile(r'^\s*afterEvaluate \{', re.M)
DEPENDS_ON = re.compile(r'evaluationDependsOn\(')


def without_comments(kotlin: str) -> str:
    """Kotlin with its comments removed.

    Needed because the file this scans EXPLAINS the ordering hazard, and
    the explanation quotes `evaluationDependsOn(":app")` by name. The
    first version of the ordering check matched that prose, decided the
    hook came after it, and refused the very arrangement it exists to
    require -- a check that punishes writing down why, which is the same
    mistake `scripts/check_web_plugin_registrant.py` made for the same
    reason.
    """
    kotlin = re.sub(r'/\*.*?\*/', '', kotlin, flags=re.S)
    return '\n'.join(
        line for line in kotlin.splitlines()
        if not line.lstrip().startswith('//'))


def floor_from_gradle():
    """The floor the build actually applies, read rather than repeated."""
    if not GRADLE.exists():
        return None
    m = FLOOR.search(GRADLE.read_text())
    return int(m.group(1)) if m else None


def plugin_roots():
    if not CONFIG.exists():
        return None
    config = json.loads(CONFIG.read_text())
    out = []
    for pkg in config.get('packages', []):
        root = pkg.get('rootUri', '')
        if root.startswith('file://'):
            path = Path(root[len('file://'):])
        else:
            path = (CONFIG.parent / root).resolve()
        out.append((pkg.get('name', '?'), path))
    return out


def main() -> int:
    floor = floor_from_gradle()
    if floor is None:
        print('could not read the compileSdk floor from')
        print(f'    {GRADLE.relative_to(ROOT)}')
        print()
        print('    It is the `val floor = <n>` line in the subprojects')
        print('    block. If that block has been removed, this check has')
        print('    nothing to measure against and should go with it.')
        return 2

    gradle = without_comments(GRADLE.read_text())
    hook = AFTER_EVALUATE.search(gradle)
    eager = DEPENDS_ON.search(gradle)
    if hook and eager and hook.start() > eager.start():
        print('The compileSdk floor is registered too late to run.')
        print()
        print(f'    In {GRADLE.relative_to(ROOT)}, the `afterEvaluate` hook')
        print('    that raises compileSdk appears AFTER a call to')
        print('    `evaluationDependsOn(...)`, which evaluates its target')
        print('    eagerly. Gradle then refuses the hook outright:')
        print()
        print('        Cannot run Project.afterEvaluate(Action) when the')
        print('        project is already evaluated.')
        print()
        print('    Move the floor block above it. That failure takes ninety')
        print('    seconds of Gradle to produce and its message says')
        print('    nothing about compileSdk.')
        return 1

    roots = plugin_roots()
    if roots is None:
        print(f'no {CONFIG.relative_to(ROOT)}. Run: cd app && flutter pub get')
        return 2

    below, above = [], []
    for name, path in roots:
        for gradle in ('android/build.gradle', 'android/build.gradle.kts'):
            f = path / gradle
            if not f.exists():
                continue
            m = COMPILE_SDK.search(f.read_text())
            if m:
                value = int(m.group(1))
                if value < floor:
                    below.append((value, name))
                elif value > floor:
                    above.append((value, name))
            break

    if above:
        print(f'A plugin wants a higher compileSdk than the floor ({floor}).')
        print()
        for value, name in sorted(above, reverse=True):
            print(f'    {name} pins {value}')
        print()
        print('    The floor in app/android/build.gradle.kts only ever')
        print('    RAISES, so it cannot help here. Raise the floor to match')
        print('    the highest of these, and the app with it.')
        return 1

    if below:
        print(f'ok   the floor ({floor}) is carrying '
              f'{len(below)} plugin(s) that pin lower:')
        for value, name in sorted(below):
            print(f'       {value}  {name}')
        print()
        print('     Not a failure. Each one stops being listed when its')
        print('     own release compiles against the floor, and when the')
        print('     list empties the floor can go.')
        return 0

    print(f'ok   every plugin compiles against at least {floor} on its own.')
    print('     The floor in app/android/build.gradle.kts is no longer')
    print('     carrying anything and can be removed.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
