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
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PUBSPEC = ROOT / 'app' / 'pubspec.yaml'
BUILD = ROOT / 'app' / '.dart_tool' / 'flutter_build'
PACKAGE_CONFIG = ROOT / 'app' / '.dart_tool' / 'package_config.json'

# What a no-op must not contain. The outage was one JS call in a
# `registerWith`, so a local package that reaches for JS at all has
# stopped being the thing this check is protecting.
JS_IN_A_NOOP = ('dart:js_interop', 'package:web/', '@JS(', 'external ')


def section(text: str, name: str) -> str:
    """One top-level block of a pubspec, by name."""
    m = re.search(rf'^{name}:\s*$(.*?)(?=^\S|\Z)', text, re.S | re.M)
    return m.group(1) if m else ''


def without_comments(dart: str) -> str:
    """Dart source with its comments taken out.

    Needed because the file this scans EXPLAINS the outage, quoting the
    `@JS('PasskeyAuthenticator.init')` line that caused it. Scanning
    the raw text refused the very file whose comment is the reason the
    check exists -- which is a check that punishes writing down why.
    """
    dart = re.sub(r'/\*.*?\*/', '', dart, flags=re.S)
    return '\n'.join(
        line for line in dart.splitlines()
        if not line.lstrip().startswith('//'))


def resolved_root(name: str) -> str | None:
    """Where `pub` actually resolved a package to, or None.

    This is the answer the generated registrant cannot give. See the
    note on the registrant check in `main`.
    """
    if not PACKAGE_CONFIG.exists():
        return None
    try:
        config = json.loads(PACKAGE_CONFIG.read_text())
    except ValueError:
        return None
    for package in config.get('packages', []):
        if package.get('name') == name:
            return package.get('rootUri')
    return None


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
    #
    # NOT a search for the NAME, which is what this was at first and
    # what a `flutter build web` proved wrong the day the plugin was
    # added back. `passkeys` federates by `default_package`, so Flutter
    # generates `import 'package:passkeys_web/passkeys_web.dart';` and
    # `PasskeysWeb.registerWith(registrar)` whatever that package turns
    # out to be. The override does not remove the line -- it changes
    # which package the line RESOLVES to, and the name in the generated
    # file is identical either way.
    #
    # A check on the name is therefore both wrong answers at once: it
    # refuses a bundle that is safe, and it would pass a bundle that is
    # not if the plugin were ever pulled in under another name. What
    # decides is `package_config.json`, which records where `pub` put
    # each package.
    registrants = sorted(BUILD.glob('*/web_plugin_registrant.dart'))
    registered = [r for r in registrants if 'passkeys_web' in r.read_text()]
    if registered:
        where = resolved_root('passkeys_web')
        if where is None:
            problems.append(
                'a build registers passkeys_web and there is no '
                'package_config.json\n'
                '        to say which passkeys_web that is. Run `flutter '
                'pub get`.')
        elif '.pub-cache' in where or where.startswith('file:///'):
            problems.append(
                f'{registered[0].relative_to(ROOT)} registers the '
                f'PUBLISHED passkeys_web.\n'
                f'        Resolved to {where}\n'
                '        This is the generated file that white-screened '
                'production: its\n'
                '        registerWith calls a JS global this app does not '
                'load, before\n'
                '        runApp, and every page goes blank.')
        else:
            # It resolves locally. Make sure that local package is still
            # the no-op it is supposed to be, because an override
            # pointing at a path is only as good as what is at the path.
            local = (PACKAGE_CONFIG.parent / where).resolve()
            for dart in sorted(local.glob('lib/**/*.dart')):
                body = without_comments(dart.read_text())
                for marker in JS_IN_A_NOOP:
                    if marker in body:
                        problems.append(
                            f'{dart.relative_to(ROOT)} contains '
                            f'`{marker.strip()}`.\n'
                            '        The local passkeys_web has to '
                            'register and do NOTHING else.\n'
                            '        One JS call in a registerWith is the '
                            'whole outage.')

    if problems:
        print('The web bundle must not carry passkeys_web.')
        print()
        for p in problems:
            print(f'    {p}')
        return 1

    where = (f'and {len(registrants)} generated registrant(s) resolve it '
             'to the local no-op'
             if registrants
             else 'no web build here to read a registrant from')
    if wants_passkeys:
        print(f'ok   passkeys is pinned away from the web bundle, {where}')
    else:
        print(f'ok   nothing depends on passkeys, {where}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
