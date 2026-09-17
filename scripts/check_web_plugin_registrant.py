#!/usr/bin/env python3
"""The `passkeys` plugin must not reach the web bundle.

    python3 scripts/check_web_plugin_registrant.py

`docs/passkeys.md` ends with an instruction, and this is it: "Whatever
the approach, the test that would have caught this is the one to write
first."

## What it would have caught

The `passkeys` plugin (Corbado) was added for Android and iOS. It
worked. It then WHITE-SCREENED PRODUCTION on deploy -- the landing
page included, which has nothing to do with passkeys.

`passkeys` declares a web implementation, `passkeys_web`. Flutter
generates `web_plugin_registrant.dart` from the platform declarations
of every package in the tree, so adding the plugin for a phone silently
enrols `passkeys_web` into the WEB bundle too. There is no per-platform
dependency in `pubspec.yaml` and nothing asks whether you wanted it.

`PasskeysWeb.registerWith` then runs inside `registerPlugins()`, which
runs BEFORE `runApp`, and its last line calls

    @JS('PasskeyAuthenticator.init')
    external void init();

`PasskeyAuthenticator` is a global that exists only if Corbado's
`bundle.js` is in `index.html`. It is not, and `script-src 'self'`
would refuse to load it if it were. So `init()` throws during
bootstrap, `main()` never finishes, and every page is blank.

Nothing caught it. `flutter analyze` is clean, `flutter build web`
compiles it happily, and the failure is a missing JS global at runtime
in a browser.

## Why this checks the pubspec rather than the generated file

The obvious check is the one `docs/passkeys.md` describes: build for
web and assert `.dart_tool/flutter_build/*/web_plugin_registrant.dart`
does not mention `passkeys_web`. That needs a web build, which in this
repository happens only in the deploy job -- so it would fire at
deploy, which is where the white screen already fired.

This fires at the moment the mistake is MADE: the commit that adds the
plugin. If `passkeys` is a dependency, `dependency_overrides` must
point `passkeys_web` at a local package that implements
`PasskeysPlatform` and registers without touching any JS. The web half
of this app has never needed the plugin -- `passkey_web.dart` calls the
browser's own WebAuthn -- so a no-op there loses nothing.

It also checks the generated registrant WHEN ONE EXISTS, so a local
`flutter build web` gets the stronger answer for free. Absent, it says
so rather than passing quietly: a check that reports success for a
file it never found is how a gate stops meaning anything.

Silent today, because nothing depends on `passkeys`. That is the point
of a tripwire.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PUBSPEC = ROOT / 'app' / 'pubspec.yaml'
BUILD = ROOT / 'app' / '.dart_tool' / 'flutter_build'


def section(text: str, name: str) -> str:
    """One top-level block of a pubspec, by name."""
    m = re.search(rf'^{name}:\s*$(.*?)(?=^\S|\Z)', text, re.S | re.M)
    return m.group(1) if m else ''


def main() -> int:
    if not PUBSPEC.exists():
        print(f'no pubspec at {PUBSPEC}', file=sys.stderr)
        return 2
    text = PUBSPEC.read_text()

    deps = section(text, 'dependencies')
    wants_passkeys = re.search(r'^\s{2}passkeys\s*:', deps, re.M) is not None

    problems = []
    if wants_passkeys:
        overrides = section(text, 'dependency_overrides')
        pinned = re.search(r'^\s{2}passkeys_web\s*:', overrides, re.M)
        if not pinned:
            problems.append(
                '`passkeys` is a dependency and `passkeys_web` is not '
                'overridden.\n'
                '        Flutter will enrol passkeys_web into the WEB '
                'bundle, and its\n'
                '        registrant calls a JS global this app does not '
                'load. Every\n'
                '        page goes blank before main() finishes. See '
                'docs/passkeys.md.')
        elif 'path:' not in overrides.split('passkeys_web:', 1)[1][:200]:
            problems.append(
                '`passkeys_web` is overridden, but not at a local `path:`.\n'
                '        The override has to be a no-op package that '
                'registers\n'
                '        without touching any JS. A version override is '
                'still the\n'
                '        real implementation.')

    # The stronger check, when a build has been run. Never a substitute:
    # a registrant that does not exist is not a registrant that is clean.
    registrants = sorted(BUILD.glob('*/web_plugin_registrant.dart'))
    for r in registrants:
        if 'passkeys_web' in r.read_text():
            problems.append(
                f'{r.relative_to(ROOT)} registers passkeys_web.\n'
                '        This is the generated file that white-screened '
                'production.')

    if problems:
        print('The web bundle must not carry passkeys_web.')
        print()
        for p in problems:
            print(f'    {p}')
        return 1

    where = (f'and {len(registrants)} generated registrant(s) are clean'
             if registrants
             else 'no web build here to read a registrant from')
    if wants_passkeys:
        print(f'ok   passkeys is pinned away from the web bundle, {where}')
    else:
        print(f'ok   nothing depends on passkeys, {where}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
