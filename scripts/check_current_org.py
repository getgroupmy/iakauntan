#!/usr/bin/env python3
"""The switcher's selection is not the current company.

    python3 scripts/check_current_org.py

`currentOrgIdProvider` holds the org somebody PICKED out of the company
switcher. It is null until they pick one -- which they never do if they
have one company, and mostly do not if they have two. The company they
are actually working in is resolved by `currentOrgProvider`, which falls
back to `profiles.last_org_id` and then to the first company they belong
to, and `repoProvider` is built from THAT.

So this is a provider whose null is the NORMAL case, with a name that
reads like the opposite, sitting next to one that does what the name
says. Every screen that read it got a null it treated as "not ready",
and the failures are silent by construction:

    final org = ref.read(currentOrgIdProvider);
    if (org == null) return;          // the Save button does nothing

That is a real report -- "Why can't save" on the assistant sheet, with
the same sheet's status card printing the word `null` because
`aiStatusProvider` was handing it an empty map for the same reason.
Thirteen call sites had it: EA forms, the time terminals, the subdomain
and the mailboxes, the addresses card, the export card, bookkeepers,
handover, mail compose, the SmartScan key card, the practice this
company belongs to, and who has held the company before. None of them
said anything; they were simply empty or inert.

## What this looks for

Any mention of `currentOrgIdProvider` outside `core/providers.dart`
that is not `.notifier`. Selecting and clearing are what the provider
is FOR, and they go through the notifier; everything else wants
`orgIdProvider`, which is `repoProvider`'s own org id and therefore
cannot disagree with the id the call is already scoped to.

Comments are blanked first, so the doc comment explaining this is not
itself an offence.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, 'app', 'lib')

# Where it is declared, where `currentOrgProvider` reads the selection
# to honour it, and where this gate is explained.
DECLARED_IN = os.path.join('app', 'lib', 'src', 'core', 'providers.dart')

USE = re.compile(r'\bcurrentOrgIdProvider\b(?!\s*\.\s*notifier)')

#: This gate expects to find NOTHING, which makes a floor on matches
#: useless -- it would demand that offenders exist. A clean codebase and
#: a blind sweep give the same answer, and it passed over an empty tree.
#:
#: So two controls instead, measuring the sweep rather than its result:
#:
#:   * LEAST_FILES -- how many .dart files the walk must have visited.
#:     544 today under app/lib; floored well below.
#:   * THE CANARY -- `USE` must still match inside providers.dart, the one
#:     file this gate deliberately skips because the provider is DECLARED
#:     there. If `currentOrgIdProvider` is ever renamed, the pattern stops
#:     matching everywhere at once, and the only way to notice is to check
#:     that it still matches where it is supposed to. 2 matches today --
#:     the GATE's number. A bare count of the pattern over that file says
#:     5, because three of them are in comments and the gate strips those
#:     first. The number a gate reports is the one to write down; a probe
#:     that re-implements the sweep has disagreed three times today.
#: LEAST_IN_DECLARATION stays at 1: the canary is "does it match at all",
#: not "does it match twice".
LEAST_FILES = int(os.environ.get('IAK_LEAST_SITES', '300'))
LEAST_IN_DECLARATION = 1


def strip_comments(source: str) -> str:
    """Blank out `//` comments, keeping line numbers.

    The fix for this bug documents the bug, quoting the line that had
    it. A scan of the raw text would report the explanation as the
    fault, which is a gate that goes red on the commit that fixed the
    thing it is watching for.
    """
    out = []
    for line in source.split('\n'):
        out.append('' if line.lstrip().startswith('//') else line)
    return '\n'.join(out)


def sweep_census(root: str = LIB) -> tuple[int, int]:
    """(.dart files the walk visits, matches inside the declaring file).

    The second number is the canary: the pattern must still match where
    the provider is DECLARED, or a rename has made the gate blind rather
    than satisfied.
    """
    visited = 0
    for dirpath, _dirs, files in os.walk(root):
        visited += sum(1 for n in files if n.endswith('.dart'))
    declared = os.path.join(ROOT, DECLARED_IN)
    if not os.path.isfile(declared):
        return visited, 0
    with open(declared, encoding='utf-8') as fh:
        return visited, len(USE.findall(strip_comments(fh.read())))


def offenders(root: str = LIB) -> list[str]:
    found: list[str] = []
    for dirpath, _dirs, files in os.walk(root):
        for name in sorted(files):
            if not name.endswith('.dart'):
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, ROOT)
            if rel == DECLARED_IN:
                continue
            with open(path, encoding='utf-8') as fh:
                source = strip_comments(fh.read())
            for m in USE.finditer(source):
                line = source.count('\n', 0, m.start()) + 1
                found.append(
                    f'{rel}:{line}: reads currentOrgIdProvider, which is '
                    f'the company switcher\'s selection and is null until '
                    f'somebody switches company -- so this is inert for '
                    f'everybody who never has. Use orgIdProvider, which is '
                    f'repoProvider\'s own org id. Selecting and clearing '
                    f'stay on .notifier.')
    return found


def main() -> int:
    visited, canary = sweep_census()
    if visited < LEAST_FILES:
        print(
            f'This sweep visited {visited} .dart file(s) under {LIB}, and '
            f'there were {LEAST_FILES} or more when it was written. A '
            f'sweep that reads nothing reports exactly what a clean '
            f'codebase reports.', file=sys.stderr)
        return 2
    if canary < LEAST_IN_DECLARATION:
        print(
            f'`currentOrgIdProvider` does not appear in {DECLARED_IN}, '
            f'where it is declared. Either it was renamed -- in which '
            f'case this pattern now matches nothing anywhere and the gate '
            f'is blind rather than satisfied -- or the file moved. This is '
            f'the canary, not a defect in the app.', file=sys.stderr)
        return 2

    bad = offenders()
    if bad:
        for b in bad:
            print(f'::error::{b}')
        return 1
    print(f'nothing mistakes the switcher\'s selection for the current '
          f'company ({visited} dart files read, {canary} declaration '
          f'reference(s) as the canary)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
