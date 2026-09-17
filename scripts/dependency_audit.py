#!/usr/bin/env python3
"""What this project actually depends on, and whether anybody has
published a vulnerability in it.

Nothing in CI watched either dependency tree until this. The ruflo
security plugin was installed to close that gap and did not: its
`cve --list` step runs `npm audit`, and this repository has no
`package.json` at all, so it reported a clean tree by auditing nothing.
See `docs/ruflo.md`.

There are two real trees here and they are in different ecosystems:

  * **Dart** -- `app/pubspec.lock`, which is where the resolved
    versions live. `pubspec.yaml` holds carets; the lock holds the
    number that actually ships.
  * **Deno** -- the edge functions, which have no lockfile and no
    manifest. What they depend on is written inline in every `import`,
    which is why the census below exists.

## Two halves, and only one of them needs the network

The **pins** half is arithmetic on files in this repository: which
module specifiers exist, whether each carries a version, and whether
the set has changed. It cannot flake and it runs with `--offline`.

The **advisories** half asks OSV (api.osv.dev) whether anybody has
published a vulnerability against a resolved version. It needs the
network, and when it cannot reach OSV it FAILS rather than passing --
"the advisory database was unreachable" and "there are no advisories"
are not the same sentence, and a security check whose green means the
second when it meant the first is worse than no check.

  scripts/dependency_audit.py              # both halves
  scripts/dependency_audit.py --offline    # pins only, no network
  python3 -m unittest scripts.dependency_audit_test   # the parsers
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ---------------------------------------------------------------------
# The Deno census
# ---------------------------------------------------------------------
# Every module specifier the edge functions may import, and the exact
# text of it. The same idea as `app/test/dropdown_census_test.dart`: the
# list is frozen, so adding a dependency -- or letting one float --
# fails here by name rather than being noticed a year later.
#
# Both entries below are MAJOR RANGES rather than pins, which is a
# finding and not an endorsement: `jsr:@supabase/supabase-js@2` resolves
# to whatever 2.x jsr serves on the day a function is deployed, so a
# minor release changes what runs in production with no commit in this
# repository. `supabase/functions/_local_check/check_locally.sh` stubs
# this package precisely because it cannot see it, which means the type
# error a minor release introduces is found by CI at the earliest.
#
# They are recorded as they are rather than tightened here because
# pinning them is a change to sixteen files that has to be type-checked
# against the real package, which is a separate commit. What this census
# guarantees today is that the set cannot GROW, or float further,
# without somebody saying so here.
DENO_CENSUS = {
    'jsr:@supabase/supabase-js@2': 'the client every function uses',
    'jsr:@std/assert@1': 'the assertion library, test files only',
}

# Schemes a specifier may use. `https:` is absent deliberately: remote
# code from an arbitrary host, resolved at deploy time, is the supply
# chain attack this list exists to make impossible rather than unlikely.
ALLOWED_SCHEMES = ('jsr:', 'npm:', 'node:')

# `import ... from "x"`, `import "x"`, `export ... from "x"`, and
# `import("x")`. Anchored on the keyword so that a URL sitting in a
# string somewhere in a test fixture is not mistaken for a dependency --
# `supabase/functions` is full of `https://` literals that are test
# data about webhooks and callbacks, not imports.
_IMPORT = re.compile(
    r"""(?:^|\s)
        (?:
            (?:import|export)\s+(?:[\w*{},\s]+\s+from\s+)?
          | import\s*\(\s*
        )
        ['"](?P<spec>[^'"]+)['"]
    """,
    re.VERBOSE | re.MULTILINE,
)

# A jsr:/npm: specifier's version, if it has one:
#   jsr:@scope/name@2      -> '2'
#   npm:name@1.2.3         -> '1.2.3'
#   jsr:@scope/name        -> None
_SPEC = re.compile(
    r'^(?P<scheme>jsr|npm):(?P<name>@[^/@]+/[^@]+|[^@]+)(?:@(?P<version>[^/]+))?')


def deno_imports(root: str = ROOT) -> dict[str, list[str]]:
    """Every non-relative module specifier under supabase/functions, and
    the files importing it."""
    found: dict[str, list[str]] = {}
    base = os.path.join(root, 'supabase', 'functions')
    for dirpath, _dirs, files in os.walk(base):
        for name in sorted(files):
            if not name.endswith(('.ts', '.js', '.mjs')):
                continue
            path = os.path.join(dirpath, name)
            with open(path, encoding='utf-8') as fh:
                source = fh.read()
            for m in _IMPORT.finditer(source):
                spec = m.group('spec')
                if spec.startswith(('./', '../', '/')):
                    continue
                found.setdefault(spec, []).append(
                    os.path.relpath(path, root))
    return found


def check_deno(root: str = ROOT) -> list[str]:
    """The pins half, for the edge functions. Returns the failures."""
    problems: list[str] = []
    imports = deno_imports(root)

    for spec, files in sorted(imports.items()):
        where = f'{files[0]} (+{len(files) - 1} more)' if len(files) > 1 \
            else files[0]
        if not spec.startswith(ALLOWED_SCHEMES):
            problems.append(
                f'{where}: imports {spec!r}. Only '
                f'{", ".join(ALLOWED_SCHEMES)} may be imported -- code '
                f'fetched from an arbitrary host at deploy time is not '
                f'reviewable and not pinnable.')
            continue
        m = _SPEC.match(spec)
        if m and m.group('scheme') and not m.group('version'):
            problems.append(
                f'{where}: imports {spec!r} with no version. It would '
                f'resolve to whatever is published on the day it is '
                f'deployed.')
        if spec not in DENO_CENSUS:
            problems.append(
                f'{where}: {spec!r} is not in DENO_CENSUS. A new '
                f'dependency for the edge functions is a decision: add '
                f'it to the census in scripts/dependency_audit.py, with '
                f'a line saying what it is for.')

    for spec in sorted(DENO_CENSUS):
        if spec not in imports:
            problems.append(
                f'{spec!r} is in DENO_CENSUS and nothing imports it. '
                f'Take it off the census.')
    return problems


# ---------------------------------------------------------------------
# The Dart lockfile
# ---------------------------------------------------------------------
# pubspec.lock is YAML, and there is no YAML parser in the standard
# library. Rather than take a dependency to read a dependency file, this
# reads the shape pub actually writes, which is rigid: two spaces for a
# package name, four for its fields.
_LOCK_PKG = re.compile(r'^  ([A-Za-z_][A-Za-z0-9_]*):\s*$')
_LOCK_FIELD = re.compile(r'^    (\w+):\s*"?([^"\n]*)"?\s*$')


def pub_packages(text: str) -> dict[str, dict[str, str]]:
    """Package name -> {version, source, dependency} from a pubspec.lock."""
    packages: dict[str, dict[str, str]] = {}
    current: str | None = None
    in_packages = False
    for line in text.splitlines():
        if line.startswith('packages:'):
            in_packages = True
            continue
        if in_packages and line and not line.startswith(' '):
            break  # `sdks:` and anything else after the package block
        if not in_packages:
            continue
        m = _LOCK_PKG.match(line)
        if m:
            current = m.group(1)
            packages[current] = {}
            continue
        if current:
            f = _LOCK_FIELD.match(line)
            if f and f.group(1) in ('version', 'source', 'dependency'):
                packages[current][f.group(1)] = f.group(2)
    return {k: v for k, v in packages.items() if v.get('version')}


def check_pub(root: str = ROOT) -> tuple[list[str], dict[str, dict[str, str]]]:
    """The pins half, for Dart. Returns (failures, packages)."""
    problems: list[str] = []
    lock_path = os.path.join(root, 'app', 'pubspec.lock')
    with open(lock_path, encoding='utf-8') as fh:
        packages = pub_packages(fh.read())

    if len(packages) < 50:
        problems.append(
            f'app/pubspec.lock parsed to only {len(packages)} packages, '
            f'which means the parser and the file disagree rather than '
            f'that the app got smaller.')

    # Every direct dependency named in pubspec.yaml has to be resolved
    # in the lock. A name in one and not the other is a lockfile that
    # was not regenerated, and the version CI builds is then not the
    # version anybody chose.
    yaml_path = os.path.join(root, 'app', 'pubspec.yaml')
    with open(yaml_path, encoding='utf-8') as fh:
        yaml = fh.read()
    for block in ('dependencies:', 'dev_dependencies:'):
        section = yaml.split('\n' + block, 1)
        if len(section) < 2:
            continue
        for line in section[1].splitlines()[1:]:
            if line and not line.startswith(' '):
                break
            m = re.match(r'^  ([a-z_][a-z0-9_]*):', line)
            if not m:
                continue
            name = m.group(1)
            if name in ('flutter', 'flutter_test', 'flutter_lints', 'sdk'):
                continue
            if name not in packages:
                problems.append(
                    f'app/pubspec.yaml names {name} and app/pubspec.lock '
                    f'does not resolve it. Run `flutter pub get` and '
                    f'commit the lockfile.')
    return problems, packages


# ---------------------------------------------------------------------
# Advisories
# ---------------------------------------------------------------------
OSV_URL = 'https://api.osv.dev/v1/querybatch'

# What a jsr: specifier is called in OSV's world. OSV has no JSR
# ecosystem; @supabase/supabase-js is the same source published to both
# registries, so npm's advisories apply. @std/* is JSR-only and has no
# OSV ecosystem at all -- it is reported as UNCHECKED rather than
# counted as clean, because those are different facts.
JSR_TO_OSV = {'@supabase/supabase-js': ('npm', '@supabase/supabase-js')}


def osv_query(queries: list[dict], attempts: int = 3,
              opener=urllib.request.urlopen) -> list[dict]:
    """Ask OSV about a batch. Raises on failure; never returns empty on
    an error, which would read as 'no advisories'."""
    body = json.dumps({'queries': queries}).encode()
    last: Exception | None = None
    for attempt in range(attempts):
        try:
            req = urllib.request.Request(
                OSV_URL, data=body,
                headers={'content-type': 'application/json'})
            with opener(req, timeout=60) as response:
                return json.loads(response.read()).get('results', [])
        except (urllib.error.URLError, TimeoutError, OSError,
                json.JSONDecodeError) as exc:  # pragma: no cover - timing
            last = exc
            if attempt < attempts - 1:
                time.sleep(2 ** attempt)
    raise RuntimeError(
        f'the advisory database at {OSV_URL} could not be reached after '
        f'{attempts} attempts ({last}). This is a failure and not a '
        f'pass: nothing was checked.')


def advisories_for(packages: dict[str, dict[str, str]],
                   deno: dict[str, list[str]],
                   query=osv_query) -> tuple[list[str], list[str]]:
    """Returns (findings, unchecked)."""
    queries: list[dict] = []
    labels: list[str] = []
    unchecked: list[str] = []

    for name, meta in sorted(packages.items()):
        if meta.get('source') != 'hosted':
            unchecked.append(
                f'{name} {meta.get("version")} (source '
                f'{meta.get("source")}, not on pub.dev)')
            continue
        queries.append({'package': {'ecosystem': 'Pub', 'name': name},
                        'version': meta['version']})
        labels.append(f'Pub {name} {meta["version"]}')

    for spec in sorted(deno):
        m = _SPEC.match(spec)
        if not m or not m.group('version'):
            continue
        name, version = m.group('name'), m.group('version')
        mapped = JSR_TO_OSV.get(name)
        if not mapped:
            unchecked.append(
                f'{spec} (no OSV ecosystem covers it)')
            continue
        ecosystem, osv_name = mapped
        queries.append({'package': {'ecosystem': ecosystem, 'name': osv_name},
                        'version': version})
        labels.append(f'{ecosystem} {osv_name} {version}')

    findings: list[str] = []
    for chunk_start in range(0, len(queries), 100):
        chunk = queries[chunk_start:chunk_start + 100]
        results = query(chunk)
        if len(results) != len(chunk):
            raise RuntimeError(
                f'OSV answered {len(results)} results for {len(chunk)} '
                f'queries; the batch cannot be matched to what was asked.')
        for offset, result in enumerate(results):
            vulns = result.get('vulns') or []
            if vulns:
                ids = ', '.join(v.get('id', '?') for v in vulns)
                findings.append(f'{labels[chunk_start + offset]}: {ids}')
    return findings, unchecked


# ---------------------------------------------------------------------
def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--offline', action='store_true',
                        help='skip the advisory query and say so')
    args = parser.parse_args(argv)

    print('Dependency audit')
    print('-' * 60)

    problems = check_deno()
    pub_problems, packages = check_pub()
    problems += pub_problems

    deno = deno_imports()
    print(f'Deno   {len(deno)} module specifiers under supabase/functions')
    print(f'Dart   {len(packages)} packages resolved in app/pubspec.lock')

    if problems:
        print()
        for p in problems:
            print(f'::error::{p}')
        print(f'\n{len(problems)} pin problem(s).')
        return 1
    print('ok     every import is on the census, versioned and scheme-checked')
    print('ok     every direct Dart dependency is resolved in the lockfile')

    if args.offline:
        print('\nSKIPPED the advisory query (--offline). Nothing about '
              'published vulnerabilities was checked.')
        return 0

    try:
        findings, unchecked = advisories_for(packages, deno)
    except RuntimeError as exc:
        print(f'\n::error::{exc}')
        return 2

    if unchecked:
        print(f'\n{len(unchecked)} not covered by an advisory database:')
        for u in unchecked:
            print(f'  - {u}')

    if findings:
        print()
        for f in findings:
            print(f'::error::advisory affects {f}')
        print(f'\n{len(findings)} package(s) with a published advisory.')
        return 1

    print(f'\nok     no advisories against {len(packages)} Dart packages '
          f'and the edge functions'
          + (f' ({len(unchecked)} unchecked, listed above)'
             if unchecked else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())
