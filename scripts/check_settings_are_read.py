#!/usr/bin/env python3
"""Every key in `platform_settings` has something that reads it.

Three rows in that table said what they did and did nothing. `0298`
found `nav_grouping` — a switch that worked for exactly one person on
the platform, the administrator who set it. `0563` found
`signup_enabled`, which an operator could turn off and watch save while
strangers went on getting accounts. `0564` found `maintenance_mode`,
which promised a banner and blocked writes and did neither.

All three were seeded in `0018` and all three were found by reading the
table, not by anybody hitting them. A settings row is a promise that
something reads it, and a promise nobody checks is one that gets broken
three times in the same table.

So: read the keys out of the migrations that seed them, and count
references to each one across the SQL, the Dart and the Deno. A key
with no reader outside its own seed is a lever bolted to the wall and
connected to nothing.

    python3 scripts/check_settings_are_read.py "$DATABASE_URL"

The database argument is optional. With it, the keys come from the
table, which is the truth; without it they are read out of the
migrations, so the check still runs where there is no database.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Where a key may be seeded without that counting as reading it.
SEEDS = ('supabase/migrations/0018_platform_admin_modules_and_permissions.sql',)

# Trees that count as a reader.
TREES = ('supabase/migrations', 'supabase/functions', 'supabase/tests',
         'app/lib', 'scripts', 'docs')


def keys_from_database(url):
    out = subprocess.run(
        ['psql', url, '-tAc', 'select key from public.platform_settings'],
        capture_output=True, text=True)
    if out.returncode != 0:
        return None
    return sorted(k.strip() for k in out.stdout.splitlines() if k.strip())


def keys_from_migrations():
    found = set()
    path = os.path.join(ROOT, SEEDS[0])
    with open(path, encoding='utf-8') as fh:
        body = fh.read()
    for match in re.finditer(r"\(\s*'([a-z_]+)'\s*,\s*'\{", body):
        found.add(match.group(1))
    return sorted(found)


# A key named in a comment is prose about the table, not code that
# consults it. `0298`, `0563` and `0564` all explain the fault in their
# headers and name every key in it while doing so, so a check that
# counted comments would report the three settings it exists to find as
# read.
_SQL_LINE = re.compile(r'--.*?$', re.M)
_SLASH_LINE = re.compile(r'//.*?$', re.M)
_BLOCK = re.compile(r'/\*.*?\*/', re.S)


def code_only(path, body):
    """The file with its comments taken out."""
    if path.endswith('.sql'):
        return _SQL_LINE.sub('', body)
    if path.endswith(('.dart', '.ts', '.js')):
        return _SLASH_LINE.sub('', _BLOCK.sub('', body))
    if path.endswith('.py'):
        return re.sub(r'#.*?$', '', body, flags=re.M)
    return body


def references(key):
    """Every mention of the key, in code, outside the file that seeds it."""
    hits = []
    for tree in TREES:
        base = os.path.join(ROOT, tree)
        if not os.path.isdir(base):
            continue
        for dirpath, dirs, files in os.walk(base):
            # Compiled bytecode carries the strings its source does and
            # is not a reader of anything.
            dirs[:] = [d for d in dirs if d != '__pycache__']
            for name in files:
                path = os.path.join(dirpath, name)
                rel = os.path.relpath(path, ROOT)
                if rel in SEEDS:
                    continue
                try:
                    with open(path, encoding='utf-8', errors='ignore') as fh:
                        if key in code_only(rel, fh.read()):
                            hits.append(rel)
                except OSError:
                    continue
    return hits


def main():
    url = sys.argv[1] if len(sys.argv) > 1 else None
    keys = (keys_from_database(url) if url else None) or keys_from_migrations()
    if not keys:
        print('no settings keys found to check', file=sys.stderr)
        return 1

    unread = []
    for key in keys:
        hits = references(key)
        # Prose is not a reader, and neither is this script.
        real = [h for h in hits
                if not h.startswith('docs/')
                and h != 'scripts/check_settings_are_read.py']
        if not real:
            unread.append(key)

    if unread:
        print('these settings are read by nothing, so switching them '
              'does nothing: ' + ', '.join(unread), file=sys.stderr)
        print('Wire one, or delete the row. A settings row is a promise '
              'that something reads it.', file=sys.stderr)
        return 1

    print(f'ok  {len(keys)} platform settings, every one of them read')
    return 0


if __name__ == '__main__':
    sys.exit(main())
