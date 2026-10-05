#!/usr/bin/env python3
"""A `mkdtemp` with nobody to remove it fills the disk, quietly.

Three test files here called `tempfile.mkdtemp()` and never removed the
result. Between them they leaked **28 directories per run** -- every
local run and every CI run -- and 7,052 of them were eventually found in
`/tmp`, 7.2G, at which point the disk was at 100% with 57M free.

The cost was not the space. A full disk does not present as a full disk:
the Dart frontend compiler sat at 857MB and 1.6% CPU unable to write its
output, and `flutter test` on one file produced ZERO BYTES in fifteen
minutes. That was first diagnosed as "this test file is twenty times
slower than the others, too expensive to mutate" -- a wrong conclusion
about the test suite drawn from a full disk. With space freed the same
file ran in 35 seconds.

So the rule: a function that calls `mkdtemp` must also, in the same
function, register the removal. Any of

    atexit.register(shutil.rmtree, root, True)
    self.addCleanup(shutil.rmtree, tmp, True)
    shutil.rmtree(tmp)

satisfies it. `tempfile.TemporaryDirectory()` needs nothing, because it
removes itself -- prefer it, and reach for `mkdtemp` only where the
directory has to outlive the function that builds it.

This is deliberately a STRUCTURAL check and not a judgement about
whether a directory matters. It asks one question with a yes or no
answer: is there a removal in the same function as the creation? Four
attempts were made on 4 October to gate something that needed judgement
and all four had to be thrown away; see docs/handoff.md parts eight to
eleven. This one needs none.
"""
from __future__ import annotations

import ast
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# A parse that matched nothing passes everything, so refuse to be that.
# `check_sweeps_look.py` exists because gates that look at nothing were
# reporting success; two empty schema dumps once compared clean.
LEAST_FILES = 60

#: Not ours, and a leak in them is not ours to fix.
SKIP = ('/.git/', '/__pycache__/', '/node_modules/', '/ephemeral/')

#: CANARIES: directories the sweep must still reach, each with at least
#: one python file in it. A floor on the TOTAL is not enough on its own,
#: because `scripts/` alone clears it -- and `check_sweeps_look.py` drives
#: every gate in a tree that holds a full copy of `scripts/` and empty
#: source directories, so a gate globbing only `scripts/` sails through
#: the one experiment designed to catch a sweep that is not looking.
#:
#: That is not hypothetical: this gate's first version did exactly that,
#: and `check_sweeps_look_test.py` failed with "check_temp_cleanup is in
#: no bucket and did not report over an empty tree". An excuse was the
#: wrong fix -- every excuse bucket there demands a SPECIFIC failure, and
#: "passed because the skeleton handed it the real thing" is not one.
#: Reaching outside `scripts/` is the fix, and it widens the gate's real
#: coverage at the same time: a `mkdtemp` leaking in `brand/build.py`
#: matters as much as one in a gate's self-test.
CANARIES = {
    'scripts': 'the gates and their self-tests, where all nine leaks were',
    'brand': 'the logo renderers, which write image files to temp dirs',
}


def python_files(root: pathlib.Path | None = None) -> list[pathlib.Path]:
    """Every first-party python file in the repository."""
    base = root or ROOT
    return sorted(p for p in base.rglob('*.py')
                  if p.is_file()
                  and not any(part in str(p) for part in SKIP))


def unreached(files: list[pathlib.Path],
              root: pathlib.Path | None = None) -> list[str]:
    """Canary directories that contributed no file."""
    base = root or ROOT
    seen = set()
    for f in files:
        try:
            seen.add(f.relative_to(base).parts[0])
        except ValueError:
            continue
    return sorted(d for d in CANARIES if d not in seen)


def _is_mkdtemp(node: ast.AST) -> bool:
    return (isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and node.func.attr == 'mkdtemp')


def _registers_removal(fn: ast.AST) -> bool:
    """Does anything in this function body remove a directory?

    Matched on the NAME `rmtree` wherever it appears as a call or is
    passed as a callable -- `atexit.register(shutil.rmtree, ...)` passes
    it without calling it, which a check for calls alone would miss.
    """
    for node in ast.walk(fn):
        if isinstance(node, ast.Attribute) and node.attr == 'rmtree':
            return True
        if isinstance(node, ast.Name) and node.id == 'rmtree':
            return True
    return False


def _name(path: pathlib.Path) -> str:
    """Repo-relative where possible, as given otherwise.

    A bare `path.relative_to(ROOT)` raises ValueError for anything
    outside the repository -- which is every file a self-test feeds it,
    so the gate could not be driven over a throwaway tree at all. Three
    of this gate's own tests failed on it. `check_thin_assertions.py`
    has the same guard in `key_for` for the same reason.
    """
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def offenders(files: list[pathlib.Path] | None = None) -> list[str]:
    out: list[str] = []
    for path in (python_files() if files is None else files):
        try:
            tree = ast.parse(path.read_text())
        except (OSError, SyntaxError):
            continue
        for fn in ast.walk(tree):
            if not isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            made = [n for n in ast.walk(fn) if _is_mkdtemp(n)]
            if made and not _registers_removal(fn):
                out.append('%s:%d  %s() calls mkdtemp and removes nothing'
                           % (_name(path), made[0].lineno, fn.name))
    return out


def main() -> int:
    files = python_files()

    missing = unreached(files)
    if missing:
        for d in missing:
            print('nothing python found under %s/ -- %s. This gate cannot '
                  'tick over a tree it cannot see.' % (d, CANARIES[d]),
                  file=sys.stderr)
        return 2

    if len(files) < LEAST_FILES:
        print('checked %d python files, expected at least %d -- this gate is '
              'looking in the wrong place, which is the one way it can pass '
              'over a real leak' % (len(files), LEAST_FILES), file=sys.stderr)
        return 2

    bad = offenders(files)
    if bad:
        print('mkdtemp with no removal in the same function:', file=sys.stderr)
        for line in bad:
            print('  ' + line, file=sys.stderr)
        print('\nUse tempfile.TemporaryDirectory() where the directory can '
              'die with the function. Where it cannot, register the removal:\n'
              '  root = tempfile.mkdtemp()\n'
              '  atexit.register(shutil.rmtree, root, True)',
              file=sys.stderr)
        return 1

    print('::notice::%d python files checked, every mkdtemp has a removal'
          % len(files))
    return 0


if __name__ == '__main__':
    sys.exit(main())
