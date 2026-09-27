#!/usr/bin/env python3
"""A caught error is shown as its message, not as its wrapper.

    python3 scripts/check_error_text.py

## The failure this exists for

Reported with a screenshot of the bank reconciliation screen. The
database refused to close a reconciliation that was out by
RM 11,008.23 and said so in a sentence written for that moment --
"There are 24 statement lines still unmatched. Completing it now would
bury the difference." What reached the phone was that sentence wrapped
in `PostgrestException(message: ..., code: 23514, details: Bad
Request, hint: null)`.

The cause is one character wide and it is everywhere: `'$e'`.
`PostgrestException.toString()` prints its fields, so every screen that
interpolates a caught error shows the driver's envelope around the
sender's sentence. `runWithFeedback` -- how every action button in this
app reports a failure -- did it, and so did `AsyncView`, which is how
every screen reports one on load.

## What is checked

Every variable bound by `catch (e)`, `on X catch (e, st)`,
`error: (e, _)` or `onError: (e)` in `app/lib`, and every bare `$e`
interpolation of that variable inside the block it is bound for. Each
one must instead be `errorText(e)`, which returns the sentence and
leaves the envelope behind.

`${e.message}` and `${e.code}` are NOT flagged: naming a field is a
deliberate act and reads what it says. It is the bare interpolation --
the one that means "whatever this prints" -- that is the defect.

## What is allowed, and why

A sink that is not a person: `debugPrint` and `print`. A log line wants
everything the object knows, including the code and the hint, and
nobody is reading it in a snackbar.

Everything else is flagged, INCLUDING `throw SomeException('... $e')`.
An exception built around a raw wrapper carries that wrapper to
whatever shows it later, which is the same defect one step further
from the screen.

## What is NOT checked, said out loud

An error passed through a variable first -- `final m = '$e'; ...` -- is
flagged at the interpolation, which is right, but an error handed to
another function as an object and interpolated there is invisible: the
binding is in one scope and the use is in another. This gate is about
the literal interpolation, which is where this defect lives and where
it is cheap to be certain.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIB = ROOT / 'app/lib'

# Where a caught error is bound. `catch` covers both `try/catch` and
# `on X catch`; Riverpod's `AsyncValue.when` and `Future.onError` bind
# one the same way without the keyword.
BINDING = re.compile(
    r'\bcatch\s*\(\s*(?:final\s+)?(?:Object\s+|dynamic\s+)?(\w+)'
    r'|\berror:\s*\(\s*(?:Object\s+)?(\w+)\s*,'
    r'|\bonError:\s*\(\s*(?:Object\s+)?(\w+)\s*[,)]')

# Sinks that are not a person. A log line may hold the whole object.
QUIET = {'debugPrint', 'print', 'log'}


def spans(src: str):
    """Yields (start, end) of every comment and string literal."""
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            j = src.find('\n', i)
            j = n if j < 0 else j
            yield ('comment', i, j)
            i = j
        elif c == '/' and i + 1 < n and src[i + 1] == '*':
            j = src.find('*/', i + 2)
            j = n if j < 0 else j + 2
            yield ('comment', i, j)
            i = j
        elif c in '\'"':
            # Triple quotes run to the matching triple.
            triple = src[i:i + 3]
            if triple in ("'''", '"""'):
                j = src.find(triple, i + 3)
                j = n if j < 0 else j + 3
                yield ('string', i, j)
                i = j
                continue
            j = i + 1
            while j < n and src[j] != c:
                if src[j] == '\\':
                    j += 2
                elif src[j] == '\n':
                    break
                else:
                    j += 1
            j = min(j + 1, n)
            yield ('string', i, j)
            i = j
        else:
            i += 1


def code_only(src: str) -> str:
    """`src` with every comment and string blanked, keeping offsets."""
    out = list(src)
    for _kind, a, b in spans(src):
        for k in range(a, b):
            if out[k] != '\n':
                out[k] = ' '
    return ''.join(out)


def block_end(code: str, start: int) -> int:
    """End of the block a binding at `start` governs.

    `catch (e) { ... }` runs to the matching brace. `error: (e, _) =>
    ...` is an expression, and runs to wherever the parenthesis it sits
    inside closes.
    """
    i = start
    n = len(code)
    while i < n and code[i] not in '{;':
        if code[i] == '=' and code[i:i + 2] == '=>':
            break
        i += 1
    if i < n and code[i] == '{':
        depth = 0
        j = i
        while j < n:
            if code[j] == '{':
                depth += 1
            elif code[j] == '}':
                depth -= 1
                if depth == 0:
                    return j
            j += 1
        return n
    # An arrow body: to the close of the enclosing parenthesis.
    depth = 0
    j = i
    while j < n:
        if code[j] in '([{':
            depth += 1
        elif code[j] in ')]}':
            if depth == 0:
                return j
            depth -= 1
        j += 1
    return n


def enclosing_call(code: str, at: int) -> str:
    """Identifier of the innermost call `at` sits inside, or ''."""
    depth = 0
    i = at
    while i >= 0:
        c = code[i]
        if c in ')]}':
            depth += 1
        elif c in '([{':
            if depth == 0:
                if c != '(':
                    return ''
                m = re.search(r'([\w.]+)\s*$', code[:i])
                return m.group(1).split('.')[-1] if m else ''
            depth -= 1
        i -= 1
    return ''


def offenders(src: str):
    """(offset, name) for every bare interpolation of a caught error."""
    code = code_only(src)
    strings = [(a, b) for kind, a, b in spans(src) if kind == 'string']
    found = []
    for m in BINDING.finditer(code):
        name = next(g for g in m.groups() if g)
        end = block_end(code, m.end())
        bare = re.compile(r'\$' + re.escape(name) + r'(?![\w.])')
        for a, b in strings:
            if a < m.end() or b > end + 1:
                continue
            for hit in bare.finditer(src, a, b):
                if enclosing_call(code, a) in QUIET:
                    continue
                found.append((hit.start(), name))
    return found


def main() -> int:
    bad = []
    for path in sorted(LIB.rglob('*.dart')):
        src = path.read_text()
        for off, name in offenders(src):
            line = src.count('\n', 0, off) + 1
            text = src.splitlines()[line - 1].strip()
            bad.append((path.relative_to(ROOT), line, name, text))

    if bad:
        print('A caught error is being shown as its wrapper, not its message.')
        print('Use errorText(e) from core/error_text.dart.\n')
        for path, line, name, text in bad:
            print(f'  {path}:{line}  ${name} in  {text[:90]}')
        print(f'\n{len(bad)} site(s).')
        return 1

    print('ok every caught error is shown through errorText')
    return 0


if __name__ == '__main__':
    sys.exit(main())
