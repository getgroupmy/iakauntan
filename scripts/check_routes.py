#!/usr/bin/env python3
"""Every screen this app navigates to is a screen that exists.

    python3 scripts/check_routes.py

## The failure this exists for

Reported with a screenshot of "No page at /banking". A bank statement
photographed in AI SmartScan, read by Gemini, charged for -- and then
`Create it from what was read` called

    context.go('/banking')

against a router that has never had a `/banking` route. The work was
done and thrown away on the last line of it.

Nothing could catch that. `context.go` takes a string; the analyser is
happy, every test passes, and the failure appears only when somebody
presses the button on the one path that reaches it.

## What is checked

Every `.go('/...')`, `.push('/...')`, `.replace(...)` and
`.pushReplacement(...)` in `lib/` whose target is a string literal, is
resolved against the routes `router.dart` declares. A target that
matches nothing is a dead end.

A `:param` segment matches any single segment, which is what it does at
runtime. An interpolated segment -- `${employee.id}` -- is likewise
treated as "some value", because that is all it is.

## What is NOT checked, said out loud

A path built entirely at runtime (`context.go(someVariable)`) is
invisible here, and there is no way to see it without running the app.
This gate is about the literals, which is where this failure lived and
where it is cheap to be certain.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ROUTER = ROOT / 'app/lib/src/core/router.dart'
LIB = ROOT / 'app/lib'

NAV = re.compile(r"\.(?:go|push|replace|pushReplacement)\(\s*'([^']*)'")


def _close(src: str, i: int) -> int:
    """Index of the bracket matching the one at `i`, skipping strings."""
    pairs = {'(': ')', '[': ']', '{': '}'}
    depth = 0
    j = i
    while j < len(src):
        c = src[j]
        # COMMENTS FIRST. A line comment reading "the company's own
        # page" has an apostrophe in it, and a scanner that treated it
        # as a string literal would run to the next quote mark and
        # swallow the code in between -- which is exactly what happened
        # here, and it hid seventeen routes including `/`.
        if c == '/' and j + 1 < len(src) and src[j + 1] == '/':
            j = src.find('\n', j)
            if j < 0:
                return len(src)
            continue
        if c == '/' and j + 1 < len(src) and src[j + 1] == '*':
            k = src.find('*/', j + 2)
            j = len(src) if k < 0 else k + 2
            continue
        if c in "'\"":
            q = c
            j += 1
            while j < len(src) and src[j] != q:
                j += 2 if src[j] == '\\' else 1
        elif c in pairs:
            depth += 1
        elif c in pairs.values():
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return len(src)


def _join(prefix: str, path: str) -> str:
    if path.startswith('/'):
        return path
    return (prefix.rstrip('/') + '/' + path) if prefix else '/' + path


def _walk(src: str, prefix: str, out: set[str]) -> None:
    """Every route declared in `src`, hung under `prefix`.

    The nesting is the whole point. A child's `path` is RELATIVE to its
    parent -- `/hr/people` with a child `new` is `/hr/people/new` -- and
    a checker that paired every absolute path with every relative one
    would invent `/:id` out of the root route and then match anything at
    all. That is not hypothetical: it is what the first version of this
    file did, and it passed the very bug it was written for.
    """
    i = 0
    while True:
        k = src.find('GoRoute(', i)
        if k < 0:
            return
        open_paren = k + len('GoRoute')
        end = _close(src, open_paren)
        body = src[open_paren + 1:end]
        i = end + 1

        m = re.search(r"path:\s*'([^']*)'", body)
        if not m:
            continue
        full = _join(prefix, m.group(1))
        out.add(full)

        r = re.search(r'routes:\s*\[', body)
        if r:
            b = body.index('[', r.start())
            _walk(body[b + 1:_close(body, b)], full, out)


def declared_routes(src: str) -> set[str]:
    """Every full path the router declares."""
    out: set[str] = set()
    _walk(src, '', out)

    # `_documentRoutes(prefix, type)` builds `$prefix/:docType` and its
    # children, so the literal in the file interpolates and the call
    # sites are what say which prefixes exist.
    # An arrow function returning a list, so the body is a `[`, not a
    # `{`. Looking for a block here found nothing and quietly dropped
    # every document route.
    body = None
    definition = re.search(r'List<RouteBase>\s+_documentRoutes\([^)]*\)\s*=>\s*\[',
                           src)
    if definition:
        b = src.rindex('[', definition.start(), definition.end())
        body = src[b + 1:_close(src, b)]
    for m in re.finditer(r"_documentRoutes\(\s*'([^']+)'", src):
        pre = m.group(1)
        if body:
            sub: set[str] = set()
            _walk(body.replace('$prefix', pre), '', sub)
            out |= sub
        else:
            out.add(pre + '/:docType')

    # And the `(path: '/customers', type: 'customer')` table beside it.
    for m in re.finditer(r"\(\s*path:\s*'(/[^']+)'\s*,\s*type:", src):
        out.add(m.group(1))
        if body:
            sub = set()
            _walk(body.replace('$prefix', m.group(1)), '', sub)
            out |= sub

    return {p for p in out if '$' not in p}


def matches(target: str, route: str) -> bool:
    t = [s for s in target.split('/') if s]
    r = [s for s in route.split('/') if s]
    if len(t) != len(r):
        return False
    for a, b in zip(t, r):
        if b.startswith(':'):
            continue          # a path parameter takes any one segment
        if '$' in a:
            continue          # an interpolated segment is some value
        if a != b:
            return False
    return True


def main() -> int:
    if not ROUTER.exists():
        print(f'FAIL no router at {ROUTER}', file=sys.stderr)
        return 1
    routes = declared_routes(ROUTER.read_text())
    if len(routes) < 50:
        # A parser that silently matched nothing would pass every file.
        print(f'FAIL only {len(routes)} routes found; the router did not parse',
              file=sys.stderr)
        return 1

    dead = []
    for f in sorted(LIB.rglob('*.dart')):
        text = f.read_text()
        for m in NAV.finditer(text):
            target = m.group(1)
            if not target.startswith('/'):
                continue      # a relative push is resolved by the router
            base = target.split('?')[0].split('#')[0]
            if any(matches(base, r) for r in routes):
                continue
            line = text[:m.start()].count('\n') + 1
            dead.append((f.relative_to(ROOT), line, target))

    if dead:
        print('FAIL these go somewhere the router does not:', file=sys.stderr)
        for f, line, target in dead:
            print(f'  {f}:{line}  {target}', file=sys.stderr)
        print(file=sys.stderr)
        print('  A person pressing that button gets "No page at ...".',
              file=sys.stderr)
        return 1

    print(f'ok   every navigation literal names a real route '
          f'({len(routes)} routes)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
